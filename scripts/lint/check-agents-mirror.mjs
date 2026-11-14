#!/usr/bin/env node
// AGENTS.md mirror checker.
//
// CLAUDE.md and AGENTS.md carry the same repository instructions: Claude Code
// reads the first, Codex and several other tools read the second. They cannot
// be one file -- AGENTS.md has a preamble and a `bd setup codex` block of its
// own -- so AGENTS.md mirrors CLAUDE.md between two markers, and nothing kept
// the copy current. By ONL-155 it had fallen behind in five places, among them
// a rule ADR-005 retired and three rules CI enforces, so an agent reading
// AGENTS.md was told the old ones.
//
// This compares the marked section of AGENTS.md, line for line, with CLAUDE.md
// after its title. Each file's generated blocks (`<!-- BEGIN ... -->` to
// `<!-- END ... -->`) are compared by position only: `bd setup` writes them
// per file, with a profile and hash of its own, and owns their text.
//
// Exit codes:
//   0  ok
//   1  the mirror has drifted, or its markers are missing
//   2  setup/usage error
//
// Flags:
//   --root <path>   override the repo root (used by the tests)

import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const START = '<!-- mirror-of-claude-md:start -->';
const END = '<!-- mirror-of-claude-md:end -->';
const BEGIN_MARKER = /^<!--\s*BEGIN\s+\S.*-->\s*$/;
const END_MARKER = /^<!--\s*END\s+\S.*-->\s*$/;
const GENERATED = '<generated block>';

function usageError(message) {
  process.stderr.write(`check-agents-mirror: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = { root: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--root') {
      args.root = argv[++i];
      if (!args.root) usageError('--root requires a path');
    } else {
      usageError(`unknown argument: ${argv[i]}`);
    }
  }
  return args;
}

// Lines as { no, text }, with each generated block collapsed to one
// placeholder line and blank lines trimmed from both ends.
function comparable(lines, firstNo) {
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const no = firstNo + i;
    if (BEGIN_MARKER.test(lines[i])) {
      out.push({ no, text: GENERATED });
      while (i < lines.length && !END_MARKER.test(lines[i])) i++;
      continue;
    }
    out.push({ no, text: lines[i].replace(/\s+$/, '') });
  }
  while (out.length > 0 && out[0].text === '') out.shift();
  while (out.length > 0 && out[out.length - 1].text === '') out.pop();
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const here = dirname(fileURLToPath(import.meta.url));
  const root = resolve(args.root ?? join(here, '..', '..'));
  const agentsPath = join(root, 'AGENTS.md');
  const claudePath = join(root, 'CLAUDE.md');
  if (!existsSync(agentsPath) || !existsSync(claudePath)) {
    usageError(`expected AGENTS.md and CLAUDE.md under ${root}`);
  }

  const agents = readFileSync(agentsPath, 'utf8').split('\n');
  const claude = readFileSync(claudePath, 'utf8').split('\n');

  const start = agents.indexOf(START);
  const end = agents.indexOf(END);
  if (start === -1 || end === -1 || end < start) {
    process.stderr.write(`error: AGENTS.md must wrap its copy of CLAUDE.md in ${START} and ${END}, in that order\n`);
    process.exit(1);
  }

  const title = claude.findIndex((line) => /^#\s/.test(line));
  const mirror = comparable(agents.slice(start + 1, end), start + 2);
  const source = comparable(claude.slice(title + 1), title + 2);

  const n = Math.max(mirror.length, source.length);
  for (let i = 0; i < n; i++) {
    const a = mirror[i];
    const c = source[i];
    if (a && c && a.text === c.text) continue;
    const where = (line, file) => (line ? `${file}:${line.no}` : `${file} (past its end)`);
    // Three lines from each side, since the first to differ is often a blank.
    const excerpt = (lines) =>
      lines
        .slice(i, i + 3)
        .map((l) => `    ${JSON.stringify(l.text)}`)
        .join('\n') || '    (nothing)';
    process.stderr.write(
      `error: AGENTS.md no longer mirrors CLAUDE.md, first at ${where(a, 'AGENTS.md')} / ${where(c, 'CLAUDE.md')}\n` +
        `  AGENTS.md:\n${excerpt(mirror)}\n` +
        `  CLAUDE.md:\n${excerpt(source)}\n` +
        'Edit CLAUDE.md, then copy everything after its title into the marked section of AGENTS.md (ONL-155).\n',
    );
    process.exit(1);
  }

  process.stdout.write(`check-agents-mirror: ok (${mirror.length} lines mirrored)\n`);
}

main();
