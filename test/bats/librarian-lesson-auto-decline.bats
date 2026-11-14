#!/usr/bin/env bats
#
# The unattended stage's decline policy (lesson_auto.on_refusal, the default).
#
# Under the hold policy a refusal waits for a person, and nobody comes: in the
# store this was written against, 41 of 52 pending candidates were refusals,
# every one of them surfaced at each SessionStart as "awaiting confirmation"
# while the stage, by design, never asked about them again. A refusal is the
# model's verdict on the candidate, so the decline policy makes it terminal:
# status `declined`, with a row in declined.jsonl (the machine-verdict ledger)
# carrying the model's reason.

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	for lib in librarian-config onlooker-project-key librarian-ulid \
		librarian-storage librarian-emit librarian-lesson-storage \
		librarian-lesson-validate librarian-author-key librarian-lesson-review \
		librarian-lesson-rubric librarian-lesson-judge librarian-lesson-promote \
		librarian-lesson-transform librarian-lesson-auto librarian-cli; do
		# shellcheck disable=SC1091
		source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh"
	done
	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-decline.git
	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"
	EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$EVENTS_LOG")"
	: >"$EVENTS_LOG"
	CALLS="${BATS_TEST_TMPDIR}/claude-calls"
	: >"$CALLS"
	export CALLS
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
printf 'justify\n' >> "$CALLS"
if [[ "$prompt" == *"refuse-me"* ]]; then
  printf '%s' "REFUSE: The claim names this repository's own plugin."
else
  printf '%s' 'The failure is a property of the exec boundary, not of any release.'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	# No on_refusal key: the shipped default is what is under test.
	_settings '{"enabled": true, "max_juries_per_scan": 0}'
}

# Usage: _settings <lesson_auto_json>
_settings() {
	mkdir -p "${PROJECT_REPO}/.claude"
	jq -cn --argjson a "$1" '{librarian: {lesson_auto: $a}}' \
		> "${PROJECT_REPO}/.claude/settings.json"
	librarian_config_load "$PROJECT_REPO"
}

_candidate() {
	jq -cn --arg claim "$1" \
		'{claim: $claim, rationale: "r",
		  evidence: {artifact_ids: ["01KZ45MKAM734ZS7JK24D2DK0R"], session_ids: ["s1"],
		             project_key: "6a7678979e31", observed_at: "2026-08-03T15:59:48Z",
		             resolution: "Pin vitest to 3.x."},
		  applies_to: {stack: ["vite"], scope: {kind: "unscoped"}, file_patterns: [], task_kinds: []}}'
}

# Usage: _seed_parked <claim> [artifact_id]
_seed_parked() {
	librarian_lesson_write_proposal "$PROJECT_KEY" "$(_candidate "$1")" \
		"${2:-01M3B87J7046SJE5BECNMP670K}"
}

_calls() { grep -c . "$CALLS" || true; }
_proposal() { printf '%s' "${LESSONS_DIR}/proposals/$1.json"; }
_declined() { printf '%s' "${LESSONS_DIR}/declined.jsonl"; }

@test "a refusal declines the candidate" {
	id=$(_seed_parked "c refuse-me")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "declined:no_justification" ] || return 1
	jq -e '.status == "declined" and (.declined_at | test("^[0-9]{4}-"))
	   and .auto_refusal.reason == "The claim names this repository'"'"'s own plugin."' \
		"$(_proposal "$id")" >/dev/null
}

@test "a declined refusal is recorded in declined.jsonl with the model's reason" {
	id=$(_seed_parked "c refuse-me")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	[ "$(grep -c . "$(_declined)")" = "1" ] || return 1
	jq -e --arg id "$id" '.lesson_id == $id and .artifact_id == "01M3B87J7046SJE5BECNMP670K"
	   and .reason == "auto_refused"
	   and .detail == "The claim names this repository'"'"'s own plugin."' \
		"$(_declined)" >/dev/null
}

