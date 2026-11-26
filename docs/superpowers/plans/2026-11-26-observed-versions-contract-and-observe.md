# Observed Versions: Contract and Observe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a lesson carry the exact tool versions it was observed on, and
build the resolver that reads those versions from a project without a model
call, then measure how often it succeeds.

**Architecture:** Two repos and two PRs. Part A changes the lesson contract in
the onlooker repo (`packages/lesson-contract`). It adds a `no_stack` scope that
is legal only with an empty stack, an optional `applies_to.topics`, and optional
`evidence.observed_on` and `evidence.unresolved`, with cross-field rules at
ingest. Part B adds `librarian-lesson-observe.mjs` to librarian, wrapped by a
bash function, and a free measurement over the real lesson store. Nothing in
this plan changes what librarian writes. The transform starts using Observe in
rollout step 3, which gets its own plan.

**Tech Stack:** TypeScript, zod 4.4.3, vitest, pnpm (onlooker). Node and bash
3.2-compatible bash, bats (ecosystem).

**Spec:** `docs/superpowers/specs/2026-11-26-evidenced-lesson-portability-design.md`,
rollout steps 1 and 2.

## Global Constraints

- The contract change is additive. Every lesson that parses today still
  parses, so `schema_version` stays `2` and the package bumps minor:
  `@onlooker-community/lesson-contract` 2.1.0 → **2.2.0**. `deploy.yml`'s
  `contract-version` job fails a schema change without a version bump.
- An empty `stack` is legal **only** with `scope.kind == "no_stack"`, and
  `no_stack` is legal only with an empty `stack`. This is in the schema itself
  (a union), not only at ingest, so a failed transform still can't mint a
  lesson that matches everything.
- `version_independent` stays in the contract, because existing pool entries
  use it.
- Observe never calls a model, never writes to the lesson store, and exits 0
  with empty output on any failure. It reads repo state with `git show
  <sha>:<path>`, never from the working tree.
- Observe runs in the detached transform (ADR-003), never at SessionEnd.
- Nothing in this plan emits an event, so no event type is registered.
  `librarian.lesson.recurred` and `librarian.lesson.kept_local` are registered
  by the plans for rollout steps 4 and 6, which emit them.
- `wrangler.toml` `compatibility_date` is left out until the spec's open
  question 2 is answered. `go.sum` and `Cargo.lock` are left out too: no repo
  registered in the store has either (checked 2026-11-26), so they would be
  untested code. `Gemfile.lock` (careeros, codegym) and `uv.lock` (unhoard)
  are in.
- An observation is `{version, source, basis[, flavor]}`. That extends the
  spec's `{version, source}` with when it was read and, for awk, grep and sed,
  which build it was.
- Commits go through `/git-workflow:commit`, in both repos.
- American English everywhere.

## Before you start

1. **Linear.** Ask Meagan to file, or approve filing, one ONL issue covering
   both PRs: "Lessons record the versions they were observed on". The
   workspace is on the free plan (250 non-archived issues), so file it only
   when work starts. Call its id `ONL-313` below.
2. **onlooker.** That checkout is on `meagan/onl-308-tribunal-override-signal`
   and has untracked files. Don't switch it. Use a worktree:

   ```bash
   cd ~/src/github.com/onlooker-community/onlooker
   git fetch origin
   git worktree add ../onlooker-onl-313 -b meagan/onl-313-observed-versions-contract origin/main
   cd ../onlooker-onl-313 && pnpm install
   ```

3. **ecosystem.** Branch from `origin/main`, not from the current branch:

   ```bash
   cd ~/src/github.com/onlooker-community/ecosystem
   git fetch origin
   git switch -c meagan/onl-313-observe-versions origin/main
   ```

---

## Part A: the contract (onlooker repo)

All paths in Part A are relative to the onlooker worktree.

### Task 1: `no_stack` scope, empty stack only with it, and `topics`

**Files:**
- Modify: `packages/lesson-contract/src/applies-to.ts`
- Modify: `packages/lesson-contract/src/applies-to.test.ts:83-85`
- Modify: `packages/lesson-contract/src/json-schema.test.ts:13-17` (the `versionedBranch` helper)
- Regenerate: `packages/lesson-contract/schema/lesson.schema.json`

**Interfaces:**
- Produces: `ZScope` with three kinds: `versioned`, `version_independent`,
  `no_stack`. `ZAppliesTo` becomes a `z.union` of a with-stack object (stack
  `min(1)`, scope `versioned | version_independent`) and a no-stack object
  (stack `max(0)`, scope `{kind: "no_stack"}`). Both carry `file_patterns`,
  `task_kinds` and optional `topics: string[]`. `TAppliesTo` is the union type.

- [ ] **Step 1: Write the failing tests**

