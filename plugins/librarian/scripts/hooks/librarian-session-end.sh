#!/usr/bin/env bash
# Librarian SessionEnd scan.
#
# Reads archivist artifacts created since the last librarian scan, runs them
# through the durability filter, classifies survivors via Haiku, and writes
# proposals to the queue for review at next SessionStart.
#
# Hook contract:
#   - Always exits 0. Never blocks session shutdown.
#   - No-ops when no project key (no git context) or no archivist artifacts.
#   - Classifier failures degrade gracefully: the affected candidate is
#     dropped, the rest of the scan proceeds.

set -uo pipefail

# Recursion guard — must be first, above hook_health_register, so a nested
# invocation is not measured as a real hook run (ecosystem-449.23).
#
# librarian reaches claude through librarian-classifier.sh. The nested session
# ends, firing SessionEnd and re-entering this hook.
[[ "${LIBRARIAN_NESTED:-}" == "1" ]] && exit 0
export LIBRARIAN_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "librarian-session-end"

# Ecosystem substrate (validate-path.sh) lives in the sibling ecosystem plugin.
# Resolution is shared rather than repeated: fourteen hooks each carried a
# byte-identical copy of this lookup, and it was wrong the same two ways in all
# fourteen (ecosystem-449.36, ecosystem-449.35). Fixing it fourteen times is how
# it stayed broken. See scripts/lib/substrate-resolve.sh.
# shellcheck source=../lib/substrate-resolve.sh
source "${PLUGIN_ROOT}/scripts/lib/substrate-resolve.sh"
_ECOSYSTEM_ROOT=$(onlooker_resolve_substrate "$PLUGIN_ROOT")

if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
fi

# shellcheck source=../lib/librarian-config.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
# shellcheck source=../lib/librarian-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
# shellcheck source=../lib/librarian-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
# shellcheck source=../lib/librarian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
# shellcheck source=../lib/librarian-emit.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
# shellcheck source=../lib/librarian-archivist-reader.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-archivist-reader.sh"
# shellcheck source=../lib/librarian-durability.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-durability.sh"
# shellcheck source=../lib/librarian-classifier.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-classifier.sh"
# shellcheck source=../lib/librarian-conflict-detector.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-conflict-detector.sh"
# shellcheck source=../lib/librarian-lesson-validate.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
# shellcheck source=../lib/librarian-lesson-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
# shellcheck source=../lib/librarian-lesson-transform.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-transform.sh"

librarian_now_ms() {
	local now_ms
	now_ms=$(python3 - <<'PY' 2>/dev/null
import time
print(int(time.time() * 1000))
PY
	) || now_ms=""
	[[ -z "$now_ms" ]] && now_ms=$(( $(date +%s) * 1000 ))
	printf '%s' "$now_ms"
}

INPUT=$(cat 2>/dev/null || true)
hook_health_context "$INPUT"
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

librarian_config_load "$CWD"

