# Watch-unmatched signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit `onlooker.watch.unmatched` when echo's or cartographer's configured patterns match zero paths in a repository, so a dead watcher stops looking identical to an idle one.

**Architecture:** One vendored substrate lib (`scripts/lib/watch-unmatched.sh`) owns scanning, a per-project marker, and the emit decision. It exposes a single entry point that each plugin calls once from a hook. Two scanners live behind a `--mode` flag because echo matches git-tracked paths and cartographer expands globs against the filesystem; each mode mirrors its own plugin's matcher exactly.

**Tech Stack:** Bash 3.2-compatible shell, `jq`, `git`, `python3` for date math, bats for tests, `@onlooker-community/schema` ^2.21.0 for event validation.

**Spec:** `docs/superpowers/specs/2026-09-15-watch-unmatched-design.md`
**Bead:** `ecosystem-449.21`
**Branch:** `feat/watch-unmatched` (already exists; the spec is committed as `4aaa34f`)

## Global Constraints

- **Bash only.** No Python or Node entry points in hooks; shelling out to `node` for event emission or `python3` for date math is fine (CLAUDE.md Conventions).
- **Never hardcode `~/.onlooker`.** Always `${ONLOOKER_DIR:-}` so the suite's temp home is respected (CLAUDE.md item 3).
- **Fail soft.** Every public function returns 0 on every path, including failure. A plugin must not block a session it was not invited to (CLAUDE.md item 7).
- **Self-locating libs.** Resolve siblings from `${BASH_SOURCE[0]}`, never from a caller-supplied `$PLUGIN_ROOT`, never via a path that climbs to the repo root (CLAUDE.md item 8).
- **Event type:** `onlooker.watch.unmatched`. Payload is exactly `plugin`, `config_key`, `patterns`, `candidates_scanned`, `project_key`. `additionalProperties: false` — any sixth field fails validation under `ONLOOKER_VALIDATE=1`.
- **`plugin` enum admits only `echo` and `cartographer`.** A third needs a schema release.
- **American English** in comments, identifiers, and commit messages.
- **Commits route through `/commit`.** Never hand-craft `git commit -m`.
- **Never push to `main`.** This lands as a PR from `feat/watch-unmatched`.
- **Bash 3.2:** no `mapfile`, no associative arrays. Read into arrays with `while IFS= read -r`.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib/watch-unmatched.sh` (create) | Canonical lib: scanners, marker, emit decision |
| `plugins/echo/scripts/lib/watch-unmatched.sh` (generated) | Vendored copy, written by `sync-shared-libs.sh` |
| `plugins/cartographer/scripts/lib/watch-unmatched.sh` (generated) | Vendored copy, written by `sync-shared-libs.sh` |
| `scripts/sync-shared-libs.sh:29` (modify) | Add the lib to `SHARED_LIBS` |
| `plugins/echo/scripts/hooks/echo-stop-gate.sh` (modify) | Call site; hoist pattern load above the `ALL_CHANGED` gate |
| `plugins/cartographer/scripts/hooks/cartographer-session-start.sh` (modify) | Call site, before the audit-interval gate |
| `test/bats/watch-unmatched.bats` (create) | Unit coverage for the lib |
| `test/bats/echo-watch-unmatched.bats` (create) | Echo call-site coverage — no `echo-stop-gate.bats` exists to extend |
| `test/bats/cartographer-session-start.bats` (create) | Cartographer call-site coverage — nothing drives this hook today |
| `test/bus-coverage.json` (modify) | Move the type from `excluded` to `expected` |

---

### Task 1: Marker read/write primitives

**Files:**
- Create: `scripts/lib/watch-unmatched.sh`
- Test: `test/bats/watch-unmatched.bats`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `onlooker_watch_marker_path <project_key> <config_key>` → prints path
  - `onlooker_watch_patterns_hash <patterns_json>` → prints 12 hex chars, returns 1 on failure
  - `onlooker_watch_marker_due <path> <hash> <ttl_hours>` → returns 0 when due, 1 when not
  - `onlooker_watch_marker_write <path> <hash>` → returns 0 on success
  - `onlooker_watch_marker_clear <path>` → always returns 0

- [ ] **Step 1: Write the failing test**

Create `test/bats/watch-unmatched.bats`:

```bash
#!/usr/bin/env bats
# Watch-unmatched signal (ecosystem-449.21).
#
# The governing rule under test: each mode mirrors its plugin's real matcher.
# A check that disagrees with the matcher invents misconfigurations that are
# not there, which is worse than the silence it replaces.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/scripts/lib/watch-unmatched.sh"
	MARKER=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
}

@test "marker path is project-scoped and under ONLOOKER_DIR" {
	[[ "$MARKER" == "${ONLOOKER_DIR}/watch-unmatched/proj123/echo.watch_paths.json" ]]
}

# Guards the fallback. Echo calls this above the point where its own hook
# establishes ONLOOKER_BASE, so an unset ONLOOKER_DIR must still yield a
# writable path rather than one rooted at "/".
@test "marker path falls back to HOME when ONLOOKER_DIR is unset" {
	saved="$ONLOOKER_DIR"
	unset ONLOOKER_DIR
	path=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	export ONLOOKER_DIR="$saved"
	[[ "$path" == "${HOME}/.onlooker/watch-unmatched/proj123/echo.watch_paths.json" ]]
}

@test "patterns hash ignores ordering but not content" {
	a=$(onlooker_watch_patterns_hash '["b.md","a.md"]')
	b=$(onlooker_watch_patterns_hash '["a.md","b.md"]')
	c=$(onlooker_watch_patterns_hash '["a.md","c.md"]')
	[[ -n "$a" && "$a" == "$b" && "$a" != "$c" ]]
}

