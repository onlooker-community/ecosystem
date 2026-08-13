#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git

	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-author-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-promote.sh"
	librarian_config_load "$PROJECT_REPO"

	PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
	librarian_lesson_storage_init "$PROJECT_KEY"

	# Promotion must spend nothing. Any invocation of this stub is a failure.
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

# A judged proposal. $1 = id, $2 = visibility, $3 = status,
# $4 = verdict judges JSON array.
_seed_judged() {
	local id="$1" visibility="$2" status="$3" judges="$4"
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -n --arg id "$id" --arg v "$visibility" --arg s "$status" \
		--arg t "$now" --argjson j "$judges" \
		'{ id: $id, artifact_id: "art-\($id)", status: $s, visibility: $v,
		   confirmed_at: $t, judged_at: $t,
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
	printf '%s' '[{"judge_type":"standard","score":0.9,"passed":true},{"judge_type":"adversarial","score":0.8,"passed":true}]'
}
_split() {
	printf '%s' '[{"judge_type":"standard","score":0.95,"passed":true},{"judge_type":"adversarial","score":0.75,"passed":false}]'
}

@test "an approved org lesson becomes a pool entry with exactly ZLesson's keys" {
	# ZLesson is a z.strictObject: an extra key fails ingest as surely as a
	# missing one, so the key SET is the assertion, not a spot-check.
	_seed_judged "org01" "org" "approved" "$(_two_passing)"
	run librarian_lesson_promote "$PROJECT_KEY" "org01"
	[ "$status" -eq 0 ]

	local keys
	keys=$(jq -r 'keys_unsorted | sort | join(" ")' "$(_dir)/approved/org01.json")
	[ "$keys" = "applies_to author_key claim consensus evidence id promoted_at rationale schema_version source status superseded_by visibility" ]
}

@test "the pool entry carries the mapped source and a derived consensus" {
	_seed_judged "org02" "org" "approved" "$(_two_passing)"
	librarian_lesson_promote "$PROJECT_KEY" "org02"

	local e
	e=$(cat "$(_dir)/approved/org02.json")
	[ "$(printf '%s' "$e" | jq -r '.source')" = "org" ]
	[ "$(printf '%s' "$e" | jq -r '.visibility')" = "org" ]
	[ "$(printf '%s' "$e" | jq -r '.schema_version')" = "2" ]
	[ "$(printf '%s' "$e" | jq -r '.status')" = "active" ]
	[ "$(printf '%s' "$e" | jq -r '.superseded_by')" = "null" ]
	[ "$(printf '%s' "$e" | jq -r '.consensus.judges')" = "2" ]
	[ "$(printf '%s' "$e" | jq -r '.consensus.agreed')" = "2" ]
	[ "$(printf '%s' "$e" | jq -r '.author_key')" != "null" ]
	printf '%s' "$e" | jq -e '.author_key | test("^[0-9a-f]{32}$")' >/dev/null || return 1
}

@test "a private lesson maps to source local with zero judges" {
	# Deliberately NOT ingest-valid: ZConsensus requires judges >= 1. A
	# private lesson never syncs, so it never reaches the validator. Do not
	# "fix" this by synthesizing a jury that never sat.
	_seed_judged "priv01" "private" "approved" '[]'
	run librarian_lesson_promote "$PROJECT_KEY" "priv01"
	[ "$status" -eq 0 ]

	local e
	e=$(cat "$(_dir)/approved/priv01.json")
	[ "$(printf '%s' "$e" | jq -r '.source')" = "local" ]
	[ "$(printf '%s' "$e" | jq -r '.visibility')" = "private" ]
	[ "$(printf '%s' "$e" | jq -r '.consensus.judges')" = "0" ]
	[ "$(printf '%s' "$e" | jq -r '.consensus.agreed')" = "0" ]
}

@test "a public lesson maps to source public" {
	_seed_judged "pub01" "public" "approved" "$(_two_passing)"
	librarian_lesson_promote "$PROJECT_KEY" "pub01"
	[ "$(jq -r '.source' "$(_dir)/approved/pub01.json")" = "public" ]
}

@test "agreed never exceeds judges" {
	# The contract's own ingest rule, which its schema deliberately cannot
	# express (it would need .refine(), which z.toJSONSchema drops).
	_seed_judged "cnt01" "org" "approved" "$(_split)"
	librarian_lesson_promote "$PROJECT_KEY" "cnt01"

	local e
	e=$(cat "$(_dir)/approved/cnt01.json")
	[ "$(printf '%s' "$e" | jq -r '.consensus.judges')" = "2" ]
	[ "$(printf '%s' "$e" | jq -r '.consensus.agreed')" = "1" ]
	printf '%s' "$e" | jq -e '.consensus.agreed <= .consensus.judges' >/dev/null || return 1
}

