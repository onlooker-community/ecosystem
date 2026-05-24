#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-aggregate.sh"
}

VERDICTS='[{"judge_id":"a","score":0.8},{"judge_id":"b","score":0.6},{"judge_id":"c","score":0.4}]'

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

@test "weighted_mean degrades to mean in v0.1" {
	local v
	v=$(tribunal_aggregate "weighted_mean" "$VERDICTS")
	awk -v v="$v" 'BEGIN { exit !(v > 0.59 && v < 0.61) }'
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
