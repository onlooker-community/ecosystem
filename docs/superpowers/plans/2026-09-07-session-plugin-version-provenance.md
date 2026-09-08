# Session Plugin-Version Provenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `hook-health.jsonl` row state which plugin code wrote it, so "what version is this session running" is an observation instead of an inference from timestamps.

**Architecture:** `scripts/lib/hook-health.sh` derives its own plugin name and version from `${BASH_SOURCE[0]}` — the lib's path is version-pinned in the installed layout — and stamps them plus `$PPID` onto every record. The lib is vendored into all sixteen plugins by `scripts/sync-shared-libs.sh`, and the substrate reaches the same code through `hook_register()` in `validate-path.sh`, so one edit covers everything. A small read script answers the question live from the rows.

**Tech Stack:** bash (system bash 3.2 on macOS), `jq`, bats, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-07-session-plugin-version-provenance-design.md`

## Global Constraints

- **bash 3.2 compatible.** Hooks run under `#!/usr/bin/env bash`, which on macOS is 3.2.57. No associative arrays, no `${var,,}`, no `$EPOCHREALTIME` assumptions. Put regexes in a variable before `=~` — 3.2's quoting rules differ from 4+.
- **No new subprocess on the hot path.** This lib runs on the per-edit path that wave 1's latency budget is gated on. Derivation must be pure parameter expansion; `$PPID` is a builtin. `_hook_health_write` already spawns exactly one `jq` and must continue to spawn exactly one.
- **Fail-soft.** Every function in this lib returns 0. A hook must never break because its instrument broke.
- **Self-locating only.** Derive from `${BASH_SOURCE[0]}`. Never `$PLUGIN_ROOT` (lost in sub-shells) and never `dirname "$(dirname ...)"` — CLAUDE.md records eighteen sites of that shape across nine plugins with zero correct.
- **Re-stamp after editing.** Editing `scripts/lib/hook-health.sh` invalidates `_ONLOOKER_LIB_FINGERPRINT`. Run `scripts/sync-shared-libs.sh` (not `--check`) to re-stamp and propagate, then commit the sixteen vendored copies with the canonical one.
- **shellcheck clean** at `-S error` with `-x`, per `npm run test:shellcheck`.
- **American English** in all comments and commit messages.
- Never hardcode `~/.onlooker`; use `$ONLOOKER_DIR`.

---

### Task 1: Derive and record plugin origin on every hook-health row

**Files:**
- Modify: `scripts/lib/hook-health.sh` (add derivation near the top; add three fields in `_hook_health_write`)
- Modify: `plugins/*/scripts/lib/hook-health.sh` (16 copies, written by the sync script — do not hand-edit)
- Test: `test/bats/hook-health-plugin-version.bats` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: three new keys on each `hook-health.jsonl` record — `plugin_name` (string|null), `plugin_version` (string|null), `host_pid` (number|null). Task 2 reads all three.
- Produces: shell globals `_ONLOOKER_PLUGIN_NAME`, `_ONLOOKER_PLUGIN_VERSION`, `_HOOK_HOST_PID`, and the function `_hook_health_derive_origin()`.

- [ ] **Step 1: Write the failing test**

Create `test/bats/hook-health-plugin-version.bats`:

