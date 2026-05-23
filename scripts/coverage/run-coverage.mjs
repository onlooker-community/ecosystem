#!/usr/bin/env node
// Run the .mjs test suite with node's built-in --experimental-test-coverage,
// parse the emitted table into structured JSON, and either pretty-print it
// or hand it off as JSON for downstream tools (format-comment.mjs).
//
// The output table is fixed-format text; we parse it line-by-line rather
// than depending on V8 coverage dumps so we don't need to handle binary
// formats across node versions.
//
// Flags:
//   --json   emit structured JSON
//   --root   override repo root

import { spawnSync } from 'node:child_process';
import { statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
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

// Parse the human-readable coverage report node prints after a --test run.
// Layout:
//   ℹ start of coverage report
//   ℹ ---------- (separator)
//   ℹ file | line % | branch % | funcs % | uncovered lines
//   ℹ ---------- (separator)
//   ℹ <directory>
//   ℹ  <subdir>
//   ℹ   <file.mjs>  | 74.20 | 58.27 | 85.00 | 130-131 170 ...
//   ℹ ---------- (separator)
//   ℹ all files     | 78.55 | 57.38 | 87.18 |
//   ℹ ---------- (separator)
//   ℹ end of coverage report
function parseCoverageOutput(text) {
  const lines = text.split(/\r?\n/);
  const files = [];
  let overall = null;
  let inReport = false;

  for (const rawLine of lines) {
    const line = rawLine.replace(/^ℹ\s?/, '').replace(/^[\sℹ]+/, '');
    if (line.startsWith('start of coverage report')) {
      inReport = true;
      continue;
    }
    if (line.startsWith('end of coverage report')) {
      inReport = false;
      continue;
    }
    if (!inReport) continue;

    // Skip separators and the header row.
    if (line.startsWith('-')) continue;
    if (line.includes('line %') && line.includes('branch %')) continue;

    const cells = line.split('|').map((c) => c.trim());
    // A real data row has 5 columns: file, line%, branch%, funcs%, uncovered.
    if (cells.length < 5) continue;

    const [file, linePct, branchPct, funcsPct, uncovered] = cells;
    if (!file) continue;
    // Directory rows have all-blank metric columns — skip them so we only
    // surface per-file numbers + the all-files total.
    if (!linePct || !branchPct || !funcsPct) continue;

    const num = (s) => Number.parseFloat(s);
    const entry = {
      file,
      line: num(linePct),
      branch: num(branchPct),
      funcs: num(funcsPct),
      uncoveredLines: uncovered || '',
    };
    if (file === 'all files') {
      overall = entry;
    } else {
      files.push(entry);
    }
  }

  return { files, overall };
}

function main() {
  const args = parseArgs(process.argv);
  const here = dirname(fileURLToPath(import.meta.url));
  const root = args.root ? resolve(args.root) : findRepoRoot(here);

  const testGlob = ['test/node'].map((d) => join(root, d, '*.test.mjs'));
  const r = spawnSync(
    'node',
    [
      '--experimental-test-coverage',
      '--test-coverage-include=scripts/**/*.mjs',
      '--test-coverage-exclude=test/**',
      '--test',
      ...testGlob,
    ],
    { encoding: 'utf8', cwd: root },
  );

  if (r.status !== 0) {
    process.stderr.write(`tests failed (exit ${r.status})\n`);
    process.stderr.write(r.stdout);
    process.stderr.write(r.stderr);
    process.exit(r.status ?? 1);
  }

  const report = parseCoverageOutput(r.stdout);

  if (args.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  if (!report.overall) {
    process.stderr.write('could not parse coverage output\n');
    process.stderr.write(r.stdout);
    process.exit(1);
  }

  process.stdout.write(
    `node coverage: line ${report.overall.line.toFixed(1)}%  branch ${report.overall.branch.toFixed(1)}%  funcs ${report.overall.funcs.toFixed(1)}%\n\n`,
  );
  for (const f of report.files) {
    process.stdout.write(
      `  line ${f.line.toFixed(0).padStart(3)}%  branch ${f.branch.toFixed(0).padStart(3)}%  ${f.file}\n`,
    );
  }
}

main();
