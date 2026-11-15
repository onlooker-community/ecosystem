# Tribunal nudge: suggest `/tribunal` when a session looks worth a jury

## Problem

Tribunal runs only when someone types `/tribunal`. Its Stop gate,
`tribunal-stop-gate.sh`, runs a paid judge on every Stop, so it is off by
default (`tribunal.stop_hook.enabled: false`). Between "never" and "every
Stop" there is nothing: a session that rewrites hooks or touches a migration
ends the same way as one that fixed a typo, and the jury is never offered.

## Goal

At the end of a turn, when this session's changes look high-stakes, show the
user one line suggesting `/tribunal`. Make no model call, cost nothing on a
session that doesn't qualify, and stay quiet once said.

## Non-goals

- Running any judge. The paid gate stays as it is.
- Deciding for the user. Claude does not see the nudge and does not act on it.
- Signals that are not on disk when Stop fires. Stop hooks of different
  plugins run in parallel, so assayer's verdict on the same Stop is not
  available; prior assayer flags and Bash-made edits were considered and left
  out.

## Design

### A separate hook

A new `plugins/tribunal/scripts/hooks/tribunal-stop-nudge.sh` is registered on
Stop beside the gate. It is free and on by default, while the gate is paid,
off by default, and about 300 lines. Keeping the two apart means turning one
on or off never affects the other. The pieces they share are already libs:
`tribunal-session-files.sh` for attribution and `tribunal-config.sh` for
config.

The decision logic lives in `plugins/tribunal/scripts/lib/tribunal-nudge.sh`
as pure functions over a file list and the previous state, so it is testable
without a hook run.

### Decision, per Stop

1. Exit silently, emitting `tribunal.nudge.skipped`, with the first reason
   that applies:
   - `disabled`: `tribunal.nudge.enabled` is not `true`.
   - `gate_enabled`: `tribunal.stop_hook.enabled` is `true`, so the paid gate
     is already judging every Stop.
   - `no_project_context`: there is no project key or repo root.
   - `no_transcript`: `transcript_path` is absent or unreadable.
   - `tribunal_ran`: the transcript shows `/tribunal` in this session, either
     a `Skill` tool_use naming `tribunal:tribunal` or `tribunal`, or a user
     turn whose command name is `/tribunal`.
2. Find this session's changed files: `tribunal_session_edited_files` on the
   transcript, filtered through `tribunal_dirty_files`. Drop files matching
   `nudge.ignore_globs`. Another session's dirty files never count; this is
   the same attribution the gate uses (ecosystem-449.42).
3. Check the triggers:
   - **size**: the count reaches `nudge.min_files`.
   - **sensitive**: any file matches `nudge.sensitive_globs`.

   If neither trips, skip with `below_threshold`.
4. Apply the frequency rule, using the state file
   `$ONLOOKER_DIR/tribunal/<project-key>/nudge-<session>.json`, which holds
   `{files, sensitive}` as of the last nudge:
   - No state yet: nudge, with the trigger `size` or `sensitive`. When both
     trip, use `sensitive`.
   - State exists: nudge again with trigger `grew` only when a sensitive file
     appears that is not in the recorded set, or the count is at least twice
     the recorded count. Otherwise skip with `unchanged`.
   - The state is rewritten only when a nudge is shown.
5. Print one JSON object to stdout and emit `tribunal.nudge.shown`:

   ```json
   {"systemMessage": "tribunal: this session changed 9 files, 2 sensitive (plugins/x/hooks/a.sh, .github/workflows/ci.yml). Worth a jury? Run /tribunal."}
   ```

   The message lists at most three sensitive paths, then "and N more".

### Hook contract

- Always exits 0 and never blocks Stop.
- Calls `hook_health_register "tribunal-stop-nudge"` and leaves only through
  `hook_health_exit`.
- Writes nothing to stdout except the single `systemMessage` object.
- Makes no `claude` call, so it needs no `*_NESTED` re-entry guard. The gate's
  nested judge already runs with `disableAllHooks`, so it never reaches this
  hook.

### Config

Defaults go in `plugins/tribunal/config.json`:

```json
"nudge": {
  "enabled": true,
  "min_files": 8,
  "sensitive_globs": ["**/hooks/**", "**/*auth*", "**/*secret*", "**/migrations/**", ".github/workflows/**"],
  "ignore_globs": ["**/*.lock", "**/package-lock.json", "**/pnpm-lock.yaml", "**/yarn.lock"]
}
```

`min_files` is read with `config_get_int`. A non-integer falls back to 8.

Globs are matched against worktree-relative paths with bash `extglob` and
`globstar` semantics: `**/` matches zero or more directories.

### Events

Both types are registered in `@onlooker-community/schema` before anything
emits them.

| Type | Payload |
|------|---------|
| `tribunal.nudge.shown` | `{trigger: "size" \| "sensitive" \| "grew", session_files: int, sensitive_files: string[]}` |
| `tribunal.nudge.skipped` | `{reason: "disabled" \| "gate_enabled" \| "no_project_context" \| "no_transcript" \| "tribunal_ran" \| "below_threshold" \| "unchanged"}` |

`sensitive_files` holds worktree-relative paths, capped at 20.

## Delivery

This is two PRs, in order:

1. **schema**: register both event types and release.
2. **ecosystem**:
   - bump `@onlooker-community/schema`
   - add the hook, the lib, config and the `hooks.json` entry
   - add a README section
   - add `test/bus-coverage.json` entries for both types

## Testing

`test/bats/tribunal-stop-nudge.bats` is written before the hook. Each test
seeds a fixture repo and a transcript with Edit tool_use lines, runs the hook,
and asserts on stdout and the event log:

- Fewer than `min_files` ordinary files: silent, `skipped:below_threshold`.
- `min_files` files: nudge with `trigger: size`, and the message names the
  count.
- One file under `hooks/`: nudge with `trigger: sensitive`. A lockfile alone
  does not trip it.
- A second Stop with no change: silent, `unchanged`. A new sensitive file, or
  a doubled count, nudges again with `trigger: grew`.
- `/tribunal` in the transcript: silent, `tribunal_ran`.
- Nudge disabled, or the gate enabled: silent, with the matching reason.
- A dirty file that only another session edited is not counted.
- A `claude` stub that fails the test if it is called proves the nudge makes
  no model call.
- Stdout is empty or exactly one JSON object with only `systemMessage`.
