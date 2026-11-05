#!/usr/bin/env node

// Installed-vs-locked checker for the npm tree (ONL-62).
//
// The npm layer has the same declared-vs-installed hazard check-plugin-installs
// covers for marketplace plugins. It surfaced as a bats failure that read like a
// schema defect: package.json declared @onlooker-community/schema ^2.18.1, the
// lockfile resolved 2.18.1, and node_modules held 2.18.0, a version satisfying
// neither. The installed copy predated the drop-reason enum values librarian
// emits, so librarian-durability.bats failed as "the schema refuses this
// reason". It cost a wrongly filed bead and a trip through an unrelated
// upstream repo before `npm ci` turned out to be the whole fix.
//
// CI cannot hit this: it always runs `npm ci`, so its tree always matches the
// lockfile. A local tree drifts whenever a merge advances the lockfile and no
// install follows, which is the normal case after pulling a dependency bump.
// So the value of this check is local, and scripts/test/run-bats.sh runs it as
// a warning before the suite: the place the drift was misdiagnosed is the
// place it has to be announced.
//
// For every package the lockfile resolves, it reads the version actually
// installed at <root>/<lockfile path>/package.json. No network.
//
// Findings:
//
//   drifted     installed, at a version other than the one locked.
//   missing     not installed at all. Optional packages are exempt, because
//               npm leaves out the ones for other platforms (biome ships one
//               binary package per OS and CPU).
//   unreadable  the installed package.json exists but is not valid JSON.
//
// Linked packages (`link: true`) are skipped: their entry records where the
// link points, and the target carries its own entry.
//
// Fails soft. A fresh clone has no node_modules, and that is a skip, not a
// failure. Use --strict to demand it.
//
// Exit codes:
//   0  ok, or skipped (no lockfile / no node_modules)
//   1  one or more packages drifted, missing or unreadable
//   2  setup/usage error
//
// Flags:
//   --root <path>  project root holding package-lock.json (default: cwd)
//   --strict       treat an absent node_modules as an error
//   --json         emit the report as JSON on stdout

import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

function parseArgs(argv) {
  const args = { root: null, strict: false, json: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--strict') args.strict = true;
    else if (a === '--json') args.json = true;
    else if (a === '--root') args.root = argv[++i];
    else if (a === '--help' || a === '-h') {
      process.stdout.write('usage: check-dep-drift [--root <path>] [--strict] [--json]\n');
      process.exit(0);
    } else {
      process.stderr.write(`check-dep-drift: unknown argument ${a}\n`);
      process.exit(2);
    }
  }
  return args;
}

// The package's name as npm prints it: the part after the LAST node_modules/,
// so a nested copy reads as its own name. The full path stays on the finding,
// because two copies of one package can disagree independently.
function packageLabel(path) {
  return path.slice(path.lastIndexOf('node_modules/') + 'node_modules/'.length);
}

function main() {
  const args = parseArgs(process.argv);
  const root = resolve(args.root ?? process.cwd());
  const lockPath = join(root, 'package-lock.json');
  const report = { root, lockfile: lockPath, checked: 0, findings: [] };

  const finish = (code) => {
    if (args.json) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    process.exit(code);
  };
  const skip = (reason, message) => {
    report.status = 'skipped';
    report.skipReason = reason;
    if (!args.json) process.stdout.write(`check-dep-drift: skipped (${message})\n`);
    finish(0);
  };

  if (!existsSync(lockPath)) skip('lockfile_absent', `no package-lock.json at ${root}`);

  let lock;
  try {
    lock = JSON.parse(readFileSync(lockPath, 'utf8'));
  } catch (err) {
    process.stderr.write(`check-dep-drift: cannot read package-lock.json (${lockPath}): ${err.message}\n`);
    process.exit(2);
  }
  // lockfileVersion 2 and 3 carry `packages`; version 1 has only `dependencies`
  // and predates npm 7. Refusing it is clearer than reporting a vacuous ok.
  if (!lock.packages || typeof lock.packages !== 'object') {
    process.stderr.write(
      `check-dep-drift: ${lockPath} has no "packages" map (lockfileVersion ${lock.lockfileVersion})\n`,
    );
    process.exit(2);
  }

  if (!existsSync(join(root, 'node_modules'))) {
    if (args.strict) {
      report.status = 'skipped';
      report.skipReason = 'node_modules_absent';
      process.stderr.write(`check-dep-drift: no node_modules at ${root}, but --strict was requested\n`);
      finish(1);
    }
    skip('node_modules_absent', `no node_modules at ${root}; run npm ci`);
  }

  for (const [path, entry] of Object.entries(lock.packages)) {
    // '' is the root project; other non-node_modules keys are workspaces.
    if (!path.startsWith('node_modules/') || entry?.link) continue;
    report.checked++;

    const pkg = packageLabel(path);
    const locked = entry?.version ?? null;
    const manifest = join(root, path, 'package.json');

    if (!existsSync(manifest)) {
      if (!entry?.optional) report.findings.push({ package: pkg, path, reason: 'missing', installed: null, locked });
      continue;
    }
    let installed;
    try {
      installed = JSON.parse(readFileSync(manifest, 'utf8')).version ?? null;
    } catch {
      report.findings.push({ package: pkg, path, reason: 'unreadable', installed: null, locked });
      continue;
    }
    if (installed !== locked) report.findings.push({ package: pkg, path, reason: 'drifted', installed, locked });
  }

  report.status = report.findings.length > 0 ? 'failed' : 'ok';

  if (report.findings.length === 0) {
    if (!args.json) process.stdout.write(`check-dep-drift: ok (${report.checked} package(s) match the lockfile)\n`);
    finish(0);
  }

  if (!args.json) {
    for (const f of report.findings) {
      // A nested copy is named by its full path so it cannot be mistaken for
      // the hoisted package of the same name.
      const name = f.path.split('node_modules/').length > 2 ? f.path.slice('node_modules/'.length) : f.package;
      const have =
        f.reason === 'missing'
          ? 'not installed'
          : f.reason === 'unreadable'
            ? 'unreadable package.json'
            : `installed ${f.installed}`;
      process.stderr.write(`error: ${name}: ${have}, lockfile resolves ${f.locked}\n`);
    }
    process.stderr.write(
      `check-dep-drift: ${report.findings.length} of ${report.checked} package(s) disagree with package-lock.json; run npm ci\n`,
    );
  }
  finish(1);
}

main();