@test "an absent marker is due" {
	onlooker_watch_marker_due "$MARKER" "abc123abc123" 168
}

@test "a fresh marker with a matching hash is not due" {
	onlooker_watch_marker_write "$MARKER" "abc123abc123"
	! onlooker_watch_marker_due "$MARKER" "abc123abc123" 168
}

@test "a changed hash re-arms a fresh marker" {
	onlooker_watch_marker_write "$MARKER" "abc123abc123"
	onlooker_watch_marker_due "$MARKER" "def456def456" 168
}

@test "an expired marker is due even when the hash matches" {
	mkdir -p "$(dirname "$MARKER")"
	jq -n --arg h "abc123abc123" --arg t "$(relative_iso_days_ago 8)" \
		'{patterns_hash: $h, last_emitted: $t}' >"$MARKER"
	onlooker_watch_marker_due "$MARKER" "abc123abc123" 168
}

@test "a corrupt marker is due rather than trusted" {
	mkdir -p "$(dirname "$MARKER")"
	printf 'not json' >"$MARKER"
	onlooker_watch_marker_due "$MARKER" "abc123abc123" 168
}

@test "clearing removes the marker and is safe when absent" {
	onlooker_watch_marker_write "$MARKER" "abc123abc123"
	onlooker_watch_marker_clear "$MARKER"
	[[ ! -f "$MARKER" ]]
	onlooker_watch_marker_clear "$MARKER"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/meaganwaller/src/github.com/onlooker-community/ecosystem && ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats`
Expected: FAIL — `scripts/lib/watch-unmatched.sh: No such file or directory`

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/lib/watch-unmatched.sh`:

```bash
#!/usr/bin/env bash
# Watch-unmatched signal (ecosystem-449.21).
#
# GOVERNING RULE
#   Each mode mirrors its plugin's real matcher.
#
# A plugin that exits 0 and emits nothing looks exactly like a plugin with
# nothing to report. This lib answers the one question that separates them:
# do these configured patterns match zero paths in this repository at all?
# That is a property of repo plus config, not of the turn -- which is why it
# is marker-gated rather than emitted on every fire.
#
# The check must agree with the matcher it describes. Echo matches git-tracked
# paths; cartographer expands globs against the filesystem and so sees
# untracked and gitignored paths too. One scanner would disagree with one of
# them and invent misconfigurations that are not there.
#
# This lib is VENDORED into every plugin by scripts/sync-shared-libs.sh: an
# installed plugin publishes rooted at ./plugins/<name> and has no ecosystem
# checkout above it, so a repo-root path resolves in this checkout and nowhere
# else (ecosystem-ber).

# Default re-arm window. A deliberate constant, not config: pure edge-triggering
# makes a misconfiguration emitted once on day 1 invisible to a query over the
# last two days, which is the exact ambiguity this signal exists to remove.
_ONLOOKER_WATCH_TTL_HOURS_DEFAULT=168

_onlooker_watch_sha256_first12() {
	local input="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

# Seconds since epoch for an ISO-8601 UTC stamp, or empty when unparseable.
# python3 rather than `date`: -d vs -v diverges between GNU and BSD/macOS.
_onlooker_watch_epoch() {
	python3 -c '
import datetime, sys
try:
    d = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
    print(int(d.replace(tzinfo=datetime.timezone.utc).timestamp()))
except Exception:
    sys.exit(1)
' "$1" 2>/dev/null
}

# The ":-$HOME/.onlooker" fallback is load-bearing, not decoration. This is
# called from echo-stop-gate.sh at a point ABOVE where that hook establishes its
# own ONLOOKER_BASE (line 173), so a bare "${ONLOOKER_DIR:-}" would resolve to
# "/watch-unmatched/..." and fail to write with no error anyone would see. Both
# call-site hooks already use exactly this fallback (echo-stop-gate.sh:173,
# cartographer-session-start.sh:49); the env var still wins where it is set,
# which is what CLAUDE.md item 3 requires.
onlooker_watch_marker_path() {
	printf '%s/watch-unmatched/%s/%s.json' \
		"${ONLOOKER_DIR:-$HOME/.onlooker}" "${1:-unknown}" "${2:-unknown}"
}

# Hash over the SORTED pattern list. Reordering watch_paths is not a change in
# meaning and must not re-arm the signal; editing one is and must.
onlooker_watch_patterns_hash() {
	local sorted
	sorted=$(printf '%s' "${1:-[]}" | jq -cS 'sort' 2>/dev/null) || return 1
	[[ -z "$sorted" || "$sorted" == "null" ]] && return 1
	_onlooker_watch_sha256_first12 "$sorted"
}

# Due when: no marker, hash differs, stamp missing/unparseable, or age > ttl.
# Every unknown resolves to "due" -- under-reporting a live misconfiguration is
# the failure this bead exists to fix, so ambiguity errs toward emitting.
onlooker_watch_marker_due() {
	local path="${1:-}" hash="${2:-}" ttl_hours="${3:-$_ONLOOKER_WATCH_TTL_HOURS_DEFAULT}"
	[[ -f "$path" ]] || return 0

	local stored_hash stored_at then now
	stored_hash=$(jq -r '.patterns_hash // ""' "$path" 2>/dev/null) || return 0
	[[ "$stored_hash" != "$hash" ]] && return 0

	stored_at=$(jq -r '.last_emitted // ""' "$path" 2>/dev/null) || return 0
	[[ -z "$stored_at" ]] && return 0

	then=$(_onlooker_watch_epoch "$stored_at") || return 0
	[[ -z "$then" ]] && return 0
	now=$(date +%s)
	(( now - then > ttl_hours * 3600 )) && return 0
	return 1
}

# Write-then-rename: concurrent sessions in one project race on this file, and
# a torn write that still parses would be worse than one that does not.
onlooker_watch_marker_write() {
	local path="${1:-}" hash="${2:-}"
	[[ -z "$path" ]] && return 1
	mkdir -p "$(dirname "$path")" 2>/dev/null || return 1

	local tmp="${path}.tmp.$$"
	if ! jq -n --arg h "$hash" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{patterns_hash: $h, last_emitted: $t}' >"$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

onlooker_watch_marker_clear() {
	[[ -n "${1:-}" ]] && rm -f "$1" 2>/dev/null
	return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats`
Expected: PASS, 7 tests

- [ ] **Step 5: Commit**

Use `/commit` with: stage `scripts/lib/watch-unmatched.sh` and `test/bats/watch-unmatched.bats`. Subject along the lines of `feat(watch-unmatched): add the marker that decides when to speak up`.

---

### Task 2: The `files` scanner (echo's matcher)

**Files:**
- Modify: `scripts/lib/watch-unmatched.sh`
- Test: `test/bats/watch-unmatched.bats`

**Interfaces:**
- Consumes: nothing from Task 1
- Produces: `_onlooker_watch_scan_files <root> <patterns_json>` → prints `"<matched> <scanned>"` where `matched` is `0` or `1`

- [ ] **Step 1: Write the failing test**

Append to `test/bats/watch-unmatched.bats`:

```bash
_make_repo() {
	FIXTURE="${BATS_TEST_TMPDIR}/fixture"
	mkdir -p "${FIXTURE}/plugins/demo/agents"
	git -C "$FIXTURE" init -q
	git -C "$FIXTURE" config user.email t@example.com
	git -C "$FIXTURE" config user.name "Test"
	printf '# agent\n' >"${FIXTURE}/plugins/demo/agents/one.md"
	printf '# readme\n' >"${FIXTURE}/README.md"
	git -C "$FIXTURE" add -A
	git -C "$FIXTURE" commit -qm "fixture"
}

@test "files scanner matches a pattern that hits a tracked file" {
	_make_repo
	result=$(_onlooker_watch_scan_files "$FIXTURE" '["plugins/*/agents/*.md"]')
	[[ "${result%% *}" == "1" ]]
}

@test "files scanner reports zero for a pattern that hits nothing" {
	_make_repo
	result=$(_onlooker_watch_scan_files "$FIXTURE" '["nope/*/never.md"]')
	[[ "${result%% *}" == "0" ]]
	[[ "${result##* }" -ge 2 ]]
}

@test "files scanner ignores untracked files" {
	_make_repo
	printf '# untracked\n' >"${FIXTURE}/plugins/demo/agents/two.txt"
	result=$(_onlooker_watch_scan_files "$FIXTURE" '["plugins/*/agents/*.txt"]')
	[[ "${result%% *}" == "0" ]]
}

@test "files scanner is safe on a non-repo root" {
	mkdir -p "${BATS_TEST_TMPDIR}/plain"
	result=$(_onlooker_watch_scan_files "${BATS_TEST_TMPDIR}/plain" '["*.md"]')
	[[ "${result%% *}" == "0" ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats -f "files scanner"`
Expected: FAIL — `_onlooker_watch_scan_files: command not found`

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/lib/watch-unmatched.sh`:

```bash
# files mode -- mirrors echo-stop-gate.sh:141 exactly: git-tracked paths tested
# with bash pattern matching. Tracked only, so a pattern matching only untracked
# files reports unmatched. That is correct here: the repository does not durably
# contain those files.
#
# Prints "<matched> <scanned>". matched is 0 or 1; the caller only needs the
# boolean, and returning on the first hit avoids walking the rest of the tree.
_onlooker_watch_scan_files() {
	local root="${1:-}" patterns_json="${2:-[]}"

	local patterns=() p
	while IFS= read -r p; do
		[[ -n "$p" ]] && patterns+=("$p")
	done < <(printf '%s' "$patterns_json" | jq -r '.[]' 2>/dev/null)

	if [[ "${#patterns[@]}" -eq 0 ]]; then
		printf '0 0'
		return 0
	fi

	local scanned=0 f pat
	while IFS= read -r f; do
		[[ -z "$f" ]] && continue
		scanned=$(( scanned + 1 ))
		for pat in "${patterns[@]}"; do
			# shellcheck disable=SC2053 # unquoted on purpose: this is the glob
			if [[ "$f" == $pat ]]; then
				printf '1 %s' "$scanned"
				return 0
			fi
		done
	done < <(git -C "$root" ls-files 2>/dev/null)

	printf '0 %s' "$scanned"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats`
Expected: PASS, 11 tests

- [ ] **Step 5: Commit**

Use `/commit`, staging `scripts/lib/watch-unmatched.sh` and `test/bats/watch-unmatched.bats`.

---

### Task 3: The `dirs` scanner (cartographer's matcher)

**Files:**
- Modify: `scripts/lib/watch-unmatched.sh`
- Test: `test/bats/watch-unmatched.bats`

**Interfaces:**
- Consumes: nothing from Tasks 1–2
- Produces: `_onlooker_watch_scan_dirs <root> <patterns_json>` → prints `"<matched> <scanned>"`

- [ ] **Step 1: Write the failing test**

Append to `test/bats/watch-unmatched.bats`:

```bash
@test "dirs scanner matches a glob that hits a real directory" {
	_make_repo
	result=$(_onlooker_watch_scan_dirs "$FIXTURE" '["plugins/*/"]')
	[[ "${result%% *}" == "1" ]]
}

@test "dirs scanner reports zero for a glob that hits nothing" {
	_make_repo
	result=$(_onlooker_watch_scan_dirs "$FIXTURE" '["nonexistent/*/"]')
	[[ "${result%% *}" == "0" ]]
}

# The divergence that forces two scanners rather than one. Cartographer expands
# against the filesystem, so it sees what git does not. A git ls-files check
# would call this unmatched and invent a misconfiguration.
@test "dirs scanner sees untracked directories, unlike the files scanner" {
	_make_repo
	mkdir -p "${FIXTURE}/untracked-dir/child"
	dirs_result=$(_onlooker_watch_scan_dirs "$FIXTURE" '["untracked-dir/*/"]')
	files_result=$(_onlooker_watch_scan_files "$FIXTURE" '["untracked-dir/*"]')
	[[ "${dirs_result%% *}" == "1" ]]
	[[ "${files_result%% *}" == "0" ]]
}

@test "dirs scanner restores the caller's nullglob setting" {
	_make_repo
	shopt -u nullglob
	_onlooker_watch_scan_dirs "$FIXTURE" '["plugins/*/"]' >/dev/null
	! shopt -q nullglob
}

@test "dirs scanner handles a root containing a space" {
	SPACED="${BATS_TEST_TMPDIR}/has space"
	mkdir -p "${SPACED}/plugins/demo"
	result=$(_onlooker_watch_scan_dirs "$SPACED" '["plugins/*/"]')
	[[ "${result%% *}" == "1" ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats -f "dirs scanner"`
Expected: FAIL — `_onlooker_watch_scan_dirs: command not found`

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/lib/watch-unmatched.sh`:

```bash
# dirs mode -- mirrors cartographer-omission.sh:77 exactly: shell glob expansion
# against the FILESYSTEM under nullglob, then an existence test. This sees
# untracked and gitignored paths, which is why it cannot be folded into the
# files scanner.
#
# nullglob is saved and restored: this lib is sourced, not run.
_onlooker_watch_scan_dirs() {
	local root="${1:-}" patterns_json="${2:-[]}"
	root="${root%/}"

	local had_nullglob=0
	shopt -q nullglob && had_nullglob=1
	shopt -s nullglob

	local scanned=0 matched=0 glob match
	while IFS= read -r glob; do
		[[ -z "$glob" ]] && continue
		# shellcheck disable=SC2086 # $glob unquoted on purpose: this is the glob
		# expansion. "${root}" IS quoted -- a repo path containing a space must
		# not word-split before the glob expands, or the match silently finds
		# nothing.
		for match in "${root}"/$glob; do
			scanned=$(( scanned + 1 ))
			[[ -e "$match" ]] || continue
			matched=1
		done
	done < <(printf '%s' "$patterns_json" | jq -r '.[]' 2>/dev/null)

	[[ "$had_nullglob" -eq 0 ]] && shopt -u nullglob
	printf '%s %s' "$matched" "$scanned"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats`
Expected: PASS, 16 tests

- [ ] **Step 5: Commit**

Use `/commit`, staging `scripts/lib/watch-unmatched.sh` and `test/bats/watch-unmatched.bats`.

---

### Task 4: The public entry point

**Files:**
- Modify: `scripts/lib/watch-unmatched.sh`
- Test: `test/bats/watch-unmatched.bats`

**Interfaces:**
- Consumes: `onlooker_watch_marker_path`, `onlooker_watch_patterns_hash`, `onlooker_watch_marker_due`, `onlooker_watch_marker_write`, `onlooker_watch_marker_clear` (Task 1); `_onlooker_watch_scan_files` (Task 2); `_onlooker_watch_scan_dirs` (Task 3)
- Produces: `onlooker_watch_unmatched_check --plugin P --config-key K --root R --project-key PK --mode files|dirs --patterns-json J --emit-fn FN [--ttl-hours N]` → always returns 0

- [ ] **Step 1: Write the failing test**

Append to `test/bats/watch-unmatched.bats`:

```bash
_fake_emit() {
	printf '%s\t%s\n' "$1" "$2" >>"${BATS_TEST_TMPDIR}/emitted"
}

_emitted_count() {
	[[ -f "${BATS_TEST_TMPDIR}/emitted" ]] && wc -l <"${BATS_TEST_TMPDIR}/emitted" | tr -d ' ' || printf '0'
}

_check() {
	onlooker_watch_unmatched_check \
		--plugin echo --config-key echo.watch_paths \
		--root "$FIXTURE" --project-key "proj123" \
		--mode files --patterns-json "$1" \
		--emit-fn _fake_emit "${@:2}"
}

@test "emits when patterns match nothing" {
	_make_repo
	_check '["nope/*.md"]'
	[[ "$(_emitted_count)" == "1" ]]
	grep -q 'onlooker.watch.unmatched' "${BATS_TEST_TMPDIR}/emitted"
}

@test "the payload carries exactly the fields the schema allows" {
	_make_repo
	_check '["nope/*.md"]'
	payload=$(cut -f2 <"${BATS_TEST_TMPDIR}/emitted")
	printf '%s' "$payload" | jq -e '
		.plugin == "echo"
		and .config_key == "echo.watch_paths"
		and .patterns == ["nope/*.md"]
		and .project_key == "proj123"
		and (.candidates_scanned | type) == "number"
		and ([keys[]] | sort) == ["candidates_scanned","config_key","patterns","plugin","project_key"]
	' >/dev/null
}

@test "does not emit when patterns match" {
	_make_repo
	_check '["plugins/*/agents/*.md"]'
	[[ "$(_emitted_count)" == "0" ]]
}

@test "a match clears an existing marker" {
	_make_repo
	marker=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	onlooker_watch_marker_write "$marker" "stale-hash-xx"
	_check '["plugins/*/agents/*.md"]'
	[[ ! -f "$marker" ]]
}

# MUTATION TEST. A test asserting "no second event" passes just as well when
# the emitter is broken outright, so the first emit is asserted in the same
# test. Break the suppression and this must fail, or it is decoration.
@test "a second call is suppressed by the marker but the first still emitted" {
	_make_repo
	_check '["nope/*.md"]'
	[[ "$(_emitted_count)" == "1" ]]
	_check '["nope/*.md"]'
	[[ "$(_emitted_count)" == "1" ]]
}

# THE COST CONTRACT. When the marker says the check is not due, the scanner must
# not run at all -- that is what makes the steady state one stat on a hook that
# fires on every Stop. Proven by its side effect: a matching repo would clear the
# marker if it were scanned, so the marker surviving proves no scan happened.
@test "a marker that is not due suppresses the scan entirely" {
	_make_repo
	marker=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	hash=$(onlooker_watch_patterns_hash '["plugins/*/agents/*.md"]')
	onlooker_watch_marker_write "$marker" "$hash"
	_check '["plugins/*/agents/*.md"]'
	[[ -f "$marker" ]]
	[[ "$(_emitted_count)" == "0" ]]
}

@test "a changed pattern set re-arms the signal" {
	_make_repo
	_check '["nope/*.md"]'
	_check '["also-nope/*.md"]'
	[[ "$(_emitted_count)" == "2" ]]
}

@test "an expired marker re-arms the signal" {
	_make_repo
	_check '["nope/*.md"]'
	marker=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	hash=$(onlooker_watch_patterns_hash '["nope/*.md"]')
	jq -n --arg h "$hash" --arg t "$(relative_iso_days_ago 8)" \
		'{patterns_hash: $h, last_emitted: $t}' >"$marker"
	_check '["nope/*.md"]'
	[[ "$(_emitted_count)" == "2" ]]
}

@test "returns 0 and emits nothing when required arguments are missing" {
	run onlooker_watch_unmatched_check --plugin echo --emit-fn _fake_emit
	[ "$status" -eq 0 ]
	[[ "$(_emitted_count)" == "0" ]]
}

@test "returns 0 when the emit function does not exist" {
	_make_repo
	run onlooker_watch_unmatched_check \
		--plugin echo --config-key echo.watch_paths \
		--root "$FIXTURE" --project-key "proj123" \
		--mode files --patterns-json '["nope/*.md"]' \
		--emit-fn no_such_function
	[ "$status" -eq 0 ]
}

@test "an empty pattern list emits nothing" {
	_make_repo
	_check '[]'
	[[ "$(_emitted_count)" == "0" ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats -f "emits when patterns match nothing"`
Expected: FAIL — `onlooker_watch_unmatched_check: command not found`

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/lib/watch-unmatched.sh`:

```bash
# Public entry point. Returns 0 on every path, including every failure.
#
# An empty pattern list emits nothing: a plugin configured to watch nothing is
# a different condition from a plugin whose patterns cannot match, and this
# event type only speaks to the second.
onlooker_watch_unmatched_check() {
	local plugin="" config_key="" root="" project_key="" mode=""
	local patterns_json="" emit_fn="" ttl_hours="$_ONLOOKER_WATCH_TTL_HOURS_DEFAULT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--plugin)        plugin="${2:-}";        shift 2 ;;
			--config-key)    config_key="${2:-}";    shift 2 ;;
			--root)          root="${2:-}";          shift 2 ;;
			--project-key)   project_key="${2:-}";   shift 2 ;;
			--mode)          mode="${2:-}";          shift 2 ;;
			--patterns-json) patterns_json="${2:-}"; shift 2 ;;
			--emit-fn)       emit_fn="${2:-}";       shift 2 ;;
			--ttl-hours)     ttl_hours="${2:-168}";  shift 2 ;;
			*) shift ;;
		esac
	done

	[[ -z "$plugin" || -z "$config_key" || -z "$root" ]] && return 0
	[[ -z "$project_key" || -z "$mode" || -z "$patterns_json" ]] && return 0
	[[ -z "$emit_fn" ]] && return 0
	command -v jq >/dev/null 2>&1 || return 0

	local count
	count=$(printf '%s' "$patterns_json" | jq -r 'length' 2>/dev/null) || return 0
	[[ -z "$count" || "$count" == "null" || "$count" -eq 0 ]] && return 0

	[[ "$mode" == "files" || "$mode" == "dirs" ]] || return 0

	# MARKER FIRST, THEN SCAN. This ordering is the cost contract: in steady
	# state the whole check is one stat, and the scan only runs when the answer
	# could change something. Scanning first would be simpler and would keep the
	# marker exact, but it would pay the scan on every Stop forever to tidy a
	# file no consumer reads.
	#
	# The price is that clearing lags by up to one TTL: a repository whose
	# patterns start matching again keeps its marker until the next due check
	# observes the match. That is harmless -- the marker only ever suppresses
	# emission, and a matching repository has nothing to emit.
	local marker hash
	marker=$(onlooker_watch_marker_path "$project_key" "$config_key")
	hash=$(onlooker_watch_patterns_hash "$patterns_json") || return 0
	onlooker_watch_marker_due "$marker" "$hash" "$ttl_hours" || return 0

	local scan
	case "$mode" in
		files) scan=$(_onlooker_watch_scan_files "$root" "$patterns_json") ;;
		dirs)  scan=$(_onlooker_watch_scan_dirs  "$root" "$patterns_json") ;;
	esac

	local matched="${scan%% *}" scanned="${scan##* }"

	# A match is the recovery edge: drop the marker so a later re-break speaks.
	if [[ "$matched" != "0" ]]; then
		onlooker_watch_marker_clear "$marker"
		return 0
	fi

	local payload
	payload=$(jq -cn \
		--arg p "$plugin" --arg k "$config_key" --arg pk "$project_key" \
		--argjson pat "$patterns_json" --argjson n "$scanned" \
		'{plugin: $p, config_key: $k, patterns: $pat,
		  candidates_scanned: $n, project_key: $pk}' 2>/dev/null) || return 0

	if command -v "$emit_fn" >/dev/null 2>&1 || declare -F "$emit_fn" >/dev/null 2>&1; then
		"$emit_fn" "onlooker.watch.unmatched" "$payload" || true
		onlooker_watch_marker_write "$marker" "$hash" || true
	fi

	return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats`
Expected: PASS, 27 tests

- [ ] **Step 5: Verify the mutation test actually bites**

Temporarily change the suppression line `onlooker_watch_marker_due "$marker" "$hash" "$ttl_hours" || return 0` to `true`, then run:

Run: `ONLOOKER_VALIDATE=1 bats test/bats/watch-unmatched.bats -f "suppressed by the marker"`
Expected: FAIL. If it passes, the test is decoration — fix it before continuing. Revert the change and confirm PASS again.

- [ ] **Step 6: Commit**

Use `/commit`, staging `scripts/lib/watch-unmatched.sh` and `test/bats/watch-unmatched.bats`.

---

### Task 5: Vendor the lib into both plugins

**Files:**
- Modify: `scripts/sync-shared-libs.sh:29`
- Generated: `plugins/*/scripts/lib/watch-unmatched.sh`

**Interfaces:**
- Consumes: the finished lib from Task 4
- Produces: a vendored copy in every plugin, so hooks can source it from `$PLUGIN_ROOT/scripts/lib/`

- [ ] **Step 1: Add the lib to `SHARED_LIBS`**

In `scripts/sync-shared-libs.sh`, change line 29 from:

```bash
SHARED_LIBS=(config-loader.sh hook-health.sh substrate-resolve.sh)
```

to:

```bash
SHARED_LIBS=(config-loader.sh hook-health.sh substrate-resolve.sh watch-unmatched.sh)
```

- [ ] **Step 2: Run the sync**

Run: `scripts/sync-shared-libs.sh`
Expected: writes `watch-unmatched.sh` into every `plugins/*/scripts/lib/`

- [ ] **Step 3: Verify no drift and that vendoring coverage picked it up**

Run: `scripts/sync-shared-libs.sh --check && ONLOOKER_VALIDATE=1 bats test/bats/shared-lib-vendoring.bats test/bats/config-lib-self-locating.bats`
Expected: no drift reported; both bats files PASS. `shared-lib-vendoring.bats` reads `SHARED_LIBS` straight out of the sync script, so the new lib is guarded automatically.

- [ ] **Step 4: Commit**

Use `/commit`, staging `scripts/sync-shared-libs.sh` and every generated `plugins/*/scripts/lib/watch-unmatched.sh`.

---

### Task 6: Echo call site

**Files:**
- Modify: `plugins/echo/scripts/hooks/echo-stop-gate.sh` (source near line 30; hoist pattern load from 123–131 up to just after line 85; retire the stale comment at 162)
- Create: `test/bats/echo-watch-unmatched.bats`

**Interfaces:**
- Consumes: `onlooker_watch_unmatched_check` (Task 4), vendored copy (Task 5)
- Produces: `onlooker.watch.unmatched` with `plugin: "echo"`, `config_key: "echo.watch_paths"`

**Note on placement:** there is no `test/bats/echo-stop-gate.bats`. Echo's stop-gate coverage is spread across `echo-stop-hook.bats`, `echo-skip-event.bats`, `echo-stop-gate-worktree.bats`, `echo-stop-gate-content-skip.bats` and `echo-stop-gate-concurrent.bats`. This adds a dedicated file rather than extending one of those, so the new concern does not inherit another file's fixture assumptions. The `setup()` below is modeled on the real one in `echo-skip-event.bats:18`.

- [ ] **Step 1: Write the failing test**

Create `test/bats/echo-watch-unmatched.bats`:

```bash
#!/usr/bin/env bats
# Echo reporting that its watch_paths can never match (ecosystem-449.21).
#
# Distinct from echo.suite.skipped, which says "nothing to do this turn". This
# says "these patterns cannot match anything here, ever" -- a property of repo
# plus config rather than of the turn.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/echo-stop-gate.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${REPO}/agents" "${REPO}/.claude"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	printf '# Agent\n' >"${REPO}/agents/reviewer.md"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm init
}

_settings() {
	printf '%s\n' "$1" >"${REPO}/.claude/settings.json"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm settings
}

_run_hook() {
	run bash -c "printf '%s' '$(jq -cn --arg cwd "$REPO" \
		'{cwd: $cwd, session_id: "sess-watch", hook_event_name: "Stop"}')' | '$HOOK'"
}

@test "reports when watch_paths can never match in this repo" {
	_settings '{"echo":{"watch_paths":["nowhere/*/never.md"]}}'
	_run_hook
	grep '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.plugin == "echo"
		         and .payload.config_key == "echo.watch_paths"
		         and .payload.patterns == ["nowhere/*/never.md"]' >/dev/null
}

