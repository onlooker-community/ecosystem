# Project-Key Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse 13 divergent `*-project-key.sh` libs into one vendored, drift-guarded lib
that also exports the project key and its derivation basis for the event emitter to read.

**Architecture:** `scripts/lib/onlooker-project-key.sh` becomes the single implementation, gains
`onlooker_worktree_root` (needed by four plugins) and `onlooker_project_resolve` (sets and exports
`ONLOOKER_PROJECT_KEY` / `ONLOOKER_PROJECT_BASIS`), and is registered in `ON_DEMAND_LIBS` so
`sync-shared-libs.sh` keeps every vendored copy byte-identical. `onlooker_project_key` becomes a
thin wrapper over `onlooker_project_resolve`, so all ~129 existing call sites populate the
emitter's env vars with no further change. The three genuinely plugin-specific helpers currently
living in those files move to plugin-local libs first, so the deletions are safe.

**Tech Stack:** bash (3.2-compatible call sites, 4+ required to *run* errexit tests), bats-core,
shellcheck, `scripts/sync-shared-libs.sh`.

**Spec:** `docs/superpowers/specs/2026-10-10-envelope-project-dimension-design.md`
**Tracked by:** [ONL-129](https://linear.app/onlooker/issue/ONL-129) (`ecosystem-hscz3o`)
**Branch:** `meagan/onl-129-envelope-project-dimension`

## Global Constraints

- **This unit has no schema dependency.** It can land before schema 2.28.0 publishes. Do not add
  envelope fields or new event types here — that is Unit 3.
- **`ON_DEMAND_LIBS`, not `SHARED_LIBS`.** 12 of 16 plugins use the lib; compass, echo, governor,
  and warden do not. `sync-shared-libs.sh`'s own header states the policy: `SHARED_LIBS` land in
  every plugin because every hook uses them, `ON_DEMAND_LIBS` only where a copy already exists,
  "because ... a copy nobody sources is noise that still has to be kept in sync."
- **`ON_DEMAND_LIBS=(...)` must stay on ONE line.** `test/bats/shared-lib-vendoring.bats` parses it
  with `sed -n 's/^ON_DEMAND_LIBS=(\(.*\))$/\1/p'`. A wrapped array silently matches nothing and
  every guard goes vacuous.
- **On-demand libs are never created by the sync script**, only refreshed where a copy exists
  (`[[ "$on_demand" -eq 1 && ! -f "$dest" ]] && continue`). The first copy into each plugin is by
  hand.
- **Vendored libs must self-locate from `${BASH_SOURCE[0]}`**, never from a caller-supplied
  `$PLUGIN_ROOT` and never via a path that climbs to the repo root. This lib defines functions and
  sources nothing, so there is nothing to resolve — but do not add a `source` line to it.
- **Never run bare `bats`.** It skips schema validation, so negative schema assertions pass
  locally and fail in CI. Use `npm run test:bats` for the whole suite, and
  `scripts/test/run-bats.sh test/bats/<file>.bats` for one file. Do **not** use
  `npm run test:bats -- <file>`: the npm script already passes `test/bats`, so the file is
  appended as a *second* target and bats runs the entire suite plus that file. The wrapper is what
  sets `ONLOOKER_VALIDATE=1`, which is the reason bare `bats` is forbidden.
- **Never run two bats suites concurrently in this checkout.** `run-bats.sh` opens with `rm -rf`
  on a shared report path and every run appends to the same `emissions.jsonl`; two concurrent runs
  clobber each other and the coverage gate then reports a wall of "expected type never emitted"
  that reads exactly like a real regression (see the script's header and ecosystem-0bh).
- **`git -C <path>`** — scope matters, and the loose wording of this rule already produced one
  near-miss finding. Do not use it in shell commands *you* run: the flag defeats the
  allowed-tools patterns and forces a needless approval prompt. It is correct and expected
  *inside* library code and bats bodies that must act on a caller-supplied directory.
  `onlooker-project-key.sh`'s three pre-existing functions all use `git -C "$cwd"`, and so does
  every plugin lib Task 4 touches. Reviewers: `git -C` in those files is not a finding.
- **American English** in all comments, commit messages, and docs.
- **Commits route through `/git-workflow:commit`.** Do not craft `git commit -m` ad hoc.
- Event types follow `<plugin>.<noun>.<verb>`; ULIDs not UUIDs; config defaults in `config.json`.

---

## File Structure

**Canonical lib (modified)**
- `scripts/lib/onlooker-project-key.sh` — the one implementation. Gains `onlooker_worktree_root`
  and `onlooker_project_resolve`; `onlooker_project_key` becomes a wrapper.

**Sync registration (modified)**
- `scripts/sync-shared-libs.sh:30` — `ON_DEMAND_LIBS` gains `onlooker-project-key.sh`.

**New plugin-local libs (created)** — these hold helpers that are *not* project-key logic and must
survive the deletions:
- `plugins/counsel/scripts/lib/counsel-project-dir.sh` — `counsel_project_dir`
- `plugins/scribe/scripts/lib/scribe-project-dir.sh` — `scribe_project_dir`
- `plugins/inspector/scripts/lib/inspector-canonical-path.sh` — `inspector_canonical_path`

**Vendored copies (created, 12)**
- `plugins/{archivist,assayer,bursar,cartographer,counsel,curator,historian,inspector,librarian,lineage,scribe,tribunal}/scripts/lib/onlooker-project-key.sh`

**Deleted (12)**
- `plugins/<p>/scripts/lib/<p>-project-key.sh` for those same 12 plugins.

**Tests**
- `test/bats/onlooker-project-key.bats` — extended; becomes the single derivation suite.
- Deleted: `test/bats/{archivist,assayer,bursar,counsel,inspector,lineage,scribe}-project-key.bats`
  and any other `*-project-key.bats` for a deleted lib. Confirm the exact set with
  `ls test/bats/*-project-key.bats` before removing.

---

## Task 1: Canonical lib gains `onlooker_worktree_root`

Four plugins (archivist, lineage, scribe, tribunal) define `<p>_worktree_root`. The canonical does
not, so deleting their libs would drop it. It is the documented counterpart to the identity
function: `onlooker_project_repo_root` resolves a linked worktree to its *parent* for identity,
while this resolves the tree the session is actually in. Conflating them is `ecosystem-449.37` /
`ecosystem-449.33`.

**Files:**
- Modify: `scripts/lib/onlooker-project-key.sh`
- Test: `test/bats/onlooker-project-key.bats`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `onlooker_worktree_root <cwd>` → prints the absolute path of the working tree
  containing `<cwd>`, or empty string when `<cwd>` is absent, not a directory, or not in a repo.
  Always returns 0.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/onlooker-project-key.bats`:

```bash
@test "worktree_root resolves a linked worktree to ITSELF, not its parent" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	git -C "$REPO" commit -q --allow-empty -m "base"
	local wt="${BATS_TEST_TMPDIR}/wt-self"
	git -C "$REPO" worktree add -q -b wt-self-branch "$wt" >/dev/null 2>&1

	# Identity collapses the two; location must not.
	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$wt")" ]
	[ "$(onlooker_worktree_root "$wt")" != "$(onlooker_worktree_root "$REPO")" ]
	[ "$(onlooker_worktree_root "$wt")" = "$(cd "$wt" && pwd -P)" ]
}

