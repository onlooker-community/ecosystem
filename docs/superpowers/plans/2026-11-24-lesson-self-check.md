# Lesson Self-Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a flag-gated second model call that rejects an unattended
version-independence justification when it defends a broader principle than
its claim, or when the claim rests on tool behavior a release could change.
A rejected candidate stays pending and never reaches the jury.

**Architecture:** The self-check runs inside `librarian_lesson_auto_confirm_one`,
between the justify call and `librarian_lesson_confirm`. A failure is recorded
on the proposal as `.auto_self_check`, with a fingerprint of both prompts and
the model, so later scans skip it without paying again. A new event,
`librarian.lesson.self_checked`, and an optional `self_check_failed` count on
`librarian.autojury.complete` are registered in `@onlooker-community/schema`
first.

**Tech Stack:** bash (macOS bash 3.2 compatible), jq, bats, `claude -p`.
TypeScript, vitest and JSON Schema in the schema repo.

**Spec:** `docs/superpowers/specs/2026-11-24-lesson-self-check-design.md`.
Linear: ONL-311. Bead: ecosystem-1z07vm.3.
Branch: `meagan/onl-311-an-unattended-justification-can-defend-a-more` (already
created from origin/main).

## Global Constraints

- The flag `librarian.lesson_auto.self_check.enabled` defaults to `false` in
  `plugins/librarian/config.json`. Only the literal `true` enables it. Nothing
  in this plan turns it on in `.claude/settings.json`.
- A self-check failure is never a decline. It writes no row to
  `declined.jsonl`, whatever `on_refusal` is set to.
- Every `claude -p` passes `--settings '{"disableAllHooks":true}'` on the line
  that builds its arguments (`test/bats/nested-claude-runs-no-hooks.bats`).
- No EXIT trap in any function the classify worker calls (ONL-118).
- Bash 3.2: no `declare -A`, no `${var,,}`, no `mapfile`, no globstar.
- American English in code, comments, commits and docs.
- Every commit goes through `/git-workflow:commit`. Never use a bare
  `git commit`.
- Run bats through `scripts/test/run-bats.sh <file>`. It sets
  `ONLOOKER_VALIDATE=1`, which bare `bats` does not. `npm run test:bats -- <file>`
  runs the whole suite.
- Use `--append-notes` on beads, never `--notes`.
- The new event's payload carries only whether a reason was given. The reason
  text stays on the proposal, never on the bus.

---

### Task 1: Register the event in `@onlooker-community/schema`

Work in `~/src/github.com/onlooker-community/schema`. Its local `main` was at
3.10.0 while ecosystem already depends on `^3.11.0`, so pull first.

**Files:**
- Modify: `schemas/event.v1.json` (event_type enum, after `"librarian.lesson.asserted",` near line 180)
- Modify: `schemas/payload/plugins-memory.json` (new payload after `librarian.lesson.asserted`; new optional property on `librarian.autojury.complete`)
- Modify: `src/event-types.ts` (after `LIBRARIAN_LESSON_ASSERTED`, line 137)
- Modify: `src/event-roles.ts` (after `"librarian.lesson.asserted": "output",`, line 218)
- Modify: `src/types.ts` (new interface after `LibrarianLessonAssertedPayload`; field on `LibrarianAutojuryCompletePayload`; map entry after line 1839)
- Test: `src/validate.test.ts`

**Interfaces:**
- Produces: event type `librarian.lesson.self_checked`, with payload
  `{lesson_id: string, outcome: "passed"|"failed"|"unavailable", reason_given?: boolean}`.
  Produces the optional `self_check_failed: integer >= 0` on
  `librarian.autojury.complete`. Both are published in the next minor release
  (expected 3.12.0).

- [ ] **Step 1: Sync and branch**

```bash
cd ~/src/github.com/onlooker-community/schema
git switch main && git pull --ff-only
git switch -c meagan/onl-311-self-checked-event
npm ci
```

- [ ] **Step 2: Write the failing tests**

Add `LIBRARIAN_LESSON_SELF_CHECKED` and `LIBRARIAN_AUTOJURY_COMPLETE` to the
import list from `./event-types` at the top of `src/validate.test.ts`, keeping
it alphabetical. Then append:

```ts
// The unattended stage's check of its own justification, before the jury
// (ONL-311). The reason stays on the proposal; only whether one was given
// rides here.
describe("librarian.lesson.self_checked", () => {
	beforeEach(() => {
		_resetSequence();
	});

	function selfChecked(payload: unknown) {
		return createEvent({
			runtime: "claude-code",
			plugin: "librarian",
			machine_id: MACHINE_ID,
			session_id: "session-self-check-1",
			event_type: LIBRARIAN_LESSON_SELF_CHECKED,
			payload: payload as never,
		});
	}

	it("validates each outcome", () => {
		for (const outcome of ["passed", "failed", "unavailable"] as const) {
			expect(
				validate(selfChecked({ lesson_id: "01M6FJ2S6P2M9EAAEB2VD8SWMG", outcome }))
					.valid,
			).toBe(true);
		}
	});

	it("accepts reason_given on a failure", () => {
		expect(
			validate(
				selfChecked({
					lesson_id: "01M6FJ2S6P2M9EAAEB2VD8SWMG",
					outcome: "failed",
					reason_given: true,
				}),
			).valid,
		).toBe(true);
	});

	it("rejects an unknown outcome", () => {
		expect(
			validate(selfChecked({ lesson_id: "x", outcome: "refused" })).valid,
		).toBe(false);
	});

	it("rejects the reason text itself", () => {
		expect(
			validate(
				selfChecked({ lesson_id: "x", outcome: "failed", reason: "leaks" }),
			).valid,
		).toBe(false);
	});
});

describe("librarian.autojury.complete self_check_failed", () => {
	beforeEach(() => {
		_resetSequence();
	});

	const base = {
		asserted: 1,
		refused: 0,
		unavailable: 0,
		juried: 1,
		deferred_by_cap: 0,
		duration_ms: 40,
	};

	function complete(payload: unknown) {
		return createEvent({
			runtime: "claude-code",
			plugin: "librarian",
			machine_id: MACHINE_ID,
			session_id: "session-self-check-1",
			event_type: LIBRARIAN_AUTOJURY_COMPLETE,
			payload: payload as never,
		});
	}

	it("still validates without it, as older emitters send", () => {
		expect(validate(complete(base)).valid).toBe(true);
	});

	it("validates with it", () => {
		expect(validate(complete({ ...base, self_check_failed: 2 })).valid).toBe(
			true,
		);
	});

	it("rejects a negative count", () => {
		expect(validate(complete({ ...base, self_check_failed: -1 })).valid).toBe(
			false,
		);
	});
});
```

