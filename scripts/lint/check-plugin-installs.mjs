#!/usr/bin/env node

// Install-state checker for Claude Code plugins.
//
// Catches the failure mode that made two dogfooding waves silently soak
// nothing (ecosystem-449.10, ecosystem-449.26): a plugin listed under
// `enabledPlugins` in a project's .claude/settings.json that has no install
// record in installed_plugins.json. Enabling a plugin auto-updates one that is
// already installed, but it never installs a new one — so the edit is a silent
// no-op. Nothing errors, no hook fires, and the gap is only discoverable weeks
// later by noticing an empty event log.
//
// It also checks CURRENCY, not just presence (ecosystem-o2s). Presence alone
// returned "ok" through a 21-hour outage in which every released fix reached
// the marketplace, was installed, and still never ran. Three layers stacked,
// all silent:
//
//   1. the marketplace clone was not being fetched, so it advertised an old
//      release;
//   2. installed_plugins.json keeps one record per projectPath plus a user
//      record, and the project record WINS — so a stale project pin shadows a
//      newer user-scope twin;
//   3. a process runs whatever was pinned when it started.
//
// Findings:
//
//   not_installed        no install record under any scope — the plugin was
//                        enabled but never installed anywhere.
//   installed_elsewhere  installed, but only project-scoped to a different
//                        projectPath. Enabled here, running there.
//   stale_install        installed for this project, but older than a version
//                        available at user scope (shadowing) or advertised by
//                        the marketplace clone (stale pin).
//   clone_behind         the marketplace clone's checked-out branch is behind
//                        its live origin, so every install from it is stale.
//
// Fails soft by design. installed_plugins.json is local user state and does
// not exist in CI or on a fresh clone, so an absent manifest is a skip, not a
// failure. Use --strict to demand it (for a local wave-readiness check).
//
// Exit codes:
//   0  ok, or skipped (no manifest / no enabled plugins)
//   1  one or more plugins enabled without a matching install, or stale
//   2  setup/usage error
//
// Flags:
//   --project <path>     project root to check (default: cwd)
//   --config-dir <path>  Claude config dir holding plugins/installed_plugins.json
//                        (default: $CLAUDE_HOME, else $CLAUDE_CONFIG_DIR, else ~/.claude)
//   --strict             treat an absent install manifest as an error
//   --offline            skip the network probe of each marketplace's origin
//   --report             always print the project/user/marketplace version table
//   --json               emit the report as JSON on stdout

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join, resolve } from 'node:path';

function parseArgs(argv) {
  const args = {
    project: null,
    configDir: null,
    strict: false,
    json: false,
    offline: false,
    report: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--strict') args.strict = true;
    else if (a === '--json') args.json = true;
    else if (a === '--offline') args.offline = true;
    else if (a === '--report') args.report = true;
    else if (a === '--project') args.project = argv[++i];
    else if (a === '--config-dir') args.configDir = argv[++i];
    else if (a === '--help' || a === '-h') {
      process.stdout.write(
        'usage: check-plugin-installs [--project <path>] [--config-dir <path>] [--strict] [--offline] [--report] [--json]\n',
      );
      process.exit(0);
    } else {
      process.stderr.write(`check-plugin-installs: unknown argument ${a}\n`);
      process.exit(2);
    }
  }
  return args;
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    process.stderr.write(`check-plugin-installs: cannot read ${label} (${path}): ${err.message}\n`);
    process.exit(2);
  }
}

// Best-effort read for files the check merely inspects (a marketplace manifest,
// a plugin.json). A malformed one degrades that plugin's row to "unknown"; it
// must not take the whole lint down.
function tryReadJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

// Compare paths through realpath so a symlinked tmpdir or /var -> /private/var
// on macOS does not read as a different project. Falls back to resolve() when
// the path no longer exists — a stale manifest entry still deserves a report.
function canonical(p) {
  const abs = resolve(p);
  try {
    return realpathSync(abs);
  } catch {
    return abs;
  }
}

// Resolution order matches scripts/lib/config-loader.sh and validate-path.sh:
// CLAUDE_HOME wins, then CLAUDE_CONFIG_DIR (what Claude Code exports to hook
// processes), then the default. Empty strings are treated as unset.
function resolveConfigDir(override) {
  if (override) return override;
  return process.env.CLAUDE_HOME || process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
}