@test "worktree_root returns the toplevel for an ordinary checkout" {
	[ "$(onlooker_worktree_root "$REPO")" = "$(cd "$REPO" && pwd -P)" ]
}

@test "worktree_root returns empty outside a git repo" {
	local plain="${BATS_TEST_TMPDIR}/plain-wt"
	mkdir -p "$plain"
	[ -z "$(onlooker_worktree_root "$plain")" ]
}

@test "worktree_root returns empty for an absent or non-directory argument" {
	[ -z "$(onlooker_worktree_root "")" ]
	[ -z "$(onlooker_worktree_root "${BATS_TEST_TMPDIR}/does-not-exist")" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test/run-bats.sh test/bats/onlooker-project-key.bats`
Expected: FAIL — `onlooker_worktree_root: command not found`.

- [ ] **Step 3: Add the function**

Append to `scripts/lib/onlooker-project-key.sh`, after `onlooker_project_repo_root`:

```bash
# Resolve the toplevel of the working tree the session is actually in.
#
# Distinct from onlooker_project_repo_root, which deliberately resolves a linked
# worktree to its parent checkout so both share a project key. That is the right
# answer for identity and the wrong one for git: a worktree's files sit beside
# the parent, not beneath it, so anything that reads or diffs the tree wants
# this root instead (ecosystem-449.37, mirroring lineage's ecosystem-449.33).
onlooker_worktree_root() {
	local cwd="${1:-}"
	[[ -z "$cwd" || ! -d "$cwd" ]] && return 0

	local toplevel
	toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 0
	[[ -z "$toplevel" ]] && return 0

	(cd "$toplevel" 2>/dev/null && pwd -P) || printf '%s' "$toplevel"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test/run-bats.sh test/bats/onlooker-project-key.bats`
Expected: PASS, all tests including the eight pre-existing ones.

- [ ] **Step 5: Shellcheck the lib**

Run: `shellcheck -S error -x scripts/lib/onlooker-project-key.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

Use `/git-workflow:commit` with: stage only `scripts/lib/onlooker-project-key.sh` and
`test/bats/onlooker-project-key.bats`. Subject along the lines of
`feat(substrate): add worktree_root to the canonical project-key lib`, body explaining that four
plugins define it today and the consolidation needs it canonical before their copies go.

---

## Task 2: Canonical lib gains `onlooker_project_resolve`

The emitter needs both the key and its basis without reimplementing derivation in JavaScript. A
JS copy that drifted from the bash one would silently stop matching the on-disk directory names,
which is the whole point of the field.

Making `onlooker_project_key` a wrapper over the resolver has a deliberate consequence: **every one
of the ~129 existing call sites begins exporting `ONLOOKER_PROJECT_KEY` and
`ONLOOKER_PROJECT_BASIS` as a side effect**, so the emitter gets populated in Unit 3 with no
further call-site changes.

**Files:**
- Modify: `scripts/lib/onlooker-project-key.sh`
- Test: `test/bats/onlooker-project-key.bats`

**Interfaces:**
- Consumes: `_onlooker_sha256_first12`, `onlooker_project_remote_url`,
  `onlooker_project_repo_root` (all already in the lib).
- Produces:
  - `onlooker_project_resolve <cwd>` → sets and exports `ONLOOKER_PROJECT_KEY` (12 hex or empty)
    and `ONLOOKER_PROJECT_BASIS` (`remote`, `root`, or empty). Prints nothing. Always returns 0.
  - `onlooker_project_key <cwd>` → unchanged contract: prints the key or empty string. Now also
    has the export side effect above.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/onlooker-project-key.bats`:

```bash
@test "resolve exports basis=remote for a repo with an origin" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_BASIS" = "remote" ]
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "resolve exports basis=root for a repo with no origin" {
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_BASIS" = "root" ]
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "resolve exports both empty outside a git repo" {
	local plain="${BATS_TEST_TMPDIR}/plain-resolve"
	mkdir -p "$plain"
	onlooker_project_resolve "$plain"
	[ -z "$ONLOOKER_PROJECT_KEY" ]
	[ -z "$ONLOOKER_PROJECT_BASIS" ]
}

@test "resolve clears a stale value rather than leaving the previous one" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ -n "$ONLOOKER_PROJECT_KEY" ]

	local plain="${BATS_TEST_TMPDIR}/plain-clear"
	mkdir -p "$plain"
	onlooker_project_resolve "$plain"
	[ -z "$ONLOOKER_PROJECT_KEY" ]
	[ -z "$ONLOOKER_PROJECT_BASIS" ]
}

@test "resolve exports the variables to a child process" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	run env
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "^ONLOOKER_PROJECT_BASIS=remote$"
}

@test "the key from resolve matches the key from the wrapper" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_KEY" = "$(onlooker_project_key "$REPO")" ]
}

