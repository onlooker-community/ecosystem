#!/usr/bin/env node
// Find hazardous bash arithmetic: config values that reach (( )) without
// numeric validation.
//
// ONL-132. The house config-fallback idiom guards empty and the literal
// "null" and nothing else, so a non-numeric value reaches (( )) where bash
// treats the bare word as a variable name, `set -u` stops the shell, and --
// because these scripts use `set -uo pipefail` deliberately without -e -- the
// status left behind is 0. A caller reads success and finds no artifacts.
//
// This exists as a committed script rather than a grep because three ad-hoc
// sweeps produced three different scopes (24 files, 5 files, 12 files) and the
// migration's scope IS this output. A number nobody can re-derive is the thing
// ADR-004 exists to prevent.
//
// Two hazard kinds are reported, deliberately kept distinct because the
// remedies differ:
//
//   unguarded_config_int  a config value reaches arithmetic unvalidated.
//                         Fix: read it through onlooker_config_int.
//   unguarded_increment   `(( x++ ))` returns its PRE-increment value, so the
//                         first bump from 0 exits 1 and aborts under errexit
//                         (ONL-29). Fix: `|| true`, as run-audit.sh already does.
//
// NOT wired into `npm run test:ci`. It currently reports 42 pre-existing
// findings, so adding it as a gate would fail CI on day one. Turning it into a
// gate needs a baseline of the known set, which is scoped separately -- the
// output is one finding per line and byte-stable across runs specifically so a
// baseline can be diffed against it.
//
// Usage:
//   check-bash-arithmetic.mjs [--root <path>]
//
//   --root <path>   override the repo root (used by the tests)

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Vendored libs exist once per plugin, so a finding in one would be reported
// N times for a single defect. The canonical copy under scripts/lib is still
// scanned.
const VENDORED = new Set([
  'hook-health.sh',
  'portable-lock.sh',
  'config-loader.sh',
  'substrate-resolve.sh',
  'watch-unmatched.sh',
]);

function usageError(msg) {
  process.stderr.write(`check-bash-arithmetic: ${msg}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--root') {
      args.root = argv[++i];
      if (!args.root) usageError('--root requires a path');
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

function shellFiles(root) {
  const out = execFileSync('git', ['ls-files', '-z', '*.sh'], { cwd: root, encoding: 'utf8' });
  return out
    .split('\0')
    .filter(Boolean)
    .filter((f) => {
      const base = f.slice(f.lastIndexOf('/') + 1);
      // Skip the per-plugin COPIES only. The canonical copy under scripts/lib
      // is still scanned, so a real defect is reported exactly once, at the
      // path where fixing it propagates to every plugin.
      const isVendoredCopy = (VENDORED.has(base) || base.endsWith('-ulid.sh')) && f.startsWith('plugins/');
      return !isVendoredCopy;
    });
}

// Any VAR=$(command ...) assignment. Classified afterwards rather than
// matched narrowly, because a config value arrives two ways and anchoring on
// just one is what made the earlier hand-greps disagree.
const ANY_ASSIGN = /^[ \t]*(?:local[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=\$\(([^)]*)\)/gm;

// Shell function definitions, name -> body.
const FUNCTION_DEF = /^([A-Za-z_][A-Za-z0-9_]*)\(\)[ \t]*\{\n([\s\S]*?)\n\}/gm;

// Pass 1: which functions RETURN a config value. A guard may live here rather
// than in the consumer -- historian's MAX_EMBED_CHARS is validated in the
// consumer but sourced from historian_embedder_max_input_chars(), while
// inspector's max_bytes is guarded in neither. A sweep that reads only one
// side miscounts in both directions, so both are resolved.
//
// "Mentions _config_get" is NOT the test. governor_estimate_tokens reads
// .governor.estimation.safety_margin and returns a computed token estimate; by
// that looser rule its caller looked like it held an unvalidated config string
// and was reported as a finding. An accessor's actual signature is that it
// PRINTS the value it read, so that is what is matched.
function configAccessors(root, files) {
  const accessors = new Map();
  for (const file of files) {
    const src = readFileSync(join(root, file), 'utf8');
    for (const [, name, body] of src.matchAll(FUNCTION_DEF)) {
      // The local that holds the config read.
      const read = body.match(/([A-Za-z_][A-Za-z0-9_]*)=\$\([^)]*_config_get[^)]*\)/);
      if (!read) continue;
      const cfgVar = read[1];
      // ... and a RETURN statement that emits it unchanged.
      //
      // Scoped to the body's last statement, not to any printf in it. The
      // looser version matched a printf nested inside an awk string --
      // governor_estimate_tokens builds its estimate with
      // `awk "BEGIN { printf ..., int($chars / $cpt * $safety_margin) }"` --
      // so a function that merely multiplies BY a config value read as one
      // that returns it.
      const lines = body
        .split('\n')
        .map((l) => l.trim())
        .filter((l) => l !== '' && !l.startsWith('#'));
      const last = lines[lines.length - 1] || '';
      // The accessor shape: the config var is the whole emitted value,
      // optionally with a :- default. Arithmetic around it disqualifies it.
      const returnsIt = new RegExp(`^(?:printf|echo)\\b[^\\n]*"\\$\\{?${cfgVar}(?::-[^}"]*)?\\}?"[ \t]*$`).test(last);
      if (returnsIt) accessors.set(name, body);
    }
  }
  return accessors;
}

