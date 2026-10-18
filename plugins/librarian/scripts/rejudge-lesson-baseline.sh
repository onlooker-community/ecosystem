#!/usr/bin/env bash
# Re-judge the candidates a recorded measurement already produced, with the
# judge prompt as it is NOW, and write a samples.json in the same shape.
#
# measure-lesson-transform.sh answers "how does the transform + jury pipeline
# do". When only the JUDGE side changed, re-running it confounds that change
# with two others: the transform model is not deterministic, and `spread`
# sampling over a corpus that has grown since picks different artifacts. This
# holds the candidates fixed, so the judge prompt is the only variable.
#
# Transform-side records (declines, the proposal rate) are copied through
# unchanged; they are a property of the transform, which did not run.
#
# Makes 2 judge calls per judged candidate and writes nothing to the lesson
# store: judging goes through the pure dispatch/aggregate/gate functions, not
# librarian_lesson_judge, exactly as the harness does.
#
# Usage:
#   rejudge-lesson-baseline.sh <baseline-samples.json> <out-dir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_ROOT}/../.." && pwd)"

BASELINE="${1:-}"
OUT_DIR="${2:-}"
if [[ -z "$BASELINE" || -z "$OUT_DIR" ]]; then
	printf 'usage: rejudge-lesson-baseline.sh <baseline-samples.json> <out-dir>\n' >&2
	exit 1
fi
[[ -f "$BASELINE" ]] || { printf 'no such file: %s\n' "$BASELINE" >&2; exit 1; }

# The harness's list, verbatim. A shorter one sourced fine and judged nothing:
# the judge's JSON extractor lives in librarian-lesson-transform.sh, so every
# verdict parsed as empty.
for lib in onlooker-project-key librarian-ulid librarian-storage \
	librarian-lesson-storage librarian-lesson-validate librarian-config \
	librarian-author-key librarian-lesson-review librarian-lesson-rubric \
	librarian-lesson-judge librarian-lesson-promote librarian-lesson-transform \
	librarian-lesson-auto; do
	# shellcheck disable=SC1090
	source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh" || {
		printf 'cannot source %s\n' "$lib" >&2
		exit 1
	}
done
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" librarian_config_load "$REPO_ROOT"

# The rubric the baseline was scored against, re-read from CONFIG rather than
# from the baseline file: the point is to judge with today's definitions.
RUBRIC_ID=$(jq -r '.rubric.id' "$BASELINE")
RUBRIC=$(librarian_lesson_rubric_get "$RUBRIC_ID") || {
	printf 'rubric %s is not defined in config\n' "$RUBRIC_ID" >&2
	exit 1
}
THRESHOLD=$(printf '%s' "$RUBRIC" | jq -r '.score_threshold')
POLICY=$(printf '%s' "$RUBRIC" | jq -r '.gate_policy')
JUDGE_MODEL=$(jq -r '.judge_model' "$BASELINE")

_sha256() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
	else sha256sum "$1" | cut -d' ' -f1; fi
}
# Same fingerprint as measure-lesson-transform.sh, so the two are comparable.
JUDGE_SHA=$(_sha256 <(cat "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-auto.sh" \
	"${PLUGIN_ROOT}/scripts/lib/librarian-lesson-rubric.sh"
	librarian_lesson_rubric_render_criteria "$RUBRIC"))

mkdir -p "$OUT_DIR" || exit 1
CANDS="${OUT_DIR}/candidates.jsonl"
: > "$CANDS"
panels=0 failed=0

n=$(jq '.candidates | length' "$BASELINE")
judged=$(jq '[.candidates[] | select(.candidate != null)] | length' "$BASELINE")
printf 'rejudging %d of %d candidates (rubric %s, model %s)\n' \
	"$judged" "$n" "$RUBRIC_ID" "$JUDGE_MODEL" >&2

for (( i = 0; i < n; i++ )); do
	row=$(jq -c ".candidates[$i]" "$BASELINE")
	candidate=$(printf '%s' "$row" | jq -c '.candidate')
	if [[ "$candidate" == "null" ]]; then
		printf '%s\n' "$row" >> "$CANDS"
		printf '-' >&2
		continue
	fi

	prompt=$(librarian_lesson_auto_judge_prompt "$candidate" "$RUBRIC")
	std=$(_librarian_lesson_auto_judge tribunal-judge-standard "$prompt" "$JUDGE_MODEL")
	adv=$(_librarian_lesson_auto_judge tribunal-judge-adversarial "$prompt" "$JUDGE_MODEL")

	verdicts='[]' aggregate='null' gate='null'
	panels=$(( panels + 1 ))
	if [[ -n "$std" && -n "$adv" ]]; then
		std=$(printf '%s' "$std" | jq -c 'if (.score | type) == "number" and (.passed | type) == "boolean" then .judge_type = "standard" else empty end' 2>/dev/null) || std=""
		adv=$(printf '%s' "$adv" | jq -c 'if (.score | type) == "number" and (.passed | type) == "boolean" then .judge_type = "adversarial" else empty end' 2>/dev/null) || adv=""
	fi
	if [[ -n "$std" && -n "$adv" ]]; then
		verdicts=$(jq -cn --argjson a "$std" --argjson b "$adv" '[$a, $b]' 2>/dev/null) || verdicts='[]'
		aggregate=$(librarian_lesson_aggregate "$verdicts" "$RUBRIC") || aggregate='null'
		if [[ "$aggregate" != "null" ]]; then
			gate=$(librarian_lesson_gate "$POLICY" "$verdicts" "$aggregate" "$THRESHOLD" "$RUBRIC") || gate='null'
		fi
		printf '.' >&2
	else
		failed=$(( failed + 1 ))
		printf 'x' >&2
	fi

	printf '%s' "$row" | jq -c --argjson v "$verdicts" \
		--argjson agg "${aggregate:-null}" --argjson g "${gate:-null}" \
		'.verdicts = $v | .aggregate = $agg | .gate = $g' >> "$CANDS"
done
printf '\n' >&2

# One empty panel is a flaky judge; every panel empty is a broken instrument,
# and its stats would read as a 0% pass rate rather than as no measurement.
if (( panels > 0 && failed == panels )); then
	printf 'every judge panel returned nothing (%d of %d); no measurement written\n' \
		"$failed" "$panels" >&2
	rm -f "$CANDS"
	exit 1
fi
(( failed > 0 )) && printf 'judge failures: %d of %d panels\n' "$failed" "$panels" >&2

jq --slurpfile c "$CANDS" --argjson rubric "$RUBRIC" --arg sha "$JUDGE_SHA" \
	--arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg from "$BASELINE" \
	'. + {candidates: $c, rubric: $rubric, judge_prompt_sha256: $sha,
	      measured_at: $at, rejudged_from: $from}' \
	"$BASELINE" > "${OUT_DIR}/samples.json" || exit 1
rm -f "$CANDS"

node "${SCRIPT_DIR}/lesson-transform-stats.mjs" "${OUT_DIR}/samples.json" > "${OUT_DIR}/stats.json" || {
	printf 'stats failed; samples kept at %s\n' "${OUT_DIR}/samples.json" >&2
	exit 1
}
printf 'wrote %s/{samples,stats}.json\n' "$OUT_DIR" >&2
