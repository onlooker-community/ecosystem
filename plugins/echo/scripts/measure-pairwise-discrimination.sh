#!/usr/bin/env bash
# Measure echo's pairwise discrimination (ONL-103).
#
# WHY THIS EXISTS. ONL-102 set drift_threshold to the measured 0.28 and made
# echo truthful. The same measurement showed why that did not make it useful:
# between-file sd of means 0.048 against a mean within-file sd of 0.079, so
# signal/noise is 0.61. The absolute rubric cannot reliably separate two
# different documents, and echo's real job -- separating two versions of one
# document -- is strictly harder. Median-of-5 only reaches signal/noise near 1,
# at five times the cost of the most expensive hook in the stack.
#
# Pairwise comparison needs no stable absolute scale, which is exactly what is
# missing. This script measures whether it discriminates, BEFORE anything in
# echo changes, because ONL-103's acceptance criterion is itself a measurement.
#
# WHAT IT DOES. Two arms over the same files:
#   self   each document against its own content  -> the noise floor
#   cross  every pair, in BOTH presentation orders -> discrimination + bias
#
# Both orders are not optional. A judge that prefers whichever document sits in
# slot B manufactures discrimination that looks excellent and means nothing,
# and running one order cannot see it.
#
# The self arm runs first: it is the cheapest kill. A judge that will not call
# identical content identical is ruled out for a sixth of the calls.
#
# THIS SCRIPT is never run by npm test -- a full run is 72 judge calls. Its
# tests are: test/bats/echo-measure-pairwise.bats covers the plumbing against
# a stub, and test/node/pairwise-stats.test.mjs covers the arithmetic. Both of
# those DO run in npm test, and cost nothing.
#
# Usage:
#   measure-pairwise-discrimination.sh [--repeats N] [--out DIR] [--dry-run] [FILE...]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_ROOT}/../.." && pwd)"

# shellcheck source=lib/echo-config.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-config.sh"
# shellcheck source=lib/echo-judge-prompt.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh"

REPEATS=2
DRY_RUN=0
OUT_DIR=""
FILES=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--repeats) REPEATS="$2"; shift 2 ;;
		--out) OUT_DIR="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help)
			printf 'usage: %s [--repeats N] [--out DIR] [--dry-run] [FILE...]\n' "$(basename "$0")"
			exit 0 ;;
		*) FILES+=("$1"); shift ;;
	esac
done

if [[ "${#FILES[@]}" -eq 0 ]]; then
	printf 'no files given; pass the paths to compare\n' >&2
	exit 1
fi

# A cross pair needs two documents. One file can only measure the noise floor,
# which answers half the question and reads as a complete run.
if [[ "${#FILES[@]}" -lt 2 ]]; then
	printf 'need at least two files to form a cross pair; got %d\n' "${#FILES[@]}" >&2
	exit 1
fi

for f in "${FILES[@]}"; do
	if [[ ! -f "$f" ]]; then
		printf 'not a readable file: %s\n' "$f" >&2
		exit 1
	fi
done

# Mirrors measure-judge-spread.sh, CLAUDE_PLUGIN_ROOT included. The accessors
# read it at call time, so a plain echo_config_load leaves every value empty and
# the run would measure whatever the DEFAULT model is rather than echo's pinned
# judge -- a measurement that describes nothing.
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$REPO_ROOT"
EVAL_MODEL=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_model)
TIMEOUT_SECS=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_timeout)

N=${#FILES[@]}
PAIRS=$(( N * (N - 1) / 2 ))
SELF_CALLS=$(( N * REPEATS ))
CROSS_CALLS=$(( PAIRS * 2 * REPEATS ))
TOTAL=$(( SELF_CALLS + CROSS_CALLS ))

if [[ "$DRY_RUN" -eq 1 ]]; then
	printf 'would run %d judge calls\n' "$TOTAL"
	printf '  self:  %d  (%d files x %d repeats)\n' "$SELF_CALLS" "$N" "$REPEATS"
	printf '  cross: %d  (%d pairs x 2 orders x %d repeats)\n' "$CROSS_CALLS" "$PAIRS" "$REPEATS"
	printf 'model: %s\n' "$EVAL_MODEL"
	for f in "${FILES[@]}"; do printf '  %s\n' "$f"; done
	exit 0
fi

[[ -z "$OUT_DIR" ]] && OUT_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}/echo/pairwise/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR" || { printf 'cannot create %s\n' "$OUT_DIR" >&2; exit 1; }

