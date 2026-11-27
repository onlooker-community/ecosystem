# Transform Derives Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The lesson transform stops asking the model for a scope. It asks
for a stack of things with a version plus topics, reads versions with
Observe, and derives the scope itself. This is rollout step 3 of
`docs/superpowers/specs/2026-11-26-evidenced-lesson-portability-design.md`.

**Architecture:** First, librarian's vendored lesson sub-schemas and their jq
mirror move to lesson-contract 2.2.0, so a candidate can carry `topics`,
`observed_on`, `unresolved` and a `no_stack` scope. A new pure lib,
`librarian-lesson-scope.sh`, turns an Observe result into a scope by D4 and
D5. The transform drops its two prompt modes and its pre-gate. It calls
`librarian_lesson_observe` after the model answers, and stitches the
observation and the derived scope into the candidate. `lesson_auto` enforces
D6: a candidate with any unresolved entry stays pending for a person.

**Tech Stack:** bash, jq, node (Observe and the ajv agreement tests), bats,
node:test.

## Global Constraints

- The contract is lesson-contract **2.2.0** (onlooker `origin/main`,
  `packages/lesson-contract/schema/lesson.schema.json`). Vendored files are
  copied from it byte for byte with `jq '.'`. They are never hand-edited.
- D4, verbatim: for an observed version `X.Y.Z`, `X >= 1` gives
  `>=X.Y.Z <X+1`, and `X == 0` gives `>=0.Y.Z <0.Y+1`. A version that doesn't
  parse as at least `X.Y` stays in `observed_on` and is left out of
  `scope.versions`. It does not go in `unresolved`.
- D5: `no_stack` is valid only when `applies_to.stack` is empty. An empty
  stack is valid only with `no_stack`.
- D6: `evidence.unresolved` lists stack entries no source could version. A
  candidate with any unresolved entry is never confirmed unattended.
- `unscoped` stays a pending-only kind. The transform validator accepts it,
  and the confirmed validator and the vendored pool schema refuse it.
- The model never writes `scope`. If it does, the transform discards it.
- `version_independent` is still produced only through a person's or
  `lesson_auto`'s justification. Retiring that is rollout step 5, not this
  plan.
- Nothing new runs at SessionEnd. Observe runs inside the transform, which is
  already detached (ADR-003).
- Every new or changed event payload must be registered in
  `@onlooker-community/schema` first. This plan adds none.
- Tests: bats uses `setup_test_env`. Every non-final `[[ ]]`, `(( ))` and `!`
  is gated with `|| return 1`. Run one file with
  `scripts/test/run-bats.sh <file>`.
- Commits follow `/git-workflow:commit`'s contract and end with
  `Refs ONL-314`. Use American English.

---

### Task 1: Vendor lesson-contract 2.2.0 and mirror it in jq

**Files:**
- Modify: `plugins/librarian/schema/lesson-applies-to.subschema.json` (regenerate)
- Modify: `plugins/librarian/schema/lesson-evidence.subschema.json` (regenerate)
- Modify: `plugins/librarian/schema/lesson-applies-to-pending.local.schema.json` (regenerate)
- Modify: `plugins/librarian/schema/PROVENANCE.json`
- Create: `scripts/lib/derive-pending-applies-to.mjs`
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-validate.sh`
- Test: `test/node/lesson-validate-agreement.test.mjs`
- Test: `test/bats/librarian-lesson-transform.bats` (the validator tests near the top)

**Interfaces:**
- Produces: `librarian_lesson_validate_candidate` accepts scope kinds
  `versioned`, `unscoped` and `no_stack`. It accepts optional
  `applies_to.topics`, `evidence.observed_on` and `evidence.unresolved`, and
  enforces the stack ⇔ `no_stack` pairing plus three cross-field rules:
  `observed_on` keys ⊆ stack, `unresolved` ⊆ stack, and the two are disjoint.
- Produces: `librarian_lesson_validate_confirmed` accepts `versioned`,
  `version_independent` and `no_stack`, with the same new fields and rules.
- Produces: `derivePending(appliesTo)` from
  `scripts/lib/derive-pending-applies-to.mjs` returns the pending schema for
  a vendored `applies_to` schema.

- [ ] **Step 1: Regenerate the vendored files**

```bash
CONTRACT=$(git -C ../onlooker show origin/main:packages/lesson-contract/schema/lesson.schema.json)
printf '%s' "$CONTRACT" | jq '.properties.applies_to' > plugins/librarian/schema/lesson-applies-to.subschema.json
printf '%s' "$CONTRACT" | jq '.properties.evidence' > plugins/librarian/schema/lesson-evidence.subschema.json
```

Run `git -C ../onlooker fetch -q origin` first. Confirm that
`jq '.anyOf | map(.title)'` on the applies_to file prints
`["with_stack","no_stack"]`.

- [ ] **Step 2: Write the pending derivation**

`scripts/lib/derive-pending-applies-to.mjs`:

```js
#!/usr/bin/env node
// The pending-state applies_to schema is the vendored one with
// version_independent swapped for unscoped in the with_stack branch. Derived,
// never hand-edited, so it can't drift from the contract it shadows.
//
// Usage: node scripts/lib/derive-pending-applies-to.mjs --write

import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const UNSCOPED = {
  type: 'object',
  properties: { kind: { type: 'string', const: 'unscoped' } },
  required: ['kind'],
  additionalProperties: false,
};

