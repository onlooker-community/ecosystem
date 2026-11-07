#!/usr/bin/env node
// Find bats assertions that cannot fail a test under bash 3.2.
//
// ONL-206. `bats` resolves `#!/usr/bin/env bash`, which on macOS is
// /bin/bash 3.2, and 3.2's errexit ignores a failing `[[ ]]` or `(( ))`. A
// test body's status is its last command, so only the final statement gates;
// any `[[ ]]` or `(( ))` before it is lost. That holds at every nesting depth
// -- measured on 3.2.57:
//
//   mid-test [[ 1 == 2 ]]                       ok     (bash 5: not ok)
//   [[ ]] inside a for loop / if body / { }     ok     (bash 5: not ok)
//   mid-test (( 1 == 2 ))                       ok     (bash 5: not ok)
//   [[ 1 == 2 ]] || return 1                    not ok
//   [ 1 = 2 ], ( [[ 1 == 2 ]] )                 not ok
//
// CI runs bash 5, so a broken assertion reads green locally and red only in
// CI. ecosystem-75a guarded 81 of these in 2026-08 without adding a lint, and
// the count grew back. This is the gate that keeps it from growing again.
//
// Reported: a statement that is exactly one `[[ ]]` or `(( ))`, starting its
// own line inside an @test body, that is not the body's last command. The
// remedy is `|| return 1` (writing-tests skill); --fix appends it. Swapping
// to `[ ]` is not offered: most of these rely on `[[ ]]`-only matching.
//
// Not reported, on purpose:
//   - `if [[ ]]`, `while [[ ]]`, `[[ ]] && x`, `[[ ]] || x`: conditions and
//     lists, not assertions. A bare `! cmd` or `x && y` mid-test asserts
//     nothing on ANY bash; shellcheck owns that (SC2314), not this lint.
//   - helper functions outside @test bodies. A helper's status is its last
//     command, the same rule one level down, and a helper that wants to be an
//     assertion has to be written as one.
//   - a `[[ ]]` continued across lines with `\`. It is rare enough to fix by
//     hand when the lint grows to cover it.
//
// Usage:
//   check-bats-assertions.mjs [--root <path>] [--fix]
//
//   --root <path>   override the repo root (used by the tests)
//   --fix           append `|| return 1` to every finding, then re-check

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const GUARD = ' || return 1';