If `MACHINE_ID`, `_resetSequence`, `createEvent` or `validate` are named
differently in this file, use the names the `tribunal.nudge.shown` block
(added in a563038) uses.

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `npx vitest run src/validate.test.ts -t "self_check"`
Expected: FAIL. `LIBRARIAN_LESSON_SELF_CHECKED` is not exported, or the event
type is not in the enum.

- [ ] **Step 4: Register the type and the payload**

`src/event-types.ts`, after line 137:

```ts
export const LIBRARIAN_LESSON_SELF_CHECKED =
	"librarian.lesson.self_checked" as const;
```

`src/event-roles.ts`, after `"librarian.lesson.asserted": "output",`:

```ts
	"librarian.lesson.self_checked": "output",
```

`schemas/event.v1.json`, after `"librarian.lesson.asserted",`:

```json
				"librarian.lesson.self_checked",
```

`schemas/payload/plugins-memory.json`, a new key after the
`librarian.lesson.asserted` object:

```json
		"librarian.lesson.self_checked": {
			"type": "object",
			"additionalProperties": false,
			"required": ["lesson_id", "outcome"],
			"properties": {
				"lesson_id": { "type": "string" },
				"outcome": {
					"type": "string",
					"enum": ["passed", "failed", "unavailable"],
					"description": "The unattended stage's check of its own version-independence justification, before the jury. passed confirmed the candidate; failed left it pending, with the reason on the proposal and no decline; unavailable wrote nothing (no model response, or one that was neither PASS nor FAIL). A candidate held by an earlier failure under the same prompts and model is not asked again and emits nothing."
				},
				"reason_given": {
					"type": "boolean",
					"description": "On a failure, whether the model said why. The reason itself stays on the proposal."
				}
			}
		},
```

In the same file, inside `librarian.autojury.complete`'s `properties`, after
`deferred_by_cap`. Do **not** add it to `required`:

```json
				"self_check_failed": {
					"type": "integer",
					"minimum": 0,
					"description": "Candidates whose justification failed the self-check on this scan. A candidate held by an earlier failure is not counted again. Absent from emitters older than this field."
				},
```

`src/types.ts`, after `LibrarianLessonAssertedPayload`:

```ts
/**
 * The unattended stage checking its own version-independence justification
 * before the jury (ONL-311). A failure leaves the lesson pending and is never
 * a decline. The reason stays on the proposal; only whether one was given
 * rides here.
 */
export interface LibrarianLessonSelfCheckedPayload {
	lesson_id: string;
	outcome: "passed" | "failed" | "unavailable";
	reason_given?: boolean;
}
```

In `LibrarianAutojuryCompletePayload`, after `deferred_by_cap: number;`:

```ts
	/** Absent from emitters older than ONL-311. */
	self_check_failed?: number;
```

In the payload map, after `"librarian.lesson.asserted": LibrarianLessonAssertedPayload;`:

```ts
	"librarian.lesson.self_checked": LibrarianLessonSelfCheckedPayload;
```

- [ ] **Step 5: Run the full schema suite**

Run: `npm run build && npm test && npm run lint`
Expected: all pass. If a test enumerates every event type against the roles
map or the generated types, it passes because steps 4's four registrations
are all present.

- [ ] **Step 6: Commit, push, open the PR**

`/git-workflow:commit` with message:

```
feat(events): give the librarian self-check an event type :mag_right:

The unattended stage is gaining a second model call that checks its own
version-independence justification before the jury (ONL-311). self_checked
records the outcome. autojury.complete gains an optional count of fresh
failures, optional so older librarian releases still validate.

Refs ONL-311
```

Then `/git-workflow:pr`. **Stop here for Meagan:** the PR merge, the
release-please PR merge, and the npm publish are hers. Task 3 can't start until
the new version is on npm (`npm view @onlooker-community/schema version`).
Tasks 2 and 4's non-event parts can go ahead in ecosystem meanwhile.

---

### Task 2: The self-check call, its prompt, fingerprint and flag

Back in `~/src/github.com/onlooker-community/ecosystem`, on the ONL-311 branch.
This task adds only functions that nothing calls yet, plus the config default.
It emits no events.

**Files:**
- Modify: `plugins/librarian/config.json` (`librarian.lesson_auto`)
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-auto.sh` (new functions after `librarian_lesson_auto_justify_fingerprint`, line ~112; refactor of `librarian_lesson_auto_justify`, lines 35–78)
- Create: `test/bats/librarian-lesson-self-check.bats`

**Interfaces:**
- Produces (all in `librarian-lesson-auto.sh`):
  - `_librarian_lesson_auto_ask <prompt_file> [model]`: prints the raw model
    response, or nothing. Shared by justify and self-check.
  - `_librarian_lesson_auto_self_check_preamble`: prints the instructions.
  - `librarian_lesson_auto_self_check_prompt <candidate_json> <justification>`:
    prints the full prompt. Prints nothing if either argument is empty.
  - `librarian_lesson_auto_self_check <candidate_json> <justification> [model]`:
    prints the response collapsed to one trimmed line.
  - `librarian_lesson_auto_self_check_fingerprint [model]`: prints a hash.
  - `_librarian_lesson_auto_self_check_enabled`: returns 0 only when the flag
    is the literal `true`.

- [ ] **Step 1: Write the test file with its setup and the failing unit tests**

Create `test/bats/librarian-lesson-self-check.bats`:

```bash
#!/usr/bin/env bats
#
# The unattended stage's self-check (ONL-311).
#
# Five of the six lessons a person vetoed after jury approval carried a
# justification that defended a broader principle than the claim, and the jury
# scored the principle. The self-check is a second call, after the justify
# call and before the confirm, that compares the two. A failure leaves the
# candidate pending and is never a decline, so its artifact survives.

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

	for lib in librarian-config onlooker-project-key librarian-ulid \
		librarian-storage librarian-emit librarian-lesson-storage \
		librarian-lesson-validate librarian-author-key librarian-lesson-review \
		librarian-lesson-rubric librarian-lesson-judge librarian-lesson-promote \
		librarian-lesson-transform librarian-lesson-auto librarian-cli; do
		# shellcheck disable=SC1091
		source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh"
	done

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-self-check.git
	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"

	EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$EVENTS_LOG")"
	: >"$EVENTS_LOG"

	# One line per call, by kind, so a test counts what a scan paid for.
	CALLS="${BATS_TEST_TMPDIR}/claude-calls"
	: >"$CALLS"
	export CALLS
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
if [[ "$prompt" == *"You are checking a justification"* ]]; then
  printf 'self_check\n' >> "$CALLS"
  [[ -n "${SELF_CHECK_LOG:-}" ]] && printf '%s' "$prompt" > "$SELF_CHECK_LOG"
  if [[ "$prompt" == *"self-check-fail"* ]]; then
    printf '%s' 'FAIL: The justification argues for batching in general, not for this claim.'
  elif [[ "$prompt" == *"self-check-bare"* ]]; then
    printf '%s' 'FAIL'
  elif [[ "$prompt" == *"self-check-garbage"* ]]; then
    printf '%s' 'This looks fine to me.'
  elif [[ "$prompt" == *"self-check-empty"* ]]; then
    printf '%s' ''
  else
    printf '%s' 'PASS'
  fi
  exit 0
