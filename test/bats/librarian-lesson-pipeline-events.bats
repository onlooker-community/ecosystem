#!/usr/bin/env bats
#
# The unattended lesson pipeline on the event bus (ONL-116).
#
# Stage 6 asserts a lesson's scope with a model, juries it with nobody present,
# and holds an approval for a veto window before it can leave the machine.
# Until this, none of that reached the bus: librarian.lesson.promoted was the
# only lesson event, and it could not tell a held approval from a shipped one.
# These tests drive each branch that now emits, so the bus gate validates every
# payload, and pin the outcome each branch reports.

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
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-events.git
	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"
	librarian_config_load "$PROJECT_REPO"

	EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$EVENTS_LOG")"
	: >"$EVENTS_LOG"
}

# Usage: _events <event_type>
_events() {
	grep "\"event_type\":\"$1\"" "$EVENTS_LOG" 2>/dev/null || true
}

_count() {
	_events "$1" | grep -c . || true
}

_candidate() {
	jq -cn --argjson scope "$1" --arg claim "${2:-c}" \
		'{claim: $claim, rationale: "r",
		  evidence: {artifact_ids: ["01KZ45MKAM734ZS7JK24D2DK0R"], session_ids: ["s1"],
		             project_key: "6a7678979e31", observed_at: "2026-08-03T15:59:48Z",
		             resolution: "Pin vitest to 3.x."},
		  applies_to: {stack: ["vite"], scope: $scope, file_patterns: [], task_kinds: []}}'
}

# A parked candidate, optionally carrying a marker the stub branches on.
_seed_parked() {
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate '{"kind":"unscoped"}' "c ${1:-}")" "${2:-01M3B87J7046SJE5BECNMP670K}"
}

_seed_versioned() {
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate '{"kind":"versioned","versions":{"vite":"<6"}}')" "01KZ45MKAM734ZS7JK24D2DK0R"
}

# Answers the justification prompt by marker, and each judge by --agent.
_stub_claude() {
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
agent=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--agent" ]]; then j=$((i + 1)); agent="${!j}"; fi
done
prompt=$(cat)
pass='{"score":0.93,"passed":true,"judge_type":"TYPE","feedback_summary":"ok","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.85,"disclosure":0.97}}'
case "$agent" in
  tribunal-judge-standard|tribunal-judge-adversarial) printf '%s' "${pass//TYPE/x}" ; exit 0 ;;
esac
if [[ "$prompt" == *"refuse-with-reason"* ]]; then
  printf '%s' "REFUSE: The claim names this repository's own plugin."
elif [[ "$prompt" == *"refuse-bare"* ]]; then
  printf '%s' 'REFUSE'
elif [[ "$prompt" == *"say-nothing"* ]]; then
  printf '%s' ''
else
  printf '%s' 'The failure is a property of the exec boundary, not of any release.'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_enable_auto() {
	mkdir -p "${PROJECT_REPO}/.claude"
	jq -cn --argjson cap "${1:-1}" \
		'{librarian: {lesson_auto: {enabled: true, max_juries_per_scan: $cap}}}' \
		> "${PROJECT_REPO}/.claude/settings.json"
	librarian_config_load "$PROJECT_REPO"
}

_verdict() {
	# $1 judge_type, $2 criterion_scores JSON
	jq -cn --arg t "$1" --argjson c "$2" \
		'{judge_type: $t, score: 0.9, passed: true, criterion_scores: $c}'
}

_full_scores='{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.97}'

# --- librarian.lesson.asserted ----------------------------------------------

@test "a model assertion emits asserted" {
	_stub_claude
	id=$(_seed_parked)
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "confirmed:${id}" ] || return 1
	[ "$(_count librarian.lesson.asserted)" = "1" ] || return 1
	_events librarian.lesson.asserted \
		| jq -e --arg id "$id" '.payload == {lesson_id: $id, outcome: "asserted"}' >/dev/null
}

@test "a refusal with a reason emits refused and says a reason was given, not what it was" {
	_stub_claude
	id=$(_seed_parked refuse-with-reason)
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:no_justification" ] || return 1
	_events librarian.lesson.asserted \
		| jq -e '.payload.outcome == "refused" and .payload.reason_given == true' >/dev/null || return 1
	! grep -q "own plugin" "$EVENTS_LOG"
}

@test "a bare REFUSE emits refused with no reason given" {
	_stub_claude
	id=$(_seed_parked refuse-bare)
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	_events librarian.lesson.asserted \
		| jq -e '.payload.outcome == "refused" and .payload.reason_given == false' >/dev/null
}

