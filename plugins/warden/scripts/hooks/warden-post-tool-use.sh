#!/usr/bin/env bash
# Warden PostToolUse hook — detection path for WebFetch and Read.
#
# Fires after content has been ingested. Extracts the returned content,
# runs the hybrid scanner, and on a positive detection closes the session
# gate and emits warden.threat.detected.
#
# Why PostToolUse and not PreToolUse: the fetched/read content does not exist
# until the tool runs, and the threat model is what the agent does NEXT with
# that content. PostToolUse cannot (and need not) block the read itself — the
# PreToolUse enforcement hook blocks the downstream external action. See
# docs/adr/001-detect-after-ingest-gate-before-action.md.
#
# Hook contract:
#   - Always exits 0. Never blocks PostToolUse.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/warden-config.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-config.sh"
# shellcheck source=../lib/warden-events.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-events.sh"
# shellcheck source=../lib/warden-sanitizer.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-sanitizer.sh"
# shellcheck source=../lib/warden-patterns.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-patterns.sh"
# shellcheck source=../lib/warden-evaluator.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-evaluator.sh"
# shellcheck source=../lib/warden-scanner.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-scanner.sh"
# shellcheck source=../lib/warden-gate-state.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-gate-state.sh"
# shellcheck source=../lib/warden-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-ulid.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL_NAME=""

export _HOOK_SESSION_ID="$SESSION_ID"

_done() { exit 0; }

warden_config_load "$CWD"

[[ -z "$SESSION_ID" ]] && _done

# If the gate is already closed, there is nothing more to do — it stays closed
# until the user clears it. Skip the (potentially paid) scan entirely.
if warden_gate_is_closed "$SESSION_ID"; then
	_done
fi

# ---- Resolve source_type from the tool name. -------------------------
SOURCE_TYPE=""
SOURCE_URL=""
SOURCE_PATH=""
case "$TOOL_NAME" in
	WebFetch)
		SOURCE_TYPE="web_fetch"
		SOURCE_URL=$(printf '%s' "$INPUT" | jq -r '.tool_input.url // ""' 2>/dev/null) || SOURCE_URL=""
		;;
	Read)
		SOURCE_TYPE="file_read"
		SOURCE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null) || SOURCE_PATH=""
		;;
	*)
		_done
		;;
esac

# Honor configured scan.sources.
SOURCES_JSON=$(warden_config_get_json '.warden.scan.sources') || SOURCES_JSON="[]"
if ! printf '%s' "$SOURCES_JSON" | jq -e --arg s "$SOURCE_TYPE" 'index($s) != null' >/dev/null 2>&1; then
	_done
fi

# ---- skip_globs (file reads only). -----------------------------------
_matches_skip_glob() {
	local file_path="$1"
	local globs_json="$2"
	[[ -z "$file_path" || -z "$globs_json" ]] && return 1
	# bash 3.2 (macOS default) has no `mapfile`; collect with a while-read loop.
	local globs=() glob pattern
	while IFS= read -r glob; do
		[[ -n "$glob" ]] && globs+=("$glob")
	done < <(printf '%s' "$globs_json" | jq -r '.[]' 2>/dev/null)
	for glob in "${globs[@]}"; do
		pattern="${glob//\*\*/DOUBLE_STAR}"
		pattern="${pattern//\*/[^/]*}"
		pattern="${pattern//DOUBLE_STAR/.*}"
		if [[ "$file_path" =~ $pattern ]]; then
			return 0
		fi
	done
	return 1
}

if [[ -n "$SOURCE_PATH" ]]; then
	SKIP_GLOBS_JSON=$(warden_config_get_json '.warden.scan.skip_globs') || SKIP_GLOBS_JSON="[]"
	if _matches_skip_glob "$SOURCE_PATH" "$SKIP_GLOBS_JSON"; then
		_done
	fi
fi

# ---- Extract ingested content from the tool response. ----------------
MAX_CHARS=$(warden_config_get '.warden.scan.max_content_chars')
MAX_CHARS="${MAX_CHARS:-20000}"

