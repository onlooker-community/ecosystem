#!/usr/bin/env bats

# The pairwise prompt behind ONL-103.
#
# echo's absolute rubric has a signal-to-noise of 0.61: it cannot reliably tell
# two different documents apart, and telling two VERSIONS of one document apart
# is harder. Pairwise comparison needs no stable absolute scale, which is the
# thing the measurement says is missing.
#
# This file pins the prompt's contract. The prompt is the whole experiment --
# a measurement taken against a different prompt does not transfer -- so the
# parts the stats depend on are asserted explicitly.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh"
}

@test "the pairwise prompt names both documents and both bodies" {
	run echo_build_pairwise_prompt "a/one.md" "BODY-ALPHA" "b/two.md" "BODY-BETA"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"a/one.md"* ]] || return 1
	[[ "$output" == *"BODY-ALPHA"* ]] || return 1
	[[ "$output" == *"b/two.md"* ]] || return 1
	[[ "$output" == *"BODY-BETA"* ]] || return 1
}

@test "the pairwise prompt fixes the verdict vocabulary" {
	run echo_build_pairwise_prompt "a.md" "A" "b.md" "B"
	[[ "$output" == *'"verdict"'* ]] || return 1
	[[ "$output" == *"better"* ]] || return 1
	[[ "$output" == *"worse"* ]] || return 1
	[[ "$output" == *"same"* ]] || return 1
	[[ "$output" == *'"confidence"'* ]] || return 1
}

# A model asked to compare two things is reluctant to call a tie, and the
# self-comparison arm depends entirely on it being willing to. If self_tie_rate
# fails for THIS reason it is a prompt defect, not evidence that pairwise
# cannot work, so the permission is explicit and pinned.
@test "the pairwise prompt says identical input is expected" {
	run echo_build_pairwise_prompt "a.md" "A" "b.md" "B"
	[[ "$output" == *"identical"* ]] || return 1
}

@test "the pairwise prompt defines better as referring to document B" {
	run echo_build_pairwise_prompt "a.md" "A" "b.md" "B"
	[[ "$output" == *"verdict is about DOCUMENT B"* ]] || return 1
	[[ "$output" == *'"better" — DOCUMENT B is the better prompt file'* ]] || return 1
}

# The absolute rubric's signal-to-noise of 0.61 comes from measurement against THIS
# exact prompt, so drift_threshold: 0.28 is a property of it. Any deliberate change
# requires re-measuring and updating the hash below.
@test "the scoring prompt byte-identity is pinned to measurement history" {
	expected_hash="29667d3fea5764c93be6011eb69a7211ad09ea83729c772568806948575d1a70"
	if command -v shasum >/dev/null 2>&1; then
		actual_hash=$(echo_build_judge_prompt "x.md" "XBODY" | shasum -a 256 | cut -d' ' -f1)
	else
		actual_hash=$(echo_build_judge_prompt "x.md" "XBODY" | sha256sum | cut -d' ' -f1)
	fi
	[ "$actual_hash" = "$expected_hash" ] || return 1
}
