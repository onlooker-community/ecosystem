# Hook-health instrumentation for plugin hooks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every plugin hook record its own execution latency to `hook-health.jsonl`, so the dogfooding waves can evaluate the latency exit criteria they are gated on.

**Architecture:** Extract the timing and record-writing code out of `scripts/lib/validate-path.sh` into a small, self-contained `scripts/lib/hook-health.sh`. Vendor that file into all 16 plugins using the sync + drift-check machinery built for `config-loader.sh`. `validate-path.sh` sources the same lib and keeps its old function names as aliases, so there is one implementation rather than a copy that rots. Each of the 31 plugin hooks gains two lines.

**Tech Stack:** bash 3.2-compatible shell, `jq`, bats for tests.

**Spec:** `docs/superpowers/specs/2026-08-29-hook-health-instrumentation-design.md`
**Tracking:** bead `ecosystem-449.5`

## Global Constraints

- Hooks run under `#!/usr/bin/env bash`, which on macOS is **bash 3.2.57**. No `$EPOCHREALTIME` assumption, no associative arrays, no `${var^^}`.
- Everything is **fail-soft**. A hook must never fail, hang, or change behavior because its instrument failed. Every function returns 0.
- The vendored lib must be **fully self-contained** — it may not source `validate-path.sh` or any other shared file, because plugins ship without one.
- Never resolve a path through a caller-supplied `$PLUGIN_ROOT` inside a lib. Libs locate themselves via `${BASH_SOURCE[0]}`. Hook entry points that compute `PLUGIN_ROOT` locally at the top of their own file may source through it — that is the existing convention.
- Vendored copies must be **byte-identical** to `scripts/lib/hook-health.sh`.
- American English in all comments and docs.
- All bats assertions: any non-final `[[ ]]` needs `|| return 1`. Only the last assertion in a body gates on its own.
- Run `npm run test:ci` before the final commit.

---

### Task 1: The `hook-health.sh` core lib

Creates the canonical lib with the clock cascade and the record writer. Trap chaining is deliberately **not** in this task — it lands in Task 2.

**Files:**
- Create: `scripts/lib/hook-health.sh`
- Test: `test/bats/hook-health.bats`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `hook_health_log_path` → prints the absolute path of the health log.
  - `_hook_health_now_ms` → prints milliseconds since the epoch as an integer string.
  - `hook_health_register <hook-name>` → sets `_HOOK_NAME`, `_HOOK_START_MS`. (Trap added in Task 2.)
  - `hook_health_context <hook-json>` → sets `_HOOK_SESSION_ID`, `_HOOK_EVENT`, `_HOOK_TOOL_NAME`.
  - `hook_health_success` / `hook_health_failure <msg>` → write a record.
  - `_hook_health_write <status> <error>` → internal record writer.

- [ ] **Step 1: Write the failing test**

Create `test/bats/hook-health.bats`:

```bash
#!/usr/bin/env bats

# The vendored hook-health lib: clock, record shape, and fail-soft behavior.
# See docs/superpowers/specs/2026-08-29-hook-health-instrumentation-design.md

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/scripts/lib/hook-health.sh"
	HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
}

@test "the log path derives from ONLOOKER_DIR" {
	[ "$(hook_health_log_path)" = "$HEALTH_LOG" ]
}

@test "the clock returns epoch milliseconds as 13 digits" {
	local ms
	ms=$(_hook_health_now_ms)
	[[ "$ms" =~ ^[0-9]{13}$ ]] || return 1
	# Sanity: within a decade of the date this was written.
	[ "$ms" -gt 1700000000000 ]
}

@test "a success record lands with the hook name and a duration" {
	hook_health_register "unit-test-hook"
	hook_health_success
	[ -f "$HEALTH_LOG" ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.hook == "unit-test-hook"
		and .status == "success"
		and .error == null
		and (.duration_ms | type) == "number"
		and .duration_ms >= 0
	' >/dev/null
}

@test "a failure record carries the status and the error text" {
	hook_health_register "failing-hook"
	hook_health_failure "exit_code=3"
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.status == "failure" and .error == "exit_code=3"
	' >/dev/null
}

@test "context from the hook JSON lands on the record" {
	hook_health_register "ctx-hook"
	hook_health_context '{"session_id":"sess-1","tool_name":"Write","hook_event_name":"PostToolUse"}'
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.session_id == "sess-1"
		and .tool_name == "Write"
		and .hook_event == "PostToolUse"
	' >/dev/null
}

@test "absent context leaves the optional fields null, not empty strings" {
	hook_health_register "bare-hook"
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.session_id == null and .tool_name == null and .hook_event == null
	' >/dev/null
}

@test "registering without writing produces no record" {
	hook_health_register "never-finished"
	[ ! -f "$HEALTH_LOG" ]
}

@test "an unwritable log directory does not fail the caller" {
	export ONLOOKER_HOOK_HEALTH_LOG="/proc/nonexistent/nope/hook-health.jsonl"
	hook_health_register "fail-soft-hook"
	run hook_health_success
	[ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `bats test/bats/hook-health.bats`
Expected: every test fails on `No such file or directory` for `scripts/lib/hook-health.sh`.

- [ ] **Step 3: Write the lib**

Create `scripts/lib/hook-health.sh`:

```bash
#!/usr/bin/env bash
# Hook execution timing for Onlooker hooks — ecosystem substrate and plugins.
#
# This file is VENDORED into every plugin's scripts/lib/. Edit this canonical
# copy and run scripts/sync-shared-libs.sh to propagate it; drift is caught by
# test/bats/shared-lib-vendoring.bats.
#
# It is deliberately self-contained. A plugin publishes rooted at
# plugins/<name> and ships no ecosystem tree, so this file may not source
# validate-path.sh or anything else (ecosystem-ber).
#
# Usage, at the top of a hook:
#   source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
#   hook_health_register "my-plugin-post-tool-use"
#   INPUT=$(cat)
#   hook_health_context "$INPUT"
#
# Fail-soft throughout: every function returns 0. A hook must never break
# because its instrument broke.

