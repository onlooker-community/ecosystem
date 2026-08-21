#!/usr/bin/env node
/**
 * Bus coverage gates.
 *
 * Gate A: no emission recorded during the suite was rejected by the schema.
 *
 * Reads the report the emitter writes when ONLOOKER_TEST_REPORT_DIR is set —
 * see recordEmission in scripts/lib/onlooker-event.mjs. A rejected emission is
 * invisible any other way: the emitter exits 1 and prints ajv errors, and the
 * hook's fail-soft exit 0 destroys both.
 *
 * Usage: check-bus-coverage.mjs [--report <dir>]
 */
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');

function parseArgs(argv) {
  const out = { report: join(REPO_ROOT, 'test', 'tmp-emission-report') };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--report') out.report = argv[++i];
    else if (a === '--help') {
      process.stderr.write('Usage: check-bus-coverage.mjs [--report <dir>]\n');
      process.exit(0);
    } else {
      process.stderr.write(`check-bus-coverage: unknown argument: ${a}\n`);
      process.exit(2);
    }
  }
  return out;
}

function loadReport(dir) {
  const p = join(dir, 'emissions.jsonl');
  if (!existsSync(p)) return [];
  return readFileSync(p, 'utf8')
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function gateA(lines) {
  const failures = [];
  if (lines.length === 0) {
    failures.push('no emissions recorded — run `npm run test:bats` with ONLOOKER_TEST_REPORT_DIR set');
    return failures;
  }
  if (!lines.some((l) => l.validated === true)) {
    failures.push(
      'no emission was validated: @onlooker-community/schema did not resolve, so this gate ' +
        'checked nothing. Run `npm ci` and try again.',
    );
  }
  for (const l of lines.filter((x) => x.valid === false)) {
    failures.push(`rejected emission: ${l.event_type} — ${JSON.stringify(l.errors)}`);
  }
  return failures;
}

function main() {
  const args = parseArgs(process.argv);
  const lines = loadReport(args.report);
  const failures = gateA(lines);
  if (failures.length) {
    for (const f of failures) process.stderr.write(`check-bus-coverage: ${f}\n`);
    process.exit(1);
  }
  process.stdout.write(`check-bus-coverage: ok (${lines.length} emission(s))\n`);
}

const isMain = process.argv[1]?.endsWith('check-bus-coverage.mjs') ?? false;
if (isMain) main();
