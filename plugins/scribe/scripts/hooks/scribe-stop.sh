#!/usr/bin/env bash
# Scribe Stop hook — intent distillation.
#
# Fires when the agent session ends. Reads the full session transcript,
# runs a Haiku extraction pass to identify the problem context, decisions,
# tradeoffs, and constraints, then writes a Markdown intent document to
# ~/.onlooker/scribe/<project_key>/<date>-<session>.md.
#
# Skip conditions (all silent):
#   - scribe.enabled is false
#   - no transcript_path in hook input, or file is unreadable
#   - session has fewer turns than scribe.capture.min_turns
#
# Hook contract:
#   - Always exits 0. Never blocks Stop.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/scribe-config.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"
# shellcheck source=../lib/scribe-events.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-events.sh"
# shellcheck source=../lib/scribe-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-project-key.sh"
# shellcheck source=../lib/scribe-extract.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-extract.sh"
# shellcheck source=../lib/scribe-distill.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-distill.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""

export _HOOK_SESSION_ID="$SESSION_ID"

_done() { exit 0; }

[[ -z "$SESSION_ID" ]] && _done

scribe_config_load "$CWD"

if ! scribe_config_enabled; then
	_done
fi

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
	_done
fi

_distill_rc=0
output_path=$(scribe_distill "$SESSION_ID" "$CWD" "$TRANSCRIPT_PATH") || _distill_rc=$?
if [[ $_distill_rc -ne 0 ]]; then
	# rc=2 means below min_turns — silent skip, not an error.
	[[ $_distill_rc -ne 2 ]] && printf 'scribe-stop: distillation failed for session %s\n' "$SESSION_ID" >&2
	_done
fi

[[ -n "$output_path" ]] && printf 'scribe: intent document written → %s\n' "$output_path" >&2

_done
