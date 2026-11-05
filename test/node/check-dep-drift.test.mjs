import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const LINTER = join(REPO_ROOT, 'scripts', 'lint', 'check-dep-drift.mjs');

function writeJson(p, data) {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, `${JSON.stringify(data, null, 2)}\n`);
}

/**
 * A project whose lockfile resolves `locked` ({ 'node_modules/<path>': entry })
 * and whose node_modules holds `installed` ({ '<path>': version }). A version
 * of null leaves the package out of node_modules entirely.
 */
function scaffold(locked, installed, { nodeModules = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'check-dep-drift-'));
  writeJson(join(root, 'package-lock.json'), {
    name: 'fixture',
    lockfileVersion: 3,
    packages: { '': { name: 'fixture' }, ...locked },
  });
  if (nodeModules) mkdirSync(join(root, 'node_modules'), { recursive: true });
  for (const [path, version] of Object.entries(installed)) {
    if (version === null) continue;
    writeJson(join(root, path, 'package.json'), { name: path.split('node_modules/').pop(), version });
  }
  return root;
}

function run(root, ...args) {
  const r = spawnSync('node', [LINTER, '--root', root, ...args], { encoding: 'utf8' });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

describe('check-dep-drift', () => {
  it('passes when every locked package is installed at its locked version', () => {
    const root = scaffold(
      { 'node_modules/ajv': { version: '8.17.1' }, 'node_modules/@onlooker-community/schema': { version: '2.18.1' } },
      { 'node_modules/ajv': '8.17.1', 'node_modules/@onlooker-community/schema': '2.18.1' },
    );
    const r = run(root);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /ok \(2 package\(s\) match the lockfile\)/);
  });

  it('fails on an installed version the lockfile does not resolve, naming both and the remedy', () => {
    // The incident that motivated this: ^2.18.1 declared, 2.18.1 locked, 2.18.0 installed.
    const root = scaffold(
      { 'node_modules/@onlooker-community/schema': { version: '2.18.1' } },
      { 'node_modules/@onlooker-community/schema': '2.18.0' },
    );
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /@onlooker-community\/schema: installed 2\.18\.0, lockfile resolves 2\.18\.1/);
    assert.match(r.stderr, /npm ci/);
  });

  it('fails on a required package missing from node_modules', () => {
    const root = scaffold({ 'node_modules/ajv': { version: '8.17.1' } }, { 'node_modules/ajv': null });
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /ajv: not installed, lockfile resolves 8\.17\.1/);
  });

  it('ignores a missing optional package, the way platform binaries are left out', () => {
    const root = scaffold(
      { 'node_modules/@biomejs/cli-linux-x64': { version: '2.4.15', optional: true } },
      { 'node_modules/@biomejs/cli-linux-x64': null },
    );
    assert.equal(run(root).code, 0);
  });

  it('still checks the version of an optional package that is installed', () => {
    const root = scaffold(
      { 'node_modules/@biomejs/cli-darwin-arm64': { version: '2.4.15', optional: true } },
      { 'node_modules/@biomejs/cli-darwin-arm64': '2.4.14' },
    );
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /cli-darwin-arm64: installed 2\.4\.14, lockfile resolves 2\.4\.15/);
  });

  it('checks a nested copy at its own path, not the hoisted one', () => {
    const root = scaffold(
      {
        'node_modules/ajv': { version: '8.17.1' },
        'node_modules/ajv-formats/node_modules/ajv': { version: '6.12.6' },
      },
      { 'node_modules/ajv': '8.17.1', 'node_modules/ajv-formats/node_modules/ajv': '6.12.5' },
    );
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /ajv-formats\/node_modules\/ajv: installed 6\.12\.5, lockfile resolves 6\.12\.6/);
    assert.doesNotMatch(r.stderr, /^error: ajv:/m);
  });

  it('skips linked packages, whose version lives at the link target', () => {
    const root = scaffold({ 'node_modules/local-pkg': { resolved: 'packages/local-pkg', link: true } }, {});
    assert.equal(run(root).code, 0);
  });

  it('skips when node_modules is absent, and fails under --strict', () => {
    const root = scaffold({ 'node_modules/ajv': { version: '8.17.1' } }, {}, { nodeModules: false });
    const soft = run(root);
    assert.equal(soft.code, 0);
    assert.match(soft.stdout, /skipped \(no node_modules/);
    assert.equal(run(root, '--strict').code, 1);
  });

  it('reports findings as JSON', () => {
    const root = scaffold(
      { 'node_modules/ajv': { version: '8.17.1' }, 'node_modules/yaml': { version: '2.5.0' } },
      { 'node_modules/ajv': '8.16.0', 'node_modules/yaml': null },
    );
    const r = run(root, '--json');
    assert.equal(r.code, 1);
    const report = JSON.parse(r.stdout);
    assert.equal(report.status, 'failed');
    assert.deepEqual(
      report.findings.map((f) => [f.package, f.reason, f.installed, f.locked]),
      [
        ['ajv', 'drifted', '8.16.0', '8.17.1'],
        ['yaml', 'missing', null, '2.5.0'],
      ],
    );
  });
});
