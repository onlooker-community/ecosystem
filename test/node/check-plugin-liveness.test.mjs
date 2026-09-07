import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SCRIPT = join(REPO, 'scripts', 'lint', 'check-plugin-liveness.mjs');

// A fixture project with a git origin, so the script derives a real project key
// the same way tribunal-project-key.sh does. Without a remote the key is empty
// and every event counts as local, which would hide the no_local_events case.
function fixture({ enabled = { 'demo@m': true }, hooks = ['demo-stop'], remote = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'liveness-'));
  const project = join(root, 'project');
  mkdirSync(join(project, '.claude'), { recursive: true });
  writeFileSync(join(project, '.claude', 'settings.json'), JSON.stringify({ enabledPlugins: enabled }));
  for (const plugin of Object.keys(enabled).map((k) => k.split('@')[0])) {
    const dir = plugin === 'ecosystem' ? join(project, 'hooks') : join(project, 'plugins', plugin, 'hooks');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'hooks.json'), JSON.stringify(hooks.map((h) => ({ command: `${h}.sh` }))));
  }
  const git = (...a) => execFileSync('git', ['-C', project, ...a], { stdio: 'ignore' });
  git('init', '-q');
  if (remote) git('remote', 'add', 'origin', 'git@github.com:org/liveness-fixture.git');
  mkdirSync(join(root, 'onlooker', 'logs'), { recursive: true });
  // Empty rather than absent: an absent log is the skip path, and several tests
  // need to read the derived project key back out of --json before writing any
  // records.
  writeFileSync(join(root, 'onlooker', 'logs', 'hook-health.jsonl'), '');
  writeFileSync(join(root, 'onlooker', 'logs', 'onlooker-events.jsonl'), '');
  return { root, project, onlooker: join(root, 'onlooker') };
}

const now = () => new Date().toISOString();

function writeLogs(fx, { health = [], events = [] }) {
  writeFileSync(
    join(fx.onlooker, 'logs', 'hook-health.jsonl'),
    health.map((r) => JSON.stringify({ timestamp: now(), ...r })).join('\n'),
  );
  writeFileSync(
    join(fx.onlooker, 'logs', 'onlooker-events.jsonl'),
    events.map((r) => JSON.stringify({ timestamp: now(), ...r })).join('\n'),
  );
}

function run(fx, extra = []) {
  const out = execFileSync(
    process.execPath,
    [SCRIPT, '--project', fx.project, '--onlooker-dir', fx.onlooker, '--json', ...extra],
    { encoding: 'utf8' },
  );
  return JSON.parse(out);
}

function verdictOf(fx, extra = []) {
  return run(fx, extra).rows.find((r) => r.plugin === 'demo').verdict;
}

test('skips when the logs are absent, rather than failing', () => {
  const root = mkdtempSync(join(tmpdir(), 'liveness-'));
  const project = join(root, 'project');
  mkdirSync(join(project, '.claude'), { recursive: true });
  writeFileSync(join(project, '.claude', 'settings.json'), JSON.stringify({ enabledPlugins: { 'demo@m': true } }));
  const out = execFileSync(process.execPath, [SCRIPT, '--project', project, '--onlooker-dir', join(root, 'nope')], {
    encoding: 'utf8',
  });
  assert.match(out, /skipped \(no logs/);
});

test('a plugin whose declared hooks never ran is not_running, not a broken emitter', () => {
  const fx = fixture();
  writeLogs(fx, { health: [{ hook: 'someone-else' }], events: [] });
  assert.equal(verdictOf(fx), 'not_running');
});

test('hooks running with events for this project is live', () => {
  const fx = fixture();
  const key = run(fx).project_key;
  writeLogs(fx, {
    health: [{ hook: 'demo-stop' }],
    events: [{ plugin: 'demo', payload: { project_key: key } }],
  });
  assert.equal(verdictOf(fx), 'live');
});

// The distinction this whole script exists for: emitting elsewhere is a fact
// about where the work happens, not a fault (ecosystem-449.28).
test('events for a different project read as no_local_events, not silent', () => {
  const fx = fixture();
  writeLogs(fx, {
    health: [{ hook: 'demo-stop' }],
    events: [{ plugin: 'demo', payload: { project_key: 'ffffffffffff' } }],
  });
  assert.equal(verdictOf(fx), 'no_local_events');
});

test('hooks running with no events anywhere is silent', () => {
  const fx = fixture();
  writeLogs(fx, { health: [{ hook: 'demo-stop' }], events: [] });
  assert.equal(verdictOf(fx), 'silent');
});

// Hook names come from hooks.json, not from a `<plugin>-` prefix. The substrate
// is the case that proves it: its hooks are named tool-sequence-tracker and the
// like, and a prefix rule reported the whole plugin dead.
test('a hook not named after its plugin is still attributed to it', () => {
  const fx = fixture({ enabled: { 'ecosystem@m': true }, hooks: ['tool-sequence-tracker'] });
  writeLogs(fx, { health: [{ hook: 'tool-sequence-tracker' }], events: [] });
  assert.equal(run(fx).rows.find((r) => r.plugin === 'ecosystem').verdict, 'silent');
});

// The substrate stamps plugin:"onlooker" while being enabled as "ecosystem".
test('substrate events stamped onlooker count for ecosystem', () => {
  const fx = fixture({ enabled: { 'ecosystem@m': true }, hooks: ['turn-tracker'] });
  const key = run(fx).project_key;
  writeLogs(fx, {
    health: [{ hook: 'turn-tracker' }],
    events: [{ plugin: 'onlooker', payload: { project_key: key } }],
  });
  assert.equal(run(fx).rows.find((r) => r.plugin === 'ecosystem').verdict, 'live');
});

test('records older than the window are excluded', () => {
  const fx = fixture();
  const old = new Date(Date.now() - 90 * 86400000).toISOString();
  writeFileSync(join(fx.onlooker, 'logs', 'hook-health.jsonl'), JSON.stringify({ timestamp: old, hook: 'demo-stop' }));
  writeFileSync(join(fx.onlooker, 'logs', 'onlooker-events.jsonl'), '');
  assert.equal(verdictOf(fx, ['--since', '30']), 'not_running');
  assert.equal(verdictOf(fx, ['--since', '365']), 'silent');
});

test('--strict exits non-zero on findings, plain mode does not', () => {
  const fx = fixture();
  writeLogs(fx, { health: [{ hook: 'demo-stop' }], events: [] });
  execFileSync(process.execPath, [SCRIPT, '--project', fx.project, '--onlooker-dir', fx.onlooker], {
    encoding: 'utf8',
  });
  assert.throws(() =>
    execFileSync(process.execPath, [SCRIPT, '--project', fx.project, '--onlooker-dir', fx.onlooker, '--strict'], {
      encoding: 'utf8',
      stdio: 'pipe',
    }),
  );
});

test('a torn final log line is skipped rather than fatal', () => {
  const fx = fixture();
  const key = run(fx).project_key;
  writeFileSync(
    join(fx.onlooker, 'logs', 'hook-health.jsonl'),
    `${JSON.stringify({ timestamp: now(), hook: 'demo-stop' })}\n{"timestamp":"2026`,
  );
  writeFileSync(
    join(fx.onlooker, 'logs', 'onlooker-events.jsonl'),
    JSON.stringify({ timestamp: now(), plugin: 'demo', payload: { project_key: key } }),
  );
  assert.equal(verdictOf(fx), 'live');
});
