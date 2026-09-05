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
// Two distinct findings, because they need different fixes:
//
//   not_installed        no install record under any scope — the plugin was
//                        enabled but never installed anywhere.
//   installed_elsewhere  installed, but only project-scoped to a different
//                        projectPath. Enabled here, running there.
//
// Fails soft by design. installed_plugins.json is local user state and does
// not exist in CI or on a fresh clone, so an absent manifest is a skip, not a
// failure. Use --strict to demand it (for a local wave-readiness check).
//
// Exit codes:
//   0  ok, or skipped (no manifest / no enabled plugins)
//   1  one or more plugins enabled without a matching install
//   2  setup/usage error
//
// Flags:
//   --project <path>     project root to check (default: cwd)
//   --config-dir <path>  Claude config dir holding plugins/installed_plugins.json
//                        (default: $CLAUDE_HOME, else $CLAUDE_CONFIG_DIR, else ~/.claude)
//   --strict             treat an absent install manifest as an error
//   --json               emit the report as JSON on stdout

import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join, resolve } from 'node:path';

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
        'usage: check-plugin-installs [--project <path>] [--config-dir <path>] [--strict] [--json]\n',
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

// Claude Code layers settings.local.json over settings.json; mirror that so we
// check what actually takes effect rather than only the committed file.
function readEnabledPlugins(projectRoot) {
  const enabled = {};
  let sawSettings = false;
  for (const name of ['settings.json', 'settings.local.json']) {
    const path = join(projectRoot, '.claude', name);
    if (!existsSync(path)) continue;
    sawSettings = true;
    const settings = readJson(path, name);
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

function main() {
  const args = parseArgs(process.argv);
  const projectRoot = canonical(args.project ?? process.cwd());
  const configDir = resolveConfigDir(args.configDir);
  const manifestPath = join(configDir, 'plugins', 'installed_plugins.json');

  const { enabled, sawSettings } = readEnabledPlugins(projectRoot);
  const enabledNames = Object.keys(enabled).filter((name) => enabled[name] === true);

  const report = {
    project: projectRoot,
    manifest: manifestPath,
    enabled: enabledNames.length,
    findings: [],
  };

  // Nothing enabled (or no settings at all) — nothing this check can assert.
  if (enabledNames.length === 0) {
    report.status = sawSettings ? 'ok' : 'skipped';
    if (args.json) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    else process.stdout.write(`check-plugin-installs: ok (0 enabled plugin(s))\n`);
    process.exit(0);
  }

  // Local user state — absent in CI and on fresh clones. Skip unless --strict.
  if (!existsSync(manifestPath)) {
    report.status = 'skipped';
    report.skipReason = 'manifest_absent';
    if (args.strict) {
      process.stderr.write(
        `check-plugin-installs: no installed_plugins.json at ${manifestPath}, but --strict was requested\n`,
      );
      if (args.json) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
      process.exit(1);
    }
    if (args.json) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    else process.stdout.write(`check-plugin-installs: skipped (no install manifest at ${manifestPath})\n`);
    process.exit(0);
  }

  const manifest = readJson(manifestPath, 'installed_plugins.json');
  const installed = manifest.plugins ?? {};

  for (const name of enabledNames) {
    const finding = classify(installed[name], projectRoot);
    if (finding) report.findings.push({ plugin: name, ...finding });
  }

  report.status = report.findings.length > 0 ? 'failed' : 'ok';

  if (args.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  }

  for (const f of report.findings) {
    if (f.reason === 'not_installed') {
      process.stderr.write(
        `error: ${f.plugin} is enabled for this project but was never installed — enabling in settings.json does not install it\n`,
      );
    } else {
      const where = f.installedFor.map((p) => `${basename(p)} (${p})`).join(', ');
      process.stderr.write(`error: ${f.plugin} is enabled here but installed for a different project: ${where}\n`);
    }
  }

  if (report.findings.length > 0) {
    if (!args.json) {
      process.stderr.write(
        `check-plugin-installs: ${report.findings.length} of ${enabledNames.length} enabled plugin(s) will never load\n`,
      );
    }
    process.exit(1);
  }

  if (!args.json) {
    process.stdout.write(`check-plugin-installs: ok (${enabledNames.length} enabled plugin(s) installed)\n`);
  }
  process.exit(0);
}

main();
