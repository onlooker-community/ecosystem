#!/usr/bin/env bash
# JSONL ledger read/write for the governor plugin.
#
# Two-phase accounting model:
#
#   1. PreToolUse (gate): writes a "reservation" record inside the gate
#      lock with estimated_tokens > 0. This ensures concurrent spawns
#      each see the others' in-flight cost before deciding to allow.
#
#   2. PostToolUse (completion): writes a "Task" record with
#      estimated_tokens = -(original estimate) to cancel the reservation,
#      plus actual_tokens = observed count (if available). Net effect:
#
#        in-flight:  estimated_tokens(reservation) = N_est
#        completed:  estimated_tokens(Task) = -N_est, actual_tokens = N_act
#        total:      N_est + (-N_est) + N_act = N_act  ✓
#
# governor_ledger_total_tokens sums (.estimated_tokens + .actual_tokens)
# across all records so the running total is always:
#   (in-flight reservation estimates) + (completed actuals)
#
# Requires portable-lock.sh to be sourced beforehand.

GOVERNOR_LEDGER_MAX_RETRIES=3
GOVERNOR_LEDGER_LOCK_TIMEOUT=5

governor_ledger_path() {
	local session_id="${1:-unknown}"
	local dir="${ONLOOKER_DIR:-${HOME}/.onlooker}/governance/ledgers"
	local safe_id
	safe_id=$(printf '%s' "$session_id" | tr -c 'a-zA-Z0-9-' '_')
	printf '%s/%s.jsonl' "$dir" "$safe_id"
}

governor_ledger_poison_path() {
	local ledger_path="${1:-}"
	printf '%s.poisoned' "$ledger_path"
}

governor_ledger_is_poisoned() {
	local session_id="${1:-}"
	local ledger_path
	ledger_path=$(governor_ledger_path "$session_id")
	[[ -f "$(governor_ledger_poison_path "$ledger_path")" ]]
}

# Append a record to the ledger under the ledger's own write lock.
# Safe to call from PostToolUse and other hooks that do not already hold
# the gate lock. For writing inside the gate lock use governor_ledger_write_direct.
#
# Usage: governor_ledger_append "$session_id" "$record_json"
governor_ledger_append() {
	local session_id="${1:-}"
	local record="${2:-}"

	[[ -z "$session_id" || -z "$record" ]] && return 1

	local ledger_path
	ledger_path=$(governor_ledger_path "$session_id")
	local lock_path="${ledger_path}.lock"

	mkdir -p "$(dirname "$ledger_path")" 2>/dev/null || return 1

	local attempt=0
	local unrecorded_tokens=0
	unrecorded_tokens=$(printf '%s' "$record" | jq -r '.estimated_tokens // 0' 2>/dev/null) \
		|| unrecorded_tokens=0

	while (( attempt < GOVERNOR_LEDGER_MAX_RETRIES )); do
		if lock_acquire "$lock_path" "$GOVERNOR_LEDGER_LOCK_TIMEOUT"; then
			printf '%s\n' "$(printf '%s' "$record" | jq -c . 2>/dev/null)" >> "$ledger_path" 2>/dev/null
			local write_ok=$?
			lock_release "$lock_path"
			if (( write_ok == 0 )); then
				return 0
			fi
		fi
		attempt=$(( attempt + 1 ))
	done

	_governor_ledger_poison "$session_id" "$ledger_path" "$unrecorded_tokens"
	return 1
}

# Write a record directly to the ledger file without acquiring the write
# lock. ONLY call this when you already hold the gate lock, which serializes
# access. The gate lock is the same as the write lock (same .lock path), so
# re-acquiring it here would deadlock.
#
# Usage: governor_ledger_write_direct "$ledger_path" "$record_json"
governor_ledger_write_direct() {
	local ledger_path="${1:-}"
	local record="${2:-}"

	[[ -z "$ledger_path" || -z "$record" ]] && return 1

	mkdir -p "$(dirname "$ledger_path")" 2>/dev/null || return 1
	printf '%s\n' "$(printf '%s' "$record" | jq -c . 2>/dev/null)" >> "$ledger_path" 2>/dev/null
}

_governor_ledger_poison() {
	local session_id="${1:-}"
	local ledger_path="${2:-}"
	local unrecorded_tokens="${3:-0}"

	touch "$(governor_ledger_poison_path "$ledger_path")" 2>/dev/null || true

	local poison_payload
	poison_payload=$(jq -n \
		--arg sid "$session_id" \
		--arg aid "${CLAUDE_SESSION_ID:-unknown}" \
		--arg err "write failed after ${GOVERNOR_LEDGER_MAX_RETRIES} attempts" \
		--argjson retries "$GOVERNOR_LEDGER_MAX_RETRIES" \
		--argjson tok "$unrecorded_tokens" \
		'{
			session_id: $sid,
			agent_id: $aid,
			error: $err,
			retry_count: $retries,
			ledger_poisoned: true,
			unrecorded_tokens: $tok
		}' 2>/dev/null) || poison_payload="{}"

	governor_emit_event "governor.ledger.write_failed" "$poison_payload" || true
}

# Running total of tokens for a session.
#
# Uses the two-phase model: each record contributes
#   .estimated_tokens + (.actual_tokens // 0)
#
# In-flight reservations:  estimated_tokens > 0, no actual_tokens → counts N_est
# Completed Task records:  estimated_tokens = -N_est, actual_tokens = N_act → counts N_act
# Net: in-flight estimates + completed actuals.
#
# Usage: tokens=$(governor_ledger_total_tokens "$session_id")
governor_ledger_total_tokens() {
	local session_id="${1:-}"
	local ledger_path
	ledger_path=$(governor_ledger_path "$session_id")

	[[ -f "$ledger_path" ]] || { printf '0'; return 0; }

	jq -s '[.[] | ((.estimated_tokens // 0) + (.actual_tokens // 0))] | add // 0' \
		"$ledger_path" 2>/dev/null || printf '0'
}

# Running total of cost for a session (same two-phase logic as tokens).
# Usage: cost=$(governor_ledger_total_cost "$session_id")
governor_ledger_total_cost() {
	local session_id="${1:-}"
	local ledger_path
	ledger_path=$(governor_ledger_path "$session_id")

	[[ -f "$ledger_path" ]] || { printf '0'; return 0; }

	jq -s '[.[] | ((.cost_usd_estimated // 0) + (.cost_usd_actual // 0))] | add // 0' \
		"$ledger_path" 2>/dev/null || printf '0'
}

# Count completed Task calls (excludes reservation records).
# Usage: calls=$(governor_ledger_call_count "$session_id")
governor_ledger_call_count() {
	local session_id="${1:-}"
	local ledger_path
	ledger_path=$(governor_ledger_path "$session_id")

	[[ -f "$ledger_path" ]] || { printf '0'; return 0; }

	jq -s '[.[] | select(.agent_type == "Task" and .record_type != "reservation")] | length' \
		"$ledger_path" 2>/dev/null || printf '0'
}