@test "the wrapper populates the env vars as a side effect" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	unset ONLOOKER_PROJECT_KEY ONLOOKER_PROJECT_BASIS
	onlooker_project_key "$REPO" >/dev/null
	[ "$ONLOOKER_PROJECT_BASIS" = "remote" ]
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test/run-bats.sh test/bats/onlooker-project-key.bats`
Expected: FAIL — `onlooker_project_resolve: command not found`.

- [ ] **Step 3: Add the resolver and rewrite the wrapper**

In `scripts/lib/onlooker-project-key.sh`, replace the existing `onlooker_project_key` function
(the whole block from `onlooker_project_key() {` to its closing `}`) with:

```bash
# Resolve key and basis in ONE git pass, exporting both.
#
# The emitter reads these two variables rather than taking arguments or
# deriving the key in JavaScript. A JS reimplementation that drifted from this
# one would silently stop matching the on-disk directory names under
# $ONLOOKER_DIR/<plugin>/<key>/, and that match is the entire point of the
# envelope field.
#
# Both variables are cleared first, so a second call for a non-repo directory
# does not leave the previous repo's key standing.
onlooker_project_resolve() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && cwd="$(pwd)"

	ONLOOKER_PROJECT_KEY=""
	ONLOOKER_PROJECT_BASIS=""
	export ONLOOKER_PROJECT_KEY ONLOOKER_PROJECT_BASIS

	local remote
	remote=$(onlooker_project_remote_url "$cwd")
	if [[ -n "$remote" ]]; then
		ONLOOKER_PROJECT_KEY=$(_onlooker_sha256_first12 "remote:$remote")
		ONLOOKER_PROJECT_BASIS="remote"
		return 0
	fi

	local root
	root=$(onlooker_project_repo_root "$cwd")
	if [[ -n "$root" ]]; then
		ONLOOKER_PROJECT_KEY=$(_onlooker_sha256_first12 "root:$root")
		ONLOOKER_PROJECT_BASIS="root"
		return 0
	fi

	return 0
}

