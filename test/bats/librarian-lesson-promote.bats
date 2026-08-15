#!/usr/bin/env bats

# `run --separate-stderr` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

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
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-review.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-rubric.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-judge.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-cli.sh"
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

# Both fixtures carry criterion_scores covering the superset of the org and
# public rubrics. They are load-bearing, not decoration: librarian_lesson_judge
# refuses a panel that leaves a floored criterion unscored, so without them
# these panels are UNJUDGED (2) and never reach the promotion path under test.
# disclosure sits at 0.95 against its 0.9 floor, which is now a panel MINIMUM.
_two_passing() {
	printf '%s' '[{"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.95}},{"judge_type":"adversarial","score":0.8,"passed":true,"criterion_scores":{"grounding":0.8,"scope_accuracy":0.8,"generality":0.8,"disclosure":0.95}}]'
}
_split() {
	printf '%s' '[{"judge_type":"standard","score":0.95,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.95,"disclosure":0.95}},{"judge_type":"adversarial","score":0.75,"passed":false,"criterion_scores":{"grounding":0.75,"scope_accuracy":0.75,"generality":0.75,"disclosure":0.95}}]'
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

@test "a promoted rejection is still seen after its proposal is deleted" {
	# The proposal is deleted after promoting, on purpose. librarian_lesson_seen
	# scans proposals/ unconditionally of status, so leaving it in place would
	# let this test pass even if promote wrote nothing at all. The property
	# under test is that the TERMINAL RECORD — the declined row — is what
	# marks the artifact handled once its proposal ages out, not the
	# (now-gone) proposal file.
	#
	# There is deliberately NO approved-path equivalent of this test. A
	# ZLesson pool entry carries no artifact_id (strict key set — see the
	# promote lib's key-set comment), so librarian_lesson_seen's approved/
	# scan can never match one; "promote, delete the proposal, assert seen"
	# would pass or fail based on proposal presence alone, never on anything
	# promote itself wrote — the same false-coverage shape this test replaced.
	# ecosystem-d0m tracks the gap. Don't add that assertion back without
	# closing it first: it will pass while proving nothing.
	_seed_judged "seen02" "public" "rejected" "$(_split)"
	librarian_lesson_promote "$PROJECT_KEY" "seen02"
	rm -f "$(_dir)/proposals/seen02.json"
	run librarian_lesson_seen "$PROJECT_KEY" "art-seen02"
	[ "$status" -eq 0 ]
}

@test "promoting a rejected lesson twice writes exactly one declined row" {
	# Mirrors test 8's shape for the approved path. A plain double-promote
	# never reaches the guard under test: a first call that succeeds
	# outright already stamps promoted_at, and the second call short-circuits
	# on that before ever looking at declined.jsonl. The guard only matters
	# when the FIRST call's stamp fails AFTER the declined row has already
	# landed — proposals/ turning read-only mid-promote is a plausible way
	# to hit that, and the same shape test 11 uses for the author_key case.
	_seed_judged "decl01" "public" "rejected" "$(_split)"

	chmod 0500 "$(_dir)/proposals"
	run --separate-stderr librarian_lesson_promote "$PROJECT_KEY" "decl01"
	chmod 0700 "$(_dir)/proposals"
	[ "$status" -ne 0 ]
	[ "$(jq -r 'has("promoted_at")' "$(_dir)/proposals/decl01.json")" = "false" ]
	[ "$(grep -c 'art-decl01' "$(_dir)/declined.jsonl")" -eq 1 ]
	# This is the one failure path that writes something (the declined row
	# above) before failing — the stderr message must say so, not return
	# silently, or this state is indistinguishable from "nothing written."
	[[ "$stderr" == *"terminal record written but promoted_at could not be stamped"* ]] || return 1

	# The standalone re-run — the exact path the ordering guarantee exists to
	# make safe.
	run librarian_lesson_promote "$PROJECT_KEY" "decl01"
	[ "$status" -eq 0 ]
	[ "$(grep -c 'art-decl01' "$(_dir)/declined.jsonl")" -eq 1 ]
}

@test "the pool entry guard leaves an existing entry untouched when the proposal isn't yet stamped" {
	# Mirrors test 14's shape for the approved path. The ordering guarantee
	# means the pool write can succeed and the stamp fail afterward, so a
	# standalone re-run must find that pool entry already present and skip
	# rewriting it. Nothing before this pins that: "promoting twice..." above
	# never reaches the pool_path guard at all — the earlier already-promoted
	# check (promoted_at present on the proposal) short-circuits first, since
	# a plain double-promote always stamps successfully on the first call.
	_seed_judged "pool01" "org" "approved" "$(_two_passing)"

	mkdir -p "$(_dir)/approved"
	printf '{"sentinel":"pre-existing pool entry"}' > "$(_dir)/approved/pool01.json"

	run librarian_lesson_promote "$PROJECT_KEY" "pool01"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.sentinel // empty' "$(_dir)/approved/pool01.json")" = "pre-existing pool entry" ]
}

@test "promotion self-heals a missing approved/ directory" {
	# Empty directories do not survive git, or tar/rsync without -d, so
	# approved/ can be legitimately absent even though proposals/ —
	# non-empty, holding this very lesson — is right there. Unlike
	# librarian_lesson_append_declined, promote did not call
	# librarian_lesson_storage_init; without it this lesson stayed stuck at
	# "cannot write the pool entry" forever.
	_seed_judged "heal01" "org" "approved" "$(_two_passing)"
	rm -rf "$(_dir)/approved"

	run librarian_lesson_promote "$PROJECT_KEY" "heal01"
	[ "$status" -eq 0 ]
	[ -f "$(_dir)/approved/heal01.json" ]
}

@test "a refusal before the approved branch creates no directory scaffolding" {
	# The self-heal above must not run ahead of every refusal path. A pure
	# refusal ("not judged yet," "not found," wrong status) has to write
	# NOTHING, per this function's own doc comment and the spec — and
	# mkdir -p is a write, even though it's idempotent and inert once made.
	# setup() already ran storage_init once, so start from zero prior
	# activity by removing approved/ again before seeding.
	_seed_judged "refuse01" "org" "confirmed" '[]'
	rm -rf "$(_dir)/approved"

	run librarian_lesson_promote "$PROJECT_KEY" "refuse01"
	[ "$status" -ne 0 ]
	[ ! -d "$(_dir)/approved" ]
}

@test "a missing lesson is refused" {
	run --separate-stderr librarian_lesson_promote "$PROJECT_KEY" "nope01"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"not found"* ]] || return 1
}