# Do not clobber values a caller already set — several plugins set
# _HOOK_SESSION_ID before sourcing, and their *-events.sh libs read it.
_HOOK_NAME="${_HOOK_NAME:-}"
_HOOK_START_MS="${_HOOK_START_MS:-}"
_HOOK_SESSION_ID="${_HOOK_SESSION_ID:-}"
_HOOK_EVENT="${_HOOK_EVENT:-}"
_HOOK_TOOL_NAME="${_HOOK_TOOL_NAME:-}"

hook_health_log_path() {
	printf '%s' "${ONLOOKER_HOOK_HEALTH_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/hook-health.jsonl}"
}

# Milliseconds since the epoch, cheapest source first.
#
# Cost measured on macOS: $EPOCHREALTIME 0.08ms, perl 6.9ms, python3 18.7ms.
# Hooks run under bash 3.2, where EPOCHREALTIME does not exist, so perl is the
# usual winner. The date rung gives second resolution rather than dropping the
# record entirely.
_hook_health_now_ms() {
	local er s us
	if [[ -n "${EPOCHREALTIME:-}" ]]; then
		er="${EPOCHREALTIME/,/.}"   # some locales render the separator as a comma
		s="${er%%.*}"
		us="${er#*.}000"
		printf '%s%s' "$s" "${us:0:3}"
		return 0
	fi
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time() * 1000' 2>/dev/null && return 0
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null && return 0
	fi
	printf '%s000' "$(date +%s 2>/dev/null || printf 0)"
}

# Start timing. Call as early in the hook as possible.
hook_health_register() {
	_HOOK_NAME="${1:-unknown}"
	_HOOK_START_MS=$(_hook_health_now_ms)
	return 0
}