function usageError(msg) {
  process.stderr.write(`check-bats-assertions: ${msg}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = { fix: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--root') {
      args.root = argv[++i];
      if (!args.root) usageError('--root requires a path');
    } else if (argv[i] === '--fix') {
      args.fix = true;
    } else {
      usageError(`unknown argument "${argv[i]}"`);
    }
  }
  return args;
}

function findRepoRoot(start) {
  let dir = start;
  while (dir !== dirname(dir)) {
    if (existsSync(join(dir, '.git'))) return dir;
    dir = dirname(dir);
  }
  return start;
}

function batsFiles(root) {
  const out = execFileSync('git', ['ls-files', '-z', '*.bats'], { cwd: root, encoding: 'utf8' });
  return out.split('\0').filter(Boolean);
}

// Walk one line of shell, carrying quote state across lines. Returns the
// state at the end of the line, where a comment starts (or the line length),
// a heredoc delimiter opened on this line, and whether the line ends in a
// `\` continuation. Rough by design: it knows quotes, escapes, comments and
// heredocs, which is what decides whether a line STARTS a statement.
function lex(line, state) {
  let codeEnd = line.length;
  let heredoc = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (state === 'single') {
      if (c === "'") state = 'none';
    } else if (state === 'double') {
      if (c === '\\') i++;
      else if (c === '"') state = 'none';
    } else if (c === '\\') {
      i++;
    } else if (c === "'") {
      state = 'single';
    } else if (c === '"') {
      state = 'double';
    } else if (c === '#' && (i === 0 || /[\s;]/.test(line[i - 1]))) {
      codeEnd = i;
      break;
    } else if (c === '<' && line[i + 1] === '<' && line[i + 2] !== '<') {
      const m = /^<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/.exec(line.slice(i));
      if (m) {
        heredoc = { word: m[3], dash: m[1] === '-' };
        i += m[0].length - 1;
      }
    }
  }
  const continued = state === 'none' && /\\$/.test(line.slice(0, codeEnd).trimEnd());
  return { state, codeEnd, heredoc, continued };
}

// Index just past the `]]` or `))` that closes the construct opening at
// `start`, or -1 when it does not close on this line.
function constructEnd(line, start, kind) {
  let state = 'none';
  let depth = 0;
  for (let i = start; i < line.length; i++) {
    const c = line[i];
    if (state === 'single') {
      if (c === "'") state = 'none';
      continue;
    }
    if (state === 'double') {
      if (c === '\\') i++;
      else if (c === '"') state = 'none';
      continue;
    }
    if (c === '\\') {
      i++;
    } else if (c === "'") {
      state = 'single';
    } else if (c === '"') {
      state = 'double';
    } else if (kind === 'ungated_double_bracket') {
      if (c === ']' && line[i + 1] === ']' && i > start + 2 && /\s/.test(line[i - 1])) return i + 2;
    } else if (c === '(') {
      depth++;
    } else if (c === ')') {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

// The ungated assertion on this line, if it holds one.
function assertionOn(line, codeEnd) {
  const indent = line.length - line.trimStart().length;
  const t = line.slice(indent, codeEnd);
  let kind = null;
  if (/^\[\[\s/.test(t)) kind = 'ungated_double_bracket';
  else if (/^\(\(/.test(t)) kind = 'ungated_arith';
  if (!kind) return null;

  const end = constructEnd(line, indent, kind);
  if (end === -1 || end > codeEnd) return null;
  // Exactly one construct and nothing after it but an optional `;`. Anything
  // else -- `||`, `&&`, a pipe -- makes it a list, which is not this hole.
  const rest = line.slice(end, codeEnd).trim();
  if (rest !== '' && rest !== ';') return null;
  return { kind, end };
}

function scanFile(text) {
  const lines = text.split('\n');
  const findings = [];
  let i = 0;
  while (i < lines.length) {
    if (!/^@test\s.*\{\s*$/.test(lines[i])) {
      i++;
      continue;
    }
    // The body runs to the next column-0 `}`, which is how every bats file in
    // this repo closes a test.
    const candidates = [];
    let lastCode = -1;
    let state = 'none';
    let heredoc = null;
    let continued = false;
    for (i++; i < lines.length && !/^\}\s*$/.test(lines[i]); i++) {
      const line = lines[i];
      if (heredoc) {
        const body = heredoc.dash ? line.replace(/^\t+/, '') : line;
        if (body === heredoc.word) heredoc = null;
        continue;
      }
      const startsStatement = state === 'none' && !continued;
      const lexed = lex(line, state);
      if (startsStatement && line.slice(0, lexed.codeEnd).trim() !== '') {
        lastCode = i;
        const a = assertionOn(line, lexed.codeEnd);
        if (a) candidates.push({ line: i, ...a });
      } else if (!startsStatement) {
        lastCode = i;
      }
      state = lexed.state;
      heredoc = lexed.heredoc;
      continued = lexed.continued;
    }
    for (const c of candidates) if (c.line !== lastCode) findings.push(c);
    i++;
  }
  return findings;
}

function scan(root, fix) {
  const findings = [];
  for (const file of batsFiles(root)) {
    const path = join(root, file);
    const text = readFileSync(path, 'utf8');
    const found = scanFile(text);
    if (found.length === 0) continue;
    if (fix) {
      const lines = text.split('\n');
      for (const f of found) lines[f.line] = lines[f.line].slice(0, f.end) + GUARD + lines[f.line].slice(f.end);
      writeFileSync(path, lines.join('\n'));
      continue;
    }
    const lines = text.split('\n');
    for (const f of found) findings.push({ ...f, file, text: lines[f.line].trim() });
  }
  return findings;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const here = dirname(fileURLToPath(import.meta.url));
  const root = args.root ? resolve(args.root) : findRepoRoot(here);

  if (args.fix) scan(root, true);
  const findings = scan(root, false);
  for (const f of findings) {
    process.stdout.write(`  ${f.kind}  ${f.file}:${f.line + 1}  ${f.text}\n`);
  }
  if (findings.length > 0) {
    process.stdout.write(`check-bats-assertions: ${findings.length} finding(s); append \`|| return 1\` or run --fix\n`);
    process.exit(1);
  }
  process.stdout.write('check-bats-assertions: ok\n');
}

main();
