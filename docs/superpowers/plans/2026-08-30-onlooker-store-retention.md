# Bounding the Onlooker store — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the Onlooker store minting a 4KB block per empty per-session file, and reclaim the ~254MB already spent on them.

**Architecture:** Two independent changes. A one-line-ish deletion in scribe's `SessionStart` hook stops payload-free files being created; a new standalone Node script prunes the existing backlog when run by hand. No new hook, no new event types, no config block — see `docs/superpowers/specs/2026-08-30-onlooker-store-retention-design.md` §5 for what was deliberately cut and why.

**Tech Stack:** bash hooks, Node 20+ ESM (`node:fs`, no dependencies), bats for tests, `jq` inside hooks.

## Global Constraints

- **Read the spec first:** `docs/superpowers/specs/2026-08-30-onlooker-store-retention-design.md`. Every decision below traces to it.
- **Never hardcode `~/.onlooker`.** Always `$ONLOOKER_DIR`, defaulting to `$HOME/.onlooker`, so the test suite's isolated temp home is honored.
- **Fail soft.** A missing store, an unreadable directory, or malformed JSON ends the operation cleanly with exit 0. Nothing here may block a session.
- **Hooks always exit 0.** Assert on side effects, never on a non-zero exit code.
- **Allowlist, never denylist.** This code deletes files. A store not named explicitly is never touched.
- **Durable stores are off limits:** `historian`, `lineage`, `archivist`, `librarian`, `curator`, `buffer.db`, and everything under `logs/`.
- **bats gotcha:** every non-final `[[ ]]` assertion needs `|| return 1`. Only the last assertion in a test body gates on its own. See `.claude/skills/writing-tests`.
- **American English** in all comments, commit messages, and docs.
- Commit via the `/commit` skill. Conventional commits, subject ≤72 chars including a mood emoji.

---

### Task 1: scribe stops writing payload-free state files

**Files:**

- Modify: `plugins/scribe/scripts/hooks/scribe-session-start.sh:1-10` (header comment) and `:44-58` (the write block)
- Test: `test/bats/scribe-session-start.bats` (create)

**Interfaces:**

- Consumes: nothing from other tasks.
- Produces: the invariant Task 2's `--empty-scribe` rule depends on — after this change, a payload-free `scribe/sessions/<id>.json` can only be a legacy file, never one a live session still needs.

**Why this is safe.** Both consumers already handle the file being absent:

- `plugins/scribe/scripts/hooks/scribe-capture.sh:69-77` has an else-branch that creates the file with a full payload when it does not exist.
- `plugins/scribe/scripts/lib/scribe-distill.sh:137-140` guards its read with `[[ -f "$state_file" ]]` and falls back to an empty `captured_prompt`.

- [ ] **Step 1: Write the failing test**

Create `test/bats/scribe-session-start.bats`:

```bash
#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/scribe"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  START_HOOK="${PLUGIN_ROOT}/scripts/hooks/scribe-session-start.sh"
  CAPTURE_HOOK="${PLUGIN_ROOT}/scripts/hooks/scribe-capture.sh"
  SESSION_DIR="${ONLOOKER_DIR}/scribe/sessions"
}

_start_input() {
  jq -cn --arg cwd "$BATS_TEST_TMPDIR" --arg sid "sess-alpha" \
    '{cwd: $cwd, session_id: $sid, hook_event_name: "SessionStart"}'
}

_capture_input() {
  jq -cn --arg cwd "$BATS_TEST_TMPDIR" --arg sid "sess-alpha" --arg p "why is the gate failing" \
    '{cwd: $cwd, session_id: $sid, prompt: $p, hook_event_name: "UserPromptSubmit"}'
}

@test "session start creates no state file" {
  run bash -c "printf '%s' '$(_start_input)' | '$START_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "${SESSION_DIR}/sess-alpha.json" ]
}

@test "session start still creates the sessions directory" {
  run bash -c "printf '%s' '$(_start_input)' | '$START_HOOK'"
  [ "$status" -eq 0 ]
  [ -d "$SESSION_DIR" ]
}

@test "capture creates the state file with a payload on first prompt" {
  run bash -c "printf '%s' '$(_start_input)' | '$START_HOOK'"
  [ "$status" -eq 0 ] || return 1
  run bash -c "printf '%s' '$(_capture_input)' | '$CAPTURE_HOOK'"
  [ "$status" -eq 0 ] || return 1
  [ -f "${SESSION_DIR}/sess-alpha.json" ] || return 1
  run jq -r '.captured_prompt' "${SESSION_DIR}/sess-alpha.json"
  [ "$output" = "why is the gate failing" ]
}

@test "capture without a prior session start still creates the state file" {
  run bash -c "printf '%s' '$(_capture_input)' | '$CAPTURE_HOOK'"
  [ "$status" -eq 0 ] || return 1
  run jq -r '.captured_prompt' "${SESSION_DIR}/sess-alpha.json"
  [ "$output" = "why is the gate failing" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bats test/bats/scribe-session-start.bats
```

