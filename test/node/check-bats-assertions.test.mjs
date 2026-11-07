// Tests for scripts/lint/check-bats-assertions.mjs.
//
// ONL-206. Under macOS /bin/bash 3.2 -- what `bats` resolves locally -- a
// failing `[[ ]]` or `(( ))` that is not a test's last command does not fail
// the test. errexit ignores both compound commands there, at any nesting
// depth: inside a for loop, an if body or a brace group the failure is lost
// just the same. bash 5 (CI) gates all of them, so a broken assertion reads
// green on a laptop and red only in CI.
//
// Each test stands up a scratch git repo, writes a .bats file into it, stages
// it (the lint reads `git ls-files`, same as a real checkout), runs the lint
// as a subprocess, and asserts on exit code plus the reported lines.

import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const LINTER = join(REPO_ROOT, 'scripts', 'lint', 'check-bats-assertions.mjs');

function scaffold() {
  const root = mkdtempSync(join(tmpdir(), 'check-bats-assert-'));
  execFileSync('git', ['init', '-q'], { cwd: root });
  return root;
}

function writeBats(root, lines, relPath = 'test/bats/demo.bats') {
  const p = join(root, relPath);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, `${lines.join('\n')}\n`);
  return p;
}

function run(root, extra = []) {
  execFileSync('git', ['add', '-A'], { cwd: root });
  const r = spawnSync('node', [LINTER, '--root', root, ...extra], { encoding: 'utf8' });
  const stderr = r.stderr || '';
  // A crash also exits 1, which would satisfy every "expected findings"
  // assertion below for the wrong reason. Fail loudly instead, so status 1
  // only ever means "the lint reported findings".
  if (/Cannot find module|\bERR_[A-Z_]+\b|^\s+at .*:\d+:\d+$/m.test(stderr)) {
    throw new Error(`lint crashed rather than reporting:\n${stderr}`);
  }
  return { status: r.status, stdout: r.stdout || '', stderr };
}

// The reported file:line pairs, so a test can say exactly which lines it
// expects rather than only that something was found.
function reported(stdout) {
  return [...stdout.matchAll(/^\s+\S+\s+(\S+:\d+)/gm)].map((m) => m[1]);
}