# These numbers are a property of ONE prompt judged by ONE model. Stamping both
# is what lets a later reader know whether the measurement still applies.
if command -v shasum >/dev/null 2>&1; then
	PROMPT_SHA=$(shasum -a 256 "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh" | cut -d' ' -f1)
else
	PROMPT_SHA=$(sha256sum "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh" | cut -d' ' -f1)
fi

PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

# One judge call. Echoes the verdict, or nothing when the response does not
# parse. Callers count usable verdicts rather than attempts.
_ask() {
	local rel_a="$1" body_a="$2" rel_b="$3" body_b="$4"
	echo_build_pairwise_prompt "$rel_a" "$body_a" "$rel_b" "$body_b" > "$PROMPT_FILE"

	local args=(-p --max-turns 1)
	[[ -n "$EVAL_MODEL" ]] && args+=(--model "$EVAL_MODEL")

	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$TIMEOUT_SECS" claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$TIMEOUT_SECS" claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
	fi

	local clean verdict
	clean=$(printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
	verdict=$(printf '%s' "$clean" | jq -r 'select(.verdict == "better" or .verdict == "worse" or .verdict == "same") | .verdict' 2>/dev/null) || verdict=""
	printf '%s' "$verdict"
}

SELF_JSON="${OUT_DIR}/.self.json"
CROSS_JSON="${OUT_DIR}/.cross.json"
printf '[]' > "$SELF_JSON"
printf '[]' > "$CROSS_JSON"

RELS=()
BODIES=()
for f in "${FILES[@]}"; do
	RELS+=("${f#"${REPO_ROOT}/"}")
	BODIES+=("$(cat "$f")")
done

# Calls issued, whether or not the response parsed -- counted separately from
# the usable verdicts recorded in self[].verdicts / cross[].ab / cross[].ba.
# Nothing else records attempted calls, which is how self_comparisons_usable
# could never diverge from self_comparisons: a silently degraded arm was
# invisible. See ONL-103 task 2 review.
SELF_ATTEMPTED=0
CROSS_ATTEMPTED=0

# Total verdicts that parsed, across both arms. Mirrors measure-judge-spread.sh's
# USABLE: a zero here means the whole run produced nothing to measure, as
# opposed to one pair or one file coming back empty, which a tie-heavy but
# otherwise healthy run can do legitimately.
USABLE=0

# --- self arm, first: the cheapest kill -------------------------------------
printf 'self arm (%d calls):\n' "$SELF_CALLS" >&2
for i in "${!RELS[@]}"; do
	printf '  %s: ' "${RELS[$i]}" >&2
	csv=""
	for ((r = 0; r < REPEATS; r++)); do
		v=$(_ask "${RELS[$i]}" "${BODIES[$i]}" "${RELS[$i]}" "${BODIES[$i]}")
		SELF_ATTEMPTED=$((SELF_ATTEMPTED + 1))
		if [[ -z "$v" ]]; then printf 'x' >&2; continue; fi
		printf '.' >&2
		USABLE=$((USABLE + 1))
		csv="${csv}${csv:+,}\"${v}\""
	done
	printf '\n' >&2
	jq --arg p "${RELS[$i]}" --argjson v "[${csv}]" \
		'. + [{path: $p, verdicts: $v}]' "$SELF_JSON" > "${SELF_JSON}.next" \
		&& mv "${SELF_JSON}.next" "$SELF_JSON"
done

# --- cross arm, both orders -------------------------------------------------
printf 'cross arm (%d calls):\n' "$CROSS_CALLS" >&2
for ((i = 0; i < N; i++)); do
	for ((j = i + 1; j < N; j++)); do
		printf '  %s vs %s: ' "${RELS[$i]}" "${RELS[$j]}" >&2
		ab_csv=""
		ba_csv=""
		for ((r = 0; r < REPEATS; r++)); do
			v=$(_ask "${RELS[$i]}" "${BODIES[$i]}" "${RELS[$j]}" "${BODIES[$j]}")
			CROSS_ATTEMPTED=$((CROSS_ATTEMPTED + 1))
			if [[ -n "$v" ]]; then printf '.' >&2; USABLE=$((USABLE + 1)); ab_csv="${ab_csv}${ab_csv:+,}\"${v}\""; else printf 'x' >&2; fi
			v=$(_ask "${RELS[$j]}" "${BODIES[$j]}" "${RELS[$i]}" "${BODIES[$i]}")
			CROSS_ATTEMPTED=$((CROSS_ATTEMPTED + 1))
			if [[ -n "$v" ]]; then printf '.' >&2; USABLE=$((USABLE + 1)); ba_csv="${ba_csv}${ba_csv:+,}\"${v}\""; else printf 'x' >&2; fi
		done
		printf '\n' >&2
		jq --arg a "${RELS[$i]}" --arg b "${RELS[$j]}" \
			--argjson ab "[${ab_csv}]" --argjson ba "[${ba_csv}]" \
			'. + [{a: $a, b: $b, ab: $ab, ba: $ba}]' "$CROSS_JSON" > "${CROSS_JSON}.next" \
			&& mv "${CROSS_JSON}.next" "$CROSS_JSON"
	done
done

if [[ "$USABLE" -eq 0 ]]; then
	printf 'no usable judge responses across %d calls — nothing to measure\n' \
		"$((SELF_ATTEMPTED + CROSS_ATTEMPTED))" >&2
	rm -f "$SELF_JSON" "$CROSS_JSON"
	exit 1
fi

VERDICTS_JSON="${OUT_DIR}/verdicts.json"
jq -n \
	--arg model "${EVAL_MODEL:-default}" \
	--arg prompt_sha256 "$PROMPT_SHA" \
	--arg measured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--argjson repeats "$REPEATS" \
	--argjson attempted_self "$SELF_ATTEMPTED" \
	--argjson attempted_cross "$CROSS_ATTEMPTED" \
	--slurpfile self "$SELF_JSON" \
	--slurpfile cross "$CROSS_JSON" \
	'{model: $model, prompt_sha256: $prompt_sha256, measured_at: $measured_at,
	  repeats: $repeats, attempted: {self_calls: $attempted_self, cross_calls: $attempted_cross},
	  self: $self[0], cross: $cross[0]}' > "$VERDICTS_JSON"
