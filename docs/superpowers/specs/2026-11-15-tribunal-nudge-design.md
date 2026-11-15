# Tribunal nudge: suggest `/tribunal` when a session looks worth a jury

## Problem

Tribunal runs only when someone types `/tribunal`. Its Stop gate,
`tribunal-stop-gate.sh`, sends a judge model the transcript tail on every
Stop where this session edited files (`claude -p`, `judges.model`, which
defaults to `claude-opus-4-7`). That bills model usage on every such Stop, so
the gate is off by default (`tribunal.stop_hook.enabled: false`). Between
"never" and "a judge on every editing Stop" there is nothing: a session that
rewrites a CI workflow or a migration ends the same way as one that fixed a
typo, and the jury is never offered.

## Goal

At the end of a turn, when this session's changes look high-stakes, show the
user one line suggesting `/tribunal`. The nudge makes no model call. Its only
cost is a transcript scan, git reads and jq on each Stop, plus one event
emission when it has something new to record. It stays quiet once it has
spoken.

## Non-goals

- Running any judge. The gate stays as it is.
- Deciding for the user. Claude does not see the nudge and does not act on it.
- Signals that are not on disk when Stop fires. Stop hooks of different
  plugins run in parallel, so assayer's verdict on the same Stop is not
  available. Prior assayer flags and Bash-made edits were considered and left
  out.

## Design

### A separate hook

A new `plugins/tribunal/scripts/hooks/tribunal-stop-nudge.sh` is registered on
Stop beside the gate. The gate makes a model call and is off by default, while
the nudge makes none and is on by default. Keeping them apart means turning
one on or off never affects the other. The shared pieces are already libs:
`tribunal-session-files.sh` for attribution and `tribunal-config.sh` for
config.

The decision logic lives in `plugins/tribunal/scripts/lib/tribunal-nudge.sh`
as functions over a file list and the previous state, so it is testable
without a hook run.

### Delivery: `systemMessage`

The hook prints one JSON object, `{"systemMessage": "..."}`. Claude Code's
hook reference lists `systemMessage` as a universal output field, a "warning
message shown to the user", and the Stop section does not discard it, as the
Notification, Setup and InstructionsLoaded sections do. No hook in this repo
emits it yet, so the first implementation step is a manual check that it
renders from a plugin's Stop hook.

`hookSpecificOutput.additionalContext` is not used. On Stop it continues the
conversation so Claude acts on it, which is the "Claude asks you" option this
design rejected.

The gate's header says a Stop hook prints nothing but an optional
`{continue: ...}`. That holds for the gate. The nudge's single
`systemMessage` object is the one other output this design adds.

### Decision, per Stop

1. Exit without a nudge, with the first reason that applies:
   - `disabled`: `tribunal.nudge.enabled` is not `true`.
   - `gate_enabled`: `tribunal.stop_hook.enabled` is `true`, so the gate is
     already judging editing Stops.
   - `no_project_context`: there is no project key or repo root.
   - `no_transcript`: `transcript_path` is absent or unreadable.
   - `tribunal_ran`: the transcript shows `/tribunal` in this session. That is
     either a `Skill` tool_use whose `skill` is `tribunal:tribunal` or
     `tribunal`, or a user turn whose command name is `/tribunal`.
2. Find this session's changed files: `tribunal_session_edited_files` on the
   transcript, filtered through `tribunal_dirty_files`. Drop files matching
   `ignore_globs`. Another session's dirty files never count; this is the same
   attribution the gate uses (ecosystem-449.42).
3. Check the triggers:
   - **size**: `min_files` is above 0 and the count reaches it. Setting
     `min_files` to 0 turns the size trigger off.
   - **sensitive**: any file matches `sensitive_globs`.

   If neither trips, skip with `below_threshold`.
4. Apply the frequency rule against the state file (below):
   - No nudge recorded yet: nudge, with trigger `size` or `sensitive`. When
     both trip, use `sensitive`.
   - A nudge recorded: nudge again with trigger `grew` only when a sensitive
     path appears that is not in `sensitive`, or the file count is at least
     twice `files`. Otherwise skip with `unchanged`.
5. On a nudge, rewrite the state's `files` and `sensitive`, print the
   `systemMessage`, and emit `tribunal.nudge.shown`.

### Message

```text
tribunal: this session changed 9 files, 2 sensitive (.github/workflows/ci.yml, db/migrations/004.sql). Worth a jury? /tribunal runs several judge models; type it to start.
```

It names at most three sensitive paths, then "and N more". When the trigger
is size alone, the sensitive clause is left out. The cost hint is there
because the full loop is 4 to 5 model calls per iteration and up to 3
iterations (tribunal ADR-001), which is far more than the gate's one judge.

### State file

`$ONLOOKER_DIR/tribunal/<project-key>/nudge-<session>.json`:

```json
{"files": 9, "sensitive": [".github/workflows/ci.yml"], "skips_reported": ["below_threshold"]}
```

- `files` is an integer: the session-file count at the last nudge.
- `sensitive` is an array of worktree-relative paths: the sensitive files at
  the last nudge.
- `skips_reported` is an array of skip reasons already emitted this session.

`files` and `sensitive` are absent until the first nudge.

### Events, and what they cost

The gate's own measurement (ONL-172) puts one emission at about 100ms of node
startup. The nudge is on by default, so an emission on every Stop would land
on every session. ONL-172 also showed that emitting nothing on a skip makes an
idle plugin look broken. The nudge does both, with a limit:

- `tribunal.nudge.shown` is emitted on every nudge. That is rare by
  construction.
- `tribunal.nudge.skipped` is emitted once per session per reason. A reason
  already in `skips_reported` is not emitted again. A typical session pays
  for one or two emissions, not one per Stop.
- `disabled`, `gate_enabled`, `no_project_context` and `no_transcript` are
  decided before the state file can be located, or without a project key.
  Those are emitted on every Stop, as the gate does for its own skips. They
  occur only when someone turned the nudge off or there is no project to
  judge.

Both types are registered in `@onlooker-community/schema` before anything
emits them:

| Type | Payload |
|------|---------|
| `tribunal.nudge.shown` | `{trigger: "size" \| "sensitive" \| "grew", session_files: int, sensitive_files: string[]}` |
| `tribunal.nudge.skipped` | `{reason: "disabled" \| "gate_enabled" \| "no_project_context" \| "no_transcript" \| "tribunal_ran" \| "below_threshold" \| "unchanged"}` |

`sensitive_files` holds worktree-relative paths, capped at 20.

### Hook contract

- Always exits 0 and never blocks Stop.
- Calls `hook_health_register "tribunal-stop-nudge"` and leaves only through
  `hook_health_exit`.
- Writes nothing to stdout except the single `systemMessage` object.
- Makes no `claude` call, so it needs no `*_NESTED` re-entry guard. The gate's
  nested judge runs with `disableAllHooks`, so it never reaches this hook.

### Config

Defaults go in `plugins/tribunal/config.json`, under the top-level `tribunal`
key like every other tribunal setting. Accessors read `.tribunal.nudge.*`.

```json
{
  "tribunal": {
    "nudge": {
      "enabled": true,
      "min_files": 8,
      "sensitive_globs": [
        ".github/workflows/**",
        "**/migrations/**",
        "**/auth/**",
        "**/*secret*",
        "**/*credential*",
        "**/.env*"
      ],
      "ignore_globs": [
        "**/*.lock",
        "**/package-lock.json",
        "**/pnpm-lock.yaml",
        "**/yarn.lock"
      ]
    }
  }
}
```

The defaults are kept narrow on purpose:

- `**/hooks/**` is left out because it matches nearly every plugin in this
  repo.
- `**/*auth*` is left out because it also matches `author*`, `oauth*` and
  `authoring.md`.

A repo that wants its hooks treated as sensitive sets the globs at project
scope, for example with
`onlooker config set tribunal.nudge.sensitive_globs '["plugins/*/scripts/hooks/*.sh"]' --scope project`.

`tribunal-config.sh` gains `tribunal_config_get_int`, a wrapper over the
vendored `config_get_int`, matching `archivist-config.sh`. `config_get_int`
returns the caller's default for a non-integer value. It returns 0 only when
the default itself is not an integer. A non-integer `min_files` therefore
reads as 8, and a test pins that.

### Glob matching

Nothing in the repo uses `globstar`, and macOS `/bin/bash` is 3.2, which has
none. Inside `[[ == ]]`, `**/hooks/**` would also fail to match a root-level
`hooks/a.sh`. So `tribunal-nudge.sh` converts each glob to an extended regex
and matches it with `[[ =~ ]]`, which behaves the same on bash 3.2 and 5.x:

- `**/` matches zero or more leading directories: `(.*/)?`.
- `**` elsewhere matches anything, including `/`: `.*`.
- `*` matches within one path segment: `[^/]*`.
- `?` matches one non-`/` character.
- Every other regex metacharacter is escaped.
- The pattern is anchored at both ends, against the worktree-relative path.

## Delivery

This is two PRs, in order:

1. **schema**: register both event types and release.
2. **ecosystem**:
   - bump `@onlooker-community/schema`
   - add the hook, the lib, `tribunal_config_get_int`, config and the
     `hooks.json` entry
   - add a README section
   - add `test/bus-coverage.json` entries for both types

## Testing

`test/bats/tribunal-stop-nudge.bats` is written before the hook. Each test
seeds a fixture repo and a transcript with Edit tool_use lines, runs the hook,
and asserts on stdout and the event log:

- Fewer than `min_files` ordinary files: no output, `skipped:below_threshold`.
- `min_files` files: nudge with `trigger: size`, and the message names the
  count.
- `.github/workflows/ci.yml` alone: nudge with `trigger: sensitive`. A
  lockfile alone does not trip it.
- A second Stop with no change: no output, `unchanged`. A new sensitive file,
  or a doubled count, nudges again with `trigger: grew`.
- A second below-threshold Stop emits no second `skipped:below_threshold`.
- `/tribunal` in the transcript: no output, `tribunal_ran`.
- Nudge disabled, or the gate enabled: no output, with the matching reason.
- `min_files: 0` turns off the size trigger. A non-integer `min_files` reads
  as 8.
- A dirty file that only another session edited is not counted.
- A `claude` stub that fails the test if it is called proves the nudge makes
  no model call.
- Stdout is empty or exactly one JSON object whose only key is
  `systemMessage`.

Glob-to-regex unit tests live in `test/bats/tribunal-nudge-glob.bats`:

- `**/migrations/**` matches both `migrations/1.sql` and `db/migrations/1.sql`.
- `*` does not cross `/`.
- `.` and `+` in a glob are literal.
- Each case runs under the bash `bats` resolves. On macOS that is 3.2, so the
  local run is the strict one.