@test "lessons promote lands a pool entry through the CLI" {
	_seed_judged "cli01" "org" "approved" "$(_two_passing)"
	run librarian_cli lessons promote "cli01" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ -f "$(_dir)/approved/cli01.json" ]
	[[ "$output" == *"cli01"* ]] || return 1
}

@test "lessons promote requires a lesson id" {
	run librarian_cli lessons promote
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage:"* && "$output" == *"promote"* ]] || return 1
}

@test "lessons promote rejects an unknown flag" {
	_seed_judged "cli02" "org" "approved" "$(_two_passing)"
	run librarian_cli lessons promote "cli02" --force
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown option"* && "$output" == *"--force"* ]] || return 1
}

@test "lessons judge promotes automatically after recording a verdict" {
	# The ordinary path is one command: judge, record, promote.
	_seed_judged "auto01" "org" "confirmed" '[]'
	run librarian_cli lessons judge "auto01" "$(_two_passing)" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.status' "$(_dir)/proposals/auto01.json")" = "approved" ]
	[ -f "$(_dir)/approved/auto01.json" ]
}

@test "an unjudged candidate does not even attempt promotion" {
	# The judge returns 2 for UNJUDGED and writes nothing — but that alone
	# does not pin the wiring. librarian_lesson_promote independently refuses
	# a still-`confirmed` proposal ("has not been judged yet"), so a `2)` arm
	# that mistakenly calls it would land on the exact same empty state as a
	# `2)` arm that never calls it at all: same status, same missing pool
	# file. Shadow librarian_lesson_promote with a spy that records whether
	# it was invoked and delegates to the real implementation, so a call
	# wired into the `2)` arm is caught even though the call itself is a
	# no-op.
	_seed_judged "auto02" "org" "confirmed" '[]'

	local marker="${BATS_TEST_TMPDIR}/promote-invoked"
	eval "$(declare -f librarian_lesson_promote | sed '1s/^librarian_lesson_promote/_real_librarian_lesson_promote/')"
	librarian_lesson_promote() {
		: > "$marker"
		_real_librarian_lesson_promote "$@"
	}

	run librarian_cli lessons judge "auto02" '[{"judge_type":"standard","score":"bad","passed":true}]' "$PROJECT_REPO"
	[ "$status" -eq 2 ]
	[ "$(jq -r '.status' "$(_dir)/proposals/auto02.json")" = "confirmed" ]
	[ ! -f "$(_dir)/approved/auto02.json" ]
	[ ! -f "$marker" ]
}

