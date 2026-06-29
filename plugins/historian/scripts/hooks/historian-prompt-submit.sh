#!/usr/bin/env bash
# Historian UserPromptSubmit retrieval pipeline.
#
# Flow:
#   1. Rate gate (cooldown_seconds, max_retrievals_per_session,
#      min_prompt_chars). Each ungated invocation costs one ollama
#      embedding round-trip; the gates keep the cost bounded.
#   2. Embed the prompt via the configured backend.
#   3. Stream every chunk record for the project from disk one line at
#      a time, cosine-search against the query vector, filter by
#      min_similarity and max_age_days.
#   4. Emit one historian.retrieval.surfaced event for the top match
#      and inject an `additionalContext` block whose first line is a
#      "looks similar" pointer and whose body is a multi-line excerpt
#      of the matched chunk.
#
# Hook contract:
#   - Always exits 0. Never blocks the prompt.
#   - Emits valid hookSpecificOutput JSON even when nothing to inject.
#   - No-ops when retrieval is disabled.
#   - Lifecycle events: historian.retrieval.started fires when the rate
#     gate clears and we are about to embed. All outcomes flow through
#     historian.retrieval.complete with `outcome: surfaced | empty |
#     skipped` and (on skipped) a `skip_reason` enum (short_prompt,
#     cooldown, budget, embedder_unavailable). The surfaced case also
#     emits historian.retrieval.surfaced with the matched chunk's
#     chunk_id, similarity, age_days, and source_session_id.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

_ECOSYSTEM_ROOT="${ONLOOKER_ECOSYSTEM_ROOT:-}"
if [[ -z "$_ECOSYSTEM_ROOT" ]]; then
	_candidate="$(cd "${PLUGIN_ROOT}/../.." 2>/dev/null && pwd)"
	if [[ -f "${_candidate}/scripts/lib/validate-path.sh" ]]; then
		_ECOSYSTEM_ROOT="$_candidate"
	fi
fi
if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
fi

# shellcheck source=../lib/historian-config.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-config.sh"
# shellcheck source=../lib/historian-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-project-key.sh"
# shellcheck source=../lib/historian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-storage.sh"
# shellcheck source=../lib/historian-emit.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-emit.sh"
# shellcheck source=../lib/historian-embedder.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-embedder.sh"
# shellcheck source=../lib/historian-retriever.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-retriever.sh"

_emit_context() {
	local context="${1:-}"
	jq -cn --arg ctx "$context" '{
		hookSpecificOutput: {
			hookEventName: "UserPromptSubmit",
			additionalContext: $ctx
		}
	}'
}

_now_ms() {
	python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null \
		|| echo "$(( $(date +%s) * 1000 ))"
}

INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // .user_message // .message // ""' 2>/dev/null) || PROMPT=""
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

REPO_ROOT=$(historian_project_repo_root "$CWD")
historian_config_load "$REPO_ROOT"

RETRIEVAL_ENABLED=$(historian_config_get '.historian.retrieval.enabled')
if [[ "$RETRIEVAL_ENABLED" == "false" ]]; then
	_emit_context ""
	exit 0
fi

PROJECT_KEY=$(historian_project_key "$CWD")
if [[ -z "$PROJECT_KEY" ]]; then
	_emit_context ""
	exit 0
fi

# ----------------------------------------------------------------------------
# Rate gate.
#
# Skipped paths emit historian.retrieval.complete with outcome:"skipped"
# and a skip_reason, matching the schema's lifecycle-event shape. There
# is no separate retrieval.skipped event in the schema; the outcome
# field carries that signal.
# ----------------------------------------------------------------------------

RETRIEVAL_STARTED_MS=$(_now_ms)

