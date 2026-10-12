#!/usr/bin/env bats
#
# librarian.lesson.promoted (ONL-7, schema 2.28.0).
#
# librarian_lesson_promote emitted nothing at all before this, which is why
# onlooker's doctor has no write axis for librarian: STREAMS declares neither
# writeHooks nor writeEvents for it, so computeVerdict's write axis never opens.
# This event is that axis's prerequisite.
#
# The emit is tied to the STAMP, not to the terminal record. That is the
# function's own ordering guarantee read as a contract: the record lands first,
# promoted_at lands last, and a run that wrote the record but failed to stamp is
# the one state `lessons promote <id>` exists to reconcile. Emitting on the
# record would double-count that reconcile; emitting on the stamp makes the
# event exactly-once across it.

bats_require_minimum_version 1.5.0

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

	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-author-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-promote.sh"
	librarian_config_load "$PROJECT_REPO"

	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
	librarian_lesson_storage_init "$PROJECT_KEY"

	EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$EVENTS_LOG")"
	: >"$EVENTS_LOG"

	# Promotion must spend nothing.
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude was invoked but promotion must spend no tokens" >&2
exit 99
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_dir() { printf '%s' "$(librarian_lessons_dir "$PROJECT_KEY")"; }

# $1 = id, $2 = visibility, $3 = status, $4 = judges JSON, $5 = asserted_by
_seed_judged() {
	local id="$1" visibility="$2" status="$3" judges="$4"
	local asserted_by="${5:-human}"
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -n --arg id "$id" --arg v "$visibility" --arg s "$status" \
		--arg t "$now" --argjson j "$judges" --arg ab "$asserted_by" \
		'{ id: $id, artifact_id: ("art-" + $id), status: $s, visibility: $v,
		   asserted_by: $ab, confirmed_at: $t, judged_at: $t,
		   candidate: { claim: "Prefer jq -c for compact output",
		                rationale: "Readable diffs",
		                evidence: { resolution: "Applied and verified" },
		                applies_to: { stack: ["bash"],
		                              scope: { kind: "versioned", versions: ">=3.2" } } },
		   verdict: { rubric_id: "lesson-promotion", gate_policy: "majority",
		              score_threshold: 0.75, aggregate_score: 0.85,
		              passed: ($s == "approved"), reason: "gate_passed",
		              judges: $j } }' \
		> "$(_dir)/proposals/${id}.json"
}

_two_passing() {
	printf '%s' '[{"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.95}},{"judge_type":"adversarial","score":0.8,"passed":true,"criterion_scores":{"grounding":0.8,"scope_accuracy":0.8,"generality":0.8,"disclosure":0.95}}]'
}

_promoted_events() {
	grep '"event_type":"librarian.lesson.promoted"' "$EVENTS_LOG" 2>/dev/null || true
}

_promoted_count() {
	_promoted_events | wc -l | tr -d ' '
}

@test "the approved branch emits librarian.lesson.promoted with outcome approved" {
	_seed_judged "ok01" "org" "approved" "$(_two_passing)"
	run librarian_lesson_promote "$PROJECT_KEY" "ok01"
	[ "$status" -eq 0 ] || return 1

	[ "$(_promoted_count)" = "1" ] || return 1
	_promoted_events | jq -e '.payload.lesson_id == "ok01"' >/dev/null || return 1
	_promoted_events | jq -e '.payload.outcome == "approved"' >/dev/null || return 1
	_promoted_events | jq -e '.plugin == "librarian"' >/dev/null || return 1
	# duration_ms is required and minimum 0 in the payload schema.
	_promoted_events | jq -e '.payload.duration_ms | type == "number" and . >= 0' >/dev/null
}

@test "the rejected branch emits outcome rejected, not declined" {
	# declined.jsonl is the FILE a rejected lesson lands in; the status
	# vocabulary this function branches on is approved|rejected, and the payload
	# enum publishes those two. Emitting "declined" would fail validation.
	_seed_judged "rej01" "org" "rejected" "$(_two_passing)"
	run librarian_lesson_promote "$PROJECT_KEY" "rej01"
	[ "$status" -eq 0 ] || return 1

	[ "$(_promoted_count)" = "1" ] || return 1
	_promoted_events | jq -e '.payload.outcome == "rejected"' >/dev/null || return 1
	_promoted_events | jq -e '.payload.lesson_id == "rej01"' >/dev/null
}

