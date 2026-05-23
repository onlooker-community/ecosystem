import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');

function runJson(script, root, ...args) {
  const r = spawnSync('node', [join(REPO_ROOT, script), '--root', root, '--json', ...args], {
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    throw new Error(`${script} exited ${r.status}\nstdout:\n${r.stdout}\nstderr:\n${r.stderr}`);
  }
  return JSON.parse(r.stdout);
}

function scaffoldMarketplace() {
  const root = mkdtempSync(join(tmpdir(), 'coverage-'));
  mkdirSync(join(root, '.claude-plugin'), { recursive: true });
  writeFileSync(
    join(root, '.claude-plugin', 'marketplace.json'),
    JSON.stringify({ name: 't', plugins: [{ name: 's', source: './' }] }),
  );
  return root;
}

function writeFile(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
}

describe('bash-coverage', () => {
  it('returns 100% when every public function is referenced in tests', () => {
    const root = scaffoldMarketplace();
    writeFile(join(root, 'scripts/lib/foo.sh'), `#!/usr/bin/env bash\nfoo() { echo 1; }\nbar() { echo 2; }\n`);
    writeFile(join(root, 'test/bats/foo.bats'), `@test "covers" { foo; bar; }\n`);
    const report = runJson('scripts/coverage/bash-coverage.mjs', root);
    assert.equal(report.overall.total, 2);
    assert.equal(report.overall.tested, 2);
    assert.equal(report.overall.ratio, 1);
  });

  it('drops untested public functions into the untested list', () => {
    const root = scaffoldMarketplace();
    writeFile(join(root, 'scripts/lib/foo.sh'), `#!/usr/bin/env bash\nfoo() { :; }\nbar() { :; }\nbaz() { :; }\n`);
    writeFile(join(root, 'test/bats/foo.bats'), `@test "covers" { foo; }\n`);
    const report = runJson('scripts/coverage/bash-coverage.mjs', root);
    assert.equal(report.overall.tested, 1);
    assert.equal(report.overall.total, 3);
    const untestedNames = report.untested.map((u) => u.name).sort();
    assert.deepEqual(untestedNames, ['bar', 'baz']);
  });

  it('skips private (underscore-prefixed) helpers', () => {
    const root = scaffoldMarketplace();
    writeFile(join(root, 'scripts/lib/foo.sh'), `#!/usr/bin/env bash\nfoo() { :; }\n_internal() { :; }\n`);
    writeFile(join(root, 'test/bats/foo.bats'), `@test "covers foo" { foo; }\n`);
    const report = runJson('scripts/coverage/bash-coverage.mjs', root);
    assert.equal(report.overall.total, 1, JSON.stringify(report));
  });

  it('does not count indented function-looking lines as definitions', () => {
    const root = scaffoldMarketplace();
    writeFile(
      join(root, 'scripts/lib/foo.sh'),
      `#!/usr/bin/env bash\nfoo() {\n  inner() { :; }  # nested, should NOT count\n}\n`,
    );
    writeFile(join(root, 'test/bats/foo.bats'), `@test "covers" { foo; }\n`);
    const report = runJson('scripts/coverage/bash-coverage.mjs', root);
    assert.equal(report.overall.total, 1);
  });

  it('handles repos with no .sh files at all', () => {
    const root = scaffoldMarketplace();
    const report = runJson('scripts/coverage/bash-coverage.mjs', root);
    assert.equal(report.overall.total, 0);
    assert.equal(report.overall.ratio, 1);
  });
});

describe('format-comment', () => {
  function render(nodeReport, bashReport, sha = 'abcdef0123456789') {
    const tmp = mkdtempSync(join(tmpdir(), 'cov-fmt-'));
    const nPath = join(tmp, 'node.json');
    const bPath = join(tmp, 'bash.json');
    writeFileSync(nPath, JSON.stringify(nodeReport));
    writeFileSync(bPath, JSON.stringify(bashReport));
    const r = spawnSync(
      'node',
      [join(REPO_ROOT, 'scripts', 'coverage', 'format-comment.mjs'), '--node', nPath, '--bash', bPath, '--sha', sha],
      { encoding: 'utf8' },
    );
    if (r.status !== 0) throw new Error(`format-comment failed: ${r.stderr}`);
    return r.stdout;
  }

  it('emits the sentinel comment so the upsert logic can find it', () => {
    const out = render(
      { overall: null, files: [] },
      { overall: { total: 0, tested: 0, ratio: 1 }, files: [], untested: [] },
    );
    assert.ok(out.startsWith('<!-- onlooker-coverage-comment -->'));
  });

  it('renders node coverage rows in the markdown table', () => {
    const out = render(
      {
        overall: { file: 'all files', line: 75, branch: 55, funcs: 90, uncoveredLines: '' },
        files: [{ file: 'foo.mjs', line: 75, branch: 50, funcs: 80, uncoveredLines: '12-14' }],
      },
      { overall: { total: 1, tested: 1, ratio: 1 }, files: [], untested: [] },
    );
    assert.match(out, /\| `foo\.mjs` \| 75\.0% \| 50\.0% \| 80\.0% \|/);
    // 75% lines → yellow (60–79 inclusive).
    assert.match(out, /\*\*Overall:\*\* 🟡 75\.0% lines/);
  });

  it('marks bash overall red when below 50%', () => {
    const out = render(
      { overall: null, files: [] },
      { overall: { total: 10, tested: 3, ratio: 0.3 }, files: [], untested: [] },
    );
    assert.match(out, /🔴 3\/10 public functions/);
  });

  it('lists untested functions inside a collapsed details block', () => {
    const out = render(
      { overall: null, files: [] },
      {
        overall: { total: 2, tested: 1, ratio: 0.5 },
        files: [{ file: 'a.sh', total: 2, tested: 1, ratio: 0.5, untested: ['bar'] }],
        untested: [{ file: 'a.sh', name: 'bar' }],
      },
    );
    assert.match(out, /<details><summary>Untested public functions<\/summary>/);
    assert.match(out, /`a\.sh` — `bar`/);
  });
});
