#!/usr/bin/env bash
# JSONL ledger read/write for the governor plugin.
#
# One record per Task spawn. Each line is a JSON object written
# atomically via portable-lock.sh (mkdir-based) so concurrent hook
# invocations do not interleave partial writes.
#
# Ledger format (one JSON object per line):
#   {
#     "ts":                  "<ISO-8601>",
#     "session_id":          "<id>",
#     "agent_id":            "<id>",
#     "agent_type":          "<string>",
#     "estimated_tokens":    <int>,
#     "actual_tokens":       <int|null>,
#     "cost_usd_estimated":  <float>,
#     "duration_ms":         <int>
#   }
#
# A poisoned ledger (write failure after retries) gets a sentinel
# file alongside it so SessionStart can detect and refuse to run.
#
# Requires portable-lock.sh to be sourced beforehand.

GOVERNOR_LEDGER_MAX_RETRIES=3
GOVERNOR_LEDGER_LOCK_TIMEOUT=5

# Resolve the ledger path for a given session.
# Usage: path=$(governor_ledger_path "$session_id")
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

# Append a record to the ledger. Returns 0 on success, 1 if the ledger
# is poisoned after exhausting retries.
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
	unrecorded_tokens=$(printf '%s' "$record" | jq -r '.estimated_tokens // 0' 2>/dev/null) || unrecorded_tokens=0

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

	# Poison the ledger — budget accounting is now unreliable.
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
	return 1
}

# Read the total estimated tokens consumed in a session from the ledger.
# Usage: tokens=$(governor_ledger_total_tokens "$session_id")
governor_ledger_total_tokens() {
	local session_id="${1:-}"
	local ledger_path
	ledger_path=$(governor_ledger_path "$session_id")

	[[ -f "$ledger_path" ]] || { printf '0'; return 0; }

	jq -s '[.[].estimated_tokens // 0] | add // 0' "$ledger_path" 2>/dev/null \
		|| printf '0'
}

# Read the total estimated cost in a session from the ledger.
# Usage: cost=$(governor_ledger_total_cost "$session_id")
governor_ledger_total_cost() {
	local session_id="${1:-}"
	local ledger_path
	ledger_path=$(governor_ledger_path "$session_id")

	[[ -f "$ledger_path" ]] || { printf '0'; return 0; }

	jq -s '[.[].cost_usd_estimated // 0] | add // 0' "$ledger_path" 2>/dev/null \
		|| printf '0'
}

# Count API calls recorded in the ledger.
# Usage: calls=$(governor_ledger_call_count "$session_id")
governor_ledger_call_count() {
	local session_id="${1:-}"
	local ledger_path
	ledger_path=$(governor_ledger_path "$session_id")

	[[ -f "$ledger_path" ]] || { printf '0'; return 0; }

	awk 'END{print NR}' "$ledger_path" 2>/dev/null || printf '0'
}
