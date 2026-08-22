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
 * Gate B: every registered event type is accounted for — either it produced
 * a validated emission during the suite, or the manifest excuses it with a
 * stated reason. See test/bus-coverage.json.
 *
 * Usage: check-bus-coverage.mjs [--report <dir>] [--manifest <path>]
 */
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');

function parseArgs(argv) {
  const out = {
    report: join(REPO_ROOT, 'test', 'tmp-emission-report'),
    manifest: join(REPO_ROOT, 'test', 'bus-coverage.json'),
  };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--report') out.report = argv[++i];
    else if (a === '--manifest') out.manifest = argv[++i];
    else if (a === '--help') {
      process.stderr.write('Usage: check-bus-coverage.mjs [--report <dir>] [--manifest <path>]\n');
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

/**
 * Gate B: every registered event type is accounted for.
 *
 * `expected` types must have produced a validated emission during the suite.
 * `excluded` types must carry a reason and must NOT have been emitted —
 * otherwise coverage is silently under-claimed and the manifest can drift
 * downward without CI noticing. Together `expected` and `excluded` must
 * equal ALL_EVENT_TYPES exactly, so a newly registered type belongs to
 * neither and fails here until someone triages it deliberately.
 */
async function gateB(lines, manifestPath) {
  const failures = [];
  let schema;
  try {
    schema = await import('@onlooker-community/schema');
  } catch {
    return ['@onlooker-community/schema is not installed; run `npm ci`'];
  }
  const registered = new Set(schema.ALL_EVENT_TYPES);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const expected = manifest.expected ?? [];
  const excluded = manifest.excluded ?? {};

  const emitted = new Set(lines.filter((l) => l.valid === true).map((l) => l.event_type));
  for (const t of expected) {
    if (!emitted.has(t)) failures.push(`expected type never emitted during the suite: ${t}`);
  }

  const accounted = new Set([...expected, ...Object.keys(excluded)]);
  for (const t of registered) {
    if (!accounted.has(t)) {
      failures.push(`registered type is in neither list — triage it in the manifest: ${t}`);
    }
  }
  for (const t of accounted) {
    if (!registered.has(t)) {
      failures.push(`manifest names a type the schema does not register: ${t}`);
    }
  }
  for (const [t, reason] of Object.entries(excluded)) {
    if (!reason || !String(reason).trim()) {
      failures.push(`excluded type needs a reason: ${t}`);
    }
  }
  // An excluded type that is actually emitted and valid is coverage silently
  // under-claimed: the manifest says "nothing tests this" while the suite
  // does. Catch it before the manifest can drift downward unnoticed.
  for (const t of Object.keys(excluded)) {
    if (emitted.has(t)) {
      failures.push(`excluded type is actually emitted — move it to expected: ${t}`);
    }
  }
  return failures;
}

async function main() {
  const args = parseArgs(process.argv);
  const lines = loadReport(args.report);
  const failures = gateA(lines);
  // Skip Gate B unless something was genuinely validated. A merely
  // non-empty report where nothing validated (schema package never
  // resolved) would otherwise bury the one real failure under a spurious
  // "expected type never emitted" line for every expected type.
  if (lines.some((l) => l.validated === true)) failures.push(...(await gateB(lines, args.manifest)));
  if (failures.length) {
    for (const f of failures) process.stderr.write(`check-bus-coverage: ${f}\n`);
    process.exit(1);
  }
  process.stdout.write(`check-bus-coverage: ok (${lines.length} emission(s))\n`);
}

const isMain = process.argv[1]?.endsWith('check-bus-coverage.mjs') ?? false;
if (isMain) {
  main().catch((err) => {
    process.stderr.write(`check-bus-coverage: ${err.message}\n`);
    process.exit(1);
  });
}
