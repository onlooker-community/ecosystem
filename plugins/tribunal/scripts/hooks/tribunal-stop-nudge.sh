#!/usr/bin/env bash
# Tribunal Stop-time nudge.
#
# Triggered by Stop. Suggests /tribunal in one line to the USER when this
# session's edits are large or touch sensitive paths. Makes no model call.
# Spec: docs/superpowers/specs/2026-11-15-tribunal-nudge-design.md
#
# Hook contract:
#   - Always exits 0. Never blocks Stop.
#   - Stdout is empty or exactly {"systemMessage": "..."}. systemMessage is
#     shown to the user; hookSpecificOutput.additionalContext would instead
#     make Claude take another turn, which this deliberately does not do.
#   - Counts files THIS session's transcript shows it editing inside the
#     worktree, committed or not. Not the dirty tree: sessions here usually end
#     in a commit, and another session's work must never count.
#   - Speaks again only on growth: a new sensitive path, or twice the files.
#   - tribunal.nudge.skipped is emitted once per session per reason, tracked in
#     the state file, so a Stop that repeats a known skip starts no node.
#     `disabled` is never emitted: opting out must not cost every Stop.
#   - No *_NESTED guard: it runs no claude. The gate's nested judge runs with
#     disableAllHooks and never reaches this hook.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "tribunal-stop-nudge"

# shellcheck source=../lib/substrate-resolve.sh
source "${PLUGIN_ROOT}/scripts/lib/substrate-resolve.sh"
_ECOSYSTEM_ROOT=$(onlooker_resolve_substrate "$PLUGIN_ROOT")
if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/onlooker-schema.sh"
fi

# shellcheck source=../lib/tribunal-config.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-config.sh"
# shellcheck source=../lib/onlooker-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
# shellcheck source=../lib/tribunal-events.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-events.sh"
# shellcheck source=../lib/tribunal-verdict.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-verdict.sh"
# shellcheck source=../lib/tribunal-session-files.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-session-files.sh"
# shellcheck source=../lib/tribunal-nudge.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-nudge.sh"

INPUT=$(cat)
hook_health_context "$INPUT"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""

tribunal_config_load "$CWD"
[[ "$(tribunal_config_get '.tribunal.nudge.enabled')" == "true" ]] || hook_health_exit 0

REPO_ROOT=$(onlooker_project_repo_root "$CWD")
onlooker_project_resolve "$CWD"
PROJECT_KEY="${ONLOOKER_PROJECT_KEY:-}"
WORKTREE_ROOT=$(onlooker_worktree_root "$CWD")
[[ -z "$WORKTREE_ROOT" ]] && WORKTREE_ROOT="$REPO_ROOT"

# Sanitized as the gate does it. No id, no state file: two id-less sessions
# must never share one. An id-less session therefore has no memory of what it
# said and is nudged on every Stop once over threshold.
STATE_FILE=""
SAFE_SID=$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9-' '_')
if [[ -n "$SESSION_ID" ]]; then
	if [[ -n "$PROJECT_KEY" ]]; then
		STATE_FILE="$(tribunal_project_dir "$PROJECT_KEY")/nudge-${SAFE_SID}.json"
	else
		STATE_FILE="$(tribunal_storage_root)/_unkeyed/nudge-${SAFE_SID}.json"
	fi
fi
STATE=$(tribunal_nudge_state_read "$STATE_FILE")

# _skip <reason> — record and emit a reason once per session, then exit.
_skip() {
	local reason="$1"
	if printf '%s' "$STATE" | jq -e --arg r "$reason" '(.skips_reported // []) | index($r) != null' >/dev/null 2>&1; then
		hook_health_exit 0
	fi
	tribunal_nudge_state_write "$STATE_FILE" \
		"$(printf '%s' "$STATE" | jq -c --arg r "$reason" '.skips_reported = ((.skips_reported // []) + [$r])')"
	tribunal_emit_event "tribunal.nudge.skipped" \
		"$(jq -cn --arg r "$reason" '{reason: $r}')" >/dev/null 2>&1 || true
	hook_health_exit 0
}

tribunal_config_stop_hook_enabled && _skip "gate_enabled"
[[ -z "$PROJECT_KEY" || -z "$REPO_ROOT" ]] && _skip "no_project_context"
[[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]] && _skip "no_transcript"

