// biome-ignore-all lint/suspicious/noTemplateCurlyInString: the fixtures below
// are bash source held in single-quoted JS strings. `${v:-4096}` and friends
// are shell parameter expansions -- the weak third fallback shape these tests
// exist to detect -- so they must stay literal, not become JS interpolation.

// Tests for scripts/lint/check-bash-arithmetic.mjs.
//
// The sweep ONL-132 asked for. It exists because three different ad-hoc greps
// produced three different answers about how many sites carry the bug (24
// files, 5 files, 12 files), and the migration's scope IS this output — so the
// detection has to be committed and reproducible rather than retyped.
//
// Each test stands up a scratch git repo, writes shell into it, stages it
// (the sweep reads `git ls-files`, same as a real checkout), runs the linter
// as a subprocess, and asserts on exit code plus emitted findings.

import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const LINTER = join(REPO_ROOT, 'scripts', 'lint', 'check-bash-arithmetic.mjs');

function scaffold() {
  const root = mkdtempSync(join(tmpdir(), 'check-arith-'));
  execFileSync('git', ['init', '-q'], { cwd: root });
  execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: root });
  execFileSync('git', ['config', 'user.name', 'test'], { cwd: root });
  return root;
}

function writeFile(root, relPath, text) {
  const p = join(root, relPath);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, text);
}

function run(root, extra = []) {
  execFileSync('git', ['add', '-A'], { cwd: root });
  const r = spawnSync('node', [LINTER, '--root', root, ...extra], { encoding: 'utf8' });
  const stderr = r.stderr || '';
  // A crash also exits 1, which would satisfy every "expected findings"
  // assertion below for entirely the wrong reason. Fail loudly instead, so
  // status 1 only ever means "the sweep reported findings".
  if (/Cannot find module|\bERR_[A-Z_]+\b|^\s+at .*:\d+:\d+$/m.test(stderr)) {
    throw new Error(`linter crashed rather than reporting:\n${stderr}`);
  }
  return { status: r.status, stdout: r.stdout || '', stderr };
}

describe('unguarded config values reaching arithmetic', () => {
  it('flags a config value that reaches arithmetic with no numeric guard', () => {
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/hooks/demo-hook.sh',
      [
        '#!/usr/bin/env bash',
        'set -uo pipefail',
        "MAX_CHARS=$(demo_config_get '.demo.max_chars')",
        '[[ -z "$MAX_CHARS" || "$MAX_CHARS" == "null" ]] && MAX_CHARS=2400',
        'if (( 10 > MAX_CHARS )); then echo over; fi',
      ].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 1, `expected findings, got status ${r.status}\n${r.stdout}${r.stderr}`);
    assert.match(r.stdout, /demo-hook\.sh/);
    assert.match(r.stdout, /MAX_CHARS/);
  });

  it('does not flag a value the file validates as numeric', () => {
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/hooks/demo-hook.sh',
      [
        '#!/usr/bin/env bash',
        'set -uo pipefail',
        "MAX_CHARS=$(demo_config_get '.demo.max_chars')",
        '[[ "$MAX_CHARS" =~ ^[0-9]+$ ]] || MAX_CHARS=2400',
        'if (( 10 > MAX_CHARS )); then echo over; fi',
      ].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 0, `expected clean, got findings:\n${r.stdout}`);
    assert.match(r.stdout, /check-bash-arithmetic: ok/);
  });
});

