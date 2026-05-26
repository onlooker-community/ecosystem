#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/governor"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export CLAUDE_SESSION_ID="bats-ledger-$$"

	# shellcheck disable=SC1091
	source "${REPO_ROOT}/scripts/lib/portable-lock.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/governor-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/governor-events.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/governor-ledger.sh"

	export ONLOOKER_DIR="${TEST_HOME}/.onlooker"
	SID="ledger-test-session-$$"
}

_make_record() {
	local tokens="${1:-1000}"
	local cost="${2:-0.009}"
	jq -n \
		--arg ts "2026-01-01T00:00:00Z" \
		--arg sid "$SID" \
		--arg aid "test-agent" \
		--argjson est "$tokens" \
		--argjson cost "$cost" \
		'{
			ts: $ts,
			session_id: $sid,
			agent_id: $aid,
			agent_type: "Task",
			estimated_tokens: $est,
			cost_usd_estimated: $cost,
			duration_ms: 1000
		}'
}

_make_reservation() {
	local tokens="${1:-1000}"
	local cost="${2:-0.009}"
	jq -n \
		--arg ts "2026-01-01T00:00:00Z" \
		--arg sid "$SID" \
		--arg aid "test-agent" \
		--argjson est "$tokens" \
		--argjson cost "$cost" \
		'{
			ts: $ts,
			session_id: $sid,
			agent_id: $aid,
			agent_type: "Task",
			estimated_tokens: $est,
			cost_usd_estimated: $cost,
			record_type: "reservation"
		}'
}

_make_completion() {
	local neg_tokens="${1:--1000}"
	local actual_tokens="${2:-900}"
	local cost="${3:-0.009}"
	jq -n \
		--arg ts "2026-01-01T00:00:00Z" \
		--arg sid "$SID" \
		--arg aid "test-agent" \
		--argjson est "$neg_tokens" \
		--argjson actual "$actual_tokens" \
		--argjson cost "$cost" \
		'{
			ts: $ts,
			session_id: $sid,
			agent_id: $aid,
			agent_type: "Task",
			estimated_tokens: $est,
			actual_tokens: $actual,
			cost_usd_estimated: $cost,
			duration_ms: 1500
		}'
}

@test "governor_ledger_path returns a .jsonl path under ONLOOKER_DIR" {
	local p
	p=$(governor_ledger_path "test-session")
	[[ "$p" == *".jsonl" ]]
	[[ "$p" == *"test-session"* ]]
}

@test "governor_ledger_total_tokens returns 0 for missing ledger" {
	local total
	total=$(governor_ledger_total_tokens "no-such-session")
	[ "$total" = "0" ]
}

@test "governor_ledger_total_cost returns 0 for missing ledger" {
	local total
	total=$(governor_ledger_total_cost "no-such-session")
	[ "$total" = "0" ]
}

@test "governor_ledger_call_count returns 0 for missing ledger" {
	local count
	count=$(governor_ledger_call_count "no-such-session")
	[ "$count" = "0" ]
}

@test "governor_ledger_append writes a record and it is readable" {
	local record
	record=$(_make_record 5000 0.045)
	governor_ledger_append "$SID" "$record"

	local ledger_path
	ledger_path=$(governor_ledger_path "$SID")
	[ -f "$ledger_path" ]

	local lines
	lines=$(awk 'END{print NR}' "$ledger_path")
	[ "$lines" = "1" ]
}

@test "governor_ledger_total_tokens sums across multiple records" {
	governor_ledger_append "$SID" "$(_make_record 3000 0.027)"
	governor_ledger_append "$SID" "$(_make_record 4000 0.036)"
	governor_ledger_append "$SID" "$(_make_record 2500 0.023)"

	local total
	total=$(governor_ledger_total_tokens "$SID")
	[ "$total" = "9500" ]
}

@test "governor_ledger_total_cost sums across multiple records" {
	governor_ledger_append "$SID" "$(_make_record 1000 0.01)"
	governor_ledger_append "$SID" "$(_make_record 1000 0.02)"

	local total
	total=$(governor_ledger_total_cost "$SID")
	# Allow slight floating-point representation variance
	[[ "$total" =~ ^0\.03 ]]
}

@test "governor_ledger_call_count counts records" {
	governor_ledger_append "$SID" "$(_make_record 1000 0.009)"
	governor_ledger_append "$SID" "$(_make_record 1000 0.009)"
	governor_ledger_append "$SID" "$(_make_record 1000 0.009)"

	local count
	count=$(governor_ledger_call_count "$SID")
	[ "$count" = "3" ]
}

@test "governor_ledger_is_poisoned returns false for healthy ledger" {
	governor_ledger_append "$SID" "$(_make_record 1000 0.009)"
	run governor_ledger_is_poisoned "$SID"
	[ "$status" -ne 0 ]
}

@test "governor_ledger_is_poisoned returns true after poison sentinel" {
	local ledger_path
	ledger_path=$(governor_ledger_path "$SID")
	mkdir -p "$(dirname "$ledger_path")"
	touch "$(governor_ledger_poison_path "$ledger_path")"

	run governor_ledger_is_poisoned "$SID"
	[ "$status" -eq 0 ]
}

@test "governor_ledger_write_direct writes a record without acquiring the write lock" {
	local ledger_path
	ledger_path=$(governor_ledger_path "$SID")
	mkdir -p "$(dirname "$ledger_path")"

	local record
	record=$(_make_reservation 2000 0.018)
	governor_ledger_write_direct "$ledger_path" "$record"

	local lines
	lines=$(awk 'END{print NR}' "$ledger_path")
	[ "$lines" = "1" ]
}

@test "two-phase: reservation plus completion converges to actual tokens" {
	# Phase 1: PreToolUse writes reservation with N_est = 5000
	local reservation
	reservation=$(_make_reservation 5000 0.045)
	governor_ledger_append "$SID" "$reservation"

	local mid_total
	mid_total=$(governor_ledger_total_tokens "$SID")
	[ "$mid_total" = "5000" ]

	# Phase 2: PostToolUse writes completion with estimated=-5000, actual=4200
	local completion
	completion=$(_make_completion -5000 4200 0.045)
	governor_ledger_append "$SID" "$completion"

	# Net: 5000 + (-5000) + 4200 = 4200
	local final_total
	final_total=$(governor_ledger_total_tokens "$SID")
	[ "$final_total" = "4200" ]
}

@test "governor_ledger_call_count excludes reservation records" {
	governor_ledger_append "$SID" "$(_make_reservation 1000 0.009)"
	governor_ledger_append "$SID" "$(_make_completion -1000 900 0.009)"
	governor_ledger_append "$SID" "$(_make_completion -1000 800 0.009)"

	local count
	count=$(governor_ledger_call_count "$SID")
	# 2 completions, 1 reservation — only completions count
	[ "$count" = "2" ]
}
