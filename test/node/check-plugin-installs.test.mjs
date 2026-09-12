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

/**
 * Write a marketplace clone: .claude-plugin/marketplace.json listing each plugin
 * with a `source` path, and a plugin.json carrying the advertised version at that
 * path. Mirrors the real onlooker-community layout, where the root `./` source is
 * the substrate and everything else lives under plugins/<name>.
 */
function writeMarketplace(configDir, market, versions) {
  const root = join(configDir, 'plugins', 'marketplaces', market);
  const entries = [];
  for (const [name, version] of Object.entries(versions)) {
    const source = name === 'ecosystem' ? './' : `./plugins/${name}`;
    entries.push({ name, source });
    writeJson(join(root, source, '.claude-plugin', 'plugin.json'), { name, version });
  }
  writeJson(join(root, '.claude-plugin', 'marketplace.json'), { name: market, plugins: entries });
  return root;
}

function git(cwd, ...args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}

/** Turn a marketplace clone dir into a git clone of a throwaway origin. */
function makeClone(cloneRoot, originRoot) {
  mkdirSync(originRoot, { recursive: true });
  git(originRoot, 'init', '-q', '-b', 'main');
  git(originRoot, 'config', 'user.email', 't@example.com');
  git(originRoot, 'config', 'user.name', 'Test');
  writeFileSync(join(originRoot, 'README.md'), 'v1\n');
  git(originRoot, 'add', '-A');
  git(originRoot, 'commit', '-qm', 'first');

  git(cloneRoot, 'init', '-q', '-b', 'main');
  git(cloneRoot, 'config', 'user.email', 't@example.com');
  git(cloneRoot, 'config', 'user.name', 'Test');
  git(cloneRoot, 'remote', 'add', 'origin', originRoot);
  git(cloneRoot, 'fetch', '-q', 'origin', 'main');
  git(cloneRoot, 'reset', '-q', '--hard', 'FETCH_HEAD');
  return originRoot;
}

/** Add a commit to origin that the clone has not seen. */
function advanceOrigin(originRoot, msg = 'second') {
  writeFileSync(join(originRoot, 'README.md'), `${msg}\n`);
  git(originRoot, 'add', '-A');
  git(originRoot, 'commit', '-qm', msg);
  return git(originRoot, 'rev-parse', 'HEAD');
}

