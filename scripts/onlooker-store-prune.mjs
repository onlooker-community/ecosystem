#!/usr/bin/env node
// One-shot prune for the Onlooker store.
//
// The store's problem is not age, it is file count: 150,725 per-session files
// averaging 545 bytes, each consuming a 4KB block, so 87% of the on-disk
// footprint is block waste (ecosystem-449.2). The permanent fix is on the write
// path; this script reclaims what was already written.
//
// Run by hand. There is deliberately no recurring sweep — see
// docs/superpowers/specs/2026-08-30-onlooker-store-retention-design.md §5.
//
// Exit code is always 0. This never blocks anything.
//
// Usage:
//   node scripts/onlooker-store-prune.mjs [--dir <path>]
//     [--scratch-max-age-hours <n>] [--retention-days <n>] [--dry-run] [--json]
import { existsSync, readdirSync, readFileSync, statSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

// Explicit allowlist. A denylist would silently swallow any store added later,
// and this script deletes files. Anything not named here is never touched —
// historian, lineage, archivist, librarian, curator, buffer.db, and logs/.
const STORES = [
  { name: 'session-trackers', segments: ['session-trackers'], policy: 'scratch' },
  { name: 'session-history', segments: ['session-history'], policy: 'retention' },
  { name: 'scribe/sessions', segments: ['scribe', 'sessions'], policy: 'retention', pruneEmptyScribe: true },
  { name: 'bursar/sessions', segments: ['bursar', 'sessions'], policy: 'retention' },
  { name: 'compass/sessions', segments: ['compass', 'sessions'], policy: 'retention' },
  { name: 'lineage-baselines', segments: ['lineage-baselines'], policy: 'scratch', nested: true },
];

function parseArgs(argv) {
  const out = {
    dir: process.env.ONLOOKER_DIR || join(homedir(), '.onlooker'),
    scratchMaxAgeHours: 48,
    retentionDays: 90,
    dryRun: false,
    json: false,
    help: false,
  };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--dir') out.dir = argv[++i];
    else if (a === '--scratch-max-age-hours') out.scratchMaxAgeHours = Number(argv[++i]);
    else if (a === '--retention-days') out.retentionDays = Number(argv[++i]);
    else if (a === '--dry-run') out.dryRun = true;
    else if (a === '--json') out.json = true;
    else if (a === '--help') {
      process.stdout.write(
        'Usage: onlooker-store-prune.mjs [--dir <path>] [--scratch-max-age-hours <n>]\n' +
          '       [--retention-days <n>] [--dry-run] [--json]\n',
      );
      out.help = true;
      return out;
    }
  }
  return out;
}

// A scribe state file whose captured_prompt is null carries no information.
// Deleting one is safe at any age: scribe-capture.sh recreates it with a real
// payload on the next prompt, so even a live session loses nothing.
function isPayloadFreeScribeFile(path) {
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8'));
    return parsed.captured_prompt === null || parsed.captured_prompt === undefined;
  } catch {
    // Unreadable or malformed: leave it alone rather than guess.
    return false;
  }
}

function pruneStore(root, store, opts, now) {
  const base = join(root, ...store.segments);
  const result = { name: store.name, scanned: 0, deleted: 0, reclaimedBytes: 0 };
  if (!existsSync(base)) return result;

  const cutoff =
    store.policy === 'scratch' ? now - opts.scratchMaxAgeHours * HOUR_MS : now - opts.retentionDays * DAY_MS;

  // Most stores are flat. lineage-baselines is partitioned one level down, by
  // the per-repo baseline scope id — a flat read would scan nothing and report
  // success, which is how a store silently stops being pruned.
  let dirs = [base];
  if (store.nested === true) {
    try {
      dirs = readdirSync(base, { withFileTypes: true })
        .filter((e) => e.isDirectory())
        .map((e) => join(base, e.name));
    } catch {
      return result; // Unreadable directory: fail soft.
    }
  }

  for (const dir of dirs) {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue; // Unreadable subdirectory: skip, don't fail the run.
    }

    for (const entry of entries) {
      if (!entry.isFile()) continue;
      const path = join(dir, entry.name);
      let st;
      try {
        st = statSync(path);
      } catch {
        continue;
      }
      result.scanned += 1;

      const tooOld = st.mtimeMs < cutoff;
      const emptyScribe = store.pruneEmptyScribe === true && isPayloadFreeScribeFile(path);
      if (!tooOld && !emptyScribe) continue;

      // Report on-disk cost, not logical size — block waste is the whole point.
      const onDisk = st.blocks * 512;
      if (!opts.dryRun) {
        try {
          unlinkSync(path);
        } catch {
          continue; // Vanished or locked: skip without failing the run.
        }
      }
      result.deleted += 1;
      result.reclaimedBytes += onDisk;
    }
  }
  return result;
}

function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) return;
  const now = Date.now();
  const stores = STORES.map((s) => pruneStore(opts.dir, s, opts, now));
  const totals = stores.reduce(
    (acc, s) => ({
      scanned: acc.scanned + s.scanned,
      deleted: acc.deleted + s.deleted,
      reclaimedBytes: acc.reclaimedBytes + s.reclaimedBytes,
    }),
    { scanned: 0, deleted: 0, reclaimedBytes: 0 },
  );
  const report = { root: opts.dir, dryRun: opts.dryRun, stores, totals };

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(report)}\n`);
  } else {
    const verb = opts.dryRun ? 'would delete' : 'deleted';
    for (const s of stores) {
      process.stdout.write(
        `${s.name.padEnd(20)} scanned ${String(s.scanned).padStart(7)}  ${verb} ${String(s.deleted).padStart(7)}  ${(s.reclaimedBytes / 1e6).toFixed(1)}MB\n`,
      );
    }
    process.stdout.write(
      `${'TOTAL'.padEnd(20)} scanned ${String(totals.scanned).padStart(7)}  ${verb} ${String(totals.deleted).padStart(7)}  ${(totals.reclaimedBytes / 1e6).toFixed(1)}MB\n`,
    );
  }
  // No process.exit(0). stdout is async when it is a pipe, and process.exit()
  // drops whatever is still buffered — which is every byte of the report under
  // `npm run store:prune | ...` or bats' `run node ...`. Falling off the end of
  // main() lets the write flush and exits 0 on its own.
}

main();