_emit_complete_skipped() {
	local reason="$1"
	local now duration
	now=$(_now_ms)
	duration=$((now - RETRIEVAL_STARTED_MS))
	historian_emit "historian.retrieval.complete" "$SESSION_ID" "$(jq -cn \
		--arg outcome "skipped" \
		--arg skip_reason "$reason" \
		--argjson duration_ms "$duration" \
		'{ outcome: $outcome, skip_reason: $skip_reason, duration_ms: $duration_ms }')"
}

MIN_PROMPT_CHARS=$(historian_config_get '.historian.retrieval.min_prompt_chars')
[[ -z "$MIN_PROMPT_CHARS" || "$MIN_PROMPT_CHARS" == "null" ]] && MIN_PROMPT_CHARS=60

PROMPT_LEN=${#PROMPT}
if (( PROMPT_LEN < MIN_PROMPT_CHARS )); then
	_emit_complete_skipped "short_prompt"
	_emit_context ""
	exit 0
fi

COOLDOWN_SECONDS=$(historian_config_get '.historian.retrieval.cooldown_seconds')
[[ -z "$COOLDOWN_SECONDS" || "$COOLDOWN_SECONDS" == "null" ]] && COOLDOWN_SECONDS=60
MAX_RETRIEVALS=$(historian_config_get '.historian.retrieval.max_retrievals_per_session')
[[ -z "$MAX_RETRIEVALS" || "$MAX_RETRIEVALS" == "null" ]] && MAX_RETRIEVALS=5

STATE=$(historian_retrieval_state_read "$PROJECT_KEY" "$SESSION_ID")
PREV_COUNT=$(printf '%s' "$STATE" | jq -r '.count // 0')
PREV_LAST_MS=$(printf '%s' "$STATE" | jq -r '.last_ms // 0')

NOW_MS=$(_now_ms)
ELAPSED_MS=$((NOW_MS - PREV_LAST_MS))
COOLDOWN_MS=$((COOLDOWN_SECONDS * 1000))

if (( PREV_LAST_MS > 0 && ELAPSED_MS < COOLDOWN_MS )); then
	_emit_complete_skipped "cooldown"
	_emit_context ""
	exit 0
fi

if (( PREV_COUNT >= MAX_RETRIEVALS )); then
	_emit_complete_skipped "budget"
	_emit_context ""
	exit 0
fi

# ----------------------------------------------------------------------------
# Embed the prompt + search.
# ----------------------------------------------------------------------------

historian_emit "historian.retrieval.started" "$SESSION_ID" "$(jq -cn \
	--argjson prompt_chars "$PROMPT_LEN" \
	'{ prompt_chars: $prompt_chars }')"

if ! historian_embedder_available; then
	BACKEND=$(historian_config_get '.historian.embedder.backend')
	[[ -z "$BACKEND" || "$BACKEND" == "null" ]] && BACKEND="none"
	historian_emit "historian.embedder.unavailable" "$SESSION_ID" "$(jq -cn \
		--arg backend "$BACKEND" '{ backend: $backend }')"
	_emit_complete_skipped "embedder_unavailable"
	_emit_context ""
	exit 0
fi

QUERY_EMBEDDING=$(historian_embedder_embed "$PROMPT")
if [[ -z "$QUERY_EMBEDDING" ]]; then
	_emit_complete_skipped "embedder_unavailable"
	_emit_context ""
	exit 0
fi

TOP_K=$(historian_config_get '.historian.retrieval.retrieval_top_k')
[[ -z "$TOP_K" || "$TOP_K" == "null" ]] && TOP_K=5
MIN_SIMILARITY=$(historian_config_get '.historian.retrieval.min_similarity')
[[ -z "$MIN_SIMILARITY" || "$MIN_SIMILARITY" == "null" ]] && MIN_SIMILARITY="0.55"
MAX_AGE=$(historian_config_get '.historian.retrieval.max_age_days')
[[ -z "$MAX_AGE" || "$MAX_AGE" == "null" ]] && MAX_AGE=180

SESSIONS_DIR=$(historian_sessions_dir "$PROJECT_KEY")
RESULTS=$(historian_retriever_search "$SESSIONS_DIR" "$QUERY_EMBEDDING" "$TOP_K" \
	"$MIN_SIMILARITY" "$MAX_AGE" "$SESSION_ID")
RESULT_COUNT=$(printf '%s' "$RESULTS" | jq 'length' 2>/dev/null) || RESULT_COUNT=0

# Bump the rate-gate state for any non-skipped run (we paid for the
# embedding regardless of whether anything matched).
historian_retrieval_state_write "$PROJECT_KEY" "$SESSION_ID" \
	"$((PREV_COUNT + 1))" "$NOW_MS" || true

if [[ "$RESULT_COUNT" == "0" ]]; then
	NOW=$(_now_ms)
	DURATION_MS=$((NOW - RETRIEVAL_STARTED_MS))
	historian_emit "historian.retrieval.complete" "$SESSION_ID" "$(jq -cn \
		--arg outcome "empty" \
		--argjson duration_ms "$DURATION_MS" \
		'{ outcome: $outcome, duration_ms: $duration_ms }')"
	_emit_context ""
	exit 0
fi

# ----------------------------------------------------------------------------
# Surfacer.
# ----------------------------------------------------------------------------

EXCERPT_MAX=$(historian_config_get '.historian.surfacer.excerpt_chars_max')
[[ -z "$EXCERPT_MAX" || "$EXCERPT_MAX" == "null" ]] && EXCERPT_MAX=400
INCLUDE_AGE=$(historian_config_get '.historian.surfacer.include_age_hint')
[[ -z "$INCLUDE_AGE" || "$INCLUDE_AGE" == "null" ]] && INCLUDE_AGE="true"

TOP=$(printf '%s' "$RESULTS" | jq -c '.[0]')
TOP_CHUNK_ID=$(printf '%s' "$TOP" | jq -r '.chunk_id // ""')
TOP_SIM=$(printf '%s' "$TOP" | jq -r '.similarity // 0')
TOP_AGE=$(printf '%s' "$TOP" | jq -r '.age_days // 0')
TOP_SESSION=$(printf '%s' "$TOP" | jq -r '.session_id // ""')
TOP_BODY=$(printf '%s' "$TOP" | jq -r '.body_redacted // ""')

EXCERPT="$TOP_BODY"
if (( ${#EXCERPT} > EXCERPT_MAX )); then
	EXCERPT="${EXCERPT:0:EXCERPT_MAX}…"
fi

if [[ "$INCLUDE_AGE" == "true" ]]; then
	AGE_HINT=" (${TOP_AGE}d ago, session ${TOP_SESSION})"
else
	AGE_HINT=""
fi

CONTEXT=$(printf 'Historian: a past chunk looks similar%s. Excerpt:\n\n> %s\n' \
	"$AGE_HINT" "$EXCERPT")

historian_emit "historian.retrieval.surfaced" "$SESSION_ID" "$(jq -cn \
	--arg chunk_id "$TOP_CHUNK_ID" \
	--argjson similarity "$TOP_SIM" \
	--argjson age_days "$TOP_AGE" \
	--arg source_session_id "$TOP_SESSION" \
	'{
		chunk_id: $chunk_id,
		similarity: $similarity,
		age_days: $age_days,
		source_session_id: $source_session_id
	}')"

NOW=$(_now_ms)
DURATION_MS=$((NOW - RETRIEVAL_STARTED_MS))
historian_emit "historian.retrieval.complete" "$SESSION_ID" "$(jq -cn \
	--arg outcome "surfaced" \
	--argjson top_similarity "$TOP_SIM" \
	--argjson candidates_above_floor "$RESULT_COUNT" \
	--argjson duration_ms "$DURATION_MS" \
	'{
		outcome: $outcome,
		top_similarity: $top_similarity,
		candidates_above_floor: $candidates_above_floor,
		duration_ms: $duration_ms
	}')"

_emit_context "$CONTEXT"
exit 0
