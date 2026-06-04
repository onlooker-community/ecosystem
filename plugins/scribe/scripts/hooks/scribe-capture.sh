#!/usr/bin/env bash
# Scribe UserPromptSubmit hook — initial intent capture.
#
# Fires on every user prompt. On the FIRST turn of a session (captured_prompt
# is null in state), extracts and stores the prompt text as the problem
# statement seed for later distillation.
#
# Subsequent turns are ignored — the full transcript is available at Stop
# time, so there is no need to accumulate per-turn captures.
#
# Hook contract:
#   - Always exits 0. Never blocks a user prompt.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/scribe-config.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null) || PROMPT=""

_done() { exit 0; }

[[ -z "$SESSION_ID" || -z "$PROMPT" ]] && _done

scribe_config_load "$CWD"

if ! scribe_config_enabled; then
	_done
fi

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
STATE_FILE="${ONLOOKER_DIR}/scribe/sessions/${SESSION_ID}.json"

# Only capture if no prompt has been stored yet for this session.
if [[ -f "$STATE_FILE" ]]; then
	existing=$(jq -r '.captured_prompt // "null"' "$STATE_FILE" 2>/dev/null) || existing="null"
	[[ "$existing" != "null" && -n "$existing" ]] && _done
fi

# Truncate prompt to configured max chars.
max_chars=$(scribe_config_get '.scribe.capture.prompt_max_chars')
[[ -z "$max_chars" || "$max_chars" == "null" ]] && max_chars="1000"

truncated="${PROMPT:0:$max_chars}"
timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || timestamp=""

# Upsert state — preserve existing keys, update captured_prompt + captured_at.
if [[ -f "$STATE_FILE" ]]; then
	updated=$(jq \
		--arg p "$truncated" \
		--arg ts "$timestamp" \
		'.captured_prompt = $p | .captured_at = $ts' \
		"$STATE_FILE" 2>/dev/null) || updated=""
	if [[ -n "$updated" ]]; then
		printf '%s\n' "$updated" > "$STATE_FILE" || true
	fi
else
	mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
	jq -n \
		--arg sid "$SESSION_ID" \
		--arg p "$truncated" \
		--arg ts "$timestamp" \
		'{session_id: $sid, captured_prompt: $p, captured_at: $ts}' \
		2>/dev/null > "$STATE_FILE" || true
fi

_done
