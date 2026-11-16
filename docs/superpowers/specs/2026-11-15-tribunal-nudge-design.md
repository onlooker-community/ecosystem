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
user one line suggesting `/tribunal`. The nudge makes no model call. Its
per-Stop cost is one filtered pass over the transcript and some jq, plus one
event emission when it has something new to record. It stays quiet once it
has spoken.

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
one on or off never affects the other.

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

### Attribution: edited, not dirty

The gate counts files this session edited that are **still dirty**, because
it judges a diff. The nudge does not, because it judges nothing. In this repo
nearly every session ends in a commit, so a dirty filter would leave the nudge
silent exactly when a session finished real work.

So the nudge counts every file the transcript shows this session editing
(Edit, Write, MultiEdit, NotebookEdit) inside this worktree, committed or not.
The count can only grow within a session. Another session's work never enters
it, because attribution comes from this session's transcript, not from the
tree. No `git status` is needed. The only git read is the worktree root.

The gate's `tribunal_session_edited_files` already maps transcript paths onto
the worktree, resolving symlinks such as macOS `/var` to `/private/var`. That
path-mapping loop is factored out into `tribunal_paths_in_worktree <root>`,
which reads absolute paths on stdin. The gate keeps calling
`tribunal_session_edited_files`, now a thin wrapper, and its existing tests
pin that its behavior is unchanged.

### One pass over the transcript

The edited files and the `/tribunal` check come from a single
`grep -E '"tool_use"|<command-name>'` followed by a single jq. The jq prints
`E\t<absolute path>` for each edit and `T` once if `/tribunal` ran. A long
session's transcript runs to megabytes, so two passes would double the
nudge's main cost.

`/tribunal` counts as ran when either of these shapes appears. Both were
checked against a real transcript, using other skills, since no transcript
yet holds a real `/tribunal` run:

- An assistant `tool_use` with `name == "Skill"` whose `input.skill` is
  `tribunal` or `tribunal:tribunal`.
- A user message whose content contains `<command-name>/tribunal</command-name>`
  or `<command-name>/tribunal:tribunal</command-name>`.

### Decision, per Stop

1. If `tribunal.nudge.enabled` is not `true`, exit. Nothing is emitted (see
   Events).
2. Resolve the project and session. The state file is
   `<tribunal_project_dir key>/nudge-<sid>.json`. With no project key it is
   `$ONLOOKER_DIR/tribunal/_unkeyed/nudge-<sid>.json`. `<sid>` is the
   session id sanitized the way the gate does it, with
   `tr -c 'a-zA-Z0-9-' '_'`. An empty id gives no state file: that Stop
   proceeds without dedupe, so two id-less sessions never share one.
3. Read the state file, or start from `{}`.
4. Skip, with the first reason that applies:
   - `gate_enabled`: `tribunal.stop_hook.enabled` is `true`, so the gate is
     already judging editing Stops.
   - `no_project_context`: there is no project key or repo root.
   - `no_transcript`: `transcript_path` is absent or unreadable.
   - `tribunal_ran`: `/tribunal` ran in this session (above).
5. Collect this session's edited files and drop those matching
   `ignore_globs`.
6. Check the triggers:
   - **size**: `min_files` is above 0 and the count reaches it. Setting
     `min_files` to 0 turns the size trigger off.
   - **sensitive**: any file matches `sensitive_globs`.

   If neither trips, skip with `below_threshold`.
7. Apply the frequency rule:
   - No nudge recorded yet: nudge, with trigger `size` or `sensitive`. When
     both trip, use `sensitive`.
   - A nudge recorded: nudge again with trigger `grew` only when a sensitive
     path appears that is not in `sensitive` (at any size), or the size
     trigger is tripped (`min_files` above 0 and the count at least
     `min_files`) and the count is at least twice `files`. A count that
     doubles below `min_files`, or with `min_files` 0, never speaks again on
     its own. Otherwise skip with `unchanged`.
