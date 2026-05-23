#!/usr/bin/env node
// Combine node coverage + bash function coverage into a single markdown
// comment suitable for posting on a pull request via `gh pr comment`.
//
// Reads each report from a file path (so the caller can capture stdout
// once and pass the file through). Emits markdown on stdout.
//
// Usage:
//   format-comment.mjs --node coverage-node.json --bash coverage-bash.json
//
// Each file should be JSON produced by the matching script's --json mode.

import { readFileSync } from 'node:fs';

function parseArgs(argv) {
  const out = { node: null, bash: null, sha: process.env.GITHUB_SHA ?? null };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === '--node') out.node = argv[++i];
    else if (argv[i] === '--bash') out.bash = argv[++i];
    else if (argv[i] === '--sha') out.sha = argv[++i];
  }
  return out;
}

function pct(n) {
  if (typeof n !== 'number' || Number.isNaN(n)) return '—';
  return `${n.toFixed(1)}%`;
}

function badge(value, kind) {
  if (typeof value !== 'number') return '⚪';
  if (kind === 'bash') {
    if (value >= 70) return '🟢';
    if (value >= 50) return '🟡';
    return '🔴';
  }
  if (value >= 80) return '🟢';
  if (value >= 60) return '🟡';
  return '🔴';
}

function nodeSection(report) {
  if (!report?.overall) {
    return '_No node coverage report._';
  }
  const o = report.overall;
  const lines = [
    `**Overall:** ${badge(o.line, 'node')} ${pct(o.line)} lines · ${pct(o.branch)} branches · ${pct(o.funcs)} functions`,
    '',
    '| file | line | branch | funcs |',
    '| --- | ---: | ---: | ---: |',
  ];
  for (const f of report.files) {
    lines.push(`| \`${f.file}\` | ${pct(f.line)} | ${pct(f.branch)} | ${pct(f.funcs)} |`);
  }
  return lines.join('\n');
}

function bashSection(report) {
  if (!report?.overall) {
    return '_No bash function coverage report._';
  }
  const o = report.overall;
  const overallPct = o.ratio * 100;
  const lines = [
    `**Overall:** ${badge(overallPct, 'bash')} ${o.tested}/${o.total} public functions exercised by bats (${pct(overallPct)})`,
    '',
    '| file | tested / total | ratio |',
    '| --- | ---: | ---: |',
  ];
  for (const f of report.files) {
    if (f.total === 0) continue;
    lines.push(`| \`${f.file}\` | ${f.tested} / ${f.total} | ${pct(f.ratio * 100)} |`);
  }
  if (report.untested.length > 0) {
    lines.push('');
    lines.push('<details><summary>Untested public functions</summary>');
    lines.push('');
    for (const u of report.untested) {
      lines.push(`- \`${u.file}\` — \`${u.name}\``);
    }
    lines.push('');
    lines.push('</details>');
  }
  return lines.join('\n');
}

function main() {
  const args = parseArgs(process.argv);
  let nodeReport = null;
  let bashReport = null;
  if (args.node) nodeReport = JSON.parse(readFileSync(args.node, 'utf8'));
  if (args.bash) bashReport = JSON.parse(readFileSync(args.bash, 'utf8'));

  const out = [];
  out.push('<!-- onlooker-coverage-comment -->');
  out.push('## Coverage');
  out.push('');
  if (args.sha) {
    out.push(`Commit: \`${args.sha.slice(0, 12)}\``);
    out.push('');
  }
  out.push('### Node (.mjs)');
  out.push('');
  out.push(nodeSection(nodeReport));
  out.push('');
  out.push('### Bash (function-reference heuristic)');
  out.push('');
  out.push(bashSection(bashReport));
  out.push('');
  out.push('---');
  out.push('');
  out.push(
    'Bash numbers are a heuristic — they count public functions referenced by bats tests, not real line coverage. A red score points to public helpers nobody directly exercises.',
  );

  process.stdout.write(`${out.join('\n')}\n`);
}

main();
