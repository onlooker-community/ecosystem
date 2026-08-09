# Lesson Transform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add librarian's fifth stage — a Haiku transform that turns a durable archivist artifact into a lesson candidate, declining anything it cannot ground.

**Architecture:** Three new bash libs with clean boundaries (pure validation, storage, orchestration), sourced by the existing `librarian-session-end.sh` chain after conflict/dup detection. A free bash pre-gate runs before any model call; survivors go to `claude -p`; output is validated by dependency-free `jq` against rules vendored from the published lesson schema. Candidates land in a `lessons/` subtree separate from librarian's existing memory proposals.

**Tech Stack:** bash, `jq`, `bats`, `claude` CLI, node (event emission and the drift-guard lint only).

**Spec:** `docs/superpowers/specs/2026-08-09-lesson-transform-design.md`

## Global Constraints

- Hooks and libs are **bash**. No Python. Node only for event emission and lint scripts.
- Always use `${ONLOOKER_DIR:-$HOME/.onlooker}`, never a literal `~/.onlooker`.
- ULIDs, not UUIDs. Use the existing `librarian_ulid` from `librarian-ulid.sh`.
- Event types follow `<plugin>.<noun>.<verb>`.
- Config defaults live in `plugins/librarian/config.json`; overrides under the plugin namespace key (ADR-004).
- Every function fails soft. Hooks always exit 0 — they never block a session.
- Config is read via `librarian_config_get '<jq-path>'`.
- **The transform emits `versioned` scope only.** It must never emit `version_independent`.
- Valid version ranges: `<6`, `<=6`, `=6`, `>4`, `>=4`, `>=4 <6`. Invalid: `^5.4.21`, `~5`, `5.x`, bare `5.4.21`, `>=0`, `>=0.0`, `>=0.0.0`.
- American English in all comments and docs.

## File Structure

| File | Responsibility |
|---|---|
| `plugins/librarian/schema/lesson-evidence.subschema.json` | Vendored `evidence` sub-schema (source of truth for the jq rules) |
| `plugins/librarian/schema/lesson-applies-to.subschema.json` | Vendored `applies_to` sub-schema |
| `plugins/librarian/schema/PROVENANCE.json` | Where the vendored copies came from, and their `schema_version` |
| `plugins/librarian/scripts/lib/librarian-lesson-validate.sh` | Pure functions: pre-gate, range check, candidate validation. No I/O |
| `plugins/librarian/scripts/lib/librarian-lesson-storage.sh` | `lessons/` paths, proposal write, declined append, idempotency lookup |
| `plugins/librarian/scripts/lib/librarian-lesson-transform.sh` | Prompt building, `claude` call, orchestration |
| `plugins/librarian/scripts/hooks/librarian-session-end.sh` | Modified: source the libs, run the stage |
| `plugins/librarian/config.json` | Modified: `librarian.lesson_transform.*` defaults |
| `scripts/lint/check-lesson-schema-drift.mjs` | CI guard on the vendored copies |
| `test/bats/librarian-lesson-transform.bats` | All bats coverage for this stage |

**Note on decomposition:** the spec names a single `librarian-lesson-transform.sh`. This plan splits it three ways — pure logic, storage, orchestration — because the pure functions are where every high-risk rule lives and they are far easier to test without standing up a project key, a git repo, and a stubbed CLI. The spec's intent is unchanged.

**Task order note:** event emission is deliberately **last**. `librarian.lesson.proposed` and `librarian.lesson.declined` are not registered in `@onlooker-community/schema`, which is a separate published package. With a validator present (dev/CI) the emitter rejects an unregistered `event_type` and exits 1, so any test asserting on those events fails until the package publishes and is bumped here. Every other task is verified through on-disk artifacts and needs no schema change.

---

### Task 1: Vendored sub-schemas and provenance

**Files:**
- Create: `plugins/librarian/schema/lesson-evidence.subschema.json`
- Create: `plugins/librarian/schema/lesson-applies-to.subschema.json`
- Create: `plugins/librarian/schema/PROVENANCE.json`
- Create: `scripts/lint/check-lesson-schema-drift.mjs`
- Modify: `package.json`
- Test: `test/node/lesson-schema-drift.test.mjs`

**Interfaces:**
- Consumes: nothing.
- Produces: two JSON Schema files that Task 2's jq rules must mirror. `npm run lint:lesson-schema` exits 0 when provenance is intact.

- [ ] **Step 1: Extract the two sub-schemas from the published contract**

