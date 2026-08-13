# Approved Pool and Declined Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a judged proposal into its terminal record — a `ZLesson`-shaped pool entry awaiting sync, or a row in the declined ledger.

**Architecture:** One new lib function plus a small extension to an existing one. The terminal record lands first, then a `promoted_at` stamp on the proposal makes the operation detectably done. The `lessons judge` CLI calls it automatically; it is also runnable standalone to reconcile.

**Tech Stack:** bash (macOS bash 3.2 compatible), `jq`, bats.

## Global Constraints

- **Write order is load-bearing.** The terminal record (pool entry or declined row) lands **before** `promoted_at` is stamped. Reversed, a stamp followed by a failed write leaves the lesson marked done, present nowhere, and invisible to a reconcile that keys on the stamp's absence.
- **Both writes are atomic** — temp file then `mv`. `ecosystem-a3b` is open against three existing `printf > path` sites in this plugin; do not add more. Do not fix the existing three either — that is a3b's branch.
- **`ZLesson` is a `z.strictObject`.** The pool entry's key set must be exactly: `applies_to author_key claim consensus evidence id promoted_at rationale schema_version source status superseded_by visibility`. An extra key fails ingest as surely as a missing one.
- **`source` is not `visibility`.** `private` → **`local`**, `org` → `org`, `public` → `public`. Emitting `private` fails ingest.
- A `private` entry has `consensus.judges: 0` and is deliberately **not** ingest-valid. Do not synthesize a jury to make it validate.
- Failure returns non-zero, writes **nothing**, and leaves the proposal `approved` without `promoted_at`, with a reason on stderr.
- Already promoted is a **no-op success**, not an error.
- Runtime artifacts under `$ONLOOKER_DIR`; never a hardcoded `~/.onlooker`.
- No event emission. `@onlooker-community/schema` 2.11.0 registers no `librarian.lesson.*` and the emitter exits 1 on an unknown type.
- Bash 3.2: no associative arrays, no `${var^^}`, no `mapfile`.
- **bats runs under macOS system bash 3.2, where a failing NON-FINAL `[[ ]]` does NOT fail the test.** Every non-final `[[ ]]` needs `|| return 1`; single-bracket `[ ]` gates on its own.
- **A test asserting "nothing on stdout" alongside a required stderr reason MUST use `run --separate-stderr`** — plain `run` merges them, and the assertion becomes unsatisfiable by any correct implementation. This defect has already cost two fix rounds on prior branches.
- Assert on messages, not just exit codes, wherever a test asserts a refusal.
- American English. Commit via the `/commit` contract: `<type>(<scope>): <subject> :emoji:`, subject ≤72 chars including the emoji, why-focused body.

## File Structure

| File | Responsibility |
|---|---|
| `plugins/librarian/scripts/lib/librarian-lesson-storage.sh` | **Modify.** Extend `librarian_lesson_append_declined` with an optional `verdict`. |
| `plugins/librarian/scripts/lib/librarian-lesson-promote.sh` | **Create.** `librarian_lesson_promote`. |
| `plugins/librarian/scripts/lib/librarian-cli.sh` | **Modify** (Task 2). Add `lessons promote`; call promote from `lessons judge`. |
| `plugins/librarian/skills/librarian/SKILL.md` | **Modify** (Task 2). Source the new lib; describe promotion in the judge walk. |
| `test/bats/librarian-lesson-promote.bats` | **Create.** |

---

### Task 1: Promote a judged proposal

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-storage.sh`
- Create: `plugins/librarian/scripts/lib/librarian-lesson-promote.sh`
- Test: `test/bats/librarian-lesson-promote.bats`

**Interfaces:**
- Consumes: `librarian_lessons_dir <key>`, `librarian_lesson_storage_init <key>` (storage); `librarian_author_key <visibility>` (author-key lib).
- Produces:
  - `librarian_lesson_append_declined <key> <artifact_id> <reason> [detail] [verdict_json]` — gains an optional 5th argument.
  - `librarian_lesson_promote <key> <lesson_id>` → 0 on success (including the already-promoted no-op), 1 on refusal or failure.

- [ ] **Step 1: Write the failing tests**

Create `test/bats/librarian-lesson-promote.bats`:

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/librarian-lesson-promote.bats`
Expected: every test FAILS — the lib does not exist, so `source` in `setup()` errors.

- [ ] **Step 3: Extend `librarian_lesson_append_declined`**

In `plugins/librarian/scripts/lib/librarian-lesson-storage.sh`, add an optional
5th argument. Keep the two-branch shape rather than folding it — gating
`--argjson` behind a non-empty check keeps "absent" structural, so `--argjson`
never receives an empty string:

```bash
# Usage: librarian_lesson_append_declined <key> <artifact_id> <reason> [detail] [verdict_json]
#
# `verdict` is emitted with --argjson so it lands as a nested object, not a
# serialized string: consumers read .verdict.judges[].score directly. Rows
# written by the transform have no verdict and simply lack the key — a format
# failure has no jury.
librarian_lesson_append_declined() {
	local key="$1"
	local artifact_id="$2"
	local reason="$3"
	local detail="${4:-}"
	local verdict="${5:-}"
	[[ -z "$key" || -z "$artifact_id" || -z "$reason" ]] && return 1

	librarian_lesson_storage_init "$key" || return 1

	local now line
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	if [[ -n "$verdict" ]]; then
		line=$(jq -cn \
			--arg artifact_id "$artifact_id" \
			--arg reason "$reason" \
			--arg detail "$detail" \
			--arg at "$now" \
			--argjson verdict "$verdict" \
			'{
				artifact_id: $artifact_id,
				reason: $reason,
				detail: (if $detail == "" then null else $detail end),
				declined_at: $at,
				verdict: $verdict
			}') || return 1
	else
		line=$(jq -cn \
			--arg artifact_id "$artifact_id" \
			--arg reason "$reason" \
			--arg detail "$detail" \
			--arg at "$now" \
			'{
				artifact_id: $artifact_id,
				reason: $reason,
				detail: (if $detail == "" then null else $detail end),
				declined_at: $at
			}') || return 1
	fi

	printf '%s\n' "$line" >> "$(librarian_lessons_dir "$key")/declined.jsonl"
}
```

- [ ] **Step 4: Write the promote lib**

Create `plugins/librarian/scripts/lib/librarian-lesson-promote.sh`:

```bash
#!/usr/bin/env bash
# Terminal state for the lesson-promotion pipeline.
#
# A judged proposal becomes either a ZLesson-shaped pool entry awaiting sync,
# or a row in the declined ledger. Nothing crosses the network — the sync
# service that drains the pool does not exist yet.
#
# Requires librarian-lesson-storage.sh and librarian-author-key.sh.
#
# Exposes:
#   librarian_lesson_promote <key> <lesson_id>

# Map a lesson's visibility to the contract's `source` enum.
#
# NOT a rename: ZSource is local|org|public while visibility is
# private|org|public. `private` maps to `local` — the tier that never leaves
# this machine maps to the source meaning "not from anywhere else". Emitting
# "private" would fail ingest.
_librarian_lesson_source_for_visibility() {
	case "${1:-}" in
		private) printf 'local' ;;
		org)     printf 'org' ;;
		public)  printf 'public' ;;
		*)       return 1 ;;
	esac
	return 0
}

# Write a file atomically: temp in the same directory, then mv.
#
# ecosystem-a3b is open against three existing `printf > path` sites in this
# plugin, each of which truncates before writing. These are new sites; adding
# a fourth instance of a known bug would be a choice, not an inheritance.
_librarian_lesson_write_atomic() {
	local path="$1"
	local content="$2"
	local tmp
	tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || return 1
	printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
	mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Promote one judged proposal to its terminal record.
#
# Returns 0 on success, including the already-promoted no-op. Returns 1 on
# refusal or failure, having written NOTHING — the proposal stays `approved`
# without `promoted_at`, which is the state a standalone re-run resolves.
#
# Ordering is load-bearing: the terminal record lands BEFORE the stamp. A
# stamp followed by a failed write would leave the lesson marked done, present
# nowhere, and invisible to a reconcile that keys on the stamp's absence.
#
# Usage: librarian_lesson_promote <key> <lesson_id>
librarian_lesson_promote() {
	local key="$1"
	local lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	local dir path
	dir="$(librarian_lessons_dir "$key")"
	path="${dir}/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	# Already promoted: a no-op success, so a reconcile loop is safe to run
	# over everything. Same precedent as unconfirm on a pending lesson.
	if [[ "$(jq -r 'has("promoted_at")' "$path" 2>/dev/null)" == "true" ]]; then
		return 0
	fi

	local current_status visibility
	current_status=$(jq -r '.status // ""' "$path" 2>/dev/null)
	visibility=$(jq -r '.visibility // ""' "$path" 2>/dev/null)

	case "$current_status" in
		approved|rejected) ;;
		confirmed)
			printf 'Lesson %s has not been judged yet; nothing to promote.\n' "$lesson_id" >&2
			return 1
			;;
		*)
			printf 'Lesson %s cannot be promoted from status: %s\n' "$lesson_id" "$current_status" >&2
			return 1
			;;
	esac

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	if [[ "$current_status" == "approved" ]]; then
		local source author_key entry pool_path
		source=$(_librarian_lesson_source_for_visibility "$visibility") || {
			printf 'Lesson %s has an unrecognized visibility: %s\n' "$lesson_id" "$visibility" >&2
			return 1
		}
		author_key=$(librarian_author_key "$visibility") || {
			printf 'Lesson %s: cannot derive an author key; nothing written.\n' "$lesson_id" >&2
			return 1
		}

		# Exactly ZLesson's key set — it is a strictObject, so an extra key
		# fails ingest as surely as a missing one. A private entry gets
		# judges: 0 and is deliberately not ingest-valid; it never syncs.
		entry=$(jq -cn \
			--argjson p "$(cat "$path")" \
			--arg ak "$author_key" \
			--arg src "$source" \
			--arg now "$now" \
			'{
				id: $p.id,
				schema_version: 2,
				claim: $p.candidate.claim,
				rationale: $p.candidate.rationale,
				evidence: $p.candidate.evidence,
				applies_to: $p.candidate.applies_to,
				visibility: $p.visibility,
				consensus: {
					judges: (($p.verdict.judges // []) | length),
					agreed: ([($p.verdict.judges // [])[] | select(.passed == true)] | length),
					decided_at: $p.judged_at
				},
				status: "active",
				superseded_by: null,
				source: $src,
				author_key: $ak,
				promoted_at: $now
			}' 2>/dev/null) || {
			printf 'Lesson %s: cannot build a pool entry.\n' "$lesson_id" >&2
			return 1
		}

		pool_path="${dir}/approved/${lesson_id}.json"
		if [[ ! -f "$pool_path" ]]; then
			_librarian_lesson_write_atomic "$pool_path" "$entry" || {
				printf 'Lesson %s: cannot write the pool entry.\n' "$lesson_id" >&2
				return 1
			}
		fi
	else
		local artifact_id reason verdict
		artifact_id=$(jq -r '.artifact_id // ""' "$path" 2>/dev/null)
		reason=$(jq -r '.verdict.reason // "rejected"' "$path" 2>/dev/null)
		verdict=$(jq -c '.verdict // {}' "$path" 2>/dev/null)
		librarian_lesson_append_declined "$key" "$artifact_id" "$reason" "" "$verdict" || {
			printf 'Lesson %s: cannot append to the declined ledger.\n' "$lesson_id" >&2
			return 1
		}
	fi

	# Stamp LAST. See the ordering note above.
	local updated
	updated=$(jq --arg t "$now" '.promoted_at = $t' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	_librarian_lesson_write_atomic "$path" "$updated"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/bats/librarian-lesson-promote.bats`