fi
printf 'justify\n' >> "$CALLS"
printf '%s' 'The failure is a property of the exec boundary, not of any release.'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	_settings '{"enabled": true, "max_juries_per_scan": 0, "self_check": {"enabled": true}}'
}

# Usage: _settings <lesson_auto_json> [transform_model]
_settings() {
	mkdir -p "${PROJECT_REPO}/.claude"
	jq -cn --argjson a "$1" --arg m "${2:-}" \
		'{librarian: ({lesson_auto: $a}
		  + (if $m == "" then {} else {lesson_transform: {model: $m}} end))}' \
		> "${PROJECT_REPO}/.claude/settings.json"
	librarian_config_load "$PROJECT_REPO"
}

_candidate() {
	jq -cn --arg claim "$1" \
		'{claim: $claim, rationale: "r",
		  evidence: {artifact_ids: ["01KZ45MKAM734ZS7JK24D2DK0R"], session_ids: ["s1"],
		             project_key: "6a7678979e31", observed_at: "2026-08-03T15:59:48Z",
		             resolution: "Pin vitest to 3.x."},
		  applies_to: {stack: ["vite", "jq"], scope: {kind: "unscoped"}, file_patterns: [], task_kinds: []}}'
}

# Usage: _seed_parked <claim> [artifact_id]
_seed_parked() {
	librarian_lesson_write_proposal "$PROJECT_KEY" "$(_candidate "$1")" \
		"${2:-01M3B87J7046SJE5BECNMP670K}"
}

_calls() { grep -c "^${1}$" "$CALLS" || true; }
_proposal() { printf '%s' "${LESSONS_DIR}/proposals/$1.json"; }
_events() { grep "\"event_type\":\"$1\"" "$EVENTS_LOG" 2>/dev/null || true; }
_count() { _events "$1" | grep -c . || true; }

# --- the prompt -------------------------------------------------------------

@test "the self-check prompt carries the claim, the stack and the justification" {
	run librarian_lesson_auto_self_check_prompt "$(_candidate "the claim text")" "the justification text"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"You are checking a justification"* ]] || return 1
	[[ "$output" == *"claim: the claim text"* ]] || return 1
	[[ "$output" == *"stack: vite, jq"* ]] || return 1
	[[ "$output" == *"justification: the justification text"* ]]
}

@test "the self-check prompt asks both questions and fixes the answer form" {
	run _librarian_lesson_auto_self_check_preamble
	[[ "$output" == *"more general principle"* ]] || return 1
	[[ "$output" == *"a release of that tool could change"* ]] || return 1
	[[ "$output" == *"PASS"* ]] || return 1
	[[ "$output" == *"FAIL: "* ]]
}

@test "the self-check prompt builder refuses missing arguments" {
	run librarian_lesson_auto_self_check_prompt "" "j"
	[ -z "$output" ] || return 1
	run librarian_lesson_auto_self_check_prompt "$(_candidate c)" ""
	[ -z "$output" ]
}

@test "the self-check dispatches exactly the prompt the builder returns" {
	export SELF_CHECK_LOG="${BATS_TEST_TMPDIR}/sc-prompt.txt"
	candidate=$(_candidate "c")
	librarian_lesson_auto_self_check "$candidate" "j" >/dev/null
	diff <(librarian_lesson_auto_self_check_prompt "$candidate" "j") "$SELF_CHECK_LOG"
}

@test "the self-check returns one trimmed line" {
	run librarian_lesson_auto_self_check "$(_candidate "c self-check-fail")" "j"
	[ "$output" = "FAIL: The justification argues for batching in general, not for this claim." ]
}

# --- the fingerprint --------------------------------------------------------

@test "the self-check fingerprint changes with either prompt and with the model" {
	a=$(librarian_lesson_auto_self_check_fingerprint "m1")
	b=$(librarian_lesson_auto_self_check_fingerprint "m2")
	[ -n "$a" ] && [ "$a" != "$b" ] || return 1
	_librarian_lesson_auto_self_check_preamble() { printf 'a different check\n'; }
	c=$(librarian_lesson_auto_self_check_fingerprint "m1")
	[ "$a" != "$c" ] || return 1
	_librarian_lesson_auto_justify_preamble() { printf 'a different justify\n'; }
	d=$(librarian_lesson_auto_self_check_fingerprint "m1")
	[ "$c" != "$d" ]
}

# --- the flag ---------------------------------------------------------------

@test "the self-check is off by default" {
	_settings '{"enabled": true}'
	run _librarian_lesson_auto_self_check_enabled
	[ "$status" -ne 0 ]
}

