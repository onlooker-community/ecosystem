# Verifying lineage's cross-session attribution

Lineage's Bash branch detects shell-shaped edits by diffing the working tree
against a baseline. When two sessions share a checkout, that diff is the whole
question: a bystander must not record work it did not do.

This is the procedure for proving it does not. It exists because the failure it
catches is silent — the wrong answer looks exactly like the right one, and
`/lineage` renders it with the same confidence either way.

**A single-session run proves nothing.** Every version attributes its own edits
correctly, including the broken ones. Only the two-session ordering below
exercises the defect. If you cannot get two genuinely separate processes, do not
run an abbreviated version and record it as a pass.

Provenance: written for ecosystem-449.41 (shared baseline, closed) and reused
for ecosystem-449.47 (unknown authorship). The worked numbers throughout are from
the 2026-09-07 run.

## Setup

Two sessions, one checkout. Decide which is **A (author)** and which is
**B (bystander)** before you start — the ordering is the test.

Derive the paths rather than pasting them; both are keyed to your checkout:

```bash
source plugins/lineage/scripts/lib/lineage-record.sh       # lineage_sha256
source plugins/lineage/scripts/lib/lineage-project-key.sh
source plugins/lineage/scripts/lib/lineage-baseline.sh

REPO_ROOT=$(git rev-parse --show-toplevel)
ONLOOKER="${ONLOOKER_DIR:-$HOME/.onlooker}"
LEDGER="$ONLOOKER/lineage/$(lineage_project_key "$REPO_ROOT")/changes.jsonl"
BASELINES="$ONLOOKER/lineage-baselines/$(lineage_baseline_scope_id "$REPO_ROOT")"
```

`lineage-baseline.sh` requires `lineage-record.sh` sourced first, for
`lineage_sha256`. Source order matters.

## 0. Preflight — both sessions, before anything else

`/clear` is not enough. **Quit `claude` entirely and relaunch.** Plugin code is
pinned at process start, so a cleared session keeps the old plugin while every
timestamp still says it is current. A session created by `/clear` inside an old
process runs the old plugin no matter what is installed.

The baseline layout names the design, so one call settles it:

```bash
ls -la "$BASELINES/" | tail -5
```

- **Shared baseline (required):** a single `baseline.json`, and it is the file
  whose mtime moves when you run shell commands.
- **Per-session baselines (stop):** a `<your-session-id>.json` appears or
  updates instead. That build predates the fix and cannot test it.

Leftover `<session-id>.json` files from older runs are inert — nothing reads
them and they age out. What matters is which file *your* process writes. Confirm
by capturing mtimes, running any command, and capturing again.

Do not proceed until both sessions show the shared layout.

## 0b. Confirm the shared baseline is current — both sessions

§0 proves your session runs the right build. It does not prove the **shared
baseline reflects the tree**, and a stale one manufactures a ghost before the
test starts.

The baseline advances only when a hook runs. It goes stale whenever the tree
moved with no hook behind it: a session on an older plugin, an edit saved in
your editor, a `git checkout`, a build. The next session to run *any* Bash
command — a pure read included — diffs against that stale baseline, sees files
it never touched, and records them under itself.

Not hypothetical. On the 2026-09-07 run, B's first preflight `ls` recorded the
runbook file under B. It had been authored 12 minutes earlier by a session on
the previous version, which never refreshed the shared baseline.

```bash
BASE="$BASELINES/baseline.json"
while IFS= read -r -d '' rec; do
  st="${rec:0:2}"; f="${rec:3}"; [[ -z "$f" ]] && continue
  [[ "$st" == *R* || "$st" == *C* ]] && { read -r -d '' _ || true; }
  [[ -f "$f" ]] || continue
  cur=$(printf '%s' "$(cat "$f")" | openssl dgst -sha256 | sed 's/^.*= *//')
  old=$(jq -r --arg k "$f" '.files[$k] // ""' "$BASE")
  [[ "$cur" == "$old" ]] && echo "ok     $f" || echo "STALE  $f"
done < <(git status --porcelain=v1 -z --untracked-files=all)
```

Every line must read `ok`.

The hash form is the plugin's own (`lineage_file_sha`): it hashes
`$(cat "$f")`, and command substitution strips trailing newlines. A plain
`shasum "$f"` disagrees with the baseline on every file and reports a staleness
that is not there.

A `STALE` line is not a failure. Clear it by **running the check a second
time** — the first run's own hook advances the baseline and sweeps those paths
into the ledger under your session. Confirm the swept records name files you did
not touch, then take §1's timestamp *after* them so they stay out of the assert.

## 1. Snapshot the ledger — either session

```bash
wc -l "$LEDGER"
date -u +%Y-%m-%dT%H:%M:%SZ
```

Note both. Everything below is asserted against records newer than that
timestamp. Call it `T0`.

