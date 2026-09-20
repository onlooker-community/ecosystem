#!/usr/bin/env node
// Bus coverage gates.
//
// Gate A: no emission recorded during the suite was rejected by the schema.
//
// Reads the report the emitter writes when ONLOOKER_TEST_REPORT_DIR is set —
// see recordEmission in scripts/lib/onlooker-event.mjs. A rejected emission is
// invisible any other way: the emitter exits 1 and prints ajv errors, and the
// hook's fail-soft exit 0 destroys both.
//
// Gate B: every registered event type is accounted for — either it produced
// a validated emission during the suite, or the manifest excuses it with a
// stated reason. See test/bus-coverage.json.
//
// Completeness gate: both gates above are only meaningful against a report that
// one complete, uncontended `npm run test:bats` produced. scripts/test/run-bats.sh
// stamps every emission with a run id and writes complete.json when the suite
// finishes; this gate requires that sentinel and refuses a report carrying
// records from any other run. Without it a clobbered report — two agents running
// the suite in one checkout, where test:bats opens with `rm -rf` on a shared
// path — produced a wall of "expected type never emitted" that reads exactly
// like a real coverage regression. See ecosystem-0bh.
//
// Exit codes:
//   0  ok
//   1  completeness, gate A, or gate B failure
//   2  unknown argument
//
// Usage: check-bus-coverage.mjs [--report <dir>] [--manifest <path>]
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

const SENTINEL = 'complete.json';

function loadSentinel(dir) {
  const p = join(dir, SENTINEL);
  if (!existsSync(p)) return null;
  try {
    return JSON.parse(readFileSync(p, 'utf8'));
  } catch {
    // A corrupt sentinel is not a completed run either.
    return null;
  }
}

/**
 * Completeness gate: did one whole, uncontended suite produce this report?
 *
 * Returns failures that must SUPPRESS gate B rather than accompany it — a
 * partial report makes every unreached type look like a coverage regression.
 */
function gateComplete(lines, sentinel, dir) {
  const failures = [];
  if (!sentinel?.run_id) {
    failures.push(
      `no completed \`npm run test:bats\` run recorded — ${join(dir, SENTINEL)} is absent or ` +
        'unreadable, so the suite either never ran against this report or did not finish. ' +
        'Coverage was NOT checked.',
    );
    return failures;
  }
  if (sentinel.bats_status !== 0) {
    failures.push(
      `the recorded test:bats run exited ${sentinel.bats_status} — fix the suite before trusting ` +
        'its coverage. Coverage was NOT checked.',
    );
  }
  // Records with no run id are fine: test:schema appends to the same directory
  // after the sentinel is written, and its records are inert for both gates.
  const foreign = [...new Set(lines.map((l) => l.run_id).filter((id) => id != null && id !== sentinel.run_id))];
  if (foreign.length) {
    failures.push(
      `report mixes records from ${foreign.length} other run(s) (${foreign.join(', ')}) — a ` +
        'concurrent `npm run test:bats` in this checkout overwrote part of it. Re-run the suite ' +
        'on its own. Coverage was NOT checked.',
    );
  }
  return failures;
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
  const incomplete = gateComplete(lines, loadSentinel(args.report), args.report);
  failures.push(...incomplete);
  // Skip Gate B unless the report is both complete and genuinely validated. A
  // partial report, or a merely non-empty one where nothing validated (schema
  // package never resolved), would otherwise bury the one real failure under a
  // spurious "expected type never emitted" line for every expected type.
  if (incomplete.length === 0 && lines.some((l) => l.validated === true)) {
    failures.push(...(await gateB(lines, args.manifest)));
  }
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