@test "only the literal true turns the self-check on" {
	_settings '{"enabled": true, "self_check": {"enabled": "yes"}}'
	run _librarian_lesson_auto_self_check_enabled
	[ "$status" -ne 0 ] || return 1
	_settings '{"enabled": true, "self_check": {"enabled": true}}'
	run _librarian_lesson_auto_self_check_enabled
	[ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-self-check.bats`
Expected: FAIL, with `librarian_lesson_auto_self_check_prompt: command not found`
or similar.

- [ ] **Step 3: Add the config default**

In `plugins/librarian/config.json`, add `"self_check": { "enabled": false }`
as the last key of `librarian.lesson_auto`, after `"judge_model"`:

```json
      "judge_model": "claude-haiku-4-5-20251001",
      "self_check": {
        "enabled": false
      }
```

Match the file's existing indentation.

- [ ] **Step 4: Extract the shared call and add the self-check functions**

In `librarian-lesson-auto.sh`, replace the body of `librarian_lesson_auto_justify`
from `local args=(-p --max-turns 1 ...` through the closing `fi` of the timeout
branches (lines 58–71) with one call to the shared helper. The function becomes:

```bash
librarian_lesson_auto_justify() {
	local candidate="$1"
	local model="${2:-}"
	[[ -z "$candidate" ]] && return 0
	command -v claude >/dev/null 2>&1 || return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-auto.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-auto.$$"
	# No EXIT trap for this file. Called directly rather than through $(...), a
	# trap here replaces the caller's and the `trap - EXIT` after it clears it
	# outright, and the classify worker's EXIT trap is what releases its queue
	# lock (ONL-118). Every path out removes the file itself; a killed call
	# leaks one small file under $TMPDIR, which costs nothing next to a lock
	# that blocks its queue for good.

	{
		_librarian_lesson_auto_justify_preamble
		printf '%s\n' '<candidate>'
		printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nrationale: \(.rationale)\nresolution: \(.evidence.resolution)\nstack: \(.applies_to.stack | join(", "))"' 2>/dev/null
		printf '%s\n' '</candidate>'
	} > "$prompt_file" || { rm -f "$prompt_file"; return 0; }

	local response
	response=$(_librarian_lesson_auto_ask "$prompt_file" "$model")
	rm -f "$prompt_file"

	# Collapse to one line and trim: a justification is a single sentence, and
	# a stray newline would corrupt the envelope's shape.
	printf '%s' "$response" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# One single-turn `claude -p` on a prompt file, under the transform's
# timeout. Prints the raw response, or nothing on any failure: an empty answer
# is infrastructure, and each caller decides what that means. Shared by the
# justify call and the self-check so the two can't drift apart in how they
# reach the model.
#
# Usage: _librarian_lesson_auto_ask <prompt_file> [model]
_librarian_lesson_auto_ask() {
	local prompt_file="$1" model="${2:-}"
	local args=(-p --max-turns 1 --settings '{"disableAllHooks":true}')
	[[ -n "$model" ]] && args+=(--model "$model")

	local timeout_seconds response=""
	timeout_seconds=$(librarian_config_get '.librarian.lesson_transform.timeout_seconds' 2>/dev/null)
	case "$timeout_seconds" in ''|null) timeout_seconds=120 ;; esac

	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$timeout_seconds" claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$timeout_seconds" claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi
	printf '%s' "$response"
}
```

Then, after `librarian_lesson_auto_justify_fingerprint`, add:

```bash
# The self-check (ONL-311). A second call that reads the justification the
# justify call just wrote, beside the claim it is meant to defend.
#
# The justify prompt already says not to restate the claim as a more general
# principle. Five of the six lessons a person vetoed after jury approval did
# it anyway, inside the call told not to, and both judges then scored the
# principle. So the comparison is a separate question to a fresh call. The
# second check comes from 01M6FJ2S: both judges passed a claim that rested on
# two Claude Code behaviors, because neither asked what had to stay true.
#
# Only the claim and stack are shown, not the rationale: the question is
# whether the justification defends this claim, and the rationale's
# project-specific detail is what invites the general principle.
_librarian_lesson_auto_self_check_preamble() {
	printf '%s\n' 'You are checking a justification written for a lesson, before a jury sees it.'
	printf '%s\n' 'Output PASS, or FAIL: followed by ONE sentence saying which check failed and why.'
	printf '%s\n\n' 'No markdown, no preamble.'
	printf '%s\n' 'The justification is meant to show that the claim, as written, holds'
	printf '%s\n\n' 'regardless of version. Check two things.'
	printf '%s\n' '1. Does the justification argue for the claim as written, or for a more'
	printf '%s\n' 'general principle the claim is one instance of? A justification that'
	printf '%s\n' 'would defend a different claim built on the same principle just as well'
	printf '%s\n\n' 'is arguing for the principle. FAIL it.'
	printf '%s\n' '2. Work out which behaviors of external tools the claim relies on: the'
	printf '%s\n' 'tools in its stack, and any tool the claim itself names. If any of those'
	printf '%s\n' 'behaviors is something a release of that tool could change, the claim'
	printf '%s\n\n' 'is not version-independent. FAIL it.'
	printf '%s\n' 'PASS only when both checks pass.'
}

# The whole self-check prompt for one candidate and its justification.
# Extracted so the measurement harness sends the text production sends.
#
# Usage: librarian_lesson_auto_self_check_prompt <candidate_json> <justification>
librarian_lesson_auto_self_check_prompt() {
	local candidate="${1:-}" justification="${2:-}"
	[[ -z "$candidate" || -z "$justification" ]] && return 0
	_librarian_lesson_auto_self_check_preamble
	printf '%s\n' '<lesson>'
	printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nstack: \(.applies_to.stack | join(", "))"' 2>/dev/null
	printf 'justification: %s\n' "$justification"
	printf '%s\n' '</lesson>'
}

# Ask the self-check. Prints the answer on one trimmed line, or nothing.
#
# Usage: librarian_lesson_auto_self_check <candidate_json> <justification> [model]
librarian_lesson_auto_self_check() {
	local candidate="$1" justification="$2" model="${3:-}"
	[[ -z "$candidate" || -z "$justification" ]] && return 0
	command -v claude >/dev/null 2>&1 || return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-self-check.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-self-check.$$"
	# No EXIT trap, for the reason librarian_lesson_auto_justify gives.
	librarian_lesson_auto_self_check_prompt "$candidate" "$justification" > "$prompt_file" \
		|| { rm -f "$prompt_file"; return 0; }

	local response
	response=$(_librarian_lesson_auto_ask "$prompt_file" "$model")
	rm -f "$prompt_file"
	printf '%s' "$response" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Identify the question a self-check failure answered. Both preambles are in
# it: the failure judged a justification the justify prompt wrote, so a
# rewritten justify prompt is owed a fresh attempt as much as a rewritten
# check is. Same mechanism as librarian_lesson_auto_justify_fingerprint.
#
# Usage: librarian_lesson_auto_self_check_fingerprint [model]
librarian_lesson_auto_self_check_fingerprint() {
	librarian_body_hash "$(_librarian_lesson_auto_self_check_preamble)
$(_librarian_lesson_auto_justify_preamble)
model: ${1:-}"
}

# Off unless the project sets the literal true. It ships off so ONL-198's
# review measures the pipeline as it ran; whether to turn it on is that
# review's decision.
_librarian_lesson_auto_self_check_enabled() {
	[[ "$(librarian_config_get '.librarian.lesson_auto.self_check.enabled' 2>/dev/null)" == "true" ]]
}
```

- [ ] **Step 5: Run the new tests and the existing auto tests**

Run:
```bash
scripts/test/run-bats.sh test/bats/librarian-lesson-self-check.bats
scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats
scripts/test/run-bats.sh test/bats/librarian-lesson-auto-hold.bats
scripts/test/run-bats.sh test/bats/nested-claude-runs-no-hooks.bats
```
Expected: all pass. The justify refactor must not change any existing result.
If `nested-claude-runs-no-hooks.bats` fails, the `--settings` literal has to sit
on the line that builds `args`, as written above.

- [ ] **Step 6: Commit**

`/git-workflow:commit` the three files with message:

```
feat(librarian): add a self-check for unattended justifications :mag_right:

The justify prompt already forbids defending a broader principle than the
claim, and five of six vetoed lessons did it anyway. This adds a separate
call that compares the two, and asks what tool behavior the claim relies on.
Nothing calls it yet, and its flag defaults to off.

Refs ONL-311
```

---

### Task 3: Wire the self-check into the stage, with its event

**Precondition:** Task 1's schema release is on npm.

**Files:**
- Modify: `package.json`, `package-lock.json` (bump `@onlooker-community/schema`)
- Modify: `test/bus-coverage.json` (`expected`)
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-auto.sh` (`librarian_lesson_auto_confirm_one` and its outcome comment, lines 210–326; `librarian_lesson_auto_stage`, lines 505–558; two new private helpers)
- Test: `test/bats/librarian-lesson-self-check.bats`

**Interfaces:**
- Consumes: everything Task 2 produces.
- Produces: new `librarian_lesson_auto_confirm_one` outputs
  `skipped:self_check_failed` and `skipped:self_check_held`. The proposal field
  `.auto_self_check = {reason, justification, failed_at, fingerprint}`, which
  Task 4 reads. The event `librarian.lesson.self_checked`.
  `librarian.autojury.complete.payload.self_check_failed`.

- [ ] **Step 1: Bump the schema and register the event for coverage**

```bash
npm install @onlooker-community/schema@^<released version>
```

In `test/bus-coverage.json`, add `"librarian.lesson.self_checked"` to `expected`
right after `"librarian.lesson.asserted"`.

- [ ] **Step 2: Write the failing integration tests**

Append to `test/bats/librarian-lesson-self-check.bats`:

```bash
# --- in the stage -----------------------------------------------------------

@test "with the flag off, nothing calls the self-check" {
	_settings '{"enabled": true, "max_juries_per_scan": 0}'
	id=$(_seed_parked "c self-check-fail")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "confirmed:${id}" ] || return 1
	[ "$(_calls self_check)" = "0" ] || return 1
	[ "$(_count librarian.lesson.self_checked)" = "0" ] || return 1
	jq -e 'has("auto_self_check") | not' "$(_proposal "$id")" >/dev/null
}

@test "a passing self-check confirms the candidate and says so" {
	id=$(_seed_parked "c")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "confirmed:${id}" ] || return 1
	[ "$(_calls justify)" = "1" ] && [ "$(_calls self_check)" = "1" ] || return 1
	jq -e '.status == "confirmed" and .asserted_by == "model"' "$(_proposal "$id")" >/dev/null || return 1
	_events librarian.lesson.self_checked \
		| jq -e --arg id "$id" '.payload == {lesson_id: $id, outcome: "passed"}' >/dev/null
}

@test "a failing self-check leaves the candidate pending, with reason and justification" {
	id=$(_seed_parked "c self-check-fail")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:self_check_failed" ] || return 1
	jq -e '.status == "pending"
	   and .auto_self_check.reason == "The justification argues for batching in general, not for this claim."
	   and .auto_self_check.justification == "The failure is a property of the exec boundary, not of any release."
	   and (.auto_self_check.failed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
	   and (.auto_self_check.fingerprint | type == "string")' \
		"$(_proposal "$id")" >/dev/null
}

@test "a self-check failure is never a decline, even under the decline policy" {
	_settings '{"enabled": true, "max_juries_per_scan": 0, "on_refusal": "decline", "self_check": {"enabled": true}}'
	id=$(_seed_parked "c self-check-fail")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:self_check_failed" ] || return 1
	[ ! -s "${LESSONS_DIR}/declined.jsonl" ] || return 1
	jq -e '.status == "pending"' "$(_proposal "$id")" >/dev/null
}

@test "a failure emits failed with reason_given, and never the reason" {
	id=$(_seed_parked "c self-check-fail")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	_events librarian.lesson.self_checked \
		| jq -e --arg id "$id" '.payload == {lesson_id: $id, outcome: "failed", reason_given: true}' >/dev/null || return 1
	! grep -q "batching in general" "$EVENTS_LOG"
}

@test "a bare FAIL is recorded with no reason" {
	id=$(_seed_parked "c self-check-bare")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:self_check_failed" ] || return 1
	jq -e '.auto_self_check.reason == null' "$(_proposal "$id")" >/dev/null || return 1
	_events librarian.lesson.self_checked | jq -e '.payload.reason_given == false' >/dev/null
}

@test "a held failure is not paid for again, and is reported as held" {
	id=$(_seed_parked "c self-check-fail")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:self_check_held" ] || return 1
	[ "$(_calls justify)" = "1" ] && [ "$(_calls self_check)" = "1" ] || return 1
	[ "$(_count librarian.lesson.self_checked)" = "1" ]
}

@test "a model change asks a held candidate again, once" {
	id=$(_seed_parked "c self-check-fail")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	_settings '{"enabled": true, "max_juries_per_scan": 0, "self_check": {"enabled": true}}' "claude-other-model"
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:self_check_failed" ] || return 1
	[ "$(_calls self_check)" = "2" ] || return 1
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:self_check_held" ]
}

@test "a later pass clears the recorded failure" {
	id=$(_seed_parked "c")
	jq --arg f "stale" '.auto_self_check = {reason: "old", justification: "j", failed_at: "2026-11-01T00:00:00Z", fingerprint: $f}' \
		"$(_proposal "$id")" > "${BATS_TEST_TMPDIR}/p.json" && mv "${BATS_TEST_TMPDIR}/p.json" "$(_proposal "$id")"
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "confirmed:${id}" ] || return 1
	jq -e 'has("auto_self_check") | not' "$(_proposal "$id")" >/dev/null
}

@test "with the flag off, a stored failure is ignored" {
	id=$(_seed_parked "c self-check-fail")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id" >/dev/null
	_settings '{"enabled": true, "max_juries_per_scan": 0}'
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "confirmed:${id}" ]
}

@test "an answer that is neither PASS nor FAIL is unavailable and writes nothing" {
	id=$(_seed_parked "c self-check-garbage")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ] || return 1
	jq -e '.status == "pending" and (has("auto_self_check") | not)' "$(_proposal "$id")" >/dev/null || return 1
	_events librarian.lesson.self_checked | jq -e '.payload.outcome == "unavailable"' >/dev/null
}

@test "an empty self-check answer is unavailable and writes nothing" {
	id=$(_seed_parked "c self-check-empty")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ] || return 1
	jq -e '.status == "pending" and (has("auto_self_check") | not)' "$(_proposal "$id")" >/dev/null
}

@test "a versioned candidate is never self-checked" {
	candidate=$(_candidate "c self-check-fail" | jq -c '.applies_to.scope = {kind: "versioned", versions: {vite: "<6"}}')
	id=$(librarian_lesson_write_proposal "$PROJECT_KEY" "$candidate" "01M3B87J7046SJE5BECNMP670K")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "confirmed:${id}" ] || return 1
	[ "$(_calls self_check)" = "0" ]
}

@test "the stage counts a fresh failure once, and never as a refusal" {
	_seed_parked "c self-check-fail" >/dev/null
	librarian_lesson_auto_stage "$PROJECT_KEY"
	librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$(_count librarian.autojury.complete)" = "2" ] || return 1
	_events librarian.autojury.complete | jq -s -e \
		'[.[].payload.self_check_failed] == [1, 0] and [.[].payload.refused] == [0, 0]' >/dev/null
}
```

- [ ] **Step 3: Run them and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-self-check.bats`
Expected: the Task 2 tests pass, and the new ones fail. The self-check is never
called, so failing candidates come back `confirmed:<id>`.

- [ ] **Step 4: Add the record and emit helpers**

In `librarian-lesson-auto.sh`, after `_librarian_lesson_auto_emit_asserted`:

```bash
# Record a self-check failure on the proposal (ONL-311). The justification
# is kept beside the reason because the reason is an objection to it, and a
# person reading `lessons show` needs to see what was objected to.
#
# Deliberately NOT a decline, under any on_refusal policy: a refusal is the
# model's judgment of the claim, a failure is a judgment of one sentence it
# wrote about the claim, and a later prompt or model may write a better one.
# Best effort, like the refusal record.
#
# Usage: _librarian_lesson_auto_record_self_check <path> <response> <justification> <fingerprint>
_librarian_lesson_auto_record_self_check() {
	local path="$1" response="$2" justification="$3" fingerprint="$4"
	local reason now updated
	reason=$(printf '%s' "$response" | sed -E 's/^FAIL[[:space:]]*:?[[:space:]]*//')
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(jq --arg r "$reason" --arg j "$justification" --arg at "$now" --arg f "$fingerprint" \
		'.auto_self_check = {reason: (if $r == "" then null else $r end),
		                     justification: $j, failed_at: $at, fingerprint: $f}' \
		"$path" 2>/dev/null) || return 0
	librarian_lesson_write_atomic "$path" "$updated" >/dev/null 2>&1 || true
}

# Usage: _librarian_lesson_auto_emit_self_checked <lesson_id> <outcome> [response]
_librarian_lesson_auto_emit_self_checked() {
	local id="$1" outcome="$2" response="${3:-}" payload
	if [[ "$outcome" == "failed" ]]; then
		local reason
		reason=$(printf '%s' "$response" | sed -E 's/^FAIL[[:space:]]*:?[[:space:]]*//')
		payload=$(jq -cn --arg id "$id" --argjson g "$([[ -n "$reason" ]] && echo true || echo false)" \
			'{lesson_id: $id, outcome: "failed", reason_given: $g}')
	else
		payload=$(jq -cn --arg id "$id" --arg o "$outcome" '{lesson_id: $id, outcome: $o}')
	fi
	librarian_lesson_emit "librarian.lesson.self_checked" "$payload"
}
```

- [ ] **Step 5: Call it from `librarian_lesson_auto_confirm_one`**

Add two lines to the outcome comment above the function, after the
`skipped:no_justification` entry:

```bash
#   skipped:self_check_failed  the justification failed the self-check; left
#                              pending, recorded as .auto_self_check, and
#                              never declined (ONL-311)
#   skipped:self_check_held    already failed under these prompts and model
```

Change the "Every other outcome emits librarian.lesson.asserted." line to:

```bash
# Every other outcome emits librarian.lesson.asserted, except the two
# self-check outcomes, whose account is librarian.lesson.self_checked.
```

In the body, directly after the closing `fi` of the refusal-fingerprint block
(the one that ends with `printf 'skipped:refused'` ... `return 0` / `fi`) and
before `justification=$(librarian_lesson_auto_justify ...)`:

```bash
	# Off, a stored failure is ignored: the candidate goes through as it did
	# before the self-check existed.
	local self_check_fp=""
	if _librarian_lesson_auto_self_check_enabled; then
		self_check_fp=$(librarian_lesson_auto_self_check_fingerprint "$model")
		if [[ -n "$self_check_fp" ]] && jq -e --arg f "$self_check_fp" \
			'.auto_self_check.fingerprint == $f' "$path" >/dev/null 2>&1; then
			printf 'skipped:self_check_held'
			return 0
		fi
	fi
```

Then, between the closing `fi` of the `REFUSE*` block and the final
`librarian_lesson_confirm "$key" "$lesson_id" "$visibility" "$justification" model`:

```bash
	if [[ -n "$self_check_fp" ]]; then
		local verdict
		verdict=$(librarian_lesson_auto_self_check "$candidate" "$justification" "$model")
		case "$verdict" in
			PASS | PASS.)
				_librarian_lesson_auto_emit_self_checked "$lesson_id" passed
				if jq -e 'has("auto_self_check")' "$path" >/dev/null 2>&1; then
					local cleared
					cleared=$(jq 'del(.auto_self_check)' "$path" 2>/dev/null) \
						&& librarian_lesson_write_atomic "$path" "$cleared" >/dev/null 2>&1
				fi
				;;
			FAIL*)
				_librarian_lesson_auto_record_self_check "$path" "$verdict" "$justification" "$self_check_fp"
				_librarian_lesson_auto_emit_self_checked "$lesson_id" failed "$verdict"
				printf 'skipped:self_check_failed'
				return 0
				;;
			*)
				# Empty or malformed is infrastructure: passing it would send a
				# candidate to the jury on noise, failing it would hold one on
				# noise. Nothing is written, so the next scan asks again.
				_librarian_lesson_auto_emit_self_checked "$lesson_id" unavailable
				printf 'unavailable'
				return 0
				;;
		esac
	fi
```

- [ ] **Step 6: Count fresh failures in the stage**

In `librarian_lesson_auto_stage`, change
`local id result asserted=0 refused=0 unavailable=0` to:

```bash
	local id result asserted=0 refused=0 unavailable=0 self_check_failed=0
```

Add a case arm after the `refused` one:

```bash
			skipped:self_check_failed) self_check_failed=$((self_check_failed + 1)) ;;