Expected: the first two tests fail — `session start creates no state file` fails because the hook currently writes one. The last two should already pass.

- [ ] **Step 3: Remove the eager write**

In `plugins/scribe/scripts/hooks/scribe-session-start.sh`, delete these lines entirely:

```bash
[[ -z "$SESSION_ID" ]] && _done

STATE_FILE="${SCRIBE_SESSION_DIR}/${SESSION_ID}.json"

jq -n \
	--arg sid "$SESSION_ID" \
	'{
		session_id: $sid,
		captured_prompt: null,
		captured_at: null
	}' 2>/dev/null > "$STATE_FILE" || {
	printf 'scribe-session-start: failed to write state file %s\n' "$STATE_FILE" >&2
	_done
}

_done
```

Replace with:

```bash
_done
```

Keep everything above it — `hook_health_register`, `scribe_config_load`, the `SCRIBE_SESSION_DIR` assignment and its `mkdir -p`.

- [ ] **Step 4: Update the header comment to match**

Replace lines 2-8 of the same file:

```bash
# Scribe SessionStart hook.
#
# Fires at every session start. Responsibilities:
#   1. Create storage directories.
#
# Deliberately does NOT create the session state file. It used to, with
# captured_prompt and captured_at both null, which meant every session that
# never submitted a prompt left a payload-free file behind — 65% of scribe's
# 37,403 files, 100MB of 4KB blocks holding zero information (ecosystem-449.2).
# scribe-capture.sh creates the file with a real payload on the first prompt,
# and scribe-distill.sh tolerates its absence, so nothing needs the empty one.
#
# Hook contract:
#   - Always exits 0. Never blocks SessionStart.
#   - Errors are written to stderr only; stdout is kept clean.
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bats test/bats/scribe-session-start.bats
```

Expected: all four PASS.

- [ ] **Step 6: Confirm nothing else depended on the eager write**

```bash
npm run test:bats
shellcheck -S error -x plugins/scribe/scripts/hooks/scribe-session-start.sh
```

Expected: full bats suite green, shellcheck silent. `SESSION_ID` is now assigned and unused, which is fine — it feeds `hook_health_context`. If shellcheck disagrees, keep the assignment and do not delete the `hook_health_context "$INPUT"` call.

- [ ] **Step 7: Commit**

Use the `/commit` skill. Suggested message:

```text
fix(scribe): stop writing a state file with nothing in it :broom:

65% of scribe's 37,403 session files held exactly captured_prompt: null --
100MB of 4KB blocks carrying zero information, one per session that never
submitted a prompt. scribe-capture.sh already creates the file with a real
payload on first prompt and scribe-distill.sh already tolerates its absence,
so the SessionStart write was pure cost.

Refs ecosystem-449.2
```

---

### Task 2: one-shot prune script for the existing backlog

**Files:**

- Create: `scripts/onlooker-store-prune.mjs`
- Modify: `package.json` (add a `store:prune` script entry)
- Test: `test/bats/onlooker-store-prune.bats` (create)

**Interfaces:**

- Consumes: the invariant from Task 1 — payload-free scribe files are legacy only.
- Produces: `scripts/onlooker-store-prune.mjs`, invoked as
  `node scripts/onlooker-store-prune.mjs [--dir <path>] [--scratch-max-age-hours <n>] [--retention-days <n>] [--dry-run] [--json]`.
  Exits 0 always. With `--json`, writes one JSON object to stdout with shape
  `{ root, dryRun, stores: [{ name, scanned, deleted, reclaimedBytes }], totals: { scanned, deleted, reclaimedBytes } }`.

**Why deleting a payload-free scribe file is always safe:** `scribe-capture.sh:69-77` recreates it with a full payload on the next prompt. Even if one belonged to a live session, nothing is lost.

- [ ] **Step 1: Write the failing test**

Create `test/bats/onlooker-store-prune.bats`:

```bash
#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PRUNE="${REPO_ROOT}/scripts/onlooker-store-prune.mjs"
  mkdir -p "${ONLOOKER_DIR}/session-trackers" \
           "${ONLOOKER_DIR}/session-history" \
           "${ONLOOKER_DIR}/scribe/sessions" \
           "${ONLOOKER_DIR}/historian/abc123/sessions" \
           "${ONLOOKER_DIR}/lineage/abc123" \
           "${ONLOOKER_DIR}/logs"
}

# Age a file by setting its mtime N days into the past.
_age_days() {
  local path="$1" days="$2"
  python3 -c "import os,sys,time; p=sys.argv[1]; d=float(sys.argv[2]); t=time.time()-d*86400; os.utime(p,(t,t))" "$path" "$days"
}

@test "prunes scratch trackers older than the window" {
  printf '{"turn_number":1}' > "${ONLOOKER_DIR}/session-trackers/old"
  printf '{"turn_number":1}' > "${ONLOOKER_DIR}/session-trackers/fresh"
  _age_days "${ONLOOKER_DIR}/session-trackers/old" 5

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/session-trackers/old" ] || return 1
  [ -f "${ONLOOKER_DIR}/session-trackers/fresh" ]
}

@test "keeps analysis files inside the retention window" {
  printf '{}' > "${ONLOOKER_DIR}/session-history/recent.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/recent.jsonl" 30

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ -f "${ONLOOKER_DIR}/session-history/recent.jsonl" ]
}

@test "prunes analysis files past the retention window" {
  printf '{}' > "${ONLOOKER_DIR}/session-history/ancient.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/ancient.jsonl" 120

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/session-history/ancient.jsonl" ]
}

@test "deletes a payload-free scribe file but keeps one with a prompt" {
  printf '{"session_id":"a","captured_prompt":null,"captured_at":null}' \
    > "${ONLOOKER_DIR}/scribe/sessions/empty.json"
  printf '{"session_id":"b","captured_prompt":"real work","captured_at":"2026-08-01T00:00:00Z"}' \
    > "${ONLOOKER_DIR}/scribe/sessions/full.json"

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/scribe/sessions/empty.json" ] || return 1
  [ -f "${ONLOOKER_DIR}/scribe/sessions/full.json" ]
}

@test "never touches durable stores or logs" {
  printf '{}' > "${ONLOOKER_DIR}/historian/abc123/sessions/old.jsonl"
  printf '{}' > "${ONLOOKER_DIR}/lineage/abc123/changes.jsonl"
  printf '{}' > "${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
  _age_days "${ONLOOKER_DIR}/historian/abc123/sessions/old.jsonl" 400
  _age_days "${ONLOOKER_DIR}/lineage/abc123/changes.jsonl" 400
  _age_days "${ONLOOKER_DIR}/logs/onlooker-events.jsonl" 400

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ -f "${ONLOOKER_DIR}/historian/abc123/sessions/old.jsonl" ] || return 1
  [ -f "${ONLOOKER_DIR}/lineage/abc123/changes.jsonl" ] || return 1
  [ -f "${ONLOOKER_DIR}/logs/onlooker-events.jsonl" ]
}

@test "dry run deletes nothing but reports what it would delete" {
  printf '{}' > "${ONLOOKER_DIR}/session-trackers/old"
  _age_days "${ONLOOKER_DIR}/session-trackers/old" 5

  run node "$PRUNE" --dir "$ONLOOKER_DIR" --dry-run --json
  [ "$status" -eq 0 ] || return 1
  [ -f "${ONLOOKER_DIR}/session-trackers/old" ] || return 1
  printf '%s' "$output" | jq -e '.dryRun == true and .totals.deleted == 1' >/dev/null
}

@test "exits cleanly when the store does not exist" {
  run node "$PRUNE" --dir "${BATS_TEST_TMPDIR}/nope"
  [ "$status" -eq 0 ]
}

@test "honors a custom retention window" {
  printf '{}' > "${ONLOOKER_DIR}/session-history/midlife.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/midlife.jsonl" 40

  run node "$PRUNE" --dir "$ONLOOKER_DIR" --retention-days 30
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/session-history/midlife.jsonl" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bats test/bats/onlooker-store-prune.bats
```

Expected: all eight fail — `Cannot find module .../scripts/onlooker-store-prune.mjs`.

- [ ] **Step 3: Write the script**

Create `scripts/onlooker-store-prune.mjs`:

```javascript
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
];

function parseArgs(argv) {
  const out = {
    dir: process.env.ONLOOKER_DIR || join(homedir(), '.onlooker'),
    scratchMaxAgeHours: 48,
    retentionDays: 90,
    dryRun: false,
    json: false,
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
      process.exit(0);
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
  const dir = join(root, ...store.segments);
  const result = { name: store.name, scanned: 0, deleted: 0, reclaimedBytes: 0 };
  if (!existsSync(dir)) return result;

  const cutoff =
    store.policy === 'scratch'
      ? now - opts.scratchMaxAgeHours * HOUR_MS
      : now - opts.retentionDays * DAY_MS;

  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return result; // Unreadable directory: fail soft.
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
  return result;
}

function main() {
  const opts = parseArgs(process.argv);
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
  process.exit(0);
}

main();
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bats test/bats/onlooker-store-prune.bats
```

