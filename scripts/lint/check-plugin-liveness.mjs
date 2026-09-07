#!/usr/bin/env node
// Liveness checker for enabled Claude Code plugins.
//
// check-plugin-installs answers "is this plugin installed?". That is necessary
// and not sufficient: a plugin can be enabled, installed, and still contribute
// nothing, either because its hooks never run or because they run and their
// events go nowhere. Those two need opposite fixes and look identical in the
// event log, which is how ecosystem-449.34 came to be diagnosed as a broken
// emitter for two plugins that were simply never loaded.
//
// Two sources, because neither answers it alone:
//
//   hook-health.jsonl      did this plugin's hooks RUN? Carries no project
//                          field, so this is a machine-wide answer.
//   onlooker-events.jsonl  did it EMIT, and for which project? Carries both a
//                          `plugin` field and a payload project_key.
//
// NEITHER SIDE IS MATCHED BY NAMING CONVENTION, because the convention does not
// hold. A first version of this script assumed hooks are named `<plugin>-*` and
// event types are `<plugin>.<noun>.<verb>`, per CLAUDE.md. It produced three
// findings and all three were false:
//
//   ecosystem  hooks are tool-sequence-tracker, turn-tracker and friends, and
//              it emits canonical types (tool.*, memory.*) stamped
//              plugin:"onlooker" -- so the substrate looked entirely dead.
//   archivist  emits onlooker.artifact.ready, not archivist.*, so its events
//              were invisible and it looked like a broken emitter.
//   echo       emits, just not for this project -- a fact about where the work
//              happens (ecosystem-449.28), not a fault.
//
// So hooks come from each plugin's own hooks/hooks.json and events are
// attributed by the record's own `plugin` field. Declarations, not guesses.
//
//   hooks  events          verdict           meaning
//   ---------------------------------------------------------------------
//    no    -               not_running       never loaded; an enablement or
//                                            install question
//    yes   none anywhere   silent            hooks run, nothing comes out --
//                                            either the 449.34 class, or these
//                                            hooks have no emit site on the
//                                            path taken. Needs a human look.
//    yes   elsewhere only  no_local_events   works, but this repo is not where
//                                            it runs (449.28)
//    yes   here            live              working
//
// `silent` is a question, not a verdict, and the window is why. archivist-inject
// has no emit site at all, and echo only emits when it actually grades
// something, so both read silent over 30 days and live over 3650. Widen --since
// before concluding anything about a low-frequency hook (PreCompact, Stop gates).
//
// Fails soft by design: these logs are local user state absent in CI, so a
// missing log is a skip. --strict turns findings into a non-zero exit for a
// local wave-readiness check.
//
// Exit codes:
//   0  ok, skipped, or findings without --strict
//   1  findings, with --strict
//   2  setup/usage error

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

function parseArgs(argv) {
  const args = { project: null, onlookerDir: null, since: 30, strict: false, json: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--strict') args.strict = true;
    else if (a === '--json') args.json = true;
    else if (a === '--project') args.project = argv[++i];
    else if (a === '--onlooker-dir') args.onlookerDir = argv[++i];
    else if (a === '--since') args.since = Number(argv[++i]);
    else if (a === '--help' || a === '-h') {
      process.stdout.write(
        'usage: check-plugin-liveness [--project <path>] [--onlooker-dir <path>] ' +
          '[--since <days>] [--strict] [--json]\n',
      );
      process.exit(0);
    } else {
      process.stderr.write(`check-plugin-liveness: unknown argument ${a}\n`);
      process.exit(2);
    }
  }
  if (!Number.isFinite(args.since) || args.since <= 0) {
    process.stderr.write('check-plugin-liveness: --since must be a positive number of days\n');
    process.exit(2);
  }
  return args;
}

// Mirrors tribunal-project-key.sh: sha256("remote:<origin-url>") first 12 hex,
// falling back to sha256("root:<realpath of toplevel>").
function projectKey(projectRoot) {
  const first12 = (s) => createHash('sha256').update(s).digest('hex').slice(0, 12);
  const git = (...a) => {
    try {
      return execFileSync('git', ['-C', projectRoot, ...a], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      }).trim();
    } catch {
      return '';
    }
  };
  const remote = git('remote', 'get-url', 'origin');
  if (remote) return first12(`remote:${remote}`);
  const top = git('rev-parse', '--show-toplevel');
  if (!top) return '';
  let real = top;
  try {
    real = realpathSync(top);
  } catch {
    /* fall back to the unresolved path */
  }
  return first12(`root:${real}`);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

// Scan a JSONL log once. Malformed lines are skipped rather than fatal: these
// logs are appended to by concurrent hooks and a torn final line is normal.
function scanJsonl(path, cutoffMs, onRecord) {
  if (!existsSync(path)) return false;
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    return false;
  }
  for (const line of text.split('\n')) {
    if (!line) continue;
    let rec;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    const ts = Date.parse(rec.timestamp || '');
    if (Number.isFinite(ts) && ts < cutoffMs) continue;
    onRecord(rec);
  }
  return true;
}