SCAN=$(tribunal_nudge_scan "$TRANSCRIPT_PATH")
# Not a grep -q pipeline: grep exits at its first match, printf takes SIGPIPE
# once a long session's SCAN outruns the pipe buffer, and pipefail then reports
# 141, so the && never fired.
[[ $'\n'"$SCAN"$'\n' == *$'\n'T$'\n'* ]] && _skip "tribunal_ran"

# A glob list that is absent or not an array falls back to what config.json
# ships, read from the file rather than restated here.
_globs() {
	local key="$1" v
	v=$(tribunal_config_get_json ".tribunal.nudge.${key}")
	printf '%s' "$v" | jq -e 'type == "array"' >/dev/null 2>&1 \
		|| v=$(jq -c ".tribunal.nudge.${key} // []" "${PLUGIN_ROOT}/config.json" 2>/dev/null)
	printf '%s' "$v" | jq -r '.[]? | strings'
}
SENSITIVE_GLOBS=()
while IFS= read -r g; do [[ -n "$g" ]] && SENSITIVE_GLOBS+=("$g"); done < <(_globs sensitive_globs)
IGNORE_GLOBS=()
while IFS= read -r g; do [[ -n "$g" ]] && IGNORE_GLOBS+=("$g"); done < <(_globs ignore_globs)

# Globs compile once; nocasematch is set once around the loop (and restored
# after it) so each edited file costs two in-process regex tests, no forks.
SENS_RE=()
IGN_RE=()
[[ ${#SENSITIVE_GLOBS[@]} -gt 0 ]] && tribunal_nudge_compile_globs SENS_RE "${SENSITIVE_GLOBS[@]}"
[[ ${#IGNORE_GLOBS[@]} -gt 0 ]] && tribunal_nudge_compile_globs IGN_RE "${IGNORE_GLOBS[@]}"
WAS_NOCASE=0
if shopt -q nocasematch; then WAS_NOCASE=1; fi
shopt -s nocasematch

COUNT=0
SENSITIVE=()
while IFS= read -r f; do
	[[ -n "$f" ]] || continue
	if [[ ${#IGN_RE[@]} -gt 0 ]] && tribunal_nudge_matches_any_re "$f" "${IGN_RE[@]}"; then
		continue
	fi
	COUNT=$((COUNT + 1))
	if [[ ${#SENS_RE[@]} -gt 0 ]] && tribunal_nudge_matches_any_re "$f" "${SENS_RE[@]}"; then
		SENSITIVE+=("$f")
	fi
done < <(printf '%s\n' "$SCAN" | awk -F'\t' '$1 == "E" { print $2 }' | tribunal_paths_in_worktree "$WORKTREE_ROOT")

if [[ $WAS_NOCASE -eq 0 ]]; then shopt -u nocasematch; fi

SENSITIVE_JSON='[]'
[[ ${#SENSITIVE[@]} -gt 0 ]] && SENSITIVE_JSON=$(printf '%s\n' "${SENSITIVE[@]}" | jq -R . | jq -cs .)

MIN_FILES=$(tribunal_config_get_int '.tribunal.nudge.min_files' 8)
DECISION=$(tribunal_nudge_decide "$COUNT" "$SENSITIVE_JSON" "$MIN_FILES" "$STATE" 2>/dev/null) || DECISION=""
ACTION=$(printf '%s' "$DECISION" | jq -r '.action' 2>/dev/null) || ACTION=""

# decide prints nothing on state it cannot read (e.g. {"files":"x"}). Skipping
# with an empty reason would record "" in skips_reported, so leave quietly.
[[ -n "$ACTION" ]] || hook_health_exit 0

if [[ "$ACTION" != "nudge" ]]; then
	_skip "$(printf '%s' "$DECISION" | jq -r '.reason')"
fi

TRIGGER=$(printf '%s' "$DECISION" | jq -r '.trigger')
tribunal_nudge_state_write "$STATE_FILE" \
	"$(printf '%s' "$STATE" | jq -c --argjson n "$COUNT" --argjson s "$SENSITIVE_JSON" '.files = $n | .sensitive = $s')"
jq -cn --arg m "$(tribunal_nudge_message "$COUNT" "$SENSITIVE_JSON")" '{systemMessage: $m}'
tribunal_emit_event "tribunal.nudge.shown" \
	"$(jq -cn --arg t "$TRIGGER" --argjson n "$COUNT" --argjson s "$SENSITIVE_JSON" \
		'{trigger: $t, session_files: $n, sensitive_files: $s[0:20]}')" >/dev/null 2>&1 || true
hook_health_exit 0