// The miscount that motivated this sweep. inspector-run.sh is credited in
// ONL-132 as one of four already-guarded files; its four numeric checks are
// all on TIMESTAMPS, while its real config value crosses from an accessor in
// another file and reaches (( )) unguarded. A sweep anchored on `_config_get`
// in the consumer cannot see it, which is how it was scored as safe.
describe('values that cross from a config accessor in another file', () => {
  it('flags a value whose accessor reads config and neither side guards it', () => {
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-config.sh',
      [
        '#!/usr/bin/env bash',
        'demo_config_output_max_bytes() {',
        '\tlocal v',
        "\tv=$(demo_config_get '.demo.output_max_bytes')",
        '\tprintf \'%s\' "${v:-4096}"',
        '}',
      ].join('\n'),
    );
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-run.sh',
      [
        '#!/usr/bin/env bash',
        'set -uo pipefail',
        'max_bytes=$(demo_config_output_max_bytes)',
        'if (( bytes > max_bytes )); then echo trim; fi',
      ].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 1, `expected a finding, got status ${r.status}\n${r.stdout}`);
    assert.match(r.stdout, /demo-run\.sh/);
    assert.match(r.stdout, /max_bytes/);
  });
  it('does not flag a value its accessor validates, whatever the local is named', () => {
    // Deliberately `local raw`, not the repo's usual `local v`. A guard check
    // keyed to one conventional name would pass this test by accident on `v`
    // and silently miss every accessor that spells it differently.
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-config.sh',
      [
        '#!/usr/bin/env bash',
        'demo_config_budget_ms() {',
        '\tlocal raw',
        "\traw=$(demo_config_get '.demo.budget_ms')",
        '\t[[ "$raw" =~ ^[0-9]+$ ]] || raw=500',
        '\tprintf \'%s\' "$raw"',
        '}',
      ].join('\n'),
    );
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-run.sh',
      [
        '#!/usr/bin/env bash',
        'set -uo pipefail',
        'budget=$(demo_config_budget_ms)',
        'if (( elapsed > budget )); then echo over; fi',
      ].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 0, `expected clean, got findings:\n${r.stdout}`);
  });
});

// 449.70 / ONL-29. A different mechanism from the config hazard above, folded
// into the same sweep because both are hazards at a (( )) site and one
// detector is cheaper to keep honest than two.
//
// `(( x++ ))` evaluates to the PRE-increment value, so the first increment
// from 0 returns exit status 1. Under errexit bash 4+ aborts on it. These are
// dormant in this repo only because the scripts use `set -uo pipefail` without
// -e -- add -e, or call the function from anything that has errexit on, and
// the counter aborts on its first increment.
describe('post-increment arithmetic that exits non-zero on the first bump', () => {
  it('flags a bare (( x++ )) used as a command', () => {
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-count.sh',
      ['#!/usr/bin/env bash', 'set -uo pipefail', 'count=0', '(( count++ ))', 'echo "$count"'].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 1, `expected a finding, got status ${r.status}\n${r.stdout}`);
    assert.match(r.stdout, /unguarded_increment/);
    assert.match(r.stdout, /demo-count\.sh/);
  });

  it('does not flag an increment guarded with || true', () => {
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-count.sh',
      ['#!/usr/bin/env bash', 'set -uo pipefail', 'count=0', '(( count++ )) || true', 'echo "$count"'].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 0, `expected clean, got findings:\n${r.stdout}`);
  });
});

describe('scope and determinism', () => {
  it('reports a vendored lib once at its canonical path, not once per plugin', () => {
    // config-loader.sh and friends are copied into every plugin by
    // sync-shared-libs.sh. Counting each copy would multiply one defect by the
    // plugin count and inflate the migration's scope -- which is the number
    // this sweep exists to pin down.
    const root = scaffold();
    const body = ['#!/usr/bin/env bash', 'count=0', '(( count++ ))'].join('\n');
    writeFile(root, 'scripts/lib/config-loader.sh', body);
    writeFile(root, 'plugins/a/scripts/lib/config-loader.sh', body);
    writeFile(root, 'plugins/b/scripts/lib/config-loader.sh', body);

    const r = run(root);
    const hits = r.stdout.split('\n').filter((l) => l.includes('config-loader.sh'));
    assert.equal(hits.length, 1, `expected 1 report, got ${hits.length}:\n${r.stdout}`);
    assert.match(hits[0], /scripts\/lib\/config-loader\.sh/);
    assert.doesNotMatch(hits[0], /plugins\//);
  });

  it('emits byte-identical output across runs', () => {
    // ONL-132's acceptance criterion. Three ad-hoc sweeps gave three different
    // scopes; an unstable one would just be a fourth.
    const root = scaffold();
    writeFile(
      root,
      'plugins/b/scripts/lib/b.sh',
      ['#!/usr/bin/env bash', 'n=0', '(( n++ ))', 'm=0', '(( m++ ))'].join('\n'),
    );
    writeFile(
      root,
      'plugins/a/scripts/lib/a.sh',
      ['#!/usr/bin/env bash', "Z=$(a_config_get '.a.z')", "Y=$(a_config_get '.a.y')", 'echo $(( Y + Z ))'].join('\n'),
    );

    const first = run(root);
    const second = run(root);
    assert.equal(first.status, 1);
    assert.equal(first.stdout, second.stdout, 'output differs between identical runs');
  });

  it('does not treat a function that merely reads config as a config accessor', () => {
    // Found as a live false positive on the real tree: governor_estimate_tokens
    // reads .governor.estimation.safety_margin internally but RETURNS a
    // computed token estimate, so its caller's value is arithmetic output, not
    // an unvalidated config string. Classifying any function that mentions
    // _config_get as an accessor reported that caller as a finding.
    //
    // An accessor's signature is that it PRINTS the config value it read.
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-estimate.sh',
      [
        '#!/usr/bin/env bash',
        'demo_estimate_tokens() {',
        '\tlocal margin',
        "\tmargin=$(demo_config_get '.demo.safety_margin')",
        '\tmargin="${margin:-1.3}"',
        '\tlocal chars=${#1}',
        '\tlocal tokens',
        // The real shape: a printf INSIDE an awk string, whose expression
        // mentions the config var. A check for "any printf referencing it"
        // matches this and mis-classifies the function as an accessor.
        '\ttokens=$(awk "BEGIN { printf \\"%d\\", int($chars * $margin) }")',
        '\tprintf \'%s\' "$tokens"',
        '}',
      ].join('\n'),
    );
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-use.sh',
      [
        '#!/usr/bin/env bash',
        'set -uo pipefail',
        'EST=$(demo_estimate_tokens "$INPUT")',
        'PROJECTED=$(( CONSUMED + EST ))',
      ].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 0, `expected clean, got a false positive:\n${r.stdout}`);
  });
});