Expected: all eight PASS.

- [ ] **Step 5: Break one assertion on purpose to prove the tests gate**

Temporarily change `pruneEmptyScribe: true` to `false` in `STORES`, re-run, and confirm `deletes a payload-free scribe file but keeps one with a prompt` FAILS. Revert.

This matters: a bats test whose non-final `[[ ]]` was left ungated passes whether or not the code works.

- [ ] **Step 6: Add the npm entry point**

In `package.json`, add to `"scripts"` after `"coverage"`:

```json
"store:prune": "node scripts/onlooker-store-prune.mjs"
```

- [ ] **Step 7: Verify lint and the full suite**

```bash
npm run lint:check
npm run test:bats
```

Expected: biome clean on the new `.mjs`, full bats suite green. If biome reports formatting, run `npm run format` and re-check.

- [ ] **Step 8: Commit**

Use the `/commit` skill. Suggested message:

```text
feat(storage): add a one-shot prune for the onlooker store :broom:

Reclaims what the write path already spent. Scratch trackers age out at 48h,
the per-session analysis stores at 90 days, and payload-free scribe files go
at any age because scribe-capture.sh recreates them with a real payload on
the next prompt.

Stores are an explicit allowlist, not a denylist -- this deletes files, and a
denylist would silently swallow any store added later. historian, lineage,
archivist, librarian, curator, buffer.db and logs/ are never touched.

Refs ecosystem-449.2
```

---

### Task 3: run it for real and record the result

**Files:**

- Modify: none. This task produces a measurement, not a diff.

**Interfaces:**

- Consumes: `scripts/onlooker-store-prune.mjs` from Task 2.
- Produces: before/after numbers for the `ecosystem-449.2` bead notes.

- [ ] **Step 1: Record the before state**

```bash
du -sh ~/.onlooker
for d in session-trackers session-history scribe/sessions bursar/sessions compass/sessions; do
  printf '%-22s %s\n' "$d" "$(ls -f ~/.onlooker/$d 2>/dev/null | grep -cv '^\.\.\?$')"
done
```

Save the output — it is the baseline the bead will cite.

- [ ] **Step 2: Dry run first**

```bash
npm run store:prune -- --dry-run
```

Expected: a per-store table. Sanity-check it before deleting anything — roughly 37.5k trackers and ~24k payload-free scribe files, and **zero** deletions attributed to historian, lineage, or logs (they should not even appear, since they are not in `STORES`).

- [ ] **Step 3: Run it**

```bash
npm run store:prune
```

- [ ] **Step 4: Record the after state**

Re-run the Step 1 commands. Confirm `~/.onlooker` dropped by roughly 250MB.

- [ ] **Step 5: Write the result into the bead**

```bash
bd update ecosystem-449.2 --append-notes "<before/after numbers and the prune report>"
```

Include the real measured reclaim, not the estimate. If it differs materially from the ~254MB the spec predicted, say so and explain why — a wrong prediction that goes unrecorded is how the next person inherits a bad number, which is exactly what happened to this bead's original diagnosis.

- [ ] **Step 6: Full CI pass before the PR**

```bash
npm run test:ci
```

Expected: shellcheck, bats, schema, bus coverage, biome, and the manifest/reference linters all green.

---

## Self-review notes

**Spec coverage.** §1 scribe write-path fix → Task 1. §2 age-out rather than SessionEnd deletion → Task 2's `scratch` policy (no SessionEnd hook exists to race bursar). §3 one-shot script with the payload-free rule → Task 2. §4 store allowlist and `$ONLOOKER_DIR` and flags-not-config → Task 2 Steps 3 and 6. §5 out-of-scope items → already filed as `ecosystem-ave`, `ecosystem-c95`, `ecosystem-s6f`, `ecosystem-d8j`; no task needed. Testing section → Task 1 Step 1 and Task 2 Step 1, one test per bullet. "No new event types" → nothing in this plan emits, so `test/bus-coverage.json` is untouched.

**Known gap, deliberate.** The spec's expected result claims ~254MB. Task 3 Step 5 requires recording the *measured* number rather than restating the estimate.

**Type consistency.** `pruneEmptyScribe` is the flag name in `STORES`, in `pruneStore`, and in Task 2 Step 5. The JSON report shape in the Interfaces block matches what `main()` builds and what the `--dry-run` test asserts (`.dryRun`, `.totals.deleted`).
