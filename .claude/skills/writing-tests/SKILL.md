---
name: writing-tests
description: How to write tests in the Onlooker ecosystem repo — bats integration tests for hooks and the node:test schema suite. Use when adding or changing anything under test/, when writing a new hook or plugin that needs tests, or when deciding which shared helper to reach for instead of hand-rolling setup, dates, CLI stubs, project keys, or event-log assertions. Steers toward test/helpers/setup.bash and each plugin's own libs so tests stay isolated and never become time bombs.
---

# Writing tests

This repo has two test suites. Use the right one for what you're testing, and lean on the shared helpers below — most fragility in this codebase has come from tests hand-rolling things a helper already does.

- **bats** (`test/bats/*.bats`) — bash hooks and end-to-end plugin behavior. This is where almost all tests live.
- **node:test** (`test/node/*.test.mjs`) — schema mapping, manifest, and reference validation. Pure data-in/data-out, no hooks.

## Run the suite

```bash
npm test               # bats + node schema suite (what most changes need)
npm run test:bats      # just bats  (bats test/bats)
npm run test:schema    # just node  (node --test test/node/*.test.mjs)
npm run test:ci        # shellcheck + bats + schema + biome + manifest/reference lint
```

Run a single bats file while iterating: `bats test/bats/<name>.bats`. `bats` comes from mise (it is on `PATH`), not `npx`.

## Golden rules

1. Every bats test starts by isolating the filesystem — source `setup.bash` and call `setup_test_env`. Never touch the real `$HOME` or `~/.onlooker`.
2. Always reference `$ONLOOKER_DIR` / `$ONLOOKER_EVENTS_LOG`, never a literal `~/.onlooker`.
3. Never hardcode a date that feeds a relative window. Use `relative_iso_days_ago`.
4. Resolve project keys, emit events, and generate ULIDs through the plugin's own libs — don't reimplement them.
5. Assert behavior through the **event log** and on-disk artifacts, the same surfaces real consumers read.

## bats tests

### Isolate the environment first

Every test file's `setup()` sources the shared helper and calls `setup_test_env`, which repoints `HOME`, `ONLOOKER_DIR`, `CLAUDE_HOME`, and `CLAUDE_PLUGIN_ROOT` into `$BATS_TEST_TMPDIR` and severs git from your global config:

```bash
setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/<plugin>"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
}
```

If your hook needs the resolved Onlooker paths (`$ONLOOKER_EVENTS_LOG`, the session/metrics dirs) materialized, call `load_validate_path` instead — it runs `setup_test_env`, sources `scripts/lib/validate-path.sh`, and `mkdir -p`s the standard directories.

`setup_test_env` exports (read `test/helpers/setup.bash` for the authoritative list):

| Variable | Points at |
|----------|-----------|
| `HOME` | `$BATS_TEST_TMPDIR/home` (isolated) |
| `ONLOOKER_DIR` | `$HOME/.onlooker` |
| `ONLOOKER_EVENTS_LOG` | `$ONLOOKER_DIR/logs/onlooker-events.jsonl` (after `validate-path.sh` is sourced) |
| `CLAUDE_HOME` | `$HOME/.claude` |
| `REPO_ROOT` | the repo root (set when `setup.bash` is sourced) |

### Dates: use `relative_iso_days_ago`, never a literal