PROJECT_KEY=$(librarian_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && hook_health_exit 0

# Storage init + manifest refresh.
librarian_storage_init "$PROJECT_KEY" || hook_health_exit 0
REMOTE_URL=$(librarian_project_remote_url "$CWD")
REPO_ROOT=$(librarian_project_repo_root "$CWD")
librarian_storage_write_manifest "$PROJECT_KEY" "$REMOTE_URL" "$REPO_ROOT" || true

# ----------------------------------------------------------------------------
# Determine the watermark. Empty means "first scan" — fall back to N days ago.
# ----------------------------------------------------------------------------

WATERMARK=$(librarian_storage_read_last_scan "$PROJECT_KEY")

if [[ -z "$WATERMARK" ]]; then
	BOOTSTRAP_DAYS=$(librarian_config_get '.librarian.scan.bootstrap_lookback_days')
	[[ -z "$BOOTSTRAP_DAYS" || "$BOOTSTRAP_DAYS" == "null" ]] && BOOTSTRAP_DAYS=14
	WATERMARK=$(python3 -c "
import datetime
delta = datetime.timedelta(days=${BOOTSTRAP_DAYS})
now = datetime.datetime.now(datetime.timezone.utc)
print((now - delta).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null) || WATERMARK=""
fi

# ----------------------------------------------------------------------------
# Emit scan.started and load candidate window.
# ----------------------------------------------------------------------------

SCAN_START_TS_MS=$(librarian_now_ms)
ARTIFACTS=$(librarian_archivist_load_since "$PROJECT_KEY" "$WATERMARK")
ARTIFACT_COUNT=$(printf '%s' "$ARTIFACTS" | jq 'length' 2>/dev/null) || ARTIFACT_COUNT=0

librarian_emit "librarian.scan.started" "$SESSION_ID" "$(jq -cn \
	--arg trigger "session_end" \
	--arg last_scan_at "$WATERMARK" \
	--argjson artifact_count_in_window "$ARTIFACT_COUNT" \
	'{ trigger: $trigger, last_scan_at: (if $last_scan_at == "" then null else $last_scan_at end),
	   artifact_count_in_window: $artifact_count_in_window } | with_entries(select(.value != null))')"

# Bail with scan.complete{outcome: skipped} when archivist has nothing new
# for us. We still advance the watermark so subsequent scans don't re-walk
# the same window.
#
# A SKIP, not an empty result. This scan never reached classification, so it
# was never a chance to write anything - which is the opposite claim from the
# full pipeline below running, classifying everything and legitimately
# proposing nothing. Both reported "empty" until now, so a consumer could not
# tell "nothing to do" from "did the work, nothing came of it", and that
# distinction is exactly what a write-health check needs. `skipped` plus a
# reason is the vocabulary the schema already carried for this; librarian had
# simply never used it.
if [[ "$ARTIFACT_COUNT" == "0" ]]; then
	librarian_storage_write_last_scan "$PROJECT_KEY" || true
	DURATION_MS=$(( $(librarian_now_ms) - SCAN_START_TS_MS ))
	librarian_emit "librarian.scan.complete" "$SESSION_ID" "$(jq -cn \
		--arg outcome "skipped" \
		--arg skip_reason "no_new_artifacts" \
		--argjson duration_ms "$DURATION_MS" \
		--argjson candidates_proposed 0 \
		--argjson candidates_dropped 0 \
		--argjson artifact_count_in_window 0 \
		'{ outcome: $outcome, skip_reason: $skip_reason,
		   duration_ms: $duration_ms,
		   candidates_proposed: $candidates_proposed,
		   candidates_dropped: $candidates_dropped,
		   artifact_count_in_window: $artifact_count_in_window }')"
	hook_health_exit 0
fi

# ----------------------------------------------------------------------------
# Durability filter — cheap, deterministic, no network.
# ----------------------------------------------------------------------------

MARKERS_JSON=$(librarian_config_get '.librarian.durability_filter.marker_phrases | tojson')
[[ -z "$MARKERS_JSON" || "$MARKERS_JSON" == "null" ]] && MARKERS_JSON='[]'
MIN_DETAIL=$(librarian_config_get '.librarian.scan.min_detail_chars')
[[ -z "$MIN_DETAIL" || "$MIN_DETAIL" == "null" ]] && MIN_DETAIL=40

FILTERED=$(librarian_durability_filter "$ARTIFACTS" "$MARKERS_JSON" "$MIN_DETAIL")
KEPT=$(printf '%s' "$FILTERED" | jq '.kept')
DROPPED=$(printf '%s' "$FILTERED" | jq '.dropped')

# A scan that could not consult its markers has not judged its window, so it
# must not claim to have handled it. Keyed on filter_markers_unavailable and
# never on filter_marker_missing: the latter is an ordinary verdict, and
# holding on it would stall every repo whose artifacts are thin.
FAULT_DROPS=$(printf '%s' "$DROPPED" \
	| jq '[.[] | select(.reason == "filter_markers_unavailable")] | length' 2>/dev/null) \
	|| FAULT_DROPS=0
MAX_FAULT_RETRY=$(librarian_config_get '.librarian.scan.max_fault_retry_artifacts')
[[ -z "$MAX_FAULT_RETRY" || "$MAX_FAULT_RETRY" == "null" ]] && MAX_FAULT_RETRY=500