// Found while spot-checking the sweep's real output. ONL-132 describes the
// hazard only at (( )), but `[[ v -gt 0 ]]` evaluates its operands
// arithmetically too and dies exactly the same way:
//
//   $ v="not-a-number"; [[ "$v" -gt 0 ]]
//   line 5: not: unbound variable      <- shell stops, status 0
//
// Single-bracket `[ ]` does NOT share it -- test(1) reports "integer
// expression expected", takes the false branch, and execution continues. So
// the distinction is load-bearing and only [[ ]] is reported.
describe('arithmetic comparison inside [[ ]]', () => {
  it('flags a config value compared with [[ -gt ]]', () => {
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-cmp.sh',
      [
        '#!/usr/bin/env bash',
        'set -uo pipefail',
        "MIN=$(demo_config_get '.demo.min')",
        '[[ -z "$MIN" || "$MIN" == "null" ]] && MIN=5',
        'if [[ "$MIN" -gt 0 ]]; then echo positive; fi',
      ].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 1, `expected a finding, got status ${r.status}\n${r.stdout}`);
    assert.match(r.stdout, /MIN/);
  });

  it('does not flag the same comparison in single-bracket [ ]', () => {
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-cmp.sh',
      [
        '#!/usr/bin/env bash',
        'set -uo pipefail',
        "MIN=$(demo_config_get '.demo.min')",
        '[[ -z "$MIN" || "$MIN" == "null" ]] && MIN=5',
        'if [ "$MIN" -gt 0 ]; then echo positive; fi',
      ].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 0, `single-bracket is safe but was flagged:\n${r.stdout}`);
  });

  it('does not flag a string operand sharing a [[ ]] with an arithmetic one', () => {
    // Live false positive on the real tree. curator-session-start.sh:343 is
    //   [[ "$OPEN_COUNT" -eq 0 && "$SKIP_WHEN_ZERO" == "true" ]]
    // Capturing the whole bracket because it contains -eq, then matching any
    // variable inside it, reported SKIP_WHEN_ZERO -- a boolean compared with
    // ==, which is never evaluated arithmetically. Only the operands of the
    // arithmetic operator itself are at risk.
    const root = scaffold();
    writeFile(
      root,
      'plugins/demo/scripts/lib/demo-bool.sh',
      [
        '#!/usr/bin/env bash',
        'set -uo pipefail',
        "SKIP=$(demo_config_get '.demo.skip')",
        '[[ -z "$SKIP" || "$SKIP" == "null" ]] && SKIP="true"',
        'if [[ "$COUNT" -eq 0 && "$SKIP" == "true" ]]; then echo skip; fi',
      ].join('\n'),
    );

    const r = run(root);
    assert.equal(r.status, 0, `string operand flagged as arithmetic:\n${r.stdout}`);
  });
});