# Fill session/event/tool from the hook's JSON payload. Optional — call it
# after reading stdin. Values already set by the caller win, so a hook that
# assigned _HOOK_SESSION_ID itself keeps its value.
hook_health_context() {
	local input="${1:-}"
	[[ -n "$input" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	[[ -z "$_HOOK_SESSION_ID" ]] && _HOOK_SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
	[[ -z "$_HOOK_TOOL_NAME" ]] && _HOOK_TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
	[[ -z "$_HOOK_EVENT" ]] && _HOOK_EVENT=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)
	return 0
}

hook_health_success() {
	_hook_health_write "success" ""
}

hook_health_failure() {
	_hook_health_write "failure" "${1:-}"
}

# Write one record. The end timestamp comes from jq's `now` inside the call we
# already make, so it costs no extra process.
_hook_health_write() {
	local hook_status="$1"
	local error_msg="$2"

	[[ -n "$_HOOK_NAME" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	local path
	path=$(hook_health_log_path)
	mkdir -p "$(dirname "$path")" 2>/dev/null || return 0

	local start="${_HOOK_START_MS:-0}"
	[[ "$start" =~ ^[0-9]+$ ]] || start=0

	jq -cn \
		--arg hook "$_HOOK_NAME" \
		--arg hook_status "$hook_status" \
		--arg error "$error_msg" \
		--arg session_id "$_HOOK_SESSION_ID" \
		--arg hook_event "$_HOOK_EVENT" \
		--arg tool_name "$_HOOK_TOOL_NAME" \
		--argjson start "$start" \
		'(now * 1000 | floor) as $end
		 | {
			timestamp: (now | todate),
			hook: $hook,
			status: $hook_status,
			duration_ms: (if $start > 0 and $end > $start then $end - $start else 0 end),
			error: (if $error == "" then null else $error end),
			session_id: (if $session_id == "" then null else $session_id end),
			hook_event: (if $hook_event == "" then null else $hook_event end),
			tool_name: (if $tool_name == "" then null else $tool_name end)
		   }' >> "$path" 2>/dev/null || true

	# Reset so a second write in the same shell cannot double-count.
	_HOOK_NAME=""
	_HOOK_START_MS=""
	return 0
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `bats test/bats/hook-health.bats`
Expected: 8 passing.

- [ ] **Step 5: Prove the clock test can fail**

Temporarily change `_hook_health_now_ms`'s last line to `printf '%s' 42`, re-run, and confirm `the clock returns epoch milliseconds as 13 digits` fails. Revert.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/hook-health.sh test/bats/hook-health.bats
git commit -m "feat(hook-health): add a self-contained timing lib :stopwatch:"
```

---

### Task 2: Chain the EXIT trap instead of clobbering it

Six plugin hooks already install an `EXIT` trap — assayer, archivist, echo, and tribunal remove a prompt file, and cartographer's two hooks **release a lock**. Overwriting those would make the instrument the cause of a stranded lock.

Re-installing the prior trap during exit processing does not run it, so the prior command must be captured and executed. `trap -p EXIT` prints `trap -- 'cmd' EXIT` with embedded single quotes escaped, and `eval "VAR=$quoted"` is the idiom that unquotes it correctly.

**Files:**
- Modify: `scripts/lib/hook-health.sh`
- Test: `test/bats/hook-health.bats`

**Interfaces:**
- Consumes: `_hook_health_write` from Task 1.
- Produces: `hook_health_register` now installs a chained EXIT trap; `_hook_health_on_exit <code>` runs the log then the prior handler.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/hook-health.bats`:

```bash
@test "an exiting hook logs success without an explicit call" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'trapped-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "trapped-hook" and .status == "success"' >/dev/null
}

@test "a nonzero exit is recorded as a failure with the exit code" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'crashing-hook'
		exit 7
	"
	[ "$status" -eq 7 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.status == "failure" and .error == "exit_code=7"' >/dev/null
}

# The regression this whole task exists for. Modeled on the real pattern in
# assayer-stop.sh and tribunal-stop-gate.sh.
@test "a pre-existing EXIT trap still runs after registering" {
	local victim="${BATS_TEST_TMPDIR}/prompt-file"
	touch "$victim"
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		trap 'rm -f \"${victim}\"' EXIT
		hook_health_register 'polite-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	# The prior handler ran: the temp file is gone.
	[ ! -f "$victim" ] || return 1
	# And we still got our record.
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "polite-hook"' >/dev/null
}

@test "a pre-existing trap containing single quotes survives chaining" {
	local victim="${BATS_TEST_TMPDIR}/quoted file"
	touch "$victim"
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		trap \"rm -f '${victim}'\" EXIT
		hook_health_register 'quoted-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$victim" ]
}
```

- [ ] **Step 2: Run and verify they fail**

Run: `bats test/bats/hook-health.bats`
Expected: the four new tests fail — no trap is installed, so no record is written and `.hook` is null.

- [ ] **Step 3: Implement trap chaining**

In `scripts/lib/hook-health.sh`, add the state variable next to the others:

```bash
_HOOK_PRIOR_EXIT_CMD="${_HOOK_PRIOR_EXIT_CMD:-}"
```

Replace `hook_health_register` with:

```bash
# Start timing and arm the exit trap.
#
# Any EXIT trap already installed is preserved and run after we log. Six plugin
# hooks depend on this: four remove a prompt file, and cartographer's two
# release a lock, which a clobbered trap would strand.
hook_health_register() {
	_HOOK_NAME="${1:-unknown}"
	_HOOK_START_MS=$(_hook_health_now_ms)

	local prior
	prior=$(trap -p EXIT 2>/dev/null)
	if [[ -n "$prior" ]]; then
		# Format is: trap -- 'cmd' EXIT
		prior="${prior#trap -- }"
		prior="${prior% EXIT}"
		# The assignment unquotes bash's own quoting, including the '\'' form
		# it emits for embedded single quotes.
		eval "_HOOK_PRIOR_EXIT_CMD=$prior" 2>/dev/null || _HOOK_PRIOR_EXIT_CMD=""
	fi

	trap '_hook_health_on_exit $?' EXIT
	return 0
}

# Log first, then hand control back to whatever trap we displaced. Logging
# first keeps the prior handler running even if the write fails, at the cost of
# excluding the hook's own cleanup from the recorded duration.
_hook_health_on_exit() {
	local exit_code="${1:-0}"
	if [[ "$exit_code" -eq 0 ]]; then
		_hook_health_write "success" ""
	else
		_hook_health_write "failure" "exit_code=${exit_code}"
	fi
	trap - EXIT
	if [[ -n "$_HOOK_PRIOR_EXIT_CMD" ]]; then
		local prior_cmd="$_HOOK_PRIOR_EXIT_CMD"
		_HOOK_PRIOR_EXIT_CMD=""
		eval "$prior_cmd" || true
	fi
	return 0
}
```

- [ ] **Step 4: Run and verify they pass**

Run: `bats test/bats/hook-health.bats`
Expected: 12 passing.

- [ ] **Step 5: Prove the chaining test can fail**

Temporarily replace the `eval "$prior_cmd" || true` line with `:`, re-run, and confirm `a pre-existing EXIT trap still runs after registering` fails because the temp file survives. Revert.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/hook-health.sh test/bats/hook-health.bats
git commit -m "feat(hook-health): chain the exit trap so cleanup still runs :chains:"
```

---

### Task 3: Route `validate-path.sh` through the shared lib

One implementation, two consumers. Ecosystem hooks keep calling `hook_register` / `hook_success` / `hook_failure` unchanged.

**Files:**
- Modify: `scripts/lib/validate-path.sh` (replace the hook-health block, roughly lines 55-205)
- Test: `test/bats/validate-path.bats` (existing, must stay green)

**Interfaces:**
- Consumes: everything Task 2 produced.
- Produces: `hook_register`, `hook_success`, `hook_failure`, `hook_set_context` as aliases. `hook_health_summary` stays where it is.

- [ ] **Step 1: Confirm the existing tests pass before touching anything**

Run: `bats test/bats/validate-path.bats`
Expected: all pass. Note the count — it must not drop.

- [ ] **Step 2: Replace the block**

In `scripts/lib/validate-path.sh`, delete the hook-health implementation (the `_HOOK_NAME` / `_HOOK_START_TIME` declarations, `_detect_hook_event`, `hook_set_context`, `hook_register`, `hook_success`, `hook_failure`, `_hook_on_exit`, `_hook_log`) and put this in its place. Keep `hook_health_summary` exactly as it is.

```bash
# ==============================================================================
# Hook health instrumentation
# ==============================================================================
# The implementation lives in hook-health.sh, which is also vendored into every
# plugin so plugin hooks report the same way. Sourced from this file's own
# directory, never from a caller-supplied variable.
# shellcheck source=hook-health.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-health.sh"

# Back-compat aliases. Every ecosystem hook calls these names.
hook_register() { hook_health_register "$@"; }
hook_success()  { hook_health_success "$@"; }
hook_failure()  { hook_health_failure "$@"; }

# hook_set_context also exports the envelope variables onlooker-emit.sh reads.
hook_set_context() {
	hook_health_context "${1:-}"
	[[ -n "${2:-}" ]] && _HOOK_EVENT="$2"
	export ONLOOKER_HOOK_TYPE="${_HOOK_EVENT}"
	export ONLOOKER_TOOL_NAME="${_HOOK_TOOL_NAME}"
	return 0
}
```

- [ ] **Step 3: Run the full bats suite**

Run: `npm run test:bats`
Expected: no failures, and `test/bats/validate-path.bats` reports the same count as Step 1.

`test/bats/validate-path.bats:165` asserts `[ -n "${_HOOK_START_TIME}" ]`. Change that line to `[ -n "${_HOOK_START_MS}" ]` — a rename, not a behavior change. Line 164's `_HOOK_NAME` assertion is unaffected.

That test also calls `hook_register "my-hook" "My Hook" "A description"` with three arguments. The new `hook_health_register` ignores everything past the first, which is fine, and the existing `trap - EXIT` on line 163 still disarms correctly.

- [ ] **Step 4: Verify a real ecosystem hook still records**

```bash
rm -f "$HOME/.onlooker/logs/hook-health.jsonl.probe"
printf '%s' '{"session_id":"probe","cwd":"/tmp","tool_name":"Bash","hook_event_name":"PreToolUse"}' \
  | ONLOOKER_HOOK_HEALTH_LOG=/tmp/probe-health.jsonl scripts/hooks/tool-sequence-tracker.sh
jq -c '{hook, status, duration_ms, hook_event}' /tmp/probe-health.jsonl
```

Expected: one record naming `tool-sequence-tracker` with `hook_event: "PreToolUse"` and a small `duration_ms`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/validate-path.sh test/bats/validate-path.bats
git commit -m "refactor(hook-health): source one timing implementation :recycle:"
```

---

### Task 4: Make librarian restore its trap instead of clearing it

`librarian-session-end.sh` sources both of these libs. Each sets a temp-file EXIT trap and then disarms with a bare `trap - EXIT`, which would also remove the health trap and silently drop librarian's record.

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-classifier.sh:85` and `:104`
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-transform.sh:169` and `:193`
- Test: `test/bats/hook-health.bats`

**Interfaces:**
- Consumes: `hook_health_register` from Task 2.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Append to `test/bats/hook-health.bats`:

This test drives the **real** `librarian_classifier_call`, not a hand-rolled
imitation of its shape, so it fails against the current code and passes only once
the trap is restored properly. `librarian-classifier.sh` sources nothing, so it can
be sourced on its own. It returns early unless `claude` is on `PATH`, so the stub is
required — without it the function never reaches its trap and the test would pass
for the wrong reason.

```bash
# librarian's classifier sets its own EXIT trap around a claude -p call and then
# disarms it with a bare `trap - EXIT`, which takes the health trap with it and
# drops the record with no error. librarian-session-end.sh sources this lib, so
# the path is live.
@test "librarian_classifier_call leaves the health trap armed" {
	local stub_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_bin"
	cat > "${stub_bin}/claude" <<-'STUB'
		#!/usr/bin/env bash
		printf '%s' '{"type":"project","title":"t","body":"b","confidence":0.9}'
	STUB
	chmod +x "${stub_bin}/claude"

	run bash -c "
		export PATH='${stub_bin}:\$PATH'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		source '${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-classifier.sh'
		hook_health_register 'librarian-session-end'
		librarian_classifier_call '{\"summary\":\"s\",\"detail\":\"d\"}' '' 0.2 256 >/dev/null 2>&1
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	[ -f "$HEALTH_LOG" ] || return 1
	grep -q '"hook":"librarian-session-end"' "$HEALTH_LOG"
}
```

- [ ] **Step 2: Run and verify it fails**

Run: `bats test/bats/hook-health.bats -f "librarian_classifier_call"`
Expected: FAIL. `librarian_classifier_call` ends with a bare `trap - EXIT` that
removes the health trap, so no record is ever written and the `[ -f "$HEALTH_LOG" ]`
assertion fails.

If it fails on the `$status` assertion instead, the stub is not being found — fix
that first, because a `claude`-less run returns before reaching the trap and would
prove nothing.

- [ ] **Step 3: Fix `librarian-classifier.sh`**

At line 85, capture the prior trap before setting your own:

```bash
	local _prior_trap
	_prior_trap=$(trap -p EXIT)
	# shellcheck disable=SC2064
	trap "rm -f '$prompt_file'" EXIT
```

At line 104, restore rather than clear:

```bash
	rm -f "$prompt_file"
	eval "${_prior_trap:-trap - EXIT}"
```

- [ ] **Step 4: Apply the identical change to `librarian-lesson-transform.sh`**

Same two edits at lines 169 and 193. Use the same `_prior_trap` local name.

- [ ] **Step 5: Verify librarian's own tests still pass**

Run: `bats test/bats/librarian-classifier.bats test/bats/librarian-lesson-transform.bats`
Expected: no failures. If those files do not exist, run `npm run test:bats` and confirm no librarian test regressed.

- [ ] **Step 6: Commit**

```bash
git add plugins/librarian/scripts/lib/librarian-classifier.sh \
        plugins/librarian/scripts/lib/librarian-lesson-transform.sh \
        test/bats/hook-health.bats
git commit -m "fix(librarian): restore the prior exit trap instead of clearing it :thread:"
```

---

### Task 5: Vendor the lib into all 16 plugins

**Files:**
- Rename: `scripts/sync-config-loader.sh` → `scripts/sync-shared-libs.sh`
- Create: `plugins/<name>/scripts/lib/hook-health.sh` × 16 (generated, do not hand-write)
- Create: `test/bats/shared-lib-vendoring.bats`
- Modify: `package.json` if it references the old script name
- Modify: `CLAUDE.md` (the numbered rule that names `scripts/sync-config-loader.sh`)

**Interfaces:**
- Consumes: `scripts/lib/hook-health.sh` from Task 2.
- Produces: `scripts/sync-shared-libs.sh [--check]`, exit 1 on drift.

- [ ] **Step 1: Write the failing test**

Create `test/bats/shared-lib-vendoring.bats`:

```bash
#!/usr/bin/env bats

# Both shared libs are vendored per plugin rather than shared, because an
# installed plugin is its own tree with no ecosystem checkout above it
# (ecosystem-ber). Vendoring only works if the copies stay identical.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

_plugin_dirs() {
	find "${REPO_ROOT}/plugins" -maxdepth 1 -mindepth 1 -type d | sort
}

@test "the plugin glob matches at least one plugin" {
	local count
	count=$(_plugin_dirs | wc -l | tr -d ' ')
	[ "$count" -gt 0 ]
}

@test "every plugin has a vendored hook-health.sh" {
	local missing=""
	local d
	while IFS= read -r d; do
		[ -f "${d}/scripts/lib/hook-health.sh" ] || missing+="$(basename "$d") "
	done < <(_plugin_dirs)
	[ -z "$missing" ] || { echo "missing in: $missing"; return 1; }
}

@test "every vendored hook-health.sh is byte-identical to the canonical copy" {
	local canonical="${REPO_ROOT}/scripts/lib/hook-health.sh"
	local drifted=""
	local d
	while IFS= read -r d; do
		cmp -s "$canonical" "${d}/scripts/lib/hook-health.sh" \
			|| drifted+="$(basename "$d") "
	done < <(_plugin_dirs)
	[ -z "$drifted" ] || { echo "drifted: $drifted"; return 1; }
}

@test "the sync script reports no drift" {
	run "${REPO_ROOT}/scripts/sync-shared-libs.sh" --check
	[ "$status" -eq 0 ]
}

@test "hook-health works from a plugin tree copied outside the repo" {
	local standalone="${BATS_TEST_TMPDIR}/standalone"
	mkdir -p "$standalone"
	cp -R "${REPO_ROOT}/plugins/lineage/scripts" "${standalone}/scripts"
	run bash -c "
		source '${standalone}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${ONLOOKER_DIR}/logs/hook-health.jsonl'
		hook_health_register 'standalone-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	tail -n 1 "${ONLOOKER_DIR}/logs/hook-health.jsonl" \
		| jq -e '.hook == "standalone-hook"' >/dev/null
}
```

- [ ] **Step 2: Run and verify it fails**

Run: `bats test/bats/shared-lib-vendoring.bats`
Expected: fails — no vendored copies, and `sync-shared-libs.sh` does not exist.

- [ ] **Step 3: Generalize the sync script**

```bash
git mv scripts/sync-config-loader.sh scripts/sync-shared-libs.sh
```

Rewrite it to loop over both libs. Replace the whole file with:

```bash
#!/usr/bin/env bash
# Propagate the shared libs into every plugin's scripts/lib/.
#
# These libs are vendored rather than shared. Each plugin publishes rooted at
# ./plugins/<name>, so an installed plugin is its own tree with no ecosystem
# checkout above it and cannot reach a repo-root path — it would source
# nothing, define no functions, and fail in silence (ecosystem-ber).
# Edit the canonical copy, run this, commit the result.
#
# Drift is caught by test/bats/shared-lib-vendoring.bats and
# test/bats/config-lib-self-locating.bats.
#
# Usage:
#   scripts/sync-shared-libs.sh           # write the copies
#   scripts/sync-shared-libs.sh --check   # report drift, write nothing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_LIBS=(config-loader.sh hook-health.sh)

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

drift=0

for lib in "${SHARED_LIBS[@]}"; do
	canonical="${REPO_ROOT}/scripts/lib/${lib}"
	[[ -f "$canonical" ]] || {
		printf 'missing canonical lib: %s\n' "$canonical" >&2
		exit 1
	}

	while IFS= read -r plugin_dir; do
		dest="${plugin_dir}/scripts/lib/${lib}"
		[[ -d "${plugin_dir}/scripts/lib" ]] || continue
		cmp -s "$canonical" "$dest" 2>/dev/null && continue
		drift=$((drift + 1))
		if [[ "$check_only" -eq 1 ]]; then
			printf 'out of sync: %s\n' "${dest#"${REPO_ROOT}/"}" >&2
		else
			cp "$canonical" "$dest"
			printf 'synced %s\n' "${dest#"${REPO_ROOT}/"}"
		fi
	done < <(find "${REPO_ROOT}/plugins" -maxdepth 1 -mindepth 1 -type d | sort)
done

if [[ "$check_only" -eq 1 ]]; then
	[[ "$drift" -eq 0 ]] || {
		printf '%d copy/copies out of sync — run scripts/sync-shared-libs.sh\n' "$drift" >&2
		exit 1
	}
	printf 'all vendored copies match their canonical libs\n'
	exit 0
fi

printf '%d copy/copies updated\n' "$drift"
```

- [ ] **Step 4: Run the sync and verify the tests pass**

```bash
chmod +x scripts/sync-shared-libs.sh
scripts/sync-shared-libs.sh
bats test/bats/shared-lib-vendoring.bats test/bats/config-lib-self-locating.bats
```

Expected: 16 copies written, all tests pass.

- [ ] **Step 5: Update the references to the old script name**

The old name appears in three kinds of place, and one of them will break the drift check if you miss it.

```bash
grep -rln 'sync-config-loader' . --exclude-dir=node_modules --exclude-dir=.git
```

1. **`scripts/lib/config-loader.sh:9`** — the canonical header says `run scripts/sync-config-loader.sh to propagate it`. This file is itself vendored into all 16 plugins, so editing it means every vendored copy is now stale. Edit the canonical copy, then **re-run `scripts/sync-shared-libs.sh`** to bring the 16 copies back in line. Skip this and `shared-lib-vendoring.bats` fails on 16 drifted `config-loader.sh` files, which reads as a mysterious failure unrelated to what you changed.

2. **`CLAUDE.md:94` and `AGENTS.md:147`** — the same numbered rule 8 in both. `CLAUDE.md` states these are independent files that must be mirrored, so change both identically: name `scripts/sync-shared-libs.sh` and note that `hook-health.sh` is vendored the same way and for the same reason.

3. Any remaining hits are the 15 other vendored `config-loader.sh` copies, which step 1 already fixes via the re-sync.

Verify:

```bash
scripts/sync-shared-libs.sh --check
grep -rn 'sync-config-loader' . --exclude-dir=node_modules --exclude-dir=.git
```

Expected: the check reports no drift, and the grep returns nothing.

- [ ] **Step 6: Commit**

```bash
git add scripts/sync-shared-libs.sh scripts/lib/config-loader.sh \
        plugins/*/scripts/lib/hook-health.sh plugins/*/scripts/lib/config-loader.sh \
        test/bats/shared-lib-vendoring.bats CLAUDE.md AGENTS.md
git commit -m "feat(hook-health): vendor the timing lib into every plugin :package:"
```

---

### Task 6: Wire the 31 plugin hooks

Two lines per hook, no body changes. Work plugin by plugin so a reviewer can follow.

**Files:** all 31 of `plugins/*/scripts/hooks/*.sh` — see the list in Step 2.

**Interfaces:**
- Consumes: the vendored `hook-health.sh` from Task 5.
- Produces: hook-health records naming each plugin hook.

- [ ] **Step 1: Write the failing integration test**

Append to `test/bats/hook-health.bats`:

```bash
# A real plugin hook, driven end to end, must name itself in the health log.
@test "a real plugin hook records its own latency" {
	local plugin_root="${REPO_ROOT}/plugins/lineage"
	export CLAUDE_PLUGIN_ROOT="$plugin_root"
	export ONLOOKER_HOOK_HEALTH_LOG="$HEALTH_LOG"

	local target="${BATS_TEST_TMPDIR}/edited.txt"
	printf 'hello\n' > "$target"

	local input
	input=$(jq -cn --arg f "$target" --arg cwd "$BATS_TEST_TMPDIR" \
		'{session_id:"hh-test", cwd:$cwd, tool_name:"Write",
		  hook_event_name:"PostToolUse",
		  tool_input:{file_path:$f, content:"hello"}}')

	run bash -c "printf '%s' '$input' | '${plugin_root}/scripts/hooks/lineage-post-tool-use.sh'"
	[ "$status" -eq 0 ] || return 1
	[ -f "$HEALTH_LOG" ] || return 1
	grep -q '"hook":"lineage-post-tool-use"' "$HEALTH_LOG"
}
```

- [ ] **Step 2: Run and verify it fails**

Run: `bats test/bats/hook-health.bats -f "real plugin hook"`
Expected: FAIL — the health log is never created.

- [ ] **Step 3: Wire every hook**

For each of the 31 files, insert the source line immediately after the block that establishes `PLUGIN_ROOT` and exports `CLAUDE_PLUGIN_ROOT`, then the register call. Use the hook's own filename without `.sh` as the name.

```bash
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "lineage-post-tool-use"
```

Then, immediately after the line that reads stdin (`INPUT=$(cat)` or equivalent), add:

```bash
hook_health_context "$INPUT"
```

If a hook does not read stdin into a variable, skip the context line — the record still lands, just without session/event/tool fields.

The full list, grouped by plugin:

```
archivist    archivist-extract, archivist-inject
assayer      assayer-stop
bursar       bursar-session-end, bursar-session-start
cartographer cartographer-post-write, cartographer-session-start
compass      compass-bash-gate, compass-pre-tool-use, compass-record-write, compass-session-start
counsel      counsel-session-start
curator      curator-session-start
echo         echo-stop-gate
governor     governor-post-tool-use, governor-pre-tool-use, governor-session-start, governor-stop
historian    historian-prompt-submit, historian-session-end
inspector    inspector-post-write
librarian    librarian-session-end, librarian-session-start
lineage      lineage-post-tool-use
scribe       scribe-capture, scribe-session-start, scribe-stop
tribunal     tribunal-stop-gate
warden       warden-post-tool-use, warden-pre-tool-use, warden-session-start
```

Two hooks need care. `inspector-post-write.sh` derives `PLUGIN_ROOT` from `$0` rather than `BASH_SOURCE`, so place the source line after that assignment, not before. `compass-pre-tool-use.sh` and `compass-bash-gate.sh` end in `exit $?` from `compass_run_gate` — the EXIT trap still fires, so no change is needed there.

- [ ] **Step 4: Verify the integration test passes**

Run: `bats test/bats/hook-health.bats`
Expected: all pass, including `a real plugin hook records its own latency`.

- [ ] **Step 5: Verify every hook was actually wired**

```bash
for f in plugins/*/scripts/hooks/*.sh; do
  grep -q 'hook_health_register' "$f" || echo "NOT WIRED: $f"
done
```

Expected: no output.

- [ ] **Step 6: Verify no gate regressed**

The three gates write their deny payload to stdout. Confirm the instrument did not contaminate it:

Run: `bats test/bats/gate-block-contract.bats`
Expected: 3 passing, canary skipped. If a gate now emits stray output, the health log path is wrong — it must never write to stdout.

- [ ] **Step 7: Commit**

```bash
git add plugins/*/scripts/hooks/*.sh test/bats/hook-health.bats
git commit -m "feat(hook-health): report latency from every plugin hook :bar_chart:"
```

---

### Task 7: Re-baseline and close out

**Files:**
- Modify: `docs/superpowers/specs/2026-08-29-dogfooding-rollout-design.md`
- Modify: `docs/superpowers/specs/2026-08-29-hook-health-instrumentation-design.md` (status line)

- [ ] **Step 1: Run the full CI suite**

Run: `npm run test:ci`
Expected: exit 0, zero `not ok`, no `check-bus-coverage: rejected` lines.

- [ ] **Step 2: Measure the instrument's own cost**

```bash
time ( for i in $(seq 1 20); do bash -c '
  source scripts/lib/hook-health.sh
  export ONLOOKER_HOOK_HEALTH_LOG=/tmp/bench-health.jsonl
  hook_health_register bench
  exit 0'; done )
```

Divide by 20. Record the per-hook overhead. The spec predicts roughly 7ms where `perl` is available.

- [ ] **Step 3: Re-baseline with only ecosystem enabled**

Restart a session with only `ecosystem@onlooker-community` enabled, do a handful of edits and prompts, then:

```bash
grep "$SESSION_ID" ~/.onlooker/logs/hook-health.jsonl | python3 -c "
import sys, json, collections
d = collections.defaultdict(list)
for l in sys.stdin:
    try: e = json.loads(l)
    except Exception: continue
    d[(e.get('hook_event'), e.get('hook'))].append(e.get('duration_ms') or 0)
for (evt, hook), v in sorted(d.items()):
    print(f'{evt:22} {hook:30} n={len(v):3} mean={sum(v)/len(v):6.0f} max={max(v):6.0f}')
"
```

- [ ] **Step 4: Update the rollout design doc**

In `docs/superpowers/specs/2026-08-29-dogfooding-rollout-design.md`, add the new figures beside the wave 0 table with a note that the two are not comparable: the original numbers included roughly 37ms per hook of measurement overhead from the old python3 clock.

- [ ] **Step 5: Update the bd memory and close the bead**

```bash
bd remember --key dogfood-wave0-baseline "<updated baseline text, both sets of numbers, noting which instrument produced each>"
bd close ecosystem-449.5 --reason="<PR reference>"
```

- [ ] **Step 6: Commit and open the PR**

```bash
git add docs/superpowers/specs/
git commit -m "docs(dogfooding): re-baseline latency under the cheaper clock :straight_ruler:"
```

Then open the PR with the `/git-workflow:pr` skill.

---

## Self-Review

**Spec coverage.** `hook-health.sh` → Task 1. Clock cascade → Task 1. jq end-time → Task 1. Trap chaining → Task 2. `validate-path.sh` aliasing → Task 3. librarian restore → Task 4. Vendoring, sync generalization, drift test → Task 5. Wiring 31 hooks → Task 6. Re-baseline → Task 7. No schema work, as the spec states. Every spec section maps to a task.

**Placeholder scan.** One deliberate placeholder remains, in Task 7 Step 5: the `bd remember` text and the close reason depend on numbers that do not exist until Step 3 runs. Every other step carries its actual content.

**Type consistency.** `_HOOK_START_MS` is the name throughout — Task 3 Step 3 flags the rename from the old `_HOOK_START_TIME` in case `validate-path.bats` asserts on it. `hook_health_register`, `hook_health_context`, `hook_health_success`, `hook_health_failure`, `_hook_health_write`, `_hook_health_now_ms`, `_hook_health_on_exit`, and `hook_health_log_path` are used consistently in every task that references them. The sync script is `scripts/sync-shared-libs.sh` from Task 5 onward, and Task 5 Step 5 catches stale references to the old name.