```bash
#!/usr/bin/env bats

# Every hook-health row states which plugin code wrote it.
#
# ecosystem-9eg. /clear mints a new session_id inside the SAME process, and
# plugin code is pinned at process start, so a cleared session looks
# post-release by every timestamp available while still running the
# pre-release plugin. Measured 2026-09-07: session c8fc83ed began 41 minutes
# after lineage 0.5.1 was installed and ran 0.5.0 for its whole life.
#
# The fix is to stop inferring. The lib's own path is version-pinned in the
# installed layout, so it can name the version that wrote each row.
#
# See docs/superpowers/specs/2026-09-07-session-plugin-version-provenance-design.md

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
}

# Stage a copy of the canonical lib at an arbitrary path and emit one record
# from it, so the derivation is exercised against a real layout rather than a
# stubbed variable. Echoes the record.
_row_from_layout() {
	local libdir="$1"
	mkdir -p "$libdir"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${libdir}/hook-health.sh"
	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "layout-probe"
		hook_health_success
	' _ "${libdir}/hook-health.sh" >/dev/null 2>&1
	tail -n 1 "$HEALTH_LOG"
}

@test "the released layout yields both the plugin name and its version" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/cache/onlooker-community/lineage/0.5.1/scripts/lib")
	printf '%s' "$row" | jq -e '
		.plugin_name == "lineage" and .plugin_version == "0.5.1"
	' >/dev/null
}

# A prerelease directory is still a release layout.
@test "a prerelease version directory is recognized" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/cache/onlooker-community/echo/1.2.3-rc.1/scripts/lib")
	printf '%s' "$row" | jq -e '
		.plugin_name == "echo" and .plugin_version == "1.2.3-rc.1"
	' >/dev/null
}

# A working-tree run is NOT a release. Null is the honest label -- it says
# "written by an unreleased copy" and keeps dev rows from being mistaken for
# a released version during a rollout measurement.
@test "a dev checkout yields the name with a null version" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/ecosystem/plugins/lineage/scripts/lib")
	printf '%s' "$row" | jq -e '
		.plugin_name == "lineage" and .plugin_version == null
	' >/dev/null
}

# The substrate published from the marketplace looks like any other plugin.
@test "the substrate reports itself by name and version" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.53.2/scripts/lib")
	printf '%s' "$row" | jq -e '
		.plugin_name == "ecosystem" and .plugin_version == "0.53.2"
	' >/dev/null
}

# Fail-soft: an unrecognizable path must still produce a usable record.
@test "an unexpected layout nulls both fields and still writes the row" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/somewhere/odd")
	printf '%s' "$row" | jq -e '
		.plugin_name == null and .plugin_version == null
		and .hook == "layout-probe" and .status == "success"
	' >/dev/null
}

# host_pid is what makes /clear visible: two session_ids sharing one host_pid
# is a cleared session, not two processes.
@test "host_pid records the shell's parent process" {
	source "${REPO_ROOT}/scripts/lib/hook-health.sh"
	hook_health_register "pid-probe"
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e --argjson want "$PPID" '.host_pid == $want' >/dev/null
}

@test "the three fields survive into every vendored copy" {
	local missing=() f
	for f in "${REPO_ROOT}"/plugins/*/scripts/lib/hook-health.sh; do
		[[ -f "$f" ]] || continue
		grep -q '_hook_health_derive_origin' "$f" || missing+=("${f#"${REPO_ROOT}/"}")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		printf 'vendored copies without the derivation:\n'
		printf '  %s\n' "${missing[@]}"
		return 1
	fi
	true
}

# The installed layout is a standalone tree with no ecosystem checkout above
# it. This is the shape that broke ecosystem-ber and ecosystem-449.35/36.
@test "derivation works from a copied-out standalone plugin tree" {
	local standalone="${BATS_TEST_TMPDIR}/standalone/onlooker-community/inspector/9.9.9"
	mkdir -p "$standalone"
	cp -R "${REPO_ROOT}/plugins/inspector/." "${standalone}/"

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "standalone-probe"
		hook_health_success
	' _ "${standalone}/scripts/lib/hook-health.sh" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "inspector" and .plugin_version == "9.9.9"
	' >/dev/null
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx bats test/bats/hook-health-plugin-version.bats`

Expected: FAIL. The `jq -e` assertions return non-zero because `.plugin_name`, `.plugin_version`, and `.host_pid` are all absent from the record (jq yields `null` for a missing key, so `.plugin_name == "lineage"` is false).

- [ ] **Step 3: Add the derivation to the canonical lib**

In `scripts/lib/hook-health.sh`, immediately after the `_HOOK_PRIOR_EXIT_CMD` declaration block, add:

```bash
# Which plugin copy is this, and which host process is running it.
#
# ecosystem-9eg. /clear mints a new session_id inside the SAME process, and
# plugin code is pinned at PROCESS start rather than session start. A cleared
# session therefore looks post-release by every timestamp available while still
# running the pre-release plugin, so comparing a session's first event to the
# install time gives a false pass. Recording the version directly retires that
# whole inference.
#
# Derived from this file's own path, which is version-pinned in the installed
# layout (.../cache/<marketplace>/<plugin>/<version>/scripts/lib/hook-health.sh).
# Self-locating via BASH_SOURCE for the same reason config-loader.sh is:
# $PLUGIN_ROOT is read from whatever scope did the sourcing and is simply gone
# in a sub-shell that inherited only CLAUDE_PLUGIN_ROOT.
_ONLOOKER_PLUGIN_NAME=""
_ONLOOKER_PLUGIN_VERSION=""

# $PPID is the process that invoked the hook — the claude process itself,
# confirmed by capturing live hook processes during an edit. A builtin, so it
# costs nothing. Two session_ids sharing one host_pid IS a /clear; one
# plugin_name carrying two plugin_versions is a mixed-version window.
_HOOK_HOST_PID="$PPID"

_hook_health_derive_origin() {
	local src="${BASH_SOURCE[0]}"

	# Walk up from <root>/scripts/lib/hook-health.sh to <root>, checking each
	# component by name. Pure parameter expansion: no dirname, no subprocess.
	# Verifying the names rather than blindly stripping three levels means a
	# path of an unexpected shape falls through to the null case instead of
	# quietly labeling rows with whatever happened to sit three levels up.
	local libdir="${src%/*}"
	[[ "${libdir##*/}" == "lib" ]] || return 0
	local scriptsdir="${libdir%/*}"
	[[ "${scriptsdir##*/}" == "scripts" ]] || return 0
	local root="${scriptsdir%/*}"
	# A relative path can run out of components before we run out of strips,
	# leaving root equal to what we tried to strip.
	[[ -n "$root" && "$root" != "$scriptsdir" ]] || return 0

	local base="${root##*/}"
	# Assigned to a variable first: bash 3.2 treats a quoted regex literal as a
	# string to match, not a pattern.
	local semver='^[0-9]+\.[0-9]+\.[0-9]+'
	if [[ "$base" =~ $semver ]]; then
		_ONLOOKER_PLUGIN_VERSION="$base"
		local parent="${root%/*}"
		[[ -n "$parent" && "$parent" != "$root" ]] && _ONLOOKER_PLUGIN_NAME="${parent##*/}"
	else
		# A working-tree checkout: <repo>/plugins/<name> or <repo> for the
		# substrate. Name it, but leave the version null — this copy is not a
		# release and must not be counted as one.
		_ONLOOKER_PLUGIN_NAME="$base"
	fi
	return 0
}

_hook_health_derive_origin
```

- [ ] **Step 4: Stamp the three fields onto the record**

In `_hook_health_write` in the same file, add three bindings to the existing `jq -cn` invocation, immediately after the `--arg lib "$_ONLOOKER_LIB_FINGERPRINT" \` line:

```bash
		--arg plugin_name "$_ONLOOKER_PLUGIN_NAME" \
		--arg plugin_version "$_ONLOOKER_PLUGIN_VERSION" \
		--argjson host_pid "${_HOOK_HOST_PID:-0}" \
```

and add three keys to the emitted object, immediately after the `lib_schema:` line (add a comma to `lib_schema`'s line):

```jq
			# Which plugin code wrote this row (ecosystem-9eg). plugin_version
			# is null for a working-tree copy, which is not a release and must
			# not be counted as one.
			plugin_name: (if $plugin_name == "" then null else $plugin_name end),
			plugin_version: (if $plugin_version == "" then null else $plugin_version end),
			# The host claude process. Two session_ids sharing one host_pid is
			# a /clear, which no timestamp can distinguish from a fresh start.
			host_pid: (if $host_pid > 0 then $host_pid else null end)
