#!/usr/bin/env bash
# Session-scoped content gate state for Warden.
#
# The gate is a single JSON lock per session under
#   $ONLOOKER_DIR/warden/sessions/<session_id>/gate.json
#
# Absent file or {"state":"open"} → gate open (writes/edits/bash allowed).
# {"state":"closed", ...} → gate closed (those operations are blocked).
#
# The gate is closed by the detection hook on a positive scan and cleared
# ONLY by the user via the /warden skill (clear_policy: user_override_only).
#
# Exposes:
#   warden_gate_dir <session_id>
#   warden_gate_file <session_id>
#   warden_gate_is_closed <session_id>            # return 0 if closed
#   warden_gate_close <session_id> <threat_json>  # write closed lock
#   warden_gate_read <session_id>                 # echo gate JSON (empty if open/absent)
#   warden_gate_threat <session_id>               # echo stored threat object (empty if open)
#   warden_gate_clear <session_id>                # remove lock; echo prior threat object

warden_gate_dir() {
	local session_id="$1"
	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	printf '%s' "${onlooker_dir}/warden/sessions/${session_id}"
}

warden_gate_file() {
	local session_id="$1"
	printf '%s/gate.json' "$(warden_gate_dir "$session_id")"
}

warden_gate_is_closed() {
	local session_id="$1"
	local file
	file=$(warden_gate_file "$session_id")
	[[ -f "$file" ]] || return 1
	local state
	state=$(jq -r '.state // "open"' "$file" 2>/dev/null) || return 1
	[[ "$state" == "closed" ]]
}

warden_gate_read() {
	local session_id="$1"
	local file
	file=$(warden_gate_file "$session_id")
	[[ -f "$file" ]] || { printf ''; return 1; }
	cat "$file" 2>/dev/null
}

warden_gate_threat() {
	local session_id="$1"
	local file
	file=$(warden_gate_file "$session_id")
	[[ -f "$file" ]] || { printf ''; return 1; }
	jq -c '.threat // empty' "$file" 2>/dev/null
}

# Close the gate. $2 is the threat object (JSON) to record.
warden_gate_close() {
	local session_id="$1"
	local threat_json="${2:-}"
	[[ -z "$threat_json" ]] && threat_json='{}'
	local dir file now
	dir=$(warden_gate_dir "$session_id")
	file=$(warden_gate_file "$session_id")
	mkdir -p "$dir" 2>/dev/null || return 1
	now=$(date +%s 2>/dev/null) || now=0
	local out
	out=$(jq -n \
		--argjson ts "$now" \
		--argjson threat "$threat_json" \
		'{state:"closed", closed_at:$ts, threat:$threat}' 2>/dev/null) || return 1
	printf '%s\n' "$out" > "$file"
}

# List session ids that currently have a CLOSED gate (one per line). Used by
# the /warden skill to resolve the active gate when CLAUDE_SESSION_ID is not
# in the skill environment.
warden_list_closed_sessions() {
	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	local base="${onlooker_dir}/warden/sessions"
	[[ -d "$base" ]] || return 0
	local gate sid state
	for gate in "$base"/*/gate.json; do
		[[ -f "$gate" ]] || continue
		state=$(jq -r '.state // "open"' "$gate" 2>/dev/null) || continue
		[[ "$state" == "closed" ]] || continue
		sid=$(basename "$(dirname "$gate")")
		printf '%s\n' "$sid"
	done
}

# Clear the gate. Echoes the prior threat object (for the cleared event), then
# removes the lock. Returns 1 if the gate was not closed.
warden_gate_clear() {
	local session_id="$1"
	local file
	file=$(warden_gate_file "$session_id")
	[[ -f "$file" ]] || return 1
	local prior_threat
	prior_threat=$(jq -c '.threat // empty' "$file" 2>/dev/null) || prior_threat=""
	rm -f "$file" 2>/dev/null || return 1
	printf '%s' "$prior_threat"
}