describe('ungated mid-test assertions', () => {
  it('flags a bare [[ ]] that is not the last command', () => {
    const root = scaffold();
    writeBats(root, ['@test "demo" {', '  [[ "$output" == *ok* ]]', '  [ "$status" -eq 0 ]', '}']);

    const r = run(root);
    assert.equal(r.status, 1, `expected findings\n${r.stdout}${r.stderr}`);
    assert.deepEqual(reported(r.stdout), ['test/bats/demo.bats:2']);
    assert.match(r.stdout, /ungated_double_bracket/);
  });

  it('flags a bare (( )) that is not the last command', () => {
    const root = scaffold();
    writeBats(root, ['@test "demo" {', '  (( count == 3 ))', '  true', '}']);

    const r = run(root);
    assert.equal(r.status, 1, `expected findings\n${r.stdout}${r.stderr}`);
    assert.deepEqual(reported(r.stdout), ['test/bats/demo.bats:2']);
    assert.match(r.stdout, /ungated_arith/);
  });

  // bash 3.2 loses these too: the loop or if returns the last iteration's
  // status, and a failing [[ ]] inside it never stops the body.
  it('flags [[ ]] nested inside a loop or an if body', () => {
    const root = scaffold();
    writeBats(root, [
      '@test "demo" {',
      '  for f in a b; do',
      '    [[ -f "$f" ]]',
      '  done',
      '  if true; then',
      '    [[ 1 == 2 ]]',
      '  fi',
      '  true',
      '}',
    ]);

    const r = run(root);
    assert.deepEqual(reported(r.stdout), ['test/bats/demo.bats:3', 'test/bats/demo.bats:6']);
  });

  it('does not flag the final command of a test body', () => {
    const root = scaffold();
    writeBats(root, ['@test "demo" {', '  run true', '  [[ "$output" == "" ]]', '', '  # trailing note', '}']);

    const r = run(root);
    assert.equal(r.status, 0, r.stdout);
    assert.match(r.stdout, /check-bats-assertions: ok/);
  });

  it('accepts the guarded forms', () => {
    const root = scaffold();
    writeBats(root, [
      '@test "demo" {',
      '  [[ -n "$a" ]] || return 1',
      '  [[ -n "$b" ]] || false',
      '  (( n > 0 )) || return 1',
      '  [[ -n "$c" ]] || { echo "c was empty" >&2; return 1; }',
      '  true',
      '}',
    ]);

    assert.equal(run(root).status, 0);
  });

  // `if [[ ]]`, `while [[ ]]` and `[[ ]] && x` are conditions, not
  // assertions. `$(( ))` is an expansion. None of them is the hole.
  it('does not flag conditions, lists or arithmetic expansion', () => {
    const root = scaffold();
    writeBats(root, [
      '@test "demo" {',
      '  if [[ -n "$a" ]]; then echo a; fi',
      '  while [[ $i -lt 3 ]]; do i=$((i + 1)); done',
      '  [[ -n "$b" ]] && echo b',
      '  [[ -f "$c" ]] || touch "$c"',
      '  n=$(( 1 + 2 ))',
      '  echo $(( n * 2 ))',
      '  true',
      '}',
    ]);

    assert.equal(run(root).status, 0, run(root).stdout);
  });

  it('ignores [[ ]] inside heredocs and multi-line quoted strings', () => {
    const root = scaffold();
    writeBats(root, [
      '@test "demo" {',
      '  cat > "$f" <<\'EOF\'',
      '[[ 1 == 2 ]]',
      'EOF',
      "  run bash -c '",
      '    [[ 1 == 2 ]]',
      "    true'",
      '  run bash -c "',
      '    [[ 1 == 2 ]]',
      '    true"',
      '  true',
      '}',
    ]);

    const r = run(root);
    assert.equal(r.status, 0, r.stdout);
  });

  it('ignores [[ ]] outside @test bodies', () => {
    const root = scaffold();
    writeBats(root, ['_helper() {', '  [[ -n "$1" ]]', '  echo "$1"', '}', '', '@test "demo" {', '  true', '}']);

    assert.equal(run(root).status, 0);
  });

  it('reports every finding in a file, one per line, in line order', () => {
    const root = scaffold();
    writeBats(root, [
      '@test "one" {',
      '  [[ a == a ]]',
      '  true',
      '}',
      '',
      '@test "two" {',
      '  (( 1 ))',
      '  [[ b == b ]]  # with a note',
      '  true',
      '}',
    ]);

    const r = run(root);
    assert.deepEqual(reported(r.stdout), ['test/bats/demo.bats:2', 'test/bats/demo.bats:7', 'test/bats/demo.bats:8']);
    assert.match(r.stdout, /check-bats-assertions: 3 finding\(s\)/);
  });
});

describe('--fix', () => {
  it('appends || return 1 to each finding and leaves everything else alone', () => {
    const root = scaffold();
    const file = writeBats(root, [
      '@test "demo" {',
      '  [[ a == a ]]',
      '  (( 1 ))  # a note',
      '  [[ ok ]] || return 1',
      '  [[ last == last ]]',
      '}',
    ]);

    const fixed = run(root, ['--fix']);
    assert.equal(fixed.status, 0, fixed.stdout);
    assert.equal(
      readFileSync(file, 'utf8'),
      [
        '@test "demo" {',
        '  [[ a == a ]] || return 1',
        '  (( 1 )) || return 1  # a note',
        '  [[ ok ]] || return 1',
        '  [[ last == last ]]',
        '}',
        '',
      ].join('\n'),
    );
    assert.equal(run(root).status, 0, 'a fixed file passes the lint');
  });
});