// Claude Code layers user settings, then the project's settings.json, then its
// settings.local.json — each overriding the last. Mirror that whole stack so we
// check what actually takes effect.
//
// Reading only the project file is not enough: on the machine that motivated
// this check, five running plugins (bursar, cartographer, counsel, curator and
// scribe) were enabled at USER scope and never appeared in the project file, so
// a project-only read reported them as not enabled and never checked their
// currency. scribe was among them, which is precisely the plugin whose staleness
// the whole investigation was chasing.
function readEnabledPlugins(projectRoot, configDir) {
  const enabled = {};
  let sawSettings = false;
  const sources = [
    [join(configDir, 'settings.json'), 'user settings.json'],
    [join(projectRoot, '.claude', 'settings.json'), 'settings.json'],
    [join(projectRoot, '.claude', 'settings.local.json'), 'settings.local.json'],
  ];
  for (const [path, label] of sources) {
    if (!existsSync(path)) continue;
    sawSettings = true;
    const settings = readJson(path, label);
    Object.assign(enabled, settings.enabledPlugins ?? {});
  }
  return { enabled, sawSettings };
}

function classify(records, projectRoot) {
  if (!Array.isArray(records) || records.length === 0) return { reason: 'not_installed' };

  const elsewhere = [];
  for (const record of records) {
    if (record?.scope === 'user') return null; // user scope satisfies every project
    if (record?.projectPath && canonical(record.projectPath) === projectRoot) return null;
    if (record?.projectPath) elsewhere.push(record.projectPath);
  }

  if (elsewhere.length > 0) return { reason: 'installed_elsewhere', installedFor: elsewhere };
  return { reason: 'not_installed' };
}

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

// Parse a dotted numeric version into comparable parts. Returns null for
// anything that is not one — installed_plugins.json really does carry
// "version": "unknown" for some records, and a non-version must never be
// ordered against a real one.
function parseVersion(v) {
  if (typeof v !== 'string') return null;
  const core = v.trim().replace(/^v/, '').split(/[-+]/)[0];
  if (!/^\d+(\.\d+)*$/.test(core)) return null;
  return core.split('.').map(Number);
}

// -1 / 0 / 1, or null when either side is not a comparable version. Compares
// numerically: '0.54.10' is NEWER than '0.54.9', though it sorts lower as text.
function compareVersions(a, b) {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (!pa || !pb) return null;
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

// A plugin key is "<name>@<marketplace>"; split on the LAST '@' so a scoped
// name survives.
function splitPluginKey(key) {
  const at = key.lastIndexOf('@');
  if (at <= 0) return { name: key, marketplace: null };
  return { name: key.slice(0, at), marketplace: key.slice(at + 1) };
}

// Versions the marketplace clone advertises, read from each plugin's own
// .claude-plugin/plugin.json at the `source` path marketplace.json gives it.
// marketplace.json itself carries no version field, so the per-plugin manifest
// is the only source.
function readMarketplaceVersions(configDir, marketplace) {
  const root = join(configDir, 'plugins', 'marketplaces', marketplace);
  const manifest = tryReadJson(join(root, '.claude-plugin', 'marketplace.json'));
  const versions = {};
  if (!manifest || !Array.isArray(manifest.plugins)) return { root, versions };
  for (const entry of manifest.plugins) {
    if (!entry?.name) continue;
    const source = entry.source ?? './';
    // `source` is a local path only in the vendored-subdirectory style. Other
    // marketplaces (claude-plugins-official) use an object form such as
    // {source: 'git-subdir', url, path, ref, sha}, which resolves to nothing on
    // disk — there is no local plugin.json, so the advertised version is simply
    // not knowable here. Report null rather than guessing; an object passed to
    // join() throws and took the whole lint down.
    if (typeof source !== 'string') continue;
    const pluginJson = tryReadJson(join(root, source, '.claude-plugin', 'plugin.json'));
    if (pluginJson?.version) versions[entry.name] = pluginJson.version;
  }
  return { root, versions };
}

// ---------------------------------------------------------------------------
// Marketplace clone state
// ---------------------------------------------------------------------------

function git(cwd, args, timeout = 10000) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8', timeout });
  if (r.status !== 0) return null;
  return r.stdout.trim();
}

/**
 * Is this clone behind the branch it tracks?
 *
 * Deliberately probes the LIVE remote with ls-remote rather than reading
 * refs/remotes/origin/<branch>. That ref is a cache of the last fetch, so it
 * cannot detect the very thing this check exists to catch: a clone that is not
 * being fetched. When no fetch happens, the remote-tracking ref keeps agreeing
 * with the local branch and the clone reports "current" no matter how far the
 * real origin has moved — which is exactly how a 21-hour staleness went unseen.
 *
 * It also drifts the other way. Measured 2026-09-11 on the real
 * onlooker-community clone, refs/heads/main sat at the current release commit
 * (#315) while refs/remotes/origin/main still pointed at #237; a naive
 * "HEAD !== origin/<branch>" test calls that current clone behind.
 *
 * lastFetchAttempt comes from FETCH_HEAD's mtime, which records the last fetch
 * ATTEMPT. The reflog cannot answer this: it logs only fetches that MOVED a
 * ref, so it cannot distinguish "checked, already current" from "never checked"
 * — and "never checked" was the actual defect.
 */