## 2. B goes first — session B

Ordering is the whole test — but not because the fixed version needs it.

Under the fix there is one baseline per checkout. A's write advances it for
everyone, so B's later read finds nothing to claim no matter when B arrived. The
ordering exists to keep this a *regression* test: it preserves the one condition
under which the broken version demonstrably fails. With per-session baselines, a
bystander whose first call came *after* the change seeded from a tree that
already contained it — recording nothing, and passing a test it should have
failed.

Keep the ordering even though the fixed version is indifferent to it. A run that
drops it cannot fail, on any version.

```bash
git status --short                                  # B touches the tree before A writes
printf 'BYSTANDER MARKER\n' > BYSTANDER_MARKER.md   # gives B a ledger record, so we learn B's session id
```

With §0b satisfied, the first command records nothing.

## 3. A makes the change — session A

```bash
printf 'AUTHOR MARKER\nline two\nline three\n' > AUTHOR_MARKER.md
```

Leave it uncommitted. The defect needs uncommitted work in a shared tree.

## 4. B touches the tree again — session B

A pure read is enough. This is the call that, against the broken version, swept
up A's work and recorded it under B:

```bash
wc -l AUTHOR_MARKER.md
```

## 5. Assert — either session

```bash
jq -r --arg t0 "$T0" 'select(.ts > $t0)
       | [.ts, .session_id[0:8], .operation, (.file_path | sub(".*/"; ""))]
       | @tsv' "$LEDGER"
```

**Pass** — exactly two records, `AUTHOR_MARKER.md` appearing once, under A:

```text
<ts>  <B-id>  shell_edit  BYSTANDER_MARKER.md
<ts>  <A-id>  shell_edit  AUTHOR_MARKER.md
```

**Fail** — a third record, timestamped just after §4:

```text
<ts>  <B-id>  shell_edit  AUTHOR_MARKER.md      <-- ghost: B claiming A's work
```

Then confirm the baseline stayed shared:

```bash
ls -la "$BASELINES/"
```

`baseline.json`'s mtime should have moved, and **no new `<session-id>.json`**
should have appeared for either session.

Verify the window was real before believing a pass. If B's read landed *before*
A's write there was no opportunity to sweep, and the result is vacuous. Check
B's hook actually fired after A's record:

```bash
grep "<B-session-id>" "$ONLOOKER/logs/hook-health.jsonl" \
  | grep lineage-post-tool-use | tail -3
```

## 5b. The reverse direction

The steps above only cast B as the bystander. The symmetric case costs nothing
and strengthens the result: have **B author** a further change, then confirm
**A** claims none of it, filtering the ledger for records under A after B's
authoring timestamp. There must be none.

Observed on the 2026-09-07 run without extra setup: B made two edits at
19:41:04Z and 19:41:11Z, both recorded under B; A then ran eight shell commands
between 19:41:14Z and 19:43:09Z, its hook firing on every one, and recorded
nothing. Neither role is privileged.

## 6. The question the plugin exists to answer

```text
/lineage AUTHOR_MARKER.md:1
```

Must name **A's** session and resolve **A's** prompt. This is the real
acceptance criterion: a wrong answer here is worse than no answer, because it is
delivered with the same confidence as a right one.

Repeat for the bystander file as a control:

```text
/lineage BYSTANDER_MARKER.md:1
```

Must name **B**. If both answers resolve identical prompt text, suspect a shared
lookup rather than two genuine transcripts.

## 7. Cleanup

```bash
rm -f AUTHOR_MARKER.md BYSTANDER_MARKER.md
git status --short
```

Do not clean up until the other session has finished §6 — the line lookup reads
the file to build its search text, so a deleted file yields "no recorded change"
instead of an answer.

Deletions produce no ledger records: `lineage_changed_files` skips paths it
cannot read (`[[ -z "$cur" ]] && continue`). A removed file cannot ghost.

## What a pass does not cover

**Changes with no hook behind them.** The shared baseline advances only when a
hook runs, so anything that moves the tree outside that path — an editor save,
`git checkout`, a build, a session on an older plugin — is attributed to
whichever session next runs a shell command. §0b catches it before a run; it
does not fix it. This is the unknown-authorship gap, and it is wider than the
same-instant race: scope any fix for "no session can be shown to have done
this", not only "two sessions raced".

**Mixed plugin versions.** The fix holds only when every live session in the
checkout runs the shared-baseline build. A session on an older build maintains
its own per-session file and never advances the shared one, so its writes are
claimed by the next current session to run any Bash call. Sweep for stale
processes before a soak, or they will manufacture false failures.

**The same-instant race.** Two sessions shell-editing in the same moment can
still cross-attribute: whichever hook takes the shared lock first builds the
baseline from disk, sees both changes, and records both under itself. The window
is one hook's critical section rather than "until the change is committed".
