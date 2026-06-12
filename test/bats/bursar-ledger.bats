#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/bursar-ledger.sh"

	KEY="proj0123abcd"
}

_record() {
	# _record <session_id> <cost-or-empty> <tokens-or-empty> <ts_epoch>
	local sid="$1" cost="$2" tokens="$3" ts="$4"
	local rec
	rec=$(jq -n --arg sid "$sid" --arg pk "$KEY" --argjson te "$ts" \
		'{ts:"x", ts_epoch:$te, session_id:$sid, project_key:$pk, governor_present:true}')
	[ -n "$cost" ] && rec=$(printf '%s' "$rec" | jq --argjson v "$cost" '. + {cost_usd:$v}')
	[ -n "$tokens" ] && rec=$(printf '%s' "$rec" | jq --argjson v "$tokens" '. + {tokens:$v}')
	printf '%s' "$rec"
}

@test "recording a session creates a single ledger line" {
	local now
	now=$(date +%s)
	bursar_ledger_record "$KEY" "$(_record s1 1.0 100 "$now")"
	local path
	path=$(bursar_ledger_path "$KEY")
	[ -f "$path" ]
	[ "$(wc -l < "$path")" -eq 1 ]
}

@test "re-recording the same session upserts in place (idempotent)" {
	local now
	now=$(date +%s)
	bursar_ledger_record "$KEY" "$(_record s1 1.0 100 "$now")"
	bursar_ledger_record "$KEY" "$(_record s1 2.5 200 "$now")"
	local path
	path=$(bursar_ledger_path "$KEY")
	[ "$(wc -l < "$path")" -eq 1 ]
	[ "$(jq -r '.cost_usd' "$path")" = "2.5" ]
}

@test "different sessions append distinct lines" {
	local now
	now=$(date +%s)
	bursar_ledger_record "$KEY" "$(_record s1 1.0 100 "$now")"
	bursar_ledger_record "$KEY" "$(_record s2 2.0 200 "$now")"
	[ "$(wc -l < "$(bursar_ledger_path "$KEY")")" -eq 2 ]
}

@test "rolling_7d cutoff is roughly now minus seven days" {
	local now cutoff diff
	now=$(date +%s)
	cutoff=$(bursar_window_cutoff_epoch "rolling_7d" "monday")
	diff=$(( now - cutoff ))
	# 7 days = 604800s; allow a couple of seconds of clock drift across calls.
	[ "$diff" -ge 604798 ]
	[ "$diff" -le 604803 ]
}

@test "calendar_week cutoff is at or before now and not in the future" {
	local now cutoff
	now=$(date +%s)
	cutoff=$(bursar_window_cutoff_epoch "calendar_week" "monday")
	[ "$cutoff" -le "$now" ]
	# Never more than a full week back.
	[ "$(( now - cutoff ))" -le 604800 ]
}

@test "window totals sum cost and tokens, count sessions, and track cost coverage" {
	local now in1 in2 out
	now=$(date +%s)
	in1=$(( now - 100 ))
	in2=$(( now - 200 ))
	out=$(( now - 700000 ))   # older than 7 days

	local dir
	dir=$(bursar_ledger_dir "$KEY")
	mkdir -p "$dir"
	{
		_record withcost 1.0 100 "$in1"
		printf '\n'
		# governor absent: no cost_usd, no tokens
		jq -nc --arg pk "$KEY" --argjson te "$in2" \
			'{ts:"x", ts_epoch:$te, session_id:"nocost", project_key:$pk, governor_present:false}'
		_record stale 50.0 9999 "$out"
		printf '\n'
	} > "${dir}/sessions.jsonl"

	local cutoff totals
	cutoff=$(bursar_window_cutoff_epoch "rolling_7d" "monday")
	totals=$(bursar_window_totals "$KEY" "$cutoff")

	[ "$(printf '%s' "$totals" | jq -r '.total_cost_usd')" = "1" ]
	[ "$(printf '%s' "$totals" | jq -r '.total_tokens')" = "100" ]
	[ "$(printf '%s' "$totals" | jq -r '.session_count')" = "2" ]
	[ "$(printf '%s' "$totals" | jq -r '.sessions_with_cost')" = "1" ]
}

@test "window totals are zero when no ledger exists" {
	local totals
	totals=$(bursar_window_totals "nonexistent000" "0")
	[ "$(printf '%s' "$totals" | jq -r '.session_count')" = "0" ]
	[ "$(printf '%s' "$totals" | jq -r '.total_cost_usd')" = "0" ]
}

@test "token formatting is human-friendly" {
	[ "$(bursar_fmt_tokens 800)" = "800" ]
	[ "$(bursar_fmt_tokens 42000)" = "42k" ]
	[ "$(bursar_fmt_tokens 3100000)" = "3.1M" ]
}