8. Write the state back, read-modify-write, keeping every field it does not
   change:
   - On a skip whose reason is not yet in `skips_reported`: append the
     reason, write, and emit `tribunal.nudge.skipped`.
   - On a skip already reported: write nothing and emit nothing.
   - On a nudge: set `files` and `sensitive`, keep `skips_reported`, write,
     print the `systemMessage`, and emit `tribunal.nudge.shown`.

   Writes go through a temp file and `mv`, so a killed hook leaves the old
   state rather than a partial one.

### Message

```text
tribunal: this session changed 9 files, 2 sensitive (.github/workflows/ci.yml, db/migrations/004.sql). Worth a jury? /tribunal runs several judge models; type it to start.
```

It names at most three sensitive paths, then "and N more". When the trigger
is size alone, the sensitive clause is left out. The cost hint is there
because the full loop is 4 to 5 model calls per iteration and up to 3
iterations (tribunal ADR-001), which is far more than the gate's one judge.

### State file

```json
{"files": 9, "sensitive": [".github/workflows/ci.yml"], "skips_reported": ["below_threshold"]}
```

- `files` is an integer: the edited-file count at the last nudge.
- `sensitive` is an array of worktree-relative paths: the sensitive files at
  the last nudge.
- `skips_reported` is an array of skip reasons already emitted this session.

`files` and `sensitive` are absent until the first nudge. An unparseable
state file is treated as `{}`.

### Events, and what they cost

The gate's own measurement (ONL-172) puts one emission at about 100ms of node
startup. The nudge is on by default, so an emission on every Stop would land
on every session. ONL-172 also showed that emitting nothing on a skip makes an
idle plugin look broken. The nudge handles both this way:

- `tribunal.nudge.shown` is emitted on every nudge. That is rare by
  construction.
- `tribunal.nudge.skipped` is emitted once per session per reason. Every
  reason dedupes through the state file, including `gate_enabled`,
  `no_project_context` and `no_transcript`. A typical session pays for one or
  two emissions, not one per Stop.
- `disabled` is never emitted. A user who turns the nudge off would otherwise
  pay the emission on every Stop forever. Whether the nudge is off is a config
  fact, so a liveness check reads it from config, the same way it can read
  `stop_hook.enabled`. Updating `check-plugin-liveness` for the nudge is a
  follow-up, not part of this work.

Both types are registered in `@onlooker-community/schema` before anything
emits them:

| Type | Payload |
|------|---------|
| `tribunal.nudge.shown` | `{trigger: "size" \| "sensitive" \| "grew", session_files: int, sensitive_files: string[]}` |
| `tribunal.nudge.skipped` | `{reason: "gate_enabled" \| "no_project_context" \| "no_transcript" \| "tribunal_ran" \| "below_threshold" \| "unchanged"}` |

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

Reading it:

- `enabled` is read with `tribunal_config_get`.
- `min_files` is read with a new `tribunal_config_get_int`, a wrapper over
  the vendored `config_get_int`, matching `archivist-config.sh`.
  `config_get_int` returns the caller's default for a non-integer or negative
  value, so a bad `min_files` reads as 8.
- The two glob lists are read with `tribunal_config_get_json`. `config_get`
  is not used for the lists because it prints them as jq-formatted text; they
  are read with `tribunal_config_get_json`. An absent or non-array value falls
  back to the shipped list.

The defaults are kept narrow on purpose:

- `**/hooks/**` is left out because it matches nearly every plugin in this
  repo.
- `**/*auth*` is left out because it also matches `author*`, `oauth*` and
  `authoring.md`. The cost is that `auth.ts` and `authMiddleware.ts` outside an
  `auth/` directory are not flagged.

**An override replaces the list; it does not extend it.** The loader's
`deepmerge` merges objects, but an array from a higher layer wins outright. A
repo that wants its hooks treated as sensitive, and still wants the defaults,
restates them. In `.claude/settings.json` (ADR-004):

```json
{
  "tribunal": {
    "nudge": {
      "sensitive_globs": [
        "plugins/*/scripts/hooks/*.sh",
        ".github/workflows/**",
        "**/migrations/**",
        "**/auth/**",
        "**/*secret*",
        "**/*credential*",
        "**/.env*"
      ]
    }
  }
}
```

