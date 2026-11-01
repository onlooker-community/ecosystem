#!/usr/bin/env bats

# The attended `/librarian lessons judge` walk, driven the way the skill drives
# it: a fresh shell that runs SKILL.md's own setup block and then calls
# librarian_cli. Every other lesson suite calls librarian_config_load in
# setup(), which the skill never does, so those suites could not see that the
# CLI ran on an empty config and resolved no rubric at all (ONL-208).

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git

	# Only what the fixtures need: the key and the lessons dir. Config is
	# deliberately NOT loaded in this shell or the one under test.
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")

	# The skill's setup block, verbatim: its `source` lines, nothing added.
	SKILL_CLI="${BATS_TEST_TMPDIR}/skill-cli.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail'
		grep -E '^source "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/lib/' \
			"${PLUGIN_ROOT}/skills/librarian/SKILL.md"
		printf '%s\n' 'librarian_cli "$@"'
	} > "$SKILL_CLI"
}

# Run librarian_cli from the project directory, as the skill does.
_cli() {
	(cd "$PROJECT_REPO" && bash "$SKILL_CLI" "$@")
}

_seed_confirmed() {
	local id="$1" visibility="$2" asserted_by="${3:-}"
	local dir
	dir="$(librarian_lessons_dir "$PROJECT_KEY")/proposals"
	mkdir -p "$dir"
	jq -n --arg id "$id" --arg v "$visibility" --arg a "$asserted_by" \
		--arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{ id: $id, artifact_id: "art-\($id)", status: "confirmed",
		   visibility: $v, confirmed_at: $t,
		   candidate: { claim: "Prefer jq -c for compact output",
		                rationale: "Readable diffs",
		                evidence: { resolution: "Applied and verified" },
		                applies_to: { stack: ["bash"],
		                              scope: { kind: "version_independent",
		                                       justification: "jq output flags are stable" } } } }
		 + (if $a == "" then {} else {asserted_by: $a} end)' \
		> "${dir}/${id}.json"
}

_status_of() {
	jq -r '.status' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/${1}.json"
}

# Two passing judges that score exactly the criteria named in a rendered
# rubric, the way the walk tells its judges to.
_verdicts_for() {
	local rendered="$1" names
	names=$(printf '%s\n' "$rendered" | sed -nE 's/^- ([a-z_]+) \(.*/\1/p' | jq -R . | jq -cs .)
	jq -cn --argjson n "$names" '
		($n | map({(.): 0.97}) | add) as $c
		| [{judge_type: "standard", score: 0.95, passed: true, criterion_scores: $c},
		   {judge_type: "adversarial", score: 0.95, passed: true, criterion_scores: $c}]'
}

@test "the skill's setup block can print the org rubric" {
	run _cli lessons rubric org
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"- grounding ("* ]]
}

@test "the skill's setup block can record a verdict on an org lesson" {
	_seed_confirmed "att01" "org"
	run _cli lessons judge "att01" "$(_verdicts_for "$(_cli lessons rubric org)")"
	[ "$status" -eq 0 ] || return 1
	[ "$(_status_of att01)" = "approved" ]
}

@test "lessons rubric <id> hands a model-asserted lesson the auto rubric" {
	_seed_confirmed "att02" "org" "model"
	run _cli lessons rubric "att02"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"- disclosure ("* ]]
}

@test "lessons rubric <id> hands a human-asserted org lesson the org rubric" {
	_seed_confirmed "att03" "org" "human"
	run _cli lessons rubric "att03"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"- grounding ("* ]] || return 1
	[[ "$output" != *"disclosure"* ]]
}

@test "lessons rubric <id> refuses a private lesson, which runs no jury" {
	_seed_confirmed "att04" "private"
	run _cli lessons rubric "att04"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"no jury"* ]]
}

@test "lessons rubric <id> refuses a lesson that does not exist" {
	run _cli lessons rubric "nosuch01"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"nosuch01"* ]]
}

@test "a model-asserted lesson judged on its own rubric gets a verdict" {
	# The failure this pins: the walk handed judges the org rubric, the
	# recorder checked the auto rubric, disclosure went unscored, and every
	# model-asserted lesson came back UNJUDGED and stayed confirmed.
	_seed_confirmed "att05" "org" "model"
	run _cli lessons judge "att05" "$(_verdicts_for "$(_cli lessons rubric att05)")"
	[ "$status" -eq 0 ] || return 1
	[ "$(_status_of att05)" != "confirmed" ]
}

@test "the walk asks for each lesson's rubric by id, not by visibility" {
	# Asking by visibility always resolves the human rubric, which is the
	# wrong one for a model-asserted lesson.
	local skill="${PLUGIN_ROOT}/skills/librarian/SKILL.md"
	grep -q 'librarian_cli lessons rubric <id>' "$skill" || return 1
	! grep -q 'librarian_cli lessons rubric <org|public>' "$skill"
}