function cloneState(root, { offline }) {
  const state = { path: root, head: null, branch: null, remoteHead: null, behind: null, lastFetchAttempt: null };
  if (!existsSync(join(root, '.git'))) return state;

  state.head = git(root, ['rev-parse', 'HEAD']);
  state.branch = git(root, ['symbolic-ref', '--short', 'HEAD']) ?? 'main';

  const fetchHead = join(root, '.git', 'FETCH_HEAD');
  if (existsSync(fetchHead)) {
    try {
      state.lastFetchAttempt = new Date(statSync(fetchHead).mtimeMs).toISOString();
    } catch {
      /* unreadable stat is not worth failing the lint over */
    }
  }

  if (offline || !state.head) return state;

  const line = git(root, ['ls-remote', 'origin', state.branch]);
  if (line === null) return state; // no network, no remote — answer stays unknown
  const remoteHead = line.split(/\s+/)[0] || null;
  state.remoteHead = remoteHead;
  if (!remoteHead) return state;

  if (remoteHead === state.head) {
    state.behind = false;
    return state;
  }
  // The remote moved. If we do not even have its commit locally we are behind;
  // if we do, we are behind only when ours is an ancestor of theirs.
  const haveIt = git(root, ['cat-file', '-e', `${remoteHead}^{commit}`]) !== null;
  state.behind = haveIt
    ? spawnSync('git', ['merge-base', '--is-ancestor', state.head, remoteHead], { cwd: root }).status === 0
    : true;
  return state;
}

// ---------------------------------------------------------------------------