Expected: PASS, 14/14.

- [ ] **Step 6: Prove the three load-bearing guards discriminate**

In a throwaway `git worktree` only — never the shared working tree. Report each
result separately; if any leaves the suite green, say so plainly.

```bash
git worktree add /tmp/ap-verify HEAD
#  (a) change the private mapping from "local" to "private"
#      Expected: "a private lesson maps to source local" FAILS
#  (b) move the promoted_at stamp BEFORE the pool write
#      Expected: "a failing author_key leaves nothing written" FAILS
#  (c) pass the verdict with --arg instead of --argjson
#      Expected: "a rejected lesson writes a declined row with a NESTED
#      verdict" FAILS on the `.verdict | type` assertion
git worktree remove --force /tmp/ap-verify
```

- [ ] **Step 7: Lint and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-promote.sh
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-storage.sh
git add plugins/librarian/scripts/lib/librarian-lesson-promote.sh \
        plugins/librarian/scripts/lib/librarian-lesson-storage.sh \
        test/bats/librarian-lesson-promote.bats
```

Read each exit code from `$?` directly — never through a pipe.

Commit subject: `feat(librarian): land a judged lesson in its terminal home :package:`

---

### Task 2: The CLI surface and the walk

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-cli.sh`
- Modify: `plugins/librarian/skills/librarian/SKILL.md`
- Test: `test/bats/librarian-lesson-promote.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_promote <key> <lesson_id>` (Task 1), returning 0 on success including the already-promoted no-op, 1 on refusal or failure.
- Produces: `librarian_cli lessons promote <id> [cwd]`, and promotion wired into `lessons judge`.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-promote.bats`. Add to `setup()`:

```bash
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-review.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-rubric.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-judge.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-cli.sh"
```

```bash
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