CONTENT=$(printf '%s' "$INPUT" | jq -r '
	.tool_response as $r
	| if   ($r|type) == "string" then $r
	  elif ($r|type) == "object" then ($r.content // $r.text // $r.output // $r.result // ($r|tostring))
	  else ($r|tostring) end
	| if (type == "string") then . else tostring end
' 2>/dev/null) || CONTENT=""

[[ -z "$CONTENT" ]] && _done

# Cap length before scanning (the scanner caps again before any model call).
CONTENT="${CONTENT:0:$MAX_CHARS}"

# ---- Run the hybrid scanner. -----------------------------------------
SCAN=$(warden_scan "$SOURCE_TYPE" "$CONTENT")
DETECTED=$(printf '%s' "$SCAN" | jq -r '.detected // false' 2>/dev/null) || DETECTED="false"

if [[ "$DETECTED" != "true" ]]; then
	_done
fi

THREAT_TYPE=$(printf '%s' "$SCAN" | jq -r '.threat_type // "prompt_injection"' 2>/dev/null) || THREAT_TYPE="prompt_injection"
CONFIDENCE=$(printf '%s' "$SCAN" | jq -r '.confidence // 0.9' 2>/dev/null) || CONFIDENCE="0.9"
MATCHED_PATTERN=$(printf '%s' "$SCAN" | jq -r '.matched_pattern // ""' 2>/dev/null) || MATCHED_PATTERN=""
METHOD=$(printf '%s' "$SCAN" | jq -r '.method // "pattern_strong"' 2>/dev/null) || METHOD="pattern_strong"

# ---- Build a snippet for the local record (config-gated). ------------
STORE_SNIPPET=$(warden_config_get '.warden.scan.store_snippet')
STORE_SNIPPET="${STORE_SNIPPET:-true}"
SNIPPET_MAX=$(warden_config_get '.warden.scan.snippet_max_chars')
SNIPPET_MAX="${SNIPPET_MAX:-240}"
SNIPPET=""
if [[ "$STORE_SNIPPET" == "true" ]]; then
	SNIPPET=$(warden_sanitize "$CONTENT" "$SNIPPET_MAX")
fi

THREAT_ID=$(warden_ulid)

# ---- Close the gate with the full local threat record. ---------------
# (The local record keeps matched_pattern / threat_id / method for forensics;
#  the emitted event below carries only schema-permitted fields.)
THREAT_RECORD=$(jq -n \
	--arg id "$THREAT_ID" \
	--arg st "$SOURCE_TYPE" \
	--arg tt "$THREAT_TYPE" \
	--argjson conf "${CONFIDENCE:-0.9}" \
	--arg url "$SOURCE_URL" \
	--arg path "$SOURCE_PATH" \
	--arg snip "$SNIPPET" \
	--arg mp "$MATCHED_PATTERN" \
	--arg method "$METHOD" \
	'{
		threat_id:$id, source_type:$st, threat_type:$tt, confidence:$conf,
		source_url:(if $url == "" then null else $url end),
		source_path:(if $path == "" then null else $path end),
		snippet:(if $snip == "" then null else $snip end),
		matched_pattern:(if $mp == "" then null else $mp end),
		detection_method:$method
	}' 2>/dev/null) || THREAT_RECORD="{}"

warden_gate_close "$SESSION_ID" "$THREAT_RECORD" || {
	printf 'warden-post-tool-use: failed to close gate for session %s\n' "$SESSION_ID" >&2
	_done
}

# ---- Emit warden.threat.detected (schema-permitted fields only). -----
EVENT_PAYLOAD=$(jq -n \
	--arg st "$SOURCE_TYPE" \
	--arg tt "$THREAT_TYPE" \
	--argjson conf "${CONFIDENCE:-0.9}" \
	--arg url "$SOURCE_URL" \
	--arg path "$SOURCE_PATH" \
	--arg snip "$SNIPPET" \
	'{source_type:$st, threat_type:$tt, confidence:$conf}
	 + (if $url  != "" then {source_url:$url}   else {} end)
	 + (if $path != "" then {source_path:$path} else {} end)
	 + (if $snip != "" then {snippet:$snip}     else {} end)' 2>/dev/null) || EVENT_PAYLOAD=""

[[ -n "$EVENT_PAYLOAD" ]] && warden_emit_event "warden.threat.detected" "$EVENT_PAYLOAD" || true

_done