@test "a judge-walk promotion failure reports, does not undo the verdict, and reconciles" {
	# The other half of the reconcile property, exercised through the CLI's
	# judge verb rather than promote directly. A promotion failure inside the
	# automatic call must not undo the verdict the jury just recorded — the
	# lesson stays `approved`, unstamped, and the standalone `lessons
	# promote` verb is how it gets picked back up once the failure is fixed.
	# Same corruption Task 1's `ak01` test uses to fail librarian_author_key.
	_seed_judged "jwfail01" "org" "confirmed" '[]'

	local secret_path
	secret_path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$secret_path")"
	printf 'not-a-valid-secret\n' > "$secret_path"
	chmod 0600 "$secret_path"

	run librarian_cli lessons judge "jwfail01" "$(_two_passing)" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Lesson jwfail01 is now approved."* ]] || return 1
	[[ "$output" == *"Lesson jwfail01 was judged but not promoted; run \`lessons promote jwfail01\` to retry."* ]] || return 1
	[ ! -f "$(_dir)/approved/jwfail01.json" ]
	[ "$(jq -r '.status' "$(_dir)/proposals/jwfail01.json")" = "approved" ]
	[ "$(jq -r 'has("promoted_at")' "$(_dir)/proposals/jwfail01.json")" = "false" ]

	# Repair the secret and reconcile through the standalone verb — the
	# point of the whole design.
	openssl rand -hex 32 > "$secret_path"
	chmod 0600 "$secret_path"
	run librarian_cli lessons promote "jwfail01" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ -f "$(_dir)/approved/jwfail01.json" ]
}

_promote_refuses_shape() {
	# $1 = id, $2 = jq program mutating the seeded proposal, $3 = field name
	# the guard's stderr message must name — pins WHY the refusal happened,
	# not just THAT it happened, so a guard that fires on the right shape but
	# mislabels the field (or a check that's silently missing) still fails
	# this test. Matches the file's existing refusal-test pattern (empty
	# stdout + a specific stderr substring) rather than status/absence alone.
	#
	# Whole-token match, not substring: "id" is a substring of "candidate"
	# (c-a-n-d-id-a-t-e), so a bare *"$field"* glob would accept a message
	# naming candidate.claim for a null .id. Pull the guard's comma-joined
	# field list out of the message, strip spaces, and check exact
	# membership by delimiting both sides with commas.
	local id="$1" mutate="$2" field="$3"
	_seed_judged "$id" "org" "approved" "$(_two_passing)"
	local p
	p="$(_dir)/proposals/${id}.json"
	local tmp="${BATS_TEST_TMPDIR}/${id}.json"
	jq "$mutate" "$p" > "$tmp" && mv "$tmp" "$p"

	run --separate-stderr librarian_lesson_promote "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	[ ! -f "$(_dir)/approved/${id}.json" ]
	[ "$(jq -r 'has("promoted_at")' "$p")" = "false" ]

	local list
	list=$(printf '%s' "$stderr" | sed -n 's/.*bad or missing: \([^)]*\)).*/\1/p')
	[ -n "$list" ] || return 1
	printf ',%s,' "$(printf '%s' "$list" | tr -d ' ')" | grep -Fq ",${field}," || return 1
}