rm -f "$SELF_JSON" "$CROSS_JSON"

node "${SCRIPT_DIR}/pairwise-stats.mjs" "$VERDICTS_JSON" > "${OUT_DIR}/stats.json" || {
	printf 'statistics failed; raw verdicts kept at %s\n' "$VERDICTS_JSON" >&2
	exit 1
}

printf '\nverdicts: %s\nstats:    %s\n\n' "$VERDICTS_JSON" "${OUT_DIR}/stats.json"
node -e '
const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const row = (k, v, bar) => `  ${k.padEnd(22)} ${String(v).padEnd(8)} ${bar}`;
console.log("pairwise discrimination:");
console.log(row("self_tie_rate", s.self_tie_rate, s.kill.self_tie_pass ? "pass (>= 0.9)" : "FAIL (>= 0.9)"));
console.log(row("false_discrimination", s.false_discrimination, ""));
console.log(row("cross_antisymmetry", s.cross_antisymmetry, s.kill.antisymmetry_pass ? "pass (>= 0.8)" : "FAIL (>= 0.8)"));
console.log(row("true_discrimination", s.true_discrimination, s.kill.discrimination_pass ? "pass (> false)" : "FAIL (> false)"));
console.log(`\n  verdict: ${s.kill.verdict.toUpperCase()}`);
' "${OUT_DIR}/stats.json"
