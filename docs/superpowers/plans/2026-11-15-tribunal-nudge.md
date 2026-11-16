# Tribunal Nudge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A model-free Stop hook in the tribunal plugin that shows the user one line suggesting `/tribunal` when this session's edits are large or touch sensitive paths.

**Architecture:** There are two PRs. The schema PR registers `tribunal.nudge.shown` and `tribunal.nudge.skipped`, and must be released first. The ecosystem PR then adds:

- `plugins/tribunal/scripts/lib/tribunal-nudge.sh`, the pure logic: glob matching, a one-pass transcript scan, the decision, the message and the state I/O.
- `plugins/tribunal/scripts/hooks/tribunal-stop-nudge.sh`, the hook that wires the lib to config, the state file and the event bus.

The spec is `docs/superpowers/specs/2026-11-15-tribunal-nudge-design.md`. Read it before starting.

**Tech Stack:**

- schema: TypeScript, JSON Schema and vitest, with npm.
- ecosystem: bash hooks and libs (bash 3.2-compatible), jq, and bats tests through `npm run test:bats`.

## Global Constraints

- **Bash 3.2.** Every lib and hook line must run on bash 3.2 (macOS `/bin/bash`). No `globstar`, no `${var,,}`, no associative arrays, no `mapfile`.
- **Arithmetic under errexit.** Never use a bare `(( x++ ))`. Use `x=$((x + 1))`. `npm run lint:bash-arithmetic` enforces it.
- **bats gating.** Every non-final `[[ ]]`, `(( ))` or `!` assertion in a bats test ends with `|| return 1`. `npm run lint:bats-assertions` enforces it.
- **`$ONLOOKER_DIR`, never `~/.onlooker`.**
- **Hooks always exit 0.** Once registered, a hook leaves only through `hook_health_exit`, never a bare `exit`.
- **The nudge's stdout** is empty or exactly one JSON object whose only key is `systemMessage`.
- **No `claude` call anywhere in the nudge.**
- **Event types:** `tribunal.nudge.shown`, with payload `{trigger: "size"|"sensitive"|"grew", session_files: int, sensitive_files: string[] (max 20)}`, and `tribunal.nudge.skipped`, with payload `{reason: "gate_enabled"|"no_project_context"|"no_transcript"|"tribunal_ran"|"below_threshold"|"unchanged"}`. `disabled` is never emitted.
- **Config defaults** live under `.tribunal.nudge`:
  - `enabled: true`
  - `min_files: 8`
  - `sensitive_globs: [".github/workflows/**","**/migrations/**","**/auth/**","**/*secret*","**/*credential*","**/.env*"]`
  - `ignore_globs: ["**/*.lock","**/package-lock.json","**/pnpm-lock.yaml","**/yarn.lock"]`
- **Message format:** `tribunal: this session changed N files, K sensitive (p1, p2, p3 and M more). Worth a jury? /tribunal runs several judge models; type it to start.`
- **Commits** go through `/git-workflow:commit`. PRs go through `/git-workflow:pr`. Never push to main.
- **The schema work** happens in a new worktree. The main `schema` checkout holds another branch (`meagan/onl-221-...`), so don't touch it.
- **American English** everywhere.

---

## File structure

**schema repo** (worktree `../schema-tribunal-nudge`):

| File | Change |
|------|--------|
| `src/event-types.ts` | Add two constants and their `ALL_EVENT_TYPES` entries. |
| `schemas/event.v1.json` | Add two `event_type` enum entries. |
| `schemas/payload/plugins-safety.json` | Add two payload schemas. |
| `src/types.ts` | Add two payload interfaces and two map entries. |
| `src/event-roles.ts` | Add two roles. |
| `src/validate.test.ts` | Add tests and bump the entry count from 148 to 150. |

**ecosystem repo** (branch `meagan/tribunal-nudge`, which already holds the spec):

| File | Responsibility |
|------|----------------|
| `plugins/tribunal/scripts/lib/tribunal-session-files.sh` | Factor out `tribunal_paths_in_worktree`. |
| `plugins/tribunal/scripts/lib/tribunal-config.sh` | Add `tribunal_config_get_int`. |
| `plugins/tribunal/scripts/lib/tribunal-nudge.sh` (new) | Glob-to-regex, matching, scan, decide, message, state I/O. |
| `plugins/tribunal/scripts/hooks/tribunal-stop-nudge.sh` (new) | The Stop hook. |
| `plugins/tribunal/hooks/hooks.json` | Register the second Stop hook. |
| `plugins/tribunal/config.json` | Add the `nudge` defaults. |
| `plugins/tribunal/README.md` | Add a "Nudge" section. |
| `test/bus-coverage.json` | Add both types to `expected`. |
| `package.json`, `package-lock.json` | Bump `@onlooker-community/schema`. |
| `test/bats/tribunal-nudge-glob.bats` (new) | Glob tests, including under `/bin/bash` 3.2. |
| `test/bats/tribunal-nudge-lib.bats` (new) | Scan, decide, message and state tests. |
| `test/bats/tribunal-stop-nudge.bats` (new) | Hook tests. |

---

### Task 0: Confirm `systemMessage` renders from a plugin Stop hook (manual, 5 minutes)

The whole design rests on this, and no hook in the repo emits it yet. Do it before writing code.

- [ ] **Step 1:** In a scratch directory, add a throwaway project setting that registers a Stop hook printing the message:

```bash
mkdir -p /private/tmp/nudge-probe/.claude && cd /private/tmp/nudge-probe && git init -q
cat > .claude/settings.json <<'JSON'
{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"printf '%s' '{\"systemMessage\":\"tribunal: probe — this line should appear\"}'"}]}]}}
JSON
```

- [ ] **Step 2:** Run `claude` in `/private/tmp/nudge-probe`, send "say hi", and confirm the probe line appears after the turn ends. Also confirm Claude does **not** respond to it, meaning no extra turn.
- [ ] **Step 3:** If it does not render, stop and report to Meagan. The delivery section of the spec needs revisiting before any other task. Otherwise delete `/private/tmp/nudge-probe`.

---

### Task 1: Schema PR — register `tribunal.nudge.shown` and `tribunal.nudge.skipped`

**Files** (all in worktree `/Users/meaganwaller/src/github.com/onlooker-community/schema-tribunal-nudge`):
- Modify: `src/event-types.ts` (after `TRIBUNAL_GATE_ERRORED`, line 39, and in `ALL_EVENT_TYPES` after line 240)
- Modify: `schemas/event.v1.json` (enum, after `"tribunal.gate.errored"`, line 109)
- Modify: `schemas/payload/plugins-safety.json` (after the `"tribunal.gate.errored"` block)
- Modify: `src/types.ts` (interfaces after `TribunalGateErroredPayload`; map entries after `"tribunal.gate.errored"`, line 1748)
- Modify: `src/event-roles.ts` (after `"tribunal.gate.errored": "failed",`)
- Test: `src/validate.test.ts`

**Interfaces:**
- Produces: the event types `tribunal.nudge.shown` and `tribunal.nudge.skipped`, validated by the published schema. The ecosystem PR (Task 2 onward) depends on this release.

- [ ] **Step 1: Create the worktree and install**

```bash
cd /Users/meaganwaller/src/github.com/onlooker-community/schema
git fetch -q origin
git worktree add ../schema-tribunal-nudge -b meagan/tribunal-nudge-events origin/main
cd ../schema-tribunal-nudge && npm ci
```

- [ ] **Step 2: Write the failing tests**

In `src/validate.test.ts`, add `TRIBUNAL_NUDGE_SHOWN, TRIBUNAL_NUDGE_SKIPPED` to the import list from `./event-types` (alphabetical, after `TRIBUNAL_GATE_SKIPPED`). Add this block after the last `describe("tribunal.gate.` block. Find it with `grep -n 'describe("tribunal' src/validate.test.ts`.