@test "a rejected lesson writes a declined row with a NESTED verdict and no pool entry" {
	# .verdict must be an object, not a serialized string. A --arg/--argjson
	# mistake produces a row that looks right and is unusable to a consumer,
	# so assert by indexing into it rather than matching a substring.
	_seed_judged "rej01" "public" "rejected" "$(_split)"
	run librarian_lesson_promote "$PROJECT_KEY" "rej01"
	[ "$status" -eq 0 ]

	[ ! -f "$(_dir)/approved/rej01.json" ]
	local row
	row=$(grep 'art-rej01' "$(_dir)/declined.jsonl")
	[ "$(printf '%s' "$row" | jq -r '.artifact_id')" = "art-rej01" ]
	[ "$(printf '%s' "$row" | jq -r '.verdict | type')" = "object" ]
	[ "$(printf '%s' "$row" | jq -r '.verdict.judges | length')" = "2" ]
	[ "$(printf '%s' "$row" | jq -r '.verdict.rubric_id')" = "lesson-promotion" ]
}

@test "a stage-5 style decline still writes cleanly and has no verdict key" {
	librarian_lesson_append_declined "$PROJECT_KEY" "art-t5" "transform_invalid" "malformed JSON"
	local row
	row=$(grep 'art-t5' "$(_dir)/declined.jsonl")
	[ "$(printf '%s' "$row" | jq -r '.reason')" = "transform_invalid" ]
	[ "$(printf '%s' "$row" | jq -r 'has("verdict")')" = "false" ]
}

@test "promoting twice leaves one pool entry with an unchanged promoted_at" {
	_seed_judged "idem01" "org" "approved" "$(_two_passing)"
	librarian_lesson_promote "$PROJECT_KEY" "idem01"
	local first
	first=$(cat "$(_dir)/approved/idem01.json")

	run librarian_lesson_promote "$PROJECT_KEY" "idem01"
	[ "$status" -eq 0 ]
	[ "$(cat "$(_dir)/approved/idem01.json")" = "$first" ]
	[ "$(ls "$(_dir)/approved" | grep -c idem01)" -eq 1 ]
}

@test "promotion is refused before the lesson has been judged" {
	_seed_judged "conf01" "org" "confirmed" '[]'
	run --separate-stderr librarian_lesson_promote "$PROJECT_KEY" "conf01"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	[[ "$stderr" == *"not been judged"* ]] || return 1
	[ ! -f "$(_dir)/approved/conf01.json" ]
}

@test "promotion is refused from a passed lesson, naming the status" {
	_seed_judged "pass01" "org" "passed" '[]'
	run --separate-stderr librarian_lesson_promote "$PROJECT_KEY" "pass01"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"passed"* ]] || return 1
}

@test "a failing author_key leaves nothing written and the lesson still approved" {
	# THE reconcile property. Promotion fails for reasons judging does not —
	# a malformed secret, absent node, a full disk — and the lesson must stay
	# exactly where a standalone re-run can pick it up.
	_seed_judged "ak01" "org" "approved" "$(_two_passing)"
	local secret_path
	secret_path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$secret_path")"
	printf 'not-a-valid-secret\n' > "$secret_path"
	chmod 0600 "$secret_path"

	run --separate-stderr librarian_lesson_promote "$PROJECT_KEY" "ak01"
	[ "$status" -ne 0 ]
	[ ! -f "$(_dir)/approved/ak01.json" ]
	[ "$(jq -r 'has("promoted_at")' "$(_dir)/proposals/ak01.json")" = "false" ]
	[ "$(jq -r '.status' "$(_dir)/proposals/ak01.json")" = "approved" ]
}

@test "the proposal survives promotion and carries promoted_at" {
	_seed_judged "keep01" "org" "approved" "$(_two_passing)"
	librarian_lesson_promote "$PROJECT_KEY" "keep01"
	[ -f "$(_dir)/proposals/keep01.json" ]
	[ "$(jq -r '.status' "$(_dir)/proposals/keep01.json")" = "approved" ]
	printf '%s' "$(jq -r '.promoted_at' "$(_dir)/proposals/keep01.json")" \
		| grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' || return 1
	# The per-judge detail is why the proposal is kept: the pool entry has
	# only consensus counts.
	[ "$(jq -r '.verdict.judges | length' "$(_dir)/proposals/keep01.json")" = "2" ]
}

@test "librarian_lesson_seen reports the artifact handled after either path" {
	_seed_judged "seen01" "org" "approved" "$(_two_passing)"
	librarian_lesson_promote "$PROJECT_KEY" "seen01"
	run librarian_lesson_seen "$PROJECT_KEY" "art-seen01"
	[ "$status" -eq 0 ]

	_seed_judged "seen02" "public" "rejected" "$(_split)"
	librarian_lesson_promote "$PROJECT_KEY" "seen02"
	run librarian_lesson_seen "$PROJECT_KEY" "art-seen02"
	[ "$status" -eq 0 ]
}

@test "a missing lesson is refused" {
	run --separate-stderr librarian_lesson_promote "$PROJECT_KEY" "nope01"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"not found"* ]] || return 1
}
