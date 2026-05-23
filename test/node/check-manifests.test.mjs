import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const LINTER = join(REPO_ROOT, 'scripts', 'lint', 'check-manifests.mjs');

function scaffold() {
  const root = mkdtempSync(join(tmpdir(), 'check-manifests-'));
  mkdirSync(join(root, '.claude-plugin'), { recursive: true });
  return root;
}

function writeJson(p, data) {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, `${JSON.stringify(data, null, 2)}\n`);
}

function run(root, ...args) {
  const r = spawnSync('node', [LINTER, '--root', root, ...args], { encoding: 'utf8' });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

const VALID_PLUGIN_JSON = (overrides = {}) => ({
  name: 'sample',
  version: '0.1.0',
  description: 'A sample plugin used by tests.',
  ...overrides,
});

const VALID_MARKETPLACE = (overrides = {}) => ({
  name: 'tm',
  owner: { name: 'Onlooker' },
  plugins: [{ name: 'sample', source: './' }],
  ...overrides,
});

describe('check-manifests', () => {
  it('passes a minimally valid marketplace + plugin', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON());
    const r = run(root);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /ok \(1 plugin/);
  });

  it('errors if marketplace plugin entry carries a version field (drift hazard)', () => {
    const root = scaffold();
    writeJson(
      join(root, '.claude-plugin', 'marketplace.json'),
      VALID_MARKETPLACE({
        plugins: [{ name: 'sample', source: './', version: '0.1.0' }],
      }),
    );
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON());
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /MUST NOT be set in marketplace\.json/);
  });

  it('errors when plugin.json name does not match marketplace name', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON({ name: 'mismatched' }));
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /does not match marketplace entry name/);
  });

  it('errors on non-kebab-case names', () => {
    const root = scaffold();
    writeJson(
      join(root, '.claude-plugin', 'marketplace.json'),
      VALID_MARKETPLACE({ plugins: [{ name: 'Bad_Name', source: './' }] }),
    );
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON({ name: 'Bad_Name' }));
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /must be kebab-case/);
  });

  it('errors on a non-semver version', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON({ version: 'v1' }));
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /not semver-shaped/);
  });

  it('errors when required plugin.json fields are missing', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(join(root, '.claude-plugin', 'plugin.json'), { name: 'sample' });
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /`version` is required/);
    assert.match(r.stderr, /`description` is required/);
  });

  it('warns on unknown fields (typo detection)', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(
      join(root, '.claude-plugin', 'plugin.json'),
      VALID_PLUGIN_JSON({ descripton: 'typo' }), // misspelled
    );
    const r = run(root);
    // Warnings alone do not fail.
    assert.equal(r.code, 0);
    assert.match(r.stderr, /unknown field "descripton"/);
  });

  it('--strict turns warnings into errors', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON({ descripton: 'typo' }));
    const r = run(root, '--strict');
    assert.equal(r.code, 1);
  });

  it('errors when skills field is not an array', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON({ skills: 'oops' }));
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /`skills` must be an array/);
  });

  it('validates hooks.json shape when present', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON());
    writeJson(join(root, 'hooks', 'hooks.json'), { wrong: true });
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /must contain a `hooks` object/);
  });

  it('warns on hook events not recognized by claude code', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), VALID_MARKETPLACE());
    writeJson(join(root, '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON());
    writeJson(join(root, 'hooks', 'hooks.json'), {
      hooks: { GibberishEvent: [{ hooks: [] }] },
    });
    const r = run(root);
    assert.equal(r.code, 0);
    assert.match(r.stderr, /declares unknown event "GibberishEvent"/);
  });

  it('--plugin filters validation to a single plugin', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [
        { name: 'good', source: './good' },
        { name: 'bad', source: './bad' },
      ],
    });
    writeJson(join(root, 'good', '.claude-plugin', 'plugin.json'), VALID_PLUGIN_JSON({ name: 'good' }));
    writeJson(join(root, 'bad', '.claude-plugin', 'plugin.json'), { name: 'bad' }); // missing version + description
    const r = run(root, '--plugin', 'good');
    assert.equal(r.code, 0, r.stderr);
  });
});
