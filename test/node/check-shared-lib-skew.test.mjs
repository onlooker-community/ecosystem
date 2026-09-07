import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SCRIPT = join(REPO, 'scripts', 'lint', 'check-shared-lib-skew.mjs');

// Builds a cache of installed plugins plus the manifest that registers them,
// so the checker sees the same shape it sees in production.
function fleet(plugins, { project = '/proj', register = null } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'skew-'));
  const cache = join(root, 'cache');
  const manifest = { version: 2, plugins: {} };
  for (const [name, { body, path }] of Object.entries(plugins)) {
    const installPath = join(cache, name, path || '1.0.0');
    mkdirSync(join(installPath, 'scripts', 'lib'), { recursive: true });
    writeFileSync(join(installPath, 'scripts', 'lib', 'hook-health.sh'), body);
    manifest.plugins[`${name}@m`] = [{ scope: 'project', projectPath: project, installPath }];
  }
  if (register) register(manifest, cache);
  mkdirSync(join(root, 'cfg', 'plugins'), { recursive: true });
  writeFileSync(join(root, 'cfg', 'plugins', 'installed_plugins.json'), JSON.stringify(manifest));
  return { root, cache, configDir: join(root, 'cfg'), project };
}

function run(fx, extra = []) {
  return execFileSync(process.execPath, [SCRIPT, '--project', fx.project, '--config-dir', fx.configDir, ...extra], {
    encoding: 'utf8',
  });
}

const A = '# lib\n_ONLOOKER_LIB_FINGERPRINT="000000000000"\necho a\n';
const B = '# lib\n_ONLOOKER_LIB_FINGERPRINT="000000000000"\necho b\n';

test('a uniform fleet reports uniform', () => {
  const fx = fleet({ alpha: { body: A }, beta: { body: A } });
  assert.match(run(fx), /uniform/);
});

test('two different copies are reported as skew, naming both sides', () => {
  const fx = fleet({ alpha: { body: A }, beta: { body: B } });
  const out = run(fx);
  assert.match(out, /SKEW across 2 versions/);
  assert.match(out, /alpha/);
  assert.match(out, /beta/);
});

// The fingerprint must depend on content, not on the stamp written into it.
// Otherwise two genuinely different libs that happen to carry the same stale
// stamp would read as uniform -- which is the failure this whole check exists
// to prevent.
test('a stale stamp does not mask a real content difference', () => {
  const stamped = '# lib\n_ONLOOKER_LIB_FINGERPRINT="deadbeefcafe"\necho b\n';
  const fx = fleet({ alpha: { body: A }, beta: { body: stamped } });
  assert.match(run(fx), /SKEW/);
});

test('an identical lib carrying different stamps still reads as uniform', () => {
  const one = '# lib\n_ONLOOKER_LIB_FINGERPRINT="111111111111"\necho a\n';
  const two = '# lib\n_ONLOOKER_LIB_FINGERPRINT="222222222222"\necho a\n';
  const fx = fleet({ alpha: { body: one }, beta: { body: two } });
  assert.match(run(fx), /uniform/);
});

// The registry names which directory is loaded; an unregistered copy sitting in
// the cache is not. Selecting by scanning (or by mtime) picked the wrong
// version for three plugins and reported five false results -- see the issue.
test('an unregistered copy in the cache is ignored', () => {
  const fx = fleet({ alpha: { body: A } });
  const stray = join(fx.cache, 'alpha', '9.9.9', 'scripts', 'lib');
  mkdirSync(stray, { recursive: true });
  writeFileSync(join(stray, 'hook-health.sh'), B);
  assert.match(run(fx), /uniform/);
});

test('installs registered to another project are ignored', () => {
  const fx = fleet({ alpha: { body: A } });
  const other = fleet({ beta: { body: B } }, { project: '/elsewhere' });
  const manifest = JSON.parse(
    execFileSync('cat', [join(fx.configDir, 'plugins', 'installed_plugins.json')], { encoding: 'utf8' }),
  );
  const otherManifest = JSON.parse(
    execFileSync('cat', [join(other.configDir, 'plugins', 'installed_plugins.json')], { encoding: 'utf8' }),
  );
  Object.assign(manifest.plugins, otherManifest.plugins);
  writeFileSync(join(fx.configDir, 'plugins', 'installed_plugins.json'), JSON.stringify(manifest));
  assert.match(run(fx), /uniform/);
});

test('skips rather than fails when no manifest exists', () => {
  const root = mkdtempSync(join(tmpdir(), 'skew-'));
  const out = execFileSync(process.execPath, [SCRIPT, '--project', '/proj', '--config-dir', root], {
    encoding: 'utf8',
  });
  assert.match(out, /skipped \(no manifest/);
});

test('--strict exits non-zero on skew, plain mode does not', () => {
  const fx = fleet({ alpha: { body: A }, beta: { body: B } });
  run(fx);
  assert.throws(() => run(fx, ['--strict']));
});

// The shell and the node implementation must agree, or a record's stamp and the
// skew report would describe the same file differently.
test('matches the shell fingerprint for the real hook-health.sh', () => {
  const shell = execFileSync(
    'bash',
    [
      '-c',
      `source '${join(REPO, 'scripts', 'lib-fingerprint.sh')}'; lib_fingerprint '${join(REPO, 'scripts', 'lib', 'hook-health.sh')}'`,
    ],
    { encoding: 'utf8' },
  ).trim();
  const fx = fleet({
    alpha: { body: execFileSync('cat', [join(REPO, 'scripts', 'lib', 'hook-health.sh')], { encoding: 'utf8' }) },
  });
  assert.match(run(fx), new RegExp(shell));
});
