#!/usr/bin/env bash
# Measure echo's judge spread on identical content (ONL-102).
#
# WHY THIS EXISTS. drift_threshold shipped at 0.05, picked rather than measured.
# The judge's spread on identical content was recorded in-tree at 0.13-0.24 --
# larger than the threshold meant to filter it -- but with no methodology
# attached: no sample count, no files, no date, no model. A number nobody can
# re-derive cannot be defended when the prompt or model changes, and both will.
#
# WHAT IT DOES. Scores the same unchanged files N times each and reports the
# distribution of |delta| between independent samples, which is exactly what
# echo compares when it decides drift: a stored single sample against a fresh
# single sample. Reports three arms -- single-sample, median-of-3, median-of-5 --
# so the question "should the threshold be bigger" and the question "should an
# evaluation be more than one sample" get answered from one run.
#
# NOT WIRED INTO npm test, deliberately. A full run costs 30 judge calls; a
# test suite that expensive is one nobody runs. test/bats/echo-measure-judge-
# spread.bats covers the plumbing with a stub, and test/node/judge-spread-
# stats.test.mjs covers the arithmetic exhaustively.
#
# Usage:
#   measure-judge-spread.sh [--samples N] [--out DIR] [--dry-run] [FILE...]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_ROOT}/../.." && pwd)"

# shellcheck source=lib/echo-config.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-config.sh"
# shellcheck source=lib/echo-judge-prompt.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh"

SAMPLES=10
DRY_RUN=0
OUT_DIR=""
FILES=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--samples) SAMPLES="$2"; shift 2 ;;
		--out) OUT_DIR="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
		-*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
		*) FILES+=("$1"); shift ;;
	esac
done

# The three files echo has actually scored in this repo, so the spread is
# measured on the kind of content echo really watches rather than a fixture.
if [[ "${#FILES[@]}" -eq 0 ]]; then
	FILES=(
		"${REPO_ROOT}/plugins/tribunal/agents/tribunal-judge-standard.md"
		"${REPO_ROOT}/plugins/lineage/skills/lineage/SKILL.md"
		"${REPO_ROOT}/.claude/skills/writing-tests/SKILL.md"
	)
fi

for f in "${FILES[@]}"; do
	if [[ ! -f "$f" ]]; then
		printf 'not a readable file: %s\n' "$f" >&2
		exit 1
	fi
done

# Mirrors echo-stop-gate.sh:86 and :264 exactly, CLAUDE_PLUGIN_ROOT included.
# The accessors read it at call time, so a plain echo_config_load leaves every
# value empty and the run would silently measure whatever the DEFAULT model is
# rather than echo's pinned judge -- a measurement that describes nothing.
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$REPO_ROOT"
EVAL_MODEL=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_model)
TIMEOUT_SECS=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_timeout)