In `applies-to.test.ts`, replace the test at lines 83-85 ("requires at least
one stack entry...") with:

```ts
	// An empty stack is how a failed transform would mint a lesson that
	// matches everything, so it is legal only when the scope says so.
	it("rejects an empty stack under a versioned scope", () => {
		expect(ZAppliesTo.safeParse({ ...valid, stack: [] }).success).toBe(false);
	});

	it("rejects an empty stack under a version_independent scope", () => {
		expect(
			ZAppliesTo.safeParse({
				...valid,
				stack: [],
				scope: { kind: "version_independent", justification: "j" },
			}).success,
		).toBe(false);
	});

	it("accepts an empty stack with the no_stack scope", () => {
		const noStack = { ...valid, stack: [], scope: { kind: "no_stack" } };
		expect(ZAppliesTo.parse(noStack)).toEqual(noStack);
	});

	it("rejects no_stack when the stack names a tool", () => {
		expect(
			ZAppliesTo.safeParse({ ...valid, scope: { kind: "no_stack" } }).success,
		).toBe(false);
	});

	it("rejects a no_stack scope carrying anything but its kind", () => {
		expect(
			ZAppliesTo.safeParse({
				...valid,
				stack: [],
				scope: { kind: "no_stack", justification: "j" },
			}).success,
		).toBe(false);
	});

	it("accepts topics beside the stack", () => {
		const withTopics = { ...valid, topics: ["testing", "refactoring"] };
		expect(ZAppliesTo.parse(withTopics)).toEqual(withTopics);
	});

	it("still accepts applicability with no topics field", () => {
		expect(ZAppliesTo.safeParse(valid).success).toBe(true);
	});

	it("rejects an empty topic", () => {
		expect(ZAppliesTo.safeParse({ ...valid, topics: [""] }).success).toBe(
			false,
		);
	});
```

In `json-schema.test.ts`, replace the `versionedBranch` helper (lines 13-17)
and add two tests inside `describe("emitted JSON Schema", ...)`:

```ts
/**
 * applies_to is a union: one branch with a stack, one without. The
 * with-stack branch is the one whose stack requires an entry.
 */
const withStackBranch = (json: Record<string, any>) =>
	json.properties.applies_to.anyOf.find(
		(branch: any) => branch.properties.stack.minItems === 1,
	);

/**
 * The versioned branch of applies_to.scope. Found by discriminator rather than
 * by index so the test does not depend on how zod happens to order oneOf.
 */
const versionedBranch = (json: Record<string, any>) =>
	withStackBranch(json).properties.scope.oneOf.find(
		(branch: any) => branch.properties.kind.const === "versioned",
	);
```

```ts
	it("publishes the no_stack branch with an empty stack", () => {
		const json = z.toJSONSchema(ZLesson) as Record<string, any>;
		const noStack = json.properties.applies_to.anyOf.find(
			(branch: any) => branch.properties.scope.properties?.kind?.const === "no_stack",
		);
		expect(noStack).toBeDefined();
		expect(noStack.properties.stack.maxItems).toBe(0);
	});

	it("keeps an entry required in the with-stack branch", () => {
		const json = z.toJSONSchema(ZLesson) as Record<string, any>;
		expect(withStackBranch(json)).toBeDefined();
	});
```

Then update the existing "publishes both scope branches" test, which reads
`json.properties.applies_to.properties.scope.oneOf`, to read
`withStackBranch(json).properties.scope.oneOf`. It still expects exactly
`versioned` and `version_independent`.

- [ ] **Step 2: Run them and confirm they fail**

Run: `pnpm --filter @onlooker-community/lesson-contract test`
Expected: FAIL. The no_stack tests fail on parse, and the JSON Schema tests
fail because `applies_to` has no `anyOf`.

- [ ] **Step 3: Change `applies-to.ts`**

Replace `ZScope` and `ZAppliesTo` (from `export const ZScope` to the end of
the file) with:

```ts
const ZVersioned = z.strictObject({
	kind: z.literal("versioned"),
	versions: ZVersions,
});

const ZVersionIndependent = z.strictObject({
	kind: z.literal("version_independent"),
	justification: z
		.string()
		.min(1)
		.describe(
			"Why this lesson holds regardless of version. Judged, not assumed.",
		),
});

/**
 * A lesson that names no tool. Unlike version_independent it carries no
 * justification, because nothing is being argued: with an empty stack there
 * is nothing that could have a version. That is checkable, which is why it
 * is allowed only beside an empty stack (see ZAppliesTo).
 */
const ZNoStack = z.strictObject({ kind: z.literal("no_stack") });

/**
 * How a lesson's applicability is bounded in time.
 *
 * A tagged union rather than an optional map, because one field cannot carry
 * two meanings. "This lesson has no version dependency" and "the transform
 * could not infer a version" are different facts, and an empty map expressed
 * both. A lesson with no version constraint never expires, so an inference
 * failure used to mint an immortal lesson silently.
 *
 * The version_independent branch demands a justification precisely so that a
 * transform which simply failed has nothing to put there. It cannot default
 * into this branch; it fails validation instead. Librarian stops producing it
 * from contract 2.2.0 (the evidenced-portability design); it stays because
 * pool entries use it.
 */
export const ZScope = z.discriminatedUnion("kind", [
	ZVersioned,
	ZVersionIndependent,
	ZNoStack,
]);
export type TScope = z.infer<typeof ZScope>;

const ZTopics = z
	.array(z.string().min(1))
	.optional()
	.describe(
		"Concepts the lesson is about, such as testing or rate-limiting. " +
			"Kept out of stack because a concept has no version.",
	);

const ZFilePatterns = z.array(z.string().min(1));
const ZTaskKinds = z.array(z.string().min(1));

/**
 * What retrieval matches a lesson against.
 *
 * scope is the field that makes staleness structural. Scoping a lesson to
 * vite <6 means a session on vite 8 never matches it, so the lesson retires
 * itself by construction rather than waiting for someone to review it.
 *
 * Two shapes. With a stack, the stack needs an entry and the scope is
 * versioned or version_independent. Without one, the scope must be no_stack.
 * The empty stack used to be refused outright, because it matches every
 * session; it is legal now only where the scope says so on purpose, so a
 * transform that simply produced nothing still fails.
 *
 * Every key of scope.versions must name an entry in stack. That is deliberately
 * NOT enforced here, for the same reason ZConsensus does not enforce
 * agreed <= judges: it is a cross-field rule, JSON Schema cannot express one,
 * and a .check() would make this package reject values the published artifact
 * accepts. The plugins that produce lessons validate against that artifact and
 * cannot import this package, so an invisible rule would fail them with no way
 * to have known. Cross-field rules belong at ingest, where both sides see the
 * same error.
 *
 * A key naming something absent from stack is a defect: depending on how
 * retrieval treats an unmatched key, the lesson either never matches or the
 * constraint is skipped, and skipping it produces a lesson that never expires.
 */
export const ZAppliesTo = z
	.union([
		z.strictObject({
			stack: z.array(z.string().min(1)).min(1),
			scope: z.discriminatedUnion("kind", [ZVersioned, ZVersionIndependent]),
			file_patterns: ZFilePatterns,
			task_kinds: ZTaskKinds,
			topics: ZTopics,
		}),
		z.strictObject({
			stack: z.array(z.string().min(1)).max(0),
			scope: ZNoStack,
			file_patterns: ZFilePatterns,
			task_kinds: ZTaskKinds,
			topics: ZTopics,
		}),
	])
	.describe(
		"Every key of scope.versions must name an entry in stack. That rule " +
			"is enforced at ingest, not by this schema, because JSON Schema " +
			"cannot express a constraint spanning two fields.",
	);
export type TAppliesTo = z.infer<typeof ZAppliesTo>;
```

Keep the existing `ZVersions` block and its imports above this unchanged.

- [ ] **Step 4: Rebuild the schema and run the tests**

Run:

```bash
pnpm --filter @onlooker-community/lesson-contract build
pnpm --filter @onlooker-community/lesson-contract test
```

Expected: PASS, including "guards the committed schema against drift", which
compares `schema/lesson.schema.json` to the zod source. If it fails, the build
didn't rewrite the file. Check that the build printed
`wrote schema/lesson.schema.json`.

- [ ] **Step 5: Typecheck the workspace**

Run: `pnpm -r typecheck`
Expected: errors in `apps/web/src/pages/LessonDetail.tsx`, which reads
`scope.justification` in its non-versioned branch. Step 6 fixes it. Any other
error is unexpected: read it before going on.

- [ ] **Step 6: Render `no_stack` and topics in `LessonDetail.tsx`**

Replace the Scope field's ternary (around lines 655-668) with:

```tsx
					<Field label="Scope">
						{appliesTo.scope.kind === "versioned" ? (
							<Chips
								values={Object.entries(appliesTo.scope.versions).map(
									([name, range]) => `${name} ${range}`,
								)}
							/>
						) : appliesTo.scope.kind === "no_stack" ? (
							// Nothing in the stack, so nothing that could have a version.
							<p style={{ margin: 0 }}>Names no tool, so no version applies.</p>
						) : (
							// The justification is the point of this branch: a lesson
							// with no version constraint never expires, so the reason
							// is judged rather than assumed.
							<p style={{ margin: 0 }}>{appliesTo.scope.justification}</p>
						)}
					</Field>

					{appliesTo.topics && appliesTo.topics.length > 0 ? (
						<Field label="Topics">
							<Chips values={appliesTo.topics} />
						</Field>
					) : null}
```

Leave the Stack field as is. `Chips` with an empty array renders nothing.
Then run `pnpm -r typecheck` again. Expected: clean.

- [ ] **Step 7: Commit**

`/git-workflow:commit` the three contract files, the regenerated schema and
`LessonDetail.tsx`:

```
feat(lesson-contract): let a lesson name no tool, and say so :card_index:

A concept-only lesson has nothing that could carry a version, so it needs
no version argument. It is legal only beside an empty stack, so a
transform that produced nothing still fails. topics holds the concepts
that used to be put in stack. The lesson page shows both, since it assumed
every non-versioned scope carried a justification.

Refs ONL-313
```

---

### Task 2: `observed_on` and `unresolved` on evidence, with ingest rules

**Files:**
- Modify: `packages/lesson-contract/src/evidence.ts`
- Modify: `packages/lesson-contract/src/evidence.test.ts`
- Modify: `packages/lesson-contract/src/index.ts` (export the new types)
- Modify: `apps/api/src/lessons/rules.ts:116-145`
- Modify: `apps/api/src/lessons/rules.test.ts`
- Regenerate: `packages/lesson-contract/schema/lesson.schema.json`

**Interfaces:**
- Produces: `ZObservation = {version: string(min 1), source: "lockfile" |
  "manifest" | "mise" | "workflow" | "component" | "probe", basis:
  "session_commit" | "head" | "machine", flavor?: "gnu" | "bsd"}`.
  `ZEvidence` gains `observed_on?: Record<string, TObservation>` and
  `unresolved?: string[]`. Exported: `ZObservation`, `TObservation`.
- Produces, in `rules.ts`: the rules `observed_key_in_stack`,
  `unresolved_in_stack` and `observed_and_unresolved_disjoint`.

- [ ] **Step 1: Write the failing contract tests**

Append to `evidence.test.ts`. It already has a `valid` evidence object at the
top. Use it, and import `ZObservation` beside `ZEvidence`:

```ts
describe("ZEvidence observations", () => {
	const observed = {
		vite: { version: "5.4.21", source: "lockfile", basis: "session_commit" },
		awk: { version: "20200816", source: "probe", basis: "machine", flavor: "bsd" },
	};

	it("accepts observed versions and unresolved entries", () => {
		const e = { ...valid, observed_on: observed, unresolved: ["Sentry"] };
		expect(ZEvidence.parse(e)).toEqual(e);
	});

	it("still accepts evidence with neither field", () => {
		expect(ZEvidence.safeParse(valid).success).toBe(true);
	});

	it("rejects an observation with no version", () => {
		expect(
			ZObservation.safeParse({ version: "", source: "lockfile", basis: "head" })
				.success,
		).toBe(false);
	});

	it("rejects a source it does not know", () => {
		expect(
			ZObservation.safeParse({ version: "1", source: "guess", basis: "head" })
				.success,
		).toBe(false);
	});

	it("rejects a basis it does not know", () => {
		expect(
			ZObservation.safeParse({ version: "1", source: "probe", basis: "now" })
				.success,
		).toBe(false);
	});

	it("rejects an extra key on an observation", () => {
		expect(
			ZObservation.safeParse({
				version: "1",
				source: "probe",
				basis: "machine",
				range: ">=1",
			}).success,
		).toBe(false);
	});
});
```

- [ ] **Step 2: Write the failing ingest-rule tests**

The file builds lessons with `validLesson(overrides)`, whose stack is
`["vite"]`, and calls `checkCrossFieldRules(lesson)`. Append:

```ts
// Rules delegated from ZEvidence in evidence.ts.
describe("observed versions", () => {
	const ev = (extra: object) =>
		({ ...validLesson().evidence, ...extra }) as TLesson["evidence"];
	const rules = (lesson: TLesson) =>
		checkCrossFieldRules(lesson).map((v) => v.rule);

	it("accepts observations keyed by stack entries", () => {
		expect(
			checkCrossFieldRules(
				validLesson({
					evidence: ev({
						observed_on: {
							vite: { version: "5.4.21", source: "lockfile", basis: "session_commit" },
						},
						unresolved: [],
					}),
				}),
			),
		).toEqual([]);
	});

	it("rejects an observation for something not in the stack", () => {
		expect(
			rules(
				validLesson({
					evidence: ev({
						observed_on: {
							react: { version: "18.2.0", source: "lockfile", basis: "head" },
						},
					}),
				}),
			),
		).toEqual(["observed_key_in_stack"]);
	});

	it("rejects an unresolved entry not in the stack", () => {
		expect(
			rules(validLesson({ evidence: ev({ unresolved: ["Sentry"] }) })),
		).toEqual(["unresolved_in_stack"]);
	});

	it("rejects an entry both observed and unresolved", () => {
		expect(
			rules(
				validLesson({
					evidence: ev({
						observed_on: {
							vite: { version: "5.4.21", source: "lockfile", basis: "head" },
						},
						unresolved: ["vite"],
					}),
				}),
			),
		).toEqual(["observed_and_unresolved_disjoint"]);
	});
});
```

- [ ] **Step 3: Run both and confirm they fail**

Run:

```bash
pnpm --filter @onlooker-community/lesson-contract test
pnpm --filter @onlooker/api test -- src/lessons/rules.test.ts
```

Expected: FAIL. `ZObservation` isn't exported, and the three rules don't
exist.

- [ ] **Step 4: Add the fields to `evidence.ts`**

Above `ZEvidence`:

```ts
/**
 * One stack entry's version, as observed rather than claimed.
 *
 * source says where it was read: a lockfile, a manifest's declared range, a
 * mise pin, a CI workflow's action pin, a component's own plugin.json or
 * package.json, or a probe of the machine. basis says when: at the commit
 * the session ran on, at HEAD because no earlier commit existed, or on the
 * machine when the transform ran. A probe is always "machine", which is why
 * the jury is shown it.
 *
 * flavor is for the tools whose BSD and GNU builds disagree (awk, grep,
 * sed). A version number alone doesn't say which one a lesson was seen on.
 */
export const ZObservation = z.strictObject({
	version: z.string().min(1),
	source: z.enum([
		"lockfile",
		"manifest",
		"mise",
		"workflow",
		"component",
		"probe",
	]),
	basis: z.enum(["session_commit", "head", "machine"]),
	flavor: z.enum(["gnu", "bsd"]).optional(),
});
export type TObservation = z.infer<typeof ZObservation>;
```

Add two fields to `ZEvidence` after `resolution`:

```ts
	observed_on: z
		.record(z.string().min(1), ZObservation)
		.optional()
		.describe("Keyed by stack entry. Every key must be in applies_to.stack."),
	unresolved: z
		.array(z.string().min(1))
		.optional()
		.describe("Stack entries no source could version."),
```

In `index.ts`, export `ZObservation` and `type TObservation` next to
`ZEvidence`.

- [ ] **Step 5: Add the three rules to `rules.ts`**

After the `if (scope.kind === "versioned") { ... }` block, and before
`return violations;`:

```ts
	// Delegated from ZEvidence in evidence.ts, for the same cross-field reason
	// as versions_key_in_stack: an observation of something the lesson does not
	// name says nothing about when the lesson holds.
	const declaredStack = new Set(stack);
	const observed = Object.keys(lesson.evidence.observed_on ?? {});
	const unresolved = lesson.evidence.unresolved ?? [];

	for (const name of observed) {
		if (!declaredStack.has(name)) {
			violations.push({
				rule: "observed_key_in_stack",
				message: `evidence.observed_on has a key "${name}" that is not in applies_to.stack`,
			});
		}
	}

	for (const name of unresolved) {
		if (!declaredStack.has(name)) {
			violations.push({
				rule: "unresolved_in_stack",
				message: `evidence.unresolved names "${name}", which is not in applies_to.stack`,
			});
		}
		if (observed.includes(name)) {
			violations.push({
				rule: "observed_and_unresolved_disjoint",
				message: `"${name}" is both observed and unresolved`,
			});
		}
	}
```

- [ ] **Step 6: Rebuild and run both suites**

Run:

```bash
pnpm --filter @onlooker-community/lesson-contract build
pnpm --filter @onlooker-community/lesson-contract test
pnpm --filter @onlooker/api test -- src/lessons/rules.test.ts
```

Expected: PASS.

- [ ] **Step 7: Commit**

`/git-workflow:commit`:

```
feat(lesson-contract): record the versions a lesson was observed on :mag:

A lesson that says which versions it was seen on needs no argument that
it holds on every version. Each observation says where it was read and
when, so a probe of today's machine is never mistaken for a lockfile at
the session's commit. Ingest refuses an observation of a tool the lesson
does not name.

Refs ONL-313
```

---

### Task 3: The playbook, the version bump, and the PR

**Files:**
- Modify: `apps/cli/src/__tests__/playbook.test.ts`
- Modify: `packages/lesson-contract/package.json` (`version`)

**Interfaces:**
- Consumes: `TAppliesTo` and `TScope` from Task 1, `TObservation` from Task 2.

- [ ] **Step 1: Write the failing playbook test**

`judge` needs no code change: an empty stack has nothing missing, and
`no_stack` isn't `versioned`, so it reaches gate 3. This test pins that down.
Add it to the `describe("judge — applicability", ...)` block:

```ts
	// A lesson naming no tool depends on nothing installed, so nothing here
	// can exclude it.
	it("applies a no_stack lesson whatever is installed", () => {
		const v = judge(
			lesson({
				applies_to: {
					...base.applies_to,
					stack: [],
					scope: { kind: "no_stack" },
				},
			} as Partial<TLesson>),
			ctx({}),
		);
		expect(v.kind).toBe("applies");
	});
```

- [ ] **Step 2: Run it**

Run: `pnpm --filter @onlooker/cli test -- src/__tests__/playbook.test.ts`
Expected: PASS. This is a characterization test, so it passes first time.
Then break it on purpose: change `"applies"` to `"excluded"`, confirm it
fails, and put it back.

- [ ] **Step 3: Bump the contract version**

In `packages/lesson-contract/package.json`, change `"version": "2.1.0"` to
`"version": "2.2.0"`.

- [ ] **Step 4: Run everything CI runs**

Run: `pnpm -r typecheck && pnpm -r test && pnpm -r lint`
Expected: PASS. If `apps/web` has a LessonDetail test asserting the scope
text, it passes unchanged, since the versioned and justification branches
are untouched.

- [ ] **Step 5: Commit**

`/git-workflow:commit`:

```
feat(lesson-contract): release the observed-versions contract as 2.2.0 :package:

The schema changed, and deploy.yml publishes only on a version bump. The
playbook test pins down that a lesson naming no tool applies wherever it
is read.

Refs ONL-313
```

- [ ] **Step 6: Open the PR**

`/git-workflow:pr`. Title: `feat(lesson-contract): record observed versions and allow no_stack`.
The body says the change is additive and names the ecosystem PR (Part B)
that consumes it.

After the merge, check that `@onlooker-community/lesson-contract@2.2.0` is
on npm (`npm view @onlooker-community/lesson-contract version`) and that
ONL-313 is still open, since Part B is still to come.

---

## Part B: Observe (ecosystem repo)

All paths in Part B are relative to the ecosystem checkout. Part B doesn't
depend on Part A's release: Observe's output is plain JSON that nothing
validates yet.

### Task 4: Manifests and own components at the session's commit

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-lesson-observe.mjs`
- Create: `plugins/librarian/scripts/lib/librarian-lesson-observe.sh`
- Create: `test/bats/librarian-lesson-observe.bats`

**Interfaces:**
- Produces: `librarian_lesson_observe <project_key> <observed_at> <stack_json>`
  (bash). On success it prints one line of JSON,
  `{"observed_on": {<entry>: {version, source, basis[, flavor]}}, "unresolved": [<entry>...]}`,
  with every stack entry in exactly one of the two. It prints nothing on a
  missing argument, or when `node` is absent. It always exits 0.
- Produces: `export function observe({onlookerDir, projectKey, observedAt, stack, probe = true})`
  in the `.mjs`, returning the same object. Task 6's measurement imports it.

- [ ] **Step 1: Write the test file with the manifest tests**

```bash
#!/usr/bin/env bats
# librarian_lesson_observe: a stack entry's version, read from the project at
# the session's commit, from a component's home repo, or from a probe of the
# machine. No model call, and nothing written.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-observe.sh"

	KEY="aaaaaaaaaaaa"
	REPO="${BATS_TEST_TMPDIR}/project"
	_init_repo "$REPO"
	_register "$KEY" "$REPO"

	# Two commits: the session ran between them, so the first is the one
	# that counts and the second must be ignored.
	OLD=$(relative_iso_days_ago 10)
	SESSION=$(relative_iso_days_ago 5)
	NEW=$(relative_iso_days_ago 2)

	_write "$REPO" package-lock.json '{"packages":{"":{},"node_modules/vite":{"version":"5.4.21"},"node_modules/@cloudflare/vite-plugin":{"version":"1.42.0"}}}'
	_write "$REPO" package.json '{"name":"fixture","dependencies":{"react":"^18.2.0"}}'
	_write "$REPO" mise.toml $'[tools]\nbats = "1.12.0"\n"aqua:BurntSushi/ripgrep" = "15.1.0"\n'
	_write "$REPO" .github/workflows/release.yml $'jobs:\n  r:\n    steps:\n      - uses: googleapis/release-please-action@v4\n'
	_write "$REPO" plugins/fixture-plugin/.claude-plugin/plugin.json '{"name":"fixture-plugin","version":"0.3.1"}'
	_commit "$REPO" "$OLD"

	_write "$REPO" package-lock.json '{"packages":{"":{},"node_modules/vite":{"version":"6.0.0"}}}'
	_commit "$REPO" "$NEW"
}