# Compute the project key for the given cwd. Prints the key, or empty string.
#
# A thin wrapper over onlooker_project_resolve, which means every caller also
# populates ONLOOKER_PROJECT_KEY and ONLOOKER_PROJECT_BASIS. That is deliberate:
# it is what lets the emitter pick the dimension up without touching any of the
# call sites. Callers passing a directory other than the session's cwd should
# know they are setting the session-visible value too.
onlooker_project_key() {
	onlooker_project_resolve "${1:-}"
	printf '%s' "$ONLOOKER_PROJECT_KEY"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test/run-bats.sh test/bats/onlooker-project-key.bats`
Expected: PASS. The eight original tests must still pass unchanged — the wrapper's printed
contract is identical.

- [ ] **Step 5: Shellcheck**

Run: `shellcheck -S error -x scripts/lib/onlooker-project-key.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

Use `/git-workflow:commit`, staging the lib and its bats file. Explain in the body that the
wrapper's export side effect is what lets the emitter read the dimension without changing call
sites.

---

## Task 3: Move the three plugin-specific helpers out

These three live in `*-project-key.sh` today but are not project-key logic. They must land in their
own plugin-local libs *before* Task 4 deletes the files, or their callers break.

**Files:**
- Create: `plugins/counsel/scripts/lib/counsel-project-dir.sh`
- Create: `plugins/scribe/scripts/lib/scribe-project-dir.sh`
- Create: `plugins/inspector/scripts/lib/inspector-canonical-path.sh`
- Modify: every file under `plugins/{counsel,scribe,inspector}/scripts` that sources the old lib
  for these functions.

**Interfaces:**
- Produces, unchanged signatures:
  - `counsel_project_dir <project_key>` → prints `${ONLOOKER_DIR:-$HOME/.onlooker}/counsel/<key>/briefs`; returns 1 on empty key.
  - `scribe_project_dir <project_key>` → prints `${ONLOOKER_DIR:-$HOME/.onlooker}/scribe/<key>`; returns 1 on empty key.
  - `inspector_canonical_path <path>` → prints the realpath, falling back through `readlink -f`,
    `cd && pwd -P`, then the input unchanged; empty input prints nothing.

- [ ] **Step 1: Find every caller**

Run:

```bash
grep -rn "counsel_project_dir\|scribe_project_dir\|inspector_canonical_path" \
  plugins/ test/ --include="*.sh" --include="*.bats"
```

Record the list. Every file that calls one of these must source its new lib.

- [ ] **Step 2: Create the three libs**

`plugins/counsel/scripts/lib/counsel-project-dir.sh`:

```bash
#!/usr/bin/env bash
# Where counsel keeps a project's briefs.
#
# Split out of counsel-project-key.sh when that file was replaced by the
# vendored canonical onlooker-project-key.sh: this embeds the plugin name and a
# subpath, so it is counsel's, not the substrate's.

counsel_project_dir() {
	local project_key="${1:-}"
	[[ -z "$project_key" ]] && return 1
	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	printf '%s' "${onlooker_dir}/counsel/${project_key}/briefs"
}
```

`plugins/scribe/scripts/lib/scribe-project-dir.sh`:

```bash
#!/usr/bin/env bash
# Where scribe keeps a project's artifacts.
#
# Split out of scribe-project-key.sh when that file was replaced by the
# vendored canonical onlooker-project-key.sh: this embeds the plugin name, so it
# is scribe's, not the substrate's.

scribe_project_dir() {
	local project_key="${1:-}"
	[[ -z "$project_key" ]] && return 1
	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	printf '%s' "${onlooker_dir}/scribe/${project_key}"
}
```

`plugins/inspector/scripts/lib/inspector-canonical-path.sh`:

```bash
#!/usr/bin/env bash
# Path normalization for inspector.
#
# Split out of inspector-project-key.sh when that file was replaced by the
# vendored canonical onlooker-project-key.sh: this is a path helper, not
# project-key derivation.

inspector_canonical_path() {
	local p="${1:-}"
	[[ -z "$p" ]] && return 0

	local out
	if out=$(realpath "$p" 2>/dev/null) && [[ -n "$out" ]]; then
		printf '%s' "$out"
		return 0
	fi
	# BSD readlink has no -f, so this silently no-ops there and falls through.
	if out=$(readlink -f "$p" 2>/dev/null) && [[ -n "$out" ]]; then
		printf '%s' "$out"
		return 0
	fi

	if [[ -d "$p" ]]; then
		out=$(cd "$p" 2>/dev/null && pwd -P) && [[ -n "$out" ]] && {
			printf '%s' "$out"
			return 0
		}
	else
		local dir base
		dir=$(dirname "$p")
		base=$(basename "$p")
		out=$(cd "$dir" 2>/dev/null && pwd -P) && [[ -n "$out" ]] && {
			printf '%s/%s' "$out" "$base"
			return 0
		}
	fi

	# Nothing resolved it — hand back the input rather than an empty string,
	# so a caller comparing two of these still compares like with like.
	printf '%s' "$p"
}
```

- [ ] **Step 3: Remove each moved function from its old host file**

Delete the function body from `plugins/counsel/scripts/lib/counsel-project-key.sh`,
`plugins/scribe/scripts/lib/scribe-project-key.sh`, and
`plugins/inspector/scripts/lib/inspector-project-key.sh` in the same commit that creates the new
libs. Do not leave it defined in two places even briefly: both files are sourced together, so the
duplicate would be a real redefinition, and a reviewer seeing two identical bodies is seeing a
genuine defect rather than a staged move.

The old `<plugin>-project-key.sh` files stay for now — they still define the project-key functions
until Task 4 deletes them. Only the moved helper leaves.

Verify each old file no longer defines it:

```bash
grep -c "counsel_project_dir" plugins/counsel/scripts/lib/counsel-project-key.sh
grep -c "scribe_project_dir" plugins/scribe/scripts/lib/scribe-project-key.sh
grep -c "inspector_canonical_path" plugins/inspector/scripts/lib/inspector-project-key.sh
```
Expected: `0` from all three.

- [ ] **Step 4: Add a source line in every caller found in Step 1**

For each caller, add alongside its existing project-key source line, matching that file's existing
brace style:

```bash
# shellcheck source=../lib/counsel-project-dir.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-project-dir.sh"
```

Use the plugin's own lib name. `PLUGIN_ROOT` is the correct variable here — these are
plugin-local libs sourced from the plugin's own tree, which is the pattern
`shared-lib-vendoring.bats`'s catch-all test greps for, and it will require the file to exist.

- [ ] **Step 5: Verify the helpers still resolve**

Run: `scripts/test/run-bats.sh test/bats/counsel-brief.bats`
Run: `npm run test:shellcheck`
Expected: PASS, exit 0. If any plugin has no test covering a moved helper, confirm by hand:

```bash
bash -c 'PLUGIN_ROOT=plugins/counsel; source "$PLUGIN_ROOT/scripts/lib/counsel-project-dir.sh"; counsel_project_dir abc123def456'
```
Expected output: `<ONLOOKER_DIR>/counsel/abc123def456/briefs`

- [ ] **Step 6: Commit**

Use `/git-workflow:commit`, staging the three new libs, the three trimmed old libs, and their
callers. Body: these are not project-key logic and had to move before the consolidation could
delete their host files.

---

## Task 4: Register and vendor the canonical; migrate all 12 plugins

This must be **atomic**: a plugin cannot have its old lib deleted while still sourcing it. Do all
twelve in one commit.

**Files:**
- Modify: `scripts/sync-shared-libs.sh:30`
- Create: 12 × `plugins/<p>/scripts/lib/onlooker-project-key.sh`
- Delete: 12 × `plugins/<p>/scripts/lib/<p>-project-key.sh`
- Modify: the 22 source lines and ~129 call sites across `plugins/` and `test/`

**Interfaces:**
- Consumes: `onlooker_project_key`, `onlooker_project_resolve`, `onlooker_project_remote_url`,
  `onlooker_project_repo_root`, `onlooker_worktree_root`, `_onlooker_sha256_first12` from Tasks 1–2.
- Produces: every plugin calls the `onlooker_*` names; no `<plugin>_project_*` or
  `<plugin>_worktree_root` identifier remains anywhere in the repo.

- [ ] **Step 1: Register the lib in `ON_DEMAND_LIBS`**

In `scripts/sync-shared-libs.sh`, change line 30 — **keeping it on one line**:

```bash
ON_DEMAND_LIBS=(portable-lock.sh watch-unmatched.sh onlooker-project-key.sh)
```

- [ ] **Step 2: Vendor the canonical into the 12 plugins by hand**

The sync script refreshes on-demand libs but never creates them, so the first copy is manual:

```bash
for p in archivist assayer bursar cartographer counsel curator historian \
         inspector librarian lineage scribe tribunal; do
  cp scripts/lib/onlooker-project-key.sh "plugins/$p/scripts/lib/onlooker-project-key.sh"
done
scripts/sync-shared-libs.sh --check
```
Expected: `--check` exits 0 with no "out of sync" lines.

- [ ] **Step 3: Rewrite the source lines and the call sites**

Rename only these exact identifiers, per plugin prefix. Do **not** sed on the bare prefix —
`scribe_project_dir` and `inspector_canonical_path` must survive untouched, and a prefix-level
substitution would rewrite them.

**Use `perl`, not `sed`.** Measured on this machine: BSD `sed` (macOS `/usr/bin/sed`) does not
support `\b`, and it fails by **matching nothing at all** — no error, exit 0, file unchanged.
`[[:<:]]`/`[[:>:]]` works on BSD but not GNU. `perl -pi` with `\b` is correct on both, and `-i`
needs no empty-string argument. Verified it renames `scribe_project_key` while leaving
`scribe_project_dir` untouched, which is exactly the distinction this rename depends on.

```bash
set -euo pipefail
for p in archivist assayer bursar cartographer counsel curator historian \
         inspector librarian lineage scribe tribunal; do
  # Files that mention this plugin's project-key identifiers or its lib path.
  files=$(grep -rl -e "${p}_project_key" -e "${p}_project_remote_url" \
                   -e "${p}_project_repo_root" -e "${p}_worktree_root" \
                   -e "_${p}_sha256_first12" -e "${p}-project-key.sh" \
            plugins/ test/ scripts/ 2>/dev/null \
          | grep -v "plugins/${p}/scripts/lib/${p}-project-key.sh" || true)
  [ -z "$files" ] && continue
  # shellcheck disable=SC2086
  perl -pi \
    -e "s/\\b${p}_project_key\\b/onlooker_project_key/g;" \
    -e "s/\\b${p}_project_remote_url\\b/onlooker_project_remote_url/g;" \
    -e "s/\\b${p}_project_repo_root\\b/onlooker_project_repo_root/g;" \
    -e "s/\\b${p}_worktree_root\\b/onlooker_worktree_root/g;" \
    -e "s/_${p}_sha256_first12/_onlooker_sha256_first12/g;" \
    -e "s/\\Q${p}-project-key.sh\\E/onlooker-project-key.sh/g;" \
    $files
done
```

`\Q...\E` quotes the filename so its dot is literal, not a wildcard.

- [ ] **Step 4: Delete the 12 old libs**

```bash
for p in archivist assayer bursar cartographer counsel curator historian \
         inspector librarian lineage scribe tribunal; do
  git rm -q "plugins/$p/scripts/lib/${p}-project-key.sh"
done
```

- [ ] **Step 5: Verify nothing references the old names**

```bash
grep -rnE '[a-z]+_(project_key|project_remote_url|project_repo_root|worktree_root)\b' \
  plugins/ test/ scripts/ | grep -v onlooker_ || echo "clean"
grep -rn -- "-project-key.sh" plugins/ test/ scripts/ | grep -v onlooker-project-key || echo "clean"
```
Expected: `clean` from both.

- [ ] **Step 6: Run shellcheck and the vendoring guards**

Run: `npm run test:shellcheck`
Run: `scripts/test/run-bats.sh test/bats/shared-lib-vendoring.bats`
Run: `scripts/test/run-bats.sh test/bats/config-lib-self-locating.bats`
Expected: all exit 0. The on-demand tests now cover `onlooker-project-key.sh`; the catch-all
"every plugin vendors every lib it sources from its own tree" must stay green.

- [ ] **Step 7: Prove the guard is not vacuous**

Deliberately break one copy and confirm the suite catches it:

```bash
echo "# drift" >> plugins/lineage/scripts/lib/onlooker-project-key.sh
scripts/test/run-bats.sh test/bats/shared-lib-vendoring.bats; echo "exit=$?"
git checkout plugins/lineage/scripts/lib/onlooker-project-key.sh
```
Expected: non-zero exit naming `lineage/onlooker-project-key.sh` as drifted, then clean after the
checkout. A passing run here means the guard is not actually covering the new lib — stop and fix
the registration before continuing.

- [ ] **Step 8: Commit**

Use `/git-workflow:commit`, staging all of `scripts/sync-shared-libs.sh`, the 12 new vendored
copies, the 12 deletions, and every rewritten caller. Body: seven distinct implementations
collapse to one; cartographer and inspector returned a key for a non-repo directory and the
canonical does not, so the consolidation deletes that bug rather than patching it.

---

## Task 5: Collapse the per-plugin derivation tests

Nine bats files each tested a copy of the same logic. One suite now covers it.

**Files:**
- Delete: `test/bats/<plugin>-project-key.bats` for every deleted lib
- Modify: `test/bats/onlooker-project-key.bats` — absorb any case not already covered

- [ ] **Step 1: List the per-plugin test files and read them for unique cases**

```bash
ls test/bats/*-project-key.bats
```

For each, compare its cases against `test/bats/onlooker-project-key.bats`. The canonical suite
already covers: 12-hex shape, stability across two clones, different remotes differ, rootless
fallback, remote-vs-rootless differ, worktree shares parent key, remoteless worktree shares parent
key, empty outside a repo, plus Tasks 1–2's `worktree_root` and `resolve` cases.

- [ ] **Step 2: Port any case the canonical suite lacks**

Add it to `test/bats/onlooker-project-key.bats` using `onlooker_*` names. Do not port a case that
only re-asserts an already-covered behavior under a different function name — that is the
duplication this task removes.

- [ ] **Step 3: Delete the per-plugin files**

```bash
for f in test/bats/*-project-key.bats; do
  [ "$f" = "test/bats/onlooker-project-key.bats" ] && continue
  git rm -q "$f"
done
```

- [ ] **Step 4: Run the full bats suite**

Run: `npm run test:bats`
Expected: PASS. Investigate any drop in test count beyond the removed duplicates.

- [ ] **Step 5: Commit**

Use `/git-workflow:commit`, staging the deletions and the canonical suite.

---

## Task 6: Full verification

- [ ] **Step 1: Run the complete CI gate**

Run: `npm run test:ci`
Expected: exit 0. This runs shellcheck, the bash-arithmetic lint, bats, the schema suite,
bus-coverage, managed-blocks, biome + markdownlint, manifests, references, and lesson-schema.

- [ ] **Step 2: Confirm the derivation is unchanged for the two real cases**

The consolidation must not move any existing key, or every plugin's on-disk directory orphans.
Against this repo and a remoteless fixture:

```bash
bash -c 'source scripts/lib/onlooker-project-key.sh; onlooker_project_key "$PWD"'
```
Expected: `ee2cfbe428c7` — the value the pre-consolidation libs produced and the directory name
already present under `~/.onlooker/librarian/`, `lineage/`, `curator/`, and `historian/`.

- [ ] **Step 3: Confirm the non-repo case is fixed**

```bash
tmp=$(mktemp -d)
bash -c "source scripts/lib/onlooker-project-key.sh; printf '[%s]\n' \"\$(onlooker_project_key '$tmp')\""
rmdir "$tmp"
```
Expected: `[]`. Before this change, cartographer and inspector returned `715b9b271e0a` here.

- [ ] **Step 4: Confirm every plugin still resolves its key at runtime**

```bash
for p in archivist assayer bursar cartographer counsel curator historian \
         inspector librarian lineage scribe tribunal; do
  printf '%-14s ' "$p"
  bash -c "source plugins/$p/scripts/lib/onlooker-project-key.sh; onlooker_project_key '$PWD'" \
    || echo "FAILED"
  echo
done
```
Expected: `ee2cfbe428c7` on all twelve lines.

- [ ] **Step 5: Update the bead**

```bash
bd update ecosystem-hscz3o --append-notes "Unit 1 (consolidation) landed: onlooker-project-key.sh in ON_DEMAND_LIBS, 12 vendored copies, 12 libs deleted, onlooker_worktree_root and onlooker_project_resolve added. Key unchanged at ee2cfbe428c7; non-repo now empty everywhere (was 715b9b271e0a in cartographer and inspector)."
```

Use `--append-notes`, never `--notes` — `--notes` replaces the field and there is no recovery
path in embedded mode.

- [ ] **Step 6: Open the PR**

Use `/git-workflow:pr`. Never push directly to `main` — release-please needs every change to
travel through a PR to be versioned and changelogged correctly. Wait for CI before merging.

---

## Self-Review

**Spec coverage.** This plan implements the spec's §3 ("One derivation, vendored and guarded") and
the `onlooker_project_resolve` half of its ecosystem code-shape list. Deliberately **not** here,
because they belong to later units: the envelope fields and `librarian.lesson.promoted` (schema
2.28.0, Unit 2); populating the fields in `onlooker-event.mjs`, the librarian emit, and the
`bus-coverage.json` triage (Unit 3); the summarizer and `counts_by_project` column (Unit 4).

**One deviation from the approved spec, and why.** The spec says `SHARED_LIBS`. The repo's own
policy — stated in `sync-shared-libs.sh`'s header and enforced by two separate groups of tests in
`shared-lib-vendoring.bats` — puts a lib used by 12 of 16 plugins in `ON_DEMAND_LIBS`:
`SHARED_LIBS` are vendored into *every* plugin "because every hook uses them", and compass, echo,
governor, and warden never derive a project key. The design's actual requirement — one
implementation, guarded against drift — holds either way: on-demand libs get the byte-identical
test, and the catch-all "every plugin vendors every lib it sources from its own tree" test covers
this lib regardless of which list it is on, because all 12 source it via `"${PLUGIN_ROOT}/..."`.
`SHARED_LIBS` would additionally place a never-sourced file in four plugins, which is the exact
noise that policy comment exists to prevent. **The spec should be corrected to match.**

**Type and name consistency.** `onlooker_project_resolve`, `onlooker_project_key`,
`onlooker_worktree_root`, `onlooker_project_remote_url`, `onlooker_project_repo_root`,
`_onlooker_sha256_first12`, `ONLOOKER_PROJECT_KEY`, `ONLOOKER_PROJECT_BASIS` are spelled
identically in Tasks 1, 2, 4, and 6. The three extracted helpers keep their original signatures
exactly, so their callers need only a new source line.

**Known risk the plan carries deliberately.** Task 2 gives `onlooker_project_key` an export side
effect. A caller that passes a directory other than the session's cwd will set the session-visible
`ONLOOKER_PROJECT_KEY` too. That is why Task 6 Step 4 checks all twelve plugins resolve the
expected key, and why the caveat is in the function's own comment.