describe('check-plugin-installs currency (ecosystem-o2s)', () => {
  it('reports project, user, and marketplace versions for every enabled plugin', () => {
    const s = scaffold();
    writeSettings(s.project, { [`scribe${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`scribe${MARKET}`]: [
        { projectPath: s.project, version: '0.8.1' },
        { scope: 'user', version: '0.8.2' },
      ],
    });
    writeMarketplace(s.configDir, 'onlooker-community', { scribe: '0.8.2' });

    const r = run(s, '--json', '--offline');
    const report = JSON.parse(r.stdout);
    const row = report.plugins.find((p) => p.plugin === `scribe${MARKET}`);
    assert.equal(row.project, '0.8.1');
    assert.equal(row.user, '0.8.2');
    assert.equal(row.marketplace, '0.8.2');
  });

  it('fails when a project-scoped pin is older than the user-scope twin', () => {
    const s = scaffold();
    writeSettings(s.project, { [`ecosystem${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`ecosystem${MARKET}`]: [
        { projectPath: s.project, version: '0.54.1' },
        { scope: 'user', version: '0.54.4' },
      ],
    });
    writeMarketplace(s.configDir, 'onlooker-community', { ecosystem: '0.54.4' });

    const r = run(s, '--offline');
    assert.equal(r.code, 1);
    assert.match(r.stderr, /ecosystem@onlooker-community/);
    assert.match(r.stderr, /0\.54\.1/);
    assert.match(r.stderr, /0\.54\.4/);
    assert.match(r.stderr, /shadow/i);
  });

  it('fails when the effective install is older than the marketplace advertises', () => {
    const s = scaffold();
    writeSettings(s.project, { [`librarian${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`librarian${MARKET}`]: [{ projectPath: s.project, version: '0.18.0' }],
    });
    writeMarketplace(s.configDir, 'onlooker-community', { librarian: '0.18.2' });

    const r = run(s, '--json', '--offline');
    assert.equal(r.code, 1);
    const report = JSON.parse(r.stdout);
    const f = report.findings.find((x) => x.plugin === `librarian${MARKET}`);
    assert.equal(f.reason, 'stale_install');
    assert.equal(f.effective, '0.18.0');
    assert.equal(f.available, '0.18.2');
  });

  it('passes when project, user, and marketplace all agree', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`lineage${MARKET}`]: [
        { projectPath: s.project, version: '0.6.1' },
        { scope: 'user', version: '0.6.1' },
      ],
    });
    writeMarketplace(s.configDir, 'onlooker-community', { lineage: '0.6.1' });

    const r = run(s, '--offline');
    assert.equal(r.code, 0, r.stderr);
  });

  it('does not flag a project pin NEWER than the marketplace clone', () => {
    // A locally-built plugin ahead of a lagging clone is not a currency failure.
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`lineage${MARKET}`]: [{ projectPath: s.project, version: '0.7.0' }],
    });
    writeMarketplace(s.configDir, 'onlooker-community', { lineage: '0.6.1' });

    const r = run(s, '--offline');
    assert.equal(r.code, 0, r.stderr);
  });

  it('compares semver numerically, not lexically', () => {
    // '0.54.10' > '0.54.9' numerically but sorts lower as a string.
    const s = scaffold();
    writeSettings(s.project, { [`ecosystem${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`ecosystem${MARKET}`]: [{ projectPath: s.project, version: '0.54.10' }],
    });
    writeMarketplace(s.configDir, 'onlooker-community', { ecosystem: '0.54.9' });

    const r = run(s, '--offline');
    assert.equal(r.code, 0, r.stderr);
  });

  it('tolerates an "unknown" version without crashing or false-flagging', () => {
    const s = scaffold();
    writeSettings(s.project, { [`skill-creator${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`skill-creator${MARKET}`]: [{ projectPath: s.project, version: 'unknown' }],
    });
    writeMarketplace(s.configDir, 'onlooker-community', {});

    const r = run(s, '--offline');
    assert.equal(r.code, 0, r.stderr);
  });

  it('reports the clone last-fetch ATTEMPT from FETCH_HEAD mtime', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`lineage${MARKET}`]: [{ projectPath: s.project, version: '0.6.1' }],
    });
    const clone = writeMarketplace(s.configDir, 'onlooker-community', { lineage: '0.6.1' });
    makeClone(clone, join(s.root, 'origin'));

    const r = run(s, '--json', '--offline');
    const m = JSON.parse(r.stdout).marketplaces.find((x) => x.name === 'onlooker-community');
    assert.ok(m.lastFetchAttempt, 'expected a FETCH_HEAD mtime');
    assert.match(m.lastFetchAttempt, /^\d{4}-\d{2}-\d{2}T/);
  });

  it('flags a clone whose HEAD is behind its live origin', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`lineage${MARKET}`]: [{ projectPath: s.project, version: '0.6.1' }],
    });
    const clone = writeMarketplace(s.configDir, 'onlooker-community', { lineage: '0.6.1' });
    const origin = makeClone(clone, join(s.root, 'origin'));
    const ahead = advanceOrigin(origin);

    const r = run(s, '--json');
    assert.equal(r.code, 1);
    const report = JSON.parse(r.stdout);
    const m = report.marketplaces.find((x) => x.name === 'onlooker-community');
    assert.equal(m.behind, true);
    assert.equal(m.remoteHead, ahead);
    assert.ok(report.findings.some((f) => f.reason === 'clone_behind'));
  });

  it('does NOT use refs/remotes/origin/main, which goes stale independently', () => {
    // Measured 2026-09-11 on the real clone: refs/heads/main was current at the
    // release commit (#315) while refs/remotes/origin/main still pointed at
    // #237. A naive "HEAD !== origin/<branch>" test calls that current clone
    // behind. The companion false-NEGATIVE case — a never-fetched clone whose
    // remote-tracking ref agrees with HEAD and so always looks current — is
    // what the "flags a clone whose HEAD is behind its live origin" test pins,
    // and it is the shape the real outage took. Only a live ls-remote answers
    // both.
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`lineage${MARKET}`]: [{ projectPath: s.project, version: '0.6.1' }],
    });
    const clone = writeMarketplace(s.configDir, 'onlooker-community', { lineage: '0.6.1' });
    const origin = makeClone(clone, join(s.root, 'origin'));

    // Rewind only the remote-tracking ref, leaving refs/heads/main current.
    const first = git(clone, 'rev-parse', 'HEAD');
    advanceOrigin(origin, 'second');
    git(clone, 'fetch', '-q', 'origin', 'main');
    git(clone, 'reset', '-q', '--hard', 'FETCH_HEAD');
    git(clone, 'update-ref', 'refs/remotes/origin/main', first);

    const r = run(s, '--json');
    const m = JSON.parse(r.stdout).marketplaces.find((x) => x.name === 'onlooker-community');
    assert.equal(m.behind, false, 'stale remote-tracking ref must not produce a false positive');
  });

  it('skips the remote probe under --offline and says the answer is unknown', () => {
    const s = scaffold();
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`lineage${MARKET}`]: [{ projectPath: s.project, version: '0.6.1' }],
    });
    const clone = writeMarketplace(s.configDir, 'onlooker-community', { lineage: '0.6.1' });
    makeClone(clone, join(s.root, 'origin'));

    const r = run(s, '--json', '--offline');
    assert.equal(r.code, 0, r.stderr);
    const m = JSON.parse(r.stdout).marketplaces.find((x) => x.name === 'onlooker-community');
    assert.equal(m.behind, null);
  });

  it('prints the three-way table under --report even when everything is current', () => {
    const s = scaffold();
    writeSettings(s.project, { [`scribe${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`scribe${MARKET}`]: [{ projectPath: s.project, version: '0.8.2' }],
    });
    writeMarketplace(s.configDir, 'onlooker-community', { scribe: '0.8.2' });

    const r = run(s, '--report', '--offline');
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /scribe@onlooker-community/);
    assert.match(r.stdout, /0\.8\.2/);
  });
});

describe('check-plugin-installs enabled-scope layering', () => {
  // Claude Code layers user settings under project settings. Reading only the
  // project file hid five running plugins from the currency table on the real
  // machine — bursar, cartographer, counsel, curator and scribe were all
  // enabled at user scope, scribe most consequentially (ecosystem-o2s).
  it('includes plugins enabled in user-scope settings.json', () => {
    const s = scaffold();
    writeJson(join(s.configDir, 'settings.json'), { enabledPlugins: { [`scribe${MARKET}`]: true } });
    writeSettings(s.project, { [`lineage${MARKET}`]: true });
    writeManifest(s.configDir, {
      [`scribe${MARKET}`]: [{ scope: 'user', version: '0.8.2' }],
      [`lineage${MARKET}`]: [{ projectPath: s.project, version: '0.6.1' }],
    });
    writeMarketplace(s.configDir, 'onlooker-community', { scribe: '0.8.2', lineage: '0.6.1' });

    const r = run(s, '--json', '--offline');
    assert.equal(r.code, 0, r.stderr);
    const report = JSON.parse(r.stdout);
    assert.equal(report.enabled, 2);
    assert.ok(
      report.plugins.some((p) => p.plugin === `scribe${MARKET}`),
      'scribe missing from the table',
    );
  });

  it('flags a stale user-scope-enabled plugin that the project file never mentions', () => {
    const s = scaffold();
    writeJson(join(s.configDir, 'settings.json'), { enabledPlugins: { [`scribe${MARKET}`]: true } });
    writeManifest(s.configDir, { [`scribe${MARKET}`]: [{ scope: 'user', version: '0.8.1' }] });
    writeMarketplace(s.configDir, 'onlooker-community', { scribe: '0.8.2' });

    const r = run(s, '--offline');
    assert.equal(r.code, 1);
    assert.match(r.stderr, /scribe@onlooker-community/);
    assert.match(r.stderr, /0\.8\.2/);
  });

  it('lets a project-scope disable override a user-scope enable', () => {
    const s = scaffold();
    writeJson(join(s.configDir, 'settings.json'), { enabledPlugins: { [`compass${MARKET}`]: true } });
    writeSettings(s.project, { [`compass${MARKET}`]: false });
    writeManifest(s.configDir, {});

    const r = run(s, '--json', '--offline');
    assert.equal(r.code, 0, r.stderr);
    assert.equal(JSON.parse(r.stdout).enabled, 0);
  });
});

describe('check-plugin-installs foreign marketplace shapes', () => {
  // Not every marketplace vendors its plugins at a local path. claude-plugins-official
  // uses an object source ({source: 'git-subdir', url, path, ref, sha}), which has no
  // local .claude-plugin/plugin.json to read. Crashed the whole lint on the real
  // machine once user-scope enables brought those marketplaces into range.
  it('survives a marketplace whose plugin source is an object, not a path', () => {
    const s = scaffold();
    writeJson(join(s.configDir, 'settings.json'), { enabledPlugins: { 'vendor@official': true } });
    writeManifest(s.configDir, { 'vendor@official': [{ scope: 'user', version: '1.0.0' }] });
    writeJson(join(s.configDir, 'plugins', 'marketplaces', 'official', '.claude-plugin', 'marketplace.json'), {
      name: 'official',
      plugins: [
        { name: 'vendor', source: { source: 'git-subdir', url: 'https://example.com/x.git', path: 'plugins/vendor' } },
      ],
    });

    const r = run(s, '--json', '--offline');
    assert.equal(r.code, 0, r.stderr);
    const row = JSON.parse(r.stdout).plugins.find((p) => p.plugin === 'vendor@official');
    assert.equal(row.marketplace, null, 'an unreadable source must report null, not crash or guess');
  });

  it('survives a marketplace directory that does not exist at all', () => {
    const s = scaffold();
    writeJson(join(s.configDir, 'settings.json'), { enabledPlugins: { 'ghost@nowhere': true } });
    writeManifest(s.configDir, { 'ghost@nowhere': [{ scope: 'user', version: '1.0.0' }] });

    const r = run(s, '--json', '--offline');
    assert.equal(r.code, 0, r.stderr);
  });

  it('survives a malformed marketplace.json', () => {
    const s = scaffold();
    writeJson(join(s.configDir, 'settings.json'), { enabledPlugins: { 'x@broken': true } });
    writeManifest(s.configDir, { 'x@broken': [{ scope: 'user', version: '1.0.0' }] });
    const p = join(s.configDir, 'plugins', 'marketplaces', 'broken', '.claude-plugin', 'marketplace.json');
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, '{ not json');

    const r = run(s, '--offline');
    assert.equal(r.code, 0, r.stderr);
  });
});