_init_repo() {
	mkdir -p "$1"
	git -C "$1" init -q
	git -C "$1" config user.email t@example.com
	git -C "$1" config user.name Test
}

_register() {
	mkdir -p "${ONLOOKER_DIR}/librarian/$1"
	jq -n --arg k "$1" --arg r "$2" '{project_key: $k, repo_root: $r}' \
		> "${ONLOOKER_DIR}/librarian/$1/manifest.json"
}

_write() {
	mkdir -p "$(dirname "$1/$2")"
	printf '%s' "$3" > "$1/$2"
}

_commit() {
	git -C "$1" add -A
	GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git -C "$1" commit -q -m c
}

_observe() {
	librarian_lesson_observe "$KEY" "$SESSION" "$1"
}

@test "a lockfile version is read at the session's commit, not HEAD" {
	run _observe '["vite"]'
	[ "$status" -eq 0 ] || return 1
	printf '%s' "$output" | jq -e '.observed_on.vite == {version: "5.4.21", source: "lockfile", basis: "session_commit"} and .unresolved == []' >/dev/null
}

@test "a scoped package name is matched as written" {
	run _observe '["@cloudflare/vite-plugin"]'
	printf '%s' "$output" | jq -e '.observed_on["@cloudflare/vite-plugin"].version == "1.42.0"' >/dev/null
}

