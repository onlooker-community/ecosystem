#!/usr/bin/env node
// Bash "tested-functions ratio" heuristic.
//
// True bash line coverage (bashcov / kcov) is heavy and flaky in CI, so
// instead we ask the cheaper question: "for every public function defined
// in scripts/lib/, does at least one bats test reference it by name?". The
// result is a per-file ratio plus a flat list of untested public functions.
//
// What counts as a "public" function:
//   * defined with either `name() { ... }` or `function name { ... }`
//   * name does NOT start with an underscore (those are private helpers and
//     should be tested indirectly through their callers).
//
// What counts as a "reference" in tests:
//   * the function name appears as a standalone word in any *.bats file
//     (typical patterns: `run my_func ...`, `my_func "$arg"`, or sourced
//     and called directly). False positives are possible — that's the cost
//     of a heuristic — but the score is still useful as a regression gate
//     and is calibrated against the noise floor.
//
// Flags:
//   --json     emit structured JSON on stdout (default: human-readable)
//   --root <p> override repo root
//
// Exit codes: always 0; this is an informational tool. Use --json to feed
// into format-comment.mjs.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

function findRepoRoot(start) {
  let cur = resolve(start);
  while (cur !== '/') {
    try {
      statSync(join(cur, '.claude-plugin', 'marketplace.json'));
      return cur;
    } catch {}
    cur = dirname(cur);
  }
  throw new Error(`no repo root above ${start}`);
}

function parseArgs(argv) {
  const out = { json: false, root: null };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--json') out.json = true;
    else if (argv[i] === '--root') out.root = argv[++i];
  }
  return out;
}

function walk(dir, predicate) {
  const out = [];
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop();
    let items;
    try {
      items = readdirSync(cur, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const item of items) {
      const p = join(cur, item.name);
      if (item.isDirectory()) {
        if (item.name === 'node_modules' || item.name === '.git') continue;
        stack.push(p);
      } else if (item.isFile() && predicate(p)) {
        out.push(p);
      }
    }
  }
  return out.sort();
}

// Extract `name` from lines like `name() {`, `name () {`, or `function name`.
// Skips lines indented (those are nested fns / non-top-level callbacks we
// don't want to attribute to the file's public surface).
function extractFunctions(content) {
  const out = [];
  const lines = content.split(/\r?\n/);
  const def = /^(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{?/;
  for (const line of lines) {
    // Strict: must start at column 0 (no leading whitespace).
    if (line.length === 0 || line[0] === ' ' || line[0] === '\t') continue;
    const m = line.match(def);
    if (!m) continue;
    const name = m[1];
    // Skip private helpers and bash keywords that look like fn names.
    if (name.startsWith('_')) continue;
    if (['if', 'while', 'for', 'case', 'then', 'do', 'else', 'fi', 'done'].includes(name)) continue;
    out.push(name);
  }
  return [...new Set(out)];
}

function isReferenced(name, testsContent) {
  // Look for the name as a standalone word (preceded/followed by non-word
  // characters). This catches `run name`, `name "$x"`, `$( name )`, etc.
  const rx = new RegExp(`(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|$)`);
  return rx.test(testsContent);
}

function main() {
  const args = parseArgs(process.argv);
  const here = dirname(fileURLToPath(import.meta.url));
  const root = args.root ? resolve(args.root) : findRepoRoot(here);

  const libDirs = [join(root, 'scripts', 'lib'), join(root, 'plugins', 'archivist', 'scripts', 'lib')];
  const libFiles = [];
  for (const d of libDirs) {
    try {
      libFiles.push(...walk(d, (p) => p.endsWith('.sh')));
    } catch {}
  }

  const testsDir = join(root, 'test', 'bats');
  const testFiles = walk(testsDir, (p) => p.endsWith('.bats'));
  const testsContent = testFiles.map((f) => readFileSync(f, 'utf8')).join('\n');

  const perFile = [];
  let totalFns = 0;
  let totalTested = 0;
  const untested = [];

  for (const file of libFiles) {
    const fns = extractFunctions(readFileSync(file, 'utf8'));
    const tested = fns.filter((name) => isReferenced(name, testsContent));
    const fileTotal = fns.length;
    const fileTested = tested.length;
    totalFns += fileTotal;
    totalTested += fileTested;
    const relpath = relative(root, file);
    perFile.push({
      file: relpath,
      total: fileTotal,
      tested: fileTested,
      ratio: fileTotal === 0 ? 1 : fileTested / fileTotal,
      untested: fns.filter((n) => !tested.includes(n)),
    });
    for (const u of fns.filter((n) => !tested.includes(n))) {
      untested.push({ file: relpath, name: u });
    }
  }

  const overallRatio = totalFns === 0 ? 1 : totalTested / totalFns;
  const report = {
    overall: { total: totalFns, tested: totalTested, ratio: overallRatio },
    files: perFile,
    untested,
  };

  if (args.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  process.stdout.write(`bash function coverage: ${totalTested}/${totalFns} (${(overallRatio * 100).toFixed(1)}%)\n\n`);
  for (const f of perFile) {
    const pct = (f.ratio * 100).toFixed(0).padStart(3);
    process.stdout.write(`  ${pct}%  ${f.tested}/${f.total}  ${f.file}\n`);
    for (const u of f.untested) {
      process.stdout.write(`         - ${u}\n`);
    }
  }
}

main();