@test "an empty model response emits unavailable" {
	_stub_claude
	id=$(_seed_parked say-nothing)
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ] || return 1
	_events librarian.lesson.asserted \
		| jq -e '.payload.outcome == "unavailable" and (.payload | has("reason_given") | not)' >/dev/null
}

@test "a candidate that is not parked is never asked, so nothing is emitted" {
	_stub_claude
	id=$(_seed_versioned)
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:not_parked" ] || return 1
	[ "$(_count librarian.lesson.asserted)" = "0" ]
}

# --- librarian.lesson.judged ------------------------------------------------

@test "a juried approval emits judged with the asserter and aggregate score" {
	_stub_claude
	id=$(_seed_parked)
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	run librarian_lesson_auto_judge_one "$PROJECT_KEY" "$id"
	[ "$output" = "judged:${id}" ] || return 1
	[ "$(_count librarian.lesson.judged)" = "1" ] || return 1
	_events librarian.lesson.judged | jq -e --arg id "$id" '
		.payload.lesson_id == $id and .payload.outcome == "approved"
		and .payload.asserted_by == "model" and .payload.juried == true
		and (.payload.aggregate_score | type == "number")
		and (.payload | has("unjudged_reason") | not)' >/dev/null
}

@test "a human-confirmed rejection emits judged rejected, asserted_by human" {
	id=$(_seed_parked)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	low='{"grounding":0.3,"scope_accuracy":0.3,"generality":0.3}'
	verdicts=$(jq -cn --argjson a "$(_verdict standard "$low")" \
		--argjson b "$(_verdict adversarial "$low")" '[$a, $b]' | jq -c '.[].passed = false')
	run librarian_lesson_judge "$PROJECT_KEY" "$id" "$verdicts"
	[ "$status" -eq 0 ] || return 1
	_events librarian.lesson.judged \
		| jq -e '.payload.outcome == "rejected" and .payload.asserted_by == "human"' >/dev/null
}

@test "a private lesson emits judged approved with juried false" {
	# A parked lesson cannot be confirmed private: a justification nobody
	# juries would go unchecked. A bound version range needs none.
	id=$(_seed_versioned)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" private
	run librarian_lesson_judge "$PROJECT_KEY" "$id" '[]'
	[ "$status" -eq 0 ] || return 1
	_events librarian.lesson.judged | jq -e '
		.payload.outcome == "approved" and .payload.juried == false
		and (.payload | has("aggregate_score") | not)' >/dev/null
}

@test "a panel missing a judge emits unjudged panel_mismatch" {
	id=$(_seed_parked)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	run librarian_lesson_judge "$PROJECT_KEY" "$id" "[$(_verdict standard "$_full_scores")]"
	[ "$status" -eq 2 ] || return 1
	_events librarian.lesson.judged | jq -e '
		.payload.outcome == "unjudged" and .payload.unjudged_reason == "panel_mismatch"
		and .payload.juried == true' >/dev/null
}

@test "a floored criterion no judge scored emits unjudged criterion_unscored" {
	id=$(_seed_parked)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	partial='{"grounding":0.9,"generality":0.9}'
	verdicts=$(jq -cn --argjson a "$(_verdict standard "$partial")" \
		--argjson b "$(_verdict adversarial "$partial")" '[$a, $b]')
	run librarian_lesson_judge "$PROJECT_KEY" "$id" "$verdicts"
	[ "$status" -eq 2 ] || return 1
	_events librarian.lesson.judged \
		| jq -e '.payload.outcome == "unjudged" and .payload.unjudged_reason == "criterion_unscored"' >/dev/null
}

# Every shipped criterion is floored, so the unscored check fires first and
# low coverage is reachable only through a rubric with an unfloored criterion.
@test "a panel covering too little rubric weight emits unjudged coverage_below_min" {
	mkdir -p "${PROJECT_REPO}/.claude"
	jq -cn '{librarian: {lesson_judging: {rubrics: [{
		id: "lesson-promotion", score_threshold: 0.75, gate_policy: "majority",
		judge_types: ["standard", "adversarial"],
		criteria: [{name: "grounding", weight: 0.3, min_pass: 0.7},
		           {name: "breadth", weight: 0.7}]}]}}}' \
		> "${PROJECT_REPO}/.claude/settings.json"
	librarian_config_load "$PROJECT_REPO"
	id=$(_seed_parked)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	only='{"grounding":0.9}'
	verdicts=$(jq -cn --argjson a "$(_verdict standard "$only")" \
		--argjson b "$(_verdict adversarial "$only")" '[$a, $b]')
	run librarian_lesson_judge "$PROJECT_KEY" "$id" "$verdicts"
	[ "$status" -eq 2 ] || return 1
	_events librarian.lesson.judged \
		| jq -e '.payload.outcome == "unjudged" and .payload.unjudged_reason == "coverage_below_min"' >/dev/null
}