@test "names are matched without case or a .js suffix" {
	run _observe '["Vite.js"]'
	printf '%s' "$output" | jq -e '.observed_on["Vite.js"].version == "5.4.21"' >/dev/null
}

@test "a session before the first commit falls back to HEAD and says so" {
	run librarian_lesson_observe "$KEY" "$(relative_iso_days_ago 30)" '["vite"]'
	printf '%s' "$output" | jq -e '.observed_on.vite == {version: "6.0.0", source: "lockfile", basis: "head"}' >/dev/null
}

@test "a mise pin is read, including a backend-prefixed tool" {
	run _observe '["bats", "ripgrep"]'
	printf '%s' "$output" | jq -e '.observed_on.bats == {version: "1.12.0", source: "mise", basis: "session_commit"} and .observed_on.ripgrep.version == "15.1.0"' >/dev/null
}

@test "a workflow action pin versions the action, without its -action suffix" {
	run _observe '["release-please"]'
	printf '%s' "$output" | jq -e '.observed_on["release-please"] == {version: "4", source: "workflow", basis: "session_commit"}' >/dev/null
}

@test "the project's own plugin is a component" {
	run _observe '["fixture-plugin"]'
	printf '%s' "$output" | jq -e '.observed_on["fixture-plugin"] == {version: "0.3.1", source: "component", basis: "session_commit"}' >/dev/null
}