A hardcoded ISO date is a **time bomb** when the code under test computes a window from "now" (for example librarian's "now − `bootstrap_lookback_days`" scan window). The fixture passes today and silently fails once wall-clock now drifts past the threshold. Date such fixtures relative to now:

```bash
# yesterday, UTC — comfortably inside a 14-day lookback window
created_at=$(relative_iso_days_ago 1)
```

`relative_iso_days_ago N` lives in `test/helpers/setup.bash` and returns an ISO-8601 UTC timestamp N days in the past (0 = now, negative = future). It uses `python3` for portable date math, since `date -d` (GNU) and `date -v` (BSD/macOS) disagree. For a plain "now" timestamp, `date -u +%Y-%m-%dT%H:%M:%SZ` is fine and portable; only the *offset* math needs the helper.

### Resolve project keys through the plugin lib

Artifacts are partitioned by a project key. Don't recompute the SHA — source the plugin's `*-project-key.sh` and call its function (`<plugin>_project_key <repo-root>`):

```bash
source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
ARTIFACT_DIR="${ONLOOKER_DIR}/<plugin>/${PROJECT_KEY}"
```

For key resolution to succeed the test needs a git context — stand up a throwaway repo in `setup()`:

```bash
PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
mkdir -p "$PROJECT_REPO"
git -C "$PROJECT_REPO" init -q
git -C "$PROJECT_REPO" config user.email t@example.com
git -C "$PROJECT_REPO" config user.name "Test"
git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git
```

### Stub the `claude` CLI on `PATH`

Hooks that classify or judge shell out to `claude`. Stub it deterministically — branch on the prompt so each case returns a known response — and prepend the stub dir to `PATH`:

```bash
STUB_BIN="${BATS_TEST_TMPDIR}/bin"
mkdir -p "$STUB_BIN"
cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
if [[ "$prompt" == *"some-marker"* ]]; then
  printf '%s' '{"type":"feedback","title":"...","body":"...","confidence":0.84}'
else
  printf '%s' '{"type":null,"title":"","body":"","confidence":0.2}'
fi
STUB
chmod +x "${STUB_BIN}/claude"
export PATH="${STUB_BIN}:${PATH}"
```

Same pattern stubs any external CLI a hook depends on (`curl`, `git`, …). Keep the responses minimal but schema-valid.

### Build hook input with `jq`

Hooks read a JSON payload on stdin. Build it with `jq -cn` and feed it in — don't hand-concatenate JSON strings:

```bash
_hook_input() {
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-test" \
    '{cwd: $cwd, session_id: $sid, hook_event_name: "SessionEnd"}'
}

run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
[ "$status" -eq 0 ]   # hooks must always exit 0 — they never block the session
```

### Assert against the event log

Plugins communicate through the canonical JSONL event bus, so that's where you assert. Grep for the event type, then check the payload with `jq -e`:

```bash
grep '"event_type":"<plugin>.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
  | jq -e '.payload.outcome == "ok" and .payload.candidates_proposed == 2' >/dev/null
```

To assert an emitted line is a **schema-valid** envelope (not just present), pipe it through the canonical validator rather than eyeballing fields:

```bash
tail -n 1 "$ONLOOKER_EVENTS_LOG" \
  | ONLOOKER_DIR="$ONLOOKER_DIR" node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
```

Production code must emit only through `scripts/lib/onlooker-event.mjs` (often via a plugin wrapper like `librarian_emit` / `assayer_emit_event`) — never by writing the log directly. New event types must be registered in `@onlooker-community/schema` before they validate.

### Seed fixtures and generate IDs

Write fixtures with `jq -n` into the plugin's project-keyed directory, and generate IDs with the plugin's `*-ulid.sh` (ULIDs, not UUIDs — a repo-wide convention). A typical artifact seeder:

```bash
_seed_artifact() {
  local kind="$1" id="$2" summary="$3" detail="$4" created_at="${5:-$(relative_iso_days_ago 1)}"
  mkdir -p "${ARTIFACT_DIR}/${kind}"
  jq -n --arg id "$id" --arg summary "$summary" --arg detail "$detail" \
        --arg created_at "$created_at" \
    '{ id: $id, created_at: $created_at, updated_at: $created_at,
       summary: $summary, detail: $detail }' \
    > "${ARTIFACT_DIR}/${kind}/${id}.json"
}
```

## Anti-patterns

Don't hand-roll these — each has bitten the suite before:

- **Hardcoded dates in window-sensitive fixtures.** Use `relative_iso_days_ago`. A literal like `2026-06-01T12:00:00Z` aged out of librarian's lookback window and broke two tests the day wall-clock now crossed it.
- **Literal `~/.onlooker` or `$HOME`.** Always `$ONLOOKER_DIR` and the `validate-path.sh` exports, so the isolated temp home is honored.
- **Reimplementing the project key, ULID, or event envelope.** Source the plugin lib (`*-project-key.sh`, `*-ulid.sh`) and emit through `onlooker-event.mjs`.
- **Concatenating JSON by hand.** Build payloads and hook input with `jq -n` / `jq -cn --arg`.
- **Asserting on log lines with `grep` substring matches alone** when you mean "valid event" — validate the envelope with `onlooker-event.mjs validate`.
- **Expecting a hook to exit non-zero.** Hooks fail soft and exit 0; assert on emitted events or absent side effects, not exit codes.

## Node tests

`test/node/*.test.mjs` use the built-in `node:test` runner and `node:assert/strict` — no external framework. They cover schema mapping (`schema-events.test.mjs`), manifest validation (`check-manifests.test.mjs`), and cross-references (`check-references.test.mjs`), driven by fixtures under `test/fixtures/`.

```javascript
import test from 'node:test';
import assert from 'node:assert/strict';

test('maps PostToolUse Read to tool.file.read', () => {
  const mapped = mapHookInputToCanonical(loadFixture('post-tool-use-read.json'), { plugin: 'onlooker' });
  assert.equal(mapped.valid, true);
  assert.equal(mapped.event.event_type, 'tool.file.read');
});
```

Prefer adding a fixture under `test/fixtures/` and asserting the mapping over inlining large JSON literals. Run with `npm run test:schema`.

## Adding tests for a new plugin

1. Create `test/bats/<plugin>-<surface>.bats` (e.g. `<plugin>-session-end.bats`).
2. `setup()`: source `setup.bash`, call `setup_test_env`, set `PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT`, stand up a fixture git repo, resolve the project key via the plugin lib.
3. Stub `claude` (and any other CLI) on `PATH` if the hook shells out.
4. Drive the hook with `jq`-built input; assert on `$ONLOOKER_EVENTS_LOG` and on-disk artifacts.
5. Date any window-sensitive fixture with `relative_iso_days_ago`.
6. Run `npm run test:ci` before opening the PR — it adds shellcheck and the manifest/reference linters on top of the tests.
