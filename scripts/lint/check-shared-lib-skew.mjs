#!/usr/bin/env node
// Vendored shared-lib skew detector.
//
// ecosystem-449.31. The shared libs are vendored into every plugin, and plugins
// install independently, so at runtime one session can have the substrate on
// one copy of hook-health.sh and its plugins on another. Records written in
// that window mix two attribution schemes, and nothing in the rollup separates
// them: a session where only the substrate is fixed can read "clean" while its
// plugin rows are still contaminated.
//
// Vendoring is deliberate -- a plugin must work standalone (ADR / ecosystem-ber)
// -- so skew is inherent to the design and cannot be engineered away. It can
// only be observed. Hence detection rather than prevention.
//
// TWO AUTHORITIES, AND NEITHER IS SUFFICIENT ALONE:
//
//   installed_plugins.json  names WHICH directory is actually loaded. Required,
//                           because scanning the cache finds unloaded copies.
//   the file's own bytes    say WHAT IS IN IT. Required, because a directory
//                           name, a package.json version, and a directory mtime
//                           have each been caught disagreeing with the contents
//                           they label -- the last one selected three plugins'
//                           wrong versions and reported five false pre-fix
//                           results (see the issue).
//
// So: hash the lib at each REGISTERED installPath. Never scan, never read a
// version.
//
// Exit codes:
//   0  uniform, or skipped (no manifest)
//   1  skew detected, with --strict
//   2  setup/usage error

import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

const LIBS = ['hook-health.sh', 'config-loader.sh', 'substrate-resolve.sh'];

function parseArgs(argv) {
  const args = { project: null, configDir: null, strict: false, json: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--strict') args.strict = true;
    else if (a === '--json') args.json = true;
    else if (a === '--project') args.project = argv[++i];
    else if (a === '--config-dir') args.configDir = argv[++i];
    else if (a === '--help' || a === '-h') {
      process.stdout.write(
        'usage: check-shared-lib-skew [--project <path>] [--config-dir <path>] [--strict] [--json]\n',
      );
      process.exit(0);
    } else {
      process.stderr.write(`check-shared-lib-skew: unknown argument ${a}\n`);
      process.exit(2);
    }
  }
  return args;
}

// Must match lib_fingerprint() in scripts/lib-fingerprint.sh: sha256 of the
// file with its own fingerprint line neutralized, first 12 hex.
const MARKER = '_ONLOOKER_LIB_FINGERPRINT=';
function fingerprint(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    return null;
  }
  const normalized = text
    .split('\n')
    .map((l) => (l.startsWith(MARKER) ? `${MARKER}PLACEHOLDER` : l))
    .join('\n');
  return createHash('sha256').update(normalized).digest('hex').slice(0, 12);
}

const args = parseArgs(process.argv);
const project = resolve(args.project || process.cwd());
const configDir =
  args.configDir || process.env.CLAUDE_HOME || process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');

const manifestPath = join(configDir, 'plugins', 'installed_plugins.json');
if (!existsSync(manifestPath)) {
  process.stdout.write(`check-shared-lib-skew: skipped (no manifest at ${manifestPath})\n`);
  process.exit(0);
}

let manifest;
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
} catch (err) {
  process.stderr.write(`check-shared-lib-skew: unreadable manifest: ${err.message}\n`);
  process.exit(2);
}

// Every registered install path for this project, plus the repo's own canonical
// copies, which is what a dev session actually loads.
const installs = [];
for (const [key, records] of Object.entries(manifest.plugins || {})) {
  for (const rec of records || []) {
    if (rec.projectPath && resolve(rec.projectPath) !== project) continue;
    if (rec.installPath) installs.push({ name: key.split('@')[0], path: rec.installPath });
  }
}

const byLib = new Map(LIBS.map((l) => [l, new Map()]));
for (const { name, path } of installs) {
  for (const lib of LIBS) {
    // The substrate keeps its libs at scripts/lib; so does every plugin.
    const p = join(path, 'scripts', 'lib', lib);
    if (!existsSync(p)) continue;
    const fp = fingerprint(p);
    if (!fp) continue;
    const m = byLib.get(lib);
    if (!m.has(fp)) m.set(fp, []);
    m.get(fp).push(name);
  }
}

const skewed = [];
const report = {};
for (const [lib, m] of byLib) {
  if (m.size === 0) continue;
  report[lib] = [...m].map(([fp, names]) => ({ fingerprint: fp, plugins: names.sort() }));
  if (m.size > 1) skewed.push(lib);
}

if (args.json) {
  process.stdout.write(`${JSON.stringify({ project, installs: installs.length, report }, null, 2)}\n`);
} else {
  for (const [lib, groups] of Object.entries(report)) {
    if (groups.length === 1) {
      process.stdout.write(`  ${lib.padEnd(22)} uniform ${groups[0].fingerprint} (${groups[0].plugins.length})\n`);
      continue;
    }
    process.stdout.write(`  ${lib.padEnd(22)} SKEW across ${groups.length} versions\n`);
    for (const g of groups) {
      process.stdout.write(`    ${g.fingerprint}  ${g.plugins.join(', ')}\n`);
    }
  }
  if (installs.length === 0) {
    process.stdout.write('check-shared-lib-skew: skipped (no installs registered for this project)\n');
    process.exit(0);
  }
  process.stdout.write(
    skewed.length === 0
      ? `check-shared-lib-skew: uniform (${installs.length} registered install(s))\n`
      : `check-shared-lib-skew: skew in ${skewed.join(', ')} — rollups spanning it mix attribution schemes\n`,
  );
}

process.exit(args.strict && skewed.length > 0 ? 1 : 0);
