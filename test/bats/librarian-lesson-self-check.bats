#!/usr/bin/env bats
#
# The unattended stage's self-check (ONL-311).
#
# Five of the six lessons a person vetoed after jury approval carried a
# justification that defended a broader principle than the claim, and the jury
# scored the principle. The self-check is a second call, after the justify
# call and before the confirm, that compares the two. A failure leaves the
# candidate pending and is never a decline, so its artifact survives.

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
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-self-check.git
	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"

	EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$EVENTS_LOG")"
	: >"$EVENTS_LOG"

	# One line per call, by kind, so a test counts what a scan paid for.
	CALLS="${BATS_TEST_TMPDIR}/claude-calls"
	: >"$CALLS"
	export CALLS
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
if [[ "$prompt" == *"You are checking a justification"* ]]; then
  printf 'self_check\n' >> "$CALLS"
  [[ -n "${SELF_CHECK_LOG:-}" ]] && printf '%s' "$prompt" > "$SELF_CHECK_LOG"
  if [[ "$prompt" == *"self-check-fail"* ]]; then
    printf '%s' 'FAIL: The justification argues for batching in general, not for this claim.'
  elif [[ "$prompt" == *"self-check-bare"* ]]; then
    printf '%s' 'FAIL'
  elif [[ "$prompt" == *"self-check-garbage"* ]]; then
    printf '%s' 'This looks fine to me.'
  elif [[ "$prompt" == *"self-check-empty"* ]]; then
    printf '%s' ''
  else
    printf '%s' 'PASS'
  fi
  exit 0
fi
printf 'justify\n' >> "$CALLS"
printf '%s' 'The failure is a property of the exec boundary, not of any release.'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	_settings '{"enabled": true, "max_juries_per_scan": 0, "self_check": {"enabled": true}}'
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
		  applies_to: {stack: ["vite", "jq"], scope: {kind: "unscoped"}, file_patterns: [], task_kinds: []}}'
}

# Usage: _seed_parked <claim> [artifact_id]
_seed_parked() {
	librarian_lesson_write_proposal "$PROJECT_KEY" "$(_candidate "$1")" \
		"${2:-01M3B87J7046SJE5BECNMP670K}"
}

_calls() { grep -c "^${1}$" "$CALLS" || true; }
_proposal() { printf '%s' "${LESSONS_DIR}/proposals/$1.json"; }
_events() { grep "\"event_type\":\"$1\"" "$EVENTS_LOG" 2>/dev/null || true; }
_count() { _events "$1" | grep -c . || true; }

# --- the prompt -------------------------------------------------------------

@test "the self-check prompt carries the claim, the stack and the justification" {
	run librarian_lesson_auto_self_check_prompt "$(_candidate "the claim text")" "the justification text"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"You are checking a justification"* ]] || return 1
	[[ "$output" == *"claim: the claim text"* ]] || return 1
	[[ "$output" == *"stack: vite, jq"* ]] || return 1
	[[ "$output" == *"justification: the justification text"* ]]
}

@test "the self-check prompt asks both questions and fixes the answer form" {
	run _librarian_lesson_auto_self_check_preamble
	[[ "$output" == *"more general principle"* ]] || return 1
	[[ "$output" == *"a release of that tool could change"* ]] || return 1
	[[ "$output" == *"PASS"* ]] || return 1
	[[ "$output" == *"FAIL: "* ]]
}

@test "the self-check prompt builder refuses missing arguments" {
	run librarian_lesson_auto_self_check_prompt "" "j"
	[ -z "$output" ] || return 1
	run librarian_lesson_auto_self_check_prompt "$(_candidate c)" ""
	[ -z "$output" ]
}

@test "the self-check dispatches exactly the prompt the builder returns" {
	export SELF_CHECK_LOG="${BATS_TEST_TMPDIR}/sc-prompt.txt"
	candidate=$(_candidate "c")
	librarian_lesson_auto_self_check "$candidate" "j" >/dev/null
	# The stub reads the prompt with $(cat), which drops the trailing newline.
	diff <(printf '%s' "$(librarian_lesson_auto_self_check_prompt "$candidate" "j")") "$SELF_CHECK_LOG"
}

@test "the self-check returns one trimmed line" {
	run librarian_lesson_auto_self_check "$(_candidate "c self-check-fail")" "j"
	[ "$output" = "FAIL: The justification argues for batching in general, not for this claim." ]
}

# --- the fingerprint --------------------------------------------------------

@test "the self-check fingerprint changes with either prompt and with the model" {
	a=$(librarian_lesson_auto_self_check_fingerprint "m1")
	b=$(librarian_lesson_auto_self_check_fingerprint "m2")
	[ -n "$a" ] && [ "$a" != "$b" ] || return 1
	_librarian_lesson_auto_self_check_preamble() { printf 'a different check\n'; }
	c=$(librarian_lesson_auto_self_check_fingerprint "m1")
	[ "$a" != "$c" ] || return 1
	_librarian_lesson_auto_justify_preamble() { printf 'a different justify\n'; }
	d=$(librarian_lesson_auto_self_check_fingerprint "m1")
	[ "$c" != "$d" ]
}

# --- the flag ---------------------------------------------------------------

@test "the self-check is off by default" {
	_settings '{"enabled": true}'
	run _librarian_lesson_auto_self_check_enabled
	[ "$status" -ne 0 ]
}

@test "only the literal true turns the self-check on" {
	_settings '{"enabled": true, "self_check": {"enabled": "yes"}}'
	run _librarian_lesson_auto_self_check_enabled
	[ "$status" -ne 0 ] || return 1
	_settings '{"enabled": true, "self_check": {"enabled": true}}'
	run _librarian_lesson_auto_self_check_enabled
	[ "$status" -eq 0 ]
}