```

In the closing `librarian_lesson_emit "librarian.autojury.complete"` call, add
`--argjson self_check_failed "$self_check_failed"` to the jq arguments and
`self_check_failed: $self_check_failed` to the object, after `deferred_by_cap`:

```bash
	librarian_lesson_emit "librarian.autojury.complete" "$(jq -cn \
		--argjson asserted "$asserted" --argjson refused "$refused" \
		--argjson unavailable "$unavailable" --argjson juried "$juried" \
		--argjson deferred "$deferred" --argjson duration_ms "$duration_ms" \
		--argjson self_check_failed "$self_check_failed" \
		'{asserted: $asserted, refused: $refused, unavailable: $unavailable,
		  juried: $juried, deferred_by_cap: $deferred,
		  self_check_failed: $self_check_failed, duration_ms: $duration_ms}')"
```

`skipped:self_check_held` deliberately has no arm, so a held failure is counted
once.

- [ ] **Step 7: Run the tests**

```bash
scripts/test/run-bats.sh test/bats/librarian-lesson-self-check.bats
scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats
scripts/test/run-bats.sh test/bats/librarian-lesson-auto-hold.bats
scripts/test/run-bats.sh test/bats/librarian-lesson-auto-decline.bats
scripts/test/run-bats.sh test/bats/librarian-lesson-pipeline-events.bats
scripts/test/run-bats.sh test/bats/hook-health.bats
npm run test:bus
```

Expected: all pass. If an existing test pins the exact `autojury.complete`
payload with `==`, add `self_check_failed: 0` to its expected object. That is
a correct update, because the field is now always emitted.

- [ ] **Step 8: Commit**

`/git-workflow:commit` with message:

```
feat(librarian): hold a justification that fails its own check :hand:

With the flag on, a justification the self-check rejects never reaches the
jury, and the candidate stays pending, where a jury rejection would have
burned it. The failure is fingerprinted, so the next scan doesn't pay for
it again. The flag stays off until ONL-198's review decides.

Refs ONL-311
```

---

### Task 4: Show the failure in the review walk

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-cli.sh` (`librarian_cli_lessons_show`, after the `auto_refusal` block near line 470)
- Modify: `plugins/librarian/skills/librarian/SKILL.md` (step 3, line 91)
- Test: `test/bats/librarian-lesson-self-check.bats`

**Interfaces:**
- Consumes: `.auto_self_check` from Task 3. This test seeds the field by hand,
  so the task doesn't depend on Task 3's code or the schema release.

- [ ] **Step 1: Write the failing test**

Append:

```bash
# --- the review walk --------------------------------------------------------

@test "lessons show prints the self-check's reason and the justification it rejected" {
	id=$(_seed_parked "c")
	jq '.auto_self_check = {reason: "It defends batching in general.", justification: "Batching always helps.",
	                        failed_at: "2026-11-24T00:00:00Z", fingerprint: "f"}' \
		"$(_proposal "$id")" > "${BATS_TEST_TMPDIR}/p.json" && mv "${BATS_TEST_TMPDIR}/p.json" "$(_proposal "$id")"
	run librarian_cli lessons show "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"self-check:  It defends batching in general."* ]] || return 1
	[[ "$output" == *"justification: Batching always helps."* ]]
}

@test "lessons show says when the self-check gave no reason" {
	id=$(_seed_parked "c")
	jq '.auto_self_check = {reason: null, justification: "j", failed_at: "2026-11-24T00:00:00Z", fingerprint: "f"}' \
		"$(_proposal "$id")" > "${BATS_TEST_TMPDIR}/p.json" && mv "${BATS_TEST_TMPDIR}/p.json" "$(_proposal "$id")"
	run librarian_cli lessons show "$id" "$PROJECT_REPO"
	[[ "$output" == *"self-check:  (no reason given)"* ]]
}

@test "lessons show prints no self-check line when nothing failed" {
	id=$(_seed_parked "c")
	run librarian_cli lessons show "$id" "$PROJECT_REPO"
	[[ "$output" != *"self-check:"* ]]
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-self-check.bats -f "lessons show"`
Expected: the first two FAIL, and the third passes.

