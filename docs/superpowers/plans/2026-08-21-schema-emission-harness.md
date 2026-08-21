# Schema Emission Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a payload that drifts from the schema fail CI, instead of being
silently dropped by an emitter whose rejection the hook swallows.

**Architecture:** The emitter appends one line per emission to a suite-durable
report directory when `ONLOOKER_TEST_REPORT_DIR` is set. Two gates then read
that report after the suite: Gate A fails on any rejected emission, Gate B
fails when a registered event type appears in neither list of a committed
manifest. Nothing changes in production, which never sets the variable.

**Tech Stack:** Node 22 ESM, `node:test`, bats, `@onlooker-community/schema`
(devDependency), npm scripts.

**Spec:** `docs/superpowers/specs/2026-08-21-schema-emission-harness-design.md`

## Global Constraints

- The emitter has **zero runtime dependencies** and **fails open** (ADR-005).
  Nothing in this plan may add an import that runs on the emit path, change an
  exit code, or make emission depend on the report succeeding.
- Report writes happen **only** when `ONLOOKER_TEST_REPORT_DIR` is set.
- The `validate` subcommand must **not** write a report line. Only `emit` and
  `emit-from-hook` do. A test that validates a fixture is not an emission, and
  counting it would give Gate B false coverage.
- Runtime artifacts go under `${ONLOOKER_DIR:-$HOME/.onlooker}`; the report
  directory is a **test** artifact and lives under `test/`, gitignored.
- American English in all comments, docs, and commit messages.
- Every commit goes through `/commit`. Never push to `main`; open a PR.
- Event types are `<plugin>.<noun>.<verb>`; ULIDs, not UUIDs, for IDs.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `scripts/lib/onlooker-event.mjs` (modify) | Add `recordEmission()`; call it from `emit` and `emit-from-hook` only |
| `test/node/emission-report.test.mjs` (create) | Proves the emitter records correctly and stays silent when unset |
| `scripts/lint/check-bus-coverage.mjs` (create) | The gate runner — Gate A in Task 2, Gate B added in Task 4 |
| `test/node/check-bus-coverage.test.mjs` (create) | Fixture-driven tests for the gate runner itself |
| `test/bus-coverage.json` (create) | The committed manifest: `expected` list + `excluded` map |
| `package.json` (modify) | Export the report dir; add `test:bus`; wire into `test:ci` |
| `.gitignore` (modify) | Ignore `test/tmp-emission-report/` |
| `docs/architecture.md`, `CLAUDE.md`, `.claude/skills/writing-tests/SKILL.md` (modify) | Document the gates |

---

## Task 1: Emitter records every emission when the report dir is set

**Files:**

- Modify: `scripts/lib/onlooker-event.mjs:7` (import), after `tryValidate`
  (~line 107), and both emit call sites (~line 512, ~line 540)
- Test: `test/node/emission-report.test.mjs`

**Interfaces:**

- Consumes: nothing from earlier tasks.
- Produces: a report file at `$ONLOOKER_TEST_REPORT_DIR/emissions.jsonl`. Each
  line is `{ event_type: string|null, validated: boolean, valid: boolean|null,
  errors?: object[] }`. `validated` is whether the schema package resolved;
  `valid` is `null` when it did not. Task 2 and Task 4 read this shape.

- [ ] **Step 1: Write the failing test**

Create `test/node/emission-report.test.mjs`:

