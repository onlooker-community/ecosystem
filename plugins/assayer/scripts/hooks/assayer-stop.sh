#!/usr/bin/env bash
# Assayer Stop hook.
#
# Triggered by Stop. Reads the just-finished session's transcript, extracts the
# agent's testable success claims from its final message, and cross-checks each
# against the actual Bash command results in the same transcript. Each claim is
# classified corroborated / contradicted / unverified and emitted as an event.
#
# Hook contract:
#   - Always exits 0. Advisory only — never blocks Stop.
#   - Skips silently if disabled, no git context, no transcript, or no claims.
#   - Recursion guard: exits immediately if ASSAYER_NESTED=1 to prevent a
#     claude -p subprocess from re-triggering this hook on its own Stop.
#   - Never runs the extraction LLM call itself: it snapshots the inputs and
#     hands them to a detached assayer-audit.sh, which owns `claude -p`.

set -uo pipefail

# Recursion guard — must be first.
[[ "${ASSAYER_NESTED:-}" == "1" ]] && exit 0
export ASSAYER_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "assayer-stop"

# Resolve the ecosystem root (sibling to this plugin's parent).
_ECOSYSTEM_ROOT="${ONLOOKER_ECOSYSTEM_ROOT:-}"
if [[ -z "$_ECOSYSTEM_ROOT" ]]; then
	_candidate="$(cd "${PLUGIN_ROOT}/../.." 2>/dev/null && pwd)"
	if [[ -f "${_candidate}/scripts/lib/validate-path.sh" ]]; then
		_ECOSYSTEM_ROOT="$_candidate"
	fi
fi
# Glob-discover the ecosystem plugin under the shared plugin cache parent;
# works regardless of which ecosystem version is installed.
if [[ -z "$_ECOSYSTEM_ROOT" ]]; then
	for _candidate in "${PLUGIN_ROOT}/../../ecosystem/"*/scripts/lib/validate-path.sh; do
		if [[ -f "$_candidate" ]]; then
			_ECOSYSTEM_ROOT="$(cd "$(dirname "$(dirname "$_candidate")")" && pwd)"
			break
		fi
	done
fi

if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/onlooker-schema.sh"
fi

# shellcheck source=../lib/assayer-config.sh
source "${PLUGIN_ROOT}/scripts/lib/assayer-config.sh"
# shellcheck source=../lib/assayer-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/assayer-project-key.sh"
# shellcheck source=../lib/assayer-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/assayer-ulid.sh"
# shellcheck source=../lib/assayer-transcript.sh
source "${PLUGIN_ROOT}/scripts/lib/assayer-transcript.sh"
# shellcheck source=../lib/assayer-extract.sh
source "${PLUGIN_ROOT}/scripts/lib/assayer-extract.sh"
# shellcheck source=../lib/assayer-verify.sh
source "${PLUGIN_ROOT}/scripts/lib/assayer-verify.sh"
# shellcheck source=../lib/assayer-events.sh
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" source "${PLUGIN_ROOT}/scripts/lib/assayer-events.sh"

INPUT=$(cat)
hook_health_context "$INPUT"
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""
[[ -z "$TRANSCRIPT_PATH" ]] && TRANSCRIPT_PATH="${CLAUDE_TRANSCRIPT_PATH:-}"

export _HOOK_SESSION_ID="${SESSION_ID:-unknown}"

_done() { exit 0; }

# ---------------------------------------------------------------------------
# Config + prerequisites
# ---------------------------------------------------------------------------

REPO_ROOT=$(assayer_project_repo_root "$CWD")
[[ -z "$REPO_ROOT" ]] && _done

CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" assayer_config_load "$REPO_ROOT"

PROJECT_KEY=$(assayer_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && _done

command -v claude >/dev/null 2>&1 || _done
command -v jq >/dev/null 2>&1 || _done

[[ -f "$TRANSCRIPT_PATH" ]] || _done

# ---------------------------------------------------------------------------
# Read transcript: final message + command evidence
# ---------------------------------------------------------------------------

FINAL_MESSAGE_CHARS=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" assayer_config_final_message_chars)
FINAL_MESSAGE=$(assayer_final_assistant_message "$TRANSCRIPT_PATH" "$FINAL_MESSAGE_CHARS")
[[ -z "$FINAL_MESSAGE" ]] && _done

# Bail before the extraction call on a message that asserts nothing. 346 of the
# first 449 audits (77%) came back with zero claims, and the only gate until
# now was "is the message empty" (ecosystem-449.24). Placed ahead of
# assayer_collect_commands so a skipped turn also avoids that transcript scan.
#
# Skipping is silent, like every other bail-out above it: no audit ran, so
# claiming one did with a synthesized nothing_to_verify event would put
# fabricated rows in front of counsel's weekly synthesis.
assayer_may_contain_claims "$FINAL_MESSAGE" || _done

COMMANDS=$(assayer_collect_commands "$TRANSCRIPT_PATH")
COMMAND_COUNT=$(printf '%s' "$COMMANDS" | jq 'length' 2>/dev/null) || COMMAND_COUNT=0

# ---------------------------------------------------------------------------
# Snapshot and hand off
# ---------------------------------------------------------------------------
#
# Everything below this line used to run inline, including a `timeout 60
# claude -p` (ecosystem-449.24). Nothing waits on the result: the audit file
# has no reader, and the assayer.* events are consumed by counsel's weekly
# synthesis, which does not care which turn they arrive on.
#
# The child gets a frozen copy rather than transcript_path. The transcript
# keeps growing after Stop returns, so a child that re-read it would extract a
# LATER turn's final message and file those claims against this turn. Freezing
# costs the 135ms already spent above.
SNAPSHOT=$(mktemp -t assayer-snapshot.XXXXXX 2>/dev/null) || _done
jq -n \
	--arg final_message "$FINAL_MESSAGE" \
	--argjson commands "${COMMANDS:-[]}" \
	--arg project_key "$PROJECT_KEY" \
	--arg session_id "${SESSION_ID:-unknown}" \
	--arg repo_root "$REPO_ROOT" \
	'{final_message: $final_message, commands: $commands, project_key: $project_key,
	  session_id: $session_id, repo_root: $repo_root}' \
	>"$SNAPSHOT" 2>/dev/null || { rm -f "$SNAPSHOT"; _done; }

# Let the child reuse this hook's resolution instead of re-deriving it.
[[ -n "$_ECOSYSTEM_ROOT" ]] && export ONLOOKER_ECOSYSTEM_ROOT="$_ECOSYSTEM_ROOT"

AUDIT="${PLUGIN_ROOT}/scripts/assayer-audit.sh"
if [[ -x "$AUDIT" ]]; then
	# setsid detaches from the controlling terminal so ending the session does
	# not SIGHUP the audit mid-flight; nohup alone on macOS, where setsid needs
	# coreutils. Same shape as counsel's ecosystem-449.19 and cartographer's
	# ADR-001.
	if command -v setsid >/dev/null 2>&1; then
		nohup setsid "$AUDIT" "$SNAPSHOT" >/dev/null 2>&1 &
	else
		nohup "$AUDIT" "$SNAPSHOT" >/dev/null 2>&1 &
	fi
	disown 2>/dev/null || true
else
	rm -f "$SNAPSHOT"
fi

_done
