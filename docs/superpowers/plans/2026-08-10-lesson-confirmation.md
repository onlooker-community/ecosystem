# Lesson Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a human pick which lesson candidates go to the jury, and their visibility, before any expensive tokens are spent.

**Architecture:** Four bash units with clean seams — a second validator that permits the `version_independent` branch a human may assert, a state-transition lib over the proposal files stage 5 already writes, a nested `librarian_cli lessons <verb>` dispatch, and the two user-facing surfaces (SessionStart counter, `/librarian lessons` skill route). No model calls anywhere in this stage; no event emission, because the types are unregistered.

**Tech Stack:** bash, `jq`, `bats`, `node:test` (agreement test only).

**Spec:** `docs/superpowers/specs/2026-08-10-lesson-confirmation-design.md`

## Global Constraints

- Bash only. `jq` for JSON. No Python in shipped code.
- Always `${ONLOOKER_DIR:-$HOME/.onlooker}` — never a literal `~/.onlooker`.
- ULIDs via `librarian_ulid`, never UUIDs.
- Repo shell style is **TAB-indented**. `shellcheck -S error -x` must be clean.
- **Never inline braces in a parameter-expansion default.** `${N:-{\}}` and `${N:-{}}` are both wrong. Default in a separate statement: `local p="${3:-}"` then `[ -z "$p" ] && p='{}'`. Guarded by `test/bats/emit-payload-default.bats`.
- bats runs under macOS bash 3.2, where a failing **non-final** `[[ ]]` does not fail the test. Use `[ ]`, or append `|| return 1`. Break each new assertion once to confirm it discriminates.
- **This stage must never invoke a model.** No `claude`, no network.
- Visibility values are exactly `private`, `org`, `public`.
- `version_independent` requires visibility `org` or `public`.
- American English. Commit style `<type>(<scope>): <subject> :emoji:` with a why-focused body.

## File Structure

| File | Responsibility |
|---|---|
| `plugins/librarian/scripts/lib/librarian-lesson-validate.sh` | Modified: extract the shared structural clause; add `librarian_lesson_validate_confirmed` |
| `plugins/librarian/scripts/lib/librarian-lesson-review.sh` | Create: state transitions (`confirm` / `pass`), `passed.jsonl` append, pending listing |
| `plugins/librarian/scripts/lib/librarian-cli.sh` | Modified: nested `lessons` dispatch + six verbs |
| `plugins/librarian/scripts/hooks/librarian-session-start.sh` | Modified: second one-line count |
| `plugins/librarian/skills/librarian/SKILL.md` | Modified: route `/librarian lessons` |
| `test/bats/librarian-lesson-review.bats` | Create: all bats coverage for this stage |
| `test/node/lesson-validate-agreement.test.mjs` | Modified: cover the confirmed validator |

**Why the validator is refactored rather than copied.** `librarian_lesson_validate_candidate` is ~50 lines of `jq` mirroring the vendored sub-schemas. Copying it to add one branch is how the two mechanisms drifted apart the first time — that drift shipped, and cost a fix round to find. Extracting the shared clause means a schema change is fixed in one place. The refactor is protected by `test/node/lesson-validate-agreement.test.mjs`, which drives the real bash function against ajv.

---

### Task 1: The confirmed-candidate validator

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-validate.sh`
- Modify: `test/node/lesson-validate-agreement.test.mjs`
- Test: `test/bats/librarian-lesson-review.bats` (create)

**Interfaces:**
- Consumes: `librarian_lesson_valid_range <string>` (exists).
- Produces: `librarian_lesson_validate_confirmed <candidate_json>` → exit 0 valid, 1 invalid (reason `schema_invalid` on stderr). Accepts either scope branch; `version_independent` requires a non-empty `justification`.

- [ ] **Step 1: Write the failing tests**

Create `test/bats/librarian-lesson-review.bats`:

```bash
#!/usr/bin/env bats
#
# Lesson confirmation: the human intent filter between the transform and the
# jury. Assertions use [ ] or `|| return 1` so every one gates under bash 3.2.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
}

_evidence() {
	printf '%s' '{"artifact_ids":["01KZ45MKAM734ZS7JK24D2DK0R"],"session_ids":["s1"],"project_key":"6a7678979e31","observed_at":"2026-08-03T15:59:48Z","resolution":"Pin vitest to 3.x."}'
}

# Usage: _candidate <scope_json>
_candidate() {
	jq -cn --argjson ev "$(_evidence)" --argjson scope "$1" \
		'{claim: "c", rationale: "r", evidence: $ev,
		  applies_to: {stack: ["vite"], scope: $scope, file_patterns: [], task_kinds: []}}'
}

_versioned() { printf '%s' '{"kind":"versioned","versions":{"vite":"<6"}}'; }
_indep() { printf '%s' '{"kind":"version_independent","justification":"git aborts checkout on a dirty tree regardless of version."}'; }

@test "confirmed validator accepts a versioned candidate" {
	run librarian_lesson_validate_confirmed "$(_candidate "$(_versioned)")"
	[ "$status" -eq 0 ]
}

@test "confirmed validator accepts version_independent with a justification" {
	run librarian_lesson_validate_confirmed "$(_candidate "$(_indep)")"
	[ "$status" -eq 0 ]
}

@test "confirmed validator rejects version_independent with an empty justification" {
	run librarian_lesson_validate_confirmed \
		"$(_candidate '{"kind":"version_independent","justification":""}')"
	[ "$status" -eq 1 ]
}

@test "confirmed validator rejects version_independent with no justification key" {
	run librarian_lesson_validate_confirmed \
		"$(_candidate '{"kind":"version_independent"}')"
	[ "$status" -eq 1 ]
}