The source is `packages/lesson-contract/schema/lesson.schema.json` in the [onlooker](https://github.com/onlooker-community/onlooker) repo. If a sibling checkout exists, extract directly:

```bash
ONL=../onlooker   # adjust to your checkout
mkdir -p plugins/librarian/schema
jq '.properties.evidence' "$ONL/packages/lesson-contract/schema/lesson.schema.json" \
  > plugins/librarian/schema/lesson-evidence.subschema.json
jq '.properties.applies_to' "$ONL/packages/lesson-contract/schema/lesson.schema.json" \
  > plugins/librarian/schema/lesson-applies-to.subschema.json
```

If no checkout is available, copy the two objects from the spec's *Validation* section by hand. Verify afterward that `applies_to` contains a `scope.oneOf` with exactly two branches, and that the `versioned` branch's `additionalProperties.pattern` is present.

- [ ] **Step 2: Record provenance**

```bash
jq -n '{
  source_repo: "https://github.com/onlooker-community/onlooker",
  source_path: "packages/lesson-contract/schema/lesson.schema.json",
  schema_version: 2,
  extracted: ["properties.evidence", "properties.applies_to"],
  note: "Vendored because ajv is unavailable at runtime (ADR-005). Runtime enforcement is jq in librarian-lesson-validate.sh; these files are the source of truth those rules mirror. Upgrade to a fetch-and-compare guard once lesson schemas are published — schema.onlooker.dev serves none today."
}' > plugins/librarian/schema/PROVENANCE.json
```

- [ ] **Step 3: Write the failing drift test**

```javascript
// test/node/lesson-schema-drift.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const dir = 'plugins/librarian/schema';
const read = (f) => JSON.parse(readFileSync(`${dir}/${f}`, 'utf8'));

test('provenance pins schema_version 2', () => {
  assert.equal(read('PROVENANCE.json').schema_version, 2);
});

test('applies_to keeps a two-branch scope union', () => {
  const appliesTo = read('lesson-applies-to.subschema.json');
  const branches = appliesTo.properties.scope.oneOf;
  assert.equal(branches.length, 2);
  assert.deepEqual(
    branches.map((b) => b.properties.kind.const).sort(),
    ['version_independent', 'versioned'],
  );
});

test('the versioned branch requires at least one version and carries the range pattern', () => {
  const appliesTo = read('lesson-applies-to.subschema.json');
  const versioned = appliesTo.properties.scope.oneOf
    .find((b) => b.properties.kind.const === 'versioned');
  assert.equal(versioned.properties.versions.minProperties, 1);
  assert.ok(versioned.properties.versions.additionalProperties.pattern);
});

test('evidence requires a resolution', () => {
  assert.ok(read('lesson-evidence.subschema.json').required.includes('resolution'));
});
```

- [ ] **Step 4: Run it and watch it fail**

Run: `node --test test/node/lesson-schema-drift.test.mjs`
Expected: FAIL — files missing — until Steps 1-2 are done. If Steps 1-2 already ran, it passes; that is fine, the assertions still guard future edits.

- [ ] **Step 5: Wire the lint script**

```javascript
// scripts/lint/check-lesson-schema-drift.mjs
import { readFileSync } from 'node:fs';

const dir = 'plugins/librarian/schema';
let failures = 0;
const fail = (m) => { console.error(`check-lesson-schema: ${m}`); failures++; };

try {
  const prov = JSON.parse(readFileSync(`${dir}/PROVENANCE.json`, 'utf8'));
  if (prov.schema_version !== 2) fail(`expected schema_version 2, got ${prov.schema_version}`);
  for (const f of ['lesson-evidence.subschema.json', 'lesson-applies-to.subschema.json']) {
    JSON.parse(readFileSync(`${dir}/${f}`, 'utf8'));
  }
} catch (err) {
  fail(err.message);
}

if (failures > 0) process.exit(1);
console.log('check-lesson-schema: ok');
```

Add to `package.json` scripts:

```json
"lint:lesson-schema": "node scripts/lint/check-lesson-schema-drift.mjs"
```

And append it to the `test:ci` chain, after `lint:references`.

- [ ] **Step 6: Verify**

Run: `node --test test/node/lesson-schema-drift.test.mjs && npm run lint:lesson-schema`
Expected: all tests PASS, lint prints `check-lesson-schema: ok`.

- [ ] **Step 7: Commit**

```bash
git add plugins/librarian/schema scripts/lint/check-lesson-schema-drift.mjs \
        test/node/lesson-schema-drift.test.mjs package.json
git commit -m "feat(librarian): vendor the lesson sub-schemas the transform validates against :seedling:"
```

---

### Task 2: Pure validation library

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-lesson-validate.sh`
- Test: `test/bats/librarian-lesson-transform.bats`

**Interfaces:**
- Consumes: the vendored sub-schemas from Task 1 (as the specification the rules mirror; the code does not read them at runtime).
- Produces:
  - `librarian_lesson_pregate <artifact_json>` → exit 0 to proceed, 1 to skip
  - `librarian_lesson_valid_range <string>` → exit 0 when a valid version range
  - `librarian_lesson_validate_candidate <candidate_json>` → prints `""` when valid, or a reason slug (`schema_invalid`) on stderr; exit 0 valid, 1 invalid

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
#
# Pure validation rules for the lesson transform. No I/O, no CLI, no project
# key — these are the rules every candidate must satisfy before it is written.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
}

_artifact() {
  jq -cn --arg s "$1" --arg d "$2" '{summary: $s, detail: $d}'
}

@test "pregate accepts an artifact carrying a dotted version" {
  run librarian_lesson_pregate "$(_artifact "Vitest 4.1.9 breaks" "against Vite 5.4.21")"
  [ "$status" -eq 0 ]
}

@test "pregate accepts a v-prefixed version" {
  run librarian_lesson_pregate "$(_artifact "broken on v5" "see notes")"
  [ "$status" -eq 0 ]
}

@test "pregate accepts an x-range" {
  run librarian_lesson_pregate "$(_artifact "fails on 5.x" "see notes")"
  [ "$status" -eq 0 ]
}

@test "pregate skips an artifact with no version token at all" {
  run librarian_lesson_pregate "$(_artifact "Prefer functional patterns" "User said so during review.")"
  [ "$status" -eq 1 ]
}

@test "valid_range accepts the four comparator forms and a two-sided range" {
  for r in "<6" "<=6" "=6" ">4" ">=4" ">=4 <6"; do
    run librarian_lesson_valid_range "$r"
    [ "$status" -eq 0 ]
  done
}

@test "valid_range rejects npm-style ranges a model reaches for by default" {
  for r in "^5.4.21" "~5" "5.x" "5.4.21" "" "latest"; do
    run librarian_lesson_valid_range "$r"
    [ "$status" -eq 1 ]
  done
}

@test "valid_range rejects unbounded lower bounds that would never expire" {
  for r in ">=0" ">=0.0" ">=0.0.0" ">0"; do
    run librarian_lesson_valid_range "$r"
    [ "$status" -eq 1 ]
  done
}

@test "valid_range anchors to the whole string, not to a line within it" {
  # grep would match per line and accept this, diverging from the schema's
  # ECMA262 pattern, which has no /m flag.
  run librarian_lesson_valid_range "$(printf '<6\n>=999')"
  [ "$status" -eq 1 ]
}

_candidate() {
  jq -cn --argjson versions "$1" --argjson stack "$2" '{
    claim: "Vitest 4 cannot import vite/module-runner on Vite 5",
    rationale: "vite/module-runner ships in Vite 6; Vitest 4 assumes it exists.",
    evidence: {
      artifact_ids: ["01KZ45MKAM734ZS7JK24D2DK0R"],
      session_ids: ["sess-1"],
      project_key: "6a7678979e31",
      observed_at: "2026-08-03T15:59:48Z",
      resolution: "Pin vitest to 3.x until Vite 6 lands."
    },
    applies_to: {
      stack: $stack,
      scope: {kind: "versioned", versions: $versions},
      file_patterns: [],
      task_kinds: []
    }
  }'
}

@test "validate_candidate accepts a well-formed versioned candidate" {
  run librarian_lesson_validate_candidate \
    "$(_candidate '{"vite":"<6","vitest":">=4"}' '["vite","vitest"]')"
  [ "$status" -eq 0 ]
}

@test "validate_candidate rejects a versions key absent from stack" {
  run librarian_lesson_validate_candidate \
    "$(_candidate '{"vite":"<6","vitest":">=4"}' '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an invalid range inside an otherwise valid candidate" {
  run librarian_lesson_validate_candidate \
    "$(_candidate '{"vite":"^5.4.21"}' '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an empty versions object" {
  run librarian_lesson_validate_candidate "$(_candidate '{}' '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an empty-string range" {
  run librarian_lesson_validate_candidate "$(_candidate '{"vite":""}' '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects a range value carrying an embedded newline" {
  run librarian_lesson_validate_candidate \
    "$(_candidate "$(jq -cn '{vite: "<6\n>=999"}')" '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects a missing resolution" {
  candidate=$(_candidate '{"vite":"<6"}' '["vite"]' | jq -c 'del(.evidence.resolution)')
  run librarian_lesson_validate_candidate "$candidate"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an empty resolution" {
  candidate=$(_candidate '{"vite":"<6"}' '["vite"]' | jq -c '.evidence.resolution = ""')
  run librarian_lesson_validate_candidate "$candidate"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects version_independent even when well-formed" {
  candidate=$(_candidate '{"vite":"<6"}' '["vite"]' \
    | jq -c '.applies_to.scope = {kind: "version_independent", justification: "git behavior is stable"}')
  run librarian_lesson_validate_candidate "$candidate"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: FAIL — `librarian_lesson_pregate: command not found`.

- [ ] **Step 3: Implement the library**

```bash
#!/usr/bin/env bash
# Pure validation rules for lesson candidates. No I/O, no network, no CLI.
#
# These rules mirror the vendored sub-schemas in plugins/librarian/schema/.
# ajv cannot run at runtime (installed plugins ship no node_modules, ADR-005),
# so enforcement here is jq. The two mechanisms have been proven able to
# disagree, so tests assert them separately.

# Version-shaped token check. Returns 0 when the artifact could plausibly
# yield a versioned scope, 1 when it definitionally cannot.
#
# This rejects only what is impossible, never what is merely low quality:
# the transform can emit `versioned` scope alone, so an artifact with no
# version token anywhere cannot produce a valid scope.versions.
#
# Usage: librarian_lesson_pregate <artifact_json>
librarian_lesson_pregate() {
	local artifact="${1:-}"
	[[ -z "$artifact" ]] && return 1

	local text
	text=$(printf '%s' "$artifact" | jq -r '((.summary // "") + " " + (.detail // ""))' 2>/dev/null) || return 1
	[[ -z "$text" ]] && return 1

	# Dotted (5.4.21), v-prefixed (v5), or x-range (5.x).
	printf '%s' "$text" | grep -qE '([0-9]+\.[0-9]+)|(\bv[0-9]+)|([0-9]+\.x\b)'
}

# Version range check, mirroring the vendored pattern.
#
# Accepts: <6  <=6  =6  >4  >=4  ">=4 <6"
# Rejects: ^5.4.21  ~5  5.x  5.4.21  >=0  >=0.0.0
#
# The >= and > forms require a non-zero lower bound. An unbounded lower bound
# matches every session and would never expire — version independence in
# disguise, which this stage is not allowed to mint.
#
# Usage: librarian_lesson_valid_range <string>
librarian_lesson_valid_range() {
	local r="${1:-}"
	[[ -z "$r" ]] && return 1

	local nonzero='([1-9][0-9]*(\.[0-9]+)?(\.[0-9]+)?|0+\.[0-9]*[1-9][0-9]*(\.[0-9]+)?|0+\.0+\.[0-9]*[1-9][0-9]*)'
	local any='[0-9]+(\.[0-9]+)?(\.[0-9]+)?'
	local pattern="^((<|<=|=)${any}|(>|>=)${nonzero}|(>|>=)${any} (<|<=)${any})$"

	# Use bash's own regex engine rather than grep: grep's ^/$ anchor to line
	# boundaries, not string boundaries, so a value with an embedded newline
	# could smuggle a valid line past an otherwise-rejected string. [[ =~ ]]
	# anchors to the whole string. The pattern must stay unquoted here —
	# quoting the right-hand side of =~ forces literal string matching.
	#
	# Do NOT escape the angle brackets as \< and \>. In GNU/glibc regex those
	# are word-boundary assertions, not escaped literals, so an inlined
	# escaped pattern behaves differently on Linux CI than on macOS. Build the
	# pattern in a variable with plain < and > as above.
	[[ "$r" =~ $pattern ]]
}

# Validate a full candidate. Prints nothing on success; prints a reason slug
# to stderr on failure.
#
# Usage: librarian_lesson_validate_candidate <candidate_json>
librarian_lesson_validate_candidate() {
	local candidate="${1:-}"
	[[ -z "$candidate" ]] && { printf 'schema_invalid\n' >&2; return 1; }

	# Structural shape, including the versioned-only rule and a non-empty
	# resolution. `versions` must be a non-empty object.
	if ! printf '%s' "$candidate" | jq -e '
		(.claim | type) == "string" and (.claim | length) > 0
		and (.rationale | type) == "string" and (.rationale | length) > 0
		and (.evidence.artifact_ids | type) == "array" and (.evidence.artifact_ids | length) > 0
		and (.evidence.session_ids | type) == "array" and (.evidence.session_ids | length) > 0
		and (.evidence.project_key | type) == "string"
		and (.evidence.project_key | test("^[0-9a-f]{12}$"))
		and (.evidence.observed_at | type) == "string"
		and (.evidence.resolution | type) == "string" and (.evidence.resolution | length) > 0
		and (.applies_to.stack | type) == "array" and (.applies_to.stack | length) > 0
		and (.applies_to.file_patterns | type) == "array"
		and (.applies_to.task_kinds | type) == "array"
		and .applies_to.scope.kind == "versioned"
		and (.applies_to.scope.versions | type) == "object"
		and (.applies_to.scope.versions | length) > 0
	' >/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	# Cross-field rule JSON Schema cannot express: every versions key must
	# name an entry in stack.
	if ! printf '%s' "$candidate" | jq -e '
		(.applies_to.scope.versions | keys) - .applies_to.stack | length == 0
	' >/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	# Every range must satisfy the vendored pattern.
	# Do NOT skip empty values here. `jq -r '.versions[]'` over a non-empty
	# object of strings emits no stray blank lines, so a `continue` on empty
	# has no defensive purpose — it only lets `{"vite": ""}` validate, which
	# is exactly the shape a model emits when it could not pin a range down.
	local range
	while IFS= read -r range; do
		librarian_lesson_valid_range "$range" || { printf 'schema_invalid\n' >&2; return 1; }
	done < <(printf '%s' "$candidate" | jq -r '.applies_to.scope.versions[]' 2>/dev/null)

	return 0
}
```

- [ ] **Step 4: Run the tests**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: all PASS.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-validate.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add plugins/librarian/scripts/lib/librarian-lesson-validate.sh \
        test/bats/librarian-lesson-transform.bats
git commit -m "feat(librarian): enforce lesson candidate rules without a schema validator :closed_lock_with_key:"
```

---

### Task 3: Lesson storage and idempotency

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-lesson-storage.sh`
- Test: `test/bats/librarian-lesson-transform.bats` (append)

**Interfaces:**
- Consumes: `librarian_project_dir <key>` and `librarian_ulid` from the existing libs.
- Produces:
  - `librarian_lessons_dir <key>` → prints `<project_dir>/lessons`
  - `librarian_lesson_storage_init <key>` → creates `lessons/proposals` and `lessons/approved`
  - `librarian_lesson_write_proposal <key> <candidate_json> <artifact_id>` → prints the ULID written
  - `librarian_lesson_append_declined <key> <artifact_id> <reason> [detail]` → appends one JSONL line
  - `librarian_lesson_seen <key> <artifact_id>` → exit 0 when already handled, 1 when new

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-transform.bats`. This block needs a project key, so it stands up its own git repo:

```bash
_storage_setup() {
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-fixture.git
  PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]
  LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
}

@test "storage_init creates the proposals and approved directories" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  [ -d "${LESSONS_DIR}/proposals" ]
  [ -d "${LESSONS_DIR}/approved" ]
}

@test "write_proposal lands a ULID-keyed file carrying its artifact_id" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  candidate=$(jq -cn '{claim: "c", rationale: "r"}')
  id=$(librarian_lesson_write_proposal "$PROJECT_KEY" "$candidate" "01KZ45MKAM734ZS7JK24D2DK0R")
  [ -n "$id" ]
  [ -f "${LESSONS_DIR}/proposals/${id}.json" ]
  jq -e '.artifact_id == "01KZ45MKAM734ZS7JK24D2DK0R" and .candidate.claim == "c"' \
    "${LESSONS_DIR}/proposals/${id}.json"
}

@test "append_declined writes one JSONL line per decline" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZEAF9EY4C6TTR0V7YFN9VYJ" "no_versions"
  [ "$(wc -l < "${LESSONS_DIR}/declined.jsonl")" -eq 2 ]
  head -n 1 "${LESSONS_DIR}/declined.jsonl" \
    | jq -e '.artifact_id == "01KZ45MKAM734ZS7JK24D2DK0R" and .reason == "no_resolution"'
}

@test "seen reports a fresh artifact as new" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 1 ]
}

@test "seen finds an artifact recorded in declined.jsonl" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 0 ]
}

@test "seen finds an artifact already sitting in proposals" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_write_proposal "$PROJECT_KEY" "$(jq -cn '{claim: "c"}')" "01KZ45MKAM734ZS7JK24D2DK0R"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 0 ]
}

@test "seen finds an artifact already promoted into the approved pool" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  jq -n '{artifact_id: "01KZ45MKAM734ZS7JK24D2DK0R"}' \
    > "${LESSONS_DIR}/approved/01KZ45MKGQ7QZWMABQ4H12SHSV.json"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: the new tests FAIL with `librarian_lesson_storage_init: command not found`.

- [ ] **Step 3: Implement the library**

```bash
#!/usr/bin/env bash
# Storage for the lesson subtree.
#
#   <project_dir>/lessons/proposals/<ulid>.json   awaiting human confirmation
#   <project_dir>/lessons/approved/<ulid>.json    jury passed (written by 4z8.4)
#   <project_dir>/lessons/declined.jsonl          append-only, never re-judged
#
# Lessons live apart from librarian's memory `proposals/` on purpose: a memory
# promotion writes to this machine, a lesson proposal is a step toward
# publishing beyond it. Separate trees keep a confirmation surface from
# merging the two by accident.
#
# Requires librarian-storage.sh (librarian_project_dir) and librarian-ulid.sh.

librarian_lessons_dir() {
	local key="$1"
	printf '%s/lessons' "$(librarian_project_dir "$key")"
}

librarian_lesson_storage_init() {
	local key="$1"
	[[ -z "$key" ]] && return 1
	local dir
	dir=$(librarian_lessons_dir "$key")
	mkdir -p "$dir/proposals" "$dir/approved" 2>/dev/null
}

# Write one candidate. Prints the ULID on success.
# Usage: librarian_lesson_write_proposal <key> <candidate_json> <artifact_id>
librarian_lesson_write_proposal() {
	local key="$1"
	local candidate="$2"
	local artifact_id="$3"
	[[ -z "$key" || -z "$candidate" || -z "$artifact_id" ]] && return 1

	librarian_lesson_storage_init "$key" || return 1

	local id now out
	id=$(librarian_ulid) || return 1
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	out="$(librarian_lessons_dir "$key")/proposals/${id}.json"

	jq -n \
		--arg id "$id" \
		--arg artifact_id "$artifact_id" \
		--arg created "$now" \
		--argjson candidate "$candidate" \
		'{
			id: $id,
			artifact_id: $artifact_id,
			created_at: $created,
			status: "pending",
			candidate: $candidate
		}' > "$out" 2>/dev/null || return 1

	printf '%s' "$id"
}

