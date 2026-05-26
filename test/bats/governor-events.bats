#!/usr/bin/env bats

# Validates that governor.* events pass @onlooker-community/schema validation.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/governor"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/governor-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/governor-events.sh"

	export CLAUDE_SESSION_ID="bats-gov-session-$$"
}

_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

SID="bats-session-000"
AID="bats-agent-000"

@test "governor.gate.checked allow validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" --arg aid "$AID" \
		'{
			session_id: $sid,
			agent_id: $aid,
			agent_type: "Task",
			decision: "allow",
			estimated_tokens: 5000,
			tokens_available: 95000,
			estimation_method: "tier_table",
			safety_margin: 1.3
		}')
	governor_emit_event "governor.gate.checked" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.gate.checked block with reason validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" --arg aid "$AID" \
		'{
			session_id: $sid,
			agent_id: $aid,
			agent_type: "Task",
			decision: "block",
			reason: "budget_exceeded",
			estimated_tokens: 110000,
			tokens_available: 5000,
			estimation_method: "tier_table",
			safety_margin: 1.3
		}')
	governor_emit_event "governor.gate.checked" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.call.recorded validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" --arg aid "$AID" \
		'{
			session_id: $sid,
			agent_id: $aid,
			agent_type: "Task",
			estimated_tokens: 4200,
			cost_usd_estimated: 0.038,
			duration_ms: 3500
		}')
	governor_emit_event "governor.call.recorded" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.call.recorded with actuals validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" --arg aid "$AID" \
		'{
			session_id: $sid,
			agent_id: $aid,
			agent_type: "Task",
			estimated_tokens: 4200,
			actual_tokens: 3900,
			estimation_error_pct: 7.69,
			cost_usd_estimated: 0.038,
			cost_usd_actual: 0.035,
			duration_ms: 3500,
			tokens_returned_to_pool: 0
		}')
	governor_emit_event "governor.call.recorded" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.ledger.write_failed validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" --arg aid "$AID" \
		'{
			session_id: $sid,
			agent_id: $aid,
			error: "write failed after 3 attempts",
			retry_count: 3,
			ledger_poisoned: true,
			unrecorded_tokens: 4200
		}')
	governor_emit_event "governor.ledger.write_failed" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.budget.warning validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" \
		'{
			budget_usd: 1.0,
			spent_usd: 0.72,
			threshold_pct: 70,
			remaining_usd: 0.28,
			session_id: $sid,
			dimension: "cost_usd"
		}')
	governor_emit_event "governor.budget.warning" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.budget.exceeded validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" --arg aid "$AID" \
		'{
			budget_usd: 1.0,
			spent_usd: 1.05,
			blocked_operation: "Task spawn",
			session_id: $sid,
			agent_id: $aid,
			dimension: "tokens",
			estimated_call_cost: 0.08,
			ceiling_type: "session"
		}')
	governor_emit_event "governor.budget.exceeded" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.session.complete validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" \
		'{
			total_cost_usd: 0.42,
			budget_usd: 1.0,
			under_budget: true,
			session_id: $sid,
			total_tokens: 46200,
			total_api_calls: 11,
			duration_ms: 0,
			calls_blocked: 0,
			calls_warned: 2,
			ledger_poisoned: false
		}')
	governor_emit_event "governor.session.complete" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.lock.stale_cleared validates" {
	local p
	p=$(jq -n \
		'{
			lock_path: "/tmp/test.lock.d",
			lock_age_seconds: 120.5,
			pid_verified_dead: false
		}')
	governor_emit_event "governor.lock.stale_cleared" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.child.allocated validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" \
		'{
			session_id: $sid,
			parent_agent_id: "parent-001",
			child_agent_id: "child-001",
			child_agent_type: "tribunal-actor",
			tokens_allocated: 20000,
			cost_usd_allocated: 0.18,
			tokens_remaining_after_allocation: 80000,
			conservation_check_passed: true
		}')
	governor_emit_event "governor.child.allocated" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor.child.returned validates" {
	local p
	p=$(jq -n \
		--arg sid "$SID" \
		'{
			session_id: $sid,
			parent_agent_id: "parent-001",
			child_agent_id: "child-001",
			tokens_allocated: 20000,
			tokens_consumed: 14200,
			tokens_returned: 5800
		}')
	governor_emit_event "governor.child.returned" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "governor_emit_event returns nonzero for unknown event type" {
	run governor_emit_event "governor.no_such_event" '{"session_id":"x"}'
	[ "$status" -ne 0 ]
}