# Bounded: load_since re-reads every artifact in the window each session, so an
# unbounded hold degrades SessionEnd until the budget bail discards the backlog
# anyway. Past the ceiling we abandon it and say so, per artifact.
SHOULD_ADVANCE=1
RETRY_CAP_HIT=0
if [[ "$FAULT_DROPS" -gt 0 ]]; then
	if [[ "$ARTIFACT_COUNT" -ge "$MAX_FAULT_RETRY" ]]; then
		RETRY_CAP_HIT=1
	else
		SHOULD_ADVANCE=0
	fi
fi

# Emit one librarian.candidate.dropped event per artifact we filtered out
# pre-classifier. Caps at a sane number per scan so the event log stays
# scannable even if archivist piled up months of artifacts.
MAX_DROPPED_EVENTS=20
DROPPED_TOTAL=$(printf '%s' "$DROPPED" | jq 'length' 2>/dev/null) || DROPPED_TOTAL=0
DROPPED_EMIT_COUNT=$(( DROPPED_TOTAL < MAX_DROPPED_EVENTS ? DROPPED_TOTAL : MAX_DROPPED_EVENTS ))
for ((i = 0; i < DROPPED_EMIT_COUNT; i++)); do
	DROP=$(printf '%s' "$DROPPED" | jq -c ".[$i]")
	# retry_cap_exceeded REPLACES filter_markers_unavailable rather than adding
	# a second event. Both facts are true -- the markers were missing, and the
	# artifact is being abandoned -- but only one is terminal, and the terminal
	# one is what a reader needs.
	librarian_emit "librarian.candidate.dropped" "$SESSION_ID" "$(jq -cn \
		--argjson drop "$DROP" \
		--argjson cap_hit "$RETRY_CAP_HIT" \
		'{ reason: (if $cap_hit == 1 and $drop.reason == "filter_markers_unavailable"
		            then "retry_cap_exceeded" else $drop.reason end),
		   source_artifact_id: $drop.artifact_id }
		 | with_entries(select(.value != null))')"
done

# ----------------------------------------------------------------------------
# Runtime budget check: SessionEnd has 1.5s total. If we're running low on time,
# skip classification to ensure scan.complete can be emitted before CLI timeout.
# Retained artifacts will be re-scanned on the next session when time permits.
#
# The threshold is config-driven rather than hardcoded (ONL-104). Everything
# between SCAN_START_TS_MS and here -- loading the window, the durability filter
# loop, its per-artifact jq calls -- counts against this clock, so on a loaded
# machine the gate trips before classification and the scan proposes nothing.
# That is correct in production and ruinous in a test, where it made every
# assertion about proposals race a one-second timer and
# librarian-session-end.bats flake under `bats -j`. A knob lets a test pin the
# budget above any plausible delay, and lets this branch be driven on purpose.
# ----------------------------------------------------------------------------

ELAPSED_MS=$(( $(librarian_now_ms) - SCAN_START_TS_MS ))
BUDGET_THRESHOLD_MS=$(librarian_config_get '.librarian.scan.budget_threshold_ms')
[[ -z "$BUDGET_THRESHOLD_MS" || "$BUDGET_THRESHOLD_MS" == "null" ]] && BUDGET_THRESHOLD_MS=1000
if [[ "$ELAPSED_MS" -ge "$BUDGET_THRESHOLD_MS" ]]; then
	# The hold is a property of THIS scan, so it has to be honored wherever the
	# scan exits -- otherwise it leaks through the budget path at exactly the
	# moment the backlog is largest and load_since is slowest.
	[[ "$SHOULD_ADVANCE" == "1" ]] && { librarian_storage_write_last_scan "$PROJECT_KEY" || true; }
	DURATION_MS=$(( $(librarian_now_ms) - SCAN_START_TS_MS ))
	librarian_emit "librarian.scan.complete" "$SESSION_ID" "$(jq -cn \
		--arg outcome "budget_exceeded" \
		--argjson duration_ms "$DURATION_MS" \
		--argjson candidates_proposed 0 \
		--argjson candidates_dropped "$DROPPED_TOTAL" \
		--argjson artifact_count_in_window "$ARTIFACT_COUNT" \
		'{ outcome: $outcome, duration_ms: $duration_ms,
		   candidates_proposed: $candidates_proposed,
		   candidates_dropped: $candidates_dropped,
		   artifact_count_in_window: $artifact_count_in_window }')"
	hook_health_exit 0