```

- [ ] **Step 5: Propagate to the vendored copies and re-stamp the fingerprint**

Run: `scripts/sync-shared-libs.sh`

Expected: one `stamped scripts/lib/hook-health.sh (<new-12-hex>)` line, then 16 `synced plugins/<name>/scripts/lib/hook-health.sh` lines, then `16 copy/copies updated`.

- [ ] **Step 6: Run the new test to verify it passes**

Run: `npx bats test/bats/hook-health-plugin-version.bats`
Expected: PASS, 8 tests.

- [ ] **Step 7: Run the surrounding suites that guard this lib**

Run: `npx bats test/bats/hook-health.bats test/bats/shared-lib-fingerprint.bats test/bats/shared-lib-vendoring.bats test/bats/config-lib-self-locating.bats`
Expected: PASS. `shared-lib-fingerprint.bats` proves the re-stamp in Step 5 actually happened; if it fails with "stamp does not match content", Step 5 was skipped or run with `--check`.

- [ ] **Step 8: Run the full suite and shellcheck**

Run: `npm run test:shellcheck && npm run test:bats`
Expected: shellcheck silent; bats fully green (the baseline is 1516 passing, so expect 1524 with the eight new tests).

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/hook-health.sh plugins/*/scripts/lib/hook-health.sh test/bats/hook-health-plugin-version.bats
```

Then commit via the `/commit` skill (CLAUDE.md requires it — do not hand-write `git commit -m`). Subject to use:

`feat(ecosystem): stamp the plugin version on every hook-health row :mag:`

---

### Task 2: Answer "what is this session running" from the rows

**Files:**
- Create: `scripts/session-plugin-versions.sh`
- Test: `test/bats/session-plugin-versions.bats` (create)

**Interfaces:**
- Consumes: the `plugin_name`, `plugin_version`, and `host_pid` fields produced by Task 1.
- Produces: `scripts/session-plugin-versions.sh`, which prints one `<plugin_name> <plugin_version>` line per distinct pair observed for the current host process, sorted. Accepts an optional `--pid <n>` to inspect a specific host process instead of resolving one.

- [ ] **Step 1: Write the failing test**

Create `test/bats/session-plugin-versions.bats`:

```bash
#!/usr/bin/env bats

# The live read path for ecosystem-9eg: what is THIS session actually running?
#
# Reads observed hook-health rows rather than installed_plugins.json, because
# the manifest reports what is on disk and the session may have pinned older
# code at process start. That gap is the entire bug.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
	mkdir -p "$(dirname "$HEALTH_LOG")"
	SCRIPT="${REPO_ROOT}/scripts/session-plugin-versions.sh"
}

_row() {
	jq -cn --arg n "$1" --arg v "$2" --argjson p "$3" \
		'{hook:"h", status:"success", plugin_name:$n, plugin_version:$v, host_pid:$p}' \
		>> "$HEALTH_LOG"
}

@test "reports the distinct plugin versions for the given host pid" {
	_row lineage 0.5.1 4242
	_row lineage 0.5.1 4242
	_row echo 0.5.2 4242
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
	[[ "$output" == *"echo 0.5.2"* ]]
	[[ "$output" == *"lineage 0.5.1"* ]]
	[ "$(printf '%s\n' "$output" | grep -c lineage)" -eq 1 ]
}

@test "ignores rows belonging to another host process" {
	_row lineage 0.5.1 4242
	_row lineage 0.5.0 9999
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
	[[ "$output" == *"0.5.1"* ]]
	[[ "$output" != *"0.5.0"* ]]
}

# The mixed-version window this bead was filed for: one plugin, two versions,
# one process. Surfacing it is the point -- collapsing it would hide the bug.
@test "surfaces a plugin running two versions in one process" {
	_row lineage 0.5.0 4242
	_row lineage 0.5.1 4242
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c '^lineage ')" -eq 2 ]
}

@test "labels an unreleased working-tree copy rather than printing null" {
	jq -cn '{hook:"h", plugin_name:"lineage", plugin_version:null, host_pid:4242}' >> "$HEALTH_LOG"
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
	[[ "$output" == *"lineage"* ]]
	[[ "$output" == *"(working tree)"* ]]
	[[ "$output" != *"null"* ]]
}

@test "says so plainly when the process has no rows yet" {
	_row lineage 0.5.1 4242
	run bash "$SCRIPT" --pid 1234
	[ "$status" -eq 0 ]
	[[ "$output" == *"no hook-health rows"* ]]
}

@test "an absent log is not an error" {
	rm -f "$HEALTH_LOG"
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx bats test/bats/session-plugin-versions.bats`
Expected: FAIL — every test errors because `scripts/session-plugin-versions.sh` does not exist.

- [ ] **Step 3: Write the script**

Create `scripts/session-plugin-versions.sh`:

```bash
#!/usr/bin/env bash
# What plugin code is this session actually running?
#
# ecosystem-9eg. installed_plugins.json reports what is on DISK. A session runs
# what was pinned when its PROCESS started, and /clear mints a new session_id
# inside the same process without reloading anything — so a cleared session
# looks post-release by every timestamp available while running pre-release
# code. Answering from the manifest, or from any timestamp comparison, gets
# this wrong. This reads what hooks actually reported.
#
# Usage:
#   scripts/session-plugin-versions.sh              # this session's host process
#   scripts/session-plugin-versions.sh --pid 1234   # a specific host process

set -uo pipefail

HEALTH_LOG="${ONLOOKER_HOOK_HEALTH_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/hook-health.jsonl}"

# Walk up the process tree to the nearest claude ancestor. A hook records its
# own $PPID, which is that process, so this is what joins us to the rows.
_resolve_host_pid() {
	local pid="$$" comm guard=0
	while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && "$guard" -lt 40 ]]; do
		comm=$(ps -o comm= -p "$pid" 2>/dev/null)
		case "$comm" in
			*claude*)
				printf '%s' "$pid"
				return 0
				;;
		esac
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
		guard=$((guard + 1))
	done
	return 1
}

HOST_PID=""
if [[ "${1:-}" == "--pid" ]]; then
	HOST_PID="${2:-}"
fi
if [[ -z "$HOST_PID" ]]; then
	HOST_PID=$(_resolve_host_pid) || {
		printf 'could not find a claude process in this process tree\n'
		exit 0
	}
fi

if [[ ! -f "$HEALTH_LOG" ]]; then
	printf 'no hook-health log at %s\n' "$HEALTH_LOG"
	exit 0
fi

OUT=$(jq -r --argjson pid "$HOST_PID" '
	select(.host_pid == $pid)
	| select(.plugin_name != null)
	| "\(.plugin_name) \(.plugin_version // "(working tree)")"
' "$HEALTH_LOG" 2>/dev/null | sort -u)

if [[ -z "$OUT" ]]; then
	printf 'no hook-health rows for host pid %s\n' "$HOST_PID"
	exit 0
fi

printf 'host pid %s is running:\n' "$HOST_PID"
printf '%s\n' "$OUT"
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x scripts/session-plugin-versions.sh`

Note: the tests invoke it as `bash "$SCRIPT"`, which passes even without the exec bit. Set it anyway — a rewrite that drops the exec bit is a known silent failure mode in this repo.

- [ ] **Step 5: Run the test to verify it passes**

Run: `npx bats test/bats/session-plugin-versions.bats`
Expected: PASS, 6 tests.

- [ ] **Step 6: Verify it works against the real log**

Run: `scripts/session-plugin-versions.sh`

Expected: `host pid <n> is running:` followed by the plugins that have fired hooks in this session. Rows written before Task 1 landed carry no `plugin_name` and are correctly skipped, so this list grows as the session continues.

- [ ] **Step 7: shellcheck and commit**

Run: `npm run test:shellcheck`
Expected: silent.

```bash
git add scripts/session-plugin-versions.sh test/bats/session-plugin-versions.bats
```

Then commit via the `/commit` skill. Subject to use:

`feat(ecosystem): read the running plugin version from observed rows :mag:`

---

### Task 3: Correct the recorded verification rule

**Files:**
- Modify: the `bd` memory `a-claude-code-session-runs-the-plugin-version`

**Interfaces:**
- Consumes: the script name from Task 2.
- Produces: nothing consumed by later tasks.

The memory currently prescribes the `ps`-based process-start-time comparison as "the reliable check". After Tasks 1 and 2 that is no longer the cheapest correct answer, and leaving it unqualified sends the next session down a three-tool-call detour.

- [ ] **Step 1: Rewrite the memory**

