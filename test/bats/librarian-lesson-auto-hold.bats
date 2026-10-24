#!/usr/bin/env bats
#
# The unattended stage's "leave this alone" markers (ONL-112).
#
# The confirm loop in librarian_lesson_auto_stage visits every pending parked
# candidate on every scan, and nothing made it skip one. So a model refusal
# was paid for again on each scan, forever, and a person's `defer` or
# `unconfirm` was undone by the next scan's model assertion. These tests drive
# both markers: a refusal is not re-asked while the prompt and model that
# refused it are unchanged, and a human hold is never auto-confirmed.

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
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-hold.git
	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"

	EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$EVENTS_LOG")"
	: >"$EVENTS_LOG"

	# Every justification call appends one line, so a test can count what a
	# scan actually paid for rather than inferring it from the outcome.
	CALLS="${BATS_TEST_TMPDIR}/claude-calls"
	: >"$CALLS"
	export CALLS
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
agent=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--agent" ]]; then j=$((i + 1)); agent="${!j}"; fi
done
prompt=$(cat)
pass='{"score":0.93,"passed":true,"judge_type":"x","feedback_summary":"ok","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.85,"disclosure":0.97}}'
if [[ -n "$agent" ]]; then printf '%s' "$pass"; exit 0; fi
printf 'justify\n' >> "$CALLS"
if [[ "$prompt" == *"refuse-me"* ]]; then
  printf '%s' "REFUSE: The claim names this repository's own plugin."
else
  printf '%s' 'The failure is a property of the exec boundary, not of any release.'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	_settings '{"enabled": true, "max_juries_per_scan": 0}'
}

# Usage: _settings <lesson_auto_json> [transform_model]
_settings() {
	mkdir -p "${PROJECT_REPO}/.claude"
	jq -cn --argjson a "$1" --arg m "${2:-}" \
		'{librarian: ({lesson_auto: $a}
		  + (if $m == "" then {} else {lesson_transform: {model: $m}} end))}' \
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

# --- a refusal is not re-asked ----------------------------------------------

@test "a refused candidate is not re-justified on the next scan" {
	id=$(_seed_parked "c refuse-me")
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_calls)" = "1" ] || return 1
	librarian_lesson_auto_stage "$PROJECT_KEY"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_calls)" = "1" ] || return 1
	jq -e '.status == "pending"' "$(_proposal "$id")" >/dev/null
}

@test "a refusal records the fingerprint of the prompt and model that refused it" {
	id=$(_seed_parked "c refuse-me")
	librarian_lesson_auto_stage "$PROJECT_KEY"
	expected=$(librarian_lesson_auto_justify_fingerprint "$(librarian_config_get '.librarian.lesson_transform.model')")
	[ -n "$expected" ] || return 1
	jq -e --arg f "$expected" '.auto_refusal.fingerprint == $f' "$(_proposal "$id")" >/dev/null
}

# A refusal is the model's answer to one prompt. A different prompt (ONL-187
# rewrote it) or a different model is a different question, owed one call.
@test "a model change re-asks a refused candidate once, then holds again" {
	id=$(_seed_parked "c refuse-me")
	librarian_lesson_auto_stage "$PROJECT_KEY"
	_settings '{"enabled": true, "max_juries_per_scan": 0}' "claude-other-model"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_calls)" = "2" ] || return 1
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_calls)" = "2" ]
}

@test "the fingerprint changes with the prompt text and with the model" {
	a=$(librarian_lesson_auto_justify_fingerprint "m1")
	b=$(librarian_lesson_auto_justify_fingerprint "m2")
	[ -n "$a" ] && [ "$a" != "$b" ] || return 1
	_librarian_lesson_auto_justify_preamble() { printf 'a different prompt\n'; }
	c=$(librarian_lesson_auto_justify_fingerprint "m1")
	[ "$a" != "$c" ]
}

# Refusals written before ONL-112 carry no fingerprint. They were refused by an
# older prompt, so each is re-asked once rather than held forever.
@test "a refusal recorded without a fingerprint is re-asked" {
	id=$(_seed_parked "c refuse-me")
	jq '.auto_refusal = {reason: "old", refused_at: "2026-10-01T00:00:00Z"}' "$(_proposal "$id")" \
		> "${BATS_TEST_TMPDIR}/p.json" && mv "${BATS_TEST_TMPDIR}/p.json" "$(_proposal "$id")"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_calls)" = "1" ] || return 1
	jq -e '.auto_refusal.fingerprint | type == "string"' "$(_proposal "$id")" >/dev/null
}

@test "auto_confirm_one reports a held refusal as skipped, without a call" {
	id=$(_seed_parked "c refuse-me")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:refused" ] || return 1
	[ "$(_calls)" = "1" ]
}

# --- a human hold is never auto-confirmed -----------------------------------