```ts
// The Stop-time nudge toward /tribunal. It makes no model call; these record
// that it spoke, or why it stayed quiet, so an idle nudge is distinguishable
// from a broken one (ONL-172).
describe("tribunal.nudge.shown", () => {
	beforeEach(() => {
		_resetSequence();
	});

	function shown(payload: unknown) {
		return createEvent({
			runtime: "claude-code",
			plugin: "tribunal",
			machine_id: MACHINE_ID,
			session_id: "session-nudge-1",
			event_type: TRIBUNAL_NUDGE_SHOWN,
			payload: payload as never,
		});
	}

	it("validates each trigger", () => {
		for (const trigger of ["size", "sensitive", "grew"] as const) {
			expect(
				validate(
					shown({
						trigger,
						session_files: 9,
						sensitive_files: [".github/workflows/ci.yml"],
					}),
				).valid,
			).toBe(true);
		}
	});

	it("rejects an unknown trigger", () => {
		expect(
			validate(
				shown({ trigger: "vibes", session_files: 9, sensitive_files: [] }),
			).valid,
		).toBe(false);
	});

	it("rejects more than 20 sensitive files", () => {
		const files = Array.from({ length: 21 }, (_, i) => `auth/${i}.ts`);
		expect(
			validate(
				shown({ trigger: "sensitive", session_files: 21, sensitive_files: files }),
			).valid,
		).toBe(false);
	});

	it("rejects a negative file count", () => {
		expect(
			validate(shown({ trigger: "size", session_files: -1, sensitive_files: [] }))
				.valid,
		).toBe(false);
	});

	it("rejects an unregistered property", () => {
		expect(
			validate(
				shown({
					trigger: "size",
					session_files: 9,
					sensitive_files: [],
					message: "x",
				}),
			).valid,
		).toBe(false);
	});
});

describe("tribunal.nudge.skipped", () => {
	beforeEach(() => {
		_resetSequence();
	});

	function skipped(payload: unknown) {
		return createEvent({
			runtime: "claude-code",
			plugin: "tribunal",
			machine_id: MACHINE_ID,
			session_id: "session-nudge-1",
			event_type: TRIBUNAL_NUDGE_SKIPPED,
			payload: payload as never,
		});
	}

	it("validates each reason", () => {
		const reasons = [
			"gate_enabled",
			"no_project_context",
			"no_transcript",
			"tribunal_ran",
			"below_threshold",
			"unchanged",
		] as const;
		for (const reason of reasons) {
			expect(validate(skipped({ reason })).valid).toBe(true);
		}
	});

	// Turning the nudge off is a config fact, read from config. Emitting it
	// would cost every opted-out Stop a node exec forever.
	it("rejects disabled", () => {
		expect(validate(skipped({ reason: "disabled" })).valid).toBe(false);
	});

	it("rejects a skip with no reason", () => {
		expect(validate(skipped({})).valid).toBe(false);
	});
});
```

Also change the `ALL_EVENT_TYPES` count test from 148 to 150 (`it("has exactly 150 entries"` and `toBe(150)`).

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `npm test -- src/validate.test.ts`
Expected: a compile or import error for `TRIBUNAL_NUDGE_SHOWN`, or failures in the new blocks.

- [ ] **Step 4: Register the types**

`src/event-types.ts`, after `TRIBUNAL_GATE_ERRORED`:

```ts
export const TRIBUNAL_NUDGE_SHOWN = "tribunal.nudge.shown" as const;
export const TRIBUNAL_NUDGE_SKIPPED = "tribunal.nudge.skipped" as const;
```

and in `ALL_EVENT_TYPES` after `TRIBUNAL_GATE_ERRORED,`:

```ts
	TRIBUNAL_NUDGE_SHOWN,
	TRIBUNAL_NUDGE_SKIPPED,
```

`schemas/event.v1.json`, in the `event_type` enum after `"tribunal.gate.errored",`:

```json
				"tribunal.nudge.shown",
				"tribunal.nudge.skipped",
```

`schemas/payload/plugins-safety.json`, after the closing `},` of `"tribunal.gate.errored"`:

```json
		"tribunal.nudge.shown": {
			"type": "object",
			"additionalProperties": false,
			"required": ["trigger", "session_files", "sensitive_files"],
			"properties": {
				"trigger": {
					"type": "string",
					"enum": ["size", "sensitive", "grew"],
					"description": "What made the Stop-time nudge suggest /tribunal. size: this session edited at least nudge.min_files files. sensitive: it edited a file matching nudge.sensitive_globs (wins when both apply). grew: a nudge was already shown this session, and since then a new sensitive file appeared or the file count doubled. The nudge makes no model call."
				},
				"session_files": {
					"type": "integer",
					"minimum": 0,
					"description": "Files this session's transcript shows it editing inside the worktree, committed or not, after nudge.ignore_globs."
				},
				"sensitive_files": {
					"type": "array",
					"maxItems": 20,
					"items": { "type": "string" },
					"description": "Worktree-relative paths that matched nudge.sensitive_globs, capped at 20."
				}
			}
		},
		"tribunal.nudge.skipped": {
			"type": "object",
			"additionalProperties": false,
			"required": ["reason"],
			"properties": {
				"reason": {
					"type": "string",
					"enum": [
						"gate_enabled",
						"no_project_context",
						"no_transcript",
						"tribunal_ran",
						"below_threshold",
						"unchanged"
					],
					"description": "Why the Stop-time nudge stayed quiet. Each reason is emitted at most once per session, so a typical session costs one or two emissions rather than one per Stop. gate_enabled: tribunal.stop_hook.enabled is on, so the paid gate already judges editing Stops. tribunal_ran: /tribunal already ran in this session. below_threshold: neither trigger tripped. unchanged: a nudge was shown and nothing has grown since. There is deliberately no disabled reason: turning the nudge off is read from config, and emitting it would cost an opted-out user a node exec on every Stop."
				}
			}
		},
```

`src/types.ts`, after the `TribunalGateErroredPayload` interface:

```ts
/**
 * The Stop-time nudge suggested /tribunal. It makes no model call; this is
 * the record that it spoke, and why.
 */
export interface TribunalNudgeShownPayload {
	trigger: "size" | "sensitive" | "grew";
	session_files: number;
	/** Worktree-relative, at most 20. */
	sensitive_files: string[];
}

/**
 * The Stop-time nudge stayed quiet, at most once per session per reason.
 * There is no `disabled`: that is read from config.
 */
export interface TribunalNudgeSkippedPayload {
	reason:
		| "gate_enabled"
		| "no_project_context"
		| "no_transcript"
		| "tribunal_ran"
		| "below_threshold"
		| "unchanged";
}
```

and in the payload map after `"tribunal.gate.errored": TribunalGateErroredPayload;`:

```ts
	"tribunal.nudge.shown": TribunalNudgeShownPayload;
	"tribunal.nudge.skipped": TribunalNudgeSkippedPayload;
```

`src/event-roles.ts`, after `"tribunal.gate.errored": "failed",`:

```ts
	// The Stop-time nudge toward /tribunal. Suggesting is its job, so shown is
	// output; staying quiet below threshold is a deliberate skip.
	"tribunal.nudge.shown": "output",
	"tribunal.nudge.skipped": "skipped",
```

- [ ] **Step 5: Run the full check and confirm it passes**

Run: `npm run ci`. If there is no `ci` script, run `npm run lint && npm run typecheck && npm test && npm run validate-schemas`.
Expected: all pass, and the new blocks show 8 passing tests.

- [ ] **Step 6: Mutation check**

Temporarily add `"disabled"` to the skipped enum in `plugins-safety.json`, run `npm test -- src/validate.test.ts`, and confirm `rejects disabled` fails. Revert the change.

- [ ] **Step 7: Commit and open the PR**

Run `/git-workflow:commit` with: `feat(events): give the tribunal nudge two event types`. In the body, say why there's no `disabled` reason. Then run `/git-workflow:pr`. Meagan submits and merges it, and release-please publishes the minor release. Note the published version, `3.x.0`, for Task 7.

---

### Task 2: Glob-to-regex and case-insensitive matching

**Files:**
- Create: `plugins/tribunal/scripts/lib/tribunal-nudge.sh`
- Test: `test/bats/tribunal-nudge-glob.bats`

**Interfaces:**
- Produces:
  - `tribunal_nudge_glob_to_regex <glob>` prints an anchored ERE on stdout.
  - `tribunal_nudge_matches_any <path> [glob...]` returns 0 if `path` matches any glob, case-insensitively, and 1 otherwise. It restores `nocasematch`.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats

# Glob matching for the Stop-time nudge (docs/superpowers/specs/
# 2026-11-15-tribunal-nudge-design.md, "Glob matching"). No globstar: macOS
# /bin/bash is 3.2 and has none, and `**/x/**` under [[ == ]] misses a
# root-level x/. Each case also runs under /bin/bash when that is a 3.2,
# because CI runs bash 5 and would never see a 3.2-only break.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	LIB="${REPO_ROOT}/plugins/tribunal/scripts/lib/tribunal-nudge.sh"
	# shellcheck source=../../plugins/tribunal/scripts/lib/tribunal-nudge.sh
	source "$LIB"
}

# _match_in <bash> <path> <glob> — run the matcher under a given interpreter.
_match_in() {
	"$1" -c 'source "$1"; tribunal_nudge_matches_any "$2" "$3"' _ "$LIB" "$2" "$3"
}

@test "**/ matches zero or more leading directories" {
	tribunal_nudge_matches_any "migrations/1.sql" "**/migrations/**" || return 1
	tribunal_nudge_matches_any "db/migrations/1.sql" "**/migrations/**" || return 1
	tribunal_nudge_matches_any "a/b/migrations/x/y.sql" "**/migrations/**"
}

@test "* stays inside one path segment" {
	tribunal_nudge_matches_any "plugins/x/hooks/a.sh" "plugins/*/hooks/*.sh" || return 1
	! tribunal_nudge_matches_any "plugins/x/y/hooks/a.sh" "plugins/*/hooks/*.sh"
}

@test "regex metacharacters in a glob are literal" {
	tribunal_nudge_matches_any ".github/workflows/ci.yml" ".github/workflows/**" || return 1
	! tribunal_nudge_matches_any "xgithub/workflows/ci.yml" ".github/workflows/**" || return 1
	tribunal_nudge_matches_any "c++/a.h" "c++/*.h" || return 1
	! tribunal_nudge_matches_any "ccc/a.h" "c++/*.h"
}

@test "the match is anchored at both ends" {
	! tribunal_nudge_matches_any "src/auth/x.ts.bak/deep" "src/auth/*.ts" || return 1
	! tribunal_nudge_matches_any "vendor/.github/workflows/ci.yml" ".github/workflows/**"
}

@test "matching ignores case, and leaves nocasematch as it found it" {
	tribunal_nudge_matches_any "docs/Secrets.md" "**/*secret*" || return 1
	tribunal_nudge_matches_any "config/.ENV" "**/.env*" || return 1
	shopt -u nocasematch
	tribunal_nudge_matches_any "A.md" "a.md" || return 1
	! shopt -q nocasematch
}

@test "no glob matches nothing" {
	! tribunal_nudge_matches_any "a.txt"
}

@test "the same cases hold under /bin/bash 3.2" {
	[[ -x /bin/bash ]] || skip "no /bin/bash"
	[[ "$(/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}"')" == "3" ]] || skip "/bin/bash is not 3.2"
	_match_in /bin/bash "migrations/1.sql" "**/migrations/**" || return 1
	_match_in /bin/bash "docs/Secrets.md" "**/*secret*" || return 1
	! _match_in /bin/bash "plugins/x/y/hooks/a.sh" "plugins/*/hooks/*.sh"
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/tribunal-nudge-glob.bats`
Expected: FAIL, because `tribunal-nudge.sh` does not exist.

- [ ] **Step 3: Implement**

`plugins/tribunal/scripts/lib/tribunal-nudge.sh`:

```bash
#!/usr/bin/env bash
# The Stop-time nudge toward /tribunal: everything it decides, with no I/O
# beyond the state file it is handed. The hook (tribunal-stop-nudge.sh) wires
# this to config, the transcript and the bus.
# Spec: docs/superpowers/specs/2026-11-15-tribunal-nudge-design.md

# Usage: tribunal_nudge_glob_to_regex <glob>
# An anchored ERE for a glob over a worktree-relative path. `**/` is zero or
# more leading directories, `**` elsewhere is anything, `*` and `?` stay inside
# one segment. Matched with [[ =~ ]] rather than globstar, which bash 3.2 lacks.
tribunal_nudge_glob_to_regex() {
	local g="$1" out="" c i=0 n=${#1}
	while [[ $i -lt $n ]]; do
		c="${g:i:1}"
		if [[ "$c" == "*" && "${g:i+1:1}" == "*" ]]; then
			if [[ "${g:i+2:1}" == "/" ]]; then
				out+="(.*/)?"
				i=$((i + 3))
			else
				out+=".*"
				i=$((i + 2))
			fi
			continue
		fi
		case "$c" in
			"*") out+="[^/]*" ;;
			"?") out+="[^/]" ;;
			"." | "+" | "^" | "$" | "(" | ")" | "[" | "]" | "{" | "}" | "|" | "\\") out+="\\${c}" ;;
			*) out+="$c" ;;
		esac
		i=$((i + 1))
	done
	printf '^%s$' "$out"
}