@test "a dependency with no lockfile entry keeps its declared range" {
	run _observe '["react"]'
	printf '%s' "$output" | jq -e '.observed_on.react == {version: "^18.2.0", source: "manifest", basis: "session_commit"}' >/dev/null
}

@test "a component from another registered repo is read at its own commit" {
	OTHER="${BATS_TEST_TMPDIR}/other"
	_init_repo "$OTHER"
	_register "bbbbbbbbbbbb" "$OTHER"
	_write "$OTHER" plugins/tribunal/.claude-plugin/plugin.json '{"name":"tribunal","version":"1.2.3"}'
	_commit "$OTHER" "$OLD"
	_write "$OTHER" plugins/tribunal/.claude-plugin/plugin.json '{"name":"tribunal","version":"2.0.0"}'
	_commit "$OTHER" "$NEW"

	run _observe '["tribunal"]'
	printf '%s' "$output" | jq -e '.observed_on.tribunal == {version: "1.2.3", source: "component", basis: "session_commit"}' >/dev/null
}

@test "a resolved gem is read from Gemfile.lock, not its dependency constraints" {
	_write "$REPO" Gemfile.lock $'GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.1.3)\n      rack (>= 2.2.4)\n    rack (3.0.9)\n'
	_commit "$REPO" "$(relative_iso_days_ago 6)"
	run _observe '["rails", "rack"]'
	printf '%s' "$output" | jq -e '.observed_on.rails.version == "7.1.3" and .observed_on.rack.version == "3.0.9"' >/dev/null
}

@test "a Python package is read from uv.lock" {
	_write "$REPO" uv.lock $'version = 1\n\n[[package]]\nname = "httpx"\nversion = "0.27.0"\nsource = { registry = "https://pypi.org/simple" }\n'
	_commit "$REPO" "$(relative_iso_days_ago 6)"
	run _observe '["httpx"]'
	printf '%s' "$output" | jq -e '.observed_on.httpx == {version: "0.27.0", source: "lockfile", basis: "session_commit"}' >/dev/null
}

@test "an entry no source knows is unresolved" {
	run _observe '["vite", "Sentry"]'
	printf '%s' "$output" | jq -e '(.observed_on | keys) == ["vite"] and .unresolved == ["Sentry"]' >/dev/null
}

@test "an unregistered project leaves every entry unresolved" {
	run librarian_lesson_observe "cccccccccccc" "$SESSION" '["vite"]'
	[ "$status" -eq 0 ] || return 1
	printf '%s' "$output" | jq -e '.observed_on == {} and .unresolved == ["vite"]' >/dev/null
}

@test "a working-tree edit is never read" {
	_write "$REPO" package-lock.json '{"packages":{"node_modules/vite":{"version":"9.9.9"}}}'
	run _observe '["vite"]'
	printf '%s' "$output" | jq -e '.observed_on.vite.version == "5.4.21"' >/dev/null
}