function main() {
  const args = parseArgs(process.argv);
  const projectRoot = canonical(args.project ?? process.cwd());
  const configDir = resolveConfigDir(args.configDir);
  const manifestPath = join(configDir, 'plugins', 'installed_plugins.json');

  const { enabled, sawSettings } = readEnabledPlugins(projectRoot, configDir);
  const enabledNames = Object.keys(enabled).filter((name) => enabled[name] === true);

  const report = {
    project: projectRoot,
    manifest: manifestPath,
    enabled: enabledNames.length,
    plugins: [],
    marketplaces: [],
    findings: [],
  };

  const finish = (code) => {
    if (args.json) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    process.exit(code);
  };

  // Nothing enabled (or no settings at all) — nothing this check can assert.
  if (enabledNames.length === 0) {
    report.status = sawSettings ? 'ok' : 'skipped';
    if (!args.json) process.stdout.write('check-plugin-installs: ok (0 enabled plugin(s))\n');
    finish(0);
  }

  // Local user state — absent in CI and on fresh clones. Skip unless --strict.
  if (!existsSync(manifestPath)) {
    report.status = 'skipped';
    report.skipReason = 'manifest_absent';
    if (args.strict) {
      process.stderr.write(
        `check-plugin-installs: no installed_plugins.json at ${manifestPath}, but --strict was requested\n`,
      );
      finish(1);
    }
    if (!args.json) {
      process.stdout.write(`check-plugin-installs: skipped (no install manifest at ${manifestPath})\n`);
    }
    finish(0);
  }

  const manifest = readJson(manifestPath, 'installed_plugins.json');
  const installed = manifest.plugins ?? {};

  // Resolve each marketplace referenced by an enabled plugin, once.
  const markets = new Map();
  for (const key of enabledNames) {
    const { marketplace } = splitPluginKey(key);
    if (!marketplace || markets.has(marketplace)) continue;
    const { root, versions } = readMarketplaceVersions(configDir, marketplace);
    markets.set(marketplace, { root, versions, exists: existsSync(root) });
  }

  for (const [name, m] of markets) {
    if (!m.exists) continue;
    const state = cloneState(m.root, { offline: args.offline });
    report.marketplaces.push({ name, ...state });
    if (state.behind === true) {
      report.findings.push({
        plugin: null,
        reason: 'clone_behind',
        marketplace: name,
        head: state.head,
        remoteHead: state.remoteHead,
        lastFetchAttempt: state.lastFetchAttempt,
      });
    }
  }

  for (const key of enabledNames) {
    const records = Array.isArray(installed[key]) ? installed[key] : [];
    const { name, marketplace } = splitPluginKey(key);

    const projectRecord = records.find(
      (r) => r?.scope !== 'user' && r?.projectPath && canonical(r.projectPath) === projectRoot,
    );
    const userRecord = records.find((r) => r?.scope === 'user');
    const marketVersion = markets.get(marketplace)?.versions?.[name] ?? null;

    // Project scope wins when it exists — that asymmetry is exactly what made
    // the outage invisible, so the row must report the version that will
    // actually load, not the newest one on disk.
    const effective = projectRecord?.version ?? userRecord?.version ?? null;

    report.plugins.push({
      plugin: key,
      project: projectRecord?.version ?? null,
      user: userRecord?.version ?? null,
      marketplace: marketVersion,
      effective,
    });

    const presence = classify(installed[key], projectRoot);
    if (presence) {
      report.findings.push({ plugin: key, ...presence });
      continue; // a plugin that will not load at all has no currency question
    }

    // Currency: is anything newer available than what will load here?
    // User scope is considered first and ties keep it, because a shadowed
    // user-scope install is the more specific diagnosis — it names the record
    // that is already on this machine and losing to the project pin, which is
    // the mechanism that actually caused the outage. Only a STRICTLY newer
    // marketplace version displaces it.
    let available = null;
    let source = null;
    for (const [candidate, from] of [
      [userRecord?.version ?? null, 'user'],
      [marketVersion, 'marketplace'],
    ]) {
      if (compareVersions(effective, candidate) !== -1) continue;
      if (available !== null && compareVersions(available, candidate) !== -1) continue;
      available = candidate;
      source = from;
    }
    if (available) {
      report.findings.push({ plugin: key, reason: 'stale_install', effective, available, source });
    }
  }

  report.status = report.findings.length > 0 ? 'failed' : 'ok';

  if (args.report || (!args.json && report.findings.length > 0)) {
    // Some marketplaces version by commit SHA rather than semver, so a version
    // cell can be 40 characters. Clip the cells and size the name column to the
    // widest actual name, or long rows bleed into the next column.
    const clip = (s) => {
      const v = String(s ?? '-');
      return v.length > 14 ? `${v.slice(0, 11)}...` : v;
    };
    const nameWidth = Math.max(6, ...report.plugins.map((p) => p.plugin.length)) + 2;
    const row = (name, a, b, c) =>
      `${String(name).padEnd(nameWidth)}${clip(a).padEnd(16)}${clip(b).padEnd(16)}${clip(c)}\n`;
    process.stdout.write(row('PLUGIN', 'PROJECT', 'USER', 'MARKET'));
    for (const p of report.plugins) {
      process.stdout.write(row(p.plugin, p.project, p.user, p.marketplace));
    }
    for (const m of report.marketplaces) {
      const behind = m.behind === null ? 'unknown' : m.behind ? 'BEHIND' : 'current';
      process.stdout.write(
        `marketplace ${m.name}: ${behind} (head ${(m.head ?? '?').slice(0, 8)}, last fetch attempt ${m.lastFetchAttempt ?? 'never'})\n`,
      );
    }
  }

  for (const f of report.findings) {
    if (f.reason === 'not_installed') {
      process.stderr.write(
        `error: ${f.plugin} is enabled for this project but was never installed — enabling in settings.json does not install it\n`,
      );
    } else if (f.reason === 'installed_elsewhere') {
      const where = f.installedFor.map((p) => `${basename(p)} (${p})`).join(', ');
      process.stderr.write(`error: ${f.plugin} is enabled here but installed for a different project: ${where}\n`);
    } else if (f.reason === 'stale_install') {
      const why =
        f.source === 'user'
          ? `a newer user-scope install (${f.available}) is being shadowed by this project's pin`
          : `the marketplace advertises ${f.available}`;
      process.stderr.write(`error: ${f.plugin} will load ${f.effective}, but ${why}\n`);
    } else if (f.reason === 'clone_behind') {
      process.stderr.write(
        `error: marketplace ${f.marketplace} clone is behind its origin (${(f.head ?? '?').slice(0, 8)} < ${(f.remoteHead ?? '?').slice(0, 8)}); last fetch attempt ${f.lastFetchAttempt ?? 'never'} — every install from it is stale\n`,
      );
    }
  }

  if (report.findings.length > 0) {
    if (!args.json) {
      process.stderr.write(
        `check-plugin-installs: ${report.findings.length} problem(s) across ${enabledNames.length} enabled plugin(s)\n`,
      );
    }
    finish(1);
  }

  if (!args.json && !args.report) {
    process.stdout.write(`check-plugin-installs: ok (${enabledNames.length} enabled plugin(s) installed)\n`);
  }
  finish(0);
}

main();
