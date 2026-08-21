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
