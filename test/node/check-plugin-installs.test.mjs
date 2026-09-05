import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const LINTER = join(REPO_ROOT, 'scripts', 'lint', 'check-plugin-installs.mjs');

const MARKET = '@onlooker-community';

function scaffold() {
  const root = mkdtempSync(join(tmpdir(), 'check-plugin-installs-'));
  const project = join(root, 'project');
  const configDir = join(root, 'claude');
  mkdirSync(join(project, '.claude'), { recursive: true });
  mkdirSync(join(configDir, 'plugins'), { recursive: true });
  return { root, project, configDir };
}

function writeJson(p, data) {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, `${JSON.stringify(data, null, 2)}\n`);
}

function writeSettings(project, enabledPlugins, { local = false } = {}) {
  const name = local ? 'settings.local.json' : 'settings.json';
  writeJson(join(project, '.claude', name), { enabledPlugins });
}

/**
 * Build an installed_plugins.json. Each entry is [name, {scope, projectPath}].
 * A project-scoped entry defaults to the scaffolded project path.
 */
function writeManifest(configDir, entries) {
  const plugins = {};
  for (const [name, records] of Object.entries(entries)) {
    plugins[name] = records.map((r) => ({
      scope: r.scope ?? 'project',
      ...(r.scope === 'user' ? {} : { projectPath: r.projectPath }),
      installPath: r.installPath ?? '/tmp/cache/x',
      version: r.version ?? '1.0.0',
      installedAt: '2026-08-30T14:43:05.000Z',
      lastUpdated: '2026-09-05T18:00:00.000Z',
    }));
  }
  writeJson(join(configDir, 'plugins', 'installed_plugins.json'), { version: 2, plugins });
}

function run({ project, configDir }, ...args) {
  const r = spawnSync('node', [LINTER, '--project', project, '--config-dir', configDir, ...args], {
    encoding: 'utf8',
    // Keep the ambient CLAUDE_* vars from leaking into the run.
    env: { ...process.env, CLAUDE_HOME: '', CLAUDE_CONFIG_DIR: '' },
  });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

describe('check-plugin-installs', () => {
  it('passes when every enabled plugin has an install record for this project', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true, [`inspector${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`lineage${MARKET}`]: [{ projectPath: s.project }],
      [`inspector${MARKET}`]: [{ projectPath: s.project }],
    });

    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /ok \(2 enabled/);
  });

  it('fails and names a plugin enabled with no install record at all', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true, [`cartographer${MARKET}`]: true });
    writeManifest(s.configDir, { [`lineage${MARKET}`]: [{ projectPath: s.project }] });

    const r = run(s);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /cartographer@onlooker-community/);
    assert.match(r.stderr, /never installed/i);
    // The healthy plugin must not be reported.
    assert.doesNotMatch(r.stderr, /lineage@onlooker-community/);
  });

  it('fails distinctly when a plugin is installed only for a different project', () => {
    const s = scaffold();
    const otherProject = join(s.root, 'other-repo');
    mkdirSync(otherProject, { recursive: true });
    writeSettings(s.project, { [`bursar${MARKET}`]: true });
    writeManifest(s.configDir, { [`bursar${MARKET}`]: [{ projectPath: otherProject }] });

    const r = run(s);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /bursar@onlooker-community/);
    // Distinguishable from the never-installed case, and it should say where.
    assert.match(r.stderr, /installed for a different project/i);
    assert.match(r.stderr, /other-repo/);
  });

  it('accepts a user-scoped install as satisfying any project', () => {
    const s = scaffold();
    writeSettings(s.project, { [`superpowers${MARKET}`]: true });
    writeManifest(s.configDir, { [`superpowers${MARKET}`]: [{ scope: 'user' }] });

    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
  });

  it('ignores plugins explicitly disabled in settings', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true, [`compass${MARKET}`]: false });
    writeManifest(s.configDir, { [`lineage${MARKET}`]: [{ projectPath: s.project }] });

    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
    assert.doesNotMatch(r.stderr, /compass/);
  });

  it('merges settings.local.json over settings.json', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    writeSettings(s.project, { [`scribe${MARKET}`]: true }, { local: true });
    writeManifest(s.configDir, { [`lineage${MARKET}`]: [{ projectPath: s.project }] });

    const r = run(s);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /scribe@onlooker-community/);
  });

  it('skips cleanly when the install manifest is absent (fresh machine / CI)', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    // No installed_plugins.json written.

    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /skip/i);
  });

  it('treats an absent install manifest as an error under --strict', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });

    const r = run(s, '--strict');
    assert.equal(r.code, 1);
    assert.match(r.stderr, /installed_plugins\.json/);
  });

  it('skips cleanly when the project enables no plugins', () => {
    const s = scaffold();
    writeJson(join(s.project, '.claude', 'settings.json'), { hooks: {} });
    writeManifest(s.configDir, {});

    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
  });

  it('skips cleanly when the project has no .claude/settings.json', () => {
    const s = scaffold();
    writeManifest(s.configDir, {});

    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
  });

  it('emits machine-readable findings under --json', () => {
    const s = scaffold();
    writeSettings(s.project, { [`cartographer${MARKET}`]: true, [`lineage${MARKET}`]: true });
    writeManifest(s.configDir, { [`lineage${MARKET}`]: [{ projectPath: s.project }] });

    const r = run(s, '--json');
    assert.equal(r.code, 1);
    const report = JSON.parse(r.stdout);
    assert.equal(report.enabled, 2);
    assert.equal(report.findings.length, 1);
    assert.equal(report.findings[0].plugin, `cartographer${MARKET}`);
    assert.equal(report.findings[0].reason, 'not_installed');
  });

  it('reports every offender, not just the first', () => {
    const s = scaffold();
    writeSettings(s.project, {
      [`archivist${MARKET}`]: true,
      [`cartographer${MARKET}`]: true,
      [`scribe${MARKET}`]: true,
      [`counsel${MARKET}`]: true,
    });
    writeManifest(s.configDir, {});

    const r = run(s, '--json');
    assert.equal(r.code, 1);
    const report = JSON.parse(r.stdout);
    assert.equal(report.findings.length, 4);
  });
});