@test "a null judges array is refused, not read as a jury-less lesson" {
	# The worst shape: consensus {judges:0, agreed:0} is byte-identical to a
	# legitimate private entry, but carries source "org" — so unlike a private
	# entry it WILL sync, and then fail ingest on ZConsensus.judges >= 1.
	_promote_refuses_shape "mal01" '.verdict.judges = null' "verdict.judges"
}

@test "a judges object rather than an array is refused" {
	_promote_refuses_shape "mal02" '.verdict.judges = {"a":{"passed":true}}' "verdict.judges"
}

@test "a proposal missing its candidate is refused" {
	# Currently produces the exact 13 ZLesson keys with null claim/rationale/
	# evidence/applies_to — it passes the key-set test while being empty.
	_promote_refuses_shape "mal03" 'del(.candidate)' "candidate.claim"
}

@test "a proposal missing judged_at is refused" {
	_promote_refuses_shape "mal04" 'del(.judged_at)' "judged_at"
}

@test "a proposal with a null id is refused" {
	# .id is read by the entry mapping (id: $p.id) same as candidate/judged_at/
	# verdict.judges — a null id promotes to a pool entry with "id": null,
	# passing the key-set check while being exactly the kind of well-formed-
	# but-wrong entry this guard exists to prevent.
	_promote_refuses_shape "mal05" '.id = null' "id"
}

@test "a well-formed proposal still promotes" {
	# The guard must not reject anything the pipeline actually produces.
	_seed_judged "ok01" "org" "approved" "$(_two_passing)"
	run librarian_lesson_promote "$PROJECT_KEY" "ok01"
	[ "$status" -eq 0 ]
	[ -f "$(_dir)/approved/ok01.json" ]
}

@test "an approved promotion succeeds when sourced through exactly SKILL.md's source list" {
	# The runtime's ONLY entry point for the lessons CLI is SKILL.md's source
	# block — not this file's own setup(), which sources librarian-author-key.sh
	# itself and so could never catch a missing dependency in the shipped list.
	# Parse the `source` lines straight out of SKILL.md (never hand-copy them)
	# and drive one promotion in a subshell seeded with only those, so a future
	# lib gaining an undeclared dependency fails THIS test instead of shipping
	# with an inert runtime.
	local skill="${PLUGIN_ROOT}/skills/librarian/SKILL.md"
	[ -f "$skill" ]

	_seed_judged "skill01" "org" "approved" "$(_two_passing)"

	local script="${BATS_TEST_TMPDIR}/drive-skill-sources.sh"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'set -uo pipefail\n'
		# Mirrors SKILL.md's own two-line preamble (unchanged by this branch):
		# librarian-config.sh sources a sibling by the bare $PLUGIN_ROOT
		# variable, not $CLAUDE_PLUGIN_ROOT, so both must be set the same way
		# the skill's bash block sets them, in the same shell as the sources
		# below. This is fixed boilerplate, not "the source list" itself —
		# only the `source` lines that follow are parsed out of SKILL.md.
		printf 'PLUGIN_ROOT=%q\n' "$PLUGIN_ROOT"
		printf 'export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"\n'
		grep -E '^source "\$CLAUDE_PLUGIN_ROOT/' "$skill"
		printf 'librarian_lesson_promote %q %q\n' "$PROJECT_KEY" "skill01"
	} > "$script"

	run bash "$script"
	[ "$status" -eq 0 ]
	[ -f "$(_dir)/approved/skill01.json" ]
}