@test "defer holds a pending candidate against the unattended stage" {
	id=$(_seed_parked "c")
	run librarian_cli lessons defer "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ] || return 1
	jq -e '.auto_hold.by == "defer" and (.auto_hold.at | type == "string")' "$(_proposal "$id")" >/dev/null || return 1
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_calls)" = "0" ] || return 1
	jq -e '.status == "pending"' "$(_proposal "$id")" >/dev/null
}

@test "defer resolves the project from the working directory when none is given" {
	id=$(_seed_parked "c")
	cd "$PROJECT_REPO"
	run librarian_cli lessons defer "$id"
	[ "$status" -eq 0 ] || return 1
	jq -e '.auto_hold.by == "defer"' "$(_proposal "$id")" >/dev/null
}

@test "defer refuses a lesson that is not pending, and says what to use instead" {
	id=$(_seed_parked "c")
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	run librarian_cli lessons defer "$id" "$PROJECT_REPO"
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"unconfirm"* ]] || return 1
	jq -e 'has("auto_hold") | not' "$(_proposal "$id")" >/dev/null
}

@test "defer refuses an unknown lesson" {
	run librarian_cli lessons defer 01M5NOSUCHLESSON0000000000 "$PROJECT_REPO"
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"not found"* ]]
}

@test "unconfirm holds the candidate it returns to pending" {
	id=$(_seed_parked "c")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	jq -e '.status == "confirmed" and .asserted_by == "model"' "$(_proposal "$id")" >/dev/null || return 1
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	jq -e '.status == "pending" and .auto_hold.by == "unconfirm"' "$(_proposal "$id")" >/dev/null || return 1
	: >"$CALLS"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_calls)" = "0" ] || return 1
	jq -e '.status == "pending"' "$(_proposal "$id")" >/dev/null
}

@test "a human confirm clears the hold" {
	id=$(_seed_parked "c")
	librarian_cli lessons defer "$id" "$PROJECT_REPO" >/dev/null
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	jq -e '.status == "confirmed" and (has("auto_hold") | not)' "$(_proposal "$id")" >/dev/null
}

# confirm writes through two branches, with and without a justification, and
# each must drop the hold. A versioned candidate takes the plain one.
@test "a human confirm without a justification clears the hold too" {
	id=$(librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "c" | jq -c '.applies_to.scope = {kind: "versioned", versions: {vite: "<6"}}')" \
		"01KZ45MKAM734ZS7JK24D2DK0R")
	librarian_cli lessons defer "$id" "$PROJECT_REPO" >/dev/null
	jq -e 'has("auto_hold")' "$(_proposal "$id")" >/dev/null || return 1
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org
	jq -e '.status == "confirmed" and (has("auto_hold") | not)' "$(_proposal "$id")" >/dev/null
}

@test "auto_confirm_one reports a human hold as skipped, without a call" {
	id=$(_seed_parked "c")
	librarian_cli lessons defer "$id" "$PROJECT_REPO" >/dev/null
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:held" ] || return 1
	[ "$(_calls)" = "0" ]
}

@test "lessons show says when a candidate is held, and by which verb" {
	id=$(_seed_parked "c")
	librarian_cli lessons defer "$id" "$PROJECT_REPO" >/dev/null
	cd "$PROJECT_REPO"
	run librarian_cli lessons show "$id"
	[[ "$output" == *"held:"*"defer"* ]]
}

# --- what the bus sees --------------------------------------------------------

# A skipped candidate was never asked, so it is not an assertion and not a
# refusal. Counting it would make every scan re-report the same refusals,
# which is the inflation ONL-115's measurement has to be free of.
@test "skipped candidates emit no assertion and are not counted as refusals" {
	_seed_parked "c refuse-me" 01M3B87J7046SJE5BECNMP670K >/dev/null
	held=$(_seed_parked "c" 01M3B87J7046SJE5BECNMP671Z)
	librarian_cli lessons defer "$held" "$PROJECT_REPO" >/dev/null
	librarian_lesson_auto_stage "$PROJECT_KEY"
	: >"$EVENTS_LOG"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(grep -c '"event_type":"librarian.lesson.asserted"' "$EVENTS_LOG" || true)" = "0" ] || return 1
	grep '"event_type":"librarian.autojury.complete"' "$EVENTS_LOG" \
		| jq -e '.payload.asserted == 0 and .payload.refused == 0 and .payload.unavailable == 0' >/dev/null
}

# --- a misconfigured visibility costs nothing -------------------------------

# librarian_lesson_confirm refuses a justification at private visibility, so
# asking the model first paid for an answer that could never be used.
@test "a private lesson_auto.visibility is refused before any model call" {
	_settings '{"enabled": true, "max_juries_per_scan": 0, "visibility": "private"}'
	id=$(_seed_parked "c")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ] || return 1
	[ "$(_calls)" = "0" ]
}

@test "an unrecognized lesson_auto.visibility is refused before any model call" {
	_settings '{"enabled": true, "max_juries_per_scan": 0, "visibility": "everyone"}'
	id=$(_seed_parked "c")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ] || return 1
	[ "$(_calls)" = "0" ]
}
