#!/usr/bin/env bash
# Tribunal Stop-gate hook.
#
# Triggered by Stop. Off by default — gated on tribunal.stop_hook.enabled in
# config. When enabled, runs a single-judge advisory pass on the just-finished
# session's last turn and writes a verdict for review on the next session.
#
# Why advisory only: by the time Stop fires the main agent loop has already
# ended. We cannot retry the Actor or re-run the work. The hook records what
# the Standard Judge would have said so a human (or a follow-up SessionStart
# hook in v0.2) can see whether the turn would have passed the gate.
#
# Hook contract:
#   - Always exits 0. Never blocks Stop.
#   - Skips silently if disabled, no git context, no transcript, or skip_if_no_file_changes
#     is true and the last turn did not modify files.
#   - Errors from `claude -p` are swallowed; worst case is "no verdict for this stop".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Ecosystem substrate lives in the sibling ecosystem plugin. Same lookup as
# archivist-extract.sh.
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

# shellcheck source=../lib/tribunal-config.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-config.sh"
# shellcheck source=../lib/tribunal-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-project-key.sh"
# shellcheck source=../lib/tribunal-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-ulid.sh"
# shellcheck source=../lib/tribunal-events.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-events.sh"
# shellcheck source=../lib/tribunal-verdict.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-verdict.sh"

INPUT=$(cat)

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""

# Stop hook MUST NOT emit any stdout besides the optional `{continue: ...}`
# acknowledgement. Exiting 0 with no output is the safe path.
_done() {
	exit 0
}

REPO_ROOT=$(tribunal_project_repo_root "$CWD")
tribunal_config_load "$REPO_ROOT"

if ! tribunal_config_stop_hook_enabled; then
	_done
fi

PROJECT_KEY=$(tribunal_project_key "$CWD")
if [[ -z "$PROJECT_KEY" || -z "$REPO_ROOT" ]]; then
	_done
fi

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
	_done
fi

# Skip if no files were modified since the last commit AND the user enabled
# skip_if_no_file_changes (default true).
SKIP_IF_CLEAN=$(tribunal_config_get '.tribunal.stop_hook.skip_if_no_file_changes')
if [[ "$SKIP_IF_CLEAN" == "true" ]]; then
	if git -C "$REPO_ROOT" diff --quiet 2>/dev/null && git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
		_done
	fi
fi

if ! command -v claude >/dev/null 2>&1; then
	_done
fi

# ----------------------------------------------------------------------------
# Build the advisory-judge prompt.
# ----------------------------------------------------------------------------

JUDGE_MODEL=$(tribunal_config_judge_model "standard")
[[ -z "$JUDGE_MODEL" || "$JUDGE_MODEL" == "null" ]] && JUDGE_MODEL=""

TRANSCRIPT_TAIL=$(tail -c 30000 "$TRANSCRIPT_PATH" 2>/dev/null) || TRANSCRIPT_TAIL=""
[[ -z "$TRANSCRIPT_TAIL" ]] && _done

DIFF_SUMMARY=$(git -C "$REPO_ROOT" diff --stat 2>/dev/null | tail -c 4000) || DIFF_SUMMARY=""

PROMPT_FILE=$(mktemp -t tribunal-stop-prompt.XXXXXX 2>/dev/null) || PROMPT_FILE="/tmp/tribunal-stop-prompt.$$"
trap 'rm -f "$PROMPT_FILE"' EXIT

{
	printf '%s\n' 'You are a Tribunal Standard Judge performing an advisory pass on a just-finished Claude Code turn. Return JSON only — no prose, no markdown fences.'
	printf '\n'
	printf '%s\n' 'Output schema (TribunalVerdictPayload, exactly these keys):'
	printf '%s\n' '{'
	printf '%s\n' '  "score": 0.0..1.0,'
	printf '%s\n' '  "passed": true|false,'
	printf '%s\n' '  "judge_type": "standard",'
	printf '%s\n' '  "feedback_summary": "1-3 sentences naming the highest-leverage concern, if any.",'
	printf '%s\n' '  "confidence": 0.0..1.0'
	printf '%s\n' '}'
	printf '\n'
	printf '%s\n' 'Score the work the assistant performed in this turn against general correctness, completeness, and clarity. A score >= 0.75 is "passed".'
	printf '%s\n' 'This is advisory — the main session has already ended, no retry will happen. Be concise.'
	printf '\n'
	if [[ -n "$DIFF_SUMMARY" ]]; then
		printf '%s\n' '---WORKING-TREE DIFF STAT---'
		printf '%s\n' "$DIFF_SUMMARY"
		printf '%s\n' '---END DIFF STAT---'
		printf '\n'
	fi
	printf '%s\n' '---TRANSCRIPT TAIL---'
	printf '%s\n' "$TRANSCRIPT_TAIL"
	printf '%s\n' '---END TRANSCRIPT TAIL---'
} > "$PROMPT_FILE"

CLAUDE_ARGS=(-p --max-turns 1)
[[ -n "$JUDGE_MODEL" ]] && CLAUDE_ARGS+=(--model "$JUDGE_MODEL")