@test "a lesson that is not confirmed is refused and emits nothing" {
	id=$(_seed_parked)
	run librarian_lesson_judge "$PROJECT_KEY" "$id" '[]'
	[ "$status" -eq 1 ] || return 1
	[ "$(_count librarian.lesson.judged)" = "0" ]
}

# --- librarian.lesson.promoted: held ----------------------------------------

@test "a model-asserted approval is promoted with held true" {
	_stub_claude
	id=$(_seed_parked)
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	librarian_lesson_auto_judge_one "$PROJECT_KEY" "$id" >/dev/null
	[ -f "${LESSONS_DIR}/approved_held/${id}.json" ] || return 1
	_events librarian.lesson.promoted \
		| jq -e '.payload.outcome == "approved" and .payload.held == true' >/dev/null
}

@test "a human-asserted approval is promoted with held false" {
	id=$(_seed_parked)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	verdicts=$(jq -cn --argjson a "$(_verdict standard "$_full_scores")" \
		--argjson b "$(_verdict adversarial "$_full_scores")" '[$a, $b]')
	librarian_lesson_judge "$PROJECT_KEY" "$id" "$verdicts"
	librarian_lesson_promote "$PROJECT_KEY" "$id"
	[ -f "${LESSONS_DIR}/approved/${id}.json" ] || return 1
	_events librarian.lesson.promoted \
		| jq -e '.payload.outcome == "approved" and .payload.held == false' >/dev/null
}

# --- librarian.lesson.shipped -----------------------------------------------

# Seeds a held lesson whose window elapsed: promoted $1 hours ago, shippable now.
_seed_held_elapsed() {
	local id="$1" hours="$2" promoted
	promoted=$(python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=$hours)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
	jq -cn --arg id "$id" --arg p "$promoted" \
		'{id: $id, status: "approved", asserted_by: "model",
		  promoted_at: $p, shippable_after: "2000-01-01T00:00:00Z"}' \
		> "${LESSONS_DIR}/proposals/${id}.json"
	printf '{}' > "${LESSONS_DIR}/approved_held/${id}.json"
}

@test "the sweep emits shipped with how long the lesson was held" {
	_seed_held_elapsed 01M5SHIPPED0000000000000001 72
	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ] || return 1
	# The sweep's stdout is its contract with SessionStart: ids, one per line.
	[ "$output" = "01M5SHIPPED0000000000000001" ] || return 1
	[ -f "${LESSONS_DIR}/approved/01M5SHIPPED0000000000000001.json" ] || return 1
	_events librarian.lesson.shipped | jq -e '
		.payload.lesson_id == "01M5SHIPPED0000000000000001"
		and .payload.held_ms >= (72 * 3600 * 1000 - 60000)
		and .payload.held_ms <= (72 * 3600 * 1000 + 60000)' >/dev/null
}

@test "a shipped lesson whose promotion time is unreadable omits held_ms" {
	_seed_held_elapsed 01M5SHIPPED0000000000000002 1
	jq '.promoted_at = "yesterday"' "${LESSONS_DIR}/proposals/01M5SHIPPED0000000000000002.json" \
		> "${BATS_TEST_TMPDIR}/p.json"
	mv "${BATS_TEST_TMPDIR}/p.json" "${LESSONS_DIR}/proposals/01M5SHIPPED0000000000000002.json"
	librarian_lesson_sweep_held "$PROJECT_KEY" >/dev/null
	_events librarian.lesson.shipped | jq -e '.payload | has("held_ms") | not' >/dev/null
}

@test "a lesson still inside its window ships nothing and emits nothing" {
	jq -cn '{id: "01M5HELD0000000000000000001", status: "approved", asserted_by: "model",
	         promoted_at: "2000-01-01T00:00:00Z", shippable_after: "2999-01-01T00:00:00Z"}' \
		> "${LESSONS_DIR}/proposals/01M5HELD0000000000000000001.json"
	printf '{}' > "${LESSONS_DIR}/approved_held/01M5HELD0000000000000000001.json"
	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ -z "$output" ] || return 1
	[ "$(_count librarian.lesson.shipped)" = "0" ]
}

# --- librarian.lesson.vetoed ------------------------------------------------

