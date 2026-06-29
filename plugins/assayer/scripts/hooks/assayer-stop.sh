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
#   - Errors from `claude -p` are swallowed; worst case is no audit written.

set -uo pipefail

# Recursion guard — must be first.
[[ "${ASSAYER_NESTED:-}" == "1" ]] && exit 0
export ASSAYER_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Resolve the ecosystem root (sibling to this plugin's parent).
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

COMMANDS=$(assayer_collect_commands "$TRANSCRIPT_PATH")
COMMAND_COUNT=$(printf '%s' "$COMMANDS" | jq 'length' 2>/dev/null) || COMMAND_COUNT=0

# ---------------------------------------------------------------------------
# Extract claims via claude -p
# ---------------------------------------------------------------------------

MAX_CLAIMS=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" assayer_config_max_claims)
MIN_CONFIDENCE=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" assayer_config_min_confidence)
EVAL_MODEL=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" assayer_config_model)
TIMEOUT_SECS=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" assayer_config_timeout)

PROMPT_FILE=$(mktemp -t assayer-prompt.XXXXXX 2>/dev/null) || PROMPT_FILE="/tmp/assayer-prompt.$$"
trap 'rm -f "$PROMPT_FILE"' EXIT
assayer_build_extraction_prompt "$FINAL_MESSAGE" "$MAX_CLAIMS" >"$PROMPT_FILE"

CLAUDE_ARGS=(-p --max-turns 1)
[[ -n "$EVAL_MODEL" ]] && CLAUDE_ARGS+=(--model "$EVAL_MODEL")

RESPONSE=""
if command -v timeout >/dev/null 2>&1; then
	RESPONSE=$(timeout "$TIMEOUT_SECS" claude "${CLAUDE_ARGS[@]}" <"$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
elif command -v gtimeout >/dev/null 2>&1; then
	RESPONSE=$(gtimeout "$TIMEOUT_SECS" claude "${CLAUDE_ARGS[@]}" <"$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
else
	RESPONSE=$(claude "${CLAUDE_ARGS[@]}" <"$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
fi
[[ -z "$RESPONSE" ]] && _done

CLAIMS=$(assayer_parse_claims "$RESPONSE")
CLAIM_COUNT=$(printf '%s' "$CLAIMS" | jq 'length' 2>/dev/null) || CLAIM_COUNT=0

# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------

AUDIT_ID=$(assayer_ulid)
AUDIT_START=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)

started_payload=$(jq -n \
	--arg audit_id "$AUDIT_ID" \
	--argjson claim_count "$CLAIM_COUNT" \
	--arg trigger "stop" \
	--argjson command_count "${COMMAND_COUNT:-0}" \
	'{audit_id: $audit_id, claim_count: $claim_count, trigger: $trigger, command_count: $command_count}')
assayer_emit_event "assayer.audit.started" "$started_payload" || true

ONLOOKER_BASE="${ONLOOKER_DIR:-$HOME/.onlooker}"
ASSAYER_DIR="${ONLOOKER_BASE}/assayer/${PROJECT_KEY}"
mkdir -p "$ASSAYER_DIR" 2>/dev/null || true

count_corroborated=0
count_contradicted=0
count_unverified=0
checked_claims="[]"

while IFS= read -r claim; do
	[[ -z "$claim" ]] && continue

	# Confidence floor — skip low-confidence extractions. Compare with awk via
	# -v bindings (not string-interpolated into code), so an LLM- or
	# config-supplied value is treated as a number and a non-numeric value
	# degrades to 0 instead of executing as code.
	conf=$(printf '%s' "$claim" | jq -r '.confidence // 0.6' 2>/dev/null) || conf="0.6"
	if awk -v a="$conf" -v b="$MIN_CONFIDENCE" 'BEGIN { exit !(a >= b) }' 2>/dev/null; then
		keep=1
	else
		keep=0
	fi
	[[ "$keep" != "1" ]] && continue

	claim_text=$(printf '%s' "$claim" | jq -r '.text // ""' 2>/dev/null) || claim_text=""
	claim_type=$(printf '%s' "$claim" | jq -r '.type // "generic"' 2>/dev/null) || claim_type="generic"
	[[ -z "$claim_text" ]] && continue

	verdict_obj=$(assayer_classify_claim "$claim" "$COMMANDS")
	verdict=$(printf '%s' "$verdict_obj" | jq -r '.verdict // "unverified"' 2>/dev/null) || verdict="unverified"

	case "$verdict" in
	contradicted)
		count_contradicted=$((count_contradicted + 1))
		evidence_command=$(printf '%s' "$verdict_obj" | jq -r '.evidence_command // ""' 2>/dev/null) || evidence_command=""
		excerpt=$(printf '%s' "$verdict_obj" | jq -r '.excerpt // ""' 2>/dev/null) || excerpt=""
		contradicted_payload=$(jq -n \
			--arg audit_id "$AUDIT_ID" \
			--arg claim "$claim_text" \
			--arg claim_type "$claim_type" \
			--arg evidence_command "$evidence_command" \
			--arg result_excerpt "$excerpt" \
			--argjson confidence "$conf" \
			'{audit_id: $audit_id, claim: $claim, claim_type: $claim_type,
			  evidence_command: $evidence_command, result_excerpt: $result_excerpt,
			  confidence: $confidence}')
		assayer_emit_event "assayer.claim.contradicted" "$contradicted_payload" || true
		;;
	corroborated)
		count_corroborated=$((count_corroborated + 1))
		;;
	*)
		count_unverified=$((count_unverified + 1))
		reason=$(printf '%s' "$verdict_obj" | jq -r '.reason // "no_evidence"' 2>/dev/null) || reason="no_evidence"
		unverified_payload=$(jq -n \
			--arg audit_id "$AUDIT_ID" \
			--arg claim "$claim_text" \
			--arg claim_type "$claim_type" \
			--arg reason "$reason" \
			'{audit_id: $audit_id, claim: $claim, claim_type: $claim_type, reason: $reason}')
		assayer_emit_event "assayer.claim.unverified" "$unverified_payload" || true
		;;
	esac

	checked_claims=$(printf '%s' "$checked_claims" | jq -c \
		--arg text "$claim_text" \
		--arg verdict "$verdict" \
		'. + [{text: $text, verdict: $verdict}]' 2>/dev/null) || true