@test "a held model-asserted lesson still emits approved" {
	# The held path writes to held/ instead of approved/ and stamps a veto
	# window, but it is the same approved outcome — a consumer counting writes
	# must not lose the ones awaiting their window.
	_seed_judged "held01" "org" "approved" "$(_two_passing)" "model"
	run librarian_lesson_promote "$PROJECT_KEY" "held01"
	[ "$status" -eq 0 ] || return 1

	[ "$(_promoted_count)" = "1" ] || return 1
	_promoted_events | jq -e '.payload.outcome == "approved"' >/dev/null
}

@test "an unresolvable lesson id emits nothing" {
	run librarian_lesson_promote "$PROJECT_KEY" "nope01"
	[ "$status" -eq 1 ] || return 1
	[ "$(_promoted_count)" = "0" ]
}

@test "a refusal on an unjudged lesson emits nothing" {
	# status confirmed: judged yet, so there is no terminal record to announce.
	_seed_judged "conf01" "org" "confirmed" "$(_two_passing)"
	run librarian_lesson_promote "$PROJECT_KEY" "conf01"
	[ "$status" -eq 1 ] || return 1
	[ "$(_promoted_count)" = "0" ]
}

@test "the already-promoted no-op emits nothing the second time" {
	# A reconcile loop is safe to run over everything, so the no-op success must
	# not re-announce a write that already happened. Exactly one event for two
	# calls is the assertion.
	_seed_judged "idem01" "org" "approved" "$(_two_passing)"
	librarian_lesson_promote "$PROJECT_KEY" "idem01"
	[ "$(_promoted_count)" = "1" ] || return 1

	run librarian_lesson_promote "$PROJECT_KEY" "idem01"
	[ "$status" -eq 0 ] || return 1
	[ "$(_promoted_count)" = "1" ]
}

@test "the emitted event is a schema-valid envelope" {
	# onlooker-schema.sh derives the validator from CLAUDE_PLUGIN_ROOT, which
	# this file repoints at the librarian plugin so librarian's own libs resolve
	# — and librarian does not vendor onlooker-event.mjs. Name the canonical one
	# directly rather than leaving the validator to resolve to a missing file,
	# where onlooker_validate_event returns 1 for the wrong reason.
	_ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
	[ -f "$_ONLOOKER_EVENT_JS" ] || return 1

	_seed_judged "valid01" "org" "approved" "$(_two_passing)"
	librarian_lesson_promote "$PROJECT_KEY" "valid01"

	_promoted_events | onlooker_validate_event
}

@test "the event carries the project dimension when the resolver exported it" {
	# The envelope half of ONL-129. librarian_emit runs node in a command
	# substitution with an env prefix that does not unset these, so an exported
	# value reaches the child.
	onlooker_project_resolve "$PROJECT_REPO"
	[ -n "$ONLOOKER_PROJECT_KEY" ] || return 1

	_seed_judged "proj01" "org" "approved" "$(_two_passing)"
	librarian_lesson_promote "$PROJECT_KEY" "proj01"

	_promoted_events | jq -e --arg k "$ONLOOKER_PROJECT_KEY" '.project == $k' >/dev/null || return 1
	_promoted_events | jq -e '.project_basis == "remote"' >/dev/null
}

@test "promotion still succeeds when librarian_emit is not sourced" {
	# The promote lib's dependency contract is storage + author-key. A caller
	# that never sourced librarian-emit.sh must not get a "command not found"
	# where it used to get a clean promotion -- librarian-lesson-promote.bats
	# itself is such a caller.
	unset -f librarian_emit
	_seed_judged "noemit01" "org" "approved" "$(_two_passing)"

	run librarian_lesson_promote "$PROJECT_KEY" "noemit01"
	[ "$status" -eq 0 ] || return 1
	[ -f "$(_dir)/approved/noemit01.json" ] || return 1
	[ "$(_promoted_count)" = "0" ]
}