```javascript
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const EMITTER = join(REPO_ROOT, 'scripts', 'lib', 'onlooker-event.mjs');

// session.start requires only working_directory and forbids extra properties.
// Verified against node_modules/@onlooker-community/schema/schemas/payload/session.json
const VALID = {
  plugin: 'onlooker',
  session_id: '01JZZZZZZZZZZZZZZZZZZZZZZZ',
  event_type: 'session.start',
  payload: { working_directory: '/tmp/x' },
};
const INVALID = { ...VALID, payload: { working_directory: 42 } };

function emit(params, { reportDir } = {}) {
  const env = {
    ...process.env,
    ONLOOKER_DIR: mkdtempSync(join(tmpdir(), 'emit-onlooker-')),
  };
  if (reportDir) env.ONLOOKER_TEST_REPORT_DIR = reportDir;
  else delete env.ONLOOKER_TEST_REPORT_DIR;
  return spawnSync('node', [EMITTER, 'emit'], {
    input: JSON.stringify(params),
    encoding: 'utf8',
    env,
  });
}

function readReport(dir) {
  const p = join(dir, 'emissions.jsonl');
  if (!existsSync(p)) return null;
  return readFileSync(p, 'utf8')
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

describe('emission report', () => {
  it('records a valid emission as validated and valid', () => {
    const dir = mkdtempSync(join(tmpdir(), 'emit-report-'));
    const r = emit(VALID, { reportDir: dir });
    assert.equal(r.status, 0, r.stderr);
    const lines = readReport(dir);
    assert.equal(lines.length, 1);
    assert.equal(lines[0].event_type, 'session.start');
    assert.equal(lines[0].validated, true);
    assert.equal(lines[0].valid, true);
  });

  it('records a rejected emission as invalid, with its errors', () => {
    const dir = mkdtempSync(join(tmpdir(), 'emit-report-'));
    const r = emit(INVALID, { reportDir: dir });
    assert.equal(r.status, 1);
    const lines = readReport(dir);
    assert.equal(lines.length, 1);
    assert.equal(lines[0].validated, true);
    assert.equal(lines[0].valid, false);
    assert.ok(Array.isArray(lines[0].errors) && lines[0].errors.length > 0);
  });

  it('writes nothing when the report dir is unset', () => {
    const dir = mkdtempSync(join(tmpdir(), 'emit-report-'));
    const r = emit(VALID);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(readReport(dir), null);
  });

  it('appends across emissions rather than truncating', () => {
    const dir = mkdtempSync(join(tmpdir(), 'emit-report-'));
    emit(VALID, { reportDir: dir });
    emit(VALID, { reportDir: dir });
    assert.equal(readReport(dir).length, 2);
  });

  it('does not record for the validate subcommand', () => {
    const dir = mkdtempSync(join(tmpdir(), 'emit-report-'));
    spawnSync('node', [EMITTER, 'validate'], {
      input: JSON.stringify({ nonsense: true }),
      encoding: 'utf8',
      env: { ...process.env, ONLOOKER_TEST_REPORT_DIR: dir },
    });
    assert.equal(readReport(dir), null);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test test/node/emission-report.test.mjs`
Expected: FAIL — the first two tests fail because `readReport` returns `null`
(no report file is written yet). The "writes nothing", "validate subcommand",
and append tests may pass vacuously; that is fine, the first two are the gate.

- [ ] **Step 3: Add `appendFileSync` to the fs import**

In `scripts/lib/onlooker-event.mjs`, replace line 7:

```javascript
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
```

with:

```javascript
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from 'node:fs';
```

- [ ] **Step 4: Add `recordEmission` immediately after `tryValidate`**

Insert after the closing brace of `tryValidate` (~line 107):

```javascript
/**
 * Test-only emission report.
 *
 * When ONLOOKER_TEST_REPORT_DIR is set, append one line per emission recording
 * the event type, whether validation actually ran, and whether it passed.
 *
 * This exists because both signals the emitter produces on rejection — a
 * non-zero exit and stderr — are destroyed by the hook's fail-soft exit 0,
 * which leaves a dropped event indistinguishable from one that never fired.
 * The report lives outside the per-test BATS_TEST_TMPDIR so the suite can gate
 * on it after the fact.
 *
 * Production never sets the variable, so nothing is written there and the
 * fail-open contract in ADR-005 is untouched. `validated` is recorded
 * separately from `valid` so a run where the schema package never resolved is
 * distinguishable from a run where everything passed — without it, a missing
 * node_modules would make the gate pass while checking nothing.
 */
function recordEmission(event, check) {
  const dir = process.env.ONLOOKER_TEST_REPORT_DIR;
  if (!dir) return;
  const record = {
    event_type: event?.event_type ?? null,
    validated: check.available === true,
    valid: check.available === true ? check.valid === true : null,
  };
  if (check.available && !check.valid) record.errors = check.errors;
  try {
    mkdirSync(dir, { recursive: true });
    appendFileSync(join(dir, 'emissions.jsonl'), `${JSON.stringify(record)}\n`);
  } catch {
    // A broken report must never break an emission.
  }
}
```

- [ ] **Step 5: Call it from both emit paths — and only those**

In the `emit-from-hook` block, after `const check = await tryValidate(mapped.event);`:

```javascript
    const check = await tryValidate(mapped.event);
    recordEmission(mapped.event, check);
```

