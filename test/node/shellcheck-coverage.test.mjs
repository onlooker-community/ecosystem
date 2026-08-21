import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');

// Every shell script git tracks. This is the set that must be linted; anything
// test:shellcheck does not hand to shellcheck is silently unlinted.
function trackedShellScripts() {
  const r = spawnSync('git', ['ls-files', '-z', '*.sh'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, `git ls-files failed: ${r.stderr}`);
  return new Set(r.stdout.split('\0').filter(Boolean));
}

// Run the real test:shellcheck command with a shellcheck that reports its
// arguments instead of linting. Shimming rather than parsing the command keeps
// this test agnostic to how the file list is produced -- an enumerated list, a
// glob, or git ls-files all answer the same question: what gets linted?
function filesHandedToShellcheck() {
  const stubDir = mkdtempSync(join(tmpdir(), 'shellcheck-stub-'));
  const stub = join(stubDir, 'shellcheck');
  writeFileSync(
    stub,
    '#!/bin/sh\nfor a in "$@"; do\n  case "$a" in\n    *.sh) printf \'%s\\n\' "$a" ;;\n  esac\ndone\nexit 0\n',
  );
  chmodSync(stub, 0o755);

  const pkg = JSON.parse(readFileSync(join(REPO_ROOT, 'package.json'), 'utf8'));
  const command = pkg.scripts['test:shellcheck'];
  assert.ok(command, 'package.json has no test:shellcheck script');

  const r = spawnSync('sh', ['-c', command], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    env: { ...process.env, PATH: `${stubDir}:${process.env.PATH}` },
  });
  assert.equal(r.status, 0, `test:shellcheck command failed: ${r.stderr}`);
  return new Set(r.stdout.split('\n').filter(Boolean));
}

describe('test:shellcheck coverage', () => {
  it('lints every shell script in the repository', () => {
    const tracked = trackedShellScripts();
    const linted = filesHandedToShellcheck();

    assert.ok(tracked.size > 0, 'expected git to track at least one .sh file');

    const orphaned = [...tracked].filter((f) => !linted.has(f)).sort();
    assert.deepEqual(orphaned, [], `these tracked scripts are never shellchecked:\n  ${orphaned.join('\n  ')}`);
  });

  it('does not reference scripts that no longer exist', () => {
    const tracked = trackedShellScripts();
    const linted = filesHandedToShellcheck();

    const stale = [...linted].filter((f) => !tracked.has(f)).sort();
    assert.deepEqual(stale, [], `test:shellcheck names paths git does not track:\n  ${stale.join('\n  ')}`);
  });
});
