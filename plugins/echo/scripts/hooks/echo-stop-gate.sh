#!/usr/bin/env bash
# Echo Stop-gate hook.
#
# Triggered by Stop. Off by default — gated on echo.enabled in config.
# When enabled, detects which watched agent files changed in this session,
# runs a single-judge advisory pass on each, and compares the score against a
# stored baseline to report improved / degraded / neutral.
#
# Hook contract:
#   - Always exits 0. Never blocks Stop.
#   - Skips silently if disabled, no git context, or no watched files changed.
#   - Recursion guard: exits immediately if ECHO_NESTED=1 to prevent a claude -p
#     subprocess from re-triggering this hook on its own Writes.
#   - Errors from `claude -p` are swallowed; worst case is no verdict written.

set -uo pipefail

# Recursion guard — must be first.
[[ "${ECHO_NESTED:-}" == "1" ]] && exit 0
export ECHO_NESTED=1

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

# shellcheck source=../lib/echo-config.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-config.sh"
# shellcheck source=../lib/echo-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-project-key.sh"
# shellcheck source=../lib/echo-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-ulid.sh"
# shellcheck source=../lib/echo-events.sh
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" source "${PLUGIN_ROOT}/scripts/lib/echo-events.sh"

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""

_done() { exit 0; }

# ---------------------------------------------------------------------------
# Config + prerequisites
# ---------------------------------------------------------------------------

REPO_ROOT=$(echo_project_repo_root "$CWD")
[[ -z "$REPO_ROOT" ]] && _done

CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$REPO_ROOT"
echo_config_enabled || _done

PROJECT_KEY=$(echo_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && _done

command -v claude >/dev/null 2>&1 || _done
command -v jq >/dev/null 2>&1 || _done

# ---------------------------------------------------------------------------
# Identify changed agent files
# ---------------------------------------------------------------------------

# Files changed vs HEAD (unstaged + staged + untracked-that-are-watched).
# Using diff-index to catch both staged and unstaged changes.
CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null) || CHANGED_FILES=""
# Also catch staged-only changes.
STAGED_FILES=$(git -C "$REPO_ROOT" diff --name-only --cached 2>/dev/null) || STAGED_FILES=""
ALL_CHANGED=$(printf '%s\n%s' "$CHANGED_FILES" "$STAGED_FILES" | sort -u | grep -v '^$') || ALL_CHANGED=""
[[ -z "$ALL_CHANGED" ]] && _done

# Load watch and exclude patterns.
mapfile -t WATCH_PATTERNS < <(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_watch_paths)
mapfile -t EXCLUDE_PATTERNS < <(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_exclude_paths)

# Filter changed files: must match at least one watch pattern AND no exclude pattern.
WATCHED_CHANGED=()
while IFS= read -r f; do
	[[ -z "$f" ]] && continue

	local_match=0
	for pat in "${WATCH_PATTERNS[@]}"; do
		# shellcheck disable=SC2053
		if [[ "$f" == $pat ]]; then
			local_match=1
			break
		fi
	done
	[[ "$local_match" -eq 0 ]] && continue

	excluded=0
	for pat in "${EXCLUDE_PATTERNS[@]}"; do
		# shellcheck disable=SC2053
		if [[ "$f" == $pat ]]; then
			excluded=1
			break
		fi
	done
	[[ "$excluded" -eq 1 ]] && continue

	WATCHED_CHANGED+=("$f")
done <<< "$ALL_CHANGED"

[[ "${#WATCHED_CHANGED[@]}" -eq 0 ]] && _done

# ---------------------------------------------------------------------------
# Storage paths
# ---------------------------------------------------------------------------

ONLOOKER_BASE="${ONLOOKER_DIR:-$HOME/.onlooker}"
ECHO_DIR="${ONLOOKER_BASE}/echo/${PROJECT_KEY}"
BASELINE_DIR="${ECHO_DIR}/baselines"
mkdir -p "$BASELINE_DIR" 2>/dev/null || _done

# ---------------------------------------------------------------------------
# Evaluation loop
# ---------------------------------------------------------------------------