TOTAL=$(( SAMPLES * ${#FILES[@]} ))

if [[ "$DRY_RUN" -eq 1 ]]; then
	printf 'would run %d judge calls: %d samples x %d files\n' "$TOTAL" "$SAMPLES" "${#FILES[@]}"
	printf 'model: %s\n' "$EVAL_MODEL"
	for f in "${FILES[@]}"; do printf '  %s\n' "$f"; done
	exit 0
fi

[[ -z "$OUT_DIR" ]] && OUT_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}/echo/spread/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR" || { printf 'cannot create %s\n' "$OUT_DIR" >&2; exit 1; }

# The threshold these numbers produce is a property of ONE prompt scored by ONE
# model. Stamping both is what lets a later reader know whether the measurement
# still applies -- the single thing the 0.13-0.24 figure could not say.
if command -v shasum >/dev/null 2>&1; then
	PROMPT_SHA=$(shasum -a 256 "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh" | cut -d' ' -f1)
else
	PROMPT_SHA=$(sha256sum "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh" | cut -d' ' -f1)
fi

PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

SAMPLES_JSON="${OUT_DIR}/samples.json"
printf '{}' > "${OUT_DIR}/.acc.json"
USABLE=0
ATTEMPTED=0

for f in "${FILES[@]}"; do
	rel="${f#"${REPO_ROOT}/"}"
	content=$(cat "$f" 2>/dev/null) || continue
	printf '%s: ' "$rel" >&2

	# Retry until N USABLE samples, not N attempts. The first real run lost 4 of
	# 30 calls to unparseable responses, which left every file at 8-9 samples --
	# below the 10 that two disjoint 5-subsets need -- and silently emptied the
	# median-5 arm. Absorbing failures into a short sample count does not just
	# weaken a percentile, it can delete a whole arm of the analysis without
	# saying so. Bounded at 2x so a judge that never parses cannot spend forever.
	scores_csv=""
	got=0
	attempts=0
	max_attempts=$(( SAMPLES * 2 ))
	while [[ "$got" -lt "$SAMPLES" && "$attempts" -lt "$max_attempts" ]]; do
		attempts=$((attempts + 1))
		ATTEMPTED=$((ATTEMPTED + 1))
		echo_build_judge_prompt "$rel" "$content" > "$PROMPT_FILE"

		args=(-p --max-turns 1)
		[[ -n "$EVAL_MODEL" ]] && args+=(--model "$EVAL_MODEL")

		response=""
		if command -v timeout >/dev/null 2>&1; then
			response=$(timeout "$TIMEOUT_SECS" claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
		elif command -v gtimeout >/dev/null 2>&1; then
			response=$(gtimeout "$TIMEOUT_SECS" claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
		else
			response=$(claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
		fi

		clean=$(printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
		score=$(printf '%s' "$clean" | jq -r '.score // empty' 2>/dev/null) || score=""

		if [[ -z "$score" ]]; then
			printf 'x' >&2
			continue
		fi
		printf '.' >&2
		got=$((got + 1))
		USABLE=$((USABLE + 1))
		scores_csv="${scores_csv}${scores_csv:+,}${score}"
	done
	if [[ "$got" -lt "$SAMPLES" ]]; then
		printf ' SHORT: %d/%d usable after %d attempts' "$got" "$SAMPLES" "$attempts" >&2
	fi
	printf '\n' >&2

	jq --arg p "$rel" --argjson s "[${scores_csv}]" \
		'. + {($p): $s}' "${OUT_DIR}/.acc.json" > "${OUT_DIR}/.acc.next" \
		&& mv "${OUT_DIR}/.acc.next" "${OUT_DIR}/.acc.json"
done

if [[ "$USABLE" -eq 0 ]]; then
	printf 'no usable judge responses across %d calls — nothing to measure\n' "$ATTEMPTED" >&2
	rm -f "${OUT_DIR}/.acc.json"
	exit 1
fi

jq -n \
	--arg model "${EVAL_MODEL:-default}" \
	--arg prompt_sha256 "$PROMPT_SHA" \
	--arg measured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--argjson requested "$SAMPLES" \
	--argjson usable "$USABLE" \
	--argjson total "$ATTEMPTED" \
	--slurpfile acc "${OUT_DIR}/.acc.json" \
	'{model: $model, prompt_sha256: $prompt_sha256, measured_at: $measured_at,
	  samples_requested_per_file: $requested, calls_attempted: $total,
	  calls_usable: $usable, samples: $acc[0]}' > "$SAMPLES_JSON"
rm -f "${OUT_DIR}/.acc.json"

node "${SCRIPT_DIR}/judge-spread-stats.mjs" "$SAMPLES_JSON" > "${OUT_DIR}/stats.json" || {
	printf 'statistics failed; raw samples kept at %s\n' "$SAMPLES_JSON" >&2
	exit 1
}

printf '\nsamples: %s\nstats:   %s\n\n' "$SAMPLES_JSON" "${OUT_DIR}/stats.json"
node -e '
const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const row = (name, a) => `  ${name.padEnd(9)} p50 ${String(a.p50).padEnd(7)} p95 ${String(a.p95).padEnd(7)} max ${String(a.max).padEnd(7)} (${a.pairCount} pairs)`;
console.log("|delta| between two independent evaluations of identical content:");
console.log(row("single", s.overall.single));
console.log(row("median-3", s.overall.median3));
console.log(row("median-5", s.overall.median5));
' "${OUT_DIR}/stats.json"