# PLACEMENT CHECK. The hook returns at line 117 when nothing changed, before
# patterns are even loaded. A dead watcher in a quiet repo is exactly the case
# that must still report, so the check has to sit above that gate.
@test "reports even when the tree is clean and nothing changed" {
	_settings '{"echo":{"watch_paths":["nowhere/*/never.md"]}}'
	[ -z "$(git -C "$REPO" status --porcelain)" ]
	_run_hook
	grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

# PLACEMENT CHECK. `claude` is not on PATH in this suite, and the hook exits at
# line 87 when it is missing. The check must sit above that guard too: it needs
# only git and jq, and a user without claude installed still deserves to learn
# their config is dead.
@test "reports without claude on PATH" {
	_settings '{"echo":{"watch_paths":["nowhere/*/never.md"]}}'
	run command -v claude
	[ "$status" -ne 0 ]
	_run_hook
	grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "stays quiet when watch_paths match real files" {
	_settings '{"echo":{"watch_paths":["agents/*.md"]}}'
	_run_hook
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "emits once across two runs, not once per Stop" {
	_settings '{"echo":{"watch_paths":["nowhere/*/never.md"]}}'
	_run_hook
	_run_hook
	count=$(grep -c '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG")
	[[ "$count" == "1" ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/echo-watch-unmatched.bats`
Expected: FAIL — no `onlooker.watch.unmatched` line in the log

- [ ] **Step 3: Modify the hook**

Source the lib alongside the other libs near line 30:

```bash
source "$PLUGIN_ROOT/scripts/lib/watch-unmatched.sh"
```

Move the `WATCH_PATTERNS` / `EXCLUDE_PATTERNS` load (currently lines 123–131) up to sit immediately after the `PROJECT_KEY` validation at line 85–86 — that is, **above** the `command -v claude` guard at line 87, not merely above the `ALL_CHANGED` gate at 117. Then insert the check directly after the hoisted pattern load:

```bash
# Whether watch_paths can match anything in this repo AT ALL is a property of
# repo plus config, not of this turn. Hence its position: above the claude guard
# at line 87 and the changed-files gate at line 117, both of which return early
# in exactly the quiet, tool-less repos where a dead watcher is least likely to
# be noticed (ecosystem-449.21). The check needs only git and jq, and the helper
# guards on jq itself.
WATCH_PATTERNS_JSON=$(printf '%s\n' "${WATCH_PATTERNS[@]}" \
	| jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null) \
	|| WATCH_PATTERNS_JSON="[]"

onlooker_watch_unmatched_check \
	--plugin echo \
	--config-key echo.watch_paths \
	--root "$WORKTREE_ROOT" \
	--project-key "$PROJECT_KEY" \
	--mode files \
	--patterns-json "$WATCH_PATTERNS_JSON" \
	--emit-fn echo_emit_event
```

Then replace the stale half-sentence in the comment at line 162 — "and distinct from a misconfigured watcher watching nothing (ecosystem-449.21), which this cannot yet tell apart" — with a note that the condition is now reported separately as `onlooker.watch.unmatched`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/echo-watch-unmatched.bats`
Expected: PASS, 5 tests

Then confirm the hoist broke nothing in the sibling suites:

Run: `ONLOOKER_VALIDATE=1 bats test/bats/echo-stop-hook.bats test/bats/echo-skip-event.bats test/bats/echo-stop-gate-worktree.bats test/bats/echo-stop-gate-content-skip.bats test/bats/echo-stop-gate-concurrent.bats`
Expected: PASS

- [ ] **Step 5: Commit**

Use `/commit`, staging `plugins/echo/scripts/hooks/echo-stop-gate.sh` and `test/bats/echo-stop-gate.bats`.

---

### Task 7: Cartographer call site

**Files:**
- Modify: `plugins/cartographer/scripts/hooks/cartographer-session-start.sh` (source near line 33; check inserted after `STATE_FILE` at line 54, before `INTERVAL_HOURS` at line 57)
- Create: `test/bats/cartographer-session-start.bats`

**Interfaces:**
- Consumes: `onlooker_watch_unmatched_check` (Task 4), vendored copy (Task 5)
- Produces: `onlooker.watch.unmatched` with `plugin: "cartographer"`, `config_key: "cartographer.undocumented_entity.globs"`

**Note:** no test file drives `cartographer-session-start.sh` today — only `hook-health.bats` and `hook-reentrancy-guard.bats` reference it, and neither exercises its behavior. This creates the file. The `setup()` below is modeled on the real one in `cartographer-run-audit.bats:19`.

Every test seeds `last_audit_at` to now so the hook exits at the interval gate and never spawns a detached audit. That keeps the suite from shelling out to `claude`, and it doubles as the placement proof: the check has to fire above a gate that returns.

- [ ] **Step 1: Write the failing test**

Create `test/bats/cartographer-session-start.bats`:

```bash
#!/usr/bin/env bats
# Cartographer reporting that its undocumented_entity globs can never match
# (ecosystem-449.21).
#
# Nothing drove this hook before this file. Every test below pins last_audit_at
# to now, so the interval gate returns and no detached audit is spawned -- which
# is also the condition the check most needs to survive, since a throttled audit
# is exactly when a dead config would otherwise stay invisible.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/cartographer-session-start.sh"

	FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${FIXTURE_REPO}/.claude"
	git -C "$FIXTURE_REPO" init -q
	git -C "$FIXTURE_REPO" config user.email test@example.com
	git -C "$FIXTURE_REPO" config user.name test
	git -C "$FIXTURE_REPO" remote add origin git@github.com:org/fixture.git
	printf '# Root\n' >"${FIXTURE_REPO}/CLAUDE.md"
	git -C "$FIXTURE_REPO" add -A
	git -C "$FIXTURE_REPO" commit -qm init

	source "${PLUGIN_ROOT}/scripts/lib/cartographer-project-key.sh"
	PROJECT_KEY=$(cartographer_project_key "$FIXTURE_REPO")
	mkdir -p "${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}"
	# Interval gate returns: no audit is ever spawned by these tests.
	date +%s >"${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}/last_audit_at"
}

_settings() {
	printf '%s\n' "$1" >"${FIXTURE_REPO}/.claude/settings.json"
}

_run_hook() {
	run bash -c "printf '%s' '$(jq -cn --arg cwd "$FIXTURE_REPO" \
		'{cwd: $cwd, session_id: "sess-carto", hook_event_name: "SessionStart", source: "startup"}')' | '$HOOK'"
}

@test "reports when undocumented_entity globs can never match" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	grep '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.plugin == "cartographer"
		         and .payload.config_key == "cartographer.undocumented_entity.globs"
		         and .payload.patterns == ["nowhere/*/"]' >/dev/null
}

# PLACEMENT CHECK. last_audit_at is pinned to now in setup, so the hook returns
# at the interval gate. The report must precede that return.
@test "reports even though the audit interval has not elapsed" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	[ "$status" -eq 0 ]
	grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "stays quiet when globs match real directories" {
	mkdir -p "${FIXTURE_REPO}/plugins/demo"
	_settings '{"cartographer":{"undocumented_entity":{"globs":["plugins/*/"]}}}'
	_run_hook
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

# The divergence from echo, exercised end to end: an untracked directory is a
# match for cartographer because its matcher expands against the filesystem.
@test "an untracked directory counts as a match" {
	mkdir -p "${FIXTURE_REPO}/untracked/child"
	printf 'untracked/\n' >"${FIXTURE_REPO}/.gitignore"
	_settings '{"cartographer":{"undocumented_entity":{"globs":["untracked/*/"]}}}'
	_run_hook
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "emits once across two sessions, not once per SessionStart" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	_run_hook
	count=$(grep -c '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG")
	[[ "$count" == "1" ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/cartographer-session-start.bats`
Expected: FAIL — no `onlooker.watch.unmatched` line in the log

- [ ] **Step 3: Modify the hook**

Source the lib and the events lib alongside the others near line 33. The hook does not currently source `cartographer-events.sh`, so `cartographer_emit_event` would otherwise be undefined:

```bash
source "$PLUGIN_ROOT/scripts/lib/cartographer-events.sh"
source "$PLUGIN_ROOT/scripts/lib/watch-unmatched.sh"
```

Insert after `STATE_FILE` is assigned (line 54) and before `INTERVAL_HOURS` is read (line 57). That position matters in both directions: it is below line 49, where the hook establishes `ONLOOKER_DIR` (the marker path needs it), and above the interval gate that returns.

```bash
# Before the interval gate on purpose. Whether these globs can match anything is
# a property of repo plus config, and a throttled or lock-contended audit is
# exactly when a dead config would otherwise stay invisible (ecosystem-449.21).
#
# REPO_ROOT, not a worktree root: this must mirror the root run-audit.sh hands
# to the matcher, or the check disagrees with the thing it describes.
onlooker_watch_unmatched_check \
	--plugin cartographer \
	--config-key cartographer.undocumented_entity.globs \
	--root "$REPO_ROOT" \
	--project-key "$PROJECT_KEY" \
	--mode dirs \
	--patterns-json "$(cartographer_config_undocumented_globs)" \
	--emit-fn cartographer_emit_event
```

`cartographer_config_undocumented_globs` (`cartographer-config.sh:110`) already returns a JSON array, so no conversion is needed here — unlike echo, whose accessor returns newline-delimited patterns.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/cartographer-session-start.bats`
Expected: PASS, 5 tests

Then confirm the new `source` lines did not disturb the hooks' own health registration:

Run: `ONLOOKER_VALIDATE=1 bats test/bats/hook-health.bats test/bats/hook-reentrancy-guard.bats`
Expected: PASS

- [ ] **Step 5: Commit**

Use `/commit`, staging `plugins/cartographer/scripts/hooks/cartographer-session-start.sh` and `test/bats/cartographer-session-start.bats`.

---

### Task 8: Bus coverage and full verification

**Files:**
- Modify: `test/bus-coverage.json`

**Interfaces:**
- Consumes: emissions from Tasks 6 and 7
- Produces: a green `npm run test:ci`

- [ ] **Step 1: Move the type from `excluded` to `expected`**

`onlooker.watch.unmatched` is already present under `excluded`, with the reason "registered in @onlooker-community/schema 2.18.0 for ecosystem-449.21, but no plugin emits it yet … Move to expected with that change, not before." This is that change.

Delete the `onlooker.watch.unmatched` key from the `excluded` object, and add the string `"onlooker.watch.unmatched"` to the `expected` array, keeping the array's existing sort order.

- [ ] **Step 2: Run the bus coverage check**

Run: `npm run test:bus`
Expected: `check-bus-coverage: ok (N emission(s))` with N greater than the 622 recorded before this work

- [ ] **Step 3: Run the full suite**

Run each leg separately, with no pipe between the command and `$?` — a pipe hides the exit code:

```bash
npm run test:bats;      echo "BATS_EXIT=$?"
npm run test:schema;    echo "SCHEMA_EXIT=$?"
npm run test:bus;       echo "BUS_EXIT=$?"
npm run test:shellcheck; echo "SHELLCHECK_EXIT=$?"
npm run lint:check;     echo "LINT_EXIT=$?"
```

Expected: every exit code 0, and `test:bats` reporting `0 not ok`.

- [ ] **Step 4: Reproduce any flake serially before touching it**

If a bats test fails under `-j 4`, run `npm run test:bats:serial` FIRST. A test that depended on an idle host was already wrong, and parallelism exposes it. Do not lower `-j` — that hides the dependency rather than fixing it.

- [ ] **Step 5: Commit**

Use `/commit`, staging `test/bus-coverage.json`.

- [ ] **Step 6: Open the PR**

Use the `/git-workflow:pr` skill from `feat/watch-unmatched`. Reference `ecosystem-449.21` in the body. Wait for CI to pass before merging.

Remember that local green does not imply CI green: two CI-only failures in the 2026-09-12 session were both macOS-versus-Linux divergences. The portable surfaces in this change are `shasum`/`sha256sum` and `python3` date math, both of which follow existing prior art in `onlooker-project-key.sh` and `test/helpers/setup.bash`.

- [ ] **Step 7: Close the bead**

Run `bd close ecosystem-449.21` with a close reason recording what shipped. Use `--append-notes`, never `--notes`, for any note added first — `--notes` destroys existing notes and embedded mode has no recovery path.