EVAL_MODEL=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_model)
TIMEOUT_SECS=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_timeout)
DRIFT_THRESHOLD=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_drift_threshold)

SUITE_ID=$(echo_ulid)
SUITE_START=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)

PROMPT_FILE=$(mktemp -t echo-prompt.XXXXXX 2>/dev/null) || PROMPT_FILE="/tmp/echo-prompt.$$"
trap 'rm -f "$PROMPT_FILE"' EXIT

count_improved=0
count_degraded=0
count_neutral=0
sum_before=0
sum_after=0
file_count=0

for rel_path in "${WATCHED_CHANGED[@]}"; do
	abs_path="${REPO_ROOT}/${rel_path}"
	[[ ! -f "$abs_path" ]] && continue

	FILE_CONTENT=$(cat "$abs_path" 2>/dev/null) || continue
	[[ -z "$FILE_CONTENT" ]] && continue

	TEST_ID=$(echo_test_id_for_path "$rel_path")
	BASELINE_FILE="${BASELINE_DIR}/${TEST_ID}.json"

	# Build the evaluation prompt.
	{
		printf '%s\n' 'You are evaluating an agent prompt file for quality. Return JSON only — no prose, no markdown fences.'
		printf '\n'
		printf '%s\n' 'Output schema (exactly these keys):'
		printf '%s\n' '{'
		printf '%s\n' '  "score": 0.0..1.0,'
		printf '%s\n' '  "passed": true|false,'
		printf '%s\n' '  "confidence": 0.0..1.0,'
		printf '%s\n' '  "feedback": "1-2 sentences on the highest-leverage issue, if any."'
		printf '%s\n' '}'
		printf '\n'
		printf '%s\n' 'Score on these criteria (equal weight):'
		printf '%s\n' '  - Role clarity: does the file clearly define what the agent is and what it must do?'
		printf '%s\n' '  - Output format: are output format and schema requirements unambiguous?'
		printf '%s\n' '  - Criterion coverage: are all evaluation dimensions specified with enough detail to apply consistently?'
		printf '%s\n' '  - Internal consistency: no contradictory instructions, no undefined terms.'
		printf '\n'
		printf '%s\n' "A score >= 0.7 is \"passed\". Be concise."
		printf '\n'
		printf '%s\n' "---FILE: ${rel_path}---"
		printf '%s\n' "$FILE_CONTENT"
		printf '%s\n' '---END FILE---'
	} > "$PROMPT_FILE"

	CLAUDE_ARGS=(-p --max-turns 1)
	[[ -n "$EVAL_MODEL" ]] && CLAUDE_ARGS+=(--model "$EVAL_MODEL")

	RESPONSE=""
	if command -v timeout >/dev/null 2>&1; then
		RESPONSE=$(timeout "$TIMEOUT_SECS" claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
	elif command -v gtimeout >/dev/null 2>&1; then
		RESPONSE=$(gtimeout "$TIMEOUT_SECS" claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
	else
		RESPONSE=$(claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
	fi

	[[ -z "$RESPONSE" ]] && continue

	CLEAN=$(printf '%s' "$RESPONSE" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
	SCORE_AFTER=$(printf '%s' "$CLEAN" | jq -r '.score // empty' 2>/dev/null) || SCORE_AFTER=""
	CONFIDENCE=$(printf '%s' "$CLEAN" | jq -r '.confidence // "0.6"' 2>/dev/null) || CONFIDENCE="0.6"
	[[ -z "$SCORE_AFTER" ]] && continue

	SCORE_BEFORE=""
	if [[ -f "$BASELINE_FILE" ]]; then
		SCORE_BEFORE=$(jq -r '.score // empty' "$BASELINE_FILE" 2>/dev/null) || SCORE_BEFORE=""
	fi

	# Persist new baseline.
	jq -n \
		--arg path "$rel_path" \
		--arg test_id "$TEST_ID" \
		--argjson score "$SCORE_AFTER" \
		--arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
		'{path: $path, test_id: $test_id, score: $score, recorded_at: $ts}' \
		> "$BASELINE_FILE" 2>/dev/null || true

	file_count=$((file_count + 1))
	sum_after=$(python3 -c "print($sum_after + $SCORE_AFTER)" 2>/dev/null) || sum_after=$sum_after

	if [[ -n "$SCORE_BEFORE" ]]; then
		DELTA=$(python3 -c "print(round($SCORE_AFTER - $SCORE_BEFORE, 4))" 2>/dev/null) || DELTA="0"
		sum_before=$(python3 -c "print($sum_before + $SCORE_BEFORE)" 2>/dev/null) || sum_before=$sum_before

		ABS_DELTA=$(python3 -c "print(abs($DELTA))" 2>/dev/null) || ABS_DELTA="0"
		IS_IMPROVED=$(python3 -c "print('true' if $DELTA > $DRIFT_THRESHOLD else 'false')" 2>/dev/null) || IS_IMPROVED="false"
		IS_DEGRADED=$(python3 -c "print('true' if $DELTA < -$DRIFT_THRESHOLD else 'false')" 2>/dev/null) || IS_DEGRADED="false"

		FILE_NAME=$(basename "$rel_path")

		if [[ "$IS_IMPROVED" == "true" ]]; then
			count_improved=$((count_improved + 1))
			improvement_payload=$(jq -n \
				--arg suite_id "$SUITE_ID" \
				--arg test_id "$TEST_ID" \
				--arg test_name "$FILE_NAME" \
				--argjson score_before "$SCORE_BEFORE" \
				--argjson score_after "$SCORE_AFTER" \
				--argjson delta "$DELTA" \
				--argjson confidence "$CONFIDENCE" \
				'{suite_id: $suite_id, test_id: $test_id, test_name: $test_name,
				  score_before: $score_before, score_after: $score_after,
				  delta: $delta, confidence: $confidence}')
			echo_emit_event "echo.improvement.detected" "$improvement_payload" || true

		elif [[ "$IS_DEGRADED" == "true" ]]; then
			count_degraded=$((count_degraded + 1))
			regression_payload=$(jq -n \
				--arg suite_id "$SUITE_ID" \
				--arg test_id "$TEST_ID" \
				--arg test_name "$FILE_NAME" \
				--argjson score_before "$SCORE_BEFORE" \
				--argjson score_after "$SCORE_AFTER" \
				--argjson delta "$DELTA" \
				--argjson confidence "$CONFIDENCE" \
				'{suite_id: $suite_id, test_id: $test_id, test_name: $test_name,
				  score_before: $score_before, score_after: $score_after,
				  delta: $delta, confidence: $confidence}')
			echo_emit_event "echo.regression.detected" "$regression_payload" || true
		else
			count_neutral=$((count_neutral + 1))
		fi
	else
		# First evaluation for this file — no baseline to compare against yet.
		count_neutral=$((count_neutral + 1))
	fi
done

[[ "$file_count" -eq 0 ]] && _done

# ---------------------------------------------------------------------------
# Emit suite events
# ---------------------------------------------------------------------------

FIRST_CHANGED="${WATCHED_CHANGED[0]}"

suite_started_payload=$(jq -n \
	--arg suite_id "$SUITE_ID" \
	--argjson test_count "$file_count" \
	--arg trigger "file_change" \
	--arg changed_file "$FIRST_CHANGED" \
	'{suite_id: $suite_id, test_count: $test_count, trigger: $trigger, changed_file: $changed_file}')
echo_emit_event "echo.suite.started" "$suite_started_payload" || true

SUITE_END=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
DURATION_MS=$(( SUITE_END - SUITE_START ))

MERGE_RECOMMENDED="false"
[[ "$count_degraded" -eq 0 && "$count_improved" -gt 0 ]] && MERGE_RECOMMENDED="true"
[[ "$count_degraded" -eq 0 && "$count_improved" -eq 0 ]] && MERGE_RECOMMENDED="true"

if [[ "$file_count" -gt 0 && -n "$sum_before" ]] && python3 -c "exit(0 if $sum_before > 0 else 1)" 2>/dev/null; then
	BASELINE_AVG=$(python3 -c "print(round($sum_before / $file_count, 4))" 2>/dev/null) || BASELINE_AVG=""
	AFTER_AVG=$(python3 -c "print(round($sum_after / $file_count, 4))" 2>/dev/null) || AFTER_AVG=""
	DRIFT=$(python3 -c "print(round($sum_after / $file_count - $sum_before / $file_count, 4))" 2>/dev/null) || DRIFT=""

	if [[ -n "$BASELINE_AVG" && -n "$AFTER_AVG" && -n "$DRIFT" ]]; then
		suite_complete_payload=$(jq -n \
			--arg suite_id "$SUITE_ID" \
			--argjson test_count "$file_count" \
			--argjson improved "$count_improved" \
			--argjson degraded "$count_degraded" \
			--argjson neutral "$count_neutral" \
			--argjson merge_recommended "$MERGE_RECOMMENDED" \
			--argjson duration_ms "$DURATION_MS" \
			--argjson baseline_score "$BASELINE_AVG" \
			--argjson score_after "$AFTER_AVG" \
			--argjson drift "$DRIFT" \
			--argjson drift_threshold "$DRIFT_THRESHOLD" \
			'{suite_id: $suite_id, test_count: $test_count,
			  improved: $improved, degraded: $degraded, neutral: $neutral,
			  merge_recommended: $merge_recommended, duration_ms: $duration_ms,
			  baseline_score: $baseline_score, score_after: $score_after,
			  drift: $drift, drift_threshold: $drift_threshold}')
	else
		suite_complete_payload=$(jq -n \
			--arg suite_id "$SUITE_ID" \
			--argjson test_count "$file_count" \
			--argjson improved "$count_improved" \
			--argjson degraded "$count_degraded" \
			--argjson neutral "$count_neutral" \
			--argjson merge_recommended "$MERGE_RECOMMENDED" \
			--argjson duration_ms "$DURATION_MS" \
			'{suite_id: $suite_id, test_count: $test_count,
			  improved: $improved, degraded: $degraded, neutral: $neutral,
			  merge_recommended: $merge_recommended, duration_ms: $duration_ms}')
	fi
else
	suite_complete_payload=$(jq -n \
		--arg suite_id "$SUITE_ID" \
		--argjson test_count "$file_count" \
		--argjson improved "$count_improved" \
		--argjson degraded "$count_degraded" \
		--argjson neutral "$count_neutral" \
		--argjson merge_recommended "$MERGE_RECOMMENDED" \
		--argjson duration_ms "$DURATION_MS" \
		'{suite_id: $suite_id, test_count: $test_count,
		  improved: $improved, degraded: $degraded, neutral: $neutral,
		  merge_recommended: $merge_recommended, duration_ms: $duration_ms}')
fi
echo_emit_event "echo.suite.complete" "$suite_complete_payload" || true

# ---------------------------------------------------------------------------
# Write advisory file for review in next session.
# ---------------------------------------------------------------------------

SAFE_SESSION_ID=$(printf '%s' "${SESSION_ID:-unknown}" | tr -c 'a-zA-Z0-9-' '_')

jq -n \
	--arg suite_id "$SUITE_ID" \
	--arg session_id "${SESSION_ID:-unknown}" \
	--argjson test_count "$file_count" \
	--argjson improved "$count_improved" \
	--argjson degraded "$count_degraded" \
	--argjson neutral "$count_neutral" \
	--argjson merge_recommended "$MERGE_RECOMMENDED" \
	--argjson files "$(printf '%s\n' "${WATCHED_CHANGED[@]}" | jq -R . | jq -s .)" \
	'{suite_id: $suite_id, session_id: $session_id, test_count: $test_count,
	  improved: $improved, degraded: $degraded, neutral: $neutral,
	  merge_recommended: $merge_recommended, files: $files}' \
	> "${ECHO_DIR}/run-${SAFE_SESSION_ID}.json" 2>/dev/null || true

_done