@test "an unjudged candidate is neither recorded nor promoted" {
	# The judge returns 2 for UNJUDGED and writes nothing; promotion must not
	# run behind it and invent a terminal state for a lesson with no verdict.
	_seed_judged "auto02" "org" "confirmed" '[]'
	run librarian_cli lessons judge "auto02" '[{"judge_type":"standard","score":"bad","passed":true}]' "$PROJECT_REPO"
	[ "$status" -eq 2 ]
	[ "$(jq -r '.status' "$(_dir)/proposals/auto02.json")" = "confirmed" ]
	[ ! -f "$(_dir)/approved/auto02.json" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/librarian-lesson-promote.bats`
Expected: the five new tests FAIL — `promote` is an unknown lessons action.

- [ ] **Step 3: Add the CLI verb**

Add to `librarian-cli.sh`, matching the sibling verbs' shape:

```bash
# Usage: librarian_cli_lessons_promote <lesson_id> [cwd]
#
# Runnable standalone on purpose: promotion fails for reasons judging does not
# — a malformed author secret, absent node, a full disk — and a standalone run
# is how a correctly-judged, not-yet-promoted lesson gets reconciled.
librarian_cli_lessons_promote() {
	local lesson_id="" cwd=""
	local positional=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--*)
				printf 'unknown option: %s\n' "$1" >&2
				return 1
				;;
			*)
				case "$positional" in
					0) lesson_id="$1" ;;
					*) cwd="$1" ;;
				esac
				positional=$((positional + 1))
				shift
				;;
		esac
	done

	[[ -z "$lesson_id" ]] && { printf 'usage: librarian_cli lessons promote <lesson_id> [cwd]\n'; return 1; }

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	librarian_lesson_promote "$key" "$lesson_id" || return 1
	printf 'Lesson %s promoted.\n' "$lesson_id"
}
```

Register it in `librarian_cli_lessons`'s `case`, after `judge`:

```bash
		promote) librarian_cli_lessons_promote "$@" ;;
```

- [ ] **Step 4: Wire promotion into the judge verb**

In `librarian_cli_lessons_judge`, inside the `case "$rc"` arm for `0` only —
**not** for `2`. An unjudged candidate has no verdict, and promoting behind it
would invent a terminal state for a lesson the jury never decided:

```bash
		0)
			printf 'Lesson %s is now %s.\n' "$lesson_id" \
				"$(jq -r '.status' "$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json")"
			# Promotion failing does not undo a correct verdict: report it and
			# leave the lesson promotable by a standalone `lessons promote`.
			librarian_lesson_promote "$key" "$lesson_id" \
				|| printf 'Lesson %s was judged but not promoted; run `lessons promote %s` to retry.\n' \
					"$lesson_id" "$lesson_id"
			;;
```

Source `librarian-lesson-promote.sh` alongside the existing lesson libs in
`librarian-cli.sh`'s header comment list — that file deliberately sources
nothing itself; its callers do.

- [ ] **Step 5: Update SKILL.md**

Add `source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-promote.sh"`
to the existing source block, **before** the `librarian-cli.sh` line.

In the `lessons judge` walk, note that recording a verdict also promotes, and
that a lesson reported as judged-but-not-promoted should be retried with
`librarian_cli lessons promote <id>` rather than re-judged — re-judging would
spend tokens again for a verdict that already exists.

- [ ] **Step 6: Run the tests and the full suite**

```bash
bats test/bats/librarian-lesson-promote.bats
bats test/bats/librarian-lesson-judge.bats
bats test/bats/librarian-cli.bats
npm run lint:check
npm run test:ci
```

Read each exit code from `$?` directly, never through a pipe.

- [ ] **Step 7: Commit**

```bash
git add plugins/librarian/scripts/lib/librarian-cli.sh \
        plugins/librarian/skills/librarian/SKILL.md \
        test/bats/librarian-lesson-promote.bats
```

Commit subject: `feat(librarian): promote a lesson from the judge walk :package:`

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| Pool entry's key set exactly equals `ZLesson`'s | 1 |
| `private` → `local`, `org` → `org`, `public` → `public` | 1 |
| `private` entry has `judges: 0`, deliberately not ingest-valid | 1 |
| `agreed <= judges` | 1 |
| Rejected → declined row with gate reason and a nested verdict, no pool entry | 1 |
| Stage-5 declines still write, without a `verdict` key | 1 |
| `confirmed` / `pending` / `passed` refused, naming the status | 1 |
| Already promoted is a no-op with one entry and unchanged `promoted_at` | 1 |
| Failing `author_key` writes nothing, lesson stays `approved` unstamped | 1 |
| `librarian_lesson_seen` reports handled after both paths | 1 |
| Terminal record before the stamp | 1 (proved by the Step 6b injection) |
| Atomic writes | 1 |
| Promotion spends nothing | 1 (the `claude` stub in `setup()`) |
| Standalone verb and automatic call from the judge walk | 2 |
| An unjudged candidate is neither recorded nor promoted | 2 |