# Usage: tribunal_nudge_matches_any <path> [glob...]
# Case-insensitive: on macOS's filesystem Secrets.md and .ENV are the same
# risk as their lowercase spellings. nocasematch is restored, as assayer does.
tribunal_nudge_matches_any() {
	local path="$1" glob re hit=1 restore
	shift
	restore=$(shopt -p nocasematch)
	shopt -s nocasematch
	for glob in "$@"; do
		re=$(tribunal_nudge_glob_to_regex "$glob")
		if [[ "$path" =~ $re ]]; then
			hit=0
			break
		fi
	done
	eval "$restore"
	return "$hit"
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `scripts/test/run-bats.sh test/bats/tribunal-nudge-glob.bats`
Expected: PASS, 7 tests. On macOS the 3.2 test runs; elsewhere it skips.

- [ ] **Step 5: Mutation check**

Change `out+="(.*/)?"` to `out+=".*/"` and confirm the `**/` test fails. Revert.

- [ ] **Step 6: Commit** via `/git-workflow:commit`: `feat(tribunal): match nudge globs without globstar`.

---

### Task 3: Factor out `tribunal_paths_in_worktree`, and add the one-pass scan

**Files:**
- Modify: `plugins/tribunal/scripts/lib/tribunal-session-files.sh` (`tribunal_session_edited_files`, lines 28–58)
- Modify: `plugins/tribunal/scripts/lib/tribunal-nudge.sh`
- Test: `test/bats/tribunal-nudge-lib.bats` (new)

**Interfaces:**
- Produces:
  - `tribunal_paths_in_worktree <worktree_root>` reads absolute paths on stdin and prints each one inside the worktree as a worktree-relative path, deduplicated and symlink-resolved.
  - `tribunal_nudge_scan <transcript>` prints `E<TAB><absolute path>` for each write-class edit, and `T` for each `/tribunal` run.
- Consumes: nothing new. `tribunal_session_edited_files` keeps its signature.

- [ ] **Step 1: Write the failing tests**

`test/bats/tribunal-nudge-lib.bats`:

```bash
#!/usr/bin/env bats

# The nudge's lib: the one-pass transcript scan, the decision, the message and
# the state file. Fixture shapes come from a real transcript: a Skill call
# carries input.skill, a typed command shows as <command-name>/x</command-name>.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	# shellcheck source=../../plugins/tribunal/scripts/lib/tribunal-session-files.sh
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-session-files.sh"
	# shellcheck source=../../plugins/tribunal/scripts/lib/tribunal-nudge.sh
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-nudge.sh"
	T="${BATS_TEST_TMPDIR}/transcript.jsonl"
	: > "$T"
}

_tool() { # <name> <input-json>
	jq -cn --arg n "$1" --argjson in "$2" \
		'{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "toolu_1", name: $n, input: $in}]}}' >> "$T"
}

_typed() { # <command>
	jq -cn --arg c "$1" \
		'{type: "user", message: {role: "user", content: ("<command-message>x</command-message>\n<command-name>" + $c + "</command-name>")}}' >> "$T"
}

@test "scan lists each write-class edit's absolute path" {
	_tool Edit '{"file_path":"/r/a.txt"}'
	_tool Write '{"file_path":"/r/b.txt"}'
	_tool NotebookEdit '{"notebook_path":"/r/c.ipynb"}'
	_tool Read '{"file_path":"/r/d.txt"}'
	run tribunal_nudge_scan "$T"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "$(printf 'E\t/r/a.txt\nE\t/r/b.txt\nE\t/r/c.ipynb')" ]
}

@test "scan marks a Skill call to tribunal or tribunal:tribunal" {
	_tool Skill '{"skill":"tribunal:tribunal","args":"x"}'
	run tribunal_nudge_scan "$T"
	[ "$output" = "T" ] || return 1
	: > "$T"
	_tool Skill '{"skill":"tribunal"}'
	run tribunal_nudge_scan "$T"
	[ "$output" = "T" ]
}

@test "scan marks a typed /tribunal, and ignores other skills and mentions" {
	_typed "/tribunal"
	run tribunal_nudge_scan "$T"
	[ "$output" = "T" ] || return 1
	: > "$T"
	_tool Skill '{"skill":"git-workflow:commit"}'
	_typed "/pickup"
	jq -cn '{type: "user", message: {role: "user", content: "should I run /tribunal?"}}' >> "$T"
	run tribunal_nudge_scan "$T"
	[ -z "$output" ]
}

@test "scan skips lines that are not JSON" {
	printf 'not json "tool_use"\n' >> "$T"
	_tool Edit '{"file_path":"/r/a.txt"}'
	run tribunal_nudge_scan "$T"
	[ "$output" = "$(printf 'E\t/r/a.txt')" ]
}

@test "paths_in_worktree keeps paths inside the root, relative and deduplicated" {
	mkdir -p "${BATS_TEST_TMPDIR}/wt/sub" "${BATS_TEST_TMPDIR}/other"
	run tribunal_paths_in_worktree "${BATS_TEST_TMPDIR}/wt" <<EOF
${BATS_TEST_TMPDIR}/wt/sub/a.txt
${BATS_TEST_TMPDIR}/wt/sub/a.txt
${BATS_TEST_TMPDIR}/wt/b.txt
${BATS_TEST_TMPDIR}/other/c.txt
${BATS_TEST_TMPDIR}/gone/d.txt
EOF
	[ "$output" = "$(printf 'b.txt\nsub/a.txt')" ]
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/tribunal-nudge-lib.bats`
Expected: FAIL with `tribunal_nudge_scan: command not found` and `tribunal_paths_in_worktree: command not found`.

- [ ] **Step 3: Implement the refactor**

In `tribunal-session-files.sh`, replace the body of `tribunal_session_edited_files` (from `local root_phys` through the final `| sort -u`) so that the path loop moves into a new function. Keep the existing comment above `tribunal_session_edited_files`.

```bash
tribunal_session_edited_files() {
	local transcript="$1" root="$2"
	[[ -n "$transcript" && -f "$transcript" && -n "$root" ]] || return 0
	# grep first so jq parses only the lines that can hold a tool call; a long
	# session's transcript runs to megabytes. -R with fromjson? skips any line
	# that is not valid JSON instead of failing the whole read.
	grep -F '"tool_use"' "$transcript" 2>/dev/null \
		| jq -rR '
			fromjson? | select(.type == "assistant") | .message.content[]?
			| select(.type == "tool_use"
				and (.name | IN("Edit", "Write", "MultiEdit", "NotebookEdit")))
			| (.input.file_path // .input.notebook_path // empty) | strings
			| select(startswith("/"))
		' 2>/dev/null \
		| tribunal_paths_in_worktree "$root"
}

# Usage: tribunal_paths_in_worktree <worktree_root>
# Reads absolute paths on stdin; prints each one inside the worktree, relative
# to it, deduplicated. Both sides are compared in physical form: git reports
# the root with symlinks resolved, while a transcript keeps whatever spelling
# the session used, so on macOS /var/... would never prefix-match git's
# /private/var/.... Deduplicated before the loop, which resolves each path's
# directory once. Shared by the gate and the nudge.
tribunal_paths_in_worktree() {
	local root="$1" root_phys p dir
	[[ -n "$root" ]] || return 0
	root_phys=$(cd "$root" 2>/dev/null && pwd -P) || return 0
	sort -u \
		| while IFS= read -r p; do
			# A directory that no longer exists holds nothing to count.
			dir=$(cd "${p%/*}/" 2>/dev/null && pwd -P) || continue
			p="${dir%/}/${p##*/}"
			case "$p" in
				"$root_phys"/*) printf '%s\n' "${p#"$root_phys"/}" ;;
			esac
		done \
		| sort -u
}
```

Then move the "Both sides are compared in physical form" paragraph out of the comment above `tribunal_session_edited_files`, since it now lives on `tribunal_paths_in_worktree`.

- [ ] **Step 4: Implement the scan**

Append to `tribunal-nudge.sh`:

```bash
# Usage: tribunal_nudge_scan <transcript>
# One pass over the transcript for both things the nudge needs: `E<TAB><path>`
# per write-class edit, and `T` per /tribunal run. A long session's transcript
# runs to megabytes, so the grep keeps jq to the lines that can matter.
#
# /tribunal counts as ran for a Skill tool_use whose input.skill is tribunal
# or tribunal:tribunal, or a user turn carrying <command-name>/tribunal</...>
# (or /tribunal:tribunal). Text that merely mentions /tribunal does not count.
tribunal_nudge_scan() {
	local transcript="$1"
	[[ -n "$transcript" && -f "$transcript" ]] || return 0
	grep -E '"tool_use"|<command-name>' "$transcript" 2>/dev/null \
		| jq -rR '
			fromjson? |
			if .type == "assistant" then
				.message.content[]? | select(type == "object" and .type == "tool_use")
				| if (.name | IN("Edit", "Write", "MultiEdit", "NotebookEdit")) then
					(.input.file_path // .input.notebook_path // empty) | strings
					| select(startswith("/")) | "E\t" + .
				elif .name == "Skill" and ((.input.skill // "") | IN("tribunal", "tribunal:tribunal")) then
					"T"
				else empty end
			elif .type == "user" then
				(.message.content
					| if type == "string" then .
					  else ([.[]? | select(type == "object" and .type == "text") | .text] | join("\n")) end)
				| select(test("<command-name>/tribunal(:tribunal)?</command-name>")) | "T"
			else empty end
		' 2>/dev/null
}
```

- [ ] **Step 5: Run the new tests and the gate's tests**

Run: `scripts/test/run-bats.sh test/bats/tribunal-nudge-lib.bats test/bats/tribunal-stop-gate-session-scope.bats test/bats/tribunal-stop-gate-worktree.bats test/bats/tribunal-stop-hook.bats`
Expected: all PASS. The gate's files pin that the refactor changed nothing.

- [ ] **Step 6: Mutation check**

Change `IN("tribunal", "tribunal:tribunal")` to `IN("tribunal")` in the scan and confirm the Skill test fails. Then remove the `test("<command-name>...")` select and confirm the "ignores other skills and mentions" test fails. Revert both.

- [ ] **Step 7: Commit** via `/git-workflow:commit`: `refactor(tribunal): share worktree path mapping; scan once for the nudge`.

---

### Task 4: The decision, the message and the state file

**Files:**
- Modify: `plugins/tribunal/scripts/lib/tribunal-nudge.sh`
- Test: `test/bats/tribunal-nudge-lib.bats`

**Interfaces:**
- Produces:
  - `tribunal_nudge_decide <count> <sensitive_json_array> <min_files> <state_json>` prints compact JSON, either `{"action":"nudge","trigger":"size"|"sensitive"|"grew"}` or `{"action":"skip","reason":"below_threshold"|"unchanged"}`.
  - `tribunal_nudge_message <count> <sensitive_json_array>` prints the message text.
  - `tribunal_nudge_state_read <path>` prints the state JSON, or `{}` when the file is missing or unparseable.
  - `tribunal_nudge_state_write <path> <json>` writes atomically (tmp then mv). It does nothing when `path` is empty.

- [ ] **Step 1: Write the failing tests** (append to `tribunal-nudge-lib.bats`)

```bash
_decide() { tribunal_nudge_decide "$@" | jq -c .; }

@test "decide: below both triggers skips below_threshold" {
	[ "$(_decide 3 '[]' 8 '{}')" = '{"action":"skip","reason":"below_threshold"}' ]
}

@test "decide: reaching min_files nudges on size" {
	[ "$(_decide 8 '[]' 8 '{}')" = '{"action":"nudge","trigger":"size"}' ]
}

@test "decide: a sensitive file nudges on sensitive, which wins over size" {
	[ "$(_decide 1 '["auth/a.ts"]' 8 '{}')" = '{"action":"nudge","trigger":"sensitive"}' ] || return 1
	[ "$(_decide 9 '["auth/a.ts"]' 8 '{}')" = '{"action":"nudge","trigger":"sensitive"}' ]
}

@test "decide: min_files 0 turns the size trigger off" {
	[ "$(_decide 50 '[]' 0 '{}')" = '{"action":"skip","reason":"below_threshold"}' ]
}

@test "decide: after a nudge, no growth is unchanged" {
	[ "$(_decide 9 '["auth/a.ts"]' 8 '{"files":9,"sensitive":["auth/a.ts"]}')" = '{"action":"skip","reason":"unchanged"}' ]
}

@test "decide: a new sensitive file, or a doubled count, is grew" {
	[ "$(_decide 9 '["auth/a.ts","auth/b.ts"]' 8 '{"files":9,"sensitive":["auth/a.ts"]}')" = '{"action":"nudge","trigger":"grew"}' ] || return 1
	[ "$(_decide 17 '[]' 8 '{"files":9,"sensitive":[]}')" = '{"action":"skip","reason":"unchanged"}' ] || return 1
	[ "$(_decide 18 '[]' 8 '{"files":9,"sensitive":[]}')" = '{"action":"nudge","trigger":"grew"}' ]
}

@test "decide: skips_reported alone does not count as a prior nudge" {
	[ "$(_decide 8 '[]' 8 '{"skips_reported":["below_threshold"]}')" = '{"action":"nudge","trigger":"size"}' ]
}

@test "message names the count, up to three sensitive paths, and the rest" {
	run tribunal_nudge_message 9 '["a","b","c","d","e"]'
	[ "$output" = "tribunal: this session changed 9 files, 5 sensitive (a, b, c and 2 more). Worth a jury? /tribunal runs several judge models; type it to start." ]
}

@test "message leaves out the sensitive clause for size alone, and says file for one" {
	run tribunal_nudge_message 8 '[]'
	[ "$output" = "tribunal: this session changed 8 files. Worth a jury? /tribunal runs several judge models; type it to start." ] || return 1
	run tribunal_nudge_message 1 '["auth/a.ts"]'
	[ "$output" = "tribunal: this session changed 1 file, 1 sensitive (auth/a.ts). Worth a jury? /tribunal runs several judge models; type it to start." ]
}

@test "state: missing or unparseable reads as {}, and a write round-trips" {
	S="${BATS_TEST_TMPDIR}/state/nudge-s.json"
	[ "$(tribunal_nudge_state_read "$S")" = "{}" ] || return 1
	mkdir -p "${S%/*}"
	printf 'not json' > "$S"
	[ "$(tribunal_nudge_state_read "$S")" = "{}" ] || return 1
	tribunal_nudge_state_write "$S" '{"files":2}'
	[ "$(tribunal_nudge_state_read "$S")" = '{"files":2}' ] || return 1
	[ ! -e "${S}.tmp" ]
}

@test "state: an empty path writes nothing" {
	tribunal_nudge_state_write "" '{"files":2}'
	[ -z "$(find "$BATS_TEST_TMPDIR" -name 'nudge-*')" ]
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/tribunal-nudge-lib.bats`
Expected: the new tests FAIL with `command not found`.

- [ ] **Step 3: Implement** (append to `tribunal-nudge.sh`)

```bash
# Usage: tribunal_nudge_decide <count> <sensitive_json> <min_files> <state_json>
# The frequency rule. A first nudge names its trigger, sensitive winning over
# size. After that, only growth speaks again: a sensitive path not seen at the
# last nudge, or at least twice the files. skips_reported is not a nudge.
tribunal_nudge_decide() {
	jq -cn --argjson n "$1" --argjson sens "$2" --argjson min "$3" --argjson st "$4" '
		($min > 0 and $n >= $min) as $size
		| (($sens | length) > 0) as $s
		| if ($size or $s) | not then {action: "skip", reason: "below_threshold"}
		  elif ($st | has("files")) | not then
			{action: "nudge", trigger: (if $s then "sensitive" else "size" end)}
		  elif (($sens - ($st.sensitive // [])) | length) > 0 or $n >= 2 * $st.files then
			{action: "nudge", trigger: "grew"}
		  else {action: "skip", reason: "unchanged"} end'
}

# Usage: tribunal_nudge_message <count> <sensitive_json>
# The cost hint is there because /tribunal runs several judge models per
# iteration (tribunal ADR-001), far more than the gate's one judge.
tribunal_nudge_message() {
	jq -rn --argjson n "$1" --argjson s "$2" '
		"tribunal: this session changed \($n) file\(if $n == 1 then "" else "s" end)"
		+ (if ($s | length) > 0 then
			", \($s | length) sensitive (" + ($s[0:3] | join(", "))
			+ (if ($s | length) > 3 then " and \(($s | length) - 3) more" else "" end) + ")"
		  else "" end)
		+ ". Worth a jury? /tribunal runs several judge models; type it to start."'
}

# Usage: tribunal_nudge_state_read <path>
tribunal_nudge_state_read() {
	local path="$1" v=""
	[[ -n "$path" && -f "$path" ]] && v=$(jq -ce 'select(type == "object")' "$path" 2>/dev/null)
	printf '%s' "${v:-"{}"}"
}

# Usage: tribunal_nudge_state_write <path> <json>
# Through a temp file and mv, so a killed hook leaves the old state, not half
# of a new one. No path (no session id) means no state, never a shared file.
tribunal_nudge_state_write() {
	local path="$1" json="$2"
	[[ -n "$path" ]] || return 0
	mkdir -p "${path%/*}" 2>/dev/null || return 0
	printf '%s\n' "$json" > "${path}.tmp" 2>/dev/null && mv -f "${path}.tmp" "$path" 2>/dev/null
	return 0
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `scripts/test/run-bats.sh test/bats/tribunal-nudge-lib.bats`
Expected: PASS, 16 tests.

- [ ] **Step 5: Mutation check**

Change `2 * $st.files` to `$st.files + 1` and confirm the "doubled count" test fails. Revert.

- [ ] **Step 6: Commit** via `/git-workflow:commit`: `feat(tribunal): decide when the nudge speaks again`.

---

### Task 5: Config defaults and `tribunal_config_get_int`

**Files:**
- Modify: `plugins/tribunal/config.json` (add `nudge` under `tribunal`, after `stop_hook`)
- Modify: `plugins/tribunal/scripts/lib/tribunal-config.sh` (after `tribunal_config_get_json`)
- Test: `test/bats/tribunal-config.bats`

**Interfaces:**
- Produces:
  - `tribunal_config_get_int <jq_path> <default>` prints a non-negative integer.
  - The config keys `.tribunal.nudge.{enabled,min_files,sensitive_globs,ignore_globs}`.

- [ ] **Step 1: Write the failing tests** (append to `test/bats/tribunal-config.bats`; reuse its existing `setup`)

Read the top of that file first to see how it seeds a project's `.claude/settings.json` and calls `tribunal_config_load`. Then add:

```bash
@test "nudge defaults ship on, with min_files 8 and both glob lists" {
	tribunal_config_load "$BATS_TEST_TMPDIR"
	[ "$(tribunal_config_get '.tribunal.nudge.enabled')" = "true" ] || return 1
	[ "$(tribunal_config_get_int '.tribunal.nudge.min_files' 8)" = "8" ] || return 1
	tribunal_config_get_json '.tribunal.nudge.sensitive_globs' | jq -e 'index(".github/workflows/**") != null' >/dev/null || return 1
	tribunal_config_get_json '.tribunal.nudge.ignore_globs' | jq -e 'index("**/*.lock") != null' >/dev/null
}

@test "a glob list reads through get_json, not get" {
	tribunal_config_load "$BATS_TEST_TMPDIR"
	[ -z "$(tribunal_config_get '.tribunal.nudge.sensitive_globs')" ] || return 1
	[ "$(tribunal_config_get_json '.tribunal.nudge.sensitive_globs' | jq -r type)" = "array" ]
}

@test "a non-integer min_files reads as the default" {
	mkdir -p "${BATS_TEST_TMPDIR}/p/.claude"
	printf '{"tribunal":{"nudge":{"min_files":"lots"}}}' > "${BATS_TEST_TMPDIR}/p/.claude/settings.json"
	tribunal_config_load "${BATS_TEST_TMPDIR}/p"
	[ "$(tribunal_config_get_int '.tribunal.nudge.min_files' 8)" = "8" ]
}

@test "a project sensitive_globs replaces the default list" {
	mkdir -p "${BATS_TEST_TMPDIR}/p/.claude"
	printf '{"tribunal":{"nudge":{"sensitive_globs":["plugins/*/scripts/hooks/*.sh"]}}}' > "${BATS_TEST_TMPDIR}/p/.claude/settings.json"
	tribunal_config_load "${BATS_TEST_TMPDIR}/p"
	[ "$(tribunal_config_get_json '.tribunal.nudge.sensitive_globs')" = '["plugins/*/scripts/hooks/*.sh"]' ]
}
```

If `tribunal-config.bats` loads config from a git repo fixture rather than a plain directory, use its fixture path in place of `${BATS_TEST_TMPDIR}/p`. The loader treats a plain directory as the project, so either works.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/tribunal-config.bats`
Expected: the new tests FAIL, because `tribunal_config_get_int` is not found and the `nudge` keys are absent.

- [ ] **Step 3: Implement**

`tribunal-config.sh`, after `tribunal_config_get_json`:

```bash
# A non-negative integer, falling back to the default on anything else. Use it
# for any value that reaches arithmetic: the plain getter returns whatever is
# configured, and a non-numeric value then kills the caller at status 0
# (ONL-132). Same as archivist_config_int.
tribunal_config_get_int() {
	local path="$1"
	local default="$2"
	config_get_int "_TRIBUNAL_CONFIG" "${path}" "${default}"
}
```

`config.json`: insert after the `stop_hook` object, inside `tribunal`. Edit it as text with the Edit tool, not `jq` or `json.dumps`, which reformat the file.

```json
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
    },
```

Match the file's existing indentation. Check it with `jq . plugins/tribunal/config.json >/dev/null`.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `scripts/test/run-bats.sh test/bats/tribunal-config.bats`
Expected: PASS.

- [ ] **Step 5: Commit** via `/git-workflow:commit`: `feat(tribunal): ship nudge defaults and an int accessor`.

---

### Task 6: The hook

**Files:**
- Create: `plugins/tribunal/scripts/hooks/tribunal-stop-nudge.sh` (mode 755)
- Modify: `plugins/tribunal/hooks/hooks.json`
- Test: `test/bats/tribunal-stop-nudge.bats`

**Interfaces:**
- Consumes:
  - from Tasks 2–4: `tribunal_nudge_matches_any`, `tribunal_nudge_scan`, `tribunal_paths_in_worktree`, `tribunal_nudge_decide`, `tribunal_nudge_message`, `tribunal_nudge_state_read` and `tribunal_nudge_state_write`
  - from Task 5: `tribunal_config_get_int`
  - from existing libs: `tribunal_config_load`, `tribunal_config_get`, `tribunal_config_get_json`, `tribunal_config_stop_hook_enabled`, `tribunal_emit_event`, `tribunal_project_dir`, `tribunal_storage_root`, `onlooker_project_repo_root`, `onlooker_worktree_root`, `onlooker_project_resolve`, `hook_health_*` and `onlooker_resolve_substrate`
- Produces: the Stop-hook behavior in the spec's "Decision, per Stop".

Until Task 7 bumps the schema dependency, `ONLOOKER_VALIDATE=1` rejects the new event types. During this task, assert on the state file and stdout. Event-log assertions are added in Task 7. For the same reason, don't run `npm run test:bus` yet.

- [ ] **Step 1: Write the failing tests**

`test/bats/tribunal-stop-nudge.bats`:

```bash
#!/usr/bin/env bats

# The Stop-time nudge toward /tribunal (docs/superpowers/specs/
# 2026-11-15-tribunal-nudge-design.md). It makes no model call, prints at most
# one {"systemMessage": ...}, counts the files THIS session's transcript shows
# it editing (committed or not), and speaks again only when that grows.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/tribunal-stop-nudge.sh"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name "Test"
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	git -C "$REPO" commit -q --allow-empty -m seed
	mkdir -p "${REPO}/.claude"
	printf '.claude/\n' > "${REPO}/.git/info/exclude"
	PROJECT_KEY=$(onlooker_project_key "$REPO")

	# Any model call fails the test.
	CLAUDE_MARKER="${BATS_TEST_TMPDIR}/claude-was-invoked"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	printf '#!/usr/bin/env bash\nprintf invoked >> %q\nexit 1\n' "$CLAUDE_MARKER" > "${STUB_BIN}/claude"
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	SID="sess-nudge"
}

_settings() { # <json for .tribunal>
	jq -cn --argjson t "$1" '{tribunal: $t}' > "${REPO}/.claude/settings.json"
}

_transcript() { printf '%s' "${BATS_TEST_TMPDIR}/transcript-$1.jsonl"; }

_edit() { # <session> <relative path> — create the file and record the edit
	mkdir -p "$(dirname "${REPO}/$2")"
	printf 'x\n' >> "${REPO}/$2"
	jq -cn --arg p "${REPO}/$2" \
		'{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "toolu_1", name: "Edit", input: {file_path: $p}}]}}' \
		>> "$(_transcript "$1")"
}

_edits() { # <session> <count> — that many ordinary files
	local i=1
	while [[ $i -le $2 ]]; do
		_edit "$1" "src/f${i}.txt"
		i=$((i + 1))
	done
}

_stop() { # <session> [transcript override]
	local tp="${2-$(_transcript "$1")}"
	[[ -n "${2-}" || -f "$tp" ]] || printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$tp"
	local input
	input=$(jq -cn --arg cwd "$REPO" --arg tp "$tp" --arg sid "$1" \
		'{cwd: $cwd, transcript_path: $tp, session_id: $sid, hook_event_name: "Stop"}')
	run bash -c "printf '%s' '$input' | '$HOOK'"
}

_state() { cat "${ONLOOKER_DIR}/tribunal/${PROJECT_KEY}/nudge-${1:-$SID}.json"; }

_message() { printf '%s' "$output" | jq -r '.systemMessage'; }

_only_system_message() {
	[[ -z "$output" ]] && return 0
	printf '%s' "$output" | jq -e 'type == "object" and keys == ["systemMessage"]' >/dev/null
}

@test "fewer than min_files ordinary files stays quiet" {
	_edits "$SID" 7
	_stop "$SID"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["below_threshold"]' >/dev/null
}

@test "min_files files nudges, names the count, and prints only systemMessage" {
	_edits "$SID" 8
	_stop "$SID"
	[ "$status" -eq 0 ] || return 1
	_only_system_message || return 1
	[[ "$(_message)" == "tribunal: this session changed 8 files."* ]] || return 1
	_state | jq -e '.files == 8 and .sensitive == []' >/dev/null
}

@test "edits that were then committed still count" {
	_edits "$SID" 8
	git -C "$REPO" add -A && git -C "$REPO" commit -qm work
	_stop "$SID"
	[[ "$(_message)" == *"changed 8 files"* ]]
}

@test "a workflow file alone nudges as sensitive, in any case; a lockfile does not" {
	_edit "$SID" "pnpm-lock.yaml"
	_stop "$SID"
	[ -z "$output" ] || return 1
	_edit "$SID" ".GitHub/Workflows/CI.yml"
	_stop "$SID"
	[[ "$(_message)" == *"1 sensitive (.GitHub/Workflows/CI.yml)"* ]]
}

@test "a second Stop with no change is quiet; growth speaks again" {
	_edit "$SID" "db/migrations/001.sql"
	_stop "$SID"
	[ -n "$output" ] || return 1
	_stop "$SID"
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["unchanged"]' >/dev/null || return 1
	_edit "$SID" "db/migrations/002.sql"
	_stop "$SID"
	[[ "$(_message)" == *"2 sensitive"* ]]
}

@test "a repeated skip is not recorded twice, and a nudge keeps skips_reported" {
	_edits "$SID" 2
	_stop "$SID"
	_stop "$SID"
	_state | jq -e '.skips_reported == ["below_threshold"]' >/dev/null || return 1
	_edits "$SID" 8
	_stop "$SID"
	[ -n "$output" ] || return 1
	# _edits reuses src/f1..fN, so the second call brings the total to 8, not 10.
	_state | jq -e '.skips_reported == ["below_threshold"] and .files == 8' >/dev/null
}

@test "/tribunal in this session silences it, as a Skill call or typed" {
	_edits "$SID" 8
	jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "t", name: "Skill", input: {skill: "tribunal:tribunal"}}]}}' >> "$(_transcript "$SID")"
	_stop "$SID"
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["tribunal_ran"]' >/dev/null || return 1

	_edits "typed" 8
	jq -cn '{type: "user", message: {role: "user", content: "<command-name>/tribunal</command-name>"}}' >> "$(_transcript typed)"
	_stop "typed"
	[ -z "$output" ]
}

@test "disabled: quiet, and nothing written or emitted" {
	_settings '{"nudge": {"enabled": false}}'
	_edits "$SID" 8
	_stop "$SID"
	[ -z "$output" ] || return 1
	[ ! -e "${ONLOOKER_DIR}/tribunal/${PROJECT_KEY}/nudge-${SID}.json" ] || return 1
	! grep -q 'tribunal.nudge' "$ONLOOKER_EVENTS_LOG" 2>/dev/null
}

@test "with the paid gate on, the nudge stays quiet" {
	_settings '{"stop_hook": {"enabled": true, "skip_if_no_file_changes": true}}'
	# The gate itself is a different hook; this runs only the nudge.
	_edits "$SID" 8
	_stop "$SID"
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["gate_enabled"]' >/dev/null
}

@test "a project sensitive_globs replaces the defaults" {
	_settings '{"nudge": {"sensitive_globs": ["plugins/*/scripts/hooks/*.sh"]}}'
	_edit "$SID" ".github/workflows/ci.yml"
	_stop "$SID"
	[ -z "$output" ] || return 1
	_edit "$SID" "plugins/x/scripts/hooks/h.sh"
	_stop "$SID"
	[[ "$(_message)" == *"(plugins/x/scripts/hooks/h.sh)"* ]]
}

@test "min_files 0 turns the size trigger off; a bad min_files reads as 8" {
	_settings '{"nudge": {"min_files": 0}}'
	_edits "$SID" 30
	_stop "$SID"
	[ -z "$output" ] || return 1
	_settings '{"nudge": {"min_files": "lots"}}'
	_edits "other" 8
	_stop "other"
	[[ "$(_message)" == *"changed 8 files"* ]]
}

@test "an empty session id writes no state file" {
	_edits "" 8
	_stop "" "$(_transcript "")"
	[ -n "$output" ] || return 1
	[ -z "$(find "${ONLOOKER_DIR}/tribunal" -name 'nudge-*' 2>/dev/null)" ]
}

@test "another session's dirty files never count" {
	_edits "author" 8
	_edit "$SID" "src/mine.txt"
	_stop "$SID"
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["below_threshold"]' >/dev/null
}

@test "no transcript is a skip, recorded" {
	_stop "$SID" "${BATS_TEST_TMPDIR}/missing.jsonl"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["no_transcript"]' >/dev/null
}

@test "no model call, ever" {
	_edits "$SID" 8
	_edit "$SID" "auth/login.ts"
	_stop "$SID"
	[ -n "$output" ] || return 1
	[ ! -e "$CLAUDE_MARKER" ]
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/tribunal-stop-nudge.bats`
Expected: FAIL, because the hook does not exist.

- [ ] **Step 3: Implement the hook**

`plugins/tribunal/scripts/hooks/tribunal-stop-nudge.sh`:

```bash
#!/usr/bin/env bash
# Tribunal Stop-time nudge.
#
# Triggered by Stop. Suggests /tribunal in one line to the USER when this
# session's edits are large or touch sensitive paths. Makes no model call.
# Spec: docs/superpowers/specs/2026-11-15-tribunal-nudge-design.md
#
# Hook contract:
#   - Always exits 0. Never blocks Stop.
#   - Stdout is empty or exactly {"systemMessage": "..."}. systemMessage is
#     shown to the user; hookSpecificOutput.additionalContext would instead
#     make Claude take another turn, which this deliberately does not do.
#   - Counts files THIS session's transcript shows it editing inside the
#     worktree, committed or not. Not the dirty tree: sessions here usually end
#     in a commit, and another session's work must never count.
#   - Speaks again only on growth: a new sensitive path, or twice the files.
#   - tribunal.nudge.skipped is emitted once per session per reason, tracked in
#     the state file, so a Stop that repeats a known skip starts no node.
#     `disabled` is never emitted: opting out must not cost every Stop.
#   - No *_NESTED guard: it runs no claude. The gate's nested judge runs with
#     disableAllHooks and never reaches this hook.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "tribunal-stop-nudge"

# shellcheck source=../lib/substrate-resolve.sh
source "${PLUGIN_ROOT}/scripts/lib/substrate-resolve.sh"
_ECOSYSTEM_ROOT=$(onlooker_resolve_substrate "$PLUGIN_ROOT")
if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/onlooker-schema.sh"
fi

# shellcheck source=../lib/tribunal-config.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-config.sh"
# shellcheck source=../lib/onlooker-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
# shellcheck source=../lib/tribunal-events.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-events.sh"
# shellcheck source=../lib/tribunal-verdict.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-verdict.sh"
# shellcheck source=../lib/tribunal-session-files.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-session-files.sh"
# shellcheck source=../lib/tribunal-nudge.sh
source "${PLUGIN_ROOT}/scripts/lib/tribunal-nudge.sh"

INPUT=$(cat)
hook_health_context "$INPUT"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""

tribunal_config_load "$CWD"
[[ "$(tribunal_config_get '.tribunal.nudge.enabled')" == "true" ]] || hook_health_exit 0

REPO_ROOT=$(onlooker_project_repo_root "$CWD")
onlooker_project_resolve "$CWD"
PROJECT_KEY="${ONLOOKER_PROJECT_KEY:-}"
WORKTREE_ROOT=$(onlooker_worktree_root "$CWD")
[[ -z "$WORKTREE_ROOT" ]] && WORKTREE_ROOT="$REPO_ROOT"

# Sanitized as the gate does it. No id, no state file: two id-less sessions
# must never share one.
STATE_FILE=""
SAFE_SID=$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9-' '_')
if [[ -n "$SESSION_ID" ]]; then
	if [[ -n "$PROJECT_KEY" ]]; then
		STATE_FILE="$(tribunal_project_dir "$PROJECT_KEY")/nudge-${SAFE_SID}.json"
	else
		STATE_FILE="$(tribunal_storage_root)/_unkeyed/nudge-${SAFE_SID}.json"
	fi
fi
STATE=$(tribunal_nudge_state_read "$STATE_FILE")

# _skip <reason> — record and emit a reason once per session, then exit.
_skip() {
	local reason="$1"
	if printf '%s' "$STATE" | jq -e --arg r "$reason" '(.skips_reported // []) | index($r) != null' >/dev/null 2>&1; then
		hook_health_exit 0
	fi
	tribunal_nudge_state_write "$STATE_FILE" \
		"$(printf '%s' "$STATE" | jq -c --arg r "$reason" '.skips_reported = ((.skips_reported // []) + [$r])')"
	tribunal_emit_event "tribunal.nudge.skipped" \
		"$(jq -cn --arg r "$reason" '{reason: $r}')" >/dev/null 2>&1 || true
	hook_health_exit 0
}

tribunal_config_stop_hook_enabled && _skip "gate_enabled"
[[ -z "$PROJECT_KEY" || -z "$REPO_ROOT" ]] && _skip "no_project_context"
[[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]] && _skip "no_transcript"

SCAN=$(tribunal_nudge_scan "$TRANSCRIPT_PATH")
printf '%s\n' "$SCAN" | grep -qx 'T' && _skip "tribunal_ran"

# A glob list that is absent or not an array falls back to what config.json
# ships, read from the file rather than restated here.
_globs() {
	local key="$1" v
	v=$(tribunal_config_get_json ".tribunal.nudge.${key}")
	printf '%s' "$v" | jq -e 'type == "array"' >/dev/null 2>&1 \
		|| v=$(jq -c ".tribunal.nudge.${key} // []" "${PLUGIN_ROOT}/config.json" 2>/dev/null)
	printf '%s' "$v" | jq -r '.[]? | strings'
}
SENSITIVE_GLOBS=()
while IFS= read -r g; do [[ -n "$g" ]] && SENSITIVE_GLOBS+=("$g"); done < <(_globs sensitive_globs)
IGNORE_GLOBS=()
while IFS= read -r g; do [[ -n "$g" ]] && IGNORE_GLOBS+=("$g"); done < <(_globs ignore_globs)

COUNT=0
SENSITIVE=()
while IFS= read -r f; do
	[[ -n "$f" ]] || continue
	if [[ ${#IGNORE_GLOBS[@]} -gt 0 ]] && tribunal_nudge_matches_any "$f" "${IGNORE_GLOBS[@]}"; then
		continue
	fi
	COUNT=$((COUNT + 1))
	if [[ ${#SENSITIVE_GLOBS[@]} -gt 0 ]] && tribunal_nudge_matches_any "$f" "${SENSITIVE_GLOBS[@]}"; then
		SENSITIVE+=("$f")
	fi
done < <(printf '%s\n' "$SCAN" | awk -F'\t' '$1 == "E" { print $2 }' | tribunal_paths_in_worktree "$WORKTREE_ROOT")

SENSITIVE_JSON='[]'
[[ ${#SENSITIVE[@]} -gt 0 ]] && SENSITIVE_JSON=$(printf '%s\n' "${SENSITIVE[@]}" | jq -R . | jq -cs .)

MIN_FILES=$(tribunal_config_get_int '.tribunal.nudge.min_files' 8)
DECISION=$(tribunal_nudge_decide "$COUNT" "$SENSITIVE_JSON" "$MIN_FILES" "$STATE")
ACTION=$(printf '%s' "$DECISION" | jq -r '.action')

if [[ "$ACTION" != "nudge" ]]; then
	_skip "$(printf '%s' "$DECISION" | jq -r '.reason')"
fi

TRIGGER=$(printf '%s' "$DECISION" | jq -r '.trigger')
tribunal_nudge_state_write "$STATE_FILE" \
	"$(printf '%s' "$STATE" | jq -c --argjson n "$COUNT" --argjson s "$SENSITIVE_JSON" '.files = $n | .sensitive = $s')"
jq -cn --arg m "$(tribunal_nudge_message "$COUNT" "$SENSITIVE_JSON")" '{systemMessage: $m}'
tribunal_emit_event "tribunal.nudge.shown" \
	"$(jq -cn --arg t "$TRIGGER" --argjson n "$COUNT" --argjson s "$SENSITIVE_JSON" \
		'{trigger: $t, session_files: $n, sensitive_files: $s[0:20]}')" >/dev/null 2>&1 || true
hook_health_exit 0
```

Then run `chmod 755 plugins/tribunal/scripts/hooks/tribunal-stop-nudge.sh`. Memory: rewriting a hook drops its exec bit, and `bash <path>` hides that. The tests run `'$HOOK'` directly, so a missing bit fails them.

`hooks.json`: add a second entry in the existing `Stop[0].hooks` array, after the gate's:

```json
          {
            "type": "command",
            "command": "\"$CLAUDE_PLUGIN_ROOT\"/scripts/hooks/tribunal-stop-nudge.sh"
          }
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `scripts/test/run-bats.sh test/bats/tribunal-stop-nudge.bats test/bats/hook-health.bats`
Expected: PASS. `hook-health.bats` checks that `hook_health_register` is called and that there is no bare `exit`.

The emissions inside the hook are rejected under `ONLOOKER_VALIDATE=1` until Task 7. They are `|| true` and silenced, so these tests are unaffected, but the emission report records rejections. Don't run `npm run test:bus` until Task 7.

- [ ] **Step 5: Mutation checks**

- Remove `committed or not` behavior by piping through `tribunal_dirty_files` instead, and confirm "edits that were then committed still count" fails.
- Make `_skip` always emit and write, skipping the dedupe, and confirm "a repeated skip is not recorded twice" fails.

Revert both.

- [ ] **Step 6: Commit** via `/git-workflow:commit`: `feat(tribunal): suggest /tribunal at Stop when a session's edits warrant it`.

---

### Task 7: Bump schema, assert events, record bus coverage, write the README, measure latency

Start this only after Task 1's release is published.

**Files:**
- Modify: `package.json`, `package-lock.json`
- Modify: `test/bats/tribunal-stop-nudge.bats` (event assertions)
- Modify: `test/bus-coverage.json` (`expected`, alphabetical after `tribunal.judge.start`)
- Modify: `plugins/tribunal/README.md`

- [ ] **Step 1: Bump the dependency**

Run: `npm install @onlooker-community/schema@^<version from Task 1>`. Confirm with `node -e "console.log(require('@onlooker-community/schema/package.json').version)"`.

- [ ] **Step 2: Add the event assertions** (append to `tribunal-stop-nudge.bats`)

```bash
_events() { # <type>
	grep "\"event_type\":\"$1\"" "$ONLOOKER_EVENTS_LOG" 2>/dev/null
}

@test "a nudge emits tribunal.nudge.shown with its trigger, count and files" {
	_edit "$SID" "auth/login.ts"
	_stop "$SID"
	_events tribunal.nudge.shown | tail -n 1 \
		| jq -e '.payload == {trigger: "sensitive", session_files: 1, sensitive_files: ["auth/login.ts"]}' >/dev/null
}

@test "a skip reason is emitted once per session" {
	_edits "$SID" 2
	_stop "$SID"
	_stop "$SID"
	[ "$(_events tribunal.nudge.skipped | grep -c below_threshold)" -eq 1 ]
}

@test "disabled emits nothing at all" {
	_settings '{"nudge": {"enabled": false}}'
	_stop "$SID"
	[ -z "$(_events tribunal.nudge.)" ]
}
```

Add `tribunal.nudge.shown` and `tribunal.nudge.skipped` to `test/bus-coverage.json` `expected`.

- [ ] **Step 3: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/tribunal-stop-nudge.bats`
Expected: PASS. Then run `npm run test:ci`. Expected: PASS, including `test:bus`.

- [ ] **Step 4: README**

Add a `## Nudge` section to `plugins/tribunal/README.md`, after the Stop gate section. It covers:

- what it does
- that it makes no model call and is on by default
- the two triggers and the frequency rule
- every config key with its default
- that an override of `sensitive_globs` **replaces** the list, with the `.claude/settings.json` example from the spec's Config section, and that `onlooker config set tribunal.nudge.min_files 5 --scope project` (onlooker CLI 2.14.0) writes the same file
- the known limitations: Bash-made edits aren't counted, and the count is of files, not lines

- [ ] **Step 5: Latency acceptance (manual, macOS)**

```bash
S=/private/tmp/claude-501/nudge-latency && mkdir -p "$S" && cd "$S" && git init -q && git commit -q --allow-empty -m seed
python3 - "$S/t.jsonl" "$S" <<'PY'
import json, sys
out, root = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    i = 0
    while f.tell() < 5 * 1024 * 1024:
        f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "x" * 400},
            {"type": "tool_use", "id": f"t{i}", "name": "Edit", "input": {"file_path": f"{root}/f{i % 40}.txt"}}]}}) + "\n")
        i += 1
PY
E=/Users/meaganwaller/src/github.com/onlooker-community/ecosystem
for i in 1 2 3; do
  jq -cn --arg cwd "$S" --arg tp "$S/t.jsonl" --arg sid "lat$i" '{cwd:$cwd,transcript_path:$tp,session_id:$sid,hook_event_name:"Stop"}' \
    | CLAUDE_PLUGIN_ROOT="$E/plugins/tribunal" ONLOOKER_ECOSYSTEM_ROOT="$E" "$E/plugins/tribunal/scripts/hooks/tribunal-stop-nudge.sh" >/dev/null
done
tail -n 3 "${ONLOOKER_DIR:-$HOME/.onlooker}/logs/hook-health.jsonl" | jq -c 'select(.hook == "tribunal-stop-nudge") | {duration_ms, status}'
```

Expected: each `duration_ms` is under 300. If it isn't, stop and report the numbers before the PR. The spec makes this the condition for shipping on by default. Read the exact log path from `hook_health_log_path` in `plugins/tribunal/scripts/lib/hook-health.sh` if the one above is empty.

- [ ] **Step 6: Commit and PR**

Run `/git-workflow:commit` for the schema bump, the tests and bus coverage: `test(tribunal): assert the nudge's events once schema registers them`. Then commit the README: `docs(tribunal): document the nudge`. Then run `/git-workflow:pr`. The PR body links the schema PR and reports the latency numbers from Step 5. The squash title is `feat(tribunal): …`, which releases only tribunal.
