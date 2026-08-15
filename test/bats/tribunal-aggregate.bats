#!/usr/bin/env bats

# `run --separate-stderr` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-aggregate.sh"
}

VERDICTS='[{"judge_id":"a","score":0.8},{"judge_id":"b","score":0.6},{"judge_id":"c","score":0.4}]'

# The rubric tribunal actually ships. Every criterion carries a min_pass, which
# is why a weight-fraction coverage guard alone cannot protect its floors.
RUBRIC_DEFAULT='{"criteria":[{"name":"correctness","weight":0.4,"min_pass":0.7},{"name":"completeness","weight":0.3,"min_pass":0.7},{"name":"safety","weight":0.2,"min_pass":0.8},{"name":"clarity","weight":0.1,"min_pass":0.5}]}'

@test "mean of [0.8, 0.6, 0.4] is 0.6" {
	local v
	v=$(tribunal_aggregate "mean" "$VERDICTS")
	awk -v v="$v" 'BEGIN { exit !(v > 0.59 && v < 0.61) }'
}

@test "median of three is the middle" {
	local v
	v=$(tribunal_aggregate "median" "$VERDICTS")
	awk -v v="$v" 'BEGIN { exit !(v > 0.59 && v < 0.61) }'
}

@test "median of four averages the two middle scores" {
	local four='[{"judge_id":"a","score":0.2},{"judge_id":"b","score":0.4},{"judge_id":"c","score":0.6},{"judge_id":"d","score":0.8}]'
	local v
	v=$(tribunal_aggregate "median" "$four")
	awk -v v="$v" 'BEGIN { exit !(v > 0.49 && v < 0.51) }'
}

@test "min picks the lowest score" {
	local v
	v=$(tribunal_aggregate "min" "$VERDICTS")
	awk -v v="$v" 'BEGIN { exit !(v > 0.39 && v < 0.41) }'
}

@test "weighted_mean falls back to mean with neither rubric nor criterion scores" {
	local v
	v=$(tribunal_aggregate "weighted_mean" "$VERDICTS")
	awk -v v="$v" 'BEGIN { exit !(v > 0.59 && v < 0.61) }'
}

@test "weighted_mean degrades to mean when the panel covered too little of the rubric" {
	# The C1 regression: two judges rating work at 0.45/0.50 overall while
	# scoring one cheap criterion at 0.9 produced an aggregate of 0.9 —
	# renormalized over a fifth of the rubric and passing a gate that the
	# judges' own scores would have blocked.
	#
	# `depth` deliberately carries NO min_pass, so every floored criterion in
	# this rubric is scored. That is what keeps this test pinned to
	# min_criterion_coverage: the unscored-floor guard below cannot fire here,
	# so only the coverage guard can produce the plain mean.
	local out
	out=$(tribunal_aggregate "weighted_mean" '[
	  {"judge_id":"a","score":0.45,"passed":true,"criterion_scores":{"clarity":0.9}},
	  {"judge_id":"b","score":0.50,"passed":true,"criterion_scores":{"clarity":0.9}}
	]' '{"criteria":[{"name":"clarity","weight":0.2,"min_pass":0.5},{"name":"depth","weight":0.8}]}')
	# Must be the plain mean of .score (0.475), not the renormalized 0.9.
	awk -v a="$out" 'BEGIN { exit !(a > 0.474 && a < 0.476) }'
}

@test "weighted_mean degrades to mean when a floored criterion went unscored" {
	# min_criterion_coverage is a weight fraction, but what a floor protects is
	# that one criterion. In the shipped default rubric correctness (0.4) plus
	# completeness (0.3) clears the 0.6 guard while skipping safety — the
	# highest floor in the rubric — so the very inversion the coverage guard
	# was added to stop reappeared one criterion further along: judges rating
	# the work 0.45 and 0.50 aggregated to 0.95 and passed.
	local out
	out=$(tribunal_aggregate "weighted_mean" '[
	  {"judge_id":"a","score":0.45,"passed":true,"criterion_scores":{"correctness":0.95,"completeness":0.95}},
	  {"judge_id":"b","score":0.50,"passed":true,"criterion_scores":{"correctness":0.95,"completeness":0.95}}
	]' "$RUBRIC_DEFAULT")
	# 0.7 of the weight is covered, so min_criterion_coverage is satisfied and
	# only the unscored-floor guard can produce the plain mean (0.475) here.
	awk -v a="$out" 'BEGIN { exit !(a > 0.474 && a < 0.476) }'
}