In the `emit` block, after `const check = await tryValidate(event);`:

```javascript
    const check = await tryValidate(event);
    recordEmission(event, check);
```

Do **not** add a call in the `validate` block.

- [ ] **Step 6: Run the test to verify it passes**

Run: `node --test test/node/emission-report.test.mjs`
Expected: PASS, 5 tests.

- [ ] **Step 7: Confirm production behavior is unchanged**

Run: `npm run test:schema && npm run test:bats`
Expected: PASS. No test sets `ONLOOKER_TEST_REPORT_DIR` yet, so this proves the
change is inert when the variable is absent.

- [ ] **Step 8: Format and commit**

```bash
./node_modules/.bin/biome check --write scripts/lib/onlooker-event.mjs test/node/emission-report.test.mjs
git add scripts/lib/onlooker-event.mjs test/node/emission-report.test.mjs
```

Then run `/commit` with: emitter records each emission to a test-only report so
a rejection outlives the hook's fail-soft exit.

---

## Task 2: Gate A — fail on a rejected emission, or on validation never running

**Files:**

- Create: `scripts/lint/check-bus-coverage.mjs`
- Test: `test/node/check-bus-coverage.test.mjs`

**Interfaces:**

- Consumes: the report line shape from Task 1.
- Produces: a CLI `check-bus-coverage.mjs [--report <dir>]` exiting 0 on pass,
  1 on gate failure, 2 on bad arguments. Task 4 extends it with `--manifest`.

- [ ] **Step 1: Write the failing test**

Create `test/node/check-bus-coverage.test.mjs`:

```javascript
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const GATE = join(REPO_ROOT, 'scripts', 'lint', 'check-bus-coverage.mjs');

function reportDir(lines) {
  const dir = mkdtempSync(join(tmpdir(), 'bus-report-'));
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, 'emissions.jsonl'),
    lines.map((l) => JSON.stringify(l)).join('\n') + (lines.length ? '\n' : ''),
  );
  return dir;
}

function run(dir) {
  const r = spawnSync('node', [GATE, '--report', dir], { encoding: 'utf8' });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

const OK = { event_type: 'session.start', validated: true, valid: true };

describe('check-bus-coverage gate A', () => {
  it('passes when every emission validated', () => {
    const r = run(reportDir([OK, OK]));
    assert.equal(r.code, 0, r.stderr);
  });

  it('fails on a rejected emission and names the type', () => {
    const bad = {
      event_type: 'librarian.scan.complete',
      validated: true,
      valid: false,
      errors: [{ path: '/outcome', message: 'must be equal to one of the allowed values' }],
    };
    const r = run(reportDir([OK, bad]));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /librarian\.scan\.complete/);
  });

  it('fails when validation never ran, rather than passing vacuously', () => {
    const unvalidated = { event_type: 'session.start', validated: false, valid: null };
    const r = run(reportDir([unvalidated, unvalidated]));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /did not resolve|never validated|no emission was validated/i);
  });

  it('fails when the report is missing entirely', () => {
    const r = run(mkdtempSync(join(tmpdir(), 'bus-empty-')));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /no emissions recorded/i);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test test/node/check-bus-coverage.test.mjs`
Expected: FAIL — `Cannot find module .../check-bus-coverage.mjs`.

- [ ] **Step 3: Write the gate runner**

Create `scripts/lint/check-bus-coverage.mjs`:

```javascript
#!/usr/bin/env node
/**
 * Bus coverage gates.
 *
 * Gate A: no emission recorded during the suite was rejected by the schema.
 *
 * Reads the report the emitter writes when ONLOOKER_TEST_REPORT_DIR is set —
 * see recordEmission in scripts/lib/onlooker-event.mjs. A rejected emission is
 * invisible any other way: the emitter exits 1 and prints ajv errors, and the
 * hook's fail-soft exit 0 destroys both.
 *
 * Usage: check-bus-coverage.mjs [--report <dir>]
 */
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');

function parseArgs(argv) {
  const out = { report: join(REPO_ROOT, 'test', 'tmp-emission-report') };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--report') out.report = argv[++i];
    else if (a === '--help') {
      process.stderr.write('Usage: check-bus-coverage.mjs [--report <dir>]\n');
      process.exit(0);
    } else {
      process.stderr.write(`check-bus-coverage: unknown argument: ${a}\n`);
      process.exit(2);
    }
  }
  return out;
}

function loadReport(dir) {
  const p = join(dir, 'emissions.jsonl');
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8')
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function gateA(lines) {
  const failures = [];
  if (lines.length === 0) {
    failures.push(
      'no emissions recorded — run `npm run test:bats` with ONLOOKER_TEST_REPORT_DIR set',
    );
    return failures;
  }
  if (!lines.some((l) => l.validated === true)) {
    failures.push(
      'no emission was validated: @onlooker-community/schema did not resolve, so this gate ' +
        'checked nothing. Run `npm ci` and try again.',
    );
  }
  for (const l of lines.filter((x) => x.valid === false)) {
    failures.push(`rejected emission: ${l.event_type} — ${JSON.stringify(l.errors)}`);
  }
  return failures;
}

function main() {
  const args = parseArgs(process.argv);
  const lines = loadReport(args.report);
  const failures = gateA(lines);
  if (failures.length) {
    for (const f of failures) process.stderr.write(`check-bus-coverage: ${f}\n`);
    process.exit(1);
  }
  process.stdout.write(`check-bus-coverage: ok (${lines.length} emission(s))\n`);
}

const isMain = process.argv[1]?.endsWith('check-bus-coverage.mjs') ?? false;
if (isMain) main();
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test test/node/check-bus-coverage.test.mjs`
Expected: PASS, 4 tests.

- [ ] **Step 5: Format and commit**

```bash
./node_modules/.bin/biome check --write scripts/lint/check-bus-coverage.mjs test/node/check-bus-coverage.test.mjs
git add scripts/lint/check-bus-coverage.mjs test/node/check-bus-coverage.test.mjs
```

Then run `/commit` with: add Gate A, which fails on a rejected emission and on a
run where validation never happened at all.

---

## Task 3: Wire the report and the gate into the test scripts

**Files:**

- Modify: `package.json` (`test:bats`, `test:schema`, new `test:bus`, `test:ci`)
- Modify: `.gitignore`

**Interfaces:**

- Consumes: the gate CLI from Task 2.
- Produces: `test/tmp-emission-report/emissions.jsonl` populated by a real suite
  run. Task 4 reads it to bootstrap the manifest.

- [ ] **Step 1: Ignore the report directory**

Add to `.gitignore` beneath the existing `test/tmp-*` entries:

```gitignore
test/tmp-emission-report/
```

- [ ] **Step 2: Update the test scripts**

In `package.json`, replace `test:bats` and `test:schema` and add `test:bus`:

```json
    "test:bats": "rm -rf \"$PWD/test/tmp-emission-report\" && ONLOOKER_TEST_REPORT_DIR=\"$PWD/test/tmp-emission-report\" bats test/bats",
    "test:schema": "ONLOOKER_TEST_REPORT_DIR=\"$PWD/test/tmp-emission-report\" node --test test/node/*.test.mjs",
    "test:bus": "node scripts/lint/check-bus-coverage.mjs",
```

`$PWD` is absolute; a relative path would break because hooks run the emitter
from arbitrary working directories. `test:bats` clears the report so a stale
run cannot mask a regression; `test:schema` appends to it.

- [ ] **Step 3: Sequence the gate after both suites in `test:ci`**

Replace `test:ci` with:

```json
    "test:ci": "npm run test:shellcheck && npm run test:bats && npm run test:schema && npm run test:bus && npm run lint:check && npm run lint:manifests && npm run lint:references && npm run lint:lesson-schema",
```

`test:bus` runs after both suites so emissions from each are counted. It is
deliberately not folded into `test:schema`: a node test that skipped when the
report was absent would pass vacuously for anyone running `test:schema` alone,
which is the exact failure mode under repair.

- [ ] **Step 4: Verify the report is actually produced**

Run: `npm run test:bats && npm run test:schema`
Then: `wc -l test/tmp-emission-report/emissions.jsonl`
Expected: a non-zero line count. If the file is missing, the environment
variable is not reaching the emitter — check that `$PWD` expanded.

- [ ] **Step 5: Verify Gate A passes on the real suite**

Run: `npm run test:bus`
Expected: `check-bus-coverage: ok (N emission(s))`, exit 0.

If it reports a rejected emission, that is a real pre-existing bug — likely
`ecosystem-ci0`. Stop and report it rather than working around the gate.

- [ ] **Step 6: Break it on purpose**