fi

# ----------------------------------------------------------------------------
# Hand the surviving window to a detached worker (ecosystem-449.72).
#
# Classification used to happen here, inline: one claude call per surviving
# candidate, inside SessionEnd's 1500ms ceiling. Measured against the binary a
# hook actually resolves, one call put its answer on stdout at +39,065ms and
# exited at +46,484ms -- ~26x the whole budget, and most of it nested CLI
# session startup rather than model work (ecosystem-449.73).
#
# The per-call timeout was 20s, below the ~39s a call needs, so every call was
# killed before answering and recorded as classified_null. librarian has
# therefore never proposed a memory (ecosystem-449.67). Neither capping calls to
# the remaining budget nor timing them out inside it can work: one call does not
# fit, at any bound.
#
# So the window goes to disk and a worker takes it with no ceiling. The queue
# file is the durable record, which is what makes the watermark advance below
# safe -- artifacts are handed off, not dropped, so this does not depend on
# ecosystem-449.55.
# ----------------------------------------------------------------------------

KEPT_COUNT=$(printf '%s' "$KEPT" | jq 'length' 2>/dev/null) || KEPT_COUNT=0

if [[ "$KEPT_COUNT" == "0" ]]; then
	# Nothing to hand off, so nothing to defer. This path still reports for
	# itself: a quiet session that emitted no outcome at all would be
	# indistinguishable from one that died.
	#
	# This is where a marker fault actually lands: with no markers to match,
	# the filter keeps nothing, so KEPT_COUNT is 0 and the scan leaves here
	# rather than through the handoff below. The comment above about the queue
	# file making the advance safe reasons about the handoff path -- here there
	# is no queue file, because there was nothing to put in one.
	[[ "$SHOULD_ADVANCE" == "1" ]] && { librarian_storage_write_last_scan "$PROJECT_KEY" || true; }
	DURATION_MS=$(( $(librarian_now_ms) - SCAN_START_TS_MS ))
	librarian_emit "librarian.scan.complete" "$SESSION_ID" "$(jq -cn \
		--arg outcome "empty" \
		--argjson duration_ms "$DURATION_MS" \
		--argjson candidates_proposed 0 \
		--argjson candidates_dropped "$DROPPED_TOTAL" \
		--argjson artifact_count_in_window "$ARTIFACT_COUNT" \
		'{ outcome: $outcome, duration_ms: $duration_ms,
		   candidates_proposed: $candidates_proposed,
		   candidates_dropped: $candidates_dropped,
		   artifact_count_in_window: $artifact_count_in_window }')"
	hook_health_exit 0
fi

# Matched pair with the restore block at the top of the worker: a field dropped
# from here is silently empty there.
_write_classify_queue() {
	local dir="${ONLOOKER_DIR:-$HOME/.onlooker}/librarian/${PROJECT_KEY}/classify-queue"
	mkdir -p "$dir" 2>/dev/null || return 1
	local file="${dir}/$(librarian_ulid).json"
	jq -n \
		--arg cwd "$CWD" \
		--arg session_id "$SESSION_ID" \
		--arg project_key "$PROJECT_KEY" \
		--argjson artifacts "$KEPT" \
		--argjson artifact_count_in_window "$ARTIFACT_COUNT" \
		--argjson candidates_dropped "$DROPPED_TOTAL" \
		--argjson queued_at_ms "$SCAN_START_TS_MS" \
		'{ cwd: $cwd, session_id: $session_id, project_key: $project_key,
		   artifacts: $artifacts,
		   artifact_count_in_window: $artifact_count_in_window,
		   candidates_dropped: $candidates_dropped,
		   queued_at_ms: $queued_at_ms }' \
		> "$file" 2>/dev/null || return 1
	printf '%s' "$file"
	return 0
}

QUEUE_FILE=$(_write_classify_queue) || QUEUE_FILE=""

