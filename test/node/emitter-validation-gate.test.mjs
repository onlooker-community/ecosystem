// Validation is opt-IN, gated on ONLOOKER_VALIDATE=1.
//
// It used to be gated on whether `@onlooker-community/schema` resolved, on the
// premise that installed marketplace plugins ship no node_modules and would
// therefore skip it. They do ship it — every cached ecosystem version from
// 0.33.1 to 0.47.0 carries node_modules/@onlooker-community/schema — so
// production resolved the package and loaded ajv on every single event. That
// cost ~73ms per emission, roughly half the measured PostToolUse budget, on a
// path that runs once per tool call. See ecosystem-aya and ADR-005.
//
// These tests run where the package DOES resolve, which is the whole point:
// the gate must be the env var, not resolvability. Asserting that requires a
// context where resolvability alone would have been enough.

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

// session.start requires working_directory and forbids extra properties.
const VALID = {
  plugin: 'onlooker',
  session_id: '01JZZZZZZZZZZZZZZZZZZZZZZZ',
  event_type: 'session.start',
  payload: { working_directory: '/tmp/x' },
};
const INVALID = { ...VALID, payload: { working_directory: 42 } };

// The package must actually be resolvable here, otherwise every assertion
// below passes for the wrong reason — a skipped validation looks identical to
// one that never had a validator. Guard it rather than assume it.
function schemaResolves() {
  const probe = spawnSync('node', ['--input-type=module', '-e', 'await import("@onlooker-community/schema")'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  });
  return probe.status === 0;
}

function emit(params, { validate, reportDir } = {}) {
  const env = {
    ...process.env,
    ONLOOKER_DIR: mkdtempSync(join(tmpdir(), 'gate-onlooker-')),
  };
  // Never inherit these — test:schema sets both, which would mask the gate.
  if (validate) env.ONLOOKER_VALIDATE = '1';
  else delete env.ONLOOKER_VALIDATE;
  if (reportDir) env.ONLOOKER_TEST_REPORT_DIR = reportDir;
  else delete env.ONLOOKER_TEST_REPORT_DIR;

  const r = spawnSync('node', [EMITTER, 'emit'], {
    input: JSON.stringify(params),
    encoding: 'utf8',
    env,
  });
  return { ...r, onlookerDir: env.ONLOOKER_DIR };
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

// The emitter prints the event on stdout; the calling hook is what redirects
// it into the log. So "was it emitted?" is a question about stdout, not about
// onlooker-events.jsonl — the emitter only ever writes emissions.jsonl itself.
function emittedEvent(result) {
  const out = (result.stdout ?? '').trim();
  if (!out) return null;
  return JSON.parse(out);
}

describe('emitter validation gate', () => {
  it('the schema package resolves here (guards the tests below)', () => {
    assert.equal(schemaResolves(), true, 'schema package must resolve for these tests to mean anything');
  });

  it('skips validation when ONLOOKER_VALIDATE is unset, though the package resolves', () => {
    const dir = mkdtempSync(join(tmpdir(), 'gate-report-'));
    const r = emit(INVALID, { reportDir: dir });

    // Fails open: the event is emitted even though it would not validate.
    assert.equal(r.status, 0, r.stderr);
    const lines = readReport(dir);
    assert.equal(lines.length, 1);
    assert.equal(lines[0].validated, false);
    // And it really was emitted — failing open means emitting, not dropping.
    assert.equal(emittedEvent(r)?.event_type, 'session.start');
  });

  it('validates and rejects when ONLOOKER_VALIDATE=1', () => {
    const dir = mkdtempSync(join(tmpdir(), 'gate-report-'));
    const r = emit(INVALID, { validate: true, reportDir: dir });

    assert.equal(r.status, 1);
    const lines = readReport(dir);
    assert.equal(lines.length, 1);
    assert.equal(lines[0].validated, true);
    assert.equal(lines[0].valid, false);
    assert.ok(Array.isArray(lines[0].errors) && lines[0].errors.length > 0);
  });

  it('accepts a valid event under either setting', () => {
    const off = emit(VALID);
    assert.equal(off.status, 0, off.stderr);
    assert.equal(emittedEvent(off)?.event_type, 'session.start');

    const on = emit(VALID, { validate: true });
    assert.equal(on.status, 0, on.stderr);
    assert.equal(emittedEvent(on)?.event_type, 'session.start');
  });

  // The `validate` subcommand is an explicit request to validate — the whole
  // reason to invoke it. The emission-path gate must not reach it, or the
  // command reports "schema is not installed" for a package that is sitting
  // right there, and bats' envelope assertions (see the writing-tests skill)
  // silently depend on whoever set the variable upstream.
  describe('the validate subcommand ignores the gate', () => {
    function validate(envelope, { validate: v } = {}) {
      const env = { ...process.env };
      if (v) env.ONLOOKER_VALIDATE = '1';
      else delete env.ONLOOKER_VALIDATE;
      return spawnSync('node', [EMITTER, 'validate'], {
        input: JSON.stringify(envelope),
        encoding: 'utf8',
        env,
      });
    }

    // Build a real envelope through the emitter rather than hand-rolling one;
    // a hand-built envelope tests the fixture, not the validator.
    function realEnvelope(params) {
      const env = { ...process.env, ONLOOKER_DIR: mkdtempSync(join(tmpdir(), 'gate-env-')) };
      delete env.ONLOOKER_VALIDATE;
      const r = spawnSync('node', [EMITTER, 'emit'], {
        input: JSON.stringify(params),
        encoding: 'utf8',
        env,
      });
      return JSON.parse(r.stdout.trim());
    }

    it('accepts a valid envelope with the gate unset', () => {
      const r = validate(realEnvelope(VALID));
      assert.equal(r.status, 0, r.stderr);
    });

    it('still rejects a bad envelope with the gate unset', () => {
      const bad = { ...realEnvelope(VALID), payload: { working_directory: 42 } };
      const r = validate(bad);
      assert.equal(r.status, 1);
      assert.ok(!/not installed/.test(r.stderr), `misreported as uninstalled: ${r.stderr}`);
    });
  });
});