Temporarily append a rejected line and confirm the gate goes red:

```bash
echo '{"event_type":"fake.bad.event","validated":true,"valid":false,"errors":[{"path":"/x","message":"nope"}]}' \
  >> test/tmp-emission-report/emissions.jsonl
npm run test:bus; echo "EXIT=$?"
```

Expected: EXIT=1, stderr naming `fake.bad.event`. Then re-run
`npm run test:bats && npm run test:schema` to restore a clean report.

- [ ] **Step 7: Commit**

```bash
git add package.json .gitignore
```

Then run `/commit` with: produce the emission report during the suite and gate
on it in CI.

---

## Task 4: The manifest and Gate B

**Files:**

- Create: `test/bus-coverage.json`
- Modify: `scripts/lint/check-bus-coverage.mjs`
- Modify: `test/node/check-bus-coverage.test.mjs`

**Interfaces:**

- Consumes: the populated report from Task 3; `ALL_EVENT_TYPES` from
  `@onlooker-community/schema` (125 entries at time of writing).
- Produces: `test/bus-coverage.json` with `{ expected: string[], excluded:
  Record<string, string> }`, and a `--manifest <path>` flag on the gate CLI.

- [ ] **Step 1: Generate the manifest skeleton from a real run**

With a clean report present from Task 3, run:

```bash
node -e "
import('@onlooker-community/schema').then(async (m) => {
  const { readFileSync } = await import('node:fs');
  const lines = readFileSync('test/tmp-emission-report/emissions.jsonl', 'utf8')
    .trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const seen = new Set(lines.filter((l) => l.valid === true).map((l) => l.event_type));
  const expected = m.ALL_EVENT_TYPES.filter((t) => seen.has(t)).sort();
  const excluded = {};
  for (const t of m.ALL_EVENT_TYPES.filter((t) => !seen.has(t)).sort()) excluded[t] = 'FILL IN';
  console.log(JSON.stringify({ expected, excluded }, null, 2));
});" > test/bus-coverage.json
```

- [ ] **Step 2: Replace every `FILL IN` with a real reason**

Open `test/bus-coverage.json` and write a specific reason for each exclusion.
Use these exact reasons for the known groups — they were established during
design:

| Prefix | Reason string |
|--------|---------------|
| `meridian.*`, `sentinel.*`, `oracle.*`, `relay.*` | `plugin lives in another repo` |
| `onlooker.session.summary` | `emitted by the agent, not this repo` |
| `curator.*` | `curator check deferred; see plugins/curator/README.md` |
| `compass.*` | `compass has no implementation yet; design phase` |
| anything else | one line saying which branch would emit it and why no test reaches that branch yet |

No reason may remain `FILL IN`; Step 5's test enforces that.

- [ ] **Step 3: Write the failing Gate B tests**

Append to `test/node/check-bus-coverage.test.mjs`:

```javascript
import { ALL_EVENT_TYPES } from '@onlooker-community/schema';

function manifestFile(manifest) {
  const dir = mkdtempSync(join(tmpdir(), 'bus-manifest-'));
  const p = join(dir, 'bus-coverage.json');
  writeFileSync(p, JSON.stringify(manifest, null, 2));
  return p;
}

function runWith(dir, manifestPath) {
  const r = spawnSync('node', [GATE, '--report', dir, '--manifest', manifestPath], {
    encoding: 'utf8',
  });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

// A manifest that accounts for all 125 types, expecting only session.start.
function fullManifest(expected = ['session.start']) {
  const excluded = {};
  for (const t of ALL_EVENT_TYPES) {
    if (!expected.includes(t)) excluded[t] = 'not emitted in tests';
  }
  return { expected, excluded };
}

describe('check-bus-coverage gate B', () => {
  it('passes when every expected type has a validated emission', () => {
    const r = runWith(reportDir([OK]), manifestFile(fullManifest()));
    assert.equal(r.code, 0, r.stderr);
  });

  it('fails when an expected type never appeared', () => {
    const m = fullManifest(['session.start', 'session.end']);
    const r = runWith(reportDir([OK]), manifestFile(m));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /session\.end/);
  });

  it('fails when a registered type is in neither list', () => {
    const m = fullManifest();
    delete m.excluded[ALL_EVENT_TYPES.find((t) => t !== 'session.start')];
    const r = runWith(reportDir([OK]), manifestFile(m));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /accounted for|neither/i);
  });

  it('fails when the manifest names a type the schema does not register', () => {
    const m = fullManifest();
    m.excluded['not.a.real.type'] = 'bogus';
    const r = runWith(reportDir([OK]), manifestFile(m));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /not\.a\.real\.type/);
  });

  it('fails when an exclusion has an empty reason', () => {
    const m = fullManifest();
    m.excluded[Object.keys(m.excluded)[0]] = '';
    const r = runWith(reportDir([OK]), manifestFile(m));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /reason/i);
  });

  it('the committed manifest accounts for every registered type', () => {
    const committed = JSON.parse(
      readFileSync(join(REPO_ROOT, 'test', 'bus-coverage.json'), 'utf8'),
    );
    const accounted = new Set([...committed.expected, ...Object.keys(committed.excluded)]);
    const missing = ALL_EVENT_TYPES.filter((t) => !accounted.has(t));
    assert.deepEqual(missing, [], `unaccounted event types: ${missing.join(', ')}`);
    for (const [type, reason] of Object.entries(committed.excluded)) {
      assert.ok(reason && reason.trim() && reason !== 'FILL IN', `${type} needs a real reason`);
    }
  });
});
```

