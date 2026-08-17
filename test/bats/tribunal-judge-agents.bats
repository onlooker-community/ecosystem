#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	AGENTS_DIR="${REPO_ROOT}/plugins/tribunal/agents"
}

# Extract the first fenced ```json block from an agent definition.
_agent_json() {
	awk '/^```json/ { f = 1; next } /^```/ { if (f) exit } f' "$1"
}

@test "every judge agent's example verdict carries criterion_scores" {
	local agent json
	for agent in standard adversarial security; do
		json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-${agent}.md")
		[ -n "$json" ] || return 1
		printf '%s' "$json" | jq -e 'has("criterion_scores")' >/dev/null || return 1
	done
}

@test "criterion_scores is an object of numbers in [0,1], not an array" {
	local agent json
	for agent in standard adversarial security; do
		json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-${agent}.md")
		printf '%s' "$json" | jq -e '
			(.criterion_scores | type) == "object"
			and (.criterion_scores | length) > 0
			and all(.criterion_scores[]; type == "number" and . >= 0 and . <= 1)
		' >/dev/null || return 1
	done
}

@test "criterion_scores is keyed by rubric criteria, not by the agent's own lenses" {
	# The default rubric's criteria are the only legal keys *for this example*.
	# This is the whole point: an agent keying by its own lens names
	# (edge-cases, injection) produces scores no aggregator can ever match to a
	# floor.
	#
	# The example is not the contract — the caller's rubric governs, and other
	# callers ship different names. Librarian dispatches these same agents
	# (ADR-002) against rubrics keyed grounding / scope_accuracy / generality /
	# disclosure. Each agent says so in prose right below the block this test
	# reads; do not "fix" a librarian mismatch by editing the keys here.
	local rubric_names json agent
	rubric_names=$(jq -c '[.tribunal.rubric.builtins[0].criteria[].name]' \
		"${REPO_ROOT}/plugins/tribunal/config.json")

	for agent in standard adversarial security; do
		json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-${agent}.md")
		printf '%s' "$json" | jq -e --argjson want "$rubric_names" '
			[.criterion_scores | keys[]] | all(. as $k | $want | index($k) != null)
		' >/dev/null || return 1
	done
}

@test "every judge agent scores safety, the criterion with the highest floor" {
	# safety carries min_pass 0.8 and appeared in NO agent contract before this
	# change, so its floor could never fire. Regression guard.
	local agent json
	for agent in standard adversarial security; do
		json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-${agent}.md")
		printf '%s' "$json" | jq -e '.criterion_scores | has("safety")' >/dev/null || return 1
	done
}

@test "every judge agent says the caller's rubric governs, not the example keys" {
	# C2. The test above pins the example block to tribunal's default rubric,
	# which is right for tribunal and wrong for everyone else: librarian
	# dispatches these same three agents by name (ADR-002) against rubrics keyed
	# grounding / scope_accuracy / generality / disclosure. A judge that copies
	# the example into a librarian context emits keys matching nothing, the
	# aggregate silently degrades, and disclosure's floor never runs on a lesson
	# about to be published. An example is the strongest signal in an agent
	# prompt, so the correction has to sit next to it.
	local agent
	for agent in standard adversarial security; do
		grep -q 'The rubric you are given governs' "${AGENTS_DIR}/tribunal-judge-${agent}.md" || return 1
		grep -q 'disclosure' "${AGENTS_DIR}/tribunal-judge-${agent}.md" || return 1
	done
}

@test "adversarial and security agents document the rubric they must score" {
	local agent
	for agent in adversarial security; do
		grep -qi 'rubric' "${AGENTS_DIR}/tribunal-judge-${agent}.md" || return 1
	done
}

@test "criteria_evaluated keeps each agent's own investigative lenses" {
	# Deliberately NOT unified with criterion_scores. If a future edit collapses
	# the two, the adversarial agent stops reporting what it actually probed.
	local json
	json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-adversarial.md")
	printf '%s' "$json" | jq -e '
		(.criteria_evaluated | index("edge-cases")) != null
	' >/dev/null
}

@test "the schema dependency admits criterion_scores" {
	# criterion_scores and the criterion_floor reason land in 2.12.0. Below that
	# the runtime emitter rejects the payload wherever the package resolves.
	#
	# Asserted by validating a payload that carries criterion_scores rather than
	# by matching the version range literally: the literal form pinned "^2.12.0"
	# and so failed on the very next bump, which says nothing about whether the
	# field is admitted. This checks the property the test is named for.
	local payload
	payload=$(jq -cn '{
		task_id: "bats-task", score: 0.82, passed: true, judge_type: "adversarial",
		criterion_scores: {"edge-cases": 0.7, "correctness": 0.9}
	}')
	jq -cn --argjson p "$payload" \
		'{plugin: "tribunal", session_id: "bats", event_type: "tribunal.verdict", payload: $p}' \
		| ONLOOKER_DIR="$ONLOOKER_DIR" \
		  node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" emit >/dev/null
}