if [[ -z "$QUEUE_FILE" ]]; then
	# The queue could not be written, so the window was neither classified nor
	# handed off. Nothing is emitted here and the watermark is NOT advanced:
	# the artifacts stay in the next scan's window and get another chance.
	#
	# No scan.complete deliberately. skip_reason's enum is
	# archivist_not_present|memory_path_unresolved|disabled|no_new_artifacts,
	# and none of them describes "storage refused the handoff". Reaching for the
	# nearest one is the conflation ecosystem-449.39 records against stamping
	# "empty" on two paths that mean opposite things, and adding a value is a
	# change in a separate repo for a path that should be unreachable.
	#
	# The silence is not a gap: a scan.started with no scan.complete is exactly
	# what "this scan did not finish" looks like, and since ecosystem-449.66
	# that shape is legible rather than invisible.
	hook_health_exit 0
fi

# Detached, following plugin-currency-surfacer's _spawn_refresh: a subshell with
# explicit env passthrough, output discarded, disowned so SessionEnd does not
# wait on it. LIBRARIAN_CLASSIFY_WORKER is a test seam -- a real worker running
# concurrently would race the assertions.
_spawn_one() {
	local worker="$1" queue="$2"
	(
		ONLOOKER_DIR="${ONLOOKER_DIR:-}" \
			CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}" \
			ONLOOKER_ECOSYSTEM_ROOT="${ONLOOKER_ECOSYSTEM_ROOT:-}" \
			CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}" \
			CLAUDE_PROJECT_ENCODED="${CLAUDE_PROJECT_ENCODED:-}" \
			LIBRARIAN_NESTED="" \
			bash "$worker" "$queue"
	) >/dev/null 2>&1 &
	disown 2>/dev/null || true
	return 0
}

# Spawn for every queued window, not just the one this session wrote.
#
# A worker can die without finishing -- the session exits and takes it with it,
# the machine reboots -- and it deletes its queue file only on success, so its
# input is still there. But nothing else ever looks at it: this hook is the only
# writer, and a later session writes a NEW file rather than draining the old
# one. Without this loop those artifacts are stranded behind an already-advanced
# watermark, which is precisely the loss the queue exists to prevent.
#
# Spawning is a fork and a disown, so the extra ones are free, and a window
# already in flight is a no-op because the worker cannot take its lock. Bounded
# anyway: if orphans are piling up something is wrong, and starting an unbounded
# number of LLM workers is not the way to find out.
_spawn_classify() {
	local worker="${LIBRARIAN_CLASSIFY_WORKER:-${PLUGIN_ROOT}/scripts/lib/librarian-classify-worker.sh}"
	[[ -f "$worker" ]] || return 1

	local dir="${ONLOOKER_DIR:-$HOME/.onlooker}/librarian/${PROJECT_KEY}/classify-queue"
	local spawned=0 q
	while IFS= read -r q; do
		[[ -n "$q" ]] || continue
		_spawn_one "$worker" "$q"
		spawned=$((spawned + 1))
		[[ "$spawned" -ge 5 ]] && break
	done < <(ls -1t "$dir"/*.json 2>/dev/null)

	# Oldest-first would be fairer to a stranded window, but `ls -1t` is newest
	# first on purpose: this session's own window is the one whose proposals the
	# user is most likely to be waiting on, and it is always the newest.
	[[ "$spawned" -gt 0 ]] || return 1
	return 0
}

_spawn_classify || true

# ----------------------------------------------------------------------------
# Watermark advance.
#
# Safe to advance even though nothing has been classified yet: the queue file
# holds the window, and the worker deletes it only after succeeding. A worker
# that dies leaves its input on disk rather than behind an advanced watermark.
#
# scan.complete is deliberately NOT emitted here. The outcome enum is
# ok|empty|skipped|budget_exceeded with additionalProperties:false, and none of
# those means "queued for a worker" -- claiming one would be a false report, and
# adding a value would be a schema change in a separate repo. The worker emits
# it with the real counts when it lands, exactly as the currency probe emits
# onlooker.currency.checked for itself.
# ----------------------------------------------------------------------------

[[ "$SHOULD_ADVANCE" == "1" ]] && { librarian_storage_write_last_scan "$PROJECT_KEY" || true; }

hook_health_exit 0
