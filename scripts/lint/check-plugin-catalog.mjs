#!/usr/bin/env node
// Catalog drift check for docs/plugin-catalog.md.
//
// The catalog is the first place anyone looks to see what already exists
// before proposing a plugin, so a stale one actively misleads: it sent four
// shipped plugins (bursar, assayer, inspector, lineage) back into the
// "planned" pile, and the calibrator, appraiser, arbiter and customs proposals
// were all scoped against it (ONL-162).
//
// Three rules, all mechanical:
//
//   * Every directory under plugins/ appears in the catalog.
//   * Every one of them is marked `shipped`, which the catalog's own legend
//     defines as "code lives under plugins/<name>/ and is exercised by the
//     test suite" - so a directory that exists cannot honestly be `planned`.
//   * The closing totals line matches the entries actually present. It was
//     wrong independently of the statuses: it claimed 17 planned against 18.
//
// Deliberately NOT checked: that a `planned` entry has no directory. A plugin
// can be renamed on the way in, and the catalog is a sketch pad for names
// nobody has committed to - failing on an aspirational entry would make the
// document harder to use for the one job it has.
//
// Exit codes:
//   0  ok
//   1  drift
//   2  setup error
//
// Flags:
//   --root <path>   override the repo root

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const CATALOG_REL = 'docs/plugin-catalog.md';

// `- **name** — status — hook surface. Purpose.`
// Em dash, not a hyphen: the catalog uses U+2014 throughout, and matching a
// hyphen here would silently find nothing and report a clean catalog.
const ENTRY = /^- \*\*([a-z][a-z0-9-]*)\*\* — ([a-z]+)/;

// `Total: 12 shipped, 0 design, 17 planned.`
const TOTALS = /Total:\s*(\d+)\s+shipped,\s*(\d+)\s+design,\s*(\d+)\s+planned/;

function parseArgs(argv) {
  const args = { root: null };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--root') {
      args.root = argv[i + 1];
      i += 1;
    }
  }
  return args;
}

function repoRoot(override) {
  if (override) return resolve(override);
  return resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = repoRoot(args.root);

  const catalogPath = join(root, CATALOG_REL);
  if (!existsSync(catalogPath)) {
    process.stderr.write(`check-plugin-catalog: ${CATALOG_REL} not found under ${root}\n`);
    process.exit(2);
  }

  const pluginsDir = join(root, 'plugins');
  if (!existsSync(pluginsDir)) {
    process.stderr.write(`check-plugin-catalog: plugins/ not found under ${root}\n`);
    process.exit(2);
  }

  const onDisk = readdirSync(pluginsDir)
    .filter((name) => statSync(join(pluginsDir, name)).isDirectory())
    .sort();

  const lines = readFileSync(catalogPath, 'utf8').split('\n');

  // The legend uses the same bullet shape as the entries ("- **shipped** —
  // code lives under ..."), so entries are read only after the `---` rule
  // that closes the header. Without that, the legend's own three bullets
  // parse as plugins named shipped/design/planned.
  const ruleAt = lines.findIndex((line) => line.trim() === '---');
  if (ruleAt === -1) {
    process.stderr.write(`check-plugin-catalog: no '---' rule closing the header in ${CATALOG_REL}\n`);
    process.exit(2);
  }

  const status = new Map();
  const counts = { shipped: 0, design: 0, planned: 0, other: 0 };
  for (const line of lines.slice(ruleAt + 1)) {
    const m = ENTRY.exec(line);
    if (!m) continue;
    const [, name, state] = m;
    status.set(name, state);
    if (state in counts) counts[state] += 1;
    else counts.other += 1;
  }

  const errors = [];

  for (const name of onDisk) {
    const state = status.get(name);
    if (state === undefined) {
      errors.push(`plugins/${name}/ exists but is not listed in ${CATALOG_REL}`);
    } else if (state !== 'shipped') {
      errors.push(
        `plugins/${name}/ exists but ${CATALOG_REL} marks it '${state}' — the legend reserves that for code that does not exist yet`,
      );
    }
  }

  if (counts.other > 0) {
    errors.push(`${CATALOG_REL} has ${counts.other} entr(y/ies) whose status is none of shipped/design/planned`);
  }

  const totalsLine = lines.find((line) => TOTALS.test(line));
  if (!totalsLine) {
    errors.push(`${CATALOG_REL} has no "Total: N shipped, N design, N planned" line`);
  } else {
    const [, shipped, design, planned] = TOTALS.exec(totalsLine).map((v, i) => (i === 0 ? v : Number(v)));
    if (shipped !== counts.shipped || design !== counts.design || planned !== counts.planned) {
      errors.push(
        `${CATALOG_REL} totals say ${shipped} shipped, ${design} design, ${planned} planned; ` +
          `the entries are ${counts.shipped} shipped, ${counts.design} design, ${counts.planned} planned`,
      );
    }
  }

  for (const e of errors) process.stderr.write(`error: ${e}\n`);
  if (errors.length > 0) {
    process.stderr.write(`check-plugin-catalog: ${errors.length} error(s)\n`);
    process.exit(1);
  }

  process.stdout.write(
    `check-plugin-catalog: ok (${onDisk.length} shipped on disk, ` +
      `${counts.shipped + counts.design + counts.planned} catalog entries)\n`,
  );
}

main();
