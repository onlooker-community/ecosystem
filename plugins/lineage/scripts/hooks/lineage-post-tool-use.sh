#!/usr/bin/env bash
# Lineage PostToolUse hook (Edit / Write / MultiEdit).
#
# Records per-change provenance into the per-project change ledger and emits a
# lean lineage.change.recorded event. Kept cheap: metadata + a redacted,
# size-capped snippet of the added content + a digest — no transcript parsing
# (the prompt is resolved lazily at /lineage query time).
#
# Hook contract: always exits 0; never blocks the tool. Skips silently when
# disabled, when the path is ignored, or when the file is outside the repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=../lib/lineage-config.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-config.sh"
# shellcheck source=../lib/lineage-events.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-events.sh"
# shellcheck source=../lib/lineage-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-project-key.sh"
# shellcheck source=../lib/lineage-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-ulid.sh"
# shellcheck source=../lib/lineage-redact.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-redact.sh"
# shellcheck source=../lib/lineage-record.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-record.sh"

INPUT=$(cat)
_done() { exit 0; }

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL=""
TOOL_INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null) || TOOL_INPUT="{}"
TOOL_USE_ID=$(printf '%s' "$INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null) || TOOL_USE_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""

case "$TOOL" in
	Edit | Write | MultiEdit) ;;
	*) _done ;;
esac

[[ -z "$CWD" ]] && CWD="$(pwd)"
REPO_ROOT=$(lineage_project_repo_root "$CWD")
lineage_config_load "$REPO_ROOT"

PROJECT_KEY=$(lineage_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && _done

FILE_PATH=""
case "$TOOL" in
	MultiEdit)
		# MultiEdit applies to one file via a top-level file_path; some shapes
		# nest file_path per edit, so fall back to the first edit's.
		FILE_PATH=$(printf '%s' "$TOOL_INPUT" | jq -r '.file_path // .edits[0].file_path // ""' 2>/dev/null) || FILE_PATH=""
		# If edits carry distinct per-file paths spanning more than one file,
		# skip to avoid misattribution. (Future: split into one record per file.)
		unique_count=$(printf '%s' "$TOOL_INPUT" | jq -r '[.edits[]?.file_path // empty] | unique | length' 2>/dev/null) || unique_count=0
		[[ "${unique_count:-0}" -gt 1 ]] && _done
		;;
	*)
		FILE_PATH=$(printf '%s' "$TOOL_INPUT" | jq -r '.file_path // .path // ""' 2>/dev/null) || FILE_PATH=""
		;;
esac
[[ -z "$FILE_PATH" ]] && _done

# Skip ignored paths. Supports the common glob shapes in config:
#   **/<dir>/**  → path-segment match ;  **/*.<ext> → suffix match.
_lineage_ignored() {
	local path="$1" glob core
	while IFS= read -r glob; do
		[[ -z "$glob" ]] && continue
		core="$glob"
		core="${core#\*\*/}"
		core="${core%/\*\*}"
		case "$core" in
			\*.*) [[ "$path" == *"${core#\*}" ]] && return 0 ;;
			*) [[ "/$path/" == *"/$core/"* ]] && return 0 ;;
		esac
	done < <(lineage_config_ignore_globs)
	return 1
}
_lineage_ignored "$FILE_PATH" && _done

# Skip files outside the repo (best-effort). Resolve the file's directory to a
# real path so the prefix test survives symlinked roots (e.g. macOS /var →
# /private/var, where REPO_ROOT is already realpath-resolved).
if [[ -n "$REPO_ROOT" && "$FILE_PATH" == /* ]]; then
	_file_dir=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P) || _file_dir=""
	if [[ -n "$_file_dir" && "$_file_dir" != "$REPO_ROOT" && "$_file_dir"/ != "$REPO_ROOT"/* ]]; then
		_done
	fi
fi

# Turn number (best-effort) from the substrate session tracker.
TURN=""
TRACKER="${ONLOOKER_DIR:-$HOME/.onlooker}/session-trackers/${SESSION_ID}"
[[ -n "$SESSION_ID" && -f "$TRACKER" ]] && TURN=$(jq -r '.turn_number // empty' "$TRACKER" 2>/dev/null)

MAX_CHARS=$(lineage_config_max_snippet_chars)
DO_REDACT=true
lineage_config_redact_enabled || DO_REDACT=false
CHANGE_ID=$(lineage_ulid)
TS=$(lineage_now_iso)
TS_EPOCH=$(lineage_now_epoch)

RECORD=$(lineage_build_record "$CHANGE_ID" "$TS" "$TS_EPOCH" "$SESSION_ID" "$TURN" \
	"$TOOL" "$FILE_PATH" "$TOOL_INPUT" "$MAX_CHARS" "$DO_REDACT" "$TRANSCRIPT_PATH")
[[ -z "$RECORD" ]] && _done

if lineage_append "$PROJECT_KEY" "$RECORD"; then
	# Lean bus event: metadata + digest only — never the added content.
	EV=$(printf '%s' "$RECORD" | jq -c --arg pk "$PROJECT_KEY" --arg tuid "$TOOL_USE_ID" '
		{
			project_key: $pk, session_id: .session_id, file_path: .file_path,
			tool: .tool, operation: .operation, change_id: .change_id,
			lines_added: .lines_added, lines_removed: .lines_removed,
			bytes: .bytes, edit_count: .edit_count, content_sha256: .content_sha256
		}
		+ (if .turn != null then {turn: .turn} else {} end)
		+ (if $tuid != "" then {tool_use_id: $tuid} else {} end)
	' 2>/dev/null)
	[[ -n "$EV" ]] && lineage_emit_event "lineage.change.recorded" "$EV" "$SESSION_ID" || true
fi

_done
