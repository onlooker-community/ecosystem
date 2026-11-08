#!/usr/bin/env bash
# Bursar stranded-session replay.
#
# SessionStart drops a breadcrumb for every session and SessionEnd removes it
# once the session is in the ledger. A breadcrumb that outlives its session
# therefore marks a session that never got recorded: the ledger lock was
# contended past SessionEnd's 1s timeout, the write failed, or the CLI killed
# the hook at its 1.5s SessionEnd deadline. Nothing read those files again, so
# the session was lost and the file stayed behind. 473 had piled up on one
# machine by 2026-11-08 (ONL-34).
#
# SessionStart launches this detached, so none of it counts against the
# session's startup. For each breadcrumb older than _BURSAR_REPLAY_MIN_AGE_MIN:
#
#   - already in the ledger   -> drop the breadcrumb, keep the real record
#   - no usable project key   -> discard the breadcrumb, counted in replay.log
#   - otherwise               -> record it as SessionEnd would have, with spend
#                                from the session's governor.session.complete
#                                when the log still has one
#   - ledger write failed     -> keep the breadcrumb for the next run
#
# A replayed record is dated to governor's event when there is one, since that
# fires at the session's last Stop, and to the session's start otherwise. Never
# to the replay itself: that would bill old sessions to this week's rollup.
#
# Always exits 0. Output goes to $ONLOOKER_DIR/bursar/replay.log.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}"

# shellcheck source=lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=lib/bursar-events.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-events.sh"
# shellcheck source=lib/bursar-ledger.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-ledger.sh"

# A day. Younger breadcrumbs may belong to a session that is still running. A
# resumed session rewrites its breadcrumb, so age is time since the last start,
# and a session replayed while still open is harmless anyway: the ledger is
# keyed by session_id, so its own SessionEnd replaces the replayed record.
_BURSAR_REPLAY_MIN_AGE_MIN=1440

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
BC_DIR="${ONLOOKER_DIR}/bursar/sessions"
REPLAY_LOG="${ONLOOKER_DIR}/bursar/replay.log"
LOG="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR}/logs/onlooker-events.jsonl}"

[[ -d "$BC_DIR" ]] || exit 0

CANDIDATES=$(find "$BC_DIR" -maxdepth 1 -type f -name '*.json' -mmin +"$_BURSAR_REPLAY_MIN_AGE_MIN" 2>/dev/null)
[[ -z "$CANDIDATES" ]] && exit 0

# Sessions starting together would otherwise replay the same files twice.
LOCK="${ONLOOKER_DIR}/bursar/replay.lock"
lock_acquire "$LOCK" 0 || exit 0
trap 'lock_release "$LOCK"' EXIT

# One pass over the event log for every candidate: the latest
# governor.session.complete per session, as {sid: {cost, tokens, calls, ts}}.
# grep pre-filters, so jq parses only governor's events, not the whole log.
SPEND='{}'
if [[ -f "$LOG" ]]; then
	SPEND=$(grep -F '"governor.session.complete"' "$LOG" 2>/dev/null \
		| jq -cs 'reduce (.[] | select(.event_type == "governor.session.complete")) as $e ({};
			.[$e.payload.session_id // ""] = {
				cost: $e.payload.total_cost_usd, tokens: $e.payload.total_tokens,
				calls: $e.payload.total_api_calls, ts: $e.timestamp })' 2>/dev/null) || SPEND='{}'
	[[ -z "$SPEND" ]] && SPEND='{}'
fi

replayed=0 already=0 discarded=0 failed=0

while IFS= read -r bc; do
	[[ -f "$bc" ]] || continue
	stem=$(basename "$bc" .json)

	# session_id joined the breadcrumb with this replay; older ones only carry
	# it in the file name, which SessionStart sanitizes to [a-zA-Z0-9-_].
	{ IFS= read -r sid; IFS= read -r pk; IFS= read -r started; } < <(
		jq -r '(.session_id // ""), (.project_key // ""), (.started_at // "")' "$bc" 2>/dev/null
	)
	[[ -z "${sid:-}" ]] && sid="$stem"

	if [[ -z "${pk:-}" ]]; then
		rm -f "$bc" 2>/dev/null || true
		discarded=$((discarded + 1))
		continue
	fi

	# SessionEnd recorded it but did not get to the rm.
	if grep -qF "\"session_id\":\"${sid}\"" "$(bursar_ledger_path "$pk")" 2>/dev/null; then
		rm -f "$bc" 2>/dev/null || true
		already=$((already + 1))
		continue
	fi

	model=""
	tracker="${ONLOOKER_DIR}/session-trackers/${sid}"
	[[ -f "$tracker" ]] && model=$(jq -r '.model // ""' "$tracker" 2>/dev/null)

	{ IFS= read -r RECORD; IFS= read -r EV; } < <(jq -rn \
		--arg sid "$sid" \
		--arg pk "$pk" \
		--arg started "${started:-}" \
		--arg model "$model" \
		--argjson spend "$SPEND" \
		'
		($spend[$sid] // null) as $g
		| (if $g != null and ($g.ts // "") != "" then $g.ts else $started end) as $ts
		| ($ts | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) as $te
		| if $te == null then empty else
			( {ts: ($ts | sub("\\.[0-9]+Z$"; "Z")), ts_epoch: $te, session_id: $sid,
			   project_key: $pk, governor_present: ($g != null)}
			  + (if ($g.cost   // null) != null then {cost_usd:  $g.cost}   else {} end)
			  + (if ($g.tokens // null) != null then {tokens:    $g.tokens} else {} end)
			  + (if ($g.calls  // null) != null then {api_calls: $g.calls}  else {} end)
			  + (if $model != "" then {model: $model} else {} end)
			) as $record
			| ($record | tojson), ($record | del(.ts, .ts_epoch) | tojson)
		  end
		' 2>/dev/null)

	# No timestamp to date it by: recording it as "now" would misplace it, so
	# fall back to the file mtime, which is when SessionStart wrote it.
	if [[ -z "${RECORD:-}" ]]; then
		mtime=$(stat -f %m "$bc" 2>/dev/null || stat -c %Y "$bc" 2>/dev/null || printf '')
		if [[ -n "$mtime" ]]; then
			{ IFS= read -r RECORD; IFS= read -r EV; } < <(
				jq -rn --arg sid "$sid" --arg pk "$pk" --arg model "$model" \
					--argjson te "$mtime" --arg ts "$(bursar_epoch_to_iso "$mtime")" \
					'({ts: $ts, ts_epoch: $te, session_id: $sid, project_key: $pk, governor_present: false}
					  + (if $model != "" then {model: $model} else {} end)) as $r
					| ($r | tojson), ($r | del(.ts, .ts_epoch) | tojson)' 2>/dev/null
			)
		fi
	fi
	if [[ -z "${RECORD:-}" ]]; then
		rm -f "$bc" 2>/dev/null || true
		discarded=$((discarded + 1))
		continue
	fi

	if bursar_ledger_record "$pk" "$RECORD"; then
		[[ -n "${EV:-}" ]] && { bursar_emit_event "bursar.session.recorded" "$EV" "$sid" || true; }
		rm -f "$bc" 2>/dev/null || true
		replayed=$((replayed + 1))
	else
		failed=$((failed + 1))
	fi
	RECORD="" EV=""
done <<<"$CANDIDATES"

printf '%s replayed=%d already_recorded=%d discarded=%d failed=%d\n' \
	"$(bursar_now_iso)" "$replayed" "$already" "$discarded" "$failed" >>"$REPLAY_LOG" 2>/dev/null || true

exit 0