_seed_held_via_promote() {
	local id="$1"
	jq -cn --arg id "$id" --argjson cand "$(_candidate '{"kind":"version_independent","justification":"j"}')" \
		'{id: $id, status: "approved", visibility: "public",
		  artifact_id: "01KZ45MKAM734ZS7JK24D2DK0R", candidate: $cand,
		  asserted_by: "model", judged_at: "2026-09-26T12:00:00Z",
		  verdict: {passed: true, judges: [{passed: true}, {passed: true}]}}' \
		> "${LESSONS_DIR}/proposals/${id}.json"
	librarian_lesson_promote "$PROJECT_KEY" "$id"
	[ -f "${LESSONS_DIR}/approved_held/${id}.json" ]
}

@test "a veto with a reason emits vetoed, reason_given true, and no reason text" {
	_seed_held_via_promote 01M33440PGTWP4QMMG1BVA52DR
	run librarian_cli lessons veto 01M33440PGTWP4QMMG1BVA52DR "overreaches badly" "$PROJECT_REPO"
	[ "$status" -eq 0 ] || return 1
	_events librarian.lesson.vetoed | jq -e '
		.payload == {lesson_id: "01M33440PGTWP4QMMG1BVA52DR", reason_given: true}' >/dev/null || return 1
	! grep -q "overreaches badly" "$EVENTS_LOG"
}

@test "a veto without a reason emits reason_given false" {
	_seed_held_via_promote 01M33440PGTWP4QMMG1BVA52DR
	cd "$PROJECT_REPO"
	run librarian_cli lessons veto 01M33440PGTWP4QMMG1BVA52DR
	[ "$status" -eq 0 ] || return 1
	_events librarian.lesson.vetoed | jq -e '.payload.reason_given == false' >/dev/null
}

@test "a refused veto emits nothing" {
	run librarian_cli lessons veto 01M33440PGTWP4QMMG1BVA52DR "why" "$PROJECT_REPO"
	[ "$status" -eq 1 ] || return 1
	[ "$(_count librarian.lesson.vetoed)" = "0" ]
}

# --- librarian.autojury.complete --------------------------------------------

@test "the stage summary counts each outcome and what the cap deferred" {
	_stub_claude
	_enable_auto 1
	_seed_parked "" 01M3B87J7046SJE5BECNMP670K >/dev/null
	_seed_parked "" 01M3B87J7046SJE5BECNMP671Z >/dev/null
	_seed_parked refuse-with-reason 01M3B87J7046SJE5BECNMP672Z >/dev/null
	_seed_parked say-nothing 01M3B87J7046SJE5BECNMP673Z >/dev/null
	run librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$status" -eq 0 ] || return 1
	[ "$(_count librarian.autojury.complete)" = "1" ] || return 1
	_events librarian.autojury.complete | jq -e '
		.payload.asserted == 2 and .payload.refused == 1 and .payload.unavailable == 1
		and .payload.juried == 1 and .payload.deferred_by_cap == 1
		and .payload.duration_ms >= 0' >/dev/null
}

@test "a human-confirmed lesson is neither juried nor counted as deferred" {
	_stub_claude
	_enable_auto 1
	id=$(_seed_parked)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	_events librarian.autojury.complete \
		| jq -e '.payload.juried == 0 and .payload.deferred_by_cap == 0' >/dev/null
}

@test "a disabled stage emits nothing at all" {
	_stub_claude
	_seed_parked >/dev/null
	run librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$status" -eq 0 ] || return 1
	[ "$(_count librarian.autojury.complete)" = "0" ] || return 1
	[ "$(_count librarian.lesson.asserted)" = "0" ]
}

@test "stage events carry the session the stage was given" {
	_stub_claude
	_enable_auto 1
	_seed_parked >/dev/null
	librarian_lesson_auto_stage "$PROJECT_KEY" "sess-worker-1"
	for t in librarian.lesson.asserted librarian.lesson.judged \
		librarian.lesson.promoted librarian.autojury.complete; do
		[ "$(_count "$t")" = "1" ] || return 1
		_events "$t" | jq -e '.session_id == "sess-worker-1"' >/dev/null || return 1
	done
}

# --- fail-soft --------------------------------------------------------------

@test "the pipeline still works when librarian_emit is not sourced" {
	unset -f librarian_emit
	_stub_claude
	_enable_auto 1
	id=$(_seed_parked)
	run librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$status" -eq 0 ] || return 1
	jq -e '.status == "approved"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null || return 1
	[ ! -s "$EVENTS_LOG" ]
}