@test "weighted_mean trusts a panel that scored every floored criterion" {
	local out
	out=$(tribunal_aggregate "weighted_mean" '[
	  {"judge_id":"a","score":0.1,"passed":true,"criterion_scores":{"correctness":0.8,"completeness":0.8,"safety":0.8,"clarity":0.8}}
	]' "$RUBRIC_DEFAULT")
	# Nothing floored is missing, so the weighted value (0.8) must win over .score.
	awk -v a="$out" 'BEGIN { exit !(a > 0.799 && a < 0.801) }'
}

@test "weighted_mean still renormalizes over an unscored criterion carrying no floor" {
	# Absence is not a zero, and renormalizing over the scored weight stays
	# correct when what went unscored was never a floor. Only a missing *floor*
	# forces the degrade — otherwise the fix for the inversion above would
	# collapse weighted_mean into mean for every partial panel.
	local out
	out=$(tribunal_aggregate "weighted_mean" '[
	  {"judge_id":"a","score":0.1,"passed":true,"criterion_scores":{"grounding":0.8}}
	]' '{"criteria":[{"name":"grounding","weight":0.7,"min_pass":0.6},{"name":"polish","weight":0.3}]}')
	# grounding is the only floor and it is scored; 0.7 coverage clears 0.6, so
	# this renormalizes to 0.8 rather than degrading to .score.
	awk -v a="$out" 'BEGIN { exit !(a > 0.799 && a < 0.801) }'
}

@test "an out-of-range criterion score is ignored, not trusted" {
	local out
	out=$(tribunal_aggregate "weighted_mean" '[
	  {"judge_id":"a","score":0.5,"criterion_scores":{"correctness":100}}
	]' '{"criteria":[{"name":"correctness","weight":1.0,"min_pass":0.7}]}')
	# 100 is filtered, nothing is covered, so this degrades to the mean of .score.
	awk -v a="$out" 'BEGIN { exit !(a > 0.499 && a < 0.501) }'
}

@test "unknown method falls back to mean with warning on stderr" {
	run bash -c '
		source "${REPO_ROOT}/plugins/tribunal/scripts/lib/tribunal-aggregate.sh"
		tribunal_aggregate "lottery" "[{\"score\":0.5},{\"score\":0.7}]" 2>&1
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"unknown method lottery"* ]]
}

@test "empty verdicts aggregates to 0" {
	local v
	v=$(tribunal_aggregate "mean" "[]")
	[ "$v" = "0" ]
}

@test "disagreement of identical scores is 0" {
	local d
	d=$(tribunal_disagreement '[{"score":0.7},{"score":0.7}]')
	awk -v d="$d" 'BEGIN { exit !(d < 0.01) }'
}

@test "disagreement of [0.2, 0.8] is 0.6" {
	local d
	d=$(tribunal_disagreement '[{"score":0.2},{"score":0.8}]')
	awk -v d="$d" 'BEGIN { exit !(d > 0.59 && d < 0.61) }'
}

@test "disagreement of single verdict is 0" {
	local d
	d=$(tribunal_disagreement '[{"score":0.7}]')
	[ "$d" = "0" ]
}

# Two criteria with deliberately unequal weights, so weighted_mean and mean
# cannot coincide. Judge A is strong on the heavy criterion, weak on the light
# one; judge B is the reverse.
# `clarity` carries NO min_pass on purpose, and that is load-bearing: the tests
# below leave it unscored to exercise the renormalization arithmetic, and an
# unscored *floor* degrades weighted_mean to the plain mean before any of that
# arithmetic runs. Re-adding a min_pass here does not fail anything loudly — it
# quietly converts five weight tests into five assertions about the mean of
# .score. `correctness` stays floored and stays scored, so the guard is still
# live in this fixture; it is just never tripped.
RUBRIC_UNEQUAL='{"criteria":[{"name":"correctness","weight":0.9,"min_pass":0.7},{"name":"clarity","weight":0.1}]}'
SCORED='[
  {"judge_id":"a","score":0.5,"criterion_scores":{"correctness":1.0,"clarity":0.0}},
  {"judge_id":"b","score":0.5,"criterion_scores":{"correctness":1.0,"clarity":0.0}}
]'