RESPONSE=""
if command -v timeout >/dev/null 2>&1; then
	RESPONSE=$(timeout 60 claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
elif command -v gtimeout >/dev/null 2>&1; then
	RESPONSE=$(gtimeout 60 claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
else
	RESPONSE=$(claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
fi

[[ -z "$RESPONSE" ]] && _done

CLEAN_RESPONSE=$(printf '%s' "$RESPONSE" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
if ! printf '%s' "$CLEAN_RESPONSE" | jq -e '.score and (.passed // false | type == "boolean") and .judge_type' >/dev/null 2>&1; then
	_done
fi

# ----------------------------------------------------------------------------
# Emit the canonical event chain + persist the advisory verdict.
# ----------------------------------------------------------------------------

TASK_ID=$(tribunal_ulid)
ITERATION_ID=$(tribunal_ulid)
JUDGE_ID=$(tribunal_ulid)
SCORE_THRESHOLD=$(tribunal_config_get '.tribunal.session.score_threshold')
[[ -z "$SCORE_THRESHOLD" ]] && SCORE_THRESHOLD="0.75"

START_PAYLOAD=$(jq -n \
	--arg task_id "$TASK_ID" \
	--arg model "$JUDGE_MODEL" \
	--argjson thr "$SCORE_THRESHOLD" \
	'{
		task_id: $task_id,
		judge_types: ["standard"],
		gate_policy: "strict",
		score_threshold: $thr,
		max_iterations: 1,
		judge_model_ids: [$model]
	} | with_entries(select(.value != null and .value != ""))')

ITER_PAYLOAD=$(jq -n \
	--arg task_id "$TASK_ID" \
	--arg iter_id "$ITERATION_ID" \
	'{task_id: $task_id, iteration_id: $iter_id, iteration_number: 0, trigger: "initial"}')

JUDGE_START_PAYLOAD=$(jq -n \
	--arg task_id "$TASK_ID" \
	--arg iter_id "$ITERATION_ID" \
	--arg judge_id "$JUDGE_ID" \
	--arg model "$JUDGE_MODEL" \
	'{
		task_id: $task_id,
		iteration_id: $iter_id,
		judge_id: $judge_id,
		judge_type: "standard",
		judge_model_id: (if $model == "" then null else $model end)
	} | with_entries(select(.value != null))')

VERDICT_PAYLOAD=$(printf '%s' "$CLEAN_RESPONSE" | jq -c \
	--arg task_id "$TASK_ID" \
	--arg iter_id "$ITERATION_ID" \
	--arg judge_id "$JUDGE_ID" \
	--arg model "$JUDGE_MODEL" \
	'{
		task_id: $task_id,
		score: .score,
		passed: (.passed // (.score >= 0.75)),
		judge_type: "standard",
		iteration_id: $iter_id,
		judge_id: $judge_id,
		feedback_summary: (.feedback_summary // ""),
		confidence: (.confidence // 0.6),
		judge_model_id: (if $model == "" then null else $model end)
	} | with_entries(select(.value != null and .value != ""))')

SCORE=$(printf '%s' "$VERDICT_PAYLOAD" | jq -r '.score')
PASSED=$(printf '%s' "$VERDICT_PAYLOAD" | jq -r '.passed')

if [[ "$PASSED" == "true" ]]; then
	GATE_PAYLOAD=$(jq -n \
		--arg task_id "$TASK_ID" \
		--arg iter_id "$ITERATION_ID" \
		--argjson score "$SCORE" \
		'{task_id: $task_id, iteration_id: $iter_id, final_score: $score, iteration_number: 0, judges_consulted: 1}')
	GATE_EVENT="tribunal.gate.passed"
	OUTCOME="accepted"
else
	GATE_PAYLOAD=$(jq -n \
		--arg task_id "$TASK_ID" \
		--arg iter_id "$ITERATION_ID" \
		--argjson score "$SCORE" \
		'{task_id: $task_id, iteration_id: $iter_id, reason: "low_score", final_score: $score, iteration_number: 0, will_retry: false}')
	GATE_EVENT="tribunal.gate.blocked"
	OUTCOME="rejected"
fi

COMPLETE_PAYLOAD=$(jq -n \
	--arg task_id "$TASK_ID" \
	--arg outcome "$OUTCOME" \
	--argjson score "$SCORE" \
	'{task_id: $task_id, outcome: $outcome, final_score: $score, iterations_used: 1}')

# Emit in canonical order. Each call is best-effort — a single schema failure
# should not break the user's Stop.
tribunal_emit_event "tribunal.session.start"     "$START_PAYLOAD"        || true
tribunal_emit_event "tribunal.iteration.start"   "$ITER_PAYLOAD"         || true
tribunal_emit_event "tribunal.judge.start"       "$JUDGE_START_PAYLOAD"  || true
tribunal_emit_event "tribunal.verdict"           "$VERDICT_PAYLOAD"      || true
tribunal_emit_event "$GATE_EVENT"                "$GATE_PAYLOAD"         || true
tribunal_emit_event "tribunal.session.complete"  "$COMPLETE_PAYLOAD"     || true

# Persist a single advisory file for the next session to surface.
STOP_DIR="$(tribunal_project_dir "$PROJECT_KEY")"
mkdir -p "$STOP_DIR" 2>/dev/null || _done
SAFE_SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9-' '_')
[[ -z "$SAFE_SESSION_ID" ]] && SAFE_SESSION_ID="unknown"

jq -n \
	--arg task_id "$TASK_ID" \
	--arg session_id "$SESSION_ID" \
	--arg outcome "$OUTCOME" \
	--argjson verdict "$VERDICT_PAYLOAD" \
	'{
		task_id: $task_id,
		session_id: $session_id,
		outcome: $outcome,
		verdict: $verdict,
		mode: "stop-advisory"
	}' > "${STOP_DIR}/stop-${SAFE_SESSION_ID}.json" 2>/dev/null || true

_done
