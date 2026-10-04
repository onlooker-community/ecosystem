#!/usr/bin/env bats
#
# config_get_int — the validating accessor ONL-132 asked for.
#
# The house idiom guards empty and the literal "null" and nothing else:
#
#   MAX=$(plugin_config_get '.plugin.max')
#   [[ -z "$MAX" || "$MAX" == "null" ]] && MAX=2400
#
# Any other non-numeric value passes straight through to (( )), where bash
# treats the bare word as a variable name, `set -u` stops the shell, and --
# because these scripts use `set -uo pipefail` deliberately without -e -- the
# status left behind is 0. A caller reads success and finds no artifacts.
#
# The contract these tests pin down: config_get_int ALWAYS prints a
# non-negative integer. That invariant is what lets a caller do (( )) with no
# guard of its own, which is the entire point of having one accessor instead of
# 34 hand-rolled ones.

bats_require_minimum_version 1.5.0

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# shellcheck source=../../scripts/lib/config-loader.sh
	source "${REPO_ROOT}/scripts/lib/config-loader.sh"
}

@test "a valid integer passes through unchanged" {
	_PROBE='{"probe":{"max":2400}}'
	run config_get_int _PROBE '.probe.max' 100
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "2400" ]
}

@test "a non-numeric value falls back to the default" {
	# The bug. Without validation this returns "not-a-number" and the caller's
	# (( )) kills the shell at status 0.
	_PROBE='{"probe":{"max":"not-a-number"}}'
	run config_get_int _PROBE '.probe.max' 100
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "100" ]
}

@test "a literal JSON null falls back" {
	_PROBE='{"probe":{"max":null}}'
	run config_get_int _PROBE '.probe.max' 100
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "100" ]
}

@test "an absent key falls back" {
	_PROBE='{"probe":{}}'
	run config_get_int _PROBE '.probe.max' 100
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "100" ]
}

@test "a float falls back, because bash arithmetic cannot take one" {
	# Not hypothetical: governor's .governor.estimation.safety_margin is 1.3.
	# A float reaching (( )) is a syntax error, so an int accessor must refuse
	# it rather than pass it on. A caller that genuinely wants 1.3 is not an
	# int caller and must not use this function.
	_PROBE='{"probe":{"max":1.3}}'
	run config_get_int _PROBE '.probe.max' 100
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "100" ]
}

@test "a negative falls back" {
	# Every current consumer is a count, limit or budget, where a negative is
	# meaningless. Accepting -1 as a budget would be its own silent failure,
	# so the contract is non-negative and the guard is ^[0-9]+$ -- matching
	# what the four hand-rolled guards in the tree already use.
	_PROBE='{"probe":{"max":-5}}'
	run config_get_int _PROBE '.probe.max' 100
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "100" ]
}

@test "a non-numeric default does not escape" {
	# The invariant. A guard that can itself emit a non-integer has not closed
	# the hole -- it has moved it from the config file into the calling code,
	# where it is harder to see. A bad default is a caller bug, so it is
	# reported on stderr rather than passed on.
	_PROBE='{"probe":{"max":"garbage"}}'
	# --separate-stderr so the warning does not land in $output and satisfy the
	# integer assertion by accident.
	run --separate-stderr config_get_int _PROBE '.probe.max' "also-garbage"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" =~ ^[0-9]+$ ]] || return 1
	[ "$output" = "0" ] || return 1
	# The caller bug is reported, not swallowed -- otherwise the 0 is just
	# another silent wrong answer.
	[[ "$stderr" == *"not a non-negative integer"* ]] || return 1
	[[ "$stderr" == *".probe.max"* ]]
}

@test "the result is safe in (( )) with no guard, under the convention these scripts use" {
	# The end-to-end point. This is the exact shape that dies today: a script
	# with `set -uo pipefail` and no -e, a non-numeric config value, and
	# arithmetic with no guard. If SENTINEL prints, the hazard is closed.
	local script="${BATS_TEST_TMPDIR}/consumer.sh"
	cat > "$script" <<SCRIPT
#!/usr/bin/env bash
set -uo pipefail
source "${REPO_ROOT}/scripts/lib/config-loader.sh"
_PROBE='{"probe":{"max":"not-a-number"}}'
MAX=\$(config_get_int _PROBE '.probe.max' 2400)
if (( 10 > MAX )); then printf 'exceeds\n'; else printf 'within\n'; fi
printf 'SENTINEL\n'
SCRIPT
	run bash "$script"
	[ "$status" -eq 0 ] || return 1
	# SENTINEL proves the shell survived the arithmetic at all.
	[[ "$output" == *"SENTINEL"* ]] || return 1
	# ... and the branch taken proves it compared against 2400, not a bare word.
	[[ "$output" == *"within"* ]]
}