Add `readFileSync` to the `node:fs` import at the top of the file.

- [ ] **Step 4: Run the tests to verify they fail**

Run: `node --test test/node/check-bus-coverage.test.mjs`
Expected: FAIL — the gate ignores `--manifest` and exits 2 on an unknown
argument.

- [ ] **Step 5: Implement Gate B**

In `scripts/lint/check-bus-coverage.mjs`, add `--manifest` to `parseArgs`:

```javascript
  const out = {
    report: join(REPO_ROOT, 'test', 'tmp-emission-report'),
    manifest: join(REPO_ROOT, 'test', 'bus-coverage.json'),
  };
```

and inside the loop, before the `--help` branch:

```javascript
    else if (a === '--manifest') out.manifest = argv[++i];
```

Add the gate itself:

```javascript
/**
 * Gate B: every registered event type is accounted for.
 *
 * `expected` types must have produced a validated emission during the suite.
 * `excluded` types must carry a reason. Together the two lists must equal
 * ALL_EVENT_TYPES exactly, so a newly registered type belongs to neither and
 * fails here until someone triages it deliberately.
 */
async function gateB(lines, manifestPath) {
  const failures = [];
  let schema;
  try {
    schema = await import('@onlooker-community/schema');
  } catch {
    return ['@onlooker-community/schema is not installed; run `npm ci`'];
  }
  const registered = new Set(schema.ALL_EVENT_TYPES);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const expected = manifest.expected ?? [];
  const excluded = manifest.excluded ?? {};

  const emitted = new Set(lines.filter((l) => l.valid === true).map((l) => l.event_type));
  for (const t of expected) {
    if (!emitted.has(t)) failures.push(`expected type never emitted during the suite: ${t}`);
  }

  const accounted = new Set([...expected, ...Object.keys(excluded)]);
  for (const t of registered) {
    if (!accounted.has(t)) {
      failures.push(`registered type is in neither list — triage it in the manifest: ${t}`);
    }
  }
  for (const t of accounted) {
    if (!registered.has(t)) {
      failures.push(`manifest names a type the schema does not register: ${t}`);
    }
  }
  for (const [t, reason] of Object.entries(excluded)) {
    if (!reason || !String(reason).trim()) {
      failures.push(`excluded type needs a reason: ${t}`);
    }
  }
  return failures;
}
```

Replace the existing `main` function and the `isMain` block at the bottom of
the file — do not append a second copy:

```javascript
async function main() {
  const args = parseArgs(process.argv);
  const lines = loadReport(args.report);
  const failures = gateA(lines);
  // Skip Gate B when nothing was recorded. Every expected type would report
  // as missing, burying the single failure that actually matters.
  if (lines.length > 0) failures.push(...(await gateB(lines, args.manifest)));
  if (failures.length) {
    for (const f of failures) process.stderr.write(`check-bus-coverage: ${f}\n`);
    process.exit(1);
  }
  process.stdout.write(`check-bus-coverage: ok (${lines.length} emission(s))\n`);
}

const isMain = process.argv[1]?.endsWith('check-bus-coverage.mjs') ?? false;
if (isMain) {
  main().catch((err) => {
    process.stderr.write(`check-bus-coverage: ${err.message}\n`);
    process.exit(1);
  });
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `node --test test/node/check-bus-coverage.test.mjs`
Expected: PASS, 10 tests.

- [ ] **Step 7: Run the whole gate against the real suite**

Run: `npm run test:ci`
Expected: PASS end to end, including `test:bus`.

- [ ] **Step 8: Break it on purpose**

Move one type from `expected` into `excluded` in `test/bus-coverage.json`, run
`npm run test:bus`, and confirm it fails naming that type — the manifest must
not be able to silently under-claim. Restore the file afterward.

- [ ] **Step 9: Format and commit**

```bash
./node_modules/.bin/biome check --write scripts/lint/check-bus-coverage.mjs test/node/check-bus-coverage.test.mjs test/bus-coverage.json
git add test/bus-coverage.json scripts/lint/check-bus-coverage.mjs test/node/check-bus-coverage.test.mjs
```

Then run `/commit` with: require every registered event type to be either
covered by a test or excluded with a stated reason.

---

## Task 5: Documentation

**Files:**

- Modify: `docs/architecture.md`
- Modify: `CLAUDE.md`
- Modify: `.claude/skills/writing-tests/SKILL.md`

**Interfaces:**

- Consumes: the finished harness from Tasks 1–4. Produces no code.

- [ ] **Step 1: Document the gates in `docs/architecture.md`**

Add a subsection to the event-bus discussion:

```markdown
### Emission gates

Payload drift used to be invisible. The emitter validates against
`@onlooker-community/schema` wherever it resolves and rejects a bad event with
a non-zero exit, but hooks fail soft and exit 0, so the rejection was destroyed
and the event simply never appeared.

Two CI gates close that hole. During the test suite `ONLOOKER_TEST_REPORT_DIR`
is set, and the emitter appends one line per emission to
`emissions.jsonl` recording whether validation ran and whether it passed.
`npm run test:bus` then fails if any emission was rejected, if validation never
ran at all, or if a registered event type appears in neither list of
`test/bus-coverage.json`.

Adding an event type therefore requires triaging it into that manifest — as
`expected`, meaning a test exercises the branch that emits it, or as
`excluded` with a stated reason.
```

- [ ] **Step 2: Add the step to the plugin checklist in `CLAUDE.md`**

In the "Adding a new plugin" numbered list, after the step about registering
event types in `@onlooker-community/schema`, add:

```markdown
6. Triage every new event type into `test/bus-coverage.json` — `expected` when
   a test drives the branch that emits it, `excluded` with a reason when not.
   `npm run test:bus` fails on any registered type that appears in neither list.
```

Renumber the steps that follow.

- [ ] **Step 3: Note the suite-wide guarantee in the testing skill**

In `.claude/skills/writing-tests/SKILL.md`, under "Assert against the event
log", add:

```markdown
You no longer need a bespoke per-plugin test proving a payload validates. The
suite gates every emission at once: `ONLOOKER_TEST_REPORT_DIR` is set during
`test:bats` and `test:schema`, and `npm run test:bus` fails on any rejected
emission. Write the test that drives the branch; the gate does the validating.

What still matters is exercising the *rare* branches. A payload is only checked
when some test makes the code emit it, so an enum bug on an error path stays
invisible until a test reaches that path.
```

- [ ] **Step 4: Lint the docs**

Run: `npm run lint:check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/architecture.md CLAUDE.md .claude/skills/writing-tests/SKILL.md
```

Then run `/commit` with: document the emission gates and the manifest step for
new plugins.

---

## Acceptance

Verified by running `npm run test:ci` from a clean tree:

- [ ] `test:bus` runs after `test:bats` and `test:schema`, and fails when the
      report is missing.
- [ ] Gate A fails on a rejected emission, naming the type and its ajv errors.
- [ ] Gate A fails when no emission was validated, rather than passing green.
- [ ] Gate B fails when a registered type is in neither manifest list.
- [ ] Gate B fails when an exclusion carries an empty reason.
- [ ] Emitting with `ONLOOKER_TEST_REPORT_DIR` unset writes no report and
      leaves exit codes unchanged.
- [ ] `plugins/cartographer`'s `finding_type:"unknown"` payload
      (`ecosystem-ci0`) is caught by Gate A once a test exercises that branch,
      with no bespoke test written for it.