export function derivePending(appliesTo) {
  const out = structuredClone(appliesTo);
  const withStack = out.anyOf.find((b) => b.title === 'with_stack');
  if (!withStack) throw new Error('vendored applies_to has no with_stack branch');
  const kinds = withStack.properties.scope.oneOf;
  const i = kinds.findIndex((k) => k.properties?.kind?.const === 'version_independent');
  if (i < 0) throw new Error('with_stack scope has no version_independent member');
  kinds[i] = UNSCOPED;
  return out;
}

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.join(here, '..', '..', 'plugins', 'librarian', 'schema');
if (process.argv.includes('--write')) {
  const vendored = JSON.parse(readFileSync(path.join(dir, 'lesson-applies-to.subschema.json'), 'utf8'));
  writeFileSync(
    path.join(dir, 'lesson-applies-to-pending.local.schema.json'),
    `${JSON.stringify(derivePending(vendored), null, 2)}\n`,
  );
}
```

Run `node scripts/lib/derive-pending-applies-to.mjs --write`. If the with_stack
scope in the vendored file isn't a `oneOf`, read the file and adjust only the
property path. Don't change what gets swapped.

In `PROVENANCE.json`, add `"contract_version": "2.2.0"`. Replace the pending
schema's description with: "Derived by scripts/lib/derive-pending-applies-to.mjs:
the vendored applies_to with version_independent swapped for unscoped in the
with_stack branch. Not upstream, and never hand-edited (ONL-107)."

- [ ] **Step 3: Write the failing agreement tests**

At the end of `test/node/lesson-validate-agreement.test.mjs`, add an import
of `derivePending` beside the others, then:

```js
describe('lesson-contract 2.2.0 shapes', () => {
  const noStack = () => {
    const c = baseCandidate();
    c.applies_to = { stack: [], scope: { kind: 'no_stack' }, file_patterns: [], task_kinds: [], topics: ['testing'] };
    return c;
  };
  const observed = (extra = {}) =>
    withEvidence({
      observed_on: { vite: { version: '5.4.21', source: 'lockfile', basis: 'session_commit' } },
      unresolved: [],
      ...extra,
    });

  it('the pending schema is exactly the derivation of the vendored one', () => {
    assert.deepEqual(appliesToPendingSchema, derivePending(appliesToSchema));
  });

  it('agree that a no_stack candidate with topics is accepted', () => {
    assertAgree('no_stack', noStack(), true);
    assert.equal(jqAccepts(noStack(), 'librarian_lesson_validate_confirmed'), true);
    assert.equal(pendingSchemaAccepts(noStack()), true);
  });

  it('agree that an empty stack under versioned is rejected', () => {
    assertAgree('empty stack versioned', withAppliesTo({ stack: [] }), false);
  });

  it('agree that no_stack beside a non-empty stack is rejected', () => {
    assertAgree('no_stack with stack', withAppliesTo({ scope: { kind: 'no_stack' } }), false);
  });

  it('agree that topics on a with-stack candidate are accepted', () => {
    assertAgree('topics', withAppliesTo({ topics: ['bundling'] }), true);
  });

  it('agree that an empty topic is rejected', () => {
    assertAgree('empty topic', withAppliesTo({ topics: [''] }), false);
  });

  it('agree that observed_on and unresolved are accepted', () => {
    assertAgree('observed', observed(), true);
  });

  it('agree that an observation with a flavor is accepted', () => {
    assertAgree(
      'flavor',
      observed({ observed_on: { vite: { version: '20200816', source: 'probe', basis: 'machine', flavor: 'bsd' } } }),
      true,
    );
  });

  for (const [name, obs] of [
    ['an unknown source', { version: '1.0.0', source: 'guess', basis: 'head' }],
    ['a truncated source', { version: '1.0.0', source: 'lock', basis: 'head' }],
    ['a non-string source', { version: '1.0.0', source: 7, basis: 'head' }],
    ['an unknown basis', { version: '1.0.0', source: 'lockfile', basis: 'today' }],
    ['an empty version', { version: '', source: 'lockfile', basis: 'head' }],
    ['an extra observation key', { version: '1.0.0', source: 'lockfile', basis: 'head', note: 'x' }],
    ['a missing basis', { version: '1.0.0', source: 'lockfile' }],
  ]) {
    it(`agree that ${name} is rejected`, () => {
      assertAgree(name, observed({ observed_on: { vite: obs } }), false);
    });
  }

  // JSON Schema can't express these, so jq alone enforces them, mirroring the
  // contract's ingest rules in onlooker apps/api/src/lessons/rules.ts.
  it('jq refuses an observed_on key outside stack', () => {
    const c = observed({ observed_on: { react: { version: '18.2.0', source: 'manifest', basis: 'head' } } });
    assert.equal(schemaAccepts(c), true);
    assert.equal(jqAccepts(c), false);
  });

  it('jq refuses an unresolved entry outside stack', () => {
    const c = observed({ unresolved: ['Sentry'] });
    assert.equal(schemaAccepts(c), true);
    assert.equal(jqAccepts(c), false);
  });

  it('jq refuses an entry both observed and unresolved', () => {
    const c = observed({ unresolved: ['vite'] });
    assert.equal(schemaAccepts(c), true);
    assert.equal(jqAccepts(c), false);
  });

  it('the pending schema refuses unscoped beside an empty stack', () => {
    const c = noStack();
    c.applies_to.scope = { kind: 'unscoped' };
    assert.equal(pendingSchemaAccepts(c), false);
    assert.equal(jqAccepts(c), false);
  });
});
```

Run: `npm run test:schema`
Expected: FAIL. The derivation test passes, because Step 2 already wrote the
file, but the no_stack, topics and observed_on cases fail on jq.

- [ ] **Step 4: Update the jq mirror**

In `librarian-lesson-validate.sh`, in `_LIBRARIAN_LESSON_STRUCTURAL`:

- Change the evidence key list to
  `["artifact_ids", "session_ids", "project_key", "observed_at", "resolution", "observed_on", "unresolved"]`.
- After the `resolution` line, add:

```jq
	and ((.evidence | has("observed_on") | not)
		or ((.evidence.observed_on | type) == "object"
			and (.evidence.observed_on | to_entries | all(
				(.key | length) > 0
				and (.value | type) == "object"
				and ((.value | keys) - ["version", "source", "basis", "flavor"] | length) == 0
				and (.value.version | type) == "string" and (.value.version | length) > 0
				and (.value.source | IN("lockfile", "manifest", "mise", "workflow", "component", "probe"))
				and (.value.basis | IN("session_commit", "head", "machine"))
				and ((.value | has("flavor") | not) or (.value.flavor | IN("gnu", "bsd")))
			))))
	and ((.evidence | has("unresolved") | not)
		or ((.evidence.unresolved | type) == "array"
			and (.evidence.unresolved | all(type == "string" and length > 0))))