The onlooker CLI's `onlooker config set ... --scope project`, released in CLI
2.14.0 from the onlooker repo, writes the same file. The README documents
both.

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
- Matching is case-insensitive, under `nocasematch`, restored afterward as
  `assayer-extract.sh` does. On macOS's case-insensitive filesystem
  `Secrets.md` and `.ENV` are the same risk as their lowercase spellings.

## Known limitations

- Files changed only through Bash (`sed -i`, `mv`, codegen) are not counted.
  The transcript does not record them as edits.
- The count is of files edited, not of lines changed. Eight one-line edits
  trip the size trigger, while one 2000-line rewrite does not.

## Delivery

This is two PRs, in order:

1. **schema**: register both event types and release.
2. **ecosystem**:
   - bump `@onlooker-community/schema`
   - add the hook, the lib, `tribunal_config_get_int`,
     `tribunal_paths_in_worktree`, config and the `hooks.json` entry
   - add a README section
   - add `test/bus-coverage.json` entries for both types

## Testing

`test/bats/tribunal-stop-nudge.bats` is written before the hook. Each test
seeds a fixture repo and a transcript, runs the hook, and asserts on stdout,
the event log and the state file. Transcript fixtures copy the shapes in
"One pass over the transcript", which come from a real session.

- Fewer than `min_files` ordinary files: no output, `skipped:below_threshold`.
- `min_files` files: nudge with `trigger: size`, and the message names the
  count.
- Edited files that were then committed still count.
- `.github/workflows/ci.yml` alone: nudge with `trigger: sensitive`.
  `.GitHub/Workflows/CI.yml` does too. A lockfile alone does not trip it.
- A second Stop with no change: no output, `unchanged`. A new sensitive file,
  or a count that doubles while at or above `min_files`, nudges again with
  `trigger: grew`.
- A second below-threshold Stop emits no second `skipped:below_threshold`.
- A nudge after a reported skip keeps `skips_reported` in the state file.
- A Skill call to `tribunal:tribunal`, a Skill call to `tribunal`, and a typed
  `/tribunal` each give no output and `tribunal_ran`.
- Nudge disabled: no output and no event. Gate enabled: no output, and
  `gate_enabled` once.
- A project-scope `sensitive_globs` replaces the default list. The test sets
  only a hooks glob and asserts that a workflow file no longer trips.
- `min_files: 0` turns off the size trigger. A non-integer `min_files` reads
  as 8.
- An empty session id writes no state file.
- A file only another session edited is not counted, even while dirty.
- A `claude` stub that fails the test if it is called proves the nudge makes
  no model call.
- Stdout is empty or exactly one JSON object whose only key is
  `systemMessage`.
- The gate's existing tests (`tribunal-stop-gate-session-scope.bats`,
  `tribunal-stop-gate-worktree.bats`) pass unchanged after the
  `tribunal_paths_in_worktree` refactor.

Glob-to-regex unit tests live in `test/bats/tribunal-nudge-glob.bats`:

- `**/migrations/**` matches both `migrations/1.sql` and `db/migrations/1.sql`.
- `*` does not cross `/`.
- `.` and `+` in a glob are literal.
- Each case runs under the default bash and again under `/bin/bash` when that
  is a 3.2. CI runs Linux with bash 5, so without that second run 3.2 is
  covered only by running the suite locally on macOS.

Acceptance before the nudge ships on by default: a run against a synthetic
0.5MB transcript with 40 edited files, the size of a typical session in this
repo, stays under 300ms, measured from its `hook-health.jsonl` record, on a
macOS laptop. The 5MB case is recorded but not a gate.

Measured on 2026-11-15, with both events emitted detached and duplicate paths
dropped before the worktree filter:

| Transcript | `duration_ms` |
|---|---|
| 1 line (a skip) | 232–274 |
| 0.5MB, 40 files | 244–286 |
| 5MB, 40 files | 383–408 |

The first ~250ms is startup shared with the gate (median 226ms) and every
other Stop hook in the plugin: substrate resolution, config load, and git
lookups. Cutting it is follow-up work across plugins, not this hook's.
Before the two changes, the 5MB case took 494–544ms; before glob compilation,
40 files took about 780ms.
