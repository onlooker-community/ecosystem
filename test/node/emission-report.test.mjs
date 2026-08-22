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
    emit(VALID, { reportDir: dir });
    assert.equal(readReport(dir).length, 1);
    // Same directory, but this emission is never told about it. The count must
    // not move. Asserting on an untouched temp dir would pass either way.
    const r = emit(VALID);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(readReport(dir).length, 1);
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