# Append one decline. Only ever called for real determinations — never for a
# missing CLI, a timeout, or an empty response. Recording an outage here would
# bury a good artifact permanently, because the watermark has already moved
# past it and declined entries are never re-read.
#
# Usage: librarian_lesson_append_declined <key> <artifact_id> <reason> [detail]
librarian_lesson_append_declined() {
	local key="$1"
	local artifact_id="$2"
	local reason="$3"
	local detail="${4:-}"
	[[ -z "$key" || -z "$artifact_id" || -z "$reason" ]] && return 1

	librarian_lesson_storage_init "$key" || return 1

	local now line
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
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

	printf '%s\n' "$line" >> "$(librarian_lessons_dir "$key")/declined.jsonl"
}

# Returns 0 when this artifact has already been handled.
#
# The watermark cannot answer this: last_scan.json records only *when* we
# scanned, not which artifacts were considered. Idempotency is artifact-keyed
# and permanent, unlike tombstones (body-hash keyed, TTL'd).
#
# Usage: librarian_lesson_seen <key> <artifact_id>
librarian_lesson_seen() {
	local key="$1"
	local artifact_id="$2"
	[[ -z "$key" || -z "$artifact_id" ]] && return 1

	local dir
	dir=$(librarian_lessons_dir "$key")

	if [[ -f "$dir/declined.jsonl" ]] \
		&& jq -e --arg a "$artifact_id" 'select(.artifact_id == $a)' \
			"$dir/declined.jsonl" >/dev/null 2>&1; then
		return 0
	fi

	local f
	for f in "$dir"/proposals/*.json "$dir"/approved/*.json; do
		[[ -f "$f" ]] || continue
		if jq -e --arg a "$artifact_id" '.artifact_id == $a' "$f" >/dev/null 2>&1; then
			return 0
		fi
	done

	return 1
}
```

- [ ] **Step 4: Run the tests**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: all PASS.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-storage.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add plugins/librarian/scripts/lib/librarian-lesson-storage.sh \
        test/bats/librarian-lesson-transform.bats
git commit -m "feat(librarian): keep lesson state in its own subtree, keyed for idempotency :file_folder:"
```

---

### Task 4: The transform itself

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-lesson-transform.sh`
- Modify: `plugins/librarian/config.json`
- Test: `test/bats/librarian-lesson-transform.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_pregate`, `librarian_lesson_validate_candidate`, `librarian_lesson_write_proposal`, `librarian_lesson_append_declined`, `librarian_lesson_seen`.
- Produces:
  - `librarian_lesson_build_prompt <artifact_json>` → prints the prompt
  - `librarian_lesson_call <artifact_json> <model>` → prints raw model JSON, or empty on any infrastructure failure
  - `librarian_lesson_transform_one <key> <artifact_json>` → prints `proposed:<ulid>`, `declined:<reason>`, `skipped:pregate`, or `unavailable` (infrastructure). Exit 0 always.

- [ ] **Step 1: Add config defaults**

In `plugins/librarian/config.json`, add under the `librarian` key:

```json
"lesson_transform": {
  "model": "claude-haiku-4-5-20251001",
  "timeout_seconds": 20
}
```

There is no `enabled` flag — that option was removed repo-wide in #108.

**Only two keys, deliberately.** The spec listed `temperature` and
`max_output_tokens` as well, but `claude --help` exposes `--model` and no
sampling flags, so those values cannot reach the model through this CLI. The
existing `librarian-classifier.sh` reads
`.librarian.classifier.{temperature,max_output_tokens}` and passes them to a
function that ignores both — dead config that reads as if it works. Do not
reproduce it here. If sampling control is genuinely needed, it requires moving
off `claude -p` to the API, which is a separate decision.

- [ ] **Step 2: Write the failing tests**

Append to the bats file. This block extends `_storage_setup` with a stubbed `claude`:

```bash
_transform_setup() {
  _storage_setup
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-transform.sh"
  librarian_lesson_storage_init "$PROJECT_KEY"

  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
if [[ "$prompt" == *"module-runner"* ]]; then
  printf '%s' '{"claim":"Vitest 4 cannot import vite/module-runner on Vite 5","rationale":"vite/module-runner ships in Vite 6; Vitest 4 assumes it exists.","evidence":{"resolution":"Pin vitest to 3.x until Vite 6 lands."},"applies_to":{"stack":["vite","vitest"],"scope":{"kind":"versioned","versions":{"vite":"<6","vitest":">=4"}},"file_patterns":[],"task_kinds":[]}}'
elif [[ "$prompt" == *"no-resolution-stub"* ]]; then
  printf '%s' '{"eligible":false,"reason":"no_resolution"}'
elif [[ "$prompt" == *"no-versions-stub"* ]]; then
  printf '%s' '{"eligible":false,"reason":"no_versions"}'
elif [[ "$prompt" == *"npm-range-stub"* ]]; then
  printf '%s' '{"claim":"c","rationale":"r","evidence":{"resolution":"fix"},"applies_to":{"stack":["vite"],"scope":{"kind":"versioned","versions":{"vite":"^5.4.21"}},"file_patterns":[],"task_kinds":[]}}'
else
  printf '%s' 'not json at all'
fi
STUB
  chmod +x "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${PATH}"
}

_seed() {
  jq -cn --arg id "$1" --arg s "$2" --arg d "$3" --arg k "$PROJECT_KEY" \
    '{id: $id, kind: "decision", project_key: $k, session_id: "sess-1",
      created_at: "2026-08-03T15:59:48Z", summary: $s, detail: $d}'
}

@test "transform_one proposes a candidate for a groundable artifact" {
  _transform_setup
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [[ "$output" == proposed:* ]]
  id="${output#proposed:}"
  jq -e '.candidate.applies_to.scope.versions.vite == "<6"
     and .candidate.applies_to.scope.versions.vitest == ">=4"' \
    "${LESSONS_DIR}/proposals/${id}.json"
}

@test "transform_one declines the real vitest artifact for having no resolution" {
  _transform_setup
  # The artifact that motivated the pipeline. Its session ended on an open
  # question — the fix was never found — so it cannot become a lesson.
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" \
    "no-resolution-stub: Vitest 4.1.9 / Vite 5.x mismatch confirmed as real, blocking bug." \
    "Running pnpm test reproduces failures. Vitest 4.1.9 attempts to import vite/module-runner which does not exist in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [ "$output" = "declined:no_resolution" ]
  tail -n 1 "${LESSONS_DIR}/declined.jsonl" | jq -e '.reason == "no_resolution"'
}

@test "transform_one declines when the model cannot infer versions" {
  _transform_setup
  art=$(_seed "01KZ45MKGQ7QZWMABQ4H12SHSV" "no-versions-stub: 5.4 something" "detail 1.2")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "declined:no_versions" ]
}

@test "transform_one declines unparseable model output as transform_invalid" {
  _transform_setup
  art=$(_seed "01KZ45MKME229J0QK0690TREAB" "garbage 1.0" "detail 2.0")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "declined:transform_invalid" ]
}

@test "transform_one declines an npm-style range as schema_invalid" {
  _transform_setup
  art=$(_seed "01KZ45MKS84KPZQNWC02Z8FE0K" "npm-range-stub 5.4" "detail 1.0")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "declined:schema_invalid" ]
}

@test "transform_one skips a version-free artifact without touching the ledger" {
  _transform_setup
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Prefer functional patterns" "User said so.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "skipped:pregate" ]
  [ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "a missing claude CLI is not a verdict and writes nothing" {
  _transform_setup
  rm -f "${STUB_BIN}/claude"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [ "$output" = "unavailable" ]
  [ ! -f "${LESSONS_DIR}/declined.jsonl" ]
  [ -z "$(ls -A "${LESSONS_DIR}/proposals")" ]
}

@test "an empty model response is not a verdict and writes nothing" {
  _transform_setup
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf ''
STUB
  chmod +x "${STUB_BIN}/claude"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x" "module-runner missing in 5.4.21")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "unavailable" ]
  [ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "an already-declined artifact is not sent to the model a second time" {
  _transform_setup
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x" "module-runner missing in 5.4.21")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "skipped:seen" ]
  [ "$(wc -l < "${LESSONS_DIR}/declined.jsonl")" -eq 1 ]
}
```

- [ ] **Step 3: Run and watch them fail**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: the new tests FAIL with `librarian_lesson_transform_one: command not found`.

- [ ] **Step 4: Implement the transform**

```bash
#!/usr/bin/env bash
# Lesson transform — librarian's fifth stage.
#
# Reads one durable, classified, deduped archivist artifact and emits a lesson
# candidate: the four fields inferable from an artifact (claim, rationale,
# evidence, applies_to). The other nine required Lesson fields belong to later
# stages, so this never produces a schema-complete Lesson and cannot be
# validated against the full lesson schema.
#
# Requires librarian-lesson-validate.sh and librarian-lesson-storage.sh.

_LIBRARIAN_LESSON_TIMEOUT_SECONDS="${_LIBRARIAN_LESSON_TIMEOUT_SECONDS:-20}"

# Usage: librarian_lesson_build_prompt <artifact_json>
librarian_lesson_build_prompt() {
	local artifact="$1"
	local summary detail files_list artifact_id session_id project_key created_at

	summary=$(printf '%s' "$artifact" | jq -r '.summary // ""')
	detail=$(printf '%s' "$artifact" | jq -r '.detail // ""')
	files_list=$(printf '%s' "$artifact" | jq -r '(.files // []) | join(", ")')
	artifact_id=$(printf '%s' "$artifact" | jq -r '.id // ""')
	session_id=$(printf '%s' "$artifact" | jq -r '.session_id // ""')
	project_key=$(printf '%s' "$artifact" | jq -r '.project_key // ""')
	created_at=$(printf '%s' "$artifact" | jq -r '.created_at // ""')

	cat <<EOF
You are turning a session artifact into a shareable lesson, or refusing to.

A lesson states something that was learned, why it follows, and the exact
version range in which it holds. It is shared with other people, so a wrong
lesson actively misleads. Refusing is the safe answer.

Output ONLY one JSON object on one line. No markdown fences, no prose.

REFUSE when either is true, by outputting exactly:
  { "eligible": false, "reason": "no_resolution" }
  { "eligible": false, "reason": "no_versions" }

- "no_resolution": the artifact records a problem but not what resolved it.
  "This breaks" without "and this fixed it" is a warning, not a lesson.
  Never invent a resolution that is not in the artifact.
- "no_versions": you cannot determine which versions the claim is bound to.

Otherwise output:
{
  "claim": "<what was learned, one sentence>",
  "rationale": "<why the claim follows from the evidence>",
  "evidence": { "resolution": "<what actually resolved it, from the artifact>" },
  "applies_to": {
    "stack": ["<tool or package name>", ...],
    "scope": { "kind": "versioned", "versions": { "<stack entry>": "<range>" } },
    "file_patterns": [],
    "task_kinds": []
  }
}

VERSION RANGE RULES — these are strict and a violation is discarded:
- Allowed: "<6", "<=6", "=6", ">4", ">=4", or two-sided ">=4 <6".
- FORBIDDEN: npm syntax. Never "^5.4.21", "~5", "5.x", or a bare "5.4.21".
- FORBIDDEN: ">=0", ">=0.0", ">=0.0.0". An unbounded lower bound matches
  everything and would never expire.
- Every key in versions MUST also appear in stack.
- Generalize honestly. Observing a break on vite 5.4.21 with vitest 4.1.9
  supports {"vite": "<6", "vitest": ">=4"} only if the cause is the missing
  API rather than that exact build.

There is no version-independent option. If the claim is not bound to a
version range, refuse with "no_versions".

<artifact>
id: ${artifact_id}
summary: ${summary}
detail: ${detail}
files: ${files_list}
project_key: ${project_key}
session_id: ${session_id}
created_at: ${created_at}
</artifact>
EOF
}

# Call the model. Prints raw output, or empty string on ANY infrastructure
# failure — missing CLI, timeout, empty response. Empty means "could not
# judge", which is not a verdict.
#
# Usage: librarian_lesson_call <artifact_json> <model>
librarian_lesson_call() {
	local artifact="$1"
	local model="${2:-}"

	command -v claude >/dev/null 2>&1 || return 0
	[[ -z "$artifact" ]] && return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-lesson.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-lesson.$$"
	# shellcheck disable=SC2064
	trap "rm -f '$prompt_file'" EXIT

	librarian_lesson_build_prompt "$artifact" > "$prompt_file" || return 0

	local args=(-p --max-turns 1)
	[[ -n "$model" ]] && args+=(--model "$model")

	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$_LIBRARIAN_LESSON_TIMEOUT_SECONDS" \
			claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$_LIBRARIAN_LESSON_TIMEOUT_SECONDS" \
			claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi

	rm -f "$prompt_file"
	trap - EXIT

	[[ -z "$response" ]] && return 0
	printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//'
}

# Transform one artifact. Always exits 0. Prints exactly one of:
#   proposed:<ulid>       candidate written
#   declined:<reason>     a real verdict, recorded in declined.jsonl
#   skipped:pregate       no version token; free to redo, nothing recorded
#   skipped:seen          already handled
#   unavailable           infrastructure failure; nothing recorded
#
# Usage: librarian_lesson_transform_one <key> <artifact_json>
librarian_lesson_transform_one() {
	local key="$1"
	local artifact="$2"
	[[ -z "$key" || -z "$artifact" ]] && { printf 'unavailable'; return 0; }

	local artifact_id session_id project_key created_at
	artifact_id=$(printf '%s' "$artifact" | jq -r '.id // ""')
	session_id=$(printf '%s' "$artifact" | jq -r '.session_id // ""')
	project_key=$(printf '%s' "$artifact" | jq -r '.project_key // ""')
	created_at=$(printf '%s' "$artifact" | jq -r '.created_at // ""')
	[[ -z "$artifact_id" ]] && { printf 'unavailable'; return 0; }

	if librarian_lesson_seen "$key" "$artifact_id"; then
		printf 'skipped:seen'
		return 0
	fi

	if ! librarian_lesson_pregate "$artifact"; then
		printf 'skipped:pregate'
		return 0
	fi

	local model raw
	model=$(librarian_config_get '.librarian.lesson_transform.model')

	raw=$(librarian_lesson_call "$artifact" "$model")

	# Empty means infrastructure, not verdict. Leave the artifact untouched.
	if [[ -z "$raw" ]]; then
		printf 'unavailable'
		return 0
	fi

	if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
		librarian_lesson_append_declined "$key" "$artifact_id" "transform_invalid"
		printf 'declined:transform_invalid'
		return 0
	fi

	# An explicit refusal is a real answer.
	local eligible reason
	eligible=$(printf '%s' "$raw" | jq -r '.eligible // empty')
	if [[ "$eligible" == "false" ]]; then
		reason=$(printf '%s' "$raw" | jq -r '.reason // "transform_invalid"')
		case "$reason" in
			no_resolution|no_versions) ;;
			*) reason="transform_invalid" ;;
		esac
		librarian_lesson_append_declined "$key" "$artifact_id" "$reason"
		printf 'declined:%s' "$reason"
		return 0
	fi

	# Stitch in the provenance the model is not asked to produce.
	local candidate
	candidate=$(printf '%s' "$raw" | jq -c \
		--arg aid "$artifact_id" \
		--arg sid "$session_id" \
		--arg pk "$project_key" \
		--arg at "$created_at" \
		'.evidence.artifact_ids = [$aid]
		 | .evidence.session_ids = [$sid]
		 | .evidence.project_key = $pk
		 | .evidence.observed_at = $at' 2>/dev/null) || candidate=""

	if [[ -z "$candidate" ]]; then
		librarian_lesson_append_declined "$key" "$artifact_id" "transform_invalid"
		printf 'declined:transform_invalid'
		return 0
	fi

	if ! librarian_lesson_validate_candidate "$candidate" 2>/dev/null; then
		librarian_lesson_append_declined "$key" "$artifact_id" "schema_invalid"
		printf 'declined:schema_invalid'
		return 0
	fi

	local id
	id=$(librarian_lesson_write_proposal "$key" "$candidate" "$artifact_id") || {
		printf 'unavailable'
		return 0
	}
	printf 'proposed:%s' "$id"
}
```

- [ ] **Step 5: Run the tests**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: all PASS.

`_transform_setup` must also source `librarian-config.sh` and call `librarian_config_load "$PROJECT_REPO"` — not conditionally. `librarian_lesson_transform_one` calls `librarian_config_get`, which reads the `_LIBRARIAN_CONFIG` global; without a load that global is `{}` and the model lookup returns empty. The call still succeeds (an empty model just omits `--model`), so skipping the load would leave the config path silently unexercised rather than failing loudly. Add both lines to `_transform_setup`:

```bash
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
  librarian_config_load "$PROJECT_REPO"
```

- [ ] **Step 6: Shellcheck**

Run: `shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-transform.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add plugins/librarian/scripts/lib/librarian-lesson-transform.sh \
        plugins/librarian/config.json test/bats/librarian-lesson-transform.bats
git commit -m "feat(librarian): transform artifacts into lesson candidates, refusing what it cannot ground :microscope:"
```

---

### Task 5: Wire the stage into SessionEnd

**Files:**
- Modify: `plugins/librarian/scripts/hooks/librarian-session-end.sh`
- Test: `test/bats/librarian-lesson-transform.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_transform_one <key> <artifact_json>` from Task 4.
- Produces: no new functions. The hook runs the stage over the same filtered artifact set the classifier sees.

- [ ] **Step 1: Write the failing end-to-end test**

```bash
@test "SessionEnd runs the lesson stage and lands a candidate on disk" {
  _transform_setup

  HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-end.sh"
  ARCHIVIST_DIR="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
  mkdir -p "${ARCHIVIST_DIR}/decisions"

  created_at=$(relative_iso_days_ago 1)
  jq -n --arg id "01KZ45MKAM734ZS7JK24D2DK0R" --arg at "$created_at" --arg k "$PROJECT_KEY" \
    '{id: $id, kind: "decision", project_key: $k, session_id: "sess-1",
      created_at: $at, updated_at: $at,
      summary: "Vitest 4.1.9 / Vite 5.x mismatch, decided to pin",
      detail: "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.",
      files: ["packages/db"]}' \
    > "${ARCHIVIST_DIR}/decisions/01KZ45MKAM734ZS7JK24D2DK0R.json"

  input=$(jq -cn --arg cwd "$PROJECT_REPO" \
    '{cwd: $cwd, session_id: "sess-1", hook_event_name: "SessionEnd"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"

  [ "$status" -eq 0 ]
  [ -n "$(ls -A "${LESSONS_DIR}/proposals" 2>/dev/null)" ]
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: FAIL — the proposals directory is empty, because the hook does not run the stage yet.

- [ ] **Step 3: Source the new libs in the hook**

In `plugins/librarian/scripts/hooks/librarian-session-end.sh`, after the existing `librarian-conflict-detector.sh` source line (around line 61), add:

```bash
# shellcheck source=../lib/librarian-lesson-validate.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
# shellcheck source=../lib/librarian-lesson-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
# shellcheck source=../lib/librarian-lesson-transform.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-transform.sh"
```

- [ ] **Step 4: Run the stage over the filtered artifacts**

Iterate `$KEPT`, **not** `$FILTERED`. `librarian_durability_filter` returns an
object `{kept: [...], dropped: [...]}` (hook line 151); `KEPT` is the array
extracted from it at line 152, and `KEPT_COUNT` is already computed at line 208.
Iterating `FILTERED` directly would yield the two arrays, not artifacts.

Match the classifier loop's idiom — a C-style index loop with `jq -c ".[$i]"` —
rather than introducing a `while read` pattern the file does not use. Use
distinct variable names so nothing from the classifier loop is clobbered.

Add after the classifier loop completes, before the watermark is written:

```bash
# ---------------------------------------------------------------------------
# Stage 5 — lesson transform.
#
# Runs over the same durability survivors the classifier saw. Each artifact is
# independent: a decline or an outage on one never stops the rest.
# ---------------------------------------------------------------------------
LESSON_PROPOSED=0
LESSON_DECLINED=0

for ((li = 0; li < KEPT_COUNT; li++)); do
	LESSON_ARTIFACT=$(printf '%s' "$KEPT" | jq -c ".[$li]")
	[[ -z "$LESSON_ARTIFACT" || "$LESSON_ARTIFACT" == "null" ]] && continue

	LESSON_RESULT=$(librarian_lesson_transform_one "$PROJECT_KEY" "$LESSON_ARTIFACT")
	case "$LESSON_RESULT" in
		proposed:*) LESSON_PROPOSED=$((LESSON_PROPOSED + 1)) ;;
		declined:*) LESSON_DECLINED=$((LESSON_DECLINED + 1)) ;;
	esac
done
```

- [ ] **Step 5: Run the tests**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: all PASS.

- [ ] **Step 6: Confirm nothing upstream regressed**

Run: `bats test/bats/librarian-session-end.bats && bats test/bats/librarian-session-start.bats && bats test/bats/librarian-cli.bats`
Expected: all PASS. The existing suite must be unaffected — the new stage only appends.

- [ ] **Step 7: Full check**

Run: `npm run test:ci`
Expected: exit 0.

- [ ] **Step 8: Commit**

```bash
git add plugins/librarian/scripts/hooks/librarian-session-end.sh \
        test/bats/librarian-lesson-transform.bats
git commit -m "feat(librarian): run the lesson stage at session end :link:"
```

---

### Task 6: Emit the stage's events

**Blocked on a cross-repo change.** `librarian.lesson.proposed` and `librarian.lesson.declined` must first be registered in `@onlooker-community/schema` (a separate published package) and the `devDependency` bumped here. Until then the emitter rejects both types in dev and CI and exits 1. Verify with:

```bash
printf '%s' '{"plugin":"librarian","session_id":"probe","event_type":"librarian.lesson.proposed","payload":{}}' \
  | node scripts/lib/onlooker-event.mjs emit
```

Expected once unblocked: a JSON event on stdout rather than a `/event_type must be equal to one of the allowed values` error.

**Files:**
- Modify: `plugins/librarian/scripts/hooks/librarian-session-end.sh`
- Test: `test/bats/librarian-lesson-transform.bats` (append)

**Interfaces:**
- Consumes: `librarian_emit <event_type> <session_id> <payload_json>` from `librarian-emit.sh`.
- Produces: two event types on the bus.

- [ ] **Step 1: Write the failing test**

```bash
@test "SessionEnd emits a schema-valid lesson.proposed event" {
  _transform_setup

  HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-end.sh"
  ARCHIVIST_DIR="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
  mkdir -p "${ARCHIVIST_DIR}/decisions"

  created_at=$(relative_iso_days_ago 1)
  jq -n --arg id "01KZ45MKAM734ZS7JK24D2DK0R" --arg at "$created_at" --arg k "$PROJECT_KEY" \
    '{id: $id, kind: "decision", project_key: $k, session_id: "sess-1",
      created_at: $at, updated_at: $at,
      summary: "Vitest 4.1.9 / Vite 5.x mismatch, decided to pin",
      detail: "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.",
      files: ["packages/db"]}' \
    > "${ARCHIVIST_DIR}/decisions/01KZ45MKAM734ZS7JK24D2DK0R.json"

  input=$(jq -cn --arg cwd "$PROJECT_REPO" \
    '{cwd: $cwd, session_id: "sess-1", hook_event_name: "SessionEnd"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ]

  grep '"event_type":"librarian.lesson.proposed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.source_artifact_id == "01KZ45MKAM734ZS7JK24D2DK0R"' >/dev/null

  grep '"event_type":"librarian.lesson.proposed"' "$ONLOOKER_EVENTS_LOG" | tail -n 1 \
    | ONLOOKER_DIR="$ONLOOKER_DIR" node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: FAIL — no matching line in the event log.

- [ ] **Step 3: Emit from the stage loop**

Extend the `case` added in Task 5:

```bash
	case "$LESSON_RESULT" in
		proposed:*)
			LESSON_PROPOSED=$((LESSON_PROPOSED + 1))
			librarian_emit "librarian.lesson.proposed" "$SESSION_ID" "$(jq -cn \
				--arg lesson_id "${LESSON_RESULT#proposed:}" \
				--arg src "$(printf '%s' "$LESSON_ARTIFACT" | jq -r '.id // ""')" \
				'{ lesson_id: $lesson_id, source_artifact_id: $src }')"
			;;
		declined:*)
			LESSON_DECLINED=$((LESSON_DECLINED + 1))
			librarian_emit "librarian.lesson.declined" "$SESSION_ID" "$(jq -cn \
				--arg reason "${LESSON_RESULT#declined:}" \
				--arg src "$(printf '%s' "$LESSON_ARTIFACT" | jq -r '.id // ""')" \
				'{ reason: $reason, source_artifact_id: $src }')"
			;;
	esac
```

`SESSION_ID` is already set at `librarian-session-end.sh:76` from the hook payload, defaulting to `"unknown"`, and is the same variable the existing `librarian_emit` calls use.

- [ ] **Step 4: Run the tests**

Run: `bats test/bats/librarian-lesson-transform.bats`
Expected: all PASS.

- [ ] **Step 5: Full check**

Run: `npm run test:ci`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add plugins/librarian/scripts/hooks/librarian-session-end.sh \
        test/bats/librarian-lesson-transform.bats
git commit -m "feat(librarian): put lesson proposals and declines on the event bus :satellite:"
```

---

## Self-review notes

**Spec coverage.** Every section of the spec maps to a task: placement and storage → Tasks 3 and 5; the three steps → Tasks 2 and 4; validation and the vendored sub-schemas → Tasks 1 and 2; the failure taxonomy → Task 4's tests, with all eight rows covered; idempotency → Task 3; testing → tests inside each task; events → Task 6.

**Deliberately deferred.** The spec's *Boundary changes* section notes that `4z8.2` gains the `version_independent` human path. That is not in this plan — it belongs to that issue. `4z8.4` reusing `librarian_lesson_append_declined` is satisfied by Task 3 creating it here.

**Known gap.** The CI drift guard in Task 1 is weaker than the event-schema equivalent, because `schema.onlooker.dev` currently serves no lesson schema. It pins provenance and structure but cannot detect an upstream contract change. File a follow-up to upgrade it once lesson schemas are published.

**Two corrections to the spec, folded in here and back into the spec itself.** The spec claimed the CI drift guard could fetch from `schema.onlooker.dev`; it cannot, and the note above replaces that. The spec also listed four config keys, but `claude -p` accepts no sampling flags, so `temperature` and `max_output_tokens` would be dead config — Task 4 ships two keys instead.

**Adjacent bug found, not fixed here.** `librarian-classifier.sh` reads `.librarian.classifier.temperature` and `.max_output_tokens` and passes them to `librarian_classifier_call`, which ignores both. The config reads as though it tunes the classifier and does not. Out of scope for this plan — worth its own issue.