- [ ] **Step 3: Add the line to `show`**

In `librarian_cli_lessons_show`'s jq program, right after the
`(if .auto_refusal then ... else empty end),` element:

```jq
		# The unattended path wrote a justification and its own self-check
		# rejected it (ONL-311). The justification is printed because the
		# reason objects to it.
		(if .auto_self_check then
			"self-check:  \(.auto_self_check.reason // "(no reason given)")\n             justification: \(.auto_self_check.justification)"
		 else empty end),
```

- [ ] **Step 4: Tell the walk what the line means**

In `SKILL.md` step 3, after the sentence ending "...they may disagree with it.
`(no reason given)` means the model refused without saying why.", insert:

```
If `show` prints a `self-check:` line, the unattended path did write a justification, and its own self-check rejected it before any jury saw it: the reason and the rejected justification follow. Show both. The candidate is waiting for the user because of that check, and confirming it with a justification of their own is the usual way forward.
```

Keep it on the same line as the rest of step 3. Step 3 is a single paragraph
line.

- [ ] **Step 5: Run the tests, including the skill-block checks**

```bash
scripts/test/run-bats.sh test/bats/librarian-lesson-self-check.bats
scripts/test/run-bats.sh test/bats/skill-blocks-run-under-bash.bats
scripts/test/run-bats.sh test/bats/skill-blocks-source-what-they-call.bats
```
Expected: all pass.

- [ ] **Step 6: Commit**

`/git-workflow:commit` with message:

```
feat(librarian): show a failed self-check in the review walk :eyes:

A person reviewing a pending candidate needs to know why the unattended
path held it, and to see the justification that was rejected, since the
reason refers to it.

Refs ONL-311
```

---

### Task 5: Measure recall, false fails and cost

This spends real money. **Ask Meagan before each run.** The recall and control
groups are 11 calls, about $0.70. The held-early group is 39 calls, about
$2.50, and needs a separate go-ahead. The run reads the real lesson store and
writes nothing to it.

**Files:**
- Create: `plugins/librarian/docs/measurements/2026-11-24-self-check/run.sh`
- Create: `plugins/librarian/docs/measurements/2026-11-24-self-check/ids.tsv`
- Create: `plugins/librarian/docs/measurements/2026-11-24-self-check/results.jsonl` (output)
- Create: `plugins/librarian/docs/measurements/2026-11-24-self-check/README.md`

**Interfaces:**
- Consumes: `librarian_lesson_auto_self_check_prompt` (Task 2), so the run
  sends production's text.