@test "confirmed validator rejects an unknown scope kind" {
	run librarian_lesson_validate_confirmed \
		"$(_candidate '{"kind":"whenever","justification":"x"}')"
	[ "$status" -eq 1 ]
}

@test "confirmed validator still enforces the range pattern on versioned scope" {
	run librarian_lesson_validate_confirmed \
		"$(_candidate '{"kind":"versioned","versions":{"vite":"^5.4.21"}}')"
	[ "$status" -eq 1 ]
}

@test "confirmed validator still enforces provenance" {
	candidate=$(_candidate "$(_versioned)" | jq -c '.evidence.session_ids = [""]')
	run librarian_lesson_validate_confirmed "$candidate"
	[ "$status" -eq 1 ]
}

@test "confirmed validator still enforces the versions-subset-of-stack rule" {
	candidate=$(_candidate '{"kind":"versioned","versions":{"vite":"<6","vitest":">=4"}}')
	run librarian_lesson_validate_confirmed "$candidate"
	[ "$status" -eq 1 ]
}

@test "the transform validator still refuses version_independent" {
	run librarian_lesson_validate_candidate "$(_candidate "$(_indep)")"
	[ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: FAIL — `librarian_lesson_validate_confirmed: command not found`.

- [ ] **Step 3: Extract the shared structural clause**

In `librarian-lesson-validate.sh`, above `librarian_lesson_validate_candidate`, add:

```bash
# Everything both validators check, excluding the scope branch. Kept in one
# place because it mirrors the vendored sub-schemas line for line; a second
# copy is how the jq rules and the schema drifted apart once already.
#
# Composed into a jq program by each validator, which appends its own scope
# clause.
#
# The mirrors below are NOT decorative, and both reasons were learned the
# hard way — do not delete them as redundant with the schema:
#
#   The `keys - [...]` checks mirror `additionalProperties: false` and the
#   `all(type == "string" and length > 0)` checks mirror the array items'
#   `minLength: 1`. Without them, a model that "helpfully" adds an extra
#   field produces a proposal that passes here but fails ajv against the
#   contract it claims to satisfy — and lessons are shared with other
#   people, so that lands on someone else's machine.
#
#   The ULID, RFC3339 and non-empty-string patterns on evidence exist
#   because a provenance-less artifact (session_id/created_at stitched in
#   as "") must fail HERE. If it passes, the proposal is written and
#   librarian_lesson_seen marks the artifact handled forever — buried
#   permanently, which is the failure the whole taxonomy exists to prevent.
_LIBRARIAN_LESSON_STRUCTURAL='
	(.claim | type) == "string" and (.claim | length) > 0
	and (.rationale | type) == "string" and (.rationale | length) > 0
	and (.evidence | type) == "object"
	and ((.evidence | keys) - ["artifact_ids", "session_ids", "project_key", "observed_at", "resolution"] | length) == 0
	and (.evidence.artifact_ids | type) == "array" and (.evidence.artifact_ids | length) > 0
	and (.evidence.artifact_ids | all(type == "string" and test("^[0-9A-HJKMNP-TV-Z]{26}$")))
	and (.evidence.session_ids | type) == "array" and (.evidence.session_ids | length) > 0
	and (.evidence.session_ids | all(type == "string" and length > 0))
	and (.evidence.project_key | type) == "string"
	and (.evidence.project_key | test("^[0-9a-f]{12}$"))
	and (.evidence.observed_at | type) == "string"
	and (.evidence.observed_at | test("^(?:(?:\\d\\d[2468][048]|\\d\\d[13579][26]|\\d\\d0[48]|[02468][048]00|[13579][26]00)-02-29|\\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\\d|30)|(?:02)-(?:0[1-9]|1\\d|2[0-8])))T(?:(?:[01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d(?:\\.\\d+)?)?(?:Z))$"))
	and (.evidence.resolution | type) == "string" and (.evidence.resolution | length) > 0
	and (.applies_to | type) == "object"
	and ((.applies_to | keys) - ["stack", "scope", "file_patterns", "task_kinds"] | length) == 0
	and (.applies_to.stack | type) == "array" and (.applies_to.stack | length) > 0
	and (.applies_to.stack | all(type == "string" and length > 0))
	and (.applies_to.file_patterns | type) == "array"
	and (.applies_to.file_patterns | all(type == "string" and length > 0))
	and (.applies_to.task_kinds | type) == "array"
	and (.applies_to.task_kinds | all(type == "string" and length > 0))
'

# The versioned branch, shared by both validators.
_LIBRARIAN_LESSON_SCOPE_VERSIONED='
	.applies_to.scope.kind == "versioned"
	and ((.applies_to.scope | keys) - ["kind", "versions"] | length) == 0
	and (.applies_to.scope.versions | type) == "object"
	and (.applies_to.scope.versions | length) > 0
'

# Checks that only apply to a versioned candidate: the cross-field rule JSON
# Schema cannot express, and the range pattern on each value.
#
# NUL-delimited, not newline-delimited: a range value with an embedded newline
# would otherwise split into two lines that can each pass individually even
# though the single value they came from is not a valid range. Do not skip
# empty reads either — jq never emits one for a non-empty object of strings,
# so an empty read means the range itself is empty, which is invalid.
_librarian_lesson_check_versions() {
	local candidate="$1"

	printf '%s' "$candidate" | jq -e '
		(.applies_to.scope.versions | keys) - .applies_to.stack | length == 0
	' >/dev/null 2>&1 || return 1

	local range
	while IFS= read -r -d '' range; do
		librarian_lesson_valid_range "$range" || return 1
	done < <(printf '%s' "$candidate" | jq --raw-output0 '.applies_to.scope.versions[]' 2>/dev/null)

	return 0
}
```

- [ ] **Step 4: Rewrite the transform validator to use them**

Replace the body of `librarian_lesson_validate_candidate` with:

```bash
librarian_lesson_validate_candidate() {
	local candidate="${1:-}"
	[[ -z "$candidate" ]] && { printf 'schema_invalid\n' >&2; return 1; }

	# versioned ONLY. This is the guarantee that stops the transform minting
	# lessons that never expire: private lessons run no jury, so nothing
	# downstream would catch a bad version_independent claim. A human may
	# assert that branch — see librarian_lesson_validate_confirmed — because
	# the constraint in the review path forces it to a judged visibility.
	if ! printf '%s' "$candidate" | jq -e \
		"${_LIBRARIAN_LESSON_STRUCTURAL} and ${_LIBRARIAN_LESSON_SCOPE_VERSIONED}" \
		>/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	_librarian_lesson_check_versions "$candidate" || {
		printf 'schema_invalid\n' >&2
		return 1
	}

	return 0
}
```

- [ ] **Step 5: Add the confirmed validator**

Immediately after it:

```bash
# Validate a candidate a human has confirmed.
#
# Identical to librarian_lesson_validate_candidate except that it also permits
# the version_independent branch, which requires a non-empty justification.
#
# The two are NOT redundant and the difference is not stylistic. They encode
# different trust: this one bounds what a human may assert AND a jury will then
# check, because the review path refuses version_independent at private
# visibility. The transform's validator bounds what a model may assert
# unsupervised, where nothing downstream would catch a bad claim. Deleting
# either collapses that distinction.
#
# Usage: librarian_lesson_validate_confirmed <candidate_json>
librarian_lesson_validate_confirmed() {
	local candidate="${1:-}"
	[[ -z "$candidate" ]] && { printf 'schema_invalid\n' >&2; return 1; }

	local scope_clause='
		(
			('"${_LIBRARIAN_LESSON_SCOPE_VERSIONED}"')
			or (
				.applies_to.scope.kind == "version_independent"
				and ((.applies_to.scope | keys) - ["kind", "justification"] | length) == 0
				and (.applies_to.scope.justification | type) == "string"
				and (.applies_to.scope.justification | length) > 0
			)
		)
	'

	if ! printf '%s' "$candidate" | jq -e \
		"${_LIBRARIAN_LESSON_STRUCTURAL} and ${scope_clause}" \
		>/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	# Range and subset rules apply only to the versioned branch.
	if printf '%s' "$candidate" | jq -e '.applies_to.scope.kind == "versioned"' >/dev/null 2>&1; then
		_librarian_lesson_check_versions "$candidate" || {
			printf 'schema_invalid\n' >&2
			return 1
		}
	fi

	return 0
}
```

- [ ] **Step 6: Run the tests**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: all 9 PASS.

- [ ] **Step 7: Prove the refactor did not change the transform validator**

Run: `bats test/bats/librarian-lesson-transform.bats && node --test test/node/lesson-validate-agreement.test.mjs`
Expected: 47/47 bats PASS; agreement test PASS. The agreement test drives the real bash function against ajv, so it is the guard that the extraction preserved behavior.

- [ ] **Step 8: Extend the agreement test to the confirmed validator**

In `test/node/lesson-validate-agreement.test.mjs`, add cases asserting `librarian_lesson_validate_confirmed` agrees with ajv on a `version_independent` candidate. The vendored `lesson-applies-to.subschema.json` already carries that branch with `justification` `minLength: 1`, so ajv is the reference for both:

The file's `jqAccepts()` currently hardcodes `librarian_lesson_validate_candidate`. Parameterize it, keeping the existing call sites working:

```javascript
function jqAccepts(candidate, fn = 'librarian_lesson_validate_candidate') {
  const result = spawnSync(
    'bash',
    ['-c', `source '${VALIDATE_LIB}' && ${fn} "$CANDIDATE_JSON"`],
    { env: { ...process.env, CANDIDATE_JSON: JSON.stringify(candidate) }, encoding: 'utf8' },
  );
  return result.status === 0;
}
```

Then add, reusing the file's existing `baseCandidate()` and `schemaAccepts()`:

```javascript
describe('confirmed validator', () => {
  it('agrees with the schema on a well-formed version_independent candidate', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = {
      kind: 'version_independent',
      justification: 'git aborts checkout on a dirty tree regardless of version.',
    };
    assert.equal(jqAccepts(candidate, 'librarian_lesson_validate_confirmed'), true);
    assert.equal(schemaAccepts(candidate), true);
  });

  it('agrees with the schema in rejecting an empty justification', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = { kind: 'version_independent', justification: '' };
    assert.equal(jqAccepts(candidate, 'librarian_lesson_validate_confirmed'), false);
    assert.equal(schemaAccepts(candidate), false);
  });

  it('still refuses version_independent through the transform validator', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = {
      kind: 'version_independent',
      justification: 'git aborts checkout on a dirty tree regardless of version.',
    };
    // The schema permits this branch; the transform's gate deliberately does not.
    assert.equal(schemaAccepts(candidate), true);
    assert.equal(jqAccepts(candidate), false);
  });
});
```

That third case is the one worth having: it pins the deliberate divergence, so nobody later "fixes" the transform validator into agreeing with the schema and silently reopens the never-expiring-lesson hole.

- [ ] **Step 9: Verify and commit**

Run: `node --test test/node/lesson-validate-agreement.test.mjs && shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-validate.sh && npm run lint:check`
Expected: all pass, shellcheck silent, lint exit 0.

```bash
git add plugins/librarian/scripts/lib/librarian-lesson-validate.sh \
        test/bats/librarian-lesson-review.bats \
        test/node/lesson-validate-agreement.test.mjs
git commit -m "feat(librarian): validate what a human may assert, separately :scales:"
```

---

### Task 2: State transitions and the passed ledger

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-lesson-review.sh`
- Test: `test/bats/librarian-lesson-review.bats` (append)

**Interfaces:**
- Consumes: `librarian_lessons_dir <key>`, `librarian_lesson_storage_init <key>` (from stage 5); `librarian_lesson_validate_confirmed` (Task 1).
- Produces:
  - `librarian_lesson_list_pending <key>` → JSON array of pending proposals, `[]` when none
  - `librarian_lesson_confirm <key> <lesson_id> <visibility> [justification]` → exit 0 on success; sets `status: "confirmed"` and `visibility`; with a justification, rewrites scope to `version_independent`
  - `librarian_lesson_pass <key> <lesson_id> [reason]` → exit 0; sets `status: "passed"` and appends to `passed.jsonl`
  - `librarian_lesson_passed_path <key>` → prints the ledger path

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-review.bats`:

```bash
_review_setup() {
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-review.sh"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-review.git
	PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"
}

# Seeds one pending proposal and prints its id.
_seed_pending() {
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "$(_versioned)")" "01KZ45MKAM734ZS7JK24D2DK0R"
}

@test "list_pending returns an empty array when the queue is empty" {
	_review_setup
	run librarian_lesson_list_pending "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
}

@test "list_pending returns a seeded pending proposal" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_list_pending "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -e --arg id "$id" 'length == 1 and .[0].id == $id' >/dev/null
}

@test "confirm records status and visibility on the proposal" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	[ "$status" -eq 0 ]
	jq -e '.status == "confirmed" and .visibility == "org"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm refuses an empty visibility and leaves the proposal pending" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" ""
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm refuses an unknown visibility" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "everyone"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm with a justification rewrites scope to version_independent" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git behavior is stable across versions."
	[ "$status" -eq 0 ]
	jq -e '.candidate.applies_to.scope.kind == "version_independent"
	       and (.candidate.applies_to.scope.justification | length) > 0' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm refuses version_independent at private visibility" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "private" "stable across versions."
	[ "$status" -ne 0 ]
	jq -e '.status == "pending" and .candidate.applies_to.scope.kind == "versioned"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm refuses a candidate that fails the confirmed validator" {
	_review_setup
	id=$(_seed_pending)
	# Corrupt the stored candidate so validation must reject it.
	tmp="${BATS_TEST_TMPDIR}/bad.json"
	jq '.candidate.evidence.resolution = ""' "${LESSONS_DIR}/proposals/${id}.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/${id}.json"
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "pass marks the proposal and appends one ledger line" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_pass "$PROJECT_KEY" "$id" "not worth sharing"
	[ "$status" -eq 0 ]
	jq -e '.status == "passed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
	[ "$(wc -l < "${LESSONS_DIR}/passed.jsonl")" -eq 1 ]
	tail -n 1 "${LESSONS_DIR}/passed.jsonl" \
		| jq -e --arg id "$id" '.lesson_id == $id and .reason == "not worth sharing"' >/dev/null
}

@test "a passed proposal keeps its file so the artifact stays seen" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_pass "$PROJECT_KEY" "$id"
	[ -f "${LESSONS_DIR}/proposals/${id}.json" ]
	run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
	[ "$status" -eq 0 ]
}

@test "this stage never writes to declined.jsonl" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	id2=$(_seed_pending)
	librarian_lesson_pass "$PROJECT_KEY" "$id2"
	[ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "confirming never invokes a model" {
	_review_setup
	# A claude on PATH that fails loudly if called at all.
	stub="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub"
	printf '#!/usr/bin/env bash\necho "MODEL WAS INVOKED" >&2\nexit 42\n' > "${stub}/claude"
	chmod +x "${stub}/claude"
	PATH="${stub}:${PATH}"

	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	[ "$status" -eq 0 ]
	[[ "$output" != *"MODEL WAS INVOKED"* ]] || return 1
	jq -e '.status == "confirmed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "list_pending excludes confirmed and passed proposals" {
	_review_setup
	a=$(_seed_pending); b=$(_seed_pending); c=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$a" "org"
	librarian_lesson_pass "$PROJECT_KEY" "$b"
	run librarian_lesson_list_pending "$PROJECT_KEY"
	printf '%s' "$output" | jq -e --arg c "$c" 'length == 1 and .[0].id == $c' >/dev/null
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: the new tests FAIL with `librarian_lesson_list_pending: command not found`. Task 1's nine still pass.

- [ ] **Step 3: Implement the library**

Create `plugins/librarian/scripts/lib/librarian-lesson-review.sh`:

```bash
#!/usr/bin/env bash
# Lesson confirmation — the human intent filter.
#
# The human picks which candidates go to the jury and their visibility, before
# any expensive tokens are spent. Intent is cheap and only a human can supply
# it; quality is expensive and only the jury can judge it. Splitting them here
# means cost scales with intent rather than artifact volume.
#
# NOTHING in this file may invoke a model. That is what makes "no tokens spent
# on unselected candidates" a property of the code rather than a promise.
#
# Requires librarian-lesson-storage.sh and librarian-lesson-validate.sh.

librarian_lesson_passed_path() {
	local key="$1"
	printf '%s/passed.jsonl' "$(librarian_lessons_dir "$key")"
}

# Print pending proposals as a JSON array, oldest first. Prints [] when none.
# Usage: librarian_lesson_list_pending <key>
librarian_lesson_list_pending() {
	local key="$1"
	[[ -z "$key" ]] && { printf '[]'; return 0; }

	local dir
	dir="$(librarian_lessons_dir "$key")/proposals"
	[[ -d "$dir" ]] || { printf '[]'; return 0; }

	local f out
	out='[]'
	for f in "$dir"/*.json; do
		[[ -f "$f" ]] || continue
		jq -e '.status == "pending"' "$f" >/dev/null 2>&1 || continue
		# Skip a file we cannot accumulate rather than abandoning the listing.
		# A concurrent confirm/pass can rewrite the file between the status
		# check above and this read; discarding everything gathered so far
		# would report an empty queue, which reads as "nothing to review"
		# rather than as an error. Same failure class librarian_lesson_seen
		# guards against in the sibling file.
		#
		# `out=$(cmd) || continue` does NOT work here: the assignment happens
		# and clobbers $out to empty stdout BEFORE `||` is evaluated, so the
		# accumulator is already wiped by the time `continue` runs. Merge into
		# a temp and promote only on success.
		local merged
		if merged=$(jq -c --slurpfile p "$f" '. + $p' <<<"$out" 2>/dev/null); then
			out="$merged"
		fi
	done
	printf '%s' "$(jq -c 'sort_by(.created_at)' <<<"$out")"
}

_librarian_lesson_valid_visibility() {
	case "${1:-}" in
		private | org | public) return 0 ;;
		*) return 1 ;;
	esac
}

# Confirm a candidate for the jury.
#
# Usage: librarian_lesson_confirm <key> <lesson_id> <visibility> [justification]
#
# With a justification, the candidate's scope is rewritten to
# version_independent. That branch is refused at private visibility: private
# lessons run no jury, so the justification would reach the pool with nothing
# checking it — the same hole the transform closes by refusing the branch
# outright. Requiring org or public means scope_accuracy actually tests it.
librarian_lesson_confirm() {
	local key="$1"
	local lesson_id="$2"
	local visibility="${3:-}"
	local justification="${4:-}"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	_librarian_lesson_valid_visibility "$visibility" || {
		printf 'visibility must be one of: private, org, public\n' >&2
		return 1
	}

	if [[ -n "$justification" && "$visibility" == "private" ]]; then
		printf 'version_independent requires org or public visibility: a private lesson runs no jury, so its justification would go unchecked and the lesson would never expire\n' >&2
		return 1
	fi

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local proposal candidate current
	proposal=$(jq '.' "$path" 2>/dev/null) || return 1
	candidate=$(printf '%s' "$proposal" | jq -c '.candidate' 2>/dev/null) || return 1
	current=$(printf '%s' "$proposal" | jq -r '.status // ""' 2>/dev/null)

	# Guard the transition, not just the write. Each write is atomic on its
	# own, but an unguarded SEQUENCE lets passed.jsonl end up contradicting
	# the candidate it describes: pass then confirm would flip status back to
	# confirmed while the ledger still asserts the human declined it. The
	# ledger is the durable record of intent, so it must never disagree.
	case "$current" in
		pending) ;;
		confirmed)
			# Idempotent only when nothing about the decision changed.
			local prev_vis prev_scope
			prev_vis=$(printf '%s' "$proposal" | jq -r '.visibility // ""')
			prev_scope=$(printf '%s' "$proposal" | jq -c '.candidate.applies_to.scope')
			if [[ "$prev_vis" == "$visibility" && -z "$justification" ]] \
				|| [[ "$prev_vis" == "$visibility" && "$prev_scope" == *'"version_independent"'* ]]; then
				return 0
			fi
			printf 'Lesson %s is already confirmed at %s visibility; pass on it first to change that.\n' \
				"$lesson_id" "$prev_vis" >&2
			return 1
			;;
		passed)
			printf 'Lesson %s was passed on; it cannot be confirmed without reopening it.\n' "$lesson_id" >&2
			return 1
			;;
		*)
			printf 'Lesson %s has an unrecognized status: %s\n' "$lesson_id" "$current" >&2
			return 1
			;;
	esac

	if [[ -n "$justification" ]]; then
		candidate=$(printf '%s' "$candidate" | jq -c \
			--arg j "$justification" \
			'.applies_to.scope = {kind: "version_independent", justification: $j}' 2>/dev/null) || return 1
	fi

	librarian_lesson_validate_confirmed "$candidate" 2>/dev/null || {
		printf 'Candidate does not validate; not confirmed.\n' >&2
		return 1
	}

	local now updated
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	# Assign .candidate rather than folding it into the `*` merge. jq's `*` is
	# RECURSIVE: `. * {candidate: $c}` merges the new candidate into the stored
	# one instead of replacing it. When a confirm rewrites scope to
	# version_independent, the fresh scope is {kind, justification} but merging
	# it over the stored {kind, versions} leaves all three keys — a candidate
	# that fails librarian_lesson_validate_confirmed, since that branch permits
	# only kind and justification. It would then be handed to the jury stage,
	# which reads exactly this field.
	updated=$(printf '%s' "$proposal" | jq \
		--arg v "$visibility" --arg t "$now" --argjson c "$candidate" \
		'. * {status: "confirmed", visibility: $v, confirmed_at: $t} | .candidate = $c' 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	printf '%s\n' "$updated" > "$path"
}

# Decline to share a candidate.
#
# The file is KEPT. librarian_lesson_seen scans proposals/ by artifact_id, so
# leaving it in place is what stops the artifact being re-proposed on the next
# scan and re-paying for a transform whose answer the human already gave.
#
# The ledger is separate from declined.jsonl on purpose: that file records
# machine verdicts and feeds rubric tuning, and folding human intent into it
# would corrupt the signal it exists to carry.
#
# Usage: librarian_lesson_pass <key> <lesson_id> [reason]
librarian_lesson_pass() {
	local key="$1"
	local lesson_id="$2"
	local reason="${3:-}"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local current
	current=$(jq -r '.status // ""' "$path" 2>/dev/null)

	# Same reasoning as confirm: guard the transition. Passing twice must not
	# append a second ledger line, and a confirmed candidate must not be
	# silently un-confirmed — that would leave stale visibility/confirmed_at
	# on the record and send a contradictory signal to the jury stage, which
	# selects on status.
	case "$current" in
		pending) ;;
		passed) return 0 ;;
		confirmed)
			printf 'Lesson %s is already confirmed for the jury; it cannot be passed on now.\n' "$lesson_id" >&2
			return 1
			;;
		*)
			printf 'Lesson %s has an unrecognized status: %s\n' "$lesson_id" "$current" >&2
			return 1
			;;
	esac

	local artifact_id now updated
	artifact_id=$(jq -r '.artifact_id // ""' "$path" 2>/dev/null)
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	updated=$(jq --arg t "$now" '. * {status: "passed", passed_at: $t}' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	printf '%s\n' "$updated" > "$path"

	local line
	line=$(jq -cn \
		--arg lesson_id "$lesson_id" \
		--arg artifact_id "$artifact_id" \
		--arg reason "$reason" \
		--arg at "$now" \
		'{lesson_id: $lesson_id, artifact_id: $artifact_id,
		  reason: (if $reason == "" then null else $reason end), passed_at: $at}') || return 1

	printf '%s\n' "$line" >> "$(librarian_lesson_passed_path "$key")"
}
```

- [ ] **Step 4: Run the tests**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: all PASS (9 from Task 1 + 13 new).

- [ ] **Step 5: Fault-inject the three guarantees**

Each of these is a guarantee, not a behavior, so confirm each test discriminates. For each: make the change, run the named test, confirm it FAILS, revert, confirm it passes.

1. Delete the `_librarian_lesson_valid_visibility` call → "confirm refuses an unknown visibility" must fail.
2. Delete the `private` + justification check → "confirm refuses version_independent at private visibility" must fail.
3. In `librarian_lesson_pass`, remove the `printf ... >> passed.jsonl` line → "pass marks the proposal and appends one ledger line" must fail.

Report the result of each in the task report.

- [ ] **Step 6: Verify and commit**

Run: `shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-review.sh && bats test/bats/librarian-lesson-transform.bats && npm run lint:check`
Expected: shellcheck silent, transform suite still green, lint exit 0.

```bash
git add plugins/librarian/scripts/lib/librarian-lesson-review.sh \
        test/bats/librarian-lesson-review.bats
git commit -m "feat(librarian): let a human confirm lessons and record what they pass on :raised_hand:"
```

---

### Task 3: CLI verbs

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-cli.sh`
- Test: `test/bats/librarian-lesson-review.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_list_pending`, `librarian_lesson_confirm`, `librarian_lesson_pass` (Task 2); `_librarian_cli_project_key <cwd>` (exists).
- Produces: `librarian_cli lessons <list|show|confirm|pass|defer|status> [args]`.

- [ ] **Step 1: Write the failing tests**

Append:

```bash
_cli_setup() {
	_review_setup
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-cli.sh"
}

@test "lessons status reports zero on an empty queue" {
	_cli_setup
	run librarian_cli lessons status "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"0"* ]] || return 1
}

@test "lessons list shows a pending lesson" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons list "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$id"* ]] || return 1
}

@test "lessons show prints the claim" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons show "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"c"* ]] || return 1
}

@test "lessons confirm requires a visibility argument" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons confirm sets status and visibility" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id" public "" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.status == "confirmed" and .visibility == "public"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons pass marks it passed" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons pass "$id" "" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.status == "passed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons defer leaves it pending" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons defer "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "an unknown lessons verb is rejected" {
	_cli_setup
	run librarian_cli lessons frobnicate
	[ "$status" -ne 0 ]
}

@test "memory verbs are unaffected by the lessons namespace" {
	_cli_setup
	run librarian_cli status "$PROJECT_REPO"
	[ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: new tests FAIL — `librarian_cli` reports `unknown action: lessons`.

- [ ] **Step 3: Source the review lib from the CLI**

At the top of `librarian-cli.sh`, alongside its existing sources, add:

```bash
# shellcheck source=./librarian-lesson-storage.sh
source "${BASH_SOURCE[0]%/*}/librarian-lesson-storage.sh"
# shellcheck source=./librarian-lesson-validate.sh
source "${BASH_SOURCE[0]%/*}/librarian-lesson-validate.sh"
# shellcheck source=./librarian-lesson-review.sh
source "${BASH_SOURCE[0]%/*}/librarian-lesson-review.sh"
```

If the file already sources siblings by a different idiom, match that idiom instead — read the top of the file first.

- [ ] **Step 4: Add the verbs and nested dispatch**

Add before `librarian_cli()`:

```bash
# ----------------------------------------------------------------------------
# Lesson confirmation surface
#
# Namespaced under `lessons` and kept apart from the memory verbs on purpose.
# Accepting a memory writes a file on this machine; confirming a lesson commits
# it toward leaving this machine, irreversibly once synced. Those two decisions
# should not sit one keystroke apart.
# ----------------------------------------------------------------------------

librarian_cli_lessons_list() {
	local cwd="${1:-}"
	local key pending
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }
	pending=$(librarian_lesson_list_pending "$key")

	if [[ "$(printf '%s' "$pending" | jq 'length')" -eq 0 ]]; then
		printf 'No pending lessons.\n'
		return 0
	fi
	printf '%s' "$pending" | jq -r '.[] | "\(.id)  \(.candidate.claim)"'
}

librarian_cli_lessons_show() {
	local lesson_id="${1:-}"
	local cwd="${2:-}"
	[[ -z "$lesson_id" ]] && { printf 'usage: librarian_cli lessons show <lesson_id>\n'; return 1; }

	local key path
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id"; return 1; }

	jq -r '
		"id:          \(.id)",
		"status:      \(.status)",
		"artifact:    \(.artifact_id)",
		"claim:       \(.candidate.claim)",
		"rationale:   \(.candidate.rationale)",
		"resolution:  \(.candidate.evidence.resolution)",
		"stack:       \(.candidate.applies_to.stack | join(", "))",
		"scope:       \(.candidate.applies_to.scope | tojson)"
	' "$path"
}

librarian_cli_lessons_confirm() {
	local lesson_id="${1:-}"
	local visibility="${2:-}"
	local justification="${3:-}"
	local cwd="${4:-}"
	[[ -z "$lesson_id" || -z "$visibility" ]] && {
		printf 'usage: librarian_cli lessons confirm <lesson_id> <private|org|public> [justification]\n'
		return 1
	}

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	librarian_lesson_confirm "$key" "$lesson_id" "$visibility" "$justification" || return 1
	printf 'Confirmed %s at %s visibility.\n' "$lesson_id" "$visibility"
}

librarian_cli_lessons_pass() {
	local lesson_id="${1:-}"
	local reason="${2:-}"
	local cwd="${3:-}"
	[[ -z "$lesson_id" ]] && { printf 'usage: librarian_cli lessons pass <lesson_id> [reason]\n'; return 1; }

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	librarian_lesson_pass "$key" "$lesson_id" "$reason" || return 1
	printf 'Passed on %s.\n' "$lesson_id"
}

librarian_cli_lessons_defer() {
	local lesson_id="${1:-}"
	[[ -z "$lesson_id" ]] && { printf 'usage: librarian_cli lessons defer <lesson_id>\n'; return 1; }
	printf 'Deferred %s; it stays in the queue.\n' "$lesson_id"
}

librarian_cli_lessons_status() {
	local cwd="${1:-}"
	local key pending
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }
	pending=$(librarian_lesson_list_pending "$key")
	printf 'lessons pending: %s\n' "$(printf '%s' "$pending" | jq 'length')"
}

librarian_cli_lessons() {
	local verb="${1:-list}"
	shift || true
	case "$verb" in
		list) librarian_cli_lessons_list "$@" ;;
		show) librarian_cli_lessons_show "$@" ;;
		confirm) librarian_cli_lessons_confirm "$@" ;;
		pass) librarian_cli_lessons_pass "$@" ;;
		defer) librarian_cli_lessons_defer "$@" ;;
		status) librarian_cli_lessons_status "$@" ;;
		*) printf 'unknown lessons action: %s\n' "$verb"; return 2 ;;
	esac
}
```

Then add one line to the existing `librarian_cli` dispatch, before the `*)` catch-all:

```bash
		lessons) librarian_cli_lessons "$@" ;;
```

- [ ] **Step 5: Run the tests**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: all PASS.

- [ ] **Step 6: Verify and commit**

Run: `shellcheck -S error -x plugins/librarian/scripts/lib/librarian-cli.sh && bats test/bats/librarian-cli.bats && npm run lint:check`
Expected: shellcheck silent, the existing CLI suite still green, lint exit 0.

```bash
git add plugins/librarian/scripts/lib/librarian-cli.sh test/bats/librarian-lesson-review.bats
git commit -m "feat(librarian): namespace the lesson verbs away from memory accepts :card_index_dividers:"
```

---

### Task 4: The two user-facing surfaces

**Files:**
- Modify: `plugins/librarian/scripts/hooks/librarian-session-start.sh`
- Modify: `plugins/librarian/skills/librarian/SKILL.md`
- Test: `test/bats/librarian-session-start.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_list_pending <key>` (Task 2), `librarian_cli lessons <verb>` (Task 3).
- Produces: no new functions.

- [ ] **Step 1: Write the failing test**

Read `test/bats/librarian-session-start.bats` first and reuse its existing setup helper rather than writing a new one. Append:

```bash
@test "session-start surfaces a pending lesson count as its own line" {
	# Reuse this file's existing project/hook setup, then seed one pending
	# lesson through the storage lib.
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	librarian_lesson_storage_init "$PROJECT_KEY"
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(jq -cn '{claim: "c", rationale: "r"}')" "01KZ45MKAM734ZS7JK24D2DK0R" >/dev/null

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"lesson"* ]] || return 1
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `bats test/bats/librarian-session-start.bats`
Expected: FAIL — no "lesson" in the injected context.

- [ ] **Step 3: Add the count to the surfacer**

In `librarian-session-start.sh`, alongside the existing pending-proposal count, source the lesson storage and review libs and add a second line to `additionalContext`. Keep it a pointer, not bodies — the file's own header explains why: session-start context is precious, and the queue belongs in the review skill.

```bash
# shellcheck source=../lib/librarian-lesson-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
# shellcheck source=../lib/librarian-lesson-validate.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
# shellcheck source=../lib/librarian-lesson-review.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-review.sh"
```

**There is a trap in the existing control flow — read this before editing.** The hook computes `PENDING` (memory proposals) and then early-exits:

```bash
if [[ "$PENDING" -eq 0 && "$SKIP_WHEN_ZERO" == "true" ]]; then
	_emit ""
	exit 0
fi
```

Adding the lesson line *after* that branch means lessons are never surfaced when there are no memory proposals — which is the common case, since the two queues fill independently. Compute the lesson count **before** the branch and include it in the condition:

```bash
LESSON_PENDING=$(librarian_lesson_list_pending "$PROJECT_KEY" | jq 'length' 2>/dev/null) || LESSON_PENDING=0
[[ -z "$LESSON_PENDING" || "$LESSON_PENDING" == "null" ]] && LESSON_PENDING=0

if [[ "$PENDING" -eq 0 && "$LESSON_PENDING" -eq 0 && "$SKIP_WHEN_ZERO" == "true" ]]; then
	_emit ""
	exit 0
fi
```

Then build the lesson line and append it to whatever context string the hook passes to `_emit`, separated by a newline:

```bash
LESSON_LINE=""
if [[ "$LESSON_PENDING" -gt 0 ]]; then
	LESSON_LINE=$(printf '%s lesson candidate(s) awaiting confirmation — run /librarian lessons' "$LESSON_PENDING")
fi
```

At the `_emit` call, join the two lines, skipping either when empty so a single-queue session gets one clean line rather than a stray blank:

```bash
CONTEXT="$MEMORY_LINE"
if [[ -n "$LESSON_LINE" ]]; then
	if [[ -n "$CONTEXT" ]]; then
		CONTEXT="${CONTEXT}"$'\n'"${LESSON_LINE}"
	else
		CONTEXT="$LESSON_LINE"
	fi
fi
_emit "$CONTEXT"
```

`MEMORY_LINE` is whatever variable the hook currently passes to `_emit` — read the end of the file and use its real name rather than renaming it.

Add a second test covering the trap, since it is the failure a reviewer would most likely miss:

```bash
@test "session-start surfaces lessons even with zero memory proposals" {
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	librarian_lesson_storage_init "$PROJECT_KEY"
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(jq -cn '{claim: "c", rationale: "r"}')" "01KZ45MKAM734ZS7JK24D2DK0R" >/dev/null

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"lesson"* ]] || return 1
}
```

- [ ] **Step 4: Run the tests**

Run: `bats test/bats/librarian-session-start.bats`
Expected: all PASS, including the pre-existing ones.

- [ ] **Step 5: Route the skill**

**First, fix the sourcing gap — the verbs do not work in production without it.** `librarian-cli.sh` deliberately sources nothing itself; its callers source its dependencies. The skill currently sources five libs (`librarian-config.sh`, `librarian-project-key.sh`, `librarian-storage.sh`, `librarian-emit.sh`, `librarian-cli.sh`) and none of the three lesson libs, so `librarian_cli lessons list` fails with `librarian_lesson_list_pending: command not found`. Verified by sourcing exactly what the skill lists and calling the verb.

Add these three to the skill's source block, before `librarian-cli.sh`:

```bash
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-storage.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-validate.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-review.sh"
```

Order matters: `librarian-lesson-review.sh` calls into both of the others, and `librarian-lesson-storage.sh` needs `librarian-storage.sh` (already sourced above it).

The bats suites pass without this because their setup sources every lib directly — which is exactly why this gap is invisible to per-task tests and has to be closed here.

Then, in `plugins/librarian/skills/librarian/SKILL.md`, extend the "Parse the request" section with the `lessons` route, and add a section describing the walk. Keep the existing memory routes untouched.

```markdown
- `lessons`, `lessons review` → **walk the lesson queue** (see below)
- `lessons list` / `lessons status` → print and stop
```

Add a section documenting: the walk shows `claim`, `rationale`, `evidence.resolution`, `applies_to.stack`, `scope.versions`, and the source artifact id; the three outcomes are `confirm <id> <visibility>`, `pass <id> [reason]`, `defer <id>`; confirming **requires** a visibility; and `version_independent` requires `org` or `public` because a private lesson runs no jury, so its justification would go unchecked.

Also update the skill's frontmatter `description` so `/librarian lessons` is discoverable.

- [ ] **Step 6: Verify and commit**

Run: `npm run test:ci`
Expected: exit 0.

```bash
git add plugins/librarian/scripts/hooks/librarian-session-start.sh \
        plugins/librarian/skills/librarian/SKILL.md \
        test/bats/librarian-session-start.bats
git commit -m "feat(librarian): surface pending lessons and route the review skill :bellhop_bell:"
```

---

## Self-review notes

**Spec coverage.** Surface and verbs → Task 3; state model and both ledgers → Task 2; the three constraints → Task 2 (enforced) and Tasks 2–3 (tested); two validators → Task 1; surfacing → Task 4; events → deliberately absent, see below; testing → inside each task; boundary to `4z8.3` → the `status: "confirmed"` + `visibility` fields written in Task 2.

**Deliberately absent.** No event emission. `librarian.lesson.*` is unregistered in `@onlooker-community/schema` 2.11.0 — verified — and with a validator present the emitter exits 1 on an unknown `event_type`. `4z8.3` reads the proposal files, not the bus, so nothing is blocked by waiting. One follow-up should wire all four types (`proposed`, `declined`, `confirmed`, `passed`) once the package publishes them.

**Refactor risk, and what covers it.** Task 1 restructures a validator that shipped in `librarian-v0.7.1` and cost a fix round to harden. The guard is `test/node/lesson-validate-agreement.test.mjs`, which drives the real bash function against ajv over a corpus — Step 7 runs it before the new behavior is added, specifically to prove the extraction changed nothing.

**Known gap.** `librarian_cli_lessons_defer` is a no-op that prints. It exists so the walk has three symmetric outcomes and the user can say "not now" without the skill inventing behavior. If a deferral ever needs to suppress re-surfacing for N sessions, that is a new field, not a change to this verb.