# The backlog: refusals recorded under the hold policy, by the prompt and model
# still in use. The stage never asks about those again, so declining them must
# not ask either, or retiring the backlog would re-bill every one.
@test "a refusal already recorded by this prompt and model is declined without a call" {
	_settings '{"enabled": true, "max_juries_per_scan": 0, "on_refusal": "hold"}'
	id=$(_seed_parked "c refuse-me")
	librarian_lesson_auto_stage "$PROJECT_KEY"
	jq -e '.status == "pending"' "$(_proposal "$id")" >/dev/null || return 1
	[ "$(_calls)" = "1" ] || return 1
	_settings '{"enabled": true, "max_juries_per_scan": 0}'
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "declined:refused" ] || return 1
	[ "$(_calls)" = "1" ] || return 1
	jq -e '.status == "declined"' "$(_proposal "$id")" >/dev/null || return 1
	jq -e '.reason == "auto_refused" and .detail == "The claim names this repository'"'"'s own plugin."' \
		"$(_declined)" >/dev/null
}

@test "a declined candidate is never asked about or declined again" {
	id=$(_seed_parked "c refuse-me")
	librarian_lesson_auto_stage "$PROJECT_KEY"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:not_pending" ] || return 1
	[ "$(_calls)" = "1" ] || return 1
	[ "$(grep -c . "$(_declined)")" = "1" ]
}

# A person's hold outranks the policy: "not now" is not a refusal.
@test "a held candidate is not declined" {
	id=$(_seed_parked "c refuse-me")
	librarian_cli lessons defer "$id" "$PROJECT_REPO" >/dev/null
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_calls)" = "0" ] || return 1
	jq -e '.status == "pending" and .auto_hold.by == "defer"' "$(_proposal "$id")" >/dev/null || return 1
	[ ! -f "$(_declined)" ]
}

# A decline is terminal, so a value nobody meant must not cause one.
@test "an unrecognized on_refusal value holds rather than declines" {
	_settings '{"enabled": true, "max_juries_per_scan": 0, "on_refusal": "drop"}'
	id=$(_seed_parked "c refuse-me")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:no_justification" ] || return 1
	jq -e '.status == "pending"' "$(_proposal "$id")" >/dev/null || return 1
	[ ! -f "$(_declined)" ]
}

@test "the stage counts a fresh refusal it declined, and not a recorded one" {
	_settings '{"enabled": true, "max_juries_per_scan": 0, "on_refusal": "hold"}'
	_seed_parked "c refuse-me" 01M3B87J7046SJE5BECNMP670K >/dev/null
	librarian_lesson_auto_stage "$PROJECT_KEY"
	_settings '{"enabled": true, "max_juries_per_scan": 0}'
	_seed_parked "c refuse-me too" 01M3B87J7046SJE5BECNMP671Z >/dev/null
	: >"$EVENTS_LOG"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(grep -c '"event_type":"librarian.lesson.asserted"' "$EVENTS_LOG")" = "1" ] || return 1
	grep '"event_type":"librarian.autojury.complete"' "$EVENTS_LOG" \
		| jq -e '.payload.refused == 1 and .payload.asserted == 0' >/dev/null || return 1
	[ "$(jq -s '[.[] | select(.status == "declined")] | length' "${LESSONS_DIR}/proposals/"*.json)" = "2" ]
}

@test "lessons status counts declined candidates" {
	id=$(_seed_parked "c refuse-me")
	librarian_lesson_auto_stage "$PROJECT_KEY"
	run librarian_cli lessons status "$PROJECT_REPO"
	[[ "$output" == *"pending: 0,"* ]] || return 1
	[[ "$output" == *"declined: 1"* ]]
}

@test "the shipped config declines refusals" {
	run jq -r '.librarian.lesson_auto.on_refusal' "${PLUGIN_ROOT}/config.json"
	[ "$output" = "decline" ]
}