@test "weighted_mean differs from mean when weights are unequal" {
	# mean of .score is 0.5 for both judges. The weighted mean is
	# 0.9*1.0 + 0.1*0.0 = 0.9. If these come out equal, weights are still inert.
	local w m
	w=$(tribunal_aggregate "weighted_mean" "$SCORED" "$RUBRIC_UNEQUAL")
	m=$(tribunal_aggregate "mean" "$SCORED" "$RUBRIC_UNEQUAL")
	awk -v a="$w" -v b="$m" 'BEGIN { exit !(a != b) }' || return 1
	awk -v a="$w" 'BEGIN { exit !(a > 0.89 && a < 0.91) }'
}

@test "weighted_mean averages judges within a criterion before weighting" {
	local out
	out=$(tribunal_aggregate "weighted_mean" '[
	  {"judge_id":"a","score":0.5,"criterion_scores":{"correctness":1.0,"clarity":1.0}},
	  {"judge_id":"b","score":0.5,"criterion_scores":{"correctness":0.0,"clarity":1.0}}
	]' "$RUBRIC_UNEQUAL")
	# correctness mean 0.5, clarity mean 1.0 → 0.9*0.5 + 0.1*1.0 = 0.55
	awk -v a="$out" 'BEGIN { exit !(a > 0.549 && a < 0.551) }'
}

@test "weighted_mean degrades to mean when no verdict carries criterion_scores" {
	# Every verdict emitted before Task 1 shipped looks like this.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.8},{"judge_id":"b","score":0.6}]' "$RUBRIC_UNEQUAL")
	awk -v a="$out" 'BEGIN { exit !(a > 0.699 && a < 0.701) }'
}

@test "an absent criterion is skipped, not counted as zero" {
	# clarity is absent everywhere. If absence read as 0 the answer would be
	# 0.9*1.0 + 0.1*0.0 = 0.9. Skipping it renormalizes to 0.9/0.9 = 1.0.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.5,"criterion_scores":{"correctness":1.0}}]' \
		"$RUBRIC_UNEQUAL")
	awk -v a="$out" 'BEGIN { exit !(a > 0.999 && a < 1.001) }'
}

@test "a criterion scored at zero is honored, not treated as absent" {
	# The mirror of the previous test, and the one that catches a `// 0` fix
	# that "passes" the absence test by accident.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.5,"criterion_scores":{"correctness":0.0}}]' \
		"$RUBRIC_UNEQUAL")
	awk -v a="$out" 'BEGIN { exit !(a >= 0 && a < 0.001) }'
}

@test "weights that do not sum to 1.0 are normalized" {
	# tribunal_rubric_validate rejects such a rubric, but librarian's loader
	# validates nothing and hands its rubric straight through. Normalizing here
	# means the two paths cannot disagree.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.1,"criterion_scores":{"correctness":1.0,"clarity":0.0}}]' \
		'{"criteria":[{"name":"correctness","weight":1.8,"min_pass":0.7},{"name":"clarity","weight":0.2,"min_pass":0.5}]}')
	# 1.8*1.0 + 0.2*0.0 = 1.8, over a weight sum of 2.0 → 0.9
	awk -v a="$out" 'BEGIN { exit !(a > 0.899 && a < 0.901) }'
}

@test "a hyphenated criterion name scores correctly" {
	# A dotted jq path would be a COMPILE error here: exit 3, empty stdout,
	# which awk reads as 0.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.2,"criterion_scores":{"path-traversal":1.0}}]' \
		'{"criteria":[{"name":"path-traversal","weight":1.0,"min_pass":0.5}]}')
	awk -v a="$out" 'BEGIN { exit !(a > 0.999 && a < 1.001) }'
}

@test "weighted_mean falls back to mean when the rubric is absent" {
	local out
	out=$(tribunal_aggregate "weighted_mean" "$SCORED")
	awk -v a="$out" 'BEGIN { exit !(a > 0.499 && a < 0.501) }'
}

@test "a non-number criterion score is ignored rather than poisoning the mean" {
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.5,"criterion_scores":{"correctness":1.0,"clarity":"n/a"}}]' \
		"$RUBRIC_UNEQUAL")
	awk -v a="$out" 'BEGIN { exit !(a > 0.999 && a < 1.001) }'
}

# --- Verdicts with no usable .score (ecosystem-up8) -------------------------
#
# A judge that returns parseable JSON omitting `score` is malformed, not
# unanimous. jq's `add` treats the missing key as null and `null + n == n`, so
# such a verdict used to contribute 0 to the numerator and 1 to the
# denominator — wrong rather than loud. It is dropped from the panel instead.

SCORELESS_RUBRIC='{"criteria":[{"name":"correctness","weight":1.0,"min_pass":0.7}]}'