```

- Change the applies_to key list to
  `["stack", "scope", "file_patterns", "task_kinds", "topics"]`.
- Replace `and (.applies_to.stack | type) == "array" and (.applies_to.stack | length) > 0`
  with:

```jq
	and (.applies_to.stack | type) == "array"
	# D5: an empty stack and the no_stack kind come together or not at all.
	and (((.applies_to.stack | length) == 0) == (.applies_to.scope.kind == "no_stack"))
```

- After the `task_kinds` lines, add:

```jq
	and ((.applies_to | has("topics") | not)
		or ((.applies_to.topics | type) == "array"
			and (.applies_to.topics | all(type == "string" and length > 0))))
```

Use `IN`, not `inside`: `inside` matches substrings on strings, so `"lock"`
would pass as `"lockfile"`. The agreement test's `a truncated source` case
pins this.

Add a scope branch beside the other two:

```bash
# The no_stack branch, legal in both validators. It needs no justification:
# with nothing in the stack, there is nothing to have a version (D5).
_LIBRARIAN_LESSON_SCOPE_NO_STACK='
	.applies_to.scope.kind == "no_stack"
	and ((.applies_to.scope | keys) - ["kind"] | length) == 0
'
```

Add `or ('"${_LIBRARIAN_LESSON_SCOPE_NO_STACK}"')` to the `scope_clause` of
both `librarian_lesson_validate_candidate` and
`librarian_lesson_validate_confirmed`. Update each function's comment to
list the kinds it accepts.

Add a function for the cross-field rules, and call it from both validators
after the structural check, on every kind:

```bash
# The three cross-field evidence rules JSON Schema can't express, mirroring
# onlooker's ingest (apps/api/src/lessons/rules.ts): an observed or unresolved
# entry names something in stack, and no entry is both.
_librarian_lesson_check_observation() {
	printf '%s' "$1" | jq -e '
		.applies_to.stack as $s
		| ((.evidence.observed_on // {}) | keys) as $o
		| (.evidence.unresolved // []) as $u
		| ($o - $s | length) == 0
		and ($u - $s | length) == 0
		and ([$o[] | select(. as $k | $u | index($k))] | length) == 0
	' >/dev/null 2>&1
}
```

- [ ] **Step 5: Update the bats validator tests**

In `test/bats/librarian-lesson-transform.bats`, the existing validator tests
stay as they are. Add these after "validate_candidate rejects a versions
value with an embedded newline":

```bash
_no_stack_candidate() {
  jq -cn '{
    claim: "Name a test for what it asserts",
    rationale: "A reader trusts the name before the body.",
    evidence: {
      artifact_ids: ["01KZ45MKAM734ZS7JK24D2DK0R"], session_ids: ["sess-1"],
      project_key: "6a7678979e31", observed_at: "2026-08-03T15:59:48Z",
      resolution: "Renamed the tests.", observed_on: {}, unresolved: []
    },
    applies_to: {stack: [], scope: {kind: "no_stack"}, file_patterns: [],
      task_kinds: [], topics: ["testing"]}
  }'
}

@test "validate_candidate accepts a no_stack candidate with topics" {
  run librarian_lesson_validate_candidate "$(_no_stack_candidate)"
  [ "$status" -eq 0 ]
}

@test "validate_confirmed accepts a no_stack candidate" {
  run librarian_lesson_validate_confirmed "$(_no_stack_candidate)"
  [ "$status" -eq 0 ]
}

@test "validate_candidate rejects no_stack carrying a stack entry" {
  run librarian_lesson_validate_candidate "$(_no_stack_candidate | jq -c '.applies_to.stack = ["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an observed key that is not in stack" {
  run librarian_lesson_validate_candidate "$(_no_stack_candidate \
    | jq -c '.evidence.observed_on = {vite: {version: "5.4.21", source: "lockfile", basis: "head"}}')"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 6: Run the tests**

Run: `npm run test:schema && scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats`
Expected: PASS. Then run `npm run lint:lesson-schema` and expect `ok`.

- [ ] **Step 7: Commit**

```bash
git add plugins/librarian/schema scripts/lib/derive-pending-applies-to.mjs \
  plugins/librarian/scripts/lib/librarian-lesson-validate.sh \
  test/node/lesson-validate-agreement.test.mjs test/bats/librarian-lesson-transform.bats
```

Message: `feat(librarian): accept the observed-versions contract in candidates :inbox_tray:`.
In the body, say that lesson-contract 2.2.0 is vendored, that the pending
schema is now derived, not copied, and that jq mirrors the three ingest
rules.

---

### Task 2: Derive a scope from an observation

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-lesson-scope.sh`
- Test: `test/bats/librarian-lesson-scope.bats`

**Interfaces:**
- Consumes: Observe's output shape
  `{"observed_on": {<entry>: {version, source, basis[, flavor]}}, "unresolved": [...]}`.
- Produces: `librarian_lesson_range_for_version <version>` prints a D4 range
  or nothing. `librarian_lesson_scope_from_observation <stack_json> <observation_json>`
  prints one compact scope object:
  - `{"kind":"no_stack"}` when the stack is empty
  - `{"kind":"versioned","versions":{...}}` when at least one entry has a range
  - `{"kind":"unscoped"}` otherwise

  Both functions always exit 0.

- [ ] **Step 1: Write the failing tests**

`test/bats/librarian-lesson-scope.bats`:

```bash
#!/usr/bin/env bats
# D4 and D5: turning what Observe read into a scope. Pure jq, no I/O.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-lesson-scope.sh"
	source "${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-lesson-validate.sh"
}

_range() { librarian_lesson_range_for_version "$1"; }

@test "a 1.x-or-later version covers the rest of its major" {
	[ "$(_range 5.4.21)" = ">=5.4.21 <6" ] || return 1
	[ "$(_range 26.1)" = ">=26.1 <27" ]
}

@test "a 0.x version covers the rest of its minor" {
	[ "$(_range 0.27.0)" = ">=0.27.0 <0.28" ] || return 1
	[ "$(_range 0.0.3)" = ">=0.0.3 <0.1" ]
}

@test "a caret range and a v prefix read as the version they start at" {
	[ "$(_range ^18.2.0)" = ">=18.2.0 <19" ] || return 1
	[ "$(_range v22.11.0)" = ">=22.11.0 <23" ]
}

@test "a version that is not at least X.Y gets no range" {
	for v in 20200816 4 latest "~5.4" ">=1" 1.0.0-beta.3 c2a87611d0e1; do
		[ -z "$(_range "$v")" ] || return 1
	done
}

@test "every range it makes passes the transform's range rule" {
	for v in 5.4.21 26.1 0.27.0 0.0.3 ^18.2.0 v22.11.0 1.0; do
		librarian_lesson_valid_range "$(_range "$v")" || return 1
	done
}

_scope() { librarian_lesson_scope_from_observation "$1" "$2"; }

@test "an empty stack is no_stack, whatever was observed" {
	[ "$(_scope '[]' '{"observed_on":{},"unresolved":[]}')" = '{"kind":"no_stack"}' ]
}

@test "a stack with a rangeable observation is versioned, on that entry only" {
	out=$(_scope '["vite","Sentry"]' '{"observed_on":{"vite":{"version":"5.4.21","source":"lockfile","basis":"session_commit"}},"unresolved":["Sentry"]}')
	[ "$out" = '{"kind":"versioned","versions":{"vite":">=5.4.21 <6"}}' ]
}

@test "an unrangeable observation stays out of versions" {
	out=$(_scope '["awk","node"]' '{"observed_on":{"awk":{"version":"20200816","source":"probe","basis":"machine","flavor":"bsd"},"node":{"version":"26.1.0","source":"probe","basis":"machine"}},"unresolved":[]}')
	[ "$out" = '{"kind":"versioned","versions":{"node":">=26.1.0 <27"}}' ]
}

@test "a stack with nothing rangeable is unscoped" {
	[ "$(_scope '["Sentry"]' '{"observed_on":{},"unresolved":["Sentry"]}')" = '{"kind":"unscoped"}' ] || return 1
	[ "$(_scope '["awk"]' '{"observed_on":{"awk":{"version":"20200816","source":"probe","basis":"machine"}},"unresolved":[]}')" = '{"kind":"unscoped"}' ]
}

@test "a missing or malformed observation is unscoped, not an error" {
	run _scope '["vite"]' ''
	[ "$status" -eq 0 ] || return 1
	[ "$output" = '{"kind":"unscoped"}' ] || return 1
	run _scope '["vite"]' 'not json'
	[ "$output" = '{"kind":"unscoped"}' ]
}
```

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-scope.bats`
Expected: FAIL, because the file being sourced doesn't exist.

- [ ] **Step 2: Implement**

`plugins/librarian/scripts/lib/librarian-lesson-scope.sh`:

```bash
#!/usr/bin/env bash
# A lesson's scope, derived from what Observe read rather than asked of the
# model. D4 and D5 of the evidenced-portability design. Pure jq, no I/O.

# The D4 rule as a jq function, shared by both entry points. A leading ^ and
# a v are read as the version they start at: a caret range IS D4's range.
# Anything else, including a prerelease, a bare major or a date, gets none.
_LIBRARIAN_LESSON_D4='
	def d4:
		(capture("^\\^?v?(?<x>[0-9]+)\\.(?<y>[0-9]+)(\\.(?<z>[0-9]+))?$") // null) as $m
		| if $m == null then empty
		  else
			($m.x | tonumber) as $x
			| (if $m.z then "\($m.x).\($m.y).\($m.z)" else "\($m.x).\($m.y)" end) as $low
			| if $x >= 1 then ">=\($low) <\($x + 1)"
			  else ">=\($low) <0.\(($m.y | tonumber) + 1)"
			  end
		  end;
'

# Usage: librarian_lesson_range_for_version <version>
librarian_lesson_range_for_version() {
	jq -rn --arg v "${1:-}" "${_LIBRARIAN_LESSON_D4}"' $v | d4' 2>/dev/null || true
}

# Usage: librarian_lesson_scope_from_observation <stack_json> <observation_json>
librarian_lesson_scope_from_observation() {
	local stack="${1:-[]}" observation="${2:-}"
	printf '%s' "$observation" | jq -e 'type == "object"' >/dev/null 2>&1 \
		|| observation='{}'
	jq -cn --argjson stack "$stack" --argjson obs "$observation" "${_LIBRARIAN_LESSON_D4}"'
		if ($stack | length) == 0 then {kind: "no_stack"}
		else
			([$stack[] as $e
			  | ($obs.observed_on[$e].version? // empty) as $v
			  | ([$v | d4] | first) as $r
			  | select($r != null)
			  | {key: $e, value: $r}] | from_entries) as $versions
			| if ($versions | length) > 0 then {kind: "versioned", versions: $versions}
			  else {kind: "unscoped"}
			  end
		end
	' 2>/dev/null || printf '{"kind":"unscoped"}'
}
```

If `capture` with no match errors instead of yielding nothing under the
installed jq, wrap it in `try ... catch null`.

- [ ] **Step 3: Run**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-scope.bats`
Expected: PASS. Break one expected range on purpose, confirm the test
fails, and restore it. Run `npm run test:shellcheck` and
`npm run lint:bats-assertions`.

- [ ] **Step 4: Commit**

```bash
git add plugins/librarian/scripts/lib/librarian-lesson-scope.sh test/bats/librarian-lesson-scope.bats
```

Message: `feat(librarian): derive a lesson's scope from what was observed :triangular_ruler:`.

---

### Task 3: The transform asks for a stack, not a scope

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-transform.sh`
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-validate.sh` (delete `librarian_lesson_pregate`)
- Modify: `plugins/librarian/scripts/lib/librarian-classify-worker.sh`
- Modify: `plugins/librarian/scripts/hooks/librarian-session-end.sh`
- Modify: `plugins/librarian/scripts/lib/librarian-cli.sh` (`librarian_cli_lessons_reconsider`)
- Modify: `plugins/librarian/config.json` (drop `lesson_transform.unscoped_per_scan`)
- Test: `test/bats/librarian-lesson-transform.bats`

**Interfaces:**
- Consumes: `librarian_lesson_observe <project_key> <observed_at> <stack_json>`
  (`librarian-lesson-observe.sh`) and `librarian_lesson_scope_from_observation`
  (Task 2).
- Produces: `librarian_lesson_build_prompt <artifact_json>` (one argument)
  and `librarian_lesson_call <artifact_json> <model>` (two). The signature
  becomes `librarian_lesson_transform_one <key> <artifact_json>`, and any
  other arguments are ignored. It prints `proposed:<id>` or
  `proposed:<id>:unscoped`, `declined:<reason>`, `skipped:seen` or
  `unavailable`. `skipped:unscoped_cap` is gone. `<reason>` is one of
  `no_resolution`, `transform_invalid` and `schema_invalid`.

- [ ] **Step 1: Rewrite the stub and the tests that depend on the model writing scope**

In `_transform_setup`, have the stub answer without a scope:
- The `module-runner` branch prints
  `{"claim":"Vitest 4 cannot import vite/module-runner on Vite 5","rationale":"vite/module-runner ships in Vite 6; Vitest 4 assumes it exists.","evidence":{"resolution":"Pin vitest to 3.x until Vite 6 lands."},"applies_to":{"stack":["vite","vitest"],"topics":["testing"],"file_patterns":[],"task_kinds":[]}}`.
- Replace the `<scope-mode>unscoped</scope-mode>` branch with a
  `release-please-stub` marker branch that prints the same release-please
  answer without a `scope` key.
- Add a `no-stack-stub` branch that prints a claim with `"stack":[]` and
  `"topics":["testing"]`.
- Add a `scope-smuggle-stub` branch that prints the module-runner answer
  plus `"scope":{"kind":"version_independent","justification":"x"}`.
- Keep the `no-versions-stub` branch. It now tests that an old reason gets
  clamped.
- Delete the `npm-range-stub` branch, because the model no longer writes
  ranges.

Then register the fixture repo so that Observe resolves vite and vitest. At
the end of `_transform_setup`:

```bash
  mkdir -p "${ONLOOKER_DIR}/librarian/${PROJECT_KEY}"
  jq -n --arg k "$PROJECT_KEY" --arg r "$PROJECT_REPO" '{project_key: $k, repo_root: $r}' \
    > "${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/manifest.json"
  printf '%s' '{"packages":{"":{},"node_modules/vite":{"version":"5.4.21"},"node_modules/vitest":{"version":"4.1.9"}}}' \
    > "${PROJECT_REPO}/package-lock.json"
  git -C "$PROJECT_REPO" add package-lock.json
  GIT_AUTHOR_DATE="2026-08-01T00:00:00Z" GIT_COMMITTER_DATE="2026-08-01T00:00:00Z" \
    git -C "$PROJECT_REPO" commit -q -m lock
```

`_seed`'s `created_at` is `2026-08-03T15:59:48Z`, so the session commit is
that one. If `_storage_setup` already writes this manifest, or the key
doesn't resolve this way, read `_storage_setup` and reuse what it sets. The
fixture is the point, not this exact code.

Delete these tests, because what they pin no longer exists:
- the four `pregate ...` tests
- "transform_one declines when the model cannot infer versions"
- "transform_one declines an npm-style range as schema_invalid"
- "build_prompt states there is no version-independent option and forbids npm ranges"
- "build_prompt marks the mode so the model knows which contract applies"
- "the unscoped route stops at the cap and declines nothing"
- "the cap does not apply to the versioned route"
- "a forced unscoped mode parks an artifact that DOES carry a version token"
- "without a forced mode that same artifact still takes the versioned route"
- "an artifact WITH a version token still takes the versioned route"

Rewrite these:
- "transform_one proposes a candidate for a groundable artifact" now asserts
  `.candidate.applies_to.scope == {kind: "versioned", versions: {vite: ">=5.4.21 <6", vitest: ">=4.1.9 <5"}}`,
  `.candidate.evidence.observed_on.vite.source == "lockfile"`,
  `.candidate.evidence.unresolved == []` and
  `.candidate.applies_to.topics == ["testing"]`.
- "build_prompt carries the claim constraints in both modes" becomes "build
  prompt carries the claim constraints". It makes one call with no mode,
  and replaces the `stack always lists at least one tool` assertion with
  `*"stack lists only things with a version"*`.
- "transform_one parks a version-free artifact ..." and "transform_one parks
  an artifact with no version token ..." now use `release-please-stub`. They
  assert `proposed:*:unscoped`, `.candidate.applies_to.scope == {kind: "unscoped"}`
  and `.candidate.evidence.unresolved == ["release-please"]`.
- "a parked result reports its route ..." uses `release-please-stub`.

Add:

```bash
@test "transform_one gives a stackless claim the no_stack scope" {
  _transform_setup
  art=$(_seed "01M3B87J7046SJE5BECNMP670K" "no-stack-stub" "Name tests for what they assert.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [[ "$output" == proposed:* ]] || return 1
  id="${output#proposed:}"; id="${id%%:*}"
  jq -e '.candidate.applies_to.scope == {kind: "no_stack"} and .candidate.applies_to.stack == []' \
    "${LESSONS_DIR}/proposals/${id}.json"
}

@test "a scope the model writes anyway is discarded" {
  _transform_setup
  art=$(_seed "01M3B93JPGAKHGEQ5KD9N836HD" "scope-smuggle-stub" "vite module-runner")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [[ "$output" == proposed:* ]] || return 1
  id="${output#proposed:}"; id="${id%%:*}"
  jq -e '.candidate.applies_to.scope.kind == "versioned"' "${LESSONS_DIR}/proposals/${id}.json"
}

@test "an old no_versions refusal is clamped to transform_invalid" {
  _transform_setup
  art=$(_seed "01KZ45MKGQ7QZWMABQ4H12SHSV" "no-versions-stub" "detail")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "declined:transform_invalid" ]
}

@test "the prompt asks for no scope and no no_versions refusal" {
  _transform_setup
  prompt=$(librarian_lesson_build_prompt "$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "s" "d")")
  [[ "$prompt" != *'"scope"'* ]] || return 1
  [[ "$prompt" != *"no_versions"* ]] || return 1
  [[ "$prompt" == *'"topics"'* ]]
}

@test "an unregistered project leaves every stack entry unresolved" {
  _transform_setup
  rm -f "${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/manifest.json"
  art=$(_seed "01KZ45MKME229J0QK0690TREAB" "Vitest 4.1.9 / Vite 5.x" "module-runner missing")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [[ "$output" == proposed:*:unscoped ]] || return 1
  id="${output#proposed:}"; id="${id%%:*}"
  jq -e '.candidate.evidence.unresolved == ["vite", "vitest"]' "${LESSONS_DIR}/proposals/${id}.json"
}
```

The vitest and vite probes aren't on the allowlist, so an unregistered
project leaves both unresolved.

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats`
Expected: FAIL on the rewritten and added tests.

- [ ] **Step 2: Rewrite the prompt**

`librarian_lesson_build_prompt <artifact_json>` loses the `mode` argument,
`scope_rules` and the `<scope-mode>` line. In the heredoc:

- Change the second paragraph's "and the exact version range in which it
  holds" to "and which tools it depends on".
- Keep only the `no_resolution` refusal, both in the REFUSE block and in
  its bullet.
- Change the output shape to:

```text
{
  "claim": "<what was learned, one sentence>",
  "rationale": "<why the claim follows from the evidence>",
  "evidence": { "resolution": "<what actually resolved it, from the artifact>" },
  "applies_to": {
    "stack": ["<a package, CLI or service the claim depends on>"],
    "topics": ["<a concept the lesson is about>"],
    "file_patterns": [],
    "task_kinds": []
  }
}
```

- Replace the `stack always lists ...` claim rule with:

```text
- stack lists only things with a version: a package, a CLI, a hosted
  service, or a component. List every one the claim depends on. Concepts
  have no version and go in topics: "CSS", "SQL", "testing",
  "rate-limiting", "authentication", "database migrations", "API design".
  stack is [] only when the claim names no tool at all; that is rare, and
  an empty stack on a claim about a tool is wrong.
- Do not output a scope. Versions are read from the project, not inferred.
```

The examples in that rule come from the 2026-11-26 measurement's concepts
list.

- [ ] **Step 3: Rewrite `librarian_lesson_transform_one`**

- Drop the `unscoped_so_far` and `forced_mode` parameters, the pre-gate,
  the mode, and the cap block.
- Call `librarian_lesson_call "$artifact" "$model"`.
- In the refusal clamp, the only allowed reason is `no_resolution`.
- Replace the provenance stitch with:

```bash
	local candidate
	candidate=$(printf '%s' "$raw" | jq -c \
		--arg aid "$artifact_id" \
		--arg sid "$session_id" \
		--arg pk "$project_key" \
		--arg at "$created_at" \
		'.evidence.artifact_ids = [$aid]
		 | .evidence.session_ids = (if $sid == "" then [] else [$sid] end)
		 | .evidence.project_key = $pk
		 | .evidence.observed_at = $at
		 # A model-written stack is JSON from a model: keep the non-empty
		 # strings, once each. A scope it wrote anyway is not its to write.
		 | .applies_to.stack = ([.applies_to.stack[]? | select(type == "string" and length > 0)] | unique)
		 | .applies_to.topics = ([.applies_to.topics[]? | select(type == "string" and length > 0)] | unique)
		 | del(.applies_to.scope)' 2>/dev/null) || candidate=""
```

`unique` sorts. That's fine for both lists, and the test assertions above
use sorted order.

- After the empty-candidate check, before validation:

```bash
	# Versions are read, not asked for (D2). Observe prints nothing when node
	# is missing or an argument is, and then every entry is unresolved: the
	# candidate stays local rather than failing (D6).
	local stack observation scope
	stack=$(printf '%s' "$candidate" | jq -c '.applies_to.stack')
	observation=$(librarian_lesson_observe "$project_key" "$created_at" "$stack")
	printf '%s' "$observation" | jq -e '.observed_on | type == "object"' >/dev/null 2>&1 \
		|| observation=$(jq -cn --argjson s "$stack" '{observed_on: {}, unresolved: $s}')
	scope=$(librarian_lesson_scope_from_observation "$stack" "$observation")
	candidate=$(printf '%s' "$candidate" | jq -c \
		--argjson o "$observation" --argjson sc "$scope" \
		'.evidence.observed_on = $o.observed_on
		 | .evidence.unresolved = [$o.unresolved[] | strings]
		 | .applies_to.scope = $sc') || candidate=""
```

`[... | strings]` drops the non-strings Observe passes through from a
malformed stack. The stack was already cleaned, so there shouldn't be any.

- Print `proposed:<id>:unscoped` when the derived scope's kind is
  `unscoped`, and `proposed:<id>` otherwise.
- Rewrite the function's header comment: drop the mode, pre-gate and cap
  paragraphs, and say that the scope comes from Observe through Task 2.
- At the top of the transform lib, update the "Requires" line to name
  `librarian-lesson-observe.sh` and `librarian-lesson-scope.sh`.

- [ ] **Step 4: Remove the pre-gate and the cap everywhere**

- Delete `librarian_lesson_pregate` from `librarian-lesson-validate.sh`.
  Grep the whole repo for `pregate` and fix every live caller. Historical
  docs under `docs/` and `plugins/librarian/docs/measurements/` stay as they
  are.
- Remove `"unscoped_per_scan": 3` from `plugins/librarian/config.json`.
  Grep for `unscoped_per_scan` and fix live code, under the same rule for
  historical docs.
- `librarian-classify-worker.sh`:
  - Call `librarian_lesson_transform_one "$PROJECT_KEY" "$LESSON_ARTIFACT"`.
  - Drop `LESSON_CAPPED` and its case arm.
  - Keep `LESSON_UNSCOPED`. It now counts candidates with nothing rangeable,
    so update its comment.
  - Wherever `LESSON_CAPPED` is reported (grep), remove it. If it rides on an
    event payload, stop and report: the payload field is registered in the
    schema, and removing it needs a schema decision.
  - Wherever `librarian-lesson-transform.sh` is sourced (the worker,
    `hooks/librarian-session-end.sh`, and anything else grep finds), source
    `librarian-lesson-observe.sh` and `librarian-lesson-scope.sh` just before
    it, with the same `# shellcheck source=` comments.
- `librarian_cli_lessons_reconsider`:
  - Drop `forced` and the `unscoped` counter.
  - Rewrite the `no_versions` doc line: such an artifact now goes back
    through the transform, which no longer asks for versions.
  - Make sure the CLI's lessons commands source the new libs (grep for how
    `librarian-lesson-transform.sh` reaches the CLI).
- `plugins/librarian/scripts/measure-lesson-transform.sh`: drop the third
  argument. Update its "THE UNSCOPED COST CAP IS BYPASSED" comment to say
  there's no cap any more.

- [ ] **Step 5: Run**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats test/bats/librarian-detached-classifier.bats test/bats/hook-health.bats`
Expected: PASS. Then grep `test/bats` for `unscoped_cap`, `pregate` and
`transform_one .* [0-9]` and fix whatever is left. Run `npm run test:shellcheck`,
`npm run lint:bats-assertions` and `npm run lint:bash-arithmetic`.

- [ ] **Step 6: Commit**

Stage every file this task touched, by name.
Message: `feat(librarian): read a lesson's versions instead of asking for them :mag:`.
In the body, cover: the model now writes stack and topics, the scope comes
from Observe through D4 and D5, and the pre-gate, the unscoped cap and the
`no_versions` refusal are gone because nothing asks for a version.

---

### Task 4: lesson_auto leaves unresolved candidates for a person

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-auto.sh`
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-review.sh`
- Modify: `plugins/librarian/skills/librarian/SKILL.md`
- Test: `test/bats/librarian-lesson-auto.bats`
- Test: `test/bats/librarian-lesson-review.bats`

**Interfaces:**
- Produces: `librarian_lesson_auto_confirm_one` adds the outcome
  `skipped:unresolved`, and confirms `no_stack` the way it confirms
  `versioned`.
- Consumes: Task 1's `no_stack` in `librarian_lesson_validate_confirmed`.

- [ ] **Step 1: Write the failing tests**

Read `test/bats/librarian-lesson-auto.bats` for its fixture helpers first,
then add tests using them:

1. A pending `versioned` candidate with `evidence.unresolved: ["Sentry"]`
   gives `skipped:unresolved`. The proposal's status stays `pending`, no
   `librarian.lesson.asserted` event is emitted, and the stub `claude` is
   never called. Assert the last one with a marker file the stub touches.
2. A pending `no_stack` candidate with `unresolved: []` gives
   `confirmed:<id>`, with `asserted_by: "model"` recorded the way the
   existing versioned test asserts it, and no `claude` call.
3. A pending `unscoped` candidate with `unresolved: ["release-please"]`
   gives `skipped:unresolved` and makes no justify call.
4. A pending `unscoped` candidate with `unresolved: []` still reaches the
   justify call, exactly as the existing unscoped tests do. Extend an
   existing test's fixture with `unresolved: []` rather than duplicating it.
5. A candidate with no `unresolved` key at all, written before this change,
   behaves as it does today.

In `test/bats/librarian-lesson-review.bats`, add a test: confirming a
`no_stack` candidate at `private` with no justification succeeds.

Run both files. Expected: FAIL on the new tests.

- [ ] **Step 2: Implement**

In `librarian_lesson_auto_confirm_one`:
- Accept `unscoped | versioned | no_stack` in the scope case.
- Immediately after that case, add:

```bash
	# D6: an entry no source could version keeps the lesson local until a
	# person supplies the version. Checked before any model call, so a held
	# candidate costs nothing on later scans either.
	if printf '%s' "$candidate" | jq -e '(.evidence.unresolved // []) | length > 0' >/dev/null 2>&1; then
		printf 'skipped:unresolved'
		return 0
	fi
```

- Change `if [[ "$scope_kind" == "versioned" ]]` to
  `if [[ "$scope_kind" == "versioned" || "$scope_kind" == "no_stack" ]]`,
  and extend the comment above it: a `no_stack` candidate has nothing to
  version either.
- In the outcome list above the function, add
  `skipped:unresolved   an entry no source versioned (D6); left for a person`,
  and change `skipped:not_parked`'s description to say "none of unscoped,
  versioned or no_stack".
- Change the file's header paragraph from "The transform still emits scope
  {kind: unscoped}" to say that the transform now derives scope from Observe,
  and that this stage confirms nothing with an unresolved entry.

`librarian-lesson-review.sh` probably needs no code change, because
Task 1's validator accepts `no_stack`. If the new review test fails, fix
whatever it hits, and don't loosen `unscoped`'s justification requirement.

In `SKILL.md`, after the "A parked candidate" bullet, add a sibling bullet:

```markdown
   - **A no-tool candidate** (`scope: {"kind":"no_stack"}`, empty `stack`) names no tool, so it has no version to scope and needs no justification. Confirm it at any visibility.
```

If `librarian_cli_lessons_list` or `show` (in `librarian-cli.sh`, around
the `unscoped` checks near lines 435 and 464) labels kinds, give `no_stack`
the label "no tool", the way `unscoped` gets "needs scope". If the user
can't see `evidence.unresolved` anywhere in `show`, add one line printing
it. That's what tells a person why a candidate was held.

- [ ] **Step 3: Run**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats test/bats/librarian-lesson-auto-hold.bats test/bats/librarian-lesson-auto-decline.bats test/bats/librarian-lesson-review.bats`
Expected: PASS. Break the D6 check on purpose, confirm test 1 fails, and
restore it.

- [ ] **Step 4: Commit**

Message: `feat(librarian): hold an unattended lesson until every tool is versioned :hourglass:`.
In the body, cite D6 and the decision to enforce it from step 3 onward.

---

### Task 5: Promote carries the new fields, and the PR

**Files:**
- Test: `test/bats/librarian-lesson-promote.bats`

- [ ] **Step 1: Write the test**

`librarian_lesson_promote` copies `candidate.evidence` and
`candidate.applies_to` whole (`librarian-lesson-promote.sh:166-167`), so the
fields already pass through. Pin that. Using the file's existing fixture
helpers, promote an approved candidate that carries `topics`, `observed_on`
and `unresolved: []`, then assert the pool entry has all three, unchanged.
Add a second case: an approved `no_stack` candidate promotes to an entry
with `applies_to.stack == []` and `scope == {kind: "no_stack"}`.

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-promote.bats`
Expected: PASS on the first run. Break one assertion on purpose and confirm
it fails.

- [ ] **Step 2: Commit**

Message: `test(librarian): pin that promote carries observed versions through :pushpin:`.

- [ ] **Step 3: Run CI**

Run: `npm run test:ci`.
Expected: PASS, apart from `test/bats/librarian-author-key.bats` #9 on
macOS, which skips on Linux CI. If that test is the only failure, run the
remaining `test:ci` steps one by one, including `test:bus` after a bats run
that excludes that file.

- [ ] **Step 4: Open the PR**

Use `/git-workflow:pr`. Title: `feat(librarian): derive a lesson's scope from observed versions`.
The body should cover:
- the stack/topics split
- D4 and D5 in one line each
- the D6 hold in `lesson_auto`
- that `unscoped` now means "nothing rangeable was observed"
- what this does to ONL-198's measurement: the justify path now runs only
  for an `unscoped` candidate with nothing unresolved

The PR touches `test/` and `scripts/lib/` as well as librarian, so it also
cuts an ecosystem root release.