// Every site that evaluates its operands as arithmetic, so a variable's uses
// can be found without matching its name in unrelated prose or strings.
//
// Two forms, not one. (( )) and $(( )) are the obvious half. The other is
// `[[ x -gt y ]]`: the arithmetic comparison operators inside [[ ]] evaluate
// their operands arithmetically and die identically --
//   v="not-a-number"; [[ "$v" -gt 0 ]]  ->  "not: unbound variable", status 0
// Single-bracket `[ ]` is deliberately NOT included: test(1) reports "integer
// expression expected", takes the false branch, and the script carries on, so
// it degrades loudly instead of silently.
// Scoped to the OPERANDS of the arithmetic operator, not the whole bracket.
// Capturing the bracket reported curator's
//   [[ "$OPEN_COUNT" -eq 0 && "$SKIP_WHEN_ZERO" == "true" ]]
// as putting SKIP_WHEN_ZERO at risk -- it is a boolean on the == side and is
// never evaluated arithmetically.
const ARITH_COMPARE = /(\S+)[ \t]+-(?:eq|ne|lt|le|gt|ge)[ \t]+(\S+)/g;

function arithmeticExpressions(src) {
  const out = [...src.matchAll(/\(\(([^)]*)\)\)/g)].map((m) => m[1]);
  // Only inside [[ ]] -- single-bracket [ ] reports "integer expression
  // expected" and carries on, so it is not a silent-death site.
  for (const [, inner] of src.matchAll(/\[\[([\s\S]*?)\]\]/g)) {
    for (const [, lhs, rhs] of inner.matchAll(ARITH_COMPARE)) out.push(`${lhs} ${rhs}`);
  }
  return out;
}

// A numeric guard on this variable, anywhere in the file: the repo spells it
// [[ "$VAR" =~ ^[0-9]+$ ]].
function hasNumericGuard(src, v) {
  return new RegExp(`${v}["}\\s]*\\}?["\\s]*=~[^\\n]*\\[0-9`).test(src);
}

// Any numeric guard inside an accessor body, regardless of what the local is
// called. Keyed to the guard rather than the variable name on purpose: the
// repo's accessors mostly spell it `local v`, and a check hardcoded to that
// would pass on the common case while missing every accessor that names it
// anything else.
function bodyHasNumericGuard(body) {
  return /=~[^\n]*\[0-9/.test(body);
}

// A bare `(( x++ ))` or `(( x-- ))` standing alone as a command. The repo
// already knows the remedy -- run-audit.sh guards all five of its counters
// with `|| true` -- so a trailing `|| true` / `|| :` is the accepted form and
// is not reported.
const BARE_INCREMENT = /^[ \t]*\(\([ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?:\+\+|--)[ \t]*\)\)[ \t]*$/;

function incrementFindings(file, src) {
  const out = [];
  src.split('\n').forEach((line, i) => {
    const m = BARE_INCREMENT.exec(line);
    if (m) out.push({ kind: 'unguarded_increment', file, variable: m[1], line: i + 1, sites: 1 });
  });
  return out;
}

function scan(root) {
  const files = shellFiles(root);
  const accessors = configAccessors(root, files);
  const findings = [];

  for (const file of files) {
    const src = readFileSync(join(root, file), 'utf8');
    findings.push(...incrementFindings(file, src));

    // variable -> the accessor body it came through, or '' for a direct read.
    const derived = new Map();
    for (const [, name, inner] of src.matchAll(ANY_ASSIGN)) {
      if (/_config_get/.test(inner)) {
        derived.set(name, '');
        continue;
      }
      const callee = inner.trim().split(/[ \t]/)[0];
      if (accessors.has(callee)) derived.set(name, accessors.get(callee));
    }
    if (derived.size === 0) continue;

    const exprs = arithmeticExpressions(src);
    for (const v of [...derived.keys()].sort()) {
      const uses = exprs.filter((e) => new RegExp(`\\b${v}\\b`).test(e)).length;
      if (uses === 0) continue;
      // Guarded on either side is guarded.
      if (hasNumericGuard(src, v)) continue;
      if (bodyHasNumericGuard(derived.get(v))) continue;
      findings.push({ kind: 'unguarded_config_int', file, variable: v, sites: uses });
    }
  }
  return findings;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const here = dirname(fileURLToPath(import.meta.url));
  const root = args.root ? resolve(args.root) : findRepoRoot(here);

  const findings = scan(root);
  for (const f of findings) {
    const where = f.line ? `${f.file}:${f.line}` : f.file;
    process.stdout.write(`  ${f.kind}  ${where}  $${f.variable}  (${f.sites} site(s))\n`);
  }
  if (findings.length > 0) {
    process.stdout.write(`check-bash-arithmetic: ${findings.length} finding(s)\n`);
    process.exit(1);
  }
  process.stdout.write('check-bash-arithmetic: ok\n');
}

main();