@test "mean drops a scoreless verdict instead of counting it as zero" {
	local out
	out=$(tribunal_aggregate "mean" '[{"judge_id":"a","score":0.9},{"judge_id":"b"}]')
	# Counting the missing score as 0 gives 0.45. Dropping it gives 0.9.
	awk -v a="$out" 'BEGIN { exit !(a > 0.899 && a < 0.901) }'
}

@test "weighted_mean does not count a scoreless judge's criterion scores" {
	# The failure mode ecosystem-pht introduced: once criterion_scores cover the
	# rubric, weighted_mean never reads .score, so a judge that returned no
	# verdict at all was silently counted as a fully participating one — and it
	# fails toward NOT blocking. Dropping happens before any method runs, so the
	# malformed judge takes its criterion scores with it.
	local out
	out=$(tribunal_aggregate "weighted_mean" '[
	  {"judge_id":"a","score":0.9,"criterion_scores":{"correctness":0.9}},
	  {"judge_id":"b","criterion_scores":{"correctness":0.1}}
	]' "$SCORELESS_RUBRIC")
	# Averaging both criterion scores gives 0.5; dropping judge b gives 0.9.
	awk -v a="$out" 'BEGIN { exit !(a > 0.899 && a < 0.901) }'
}

@test "median drops a scoreless verdict" {
	local out
	out=$(tribunal_aggregate "median" '[{"score":0.4},{"score":0.8},{"judge_id":"c"}]')
	# Two usable scores left, so the median is their mean: 0.6.
	awk -v a="$out" 'BEGIN { exit !(a > 0.599 && a < 0.601) }'
}

@test "min never returns null when a verdict has no score" {
	# jq's `min` over [null, 0.9] is null, which the gate then feeds to awk as
	# the string "null" and coerces to 0 — a non-numeric aggregate that reads
	# as the worst possible score.
	local out
	out=$(tribunal_aggregate "min" '[{"judge_id":"a","score":0.9},{"judge_id":"b"}]')
	[ "$out" != "null" ] || return 1
	awk -v a="$out" 'BEGIN { exit !(a > 0.899 && a < 0.901) }'
}

@test "a panel where no verdict carries a score aggregates to 0, not a crash" {
	# Fails closed, matching the empty-panel convention directly above it: 0 is
	# below every threshold, so the gate blocks.
	local none='[{"judge_id":"a"},{"judge_id":"b"}]'
	local m
	for m in mean weighted_mean median min; do
		# --separate-stderr: the drop warning would otherwise land in $output.
		run --separate-stderr tribunal_aggregate "$m" "$none" "$SCORELESS_RUBRIC"
		[ "$status" -eq 0 ] || return 1
		[ "$output" = "0" ] || return 1
	done
}

@test "a scoreless verdict with criterion_scores still aggregates to 0 when it is the whole panel" {
	# weighted_mean must not resurrect a panel that has no usable verdict just
	# because the criterion map looks complete.
	run --separate-stderr tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","criterion_scores":{"correctness":0.9}}]' "$SCORELESS_RUBRIC"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "0" ]
}

@test "dropping a scoreless verdict is reported on stderr with its judge_id" {
	run --separate-stderr tribunal_aggregate "mean" \
		'[{"judge_id":"a","score":0.9},{"judge_id":"bad-judge"}]'
	[ "$status" -eq 0 ] || return 1
	local re='bad-judge'
	[[ "$stderr" =~ $re ]]
}

@test "no dropped-verdict warning when every verdict carries a score" {
	run --separate-stderr tribunal_aggregate "mean" '[{"score":0.8},{"score":0.6}]'
	[ -z "$stderr" ]
}

@test "disagreement ignores a verdict with no score" {
	local d
	d=$(tribunal_disagreement '[{"score":0.2},{"score":0.8},{"judge_id":"c"}]')
	awk -v d="$d" 'BEGIN { exit !(d > 0.599 && d < 0.601) }'
}

@test "disagreement is 0 when fewer than two verdicts carry a score" {
	# It crashed on a single scoreless verdict, and a crash prints nothing to
	# stdout — so the caller read an empty dissent score, awk coerced it to 0,
	# and the gate's dissent short-circuit never fired. Fails toward not blocking.
	local d
	d=$(tribunal_disagreement '[{"score":0.9},{"judge_id":"b"}]')
	[ "$d" = "0" ] || return 1
	d=$(tribunal_disagreement '[{"judge_id":"a"},{"judge_id":"b"}]')
	[ "$d" = "0" ]
}