@test "a missing argument prints nothing" {
	run librarian_lesson_observe "$KEY" "" '["vite"]'
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "nothing is written to the librarian store" {
	before=$(find "${ONLOOKER_DIR}" -type f | sort)
	run _observe '["vite", "Sentry"]'
	[ "$(find "${ONLOOKER_DIR}" -type f | sort)" = "$before" ]
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-observe.bats`
Expected: FAIL, because `librarian-lesson-observe.sh` doesn't exist.

- [ ] **Step 3: Write the bash wrapper**

`plugins/librarian/scripts/lib/librarian-lesson-observe.sh`:

```bash
#!/usr/bin/env bash
# librarian-lesson-observe.sh: the versions a lesson's stack entries were
# observed on, read from the project rather than claimed by a model.
#
# The work is in librarian-lesson-observe.mjs, beside this file. Manifest
# parsing is JSON, YAML and TOML, which is node's job, not jq's. The path is
# resolved from this file, never from a caller's $PLUGIN_ROOT, so a sub-shell
# that loses PLUGIN_ROOT still finds it.
#
# Fail-soft: on a missing argument, no node, or any error, it prints nothing
# and the caller treats every entry as unresolved.

_LIBRARIAN_LESSON_OBSERVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Usage: librarian_lesson_observe <project_key> <observed_at> <stack_json>
librarian_lesson_observe() {
	local key="${1:-}" observed_at="${2:-}" stack="${3:-}"
	[[ -z "$key" || -z "$observed_at" || -z "$stack" ]] && return 0
	command -v node >/dev/null 2>&1 || return 0
	node "${_LIBRARIAN_LESSON_OBSERVE_DIR}/librarian-lesson-observe.mjs" \
		"${ONLOOKER_DIR:-$HOME/.onlooker}" "$key" "$observed_at" "$stack" 2>/dev/null || true
}
```

- [ ] **Step 4: Write the resolver, without the probe**

`plugins/librarian/scripts/lib/librarian-lesson-observe.mjs`:

```js
#!/usr/bin/env node
// The versions a lesson's stack entries were observed on. See
// librarian-lesson-observe.sh for the contract. Reads git objects only, so a
// working-tree edit made after the session is never mistaken for what the
// session ran on.
//
// Usage: node librarian-lesson-observe.mjs <onlooker_dir> <project_key> <observed_at> <stack_json>

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const GIT_TIMEOUT_MS = 5000;

// Lowercase, then drop a trailing ".js" or "js": "Vite.js" and "vite" are
// the same entry, as are "Next.js" and "next".
export const normalize = (name) =>
	name.toLowerCase().replace(/\.?js$/, "") || name.toLowerCase();

const git = (repo, args) => {
	try {
		return execFileSync("git", ["-C", repo, ...args], {
			encoding: "utf8",
			stdio: ["ignore", "pipe", "ignore"],
			timeout: GIT_TIMEOUT_MS,
		});
	} catch {
		return null;
	}
};

const parseJson = (text) => {
	try {
		return JSON.parse(text);
	} catch {
		return null;
	}
};

// project_key -> repo_root, from each librarian store's manifest.json.
export function registeredRepos(onlookerDir) {
	const repos = new Map();
	const root = path.join(onlookerDir, "librarian");
	let keys = [];
	try {
		keys = readdirSync(root);
	} catch {
		return repos;
	}
	for (const key of keys) {
		let manifest = null;
		try {
			manifest = parseJson(readFileSync(path.join(root, key, "manifest.json"), "utf8"));
		} catch {}
		if (manifest?.repo_root) repos.set(key, manifest.repo_root);
	}
	return repos;
}

// The last commit at or before the session, or HEAD when there is none.
export function commitAt(repo, observedAt) {
	const sha = git(repo, ["rev-list", "-1", `--before=${observedAt}`, "HEAD"])?.trim();
	if (sha) return { sha, basis: "session_commit" };
	const head = git(repo, ["rev-parse", "HEAD"])?.trim();
	return head ? { sha: head, basis: "head" } : null;
}

// A later source never replaces an exact one with a declared range.
const RANK = { manifest: 1, lockfile: 2, mise: 2, workflow: 2, component: 2 };

function miseTools(text) {
	const tools = {};
	let inTools = false;
	for (const line of text.split("\n")) {
		if (/^\s*\[/.test(line)) {
			inTools = /^\s*\[tools\]\s*$/.test(line);
			continue;
		}
		const m = inTools && line.match(/^\s*"?([^"=\s]+)"?\s*=\s*(.+)$/);
		if (!m) continue;
		// "aqua:BurntSushi/ripgrep" -> "ripgrep"
		const name = m[1].split(/[:/]/).pop();
		const version = m[2].replace(/["[\]]/g, "").split(",")[0].trim();
		if (version) tools[name] = version;
	}
	return tools;
}

const cache = new Map();

// normalized name -> {version, source}, from the manifests at one commit.
// componentsOnly restricts it to what a repo says about itself, which is all
// another project's repo is consulted for.
export function indexAt(repo, sha, { componentsOnly = false } = {}) {
	const cacheKey = `${repo}\0${sha}\0${componentsOnly}`;
	if (cache.has(cacheKey)) return cache.get(cacheKey);

	const index = new Map();
	const put = (name, version, source) => {
		if (!name || !version) return;
		const key = normalize(name);
		const prev = index.get(key);
		if (!prev || RANK[source] > RANK[prev.source]) index.set(key, { version, source });
	};
	const show = (p) => git(repo, ["show", `${sha}:${p}`]);

	const files = (git(repo, ["ls-tree", "-r", "--name-only", sha]) ?? "")
		.split("\n")
		.filter((p) => p && !p.split("/").includes("node_modules") && p.split("/").length <= 6);

	for (const p of files) {
		const base = path.posix.basename(p);
		if (base === "plugin.json" && p.includes(".claude-plugin/")) {
			const j = parseJson(show(p));
			put(j?.name, j?.version, "component");
		} else if (base === "package.json") {
			const j = parseJson(show(p));
			put(j?.name, j?.version, "component");
			if (componentsOnly) continue;
			for (const field of ["dependencies", "devDependencies", "peerDependencies"]) {
				for (const [n, v] of Object.entries(j?.[field] ?? {})) put(n, v, "manifest");
			}
		} else if (componentsOnly) {
			continue;
		} else if (base === "package-lock.json") {
			const j = parseJson(show(p));
			for (const [k, v] of Object.entries(j?.packages ?? {})) {
				if (k.startsWith("node_modules/")) put(k.replace(/^.*node_modules\//, ""), v?.version, "lockfile");
			}
		} else if (base === "pnpm-lock.yaml") {
			for (const m of (show(p) ?? "").matchAll(/^\s{2}'?\/?((?:@[^/@\s]+\/)?[^@\s'/]+)@(\d[^(:'\s]*)/gm)) {
				put(m[1], m[2], "lockfile");
			}
		} else if (base === "uv.lock") {
			for (const m of (show(p) ?? "").matchAll(/^name = "([^"]+)"\nversion = "([^"]+)"/gm)) {
				put(m[1], m[2], "lockfile");
			}
		} else if (base === "Gemfile.lock") {
			// Only the four-space lines under a specs: block are resolved gems;
			// six-space lines are their dependency constraints.
			for (const m of (show(p) ?? "").matchAll(/^ {4}([A-Za-z0-9_.-]+) \(([^)]+)\)$/gm)) {
				put(m[1], m[2], "lockfile");
			}
		} else if (base === "mise.toml" || base === ".mise.toml") {
			for (const [n, v] of Object.entries(miseTools(show(p) ?? ""))) put(n, v, "mise");
		} else if (/^\.github\/workflows\/[^/]+\.ya?ml$/.test(p)) {
			for (const m of (show(p) ?? "").matchAll(/uses:\s*([^@\s]+)@([^\s#]+)/g)) {
				const action = m[1].split("/")[1] ?? m[1];
				put(action.replace(/-action$/, ""), m[2].replace(/^v/, ""), "workflow");
			}
		}
	}

	cache.set(cacheKey, index);
	return index;
}

export function observe({ onlookerDir, projectKey, observedAt, stack, probe = true }) {
	const observed_on = {};
	const unresolved = [];
	const repos = registeredRepos(onlookerDir);

	const own = repos.get(projectKey);
	const ownAt = own ? commitAt(own, observedAt) : null;
	const ownIndex = ownAt ? indexAt(own, ownAt.sha) : new Map();

	const others = [];
	for (const [key, repo] of repos) {
		if (key === projectKey || repo === own) continue;
		const at = commitAt(repo, observedAt);
		if (at) others.push({ index: indexAt(repo, at.sha, { componentsOnly: true }), basis: at.basis });
	}

	for (const entry of stack) {
		const key = normalize(entry);
		const hit = ownIndex.get(key);
		if (hit) {
			observed_on[entry] = { version: hit.version, source: hit.source, basis: ownAt.basis };
			continue;
		}
		const elsewhere = others.find((o) => o.index.get(key));
		if (elsewhere) {
			const c = elsewhere.index.get(key);
			observed_on[entry] = { version: c.version, source: "component", basis: elsewhere.basis };
			continue;
		}
		const probed = probe ? probeTool(key) : null;
		if (probed) {
			observed_on[entry] = probed;
			continue;
		}
		unresolved.push(entry);
	}

	return { observed_on, unresolved };
}

// Filled in by Task 5.
function probeTool(_key) {
	return null;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
	const [onlookerDir, projectKey, observedAt, stackJson] = process.argv.slice(2);
	const stack = parseJson(stackJson);
	if (onlookerDir && projectKey && observedAt && Array.isArray(stack)) {
		process.stdout.write(`${JSON.stringify(observe({ onlookerDir, projectKey, observedAt, stack }))}\n`);
	}
}
```

The `probeTool` stub that returns `null` is replaced in Task 5. It is here so
`observe`'s control flow is complete and testable now.

- [ ] **Step 5: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-observe.bats`
Expected: PASS. Then break one on purpose: change `5.4.21` to `5.4.22` in the
first test, confirm it fails, and put it back.

- [ ] **Step 6: Lint**

Run:

```bash
shellcheck plugins/librarian/scripts/lib/librarian-lesson-observe.sh test/bats/librarian-lesson-observe.bats
npx --no-install biome check plugins/librarian/scripts/lib/librarian-lesson-observe.mjs
npm run -s lint:bats-assertions
```

If a hook blocks `npx`, run `./node_modules/.bin/biome check <file>` instead.
Expected: clean. Fix a warning rather than disabling it.

- [ ] **Step 7: Commit**

`/git-workflow:commit`:

```
feat(librarian): read a lesson's versions from the project :mag:

A lesson's versions come from the lockfiles, mise pins, workflow pins and
component manifests at the commit the session ran on, not from a model's
guess at a range. Nothing calls it yet; the transform will.

Refs ONL-313
```

---

### Task 5: The probe allowlist

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-observe.mjs` (replace `probeTool`)
- Modify: `test/bats/librarian-lesson-observe.bats`

**Interfaces:**
- Consumes: `observe()` and the bash wrapper from Task 4.
- Produces: `probeTool(normalizedName)` returns `{version, source: "probe",
  basis: "machine"[, flavor]}` or `null`.

- [ ] **Step 1: Write the failing probe tests**

Append to the bats file. The stubs go in a directory put on `PATH` only for
the call, so the test's own `jq` and `git` stay real:

```bash
_stub() {
	mkdir -p "${BATS_TEST_TMPDIR}/stub"
	printf '#!/usr/bin/env bash\n%s\n' "$2" > "${BATS_TEST_TMPDIR}/stub/$1"
	chmod +x "${BATS_TEST_TMPDIR}/stub/$1"
}

_observe_stubbed() {
	PATH="${BATS_TEST_TMPDIR}/stub:${PATH}" librarian_lesson_observe "$KEY" "$SESSION" "$1"
}

@test "a tool on the allowlist is probed when no manifest has it" {
	_stub sqlite3 'echo "3.43.2 2023-10-10 13:08:14 abc"'
	run _observe_stubbed '["sqlite3"]'
	printf '%s' "$output" | jq -e '.observed_on.sqlite3 == {version: "3.43.2", source: "probe", basis: "machine"}' >/dev/null
}

@test "sqlite is probed under either name" {
	_stub sqlite3 'echo "3.43.2 2023-10-10"'
	run _observe_stubbed '["SQLite"]'
	printf '%s' "$output" | jq -e '.observed_on.SQLite.version == "3.43.2"' >/dev/null
}

@test "a GNU awk is recorded with its flavor" {
	_stub awk 'echo "GNU Awk 5.3.0, API 4.0"'
	run _observe_stubbed '["awk"]'
	printf '%s' "$output" | jq -e '.observed_on.awk == {version: "5.3.0", source: "probe", basis: "machine", flavor: "gnu"}' >/dev/null
}

@test "a BSD awk's date-shaped version is kept" {
	_stub awk 'echo "awk version 20200816"'
	run _observe_stubbed '["awk"]'
	printf '%s' "$output" | jq -e '.observed_on.awk == {version: "20200816", source: "probe", basis: "machine", flavor: "bsd"}' >/dev/null
}

@test "a probe that fails leaves the entry unresolved" {
	_stub npm 'exit 1'
	run _observe_stubbed '["npm"]'
	printf '%s' "$output" | jq -e '.unresolved == ["npm"]' >/dev/null
}

@test "a tool off the allowlist is never run" {
	_stub vitest 'touch "'"${BATS_TEST_TMPDIR}"'/ran"; echo "vitest/9.0.0"'
	run _observe_stubbed '["vitest"]'
	[ ! -e "${BATS_TEST_TMPDIR}/ran" ] || return 1
	printf '%s' "$output" | jq -e '.unresolved == ["vitest"]' >/dev/null
}

@test "a manifest pin wins over the probe" {
	_stub bats 'echo "Bats 9.9.9"'
	run _observe_stubbed '["bats"]'
	printf '%s' "$output" | jq -e '.observed_on.bats.source == "mise"' >/dev/null
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-observe.bats`
Expected: the first four probe tests FAIL, since `probeTool` returns `null`.
The last three pass already, and that's expected: they guard behavior the
probe must not break.

- [ ] **Step 3: Replace `probeTool`**

Replace the stub at the end of `librarian-lesson-observe.mjs` with:

```js
const PROBE_TIMEOUT_MS = 2000;

// Only these are ever run. Each is the tool's own version flag, so probing
// one can't do anything else. The machine is read when the transform runs,
// not when the session did, which is why every probe says basis "machine".
const PROBES = {
	bash: ["bash", ["--version"]],
	git: ["git", ["--version"]],
	node: ["node", ["--version"]],
	npm: ["npm", ["--version"]],
	jq: ["jq", ["--version"]],
	sqlite: ["sqlite3", ["--version"]],
	sqlite3: ["sqlite3", ["--version"]],
	awk: ["awk", ["--version"]],
	grep: ["grep", ["--version"]],
	sed: ["sed", ["--version"]],
	macos: ["uname", ["-r"]],
	darwin: ["uname", ["-r"]],
	linux: ["uname", ["-r"]],
};

// awk, grep and sed differ between BSD and GNU builds in ways a lesson can
// depend on, and a version number alone doesn't say which.
const FLAVORED = new Set(["awk", "grep", "sed"]);

function probeTool(key) {
	const probe = PROBES[key];
	if (!probe) return null;
	let out;
	try {
		out = execFileSync(probe[0], probe[1], {
			encoding: "utf8",
			stdio: ["ignore", "pipe", "ignore"],
			timeout: PROBE_TIMEOUT_MS,
		});
	} catch {
		return null;
	}
	const line = out.split("\n").find((l) => l.trim()) ?? "";
	const version = line.match(/\d+\.\d+(?:\.\d+)?|\d{8}/)?.[0];
	if (!version) return null;
	const result = { version, source: "probe", basis: "machine" };
	if (FLAVORED.has(key)) result.flavor = /\bGNU\b/.test(line) ? "gnu" : "bsd";
	return result;
}
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-observe.bats`
Expected: PASS, all 23 tests.

- [ ] **Step 5: Lint and commit**

Run the Task 4 Step 6 lint commands again, then `/git-workflow:commit`:

```
feat(librarian): probe the system tools no manifest pins :wrench:

bash was the most common stack entry no manifest could version, and it is
the one where versions matter most. Each probe is a fixed version flag
from an allowlist, and BSD and GNU builds are told apart.

Refs ONL-313
```

---

### Task 6: Measure resolution against the store, and the PR

**Files:**
- Create: `plugins/librarian/docs/measurements/2026-11-26-observe-resolution/run.mjs`
- Create: `plugins/librarian/docs/measurements/2026-11-26-observe-resolution/concepts.txt`
- Create: `plugins/librarian/docs/measurements/2026-11-26-observe-resolution/results.jsonl` (output)
- Create: `plugins/librarian/docs/measurements/2026-11-26-observe-resolution/README.md`

**Interfaces:**
- Consumes: `observe()` from Task 4, including the probe from Task 5.

This reads the real lesson store and the real repos, writes nothing to
either, and makes no model call. It costs nothing, so it needs no go-ahead.

- [ ] **Step 1: Write `concepts.txt`**

These are the stack entries from the 2026-11-26 baseline that name a concept,
not something with a version. One per line, compared case-insensitively.
Rollout step 3 moves them to `topics`:

```text
CSS
SQL
testing
api
rate-limiting
web
database
db
HTTP routing
API design
database access control
database-schema
database-migrations
authentication
hooks
dispatch
shell
```

- [ ] **Step 2: Write `run.mjs`**

```js
#!/usr/bin/env node
// Rollout step 2's measurement: how often Observe versions a stored
// candidate's stack. Reads the lesson store and the repos; writes only
// results.jsonl beside this file. No model call.
//
// Usage: node run.mjs [onlooker_dir]   (default: ~/.onlooker)

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { observe } from "../../../scripts/lib/librarian-lesson-observe.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const onlookerDir = process.argv[2] ?? path.join(os.homedir(), ".onlooker");
const store = path.join(onlookerDir, "librarian");
const concepts = new Set(
	readFileSync(path.join(here, "concepts.txt"), "utf8")
		.split("\n").map((l) => l.trim().toLowerCase()).filter(Boolean),
);

const rows = [];
for (const key of readdirSync(store)) {
	let files = [];
	try {
		files = readdirSync(path.join(store, key, "lessons/proposals")).filter((f) => f.endsWith(".json"));
	} catch {
		continue;
	}
	for (const f of files) {
		const p = JSON.parse(readFileSync(path.join(store, key, "lessons/proposals", f), "utf8"));
		const c = p.candidate ?? {};
		const stack = c.applies_to?.stack ?? [];
		const observedAt = c.evidence?.observed_at;
		const projectKey = c.evidence?.project_key ?? key;
		const tools = stack.filter((s) => !concepts.has(s.toLowerCase()));
		const result = observedAt
			? observe({ onlookerDir, projectKey, observedAt, stack: tools })
			: { observed_on: {}, unresolved: tools };
		rows.push({
			id: p.id, key: projectKey, stack, concepts: stack.filter((s) => concepts.has(s.toLowerCase())),
			observed_on: result.observed_on, unresolved: result.unresolved,
		});
	}
}
writeFileSync(path.join(here, "results.jsonl"), rows.map((r) => JSON.stringify(r)).join("\n") + "\n");

const tally = (xs) => xs.reduce((m, x) => ((m[x] = (m[x] ?? 0) + 1), m), {});
const outcome = (r) =>
	r.stack.length === 0 ? "empty_stack"
	: r.unresolved.length === 0 && Object.keys(r.observed_on).length === 0 ? "concepts_only"
	: r.unresolved.length === 0 ? "fully_resolved"
	: Object.keys(r.observed_on).length > 0 ? "partly" : "none";
const entries = rows.flatMap((r) => Object.values(r.observed_on).map((o) => `${o.source}/${o.basis}`));

console.log(JSON.stringify({
	candidates: rows.length,
	outcomes: tally(rows.map(outcome)),
	observed_by_source: tally(entries),
	top_unresolved: Object.entries(tally(rows.flatMap((r) => r.unresolved)))
		.sort((a, b) => b[1] - a[1]).slice(0, 25),
}, null, 2));
```

- [ ] **Step 3: Run it**

Run: `node plugins/librarian/docs/measurements/2026-11-26-observe-resolution/run.mjs`
Expected: a summary over about 215 candidates. `fully_resolved` plus
`concepts_only` is the number to compare against the baseline's 83 of 215
(39%). The spec's estimate is 60–70%.

- [ ] **Step 4: Read `top_unresolved` before writing anything up**

For each entry left in `top_unresolved`, decide which group it falls in:
- a concept → add it to `concepts.txt`, note it in the README, and run again;
- a hosted service (Sentry, Cloudflare Workers, D1) → leave it, since
  that's open question 2;
- a tool Observe should have found → that's a resolver bug. Stop, and fix
  it with a failing bats test first.

- [ ] **Step 5: Check results.jsonl for client repos before committing**

`results.jsonl` holds stack entries, not claims, but it's committed to a
public repo. List the project keys in it and compare them to
`~/.onlooker/librarian/*/manifest.json` `remote_url`. Drop every row whose
remote is outside `github.com/meaganewaller/` and
`github.com/onlooker-community/`, and say in the README how many rows were
dropped and why, without naming the repos. The counts in the README still
cover every candidate.

- [ ] **Step 6: Write the README**

Follow the shape of `plugins/librarian/docs/measurements/2026-10-24-unattended-run/README.md`.
Sections:
- What was run: the date, the commit of the ecosystem checkout, and that the
  probe read this machine.
- The result against the 39% baseline. Report it twice: once with
  `concepts.txt` applied, and once without it (rerun with an empty file),
  so the topics split's share is visible on its own.
- Observed entries by source and basis.
- What's still unresolved, grouped into hosted services, concepts added
  during Step 4, and anything else.
- Caveats: a probe reads today's machine, not the session's. Component and
  manifest reads use `--before=<observed_at>` on the current HEAD's history,
  so a rebased branch can change the answer.
- What rollout step 3 should take from it. If the result is under 60%,
  say so plainly and say which group accounts for the gap.

- [ ] **Step 7: Commit the measurement**

`/git-workflow:commit` the four files:

```
docs(librarian): measure how often Observe versions a stack :bar_chart:

<n> of <m> stored candidates now resolve fully, against 83 of 215 when only
manifests at HEAD were read. This is the number rollout step 3 builds on.

Refs ONL-313
```

- [ ] **Step 8: Run the CI suite**

Run: `npm run test:ci`
Expected: PASS. `test:bus` has nothing new to triage, because Observe emits
nothing.

- [ ] **Step 9: Open the PR**

`/git-workflow:pr`. Title: `feat(librarian): read a lesson's versions from the project`.
The body gives the measured number, links the onlooker PR from Task 3, and
says nothing calls Observe yet. Only librarian's files change, so the squash
title releases librarian alone.

- [ ] **Step 10: After merge**

Check ONL-313's state in Linear, since auto-close is unreliable. It should
close once both PRs have merged. Close the matching bead to match.
