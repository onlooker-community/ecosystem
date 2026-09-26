# Version-Independent Lesson Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a lesson that is not bound to a stack version range reach the pending queue, so a human can assert version-independence on it and a jury can check that assertion.

**Architecture:** The pre-gate stops skipping artifacts and instead routes them to one of two prompt modes. A third scope kind, `unscoped`, is legal only while a candidate is pending: `librarian_lesson_validate_candidate` accepts it and `librarian_lesson_validate_confirmed` refuses it, so the only exit from the queue is a human justification, which `librarian_lesson_confirm` already forces to `org` or `public` and therefore to a jury. A per-scan cap bounds the newly reachable route, and a `reconsider` action recovers the artifacts already declined `no_versions`.

**Tech Stack:** bash 3.2-compatible shell, `jq`, bats-core for integration tests, `node:test` + `ajv` for schema-agreement tests.

**Spec:** `docs/superpowers/specs/2026-09-25-version-independent-lesson-intake-design.md` (commit 6e470eb). Read it before Task 1 — every decision below has a `D<n>` there.

**Tracking:** bead `ecosystem-65mqw6`, Linear [ONL-107](https://linear.app/onlooker/issue/ONL-107).

## Global Constraints

- **Commits route through `/git-workflow:commit`.** Never craft `git commit -m` by hand — not even for a one-line change. The skill enforces conventional commits, intentional file selection, and a mood emoji reflecting *this* change.
- **American English** in code, comments, docs and commit messages.
- **Branch:** `meagan/onl-107-version-independent-lesson-intake`, already cut from `origin/main` at 560c52c. Never push to `main`; the work lands via PR.
- **No new event types.** `@onlooker-community/schema` is an external dependency at `^2.22.0` and registration is cross-repo. See the spec's Events section; a parked candidate rides on `librarian.candidate.proposed`.
- **Do not touch `plugins/librarian/schema/lesson-applies-to.subschema.json` or `lesson-evidence.subschema.json`.** They are vendored from the published lesson contract (`PROVENANCE.json`, `schema_version` 2) and represent what the *pool* accepts. `unscoped` never reaches the pool.
- **`librarian-lesson-validate.sh` stays I/O-free and route-blind** (D4). No new parameters on either validator.
- **Config defaults live in `plugins/librarian/config.json`**, read through `librarian_config_get`, and every accessor must tolerate a missing key by falling back to the shipped default.
- **Never run bare `bats`** — `ONLOOKER_VALIDATE=1` must be set or negative schema tests pass locally and fail in CI.
- **For a single file, call `scripts/test/run-bats.sh <file>` directly.** It sets `ONLOOKER_VALIDATE=1` itself, so it is safe. Do **not** use `npm run test:bats -- <file>`: that expands to `run-bats.sh test/bats <file>`, so bats receives the directory *and* the file, plans both, and then executes that file's tests **zero times** — exiting 0 with only a `bats warning: Executed N instead of expected M` line. Verified on this branch: the file holds 48 tests and the run executed exactly 48 fewer than planned, reporting no failures while a genuinely failing test never ran. Use `npm run test:bats` (no arguments) only for the whole suite.
- **`run-bats.sh` `rm -rf`s a shared report directory**, so never start a second bats run while one is in flight — the emission-coverage gate then reports a wall of phantom regressions. One run at a time.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `plugins/librarian/scripts/lib/librarian-lesson-validate.sh` | Add the `unscoped` scope clause; make the versions check conditional in `validate_candidate` | 1 |
| `plugins/librarian/schema/lesson-applies-to-pending.local.schema.json` | **New.** Locally owned, explicitly not vendored: the pending-state shape (`versioned \| unscoped`) | 1 |
| `plugins/librarian/schema/PROVENANCE.json` | Record that the new file is local, not extracted from upstream | 1 |
| `plugins/librarian/scripts/lib/librarian-lesson-transform.sh` | `build_prompt` gains a mode; `transform_one` routes on the pre-gate instead of skipping | 2 |
| `plugins/librarian/scripts/lib/librarian-classify-worker.sh` | Count and cap unscoped-route transforms | 3 |
| `plugins/librarian/config.json` | `unscoped_per_scan` default | 3 |
| `plugins/librarian/scripts/lib/librarian-lesson-review.sh` | Refuse confirming an `unscoped` candidate with no justification | 4 |
| `plugins/librarian/scripts/lib/librarian-cli.sh` | Mark parked candidates in `list`/`show`; dispatch `reconsider` | 4, 5 |
| `plugins/librarian/skills/librarian/SKILL.md` | The walk learns when a justification is mandatory | 4 |
| `plugins/librarian/scripts/lib/librarian-lesson-storage.sh` | Remove selected decline records atomically | 5 |
| `test/bats/librarian-lesson-transform.bats` | Validator and routing tests | 1, 2, 3 |
| `test/bats/librarian-lesson-review.bats` | Confirm-refusal and surfacing tests (there is no `librarian-lesson-confirmation.bats`) | 4 |
| `test/bats/librarian-lesson-reconsider.bats` | **New.** Reconsider tests | 5 |
| `test/node/lesson-validate-agreement.test.mjs` | Agreement in both directions for `unscoped` | 1 |

---

### Task 1: `unscoped` in the validator pair

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-validate.sh:105` (add clause after `_LIBRARIAN_LESSON_SCOPE_VERSIONED`) and `:140-165` (`librarian_lesson_validate_candidate`)
- Create: `plugins/librarian/schema/lesson-applies-to-pending.local.schema.json`
- Modify: `plugins/librarian/schema/PROVENANCE.json`
- Test: `test/bats/librarian-lesson-transform.bats`, `test/node/lesson-validate-agreement.test.mjs`

**Interfaces:**
- Produces: `_LIBRARIAN_LESSON_SCOPE_UNSCOPED` (a jq boolean expression string, same shape as `_LIBRARIAN_LESSON_SCOPE_VERSIONED`). `librarian_lesson_validate_candidate` and `librarian_lesson_validate_confirmed` keep their exact current signatures — one positional candidate JSON argument, silent on success, `schema_invalid` on stderr and exit 1 on failure.
- Consumes: nothing from other tasks. Task 2 relies on `validate_candidate` accepting `{"kind":"unscoped"}`.

- [ ] **Step 1: Write the failing bats tests**

Append to `test/bats/librarian-lesson-transform.bats`. Its `setup()` already sources `librarian-lesson-validate.sh`. The existing builder is `_candidate <versions_json> <stack_json>` (:68) — it takes **two** required `--argjson` arguments and always produces a `versioned` scope, so it must be called with both and then have its scope replaced. Calling it bare fails inside jq.

```bash
@test "validate_candidate accepts an unscoped candidate" {
  cand=$(_candidate '{"vite":"<6"}' '["vite"]' | jq -c '.applies_to.scope = {kind: "unscoped"}')
  run librarian_lesson_validate_candidate "$cand"
  [ "$status" -eq 0 ]
}

@test "validate_candidate rejects unscoped carrying any extra key" {
  cand=$(_candidate '{"vite":"<6"}' '["vite"]' | jq -c '.applies_to.scope = {kind: "unscoped", versions: {vite: "<6"}}')
  run librarian_lesson_validate_candidate "$cand"
  [ "$status" -ne 0 ]
}

@test "validate_confirmed refuses unscoped: it may never leave the pending queue" {
  cand=$(_candidate '{"vite":"<6"}' '["vite"]' | jq -c '.applies_to.scope = {kind: "unscoped"}')
  run librarian_lesson_validate_confirmed "$cand"
  [ "$status" -ne 0 ]
}

@test "validate_candidate still runs the range rules on a versioned candidate" {
  cand=$(_candidate '{"vite":"^5.4.21"}' '["vite"]')
  run librarian_lesson_validate_candidate "$cand"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run them and confirm the first three fail**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats`
Expected: exactly **one** failure — `validate_candidate accepts an unscoped candidate`. Verified on this branch. The other three pass before any implementation, each for a reason worth knowing:

- *rejects unscoped carrying any extra key* passes **vacuously** today, because `validate_candidate` currently rejects every `unscoped` candidate. It only becomes meaningful after Step 4, which is why it must be re-read then rather than trusted now.
- *validate_confirmed refuses unscoped* passes for the right reason already: that validator's scope clause never listed the kind. Step 5 only records why the omission is deliberate.
- *still runs the range rules on a versioned candidate* is the regression guard for Step 4, which makes the versions check conditional.

- [ ] **Step 3: Add the scope clause**

In `librarian-lesson-validate.sh`, directly after the `_LIBRARIAN_LESSON_SCOPE_VERSIONED` block:

```bash
# The unscoped branch. Legal ONLY while a candidate is pending.
#
# This is the model declining to bind a range, NOT a claim that the lesson
# holds for every version — that assertion stays the human's, and
# librarian_lesson_validate_confirmed refuses this kind precisely so the only
# exit from the pending queue is a justification, which the review path forces
# to org or public and therefore to a jury.
#
# `keys - ["kind"]` is the whole shape: no versions, no justification. An
# unscoped scope that smuggled either would be asserting something.
_LIBRARIAN_LESSON_SCOPE_UNSCOPED='
	.applies_to.scope.kind == "unscoped"
	and ((.applies_to.scope | keys) - ["kind"] | length) == 0
'
```

- [ ] **Step 4: Widen `validate_candidate` and make the versions check conditional**

Replace the body of `librarian_lesson_validate_candidate` (currently `:140-165`) so the scope clause is a two-branch `or` and `_librarian_lesson_check_versions` runs only for the versioned branch. The conditional is load-bearing: that helper reads `.applies_to.scope.versions`, which an `unscoped` candidate does not have, so calling it unconditionally would reject every parked candidate.

```bash
librarian_lesson_validate_candidate() {
	local candidate="${1:-}"
	[[ -z "$candidate" ]] && { printf 'schema_invalid\n' >&2; return 1; }

	# versioned or unscoped, never version_independent. This is the guarantee
	# that stops the transform minting lessons that never expire: private
	# lessons run no jury, so nothing downstream would catch a bad
	# version_independent claim. A human may assert that branch — see
	# librarian_lesson_validate_confirmed — because the constraint in the
	# review path forces it to a judged visibility.
	#
	# unscoped is the mirror image: legal here, refused there. It parks a
	# claim for a human instead of discarding it, and cannot reach the pool.
	local scope_clause='
		(
			('"${_LIBRARIAN_LESSON_SCOPE_VERSIONED}"')
			or ('"${_LIBRARIAN_LESSON_SCOPE_UNSCOPED}"')
		)
	'

	if ! printf '%s' "$candidate" | jq -e \
		"${_LIBRARIAN_LESSON_STRUCTURAL} and ${scope_clause}" \
		>/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	# Range and subset rules apply only to the versioned branch — an unscoped
	# candidate has no .versions for them to read.
	if printf '%s' "$candidate" | jq -e '.applies_to.scope.kind == "versioned"' >/dev/null 2>&1; then
		_librarian_lesson_check_versions "$candidate" || {
			printf 'schema_invalid\n' >&2
			return 1
		}
	fi

	return 0
}
```

- [ ] **Step 5: Refuse `unscoped` in `validate_confirmed`**

`librarian_lesson_validate_confirmed`'s scope clause already lists only `versioned` and `version_independent`, so it rejects `unscoped` as written. Confirm that by reading it, and add one comment line above its `scope_clause` recording that the omission is deliberate, so nobody "helpfully" adds the third branch for symmetry:

```bash
	# versioned or version_independent. unscoped is deliberately absent: it is
	# a pending-only shape, and permitting it here would let a parked claim
	# reach the jury and the pool with nobody having asserted anything.
```

- [ ] **Step 6: Run the bats tests and confirm all four pass**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats`
Expected: PASS, including the pre-existing tests — especially `test/node`'s counterpart guard that `validate_candidate` still refuses `version_independent`.

- [ ] **Step 7: Create the local pending schema**

`plugins/librarian/schema/lesson-applies-to-pending.local.schema.json`. Copy `lesson-applies-to.subschema.json` verbatim, then replace the second member of `scope.oneOf` (the `version_independent` branch) with the `unscoped` branch below, and replace the top-level `description`. Everything else — `stack`, `file_patterns`, `task_kinds`, `required`, `additionalProperties: false`, and the entire `versioned` branch including its range `pattern` — must stay byte-identical to the vendored file, so the two disagree on exactly one thing.

```json
        {
          "type": "object",
          "properties": {
            "kind": {
              "type": "string",
              "const": "unscoped"
            }
          },
          "required": ["kind"],
          "additionalProperties": false
        }
```

Top-level `description`:

```json
  "description": "LOCAL, NOT VENDORED. The pending-state shape of applies_to, mirroring librarian_lesson_validate_candidate. It admits `unscoped` — a model declining to bind a version range — and refuses `version_independent`, which only a human may assert at confirm time. The pool never sees this shape: see lesson-applies-to.subschema.json for the published contract, which is the mirror image. Every key of scope.versions must name an entry in stack; that rule is enforced at ingest, not by this schema, because JSON Schema cannot express a constraint spanning two fields."
```

- [ ] **Step 8: Record the new file's provenance**

In `plugins/librarian/schema/PROVENANCE.json`, add one key. Do **not** change `schema_version`, and do not add the new file to anything the drift check iterates — `scripts/lint/check-lesson-schema-drift.mjs` asserts `schema_version === 2` and parses only the two vendored files, and both must keep passing unchanged.

```json
  "local_schemas": {
    "lesson-applies-to-pending.local.schema.json": "Not vendored and deliberately not upstream. The pending-state mirror of librarian_lesson_validate_candidate, admitting `unscoped`. The pool contract does not have that kind and must not gain it — see ONL-107."
  }
```

- [ ] **Step 9: Write the failing agreement tests**

In `test/node/lesson-validate-agreement.test.mjs`, add the pending-schema compilation beside the existing two, after the `validateAppliesTo` line:

```javascript
const appliesToPendingSchema = JSON.parse(
  readFileSync(join(SCHEMA_DIR, 'lesson-applies-to-pending.local.schema.json'), 'utf8'),
);
const validateAppliesToPending = ajv.compile(appliesToPendingSchema);

// True when the local pending schema accepts the applies_to half. Paired with
// jqAccepts(candidate) — the transform-side validator — the way schemaAccepts
// is paired with the confirmed-side one.
function pendingSchemaAccepts(candidate) {
  return validateEvidence(candidate.evidence) && validateAppliesToPending(candidate.applies_to);
}
```

Then add this block after the existing `describe('confirmed validator', ...)`:

```javascript
describe('unscoped is a pending-only shape', () => {
  const unscoped = () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = { kind: 'unscoped' };
    return candidate;
  };

  it('the transform validator and the local pending schema agree it is accepted', () => {
    assert.equal(jqAccepts(unscoped()), true);
    assert.equal(pendingSchemaAccepts(unscoped()), true);
  });

  it('the vendored pool schema rejects it, so it can never be a pool shape', () => {
    assert.equal(schemaAccepts(unscoped()), false);
  });

  it('the confirmed validator refuses it, so it can never leave the queue', () => {
    assert.equal(jqAccepts(unscoped(), 'librarian_lesson_validate_confirmed'), false);
  });

  it('the local pending schema refuses version_independent, so a model cannot mint it', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = {
      kind: 'version_independent',
      justification: 'holds regardless of version',
    };
    assert.equal(pendingSchemaAccepts(candidate), false);
  });

  it('agrees that unscoped carrying versions is rejected on both sides', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = { kind: 'unscoped', versions: { vite: '<6' } };
    assert.equal(jqAccepts(candidate), false);
    assert.equal(pendingSchemaAccepts(candidate), false);
  });
});
```

- [ ] **Step 10: Run the node tests**

Run: `npm run test:schema`
Expected: PASS. If `test:schema` does not cover `test/node/`, find the script in `package.json` that runs `node --test` over `test/node` and use that; report which one you used.

- [ ] **Step 11: Run the full suite, then commit**

Run: `npm run test:ci`
Expected: PASS, including `shellcheck` on the modified lib and `check-lesson-schema-drift`.

Then invoke `/git-workflow:commit` with this intent: a `feat(librarian)` scoped change adding the `unscoped` pending-only scope kind, whose body explains that the validator pair now encodes the asymmetry in both directions and that the vendored pool schema was deliberately left alone because `unscoped` must never be a pool shape. Reference `Refs ONL-107`.

---

### Task 2: Route on the pre-gate instead of skipping

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-transform.sh:37-105` (`librarian_lesson_build_prompt`), `:248-251` (the pre-gate skip in `transform_one`), `librarian_lesson_call`
- Test: `test/bats/librarian-lesson-transform.bats`

**Interfaces:**
- Consumes: Task 1's `validate_candidate` accepting `{"kind":"unscoped"}`.
- Produces: `librarian_lesson_build_prompt <artifact_json> [mode]` where `mode` is `versioned` (default) or `unscoped`; `librarian_lesson_call <artifact_json> [model] [mode]` passing the mode through. `transform_one` returns `proposed:<id>` for a parked candidate exactly as for a versioned one — Task 3 depends on that, since the worker counts `proposed:*`.

- [ ] **Step 1: Write the failing tests**

Add to `test/bats/librarian-lesson-transform.bats`. The `_transform_setup` helper already installs a stub `claude` on `PATH` that branches on marker strings in the prompt; add two branches to that stub's `if` chain, before its final `else`:

```bash
elif [[ "$prompt" == *"<scope-mode>unscoped</scope-mode>"* ]]; then
  printf '%s' '{"claim":"A bare Release-As footer bumps every component","rationale":"release-please applies an unscoped footer to the whole manifest.","evidence":{"resolution":"Scope the bump in the manifest instead."},"applies_to":{"stack":["release-please"],"scope":{"kind":"unscoped"},"file_patterns":[],"task_kinds":[]}}'
```

Then the tests:

```bash
@test "transform_one parks an artifact with no version token instead of skipping it" {
  _transform_setup
  art=$(_seed "01M3B87J7046SJE5BECNMP670K" "Release-As bumps every component" \
    "A bare footer was meant for one package and hit the whole manifest.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [[ "$output" == proposed:* ]]
  # Task 3 appends the route to a parked result, so strip twice. Writing it
  # this way now means Task 3 does not have to come back and edit this test.
  id="${output#proposed:}"; id="${id%%:*}"
  jq -e '.candidate.applies_to.scope.kind == "unscoped"' \
    "${LESSONS_DIR}/proposals/${id}.json"
}

@test "an artifact with no version token is never declined no_versions" {
  _transform_setup
  art=$(_seed "01M3B93JPGAKHGEQ5KD9N836HD" "Release-As bumps every component" \
    "A bare footer was meant for one package and hit the whole manifest.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ ! -f "${LESSONS_DIR}/declined.jsonl" ] || \
    ! grep -q "01M3B93JPGAKHGEQ5KD9N836HD" "${LESSONS_DIR}/declined.jsonl"
}

@test "an artifact WITH a version token still takes the versioned route" {
  _transform_setup
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [[ "$output" == proposed:* ]]
  id="${output#proposed:}"
  jq -e '.candidate.applies_to.scope.kind == "versioned"' \
    "${LESSONS_DIR}/proposals/${id}.json"
}

@test "build_prompt marks the mode so the model knows which contract applies" {
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "no token here" "none either")
  run librarian_lesson_build_prompt "$art" unscoped
  [ "$status" -eq 0 ]
  [[ "$output" == *"<scope-mode>unscoped</scope-mode>"* ]]
  [[ "$output" != *"There is no version-independent option"* ]]
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats`
Expected: the **first and fourth** FAIL — verified on this branch. Today the pre-gate returns `skipped:pregate`, so `${output#proposed:}` yields `skipped` and the proposal file does not exist; and `build_prompt` ignores a second argument, so the no-version-independent line is still in the prompt. The second passes **vacuously** (a skipped artifact writes no decline either) and only becomes meaningful after Step 5. The third is the regression guard that the versioned route is untouched.

Then, after Step 5, one **pre-existing** test in the same file fails and must be updated rather than worked around: `transform_one skips a version-free artifact without touching the ledger` (:413) asserts `[ "$output" = "skipped:pregate" ]`, which is exactly the contract D1 replaces. Rewrite it to assert a parked result while keeping its distinctive half — that the artifact never reaches the decline ledger — and rename it to say "parks". Also delete the `skipped:pregate` line from the result-value comment above `librarian_lesson_transform_one`; the historical `docs/superpowers/plans/2026-08-09-lesson-transform.md` keeps its references, since it records what was built then.

- [ ] **Step 3: Give `build_prompt` a mode**

Add a second parameter and branch only the version-rules section. The `versioned` text must stay byte-identical to today's — a token was found, so binding is the right ask and its wording is already calibrated.

```bash
# Usage: librarian_lesson_build_prompt <artifact_json> [mode]
#
# mode is "versioned" (default) or "unscoped", chosen by the caller from
# librarian_lesson_pregate. The two differ in one section only: whether an
# unbindable claim is refused or parked.
librarian_lesson_build_prompt() {
	local artifact="$1"
	local mode="${2:-versioned}"
```

Keep every existing `jq -r` extraction line unchanged. Then, in the heredoc, replace the block that currently runs from `VERSION RANGE RULES` through `refuse with "no_versions".` with a shell variable interpolated into the heredoc, built before the `cat <<EOF`:

```bash
	local scope_rules
	if [[ "$mode" == "unscoped" ]]; then
		# No version token anywhere in the artifact, so asking for a range
		# would only invite invention. The model states the claim and leaves
		# the scope open; a human decides whether it truly holds regardless of
		# version, and a jury checks that. no_versions is unreachable here by
		# construction — there is nothing to refuse for.
		scope_rules='SCOPE — this artifact carries no version information.
Do NOT invent a version range. Output scope exactly:
  "scope": { "kind": "unscoped" }
The scope object must contain nothing but that one key. A human will decide
whether this lesson holds regardless of version; you are not asserting that.

Refuse ONLY with "no_resolution" if the artifact records a problem but not
what resolved it.'
	else
		scope_rules='VERSION RANGE RULES — these are strict and a violation is discarded:
- Allowed: "<6", "<=6", "=6", ">4", ">=4", or two-sided ">=4 <6".
- FORBIDDEN: npm syntax. Never "^5.4.21", "~5", "5.x", or a bare "5.4.21".
- FORBIDDEN: ">=0", ">=0.0", ">=0.0.0". An unbounded lower bound matches
  everything and would never expire.
- Every key in versions MUST also appear in stack.
- Generalize honestly. Observing a break on vite 5.4.21 with vitest 4.1.9
  supports {"vite": "<6", "vitest": ">=4"} only if the cause is the missing
  API rather than that exact build.

There is no version-independent option. If the claim is not bound to a
version range, refuse with "no_versions".'
	fi
```

In the heredoc body, replace that removed block with `${scope_rules}`, and add the mode marker immediately above `<artifact>` so a test (and a transcript) can tell the two apart:

```
<scope-mode>${mode}</scope-mode>
```

The `REFUSE when either is true` list near the top still names both reasons. Leave it: `no_versions` being listed but unreachable in `unscoped` mode is harmless, and the scope section above is unambiguous about which refusals apply. Also change the `applies_to` example's `scope` line to `"scope": <as directed below>` so the example does not contradict the `unscoped` instruction.

- [ ] **Step 4: Pass the mode through `librarian_lesson_call`**

```bash
# Usage: librarian_lesson_call <artifact_json> [model] [mode]
librarian_lesson_call() {
	local artifact="$1"
	local model="${2:-}"
	local mode="${3:-versioned}"
```

and in its body:

```bash
	librarian_lesson_build_prompt "$artifact" "$mode" > "$prompt_file" || return 0
```

- [ ] **Step 5: Route in `transform_one`**

Replace the pre-gate skip at `:248-251`:

```bash
	# The pre-gate routes, it does not gate. A version-shaped token means a
	# range is plausibly bindable, so ask for one; its absence means asking
	# would invite invention, so park the claim for a human instead. Nothing
	# is dropped without a record — see ONL-107.
	local mode="versioned"
	librarian_lesson_pregate "$artifact" || mode="unscoped"
```

and pass it to the call:

```bash
	raw=$(librarian_lesson_call "$artifact" "$model" "$mode")
```

Leave everything downstream — the refusal branch, provenance stitching, `validate_candidate`, `write_proposal`, and the `proposed:<id>` return — untouched. A parked candidate is a proposal like any other.

- [ ] **Step 6: Run the tests and confirm all four pass**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats`
Expected: PASS, with every pre-existing test in the file still green — in particular `transform_one declines the real vitest artifact for having no resolution` and `transform_one declines when the model cannot infer versions`, which prove the versioned route kept its refusals.

- [ ] **Step 7: Commit**

Invoke `/git-workflow:commit`: a `feat(librarian)` change making the pre-gate route rather than skip, whose body explains that a token-less artifact was previously dropped with no record at all and is now parked for a human. `Refs ONL-107`.

---

### Task 3: Cap the newly reachable route

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-transform.sh` (`transform_one` gains an opt-in cap check), `plugins/librarian/scripts/lib/librarian-classify-worker.sh:465-485`, `plugins/librarian/config.json`
- Test: `test/bats/librarian-lesson-transform.bats`

**Interfaces:**
- Consumes: Task 2's `mode` routing.
- Produces: the result string `skipped:unscoped_cap`, and config key `.librarian.lesson_transform.unscoped_per_scan` (integer, default 3).

- [ ] **Step 1: Write the failing test**

```bash
@test "the unscoped route stops at the cap and declines nothing" {
  _transform_setup
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"librarian":{"lesson_transform":{"unscoped_per_scan":1}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
  librarian_config_load "$PROJECT_REPO"

  for i in 1 2; do
    art=$(_seed "01M3B87J7046SJE5BECNMP670${i}" "Release-As bumps every component" \
      "A bare footer was meant for one package and hit the whole manifest.")
    run librarian_lesson_transform_one "$PROJECT_KEY" "$art" "$((i - 1))"
    if [ "$i" -eq 1 ]; then
      [[ "$output" == proposed:* ]]
    else
      [ "$output" = "skipped:unscoped_cap" ]
    fi
  done

  # A cost-control skip must leave no terminal record, or the artifact is lost.
  [ ! -f "${LESSONS_DIR}/declined.jsonl" ] || \
    ! grep -q "01M3B87J7046SJE5BECNMP6702" "${LESSONS_DIR}/declined.jsonl"
}

@test "the cap does not apply to the versioned route" {
  _transform_setup
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"librarian":{"lesson_transform":{"unscoped_per_scan":0}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
  librarian_config_load "$PROJECT_REPO"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art" 99
  [[ "$output" == proposed:* ]]
}
```

Use the pattern the file already proves at `:555` (`librarian_lesson_call reads timeout_seconds from config`), not a home-directory path: `_transform_setup` calls `librarian_config_load "$PROJECT_REPO"` once, so a settings file written afterward is invisible until config is re-loaded. Write to the project repo and re-load explicitly:

```bash
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"librarian":{"lesson_transform":{"unscoped_per_scan":1}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
  librarian_config_load "$PROJECT_REPO"
```

Writing to `${TEST_HOME}/.claude/settings.json` without the re-load leaves the shipped default in force, and the cap test then passes or fails for a reason unrelated to the cap.

- [ ] **Step 2: Run and confirm failure**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats`
Expected: FAIL — `transform_one` takes two arguments today, so the third is ignored and both artifacts are parked.

- [ ] **Step 3: Add the cap check to `transform_one`**

A third optional parameter keeps the counter in the caller, so the function stays free of cross-invocation state and the cap is testable directly.

```bash
# Usage: librarian_lesson_transform_one <key> <artifact_json> [unscoped_so_far]
#
# unscoped_so_far is how many artifacts this scan has already routed to the
# unscoped path. The caller owns the count; this function only compares it to
# the configured cap. Omitted, it defaults to 0, so a direct caller gets one
# parked candidate and no surprise.
librarian_lesson_transform_one() {
	local key="$1"
	local artifact="$2"
	local unscoped_so_far="${3:-0}"
```

After the mode is resolved in Step 5 of Task 2, and before the model is called:

```bash
	if [[ "$mode" == "unscoped" ]]; then
		local unscoped_cap
		unscoped_cap=$(librarian_config_get '.librarian.lesson_transform.unscoped_per_scan' 2>/dev/null)
		[[ -z "$unscoped_cap" || "$unscoped_cap" == "null" ]] && unscoped_cap=3
		if [[ "$unscoped_so_far" -ge "$unscoped_cap" ]]; then
			# Deliberately writes NO decline record. A decline is terminal
			# (librarian_lesson_seen reads declined.jsonl), so recording one
			# for a cost-control skip would destroy the candidate forever.
			# Skipping means the artifact is reconsidered on a later scan,
			# which is the direction this stage already treats as safe.
			printf 'skipped:unscoped_cap'
			return 0
		fi
	fi
```

- [ ] **Step 4: Count in the worker**

In `librarian-classify-worker.sh`, beside `LESSON_PROPOSED=0`:

```bash
LESSON_UNSCOPED=0
LESSON_CAPPED=0
```

Pass the count and read the new result, inside the existing loop:

```bash
	LESSON_RESULT=$(librarian_lesson_transform_one "$PROJECT_KEY" "$LESSON_ARTIFACT" "$LESSON_UNSCOPED")
	case "$LESSON_RESULT" in
		proposed:*:unscoped)
			LESSON_PROPOSED=$((LESSON_PROPOSED + 1))
			LESSON_UNSCOPED=$((LESSON_UNSCOPED + 1))
			;;
		proposed:*) LESSON_PROPOSED=$((LESSON_PROPOSED + 1)) ;;
		declined:*) LESSON_DECLINED=$((LESSON_DECLINED + 1)) ;;
		skipped:unscoped_cap) LESSON_CAPPED=$((LESSON_CAPPED + 1)) ;;
	esac
```

The route rides on stdout because it has to: `transform_one` is called inside a command substitution, so a variable it exports cannot reach the worker. Re-deriving the route in the worker by copying the pre-gate's regex was the alternative and is rejected — two copies of that pattern would drift.

So in `transform_one`, the parked write returns `proposed:<id>:unscoped` while the versioned write keeps `proposed:<id>`:

```bash
	if [[ "$mode" == "unscoped" ]]; then
		printf 'proposed:%s:unscoped' "$id"
	else
		printf 'proposed:%s' "$id"
	fi
```

`proposed:*` still matches both, so no existing matcher in the suite breaks — but any test extracting the id with `${output#proposed:}` gets `<id>:unscoped` for a parked candidate. Task 2's parked tests must therefore strip twice:

```bash
  id="${output#proposed:}"; id="${id%%:*}"
```

Check every `proposed:` matcher in `test/bats/` before finishing this task and fix any that extract an id from a parked result.

- [ ] **Step 5: Add the config default**

In `plugins/librarian/config.json`, inside `librarian.lesson_transform`:

```json
    "unscoped_per_scan": 3
```

- [ ] **Step 6: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-transform.bats`
Expected: PASS, both new tests and every existing one.

- [ ] **Step 7: Commit**

`/git-workflow:commit`: a `feat(librarian)` change bounding the unscoped route, body explaining why a capped artifact writes no decline record and which option from Step 4 you chose.

---

### Task 4: Make a parked candidate usable by a human

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-review.sh:90` (refusal), `plugins/librarian/scripts/lib/librarian-cli.sh` (`librarian_cli_lessons_list`, `librarian_cli_lessons_show`), `plugins/librarian/skills/librarian/SKILL.md` (the lesson walkthrough, around the `confirm` bullet)
- Test: `test/bats/librarian-lesson-review.bats`

**Interfaces:**
- Consumes: Task 1's `unscoped` kind, Task 2's parked proposals on disk.
- Produces: no new function signatures. `librarian_lesson_confirm` keeps `<key> <lesson_id> <visibility> [justification]`.

- [ ] **Step 1: Write the failing tests**

The confirm tests live in `test/bats/librarian-lesson-review.bats` — there is no `librarian-lesson-confirmation.bats`. That file already has exactly the helpers needed: `_candidate <scope_json>` (:20), `_versioned()` (:26), `_indep()` (:27), `_review_setup()` (:80), `_seed_pending()` (:112), and `_cli_setup()` (:380) for the CLI-facing tests.

First add a scope helper beside the other two, at :27:

```bash
_unscoped() { printf '%s' '{"kind":"unscoped"}'; }
```

and a seeder beside `_seed_pending`, which returns the new lesson id on stdout exactly as `librarian_lesson_write_proposal` does:

```bash
_seed_pending_unscoped() {
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "$(_unscoped)")" "01M3B87J7046SJE5BECNMP670K"
}
```

Then the tests — note `_review_setup` for the first three and `_cli_setup` for the `list` one, matching how the file already splits them:

```bash
@test "confirming a parked candidate without a justification is refused" {
  _review_setup
  id=$(_seed_pending_unscoped)
  run librarian_lesson_confirm "$PROJECT_KEY" "$id" org
  [ "$status" -ne 0 ]
  [[ "$output" == *"justification"* ]]
}

@test "confirming a parked candidate with a justification rewrites it to version_independent" {
  _review_setup
  id=$(_seed_pending_unscoped)
  run librarian_lesson_confirm "$PROJECT_KEY" "$id" org \
    "release-please applies an unscoped footer to the whole manifest in every version."
  [ "$status" -eq 0 ]
  jq -e '.candidate.applies_to.scope.kind == "version_independent"
     and (.candidate.applies_to.scope | has("versions") | not)' \
    "${LESSONS_DIR}/proposals/${id}.json"
}

@test "a parked candidate cannot be confirmed private even with a justification" {
  _review_setup
  id=$(_seed_pending_unscoped)
  run librarian_lesson_confirm "$PROJECT_KEY" "$id" private "holds regardless of version"
  [ "$status" -ne 0 ]
}

@test "lessons list marks a parked candidate" {
  _cli_setup
  _seed_pending_unscoped
  run librarian_cli lessons list
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs scope"* ]]
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-review.bats`
Expected: the first and fourth FAIL. The second and third may already pass — the justification rewrite is scope-kind-agnostic and the private guard at `:125` checks the resulting state — which is the point: confirm them as passing rather than assuming they need code.

- [ ] **Step 3: Refuse a scopeless confirm**

In `librarian_lesson_confirm`, after the file is read and `candidate` extracted, and **before** the `if [[ -n "$justification" ]]` rewrite block:

```bash
	# A parked candidate carries no scope of its own. Confirming it without a
	# justification would write a lesson asserting nothing, which
	# librarian_lesson_validate_confirmed refuses anyway — refuse here instead,
	# where the message can say what is actually required.
	if [[ -z "$justification" ]] && printf '%s' "$candidate" \
		| jq -e '.applies_to.scope.kind == "unscoped"' >/dev/null 2>&1; then
		printf 'this lesson has no version scope: confirming it requires --justification (why it holds regardless of version), at org or public visibility so a jury checks the claim\n' >&2
		return 1
	fi
```

- [ ] **Step 4: Mark parked candidates in `list` and `show`**

Read `librarian_cli_lessons_list` and `librarian_cli_lessons_show`, then append the suffix `— needs scope` (preceded by a space) to a parked row's rendered line and add a `scope: unscoped (needs a justification)` line to `show`'s output. Match each function's existing rendering style — if rows are built in a `jq -r` expression, extend that expression rather than post-processing its output.

- [ ] **Step 5: Teach the walk**

In `plugins/librarian/skills/librarian/SKILL.md`, in the lesson walkthrough at step 4 (where routing options are listed), add:

```markdown
   - **A parked candidate** (`show` reports `scope: unscoped`) has no version
     scope: the transform could not bind one and left it to you. Confirming it
     **requires** `--justification` — why the lesson holds regardless of version
     — and therefore `org` or `public`, because a `private` lesson runs no jury
     and the justification would go unchecked. Do not offer `private` for one.
     Ask for the justification in the user's own words; never write it for them.
```

- [ ] **Step 6: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-review.bats`
Expected: PASS, all four plus the file's existing tests.

- [ ] **Step 7: Commit**

`/git-workflow:commit`: a `feat(librarian)` change making a parked candidate confirmable, body explaining that without the refusal and the marker the walk would offer `private` and dead-end.

---

### Task 5: Recover the artifacts already declined

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-storage.sh` (new removal function), `plugins/librarian/scripts/lib/librarian-archivist-reader.sh` (new by-id reader), `plugins/librarian/scripts/lib/librarian-cli.sh` (dispatch + new function)
- Create: `test/bats/librarian-lesson-reconsider.bats`

**Interfaces:**
- Consumes: Task 2's routing and Task 3's cap.
- Produces: `librarian_lesson_remove_declined <key> <reason>` printing the removed `artifact_id`s one per line; `librarian_archivist_load_by_id <key> <artifact_id>` printing one artifact's JSON or nothing; `librarian_cli lessons reconsider [--limit N] [cwd]`.

- [ ] **Step 1: Write the failing tests**

Create `test/bats/librarian-lesson-reconsider.bats`, modeled on `librarian-lesson-transform.bats`'s setup (it needs the stub `claude` and the seeded archivist artifacts, so reuse `_transform_setup` and `_seed` by copying them or sourcing a shared helper — check whether `test/helpers/` already exposes one before duplicating).

```bash
@test "remove_declined removes only the named reason and reports the ids" {
  _reconsider_setup
  printf '%s\n' \
    '{"artifact_id":"01M3B87J7046SJE5BECNMP670K","reason":"no_versions","declined_at":"2026-09-20T17:39:59Z"}' \
    '{"artifact_id":"01M3B93JPGAKHGEQ5KD9N836HD","reason":"no_resolution","declined_at":"2026-09-21T23:18:55Z"}' \
    '{"artifact_id":"01M33440PGTWP4QMMG1BVA52DR","reason":"no_versions","declined_at":"2026-09-21T23:18:55Z"}' \
    > "${LESSONS_DIR}/declined.jsonl"

  run librarian_lesson_remove_declined "$PROJECT_KEY" no_versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"01M3B87J7046SJE5BECNMP670K"* ]]
  [[ "$output" == *"01M33440PGTWP4QMMG1BVA52DR"* ]]
  [ "$(wc -l < "${LESSONS_DIR}/declined.jsonl" | tr -d ' ')" -eq 1 ]
  jq -e '.reason == "no_resolution"' < "${LESSONS_DIR}/declined.jsonl"
}

@test "remove_declined survives a truncated trailing line" {
  _reconsider_setup
  printf '%s\n' \
    '{"artifact_id":"01M3B87J7046SJE5BECNMP670K","reason":"no_versions"}' \
    '{"artifact_id":"01M33440PGTWP' \
    > "${LESSONS_DIR}/declined.jsonl"
  run librarian_lesson_remove_declined "$PROJECT_KEY" no_versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"01M3B87J7046SJE5BECNMP670K"* ]]
}

@test "reconsider replays a no_versions decline into a parked proposal" {
  _reconsider_setup
  _seed_artifact_on_disk "01M3B87J7046SJE5BECNMP670K" \
    "Release-As bumps every component" \
    "A bare footer was meant for one package and hit the whole manifest."
  printf '%s\n' \
    '{"artifact_id":"01M3B87J7046SJE5BECNMP670K","reason":"no_versions","declined_at":"2026-09-20T17:39:59Z"}' \
    > "${LESSONS_DIR}/declined.jsonl"

  run librarian_cli lessons reconsider
  [ "$status" -eq 0 ]
  [ "$(ls "${LESSONS_DIR}/proposals" | wc -l | tr -d ' ')" -eq 1 ]
  jq -e '.candidate.applies_to.scope.kind == "unscoped"' \
    "${LESSONS_DIR}/proposals/"*.json
}

@test "reconsider leaves a decline in place when its artifact is gone" {
  _reconsider_setup
  printf '%s\n' \
    '{"artifact_id":"01M3B87J7046SJE5BECNMP670K","reason":"no_versions","declined_at":"2026-09-20T17:39:59Z"}' \
    > "${LESSONS_DIR}/declined.jsonl"
  run librarian_cli lessons reconsider
  [ "$status" -eq 0 ]
  grep -q "01M3B87J7046SJE5BECNMP670K" "${LESSONS_DIR}/declined.jsonl"
  [[ "$output" == *"artifact missing"* ]]
}
```

`_seed_artifact_on_disk` writes to `${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions/<id>.json`, which is the layout `librarian-archivist-reader.sh` documents and reads. `setup_test_env` exports `ONLOOKER_DIR="${TEST_HOME}/.onlooker"`, so the whole tree is inside the isolated home:

```bash
_seed_artifact_on_disk() {
	local dir="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions"
	mkdir -p "$dir"
	jq -cn --arg id "$1" --arg s "$2" --arg d "$3" --arg k "$PROJECT_KEY" \
		'{id: $id, kind: "decision", project_key: $k, session_id: "sess-1",
		  created_at: "2026-08-03T15:59:48Z", summary: $s, detail: $d, files: []}' \
		> "${dir}/$1.json"
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-reconsider.bats`
Expected: FAIL — neither function exists.

- [ ] **Step 3: Implement the removal**

In `librarian-lesson-storage.sh`, beside `librarian_lesson_append_declined`:

```bash
# Remove every decline record with the given reason, printing the removed
# artifact_ids one per line. Rewrites atomically through the same temp-then-mv
# path the other writers use, so a reader never sees a half-written file.
#
# The -R/fromjson?/objects guard mirrors librarian_lesson_seen: one truncated
# trailing line must not take the whole file with it, and a line that parses to
# a non-object must not error out the invocation.
#
# Usage: librarian_lesson_remove_declined <key> <reason>
librarian_lesson_remove_declined() {
	local key="$1"
	local reason="$2"
	[[ -z "$key" || -z "$reason" ]] && return 1

	local dir
	dir=$(librarian_lessons_dir "$key")
	local file="$dir/declined.jsonl"
	[[ -f "$file" ]] || return 0

	jq -Rr --arg r "$reason" \
		'fromjson? | objects | select(.reason == $r) | .artifact_id' \
		"$file" 2>/dev/null

	local tmp="${file}.$$"
	jq -Rr --arg r "$reason" \
		'select((fromjson? | objects | select(.reason == $r) | .artifact_id) == null)' \
		"$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
	return 0
}
```

Verify the `select(... == null)` retention filter against the second test (the truncated line must be *kept*, since it is not a matching decline). If the filter drops it, invert the logic explicitly with a `. as $line | ($line | fromjson? | objects | .reason) as $rr | if $rr == $r then empty else $line end` form and keep the test as the arbiter.

- [ ] **Step 4: Implement the CLI action**

In `librarian-cli.sh`, add to `librarian_cli_lessons`'s case, after `promote`:

```bash
		reconsider) librarian_cli_lessons_reconsider "$@" ;;
```

and the function, modeled on the file's other `librarian_cli_lessons_*` functions for key resolution and output style:

```bash
# Replay artifacts that were declined no_versions back through the transform,
# which now routes them to the unscoped path instead of refusing. Only
# no_versions: no_resolution and schema_invalid are still correct refusals.
librarian_cli_lessons_reconsider() {
	# Arg shape copied from librarian_cli_lessons_promote: options, then an
	# optional trailing [cwd] positional that resolves the project key.
	local limit=0 cwd=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--limit) limit="${2:-0}"; shift 2 ;;
			--*) printf 'unknown option: %s\n' "$1" >&2; return 1 ;;
			*) cwd="$1"; shift ;;
		esac
	done

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	local ids id count=0 unscoped=0
	ids=$(librarian_lesson_remove_declined "$key" no_versions) || return 1
	[[ -z "$ids" ]] && { printf 'Nothing to reconsider: no no_versions declines.\n'; return 0; }

	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		if [[ "$limit" -gt 0 && "$count" -ge "$limit" ]]; then
			printf '%s: stopped at --limit %s\n' "$id" "$limit"
			librarian_lesson_append_declined "$key" "$id" no_versions
			continue
		fi
		local artifact
		artifact=$(librarian_archivist_load_by_id "$key" "$id" 2>/dev/null)
		if [[ -z "$artifact" ]]; then
			printf '%s: artifact missing, decline kept\n' "$id"
			librarian_lesson_append_declined "$key" "$id" no_versions
			continue
		fi
		local result
		result=$(librarian_lesson_transform_one "$key" "$artifact" "$unscoped")
		printf '%s: %s\n' "$id" "$result"
		case "$result" in
			proposed:*) unscoped=$((unscoped + 1)) ;;
		esac
		count=$((count + 1))
	done <<< "$ids"

	printf 'Reconsidered %s artifact(s).\n' "$count"
}
```

`librarian_archivist_load_by_id` does not exist yet. Add it to `plugins/librarian/scripts/lib/librarian-archivist-reader.sh`, beside `librarian_archivist_load_since`, reusing that file's `librarian_archivist_project_dir`. The layout is documented at the top of that file and confirmed on disk:

```bash
# Load one archivist artifact by its id, or print nothing if it is gone.
#
# reconsider needs a single artifact, not a watermark window, so this walks the
# three kind directories rather than reusing load_since's corpus-wide jq.
#
# Usage: librarian_archivist_load_by_id <project_key> <artifact_id>
librarian_archivist_load_by_id() {
	local project_key="$1"
	local artifact_id="$2"
	[[ -z "$project_key" || -z "$artifact_id" ]] && return 0

	# Reject anything that is not a bare ULID before it reaches a path: the id
	# comes from declined.jsonl, and a value with a slash or .. in it would
	# otherwise read outside the project dir.
	[[ "$artifact_id" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || return 0

	local project_dir
	project_dir=$(librarian_archivist_project_dir "$project_key")
	[[ -z "$project_dir" ]] && return 0

	local kind file
	for kind in decisions dead_ends open_questions; do
		file="${project_dir}/${kind}/${artifact_id}.json"
		[[ -f "$file" ]] || continue
		jq -c '. | select(type == "object")' "$file" 2>/dev/null
		return 0
	done
	return 0
}
```

Note the kind list matches `librarian_archivist_load_since`'s exactly — `decisions`, `dead_ends`, `open_questions`. Do not add `extracts` here to make one test pass; if a reconsidered id turns out to live in an `extracts` directory, stop and raise it, because then the scan is not reading those either and that is a separate finding.

Re-appending a decline for a skipped or missing artifact is deliberate: `remove_declined` has already rewritten the file, so without it a `--limit` run would silently make every remaining id eligible on the next scan, outside the cap.

- [ ] **Step 5: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-reconsider.bats`
Expected: PASS, all four.

- [ ] **Step 6: Run everything**

Run: `npm run test:ci`
Expected: PASS. If `shellcheck` objects to the `<<< "$ids"` here-string or the `local` inside the loop, fix the shell rather than adding a disable comment.

- [ ] **Step 7: Commit**

`/git-workflow:commit`: a `feat(librarian)` change adding `lessons reconsider`, body explaining that a decline is terminal so recovering the 11 requires rewriting the record, and that only `no_versions` is replayed.

---

## After the plan

- [ ] **Verify end to end against the real backlog**

On this machine, with the branch checked out:

```bash
librarian_cli lessons reconsider --limit 3
librarian_cli lessons list
librarian_cli lessons show <id>
librarian_cli lessons confirm <id> org --justification "<Meagan's own words>"
librarian_cli lessons list --confirmed
```

Then `/librarian lessons judge` for the jury, which is the first point real model cost is spent on a judged visibility. **Report the batch and wait for Meagan's go-ahead before dispatching a single judge** — the SKILL.md safety rule, and the most expensive step in the pipeline.

- [ ] **Close out**

`bd close ecosystem-65mqw6` once an approved lesson exists, then open the PR with `/git-workflow:pr`. ONL-107 needs a closing keyword to move — `Refs` links but does not close it.