done < <(printf '%s' "$CLAIMS" | jq -c '.[]' 2>/dev/null)

# ---------------------------------------------------------------------------
# Audit summary
# ---------------------------------------------------------------------------

AUDIT_END=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
DURATION_MS=$((AUDIT_END - AUDIT_START))
[[ "$DURATION_MS" -lt 0 ]] && DURATION_MS=0

VERDICT=$(assayer_audit_verdict "$count_contradicted" "$count_corroborated" "$count_unverified")

complete_payload=$(jq -n \
	--arg audit_id "$AUDIT_ID" \
	--argjson claim_count "$CLAIM_COUNT" \
	--argjson corroborated "$count_corroborated" \
	--argjson contradicted "$count_contradicted" \
	--argjson unverified "$count_unverified" \
	--arg verdict "$VERDICT" \
	--argjson duration_ms "$DURATION_MS" \
	'{audit_id: $audit_id, claim_count: $claim_count,
	  corroborated: $corroborated, contradicted: $contradicted,
	  unverified: $unverified, verdict: $verdict, duration_ms: $duration_ms}')
assayer_emit_event "assayer.audit.complete" "$complete_payload" || true

# Advisory file for review in the next session.
SAFE_SESSION_ID=$(printf '%s' "${SESSION_ID:-unknown}" | tr -c 'a-zA-Z0-9-' '_')
jq -n \
	--arg audit_id "$AUDIT_ID" \
	--arg session_id "${SESSION_ID:-unknown}" \
	--argjson claim_count "$CLAIM_COUNT" \
	--argjson corroborated "$count_corroborated" \
	--argjson contradicted "$count_contradicted" \
	--argjson unverified "$count_unverified" \
	--arg verdict "$VERDICT" \
	--argjson claims "$checked_claims" \
	'{audit_id: $audit_id, session_id: $session_id, claim_count: $claim_count,
	  corroborated: $corroborated, contradicted: $contradicted,
	  unverified: $unverified, verdict: $verdict, claims: $claims}' \
	>"${ASSAYER_DIR}/audit-${SAFE_SESSION_ID}.json" 2>/dev/null || true

_done