```bash
bd remember "A Claude Code session runs the plugin version pinned when its PROCESS started, not what installed_plugins.json currently reports, and NOT what the session's own start time implies. /clear mints a new session_id inside the same process and does NOT reload plugin code, so a cleared session looks post-release by every timestamp available and still runs the pre-release plugin. Caught twice on 2026-09-07: session b924fabe ran echo 0.5.0 for its whole life while the manifest said 0.5.1; session c8fc83ed began 41 minutes AFTER lineage 0.5.1 was installed and still ran 0.5.0, because /clear had minted it inside a process that started before the install. CHECK THIS THE CHEAP WAY: run scripts/session-plugin-versions.sh, which reads the plugin_name/plugin_version/host_pid stamped on every hook-health row since ecosystem-9eg and reports what hooks actually ran. Two session_ids sharing one host_pid is a /clear; one plugin_name with two plugin_versions is a mixed-version window. A null plugin_version means a working-tree copy, not a release. Only for rows written BEFORE ecosystem-9eg landed does the old fallback apply: get the hook's PPID during a live tool call and compare that process's lstart to the install timestamp. Do not use the session's first-event timestamp -- that is the check that gave the false pass." --key a-claude-code-session-runs-the-plugin-version
```

- [ ] **Step 2: Verify it took**

Run: `bd recall a-claude-code-session-runs-the-plugin-version`
Expected: the stored text now mentions `session-plugin-versions.sh`.

- [ ] **Step 3: No commit**

`bd remember` writes to the beads store, not the working tree. Nothing to stage.

---

### Task 4: Re-measure what the contaminated sessions reported

**Files:** none — this is verification, not code. Record findings on the beads.

**Interfaces:**
- Consumes: Task 2's script.
- Produces: annotations on `ecosystem-449.40`, `ecosystem-449.41`, `ecosystem-449.46`.

This task closes the bead's acceptance 3 and 4. It must run from a process started *after* the 0.5.1 install — confirm with Task 2's script before trusting any number produced here.

- [ ] **Step 1: Confirm this process is clean**

Run: `scripts/session-plugin-versions.sh`
Expected: `lineage 0.5.1` and `ecosystem 0.53.2`. If it reports `lineage 0.5.0`, stop — this process pinned pre-release code and no measurement from it counts.

- [ ] **Step 2: Re-run the lineage cross-session check (`ecosystem-449.41`)**

Make a known edit, then run `/lineage <file>:<line>` and confirm it names *this* session rather than a bystander. Record the observed session id alongside the expected one.

- [ ] **Step 3: Re-measure echo's stop-gate fires (`ecosystem-449.40` acceptance 7)**

The prediction on record: slow (>5s) `echo-stop-gate` fires track distinct content changes, so 2026-09-07's 8 fires over 2 files should become 2. Partition `hook-health.jsonl` by `plugin_version` — now possible for the first time — and compare only rows written by 0.5.1.

- [ ] **Step 4: Triage `ecosystem-449.46` for pre-install contamination**

That bead's evidence came from sessions `b924fabe` and `9efeb7d6`. `b924fabe` is already known to have run echo 0.5.0. Determine whether `9efeb7d6` did too, and annotate or discard the affected numbers accordingly.

- [ ] **Step 5: Record findings**

Use `bd update <id> --append-notes` — **not** `--notes`, which replaces existing notes and only warns after the write.

---

## Self-Review

**Spec coverage.** Three fields → Task 1. Self-location and both layouts → Task 1 Steps 3 and 6, plus the standalone-tree test. Zero-subprocess cost constraint → Global Constraints and Task 1 Step 3. No schema change → nothing in any task touches `@onlooker-community/schema`. Live read path → Task 2. The spec's "Testing" section lists five cases plus the standalone tree; Task 1's test file covers all six and adds the prerelease and vendored-copy cases. Acceptance 1 of the bead → Task 3. Acceptances 3 and 4 → Task 4.

**Placeholder scan.** No TBD/TODO. Every code step carries the literal code. Task 4 is deliberately procedural rather than code-bearing because it is a measurement task; each step names the exact bead and the exact expected number.

**Type consistency.** `_ONLOOKER_PLUGIN_NAME`, `_ONLOOKER_PLUGIN_VERSION`, `_HOOK_HOST_PID`, and `_hook_health_derive_origin` are spelled identically in Task 1 Steps 3, 4, and the Task 1 test's vendored-copy grep. The record keys `plugin_name`, `plugin_version`, `host_pid` are spelled identically in Task 1 Step 4, Task 1's tests, Task 2's script, and Task 2's tests. `--pid` is the flag in both Task 2's script and its tests.