const args = parseArgs(process.argv);
const project = resolve(args.project || process.cwd());
const onlookerDir = args.onlookerDir || process.env.ONLOOKER_DIR || join(homedir(), '.onlooker');

const settings = readJson(join(project, '.claude', 'settings.json'));
const enabled = Object.entries(settings?.enabledPlugins || {})
  .filter(([, on]) => on)
  .map(([key]) => key.split('@')[0]);

if (enabled.length === 0) {
  process.stdout.write('check-plugin-liveness: skipped (no enabled plugins)\n');
  process.exit(0);
}

// Hook script basenames each plugin declares. The substrate's hooks.json lives
// at the repo root rather than under plugins/.
function declaredHooks(plugin) {
  const path =
    plugin === 'ecosystem'
      ? join(project, 'hooks', 'hooks.json')
      : join(project, 'plugins', plugin, 'hooks', 'hooks.json');
  if (!existsSync(path)) return [];
  try {
    return [...readFileSync(path, 'utf8').matchAll(/([a-z0-9-]+)\.sh/g)].map((m) => m[1]);
  } catch {
    return [];
  }
}

// The substrate is enabled as "ecosystem" but stamps its events plugin:"onlooker".
const EMITTER_ALIAS = new Map([['ecosystem', 'onlooker']]);

const hookOwner = new Map();
for (const plugin of enabled) {
  for (const hook of declaredHooks(plugin)) hookOwner.set(hook, plugin);
}
const byEmitter = new Map(enabled.map((p) => [EMITTER_ALIAS.get(p) || p, p]));

const cutoff = Date.now() - args.since * 86400000;
const key = projectKey(project);
const hookCounts = new Map();
const eventsHere = new Map();
const eventsAnywhere = new Map();

const sawHealth = scanJsonl(join(onlookerDir, 'logs', 'hook-health.jsonl'), cutoff, (r) => {
  const plugin = hookOwner.get(typeof r.hook === 'string' ? r.hook : '');
  if (plugin) hookCounts.set(plugin, (hookCounts.get(plugin) || 0) + 1);
});

const sawEvents = scanJsonl(join(onlookerDir, 'logs', 'onlooker-events.jsonl'), cutoff, (r) => {
  const plugin = byEmitter.get(typeof r.plugin === 'string' ? r.plugin : '');
  if (!plugin) return;
  eventsAnywhere.set(plugin, (eventsAnywhere.get(plugin) || 0) + 1);
  // Events with no project_key count as local: attributing them to some other
  // repo would be a guess, and over-counting here is the safer error.
  const pk = r.payload?.project_key;
  if (key && pk && pk !== key) return;
  eventsHere.set(plugin, (eventsHere.get(plugin) || 0) + 1);
});

if (!sawHealth && !sawEvents) {
  process.stdout.write(`check-plugin-liveness: skipped (no logs under ${onlookerDir})\n`);
  process.exit(0);
}

const rows = enabled.map((plugin) => {
  const hooks = hookCounts.get(plugin) || 0;
  const here = eventsHere.get(plugin) || 0;
  const anywhere = eventsAnywhere.get(plugin) || 0;
  let verdict;
  if (hooks === 0) verdict = 'not_running';
  else if (anywhere === 0) verdict = 'silent';
  else if (here === 0) verdict = 'no_local_events';
  else verdict = 'live';
  return { plugin, hooks, here, anywhere, verdict };
});

const findings = rows.filter((r) => r.verdict !== 'live');

if (args.json) {
  process.stdout.write(`${JSON.stringify({ project, project_key: key, since_days: args.since, rows }, null, 2)}\n`);
} else {
  for (const r of rows) {
    process.stdout.write(
      `  ${r.plugin.padEnd(14)} hooks=${String(r.hooks).padEnd(6)} ` +
        `here=${String(r.here).padEnd(6)} anywhere=${String(r.anywhere).padEnd(7)} ${r.verdict}\n`,
    );
  }
  process.stdout.write(
    `check-plugin-liveness: ${findings.length === 0 ? 'ok' : `${findings.length} finding(s)`} ` +
      `(${enabled.length} enabled, last ${args.since}d, key ${key || 'unknown'})\n`,
  );
  for (const r of findings) {
    if (r.verdict === 'silent') {
      process.stdout.write(
        `  ${r.plugin}: hooks ran ${r.hooks}x, emitted nothing in ${args.since}d — broken emitter, or no emit site on the path taken; try a wider --since\n`,
      );
    } else if (r.verdict === 'not_running') {
      process.stdout.write(`  ${r.plugin}: no declared hook ran — check enablement and install, not the emitter\n`);
    } else {
      process.stdout.write(
        `  ${r.plugin}: emitted ${r.anywhere} event(s), none for this project — ` + `this repo is not where it runs\n`,
      );
    }
  }
}

process.exit(args.strict && findings.length > 0 ? 1 : 0);
