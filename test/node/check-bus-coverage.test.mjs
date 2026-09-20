import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { ALL_EVENT_TYPES } from '@onlooker-community/schema';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const GATE = join(REPO_ROOT, 'scripts', 'lint', 'check-bus-coverage.mjs');

const RUN_ID = 'testrun-0001';

// Mirrors what scripts/test/run-bats.sh leaves behind: the emissions plus the
// completion sentinel. `sentinel: null` models a run that never finished (or
// whose report a concurrent run clobbered), which is the case the gate has to
// tell apart from a genuine coverage regression.
function reportDir(
  lines,
  { sentinel = { run_id: RUN_ID, completed_at: '2026-09-20T00:00:00Z', bats_status: 0 } } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), 'bus-report-'));
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, 'emissions.jsonl'),
    lines.map((l) => JSON.stringify(l)).join('\n') + (lines.length ? '\n' : ''),
  );
  if (sentinel) writeFileSync(join(dir, 'complete.json'), JSON.stringify(sentinel));
  return dir;
}

function manifestFile(manifest) {
  const dir = mkdtempSync(join(tmpdir(), 'bus-manifest-'));
  const p = join(dir, 'bus-coverage.json');
  writeFileSync(p, JSON.stringify(manifest, null, 2));
  return p;
}

// Gate A's own tests exercise Gate A only. They must stay hermetic — immune
// to whatever the real committed manifest expects — so they run against a
// fixture that expects only session.start (the type the OK fixture below
// actually emits) and excludes every other registered type. session.start
// has to sit in `expected`, not `excluded`: Gate B's fourth assertion fails
// an excluded type that turns up emitted-and-valid, and every Gate A test
// using OK does emit it.
function gateAManifest() {
  const excluded = {};
  for (const t of ALL_EVENT_TYPES) {
    if (t !== 'session.start') excluded[t] = 'not exercised by this Gate A fixture';
  }
  return { expected: ['session.start'], excluded };
}

const GATE_A_MANIFEST = manifestFile(gateAManifest());

function run(dir) {
  const r = spawnSync('node', [GATE, '--report', dir, '--manifest', GATE_A_MANIFEST], {
    encoding: 'utf8',
  });
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

  it('fails when an excluded type is actually emitted and valid', () => {
    // expected: [] puts session.start in excluded, but the fixture report
    // still emits it as valid — coverage would be silently under-claimed.
    const m = fullManifest([]);
    const r = runWith(reportDir([OK]), manifestFile(m));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /session\.start/);
  });

  it('the committed manifest accounts for every registered type', () => {
    const committed = JSON.parse(readFileSync(join(REPO_ROOT, 'test', 'bus-coverage.json'), 'utf8'));
    const accounted = new Set([...committed.expected, ...Object.keys(committed.excluded)]);
    const missing = ALL_EVENT_TYPES.filter((t) => !accounted.has(t));
    assert.deepEqual(missing, [], `unaccounted event types: ${missing.join(', ')}`);
    for (const [type, reason] of Object.entries(committed.excluded)) {
      assert.ok(reason?.trim() && reason !== 'FILL IN', `${type} needs a real reason`);
    }
  });
});

// The gate's hidden precondition: a COMPLETE test:bats must have run against
// this report directory. Nothing used to enforce it, so a clobbered or partial
// report produced a wall of "expected type never emitted" — which reads exactly
// like a real coverage regression and cost an investigation every time. The
// sentinel makes the precondition explicit and, crucially, SKIPS gate B when it
// fails, so one accurate line replaces ninety misleading ones (ecosystem-0bh).
describe('check-bus-coverage completeness sentinel', () => {
  // A manifest gate B would certainly fail, to prove gate B never ran.
  const WOULD_FAIL_GATE_B = manifestFile(fullManifest(['session.start', 'session.end']));

  it('fails when no completed run is recorded', () => {
    const r = runWith(reportDir([OK], { sentinel: null }), WOULD_FAIL_GATE_B);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /no completed .*test:bats.* run/i);
  });

  it('does not report coverage gaps when the run never completed', () => {
    const r = runWith(reportDir([OK], { sentinel: null }), WOULD_FAIL_GATE_B);
    assert.doesNotMatch(r.stderr, /never emitted/i);
    assert.doesNotMatch(r.stderr, /session\.end/);
  });

  it('fails when the report mixes records from another run', () => {
    const mine = { ...OK, run_id: RUN_ID };
    const theirs = { ...OK, run_id: 'testrun-9999' };
    const r = runWith(reportDir([mine, theirs]), WOULD_FAIL_GATE_B);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /concurrent|another run|testrun-9999/i);
  });

  it('does not report coverage gaps when the report was clobbered', () => {
    const mine = { ...OK, run_id: RUN_ID };
    const theirs = { ...OK, run_id: 'testrun-9999' };
    const r = runWith(reportDir([mine, theirs]), WOULD_FAIL_GATE_B);
    assert.doesNotMatch(r.stderr, /never emitted/i);
  });

  it('passes when every stamped record belongs to the recorded run', () => {
    const mine = { ...OK, run_id: RUN_ID };
    const r = runWith(reportDir([mine, mine]), manifestFile(fullManifest()));
    assert.equal(r.code, 0, r.stderr);
  });

  // test:schema appends to the same report directory after the sentinel is
  // written, without a run id. Those records are inert for both gates and must
  // not be mistaken for a concurrent suite.
  it('tolerates records that carry no run id', () => {
    const stamped = { ...OK, run_id: RUN_ID };
    const r = runWith(reportDir([stamped, OK]), manifestFile(fullManifest()));
    assert.equal(r.code, 0, r.stderr);
  });

  it('reports a recorded run that exited non-zero', () => {
    const sentinel = { run_id: RUN_ID, completed_at: '2026-09-20T00:00:00Z', bats_status: 1 };
    const r = runWith(reportDir([{ ...OK, run_id: RUN_ID }], { sentinel }), manifestFile(fullManifest()));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /exited 1|non-zero/i);
  });
});