- [ ] **Step 1: Write the id list**

Generate `ids.tsv` (`<group>\t<lesson_id>`) from the store with this, and commit
its output, not the command's results at some later date:

```bash
bash <<'EOF'
cd ~/.onlooker/librarian
vetoed=$(grep '"librarian.lesson.vetoed"' ~/.onlooker/logs/onlooker-events.jsonl | jq -r .payload.lesson_id | sort -u)
for f in */lessons/proposals/*.json; do
	jq -r 'select(.candidate.applies_to.scope.kind == "version_independent")
	  | [(.asserted_by // "human"), .status, .id] | @tsv' "$f"
done | while IFS=$'\t' read -r by status id; do
	if printf '%s\n' "$vetoed" | grep -qx "$id"; then g=vetoed
	elif [[ "$by" == model && "$status" == approved ]]; then g=kept
	elif [[ "$by" == human && "$status" == approved ]]; then g=human
	elif [[ "$by" == model && "$status" == rejected ]]; then g=rejected
	else continue; fi
	printf '%s\t%s\n' "$g" "$id"
done | sort
EOF
```

Expected counts, from 2026-11-24: vetoed 6, kept 1, human 4, rejected 39.

- [ ] **Step 2: Write `run.sh`**

```bash
#!/usr/bin/env bash
# ONL-311: the self-check's recall, false fails and cost, on real lessons.
#
# Sends each lesson's claim, stack and stored version_independent
# justification through the production prompt builder, one real `claude -p`
# each, with --output-format json for the cost. Reads the lesson store;
# writes nothing to it.
#
# Usage: run.sh <group>...   (vetoed kept human rejected)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO/plugins/librarian"
for lib in librarian-config librarian-storage librarian-lesson-storage librarian-lesson-auto; do
	# shellcheck disable=SC1090
	source "$CLAUDE_PLUGIN_ROOT/scripts/lib/${lib}.sh"
done
librarian_config_load "$REPO"
MODEL=$(librarian_config_get '.librarian.lesson_transform.model')

[[ $# -gt 0 ]] || { echo "usage: run.sh <group>..."; exit 1; }
OUT="$HERE/results.jsonl"
STORE="${ONLOOKER_DIR:-$HOME/.onlooker}/librarian"

for group in "$@"; do
	awk -F'\t' -v g="$group" '$1 == g {print $2}' "$HERE/ids.tsv" | while read -r id; do
		f=$(ls "$STORE"/*/lessons/proposals/"$id".json 2>/dev/null | head -1)
		[[ -n "$f" ]] || { echo "missing $id" >&2; continue; }
		candidate=$(jq -c '.candidate' "$f")
		justification=$(jq -r '.candidate.applies_to.scope.justification' "$f")
		raw=$(librarian_lesson_auto_self_check_prompt "$candidate" "$justification" \
			| claude -p --max-turns 1 --settings '{"disableAllHooks":true}' \
				--model "$MODEL" --output-format json 2>/dev/null)
		jq -cn --arg g "$group" --arg id "$id" --argjson r "${raw:-null}" \
			'{group: $g, id: $id,
			  verdict: ($r.result // "" | gsub("\n"; " ")),
			  cost_usd: ($r.total_cost_usd // null)}' >> "$OUT"
	done
done
```

`chmod +x run.sh`.

- [ ] **Step 3: Run the recall and control groups, after Meagan approves**

```bash
plugins/librarian/docs/measurements/2026-11-24-self-check/run.sh vetoed kept human
```

Then reduce:

```bash
jq -s 'group_by(.group) | map({group: .[0].group, n: length,
  failed: map(select(.verdict | startswith("FAIL"))) | length,
  median_cost: (map(.cost_usd) | sort | .[length/2|floor])})' \
  plugins/librarian/docs/measurements/2026-11-24-self-check/results.jsonl
```

Success: `vetoed` fails at least 5 of 6, and `kept` + `human` fail 0 of 5. If
it misses, revise `_librarian_lesson_auto_self_check_preamble`, rerun Task 2's
and Task 3's tests, clear `results.jsonl`, and run again. Record each attempt
in the README.

- [ ] **Step 4: Optionally run the held-early group, after a separate go-ahead**

```bash
plugins/librarian/docs/measurements/2026-11-24-self-check/run.sh rejected
```

- [ ] **Step 5: Write the README**

Follow the shape of `2026-10-24-unattended-run/README.md`. Sections:
- What was run: model, date, prompt fingerprint
  (`librarian_lesson_auto_self_check_fingerprint "$MODEL"`), and the groups.
- Recall: n failed of 6, with each verdict verbatim.
- False fails: n of 5, each verbatim. Say plainly that 5 is too few to give a
  rate.
- Held early, if run: n of 39 that would never have reached a jury, and the
  judge spend that would have saved, at the 10-24 per-judge cost.
- Cost: median per self-check against the per-judge range of $0.056–0.081 and
  the justify call's $0.063, and the ratio to a two-judge jury.
- What ONL-198's review should take from it.

- [ ] **Step 6: Commit**

`/git-workflow:commit` the four files with message, filling in the measured
numbers:

```
docs(librarian): measure the self-check against the vetoed lessons :bar_chart:

<n>/6 vetoed lessons fail it and <n>/5 approved ones do, at $<x> a call
against $0.056-0.081 a judge. This is the evidence ONL-198's review needs to
decide whether to turn it on.

Refs ONL-311
```

---

### Task 6: Full verification and the PR

- [ ] **Step 1: Run the CI suite**

Run: `npm run test:ci`
Expected: shellcheck, bats, schema and lint all pass. A shellcheck warning on a
new function is fixed, not disabled, unless the existing file disables the same
check for the same reason.

- [ ] **Step 2: Bead notes**

```bash
bd update ecosystem-1z07vm.3 --append-notes "2026-11-24 ONL-311: self-check built behind lesson_auto.self_check.enabled (off). Measurement in plugins/librarian/docs/measurements/2026-11-24-self-check/. Enabling is ONL-198's call."
```

- [ ] **Step 3: Open the PR**

`/git-workflow:pr`. Title: `feat(librarian): check an unattended justification before the jury`.
The body says the flag is off and why (ONL-198), gives the measured numbers,
and links ONL-311.

Only librarian's files and the root `package.json`/lock change in this PR.
Check that the squash title doesn't patch-release unrelated plugins.

- [ ] **Step 4: After merge**

Check ONL-311's state in Linear, because auto-close is unreliable. Close
ecosystem-1z07vm.3 to match it. Add the measurement link to ONL-198 as a
comment, so the review finds it.
