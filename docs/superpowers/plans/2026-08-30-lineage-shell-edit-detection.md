# Lineage shell-edit detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lineage records a change when a tracked file changes, regardless of which tool changed it — closing the gap where shell-shaped edits (heredoc, `sed -i`, `python -c`) are invisible to its `Edit`/`Write`/`MultiEdit` matcher.

**Architecture:** Ask git what changed rather than parse shell commands. A new `PostToolUse` matcher on `Bash` runs one `git status --porcelain=v1 -z` — which reports modified, staged, and untracked paths alike — and compares each path's content hash against a rolling per-session baseline. Changed files get real ledger records, with content from `git diff HEAD` for tracked files and the whole file for newly created ones. Two new fields tag what the record is worth: `provenance_kind` (authored vs tool-generated) and `content_scope` (exact delta vs cumulative).

**Tech Stack:** bash hooks, `jq`, `git`, bats for tests. Schema work is TypeScript + JSON Schema + vitest in a second repo.

## Global Constraints

- **Read the spec first:** `docs/superpowers/specs/2026-08-30-lineage-shell-edit-detection-design.md`. Every decision below traces to it.
- **Task 1 is in a different repo** (`onlooker-community/schema`) and must be released to npm before Tasks 3–5 can pass CI. Do not start Task 3 until schema 2.16.0 is published and installed here.
- **Never hardcode `~/.onlooker`.** Always `$ONLOOKER_DIR`, defaulting to `$HOME/.onlooker`.
- **The baseline must never be written under `$ONLOOKER_DIR/lineage/`.** That path is on the durable never-touch list in `scripts/onlooker-store-prune.mjs`. Baselines go to `$ONLOOKER_DIR/lineage-baselines/`.
- **Hooks always exit 0.** Assert on side effects, never on a non-zero exit code.
- **Fail soft.** No git, no repo, unreadable baseline, malformed JSON → exit 0 having recorded nothing.
- **`provenance_kind` defaults to `authored`.** An unclassified writer must show up as noise, never vanish. This is the whole point of the field.
- **bats gotcha:** every non-final `[[ ]]` assertion needs `|| return 1`. Only the last assertion in a test body gates on its own. See `.claude/skills/writing-tests`.
- **Use `git -C "$root"` in libs**, matching `lineage-project-key.sh`. Never `cd`.
- **American English** in all comments, commit messages, and docs.
- Commit via the `/commit` skill. Subject ≤72 chars including a mood emoji.

---

### Task 1: Schema accepts shell-edit change records

**Repo:** `onlooker-community/schema` (NOT the ecosystem repo)

**Files:**

- Modify: `schemas/payload/plugins-ops.json` — the `lineage.change.recorded` entry under `$defs`
- Modify: `src/types.ts:682-698` — `LineageChangeRecordedPayload` (hand-written; `scripts/generate-types.js` only emits a drift-detection file at `generated-types.d.ts` and does not overwrite this)
- Test: `src/validate.test.ts` — the existing `describe("lineage provenance events", ...)` block

**Interfaces:**

- Consumes: nothing.
- Produces: schema `2.16.0` on npm, accepting `tool: "Bash"`, `operation: "shell_edit"`, `provenance_kind`, and `content_scope` on `lineage.change.recorded`.

**Why this is blocking.** The payload is `additionalProperties: false` with `tool` enum `[Edit, Write, MultiEdit]` and `operation` enum `[create, overwrite, edit, multi_edit]`. All three reject what Tasks 3–5 emit. The runtime emitter fails open ([ADR-005](../adr/005-runtime-emitter-fails-open.md)) — it validates only when the schema package resolves — so shipping without this fails CI here *and* silently emits invalid events from every installed plugin, which ship no `node_modules`.

- [ ] **Step 1: Sync the repo**

```bash
cd ../schema        # adjust to wherever onlooker-community/schema is checked out
git checkout main && git pull --ff-only
npm ci
```

Confirm `package.json` reads `2.15.0`. The local checkout was last seen on an unmerged branch at 2.14.0.

- [ ] **Step 2: Write the failing tests**

In `src/validate.test.ts`, inside the existing `describe("lineage provenance events", ...)` block, add these three tests immediately before the closing `});` of that block. Keep the existing `rejects an unknown tool enum` test exactly as it is — `NotebookEdit` stays invalid, so it does not need changing.

```typescript
	it("validates a shell-detected change record", () => {
		const event = lineage(LINEAGE_CHANGE_RECORDED, {
			project_key: PROJECT_KEY,
			session_id: SID,
			file_path: "docs/plan.md",
			tool: "Bash",
			operation: "shell_edit",
			provenance_kind: "authored",
			content_scope: "cumulative",
		});
		expect(validate(event).valid).toBe(true);
	});

	it("rejects an unknown provenance_kind", () => {
		const event = lineage(LINEAGE_CHANGE_RECORDED, {
			project_key: PROJECT_KEY,
			session_id: SID,
			file_path: "docs/plan.md",
			tool: "Bash",
			operation: "shell_edit",
			provenance_kind: "guessed",
		} as never);
		expect(validate(event).valid).toBe(false);
	});

	it("rejects an unknown content_scope", () => {
		const event = lineage(LINEAGE_CHANGE_RECORDED, {
			project_key: PROJECT_KEY,
			session_id: SID,
			file_path: "docs/plan.md",
			tool: "Bash",
			operation: "shell_edit",
			content_scope: "partial",
		} as never);
		expect(validate(event).valid).toBe(false);
	});
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
npm test -- src/validate.test.ts
```

Expected: `validates a shell-detected change record` FAILS (the `tool` enum rejects `"Bash"`). The two rejection tests will already pass, because `additionalProperties: false` currently rejects the unknown fields for the wrong reason — they become meaningful once Step 4 lands.

- [ ] **Step 4: Extend the JSON Schema**

In `schemas/payload/plugins-ops.json`, in the `lineage.change.recorded` definition, make exactly these four changes. Leave `required` untouched — both new fields are optional, so existing producers stay valid.

Change the `tool` enum:

```json
        "tool": {
          "type": "string",
          "enum": ["Edit", "Write", "MultiEdit", "Bash"]
        },
```

Change the `operation` enum:

```json
        "operation": {
          "type": "string",
          "enum": ["create", "overwrite", "edit", "multi_edit", "shell_edit"]
        },
```

Add both new properties after `content_sha256`:

```json
        "content_sha256": {
          "type": "string"
        },
        "provenance_kind": {
          "type": "string",
          "enum": ["authored", "tool_generated"]
        },
        "content_scope": {
          "type": "string",
          "enum": ["delta", "cumulative"]
        }
```

- [ ] **Step 5: Update the hand-written TypeScript type**

In `src/types.ts`, replace the `LineageChangeRecordedPayload` interface with:

```typescript
export interface LineageChangeRecordedPayload {
	project_key: string;
	session_id: string;
	file_path: string;
	tool: "Edit" | "Write" | "MultiEdit" | "Bash";
	operation: "create" | "overwrite" | "edit" | "multi_edit" | "shell_edit";
	change_id?: string;
	turn?: number;
	tool_use_id?: string;
	agent_type?: string;
	lines_added?: number;
	lines_removed?: number;
	bytes?: number;
	edit_count?: number;
	content_sha256?: string;
	provenance_kind?: "authored" | "tool_generated";
	content_scope?: "delta" | "cumulative";
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
npm test
npm run typecheck
npm run validate-schemas
```

Expected: all three green.

- [ ] **Step 7: Commit and open the PR**

Use the `/commit` skill, then `/git-workflow:pr`. Suggested message:

```text
feat(lineage): let a change record say the shell made it :shell:

lineage watches Edit/Write/MultiEdit, which is a tool call rather than a
file change, so a heredoc or sed -i was invisible to it. Fixing that needs
a vocabulary for changes git noticed and no tool announced.

tool gains Bash and operation gains shell_edit. Two optional fields carry
what such a record is worth: provenance_kind separates an authored edit
from formatter and package-manager churn, and content_scope marks whether
the captured content is exactly this change or includes earlier
uncommitted work.

Both are optional, so every existing producer stays valid.

Refs ecosystem-449.13
```

- [ ] **Step 8: Merge, release, and install downstream**

Wait for release-please to cut `2.16.0` and publish. Then, back in the ecosystem repo:

```bash
cd ../ecosystem
npm install --save-dev @onlooker-community/schema@^2.16.0
node -e "const s=require('@onlooker-community/schema/package.json');console.log(s.version)"
```

Expected: prints `2.16.0` or higher. **Do not start Task 3 before this prints.**

---

### Task 2: Baseline and classification library

**Files:**

- Create: `plugins/lineage/scripts/lib/lineage-baseline.sh`
- Test: `test/bats/lineage-baseline.bats` (create)

**Interfaces:**

- Consumes: `lineage_sha256` from `lineage-record.sh`.
- Produces, for Task 4:
  - `lineage_baseline_path <project_key> <session_id>` → absolute path string
  - `lineage_candidate_paths <repo_root>` → newline-separated repo-relative paths that differ from HEAD **or are untracked**
  - `lineage_file_sha <path>` → sha256 of file contents, empty if unreadable
  - `lineage_baseline_build <repo_root>` → baseline JSON `{files:{path:sha}}`
  - `lineage_changed_files <repo_root> <baseline_json>` → newline-separated repo-relative paths
  - `lineage_classify_command <command>` → `authored` | `tool_generated`
  - `lineage_content_scope <baseline_json> <rel_path>` → `delta` | `cumulative`
  - `lineage_added_content <repo_root> <rel_path>` → added lines (whole file when untracked)

**Enumerate with `git status --porcelain`, not `git diff --name-only HEAD`.** The latter lists only *tracked* files that differ from HEAD, so a shell command creating a new file (`cat > new.md <<EOF`) leaves it untracked and invisible — reproducing the exact silent gap this bead closes. `git status --porcelain=v1` reports modified, staged, and untracked in one call, which is both more correct and one fewer subprocess on the hot path.

This task is pure library code with no hook wiring, so it is testable and reviewable on its own.

- [ ] **Step 1: Write the failing test**

Create `test/bats/lineage-baseline.bats`:

```bash
#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  source "${PLUGIN_ROOT}/scripts/lib/lineage-record.sh"
  source "${PLUGIN_ROOT}/scripts/lib/lineage-baseline.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  printf 'one\n' > "${PROJECT_REPO}/tracked.txt"
  git -C "$PROJECT_REPO" add tracked.txt
  git -C "$PROJECT_REPO" commit -qm "seed"
}

@test "baseline path lands under lineage-baselines, never under lineage" {
  run lineage_baseline_path "abc123" "sess-1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"/lineage-baselines/abc123/sess-1.json" ]] || return 1
  [[ "$output" != *"/lineage/abc123"* ]]
}

@test "candidate_paths reports a modified tracked file" {
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$output" = "tracked.txt" ]
}

# The gap a `git diff --name-only HEAD` enumeration would miss entirely.
@test "candidate_paths reports an untracked new file" {
  printf 'brand new\n' > "${PROJECT_REPO}/created.txt"
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$output" = "created.txt" ]
}

@test "candidate_paths handles a path with a space" {
  printf 'x\n' > "${PROJECT_REPO}/two words.txt"
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$output" = "two words.txt" ]
}

# A rename emits two records: "R  newname.txt" then a BARE "oldname.txt". Slicing
# a status prefix off the second one turns it into "name.txt".
@test "candidate_paths reports a rename's new path and not a mangled old one" {
  git -C "$PROJECT_REPO" mv tracked.txt renamed.txt
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"renamed.txt"* ]] || return 1
  [[ "$output" != *"acked.txt"* ]]
}

@test "baseline_build writes no key for a path that does not exist on disk" {
  git -C "$PROJECT_REPO" mv tracked.txt renamed.txt
  base=$(lineage_baseline_build "$PROJECT_REPO")
  run bash -c "printf '%s' '$base' | jq -r '.files | keys[]'"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"acked.txt"* ]]
}

@test "changed_files reports a newly created untracked file" {
  base=$(lineage_baseline_build "$PROJECT_REPO")
  printf 'brand new\n' > "${PROJECT_REPO}/created.txt"
  run lineage_changed_files "$PROJECT_REPO" "$base"
  [ "$output" = "created.txt" ]
}

@test "added_content returns the whole file for an untracked file" {
  printf 'brand new\n' > "${PROJECT_REPO}/created.txt"
  run lineage_added_content "$PROJECT_REPO" "created.txt"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"brand new"* ]]
}

@test "changed_files reports a file modified after the baseline" {
  base=$(lineage_baseline_build "$PROJECT_REPO")
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  run lineage_changed_files "$PROJECT_REPO" "$base"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "tracked.txt" ]
}

@test "changed_files reports nothing when nothing changed" {
  base=$(lineage_baseline_build "$PROJECT_REPO")
  run lineage_changed_files "$PROJECT_REPO" "$base"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ]
}

# The case a hash of `git status` output alone would miss: the file was ALREADY
# dirty at baseline, so its status line is byte-identical after the second edit
# and only a per-path content sha can tell them apart.
@test "changed_files catches a second edit to an already-dirty file" {
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  base=$(lineage_baseline_build "$PROJECT_REPO")
  before=$(lineage_candidate_paths "$PROJECT_REPO")
  printf 'three\n' >> "${PROJECT_REPO}/tracked.txt"
  after=$(lineage_candidate_paths "$PROJECT_REPO")
  [ "$before" = "$after" ] || return 1   # the status listing really is identical
  run lineage_changed_files "$PROJECT_REPO" "$base"
  [ "$output" = "tracked.txt" ]
}

@test "content_scope is delta for a file clean at baseline" {
  base=$(lineage_baseline_build "$PROJECT_REPO")
  run lineage_content_scope "$base" "tracked.txt"
  [ "$output" = "delta" ]
}

@test "content_scope is cumulative for a file already dirty at baseline" {
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  base=$(lineage_baseline_build "$PROJECT_REPO")
  run lineage_content_scope "$base" "tracked.txt"
  [ "$output" = "cumulative" ]
}

@test "added_content returns the added lines only" {
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  run lineage_added_content "$PROJECT_REPO" "tracked.txt"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"two"* ]] || return 1
  [[ "$output" != *"one"* ]]
}

@test "classify marks git switch as tool_generated" {
  run lineage_classify_command "git switch -c feat/x"
  [ "$output" = "tool_generated" ]
}

@test "classify marks npm ci as tool_generated" {
  run lineage_classify_command "npm ci --silent"
  [ "$output" = "tool_generated" ]
}

@test "classify marks a formatter as tool_generated" {
  run lineage_classify_command "./node_modules/.bin/biome format --write src"
  [ "$output" = "tool_generated" ]
}

# The default that keeps this bug from recurring one layer up.
@test "classify defaults an unrecognized command to authored" {
  run lineage_classify_command "frobnicate --rewrite everything"
  [ "$output" = "authored" ]
}

@test "classify treats a heredoc write as authored" {
  run lineage_classify_command "cat > file.txt <<EOF"
  [ "$output" = "authored" ]
}

@test "candidate_paths is empty for a non-git directory" {
  run lineage_candidate_paths "${BATS_TEST_TMPDIR}"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bats test/bats/lineage-baseline.bats
```

Expected: every test fails — `lineage-baseline.sh` does not exist, so the `source` in `setup()` errors.

- [ ] **Step 3: Write the library**

Create `plugins/lineage/scripts/lib/lineage-baseline.sh`:

```bash
#!/usr/bin/env bash
# Detect file changes git noticed and no tool announced.
#
# lineage's PostToolUse matcher sees Edit/Write/MultiEdit — a TOOL CALL, not a
# change to the filesystem. An agent editing through the shell moves the same
# bytes past an unwatched path (ecosystem-449.13). This library asks git what
# changed instead of parsing shell commands: covering sed -i, tee, heredocs and
# python -c is open-ended, and a wrong parse writes a FALSE ledger entry, which
# is worse than a missing one.
#
# Baselines are scratch state and live under $ONLOOKER_DIR/lineage-baselines/,
# NEVER under $ONLOOKER_DIR/lineage/ — that path is on the durable never-touch
# list in scripts/onlooker-store-prune.mjs, and a per-session file there would
# recreate ecosystem-449.2 inside the store that bead just bounded.
#
# Requires lineage-record.sh sourced beforehand (for lineage_sha256).

# ---------------------------------------------------------------------------
# Baseline location
# ---------------------------------------------------------------------------

lineage_baseline_dir() {
	local key="${1:-unknown}" safe
	safe=$(printf '%s' "$key" | tr -c 'a-zA-Z0-9-' '_')
	printf '%s/lineage-baselines/%s' "${ONLOOKER_DIR:-${HOME}/.onlooker}" "$safe"
}

lineage_baseline_path() {
	local key="$1" sid="${2:-unknown}" safe_sid
	safe_sid=$(printf '%s' "$sid" | tr -c 'a-zA-Z0-9-' '_')
	printf '%s/%s.json' "$(lineage_baseline_dir "$key")" "$safe_sid"
}

# ---------------------------------------------------------------------------
# Git state
# ---------------------------------------------------------------------------

lineage_file_sha() {
	local path="$1"
	[[ -f "$path" ]] || return 0
	lineage_sha256 "$(cat "$path" 2>/dev/null)"
}

# Repo-relative paths that differ from HEAD OR are untracked.
#
# `git status --porcelain=v1 -z` rather than `git diff --name-only HEAD`: the
# latter reports only TRACKED files, so a shell command creating a new file
# would be invisible — the same silent gap this bead exists to close. Porcelain
# reports modified, staged, and untracked in one call.
#
# -z gives NUL-terminated records, so paths with spaces survive. A normal record
# is a 2-char status, a space, then the path.
#
# A rename or copy is the exception and emits TWO records: "R  newpath", then a
# BARE "oldpath" carrying no status prefix. Slicing ${rec:3} off that second
# record eats three characters of a real filename — "oldname.txt" becomes
# "name.txt" — so a rename must consume and discard its companion record. The
# old path is gone from disk anyway, so there is nothing to hash.
lineage_candidate_paths() {
	local root="$1" rec path xy skip_next=0
	[[ -z "$root" ]] && return 0
	git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
	while IFS= read -r -d '' rec; do
		if [[ "$skip_next" -eq 1 ]]; then
			skip_next=0
			continue
		fi
		[[ -z "$rec" ]] && continue
		xy="${rec:0:2}"
		[[ "$xy" == *R* || "$xy" == *C* ]] && skip_next=1
		path="${rec:3}"
		[[ -z "$path" ]] && continue
		printf '%s\n' "$path"
	done < <(git -C "$root" status --porcelain=v1 -z 2>/dev/null) || true
}

# Baseline JSON: { files: { <rel_path>: <sha>, ... } }
lineage_baseline_build() {
	local root="$1" files_json rel abs
	files_json='{}'
	while IFS= read -r rel; do
		[[ -z "$rel" ]] && continue
		abs="${root}/${rel}"
		files_json=$(printf '%s' "$files_json" \
			| jq -c --arg k "$rel" --arg v "$(lineage_file_sha "$abs")" '.[$k]=$v' 2>/dev/null) \
			|| files_json='{}'
	done < <(lineage_candidate_paths "$root")

	jq -cn --argjson f "$files_json" '{files: $f}' 2>/dev/null
}

# Paths whose contents differ from the baseline.
#
# Compares per-path content shas rather than a hash of `git status` output. A
# status hash cannot see a second edit to an already-modified file: the status
# line is byte-identical both times, so the edit would vanish — the same class
# of silent miss this bead is about. A path absent from the baseline is new to
# the working tree and always reported.
lineage_changed_files() {
	local root="$1" base="$2" rel abs cur old
	[[ -z "$root" ]] && return 0
	while IFS= read -r rel; do
		[[ -z "$rel" ]] && continue
		abs="${root}/${rel}"
		cur=$(lineage_file_sha "$abs")
		[[ -z "$cur" ]] && continue   # deleted or unreadable: nothing to record
		old=$(printf '%s' "$base" | jq -r --arg k "$rel" '.files[$k] // ""' 2>/dev/null)
		[[ "$cur" != "$old" ]] && printf '%s\n' "$rel"
	done < <(lineage_candidate_paths "$root")
}

# ---------------------------------------------------------------------------
# Record qualifiers
# ---------------------------------------------------------------------------

# delta     — the file was clean at baseline, so `git diff HEAD` IS this change.
# cumulative— it was already dirty, so the diff also carries earlier uncommitted
#             work. Recorded rather than hidden: lineage's lookup tolerates
#             over-inclusion (it over-attributes to a later change, never
#             returns nothing), and tagging keeps the imprecision auditable.
lineage_content_scope() {
	local base="$1" rel="$2" old
	old=$(printf '%s' "$base" | jq -r --arg k "$rel" '.files[$k] // ""' 2>/dev/null)
	if [[ -n "$old" ]]; then printf 'cumulative'; else printf 'delta'; fi
}

# Added lines from the working tree against HEAD, '+' markers stripped.
#
# An untracked file has nothing in HEAD to diff against and `git diff` prints
# nothing for it, so its whole content is the added content. Without this the
# newly-created-file case would be detected and then silently skipped for
# having no content — a miss disguised as a decision.
lineage_added_content() {
	local root="$1" rel="$2"
	if git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
		git -C "$root" diff --unified=0 HEAD -- "$rel" 2>/dev/null \
			| sed -n 's/^+\([^+].*\)$/\1/p' \
			|| true
	else
		cat "${root}/${rel}" 2>/dev/null || true
	fi
}

# authored | tool_generated, from the Bash command string.
#
# DEFAULTS TO authored ON PURPOSE. If the unknown case defaulted to
# tool_generated and /lineage filtered those out, a writer nobody classified
# would vanish silently — which is this bug one layer up. An unrecognized
# command shows up as noise instead: visible, and fixable.
lineage_classify_command() {
	local cmd="$1"
	case "$cmd" in
		*"git checkout"* | *"git switch"* | *"git merge"* | *"git rebase"* \
			| *"git pull"* | *"git stash"* | *"git reset"* | *"git revert"* \
			| *"git apply"* | *"git cherry-pick"*)
			printf 'tool_generated' ;;
		*"npm install"* | *"npm ci"* | *"npm update"* \
			| *"pnpm install"* | *"pnpm ci"* | *"yarn install"* | *"bun install"*)
			printf 'tool_generated' ;;
		*biome* | *prettier* | *"black "* | *rustfmt* | *gofmt* | *"npm run format"*)
			printf 'tool_generated' ;;
		*release-please*)
			printf 'tool_generated' ;;
		*)
			printf 'authored' ;;
	esac
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bats test/bats/lineage-baseline.bats
shellcheck -S error -x plugins/lineage/scripts/lib/lineage-baseline.sh
```

Expected: all 20 PASS, shellcheck silent.

- [ ] **Step 5: Break one assertion on purpose to prove the tests gate**

Temporarily change the `lineage_classify_command` default from `authored` to `tool_generated`, re-run, and confirm `classify defaults an unrecognized command to authored` FAILS. Revert.

A bats test whose non-final `[[ ]]` was left ungated passes whether or not the code works, so this check is not optional.

- [ ] **Step 6: Commit**

Use the `/commit` skill. Suggested message:

```text
feat(lineage): ask git which files changed :mag:

Groundwork for recording edits the tool matcher never sees. Detection is
two checks, not one: the porcelain status hash catches a file entering or
leaving the dirty set, and a per-path content sha catches a second edit to
a file that was already dirty -- which leaves git status byte-identical and
would otherwise be invisible.

Classification defaults to authored rather than tool_generated. Defaulting
the unknown case to filtered-out would make an unclassified writer vanish
silently, which is the bug this fixes, one layer up.

Refs ecosystem-449.13
```

---

### Task 3: Records carry provenance_kind and content_scope

**Depends on:** Task 1 released and installed.

**Files:**

- Modify: `plugins/lineage/scripts/lib/lineage-record.sh` — `_lineage_operation`, `lineage_build_record`
- Test: `test/bats/lineage-record.bats` (existing — add cases)

**Interfaces:**

- Consumes: `lineage_classify_command`, `lineage_content_scope` from Task 2.
- Produces, for Task 4: `lineage_build_record` extended with three trailing optional parameters — `<added_override> <provenance_kind> <content_scope>`. When `added_override` is non-empty it replaces the tool_input-derived content; when empty, behavior is exactly as before.

- [ ] **Step 1: Write the failing test**

Append to `test/bats/lineage-record.bats`. If that file's `setup()` does not already source `lineage-record.sh` and `lineage-redact.sh`, mirror whatever the existing tests in it do.

```bash
@test "operation maps Bash to shell_edit" {
  run _lineage_operation "Bash"
  [ "$output" = "shell_edit" ]
}

@test "build_record uses the added override when given" {
  run lineage_build_record "cid1" "2026-01-01T00:00:00Z" "0" "sess" "1" \
    "Bash" "/repo/f.txt" '{}' "4000" "false" "" "added from git" "authored" "delta"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" | jq -e '.added_snippets[0] == "added from git"' >/dev/null
}

@test "build_record carries provenance_kind and content_scope" {
  run lineage_build_record "cid2" "2026-01-01T00:00:00Z" "0" "sess" "1" \
    "Bash" "/repo/f.txt" '{}' "4000" "false" "" "x" "tool_generated" "cumulative"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" \
    | jq -e '.provenance_kind == "tool_generated" and .content_scope == "cumulative"' >/dev/null
}

@test "build_record omits the new fields for a normal Edit" {
  run lineage_build_record "cid3" "2026-01-01T00:00:00Z" "0" "sess" "1" \
    "Edit" "/repo/f.txt" '{"new_string":"hello"}' "4000" "false" ""
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" | jq -e 'has("provenance_kind") == false' >/dev/null || return 1
  printf '%s' "$output" | jq -e '.added_snippets[0] == "hello"' >/dev/null
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bats test/bats/lineage-record.bats
```

Expected: the four new tests fail; every pre-existing test in the file still passes.

- [ ] **Step 3: Extend the operation map**

In `plugins/lineage/scripts/lib/lineage-record.sh`, replace `_lineage_operation` with:

```bash
_lineage_operation() {
	case "$1" in
		Edit) printf 'edit' ;;
		MultiEdit) printf 'multi_edit' ;;
		Write) printf 'create' ;;
		Bash) printf 'shell_edit' ;;
		*) printf 'edit' ;;
	esac
}
```

- [ ] **Step 4: Extend the record builder**

In the same file, replace the `lineage_build_record` function with the version below. The three new parameters are optional and default to empty, so every existing caller keeps working unchanged.

```bash
# Build a change record JSON (pure — no I/O). Echoes the record.
# Usage: lineage_build_record <change_id> <ts> <ts_epoch> <session_id> <turn>
#          <tool> <file_path> <tool_input_json> <max_chars> <do_redact>
#          <transcript_path> [added_override] [provenance_kind] [content_scope]
#
# added_override carries content git found for a shell-shaped edit, where
# tool_input says nothing about what changed. provenance_kind and content_scope
# are emitted only when set, so Edit/Write/MultiEdit records are byte-identical
# to before this change.
lineage_build_record() {
	local change_id="$1" ts="$2" ts_epoch="$3" session_id="$4" turn="$5"
	local tool="$6" file_path="$7" ti="$8" max_chars="$9" do_redact="${10}" transcript_path="${11}"
	local added_override="${12:-}" prov_kind="${13:-}" content_scope="${14:-}"

	local added removed added_red lines_added lines_removed bytes digest op edit_count
	if [[ -n "$added_override" ]]; then
		added="$added_override"
		removed=""
	else
		added=$(_lineage_added "$tool" "$ti")
		removed=$(_lineage_removed "$tool" "$ti")
	fi
	lines_added=$(_lineage_count_lines "$added")
	lines_removed=$(_lineage_count_lines "$removed")
	bytes=$(printf '%s' "$added" | wc -c | tr -d ' ')
	digest=$(lineage_sha256 "$added")
	op=$(_lineage_operation "$tool")
	edit_count=$(printf '%s' "$ti" | jq -r 'if .edits then (.edits | length) else 1 end' 2>/dev/null) || edit_count=1
	added_red=$(printf '%s' "$added" | lineage_redact "$max_chars" "$do_redact")

	jq -n \
		--arg cid "$change_id" --arg ts "$ts" --argjson te "${ts_epoch:-0}" \
		--arg sid "$session_id" --arg tool "$tool" --arg op "$op" \
		--arg fp "$file_path" --arg snip "$added_red" --arg tp "$transcript_path" \
		--argjson la "${lines_added:-0}" --argjson lr "${lines_removed:-0}" \
		--argjson by "${bytes:-0}" --arg digest "$digest" \
		--argjson ec "${edit_count:-1}" --arg turn "$turn" \
		--arg pk "$prov_kind" --arg cs "$content_scope" \
		'{
			change_id: $cid, ts: $ts, ts_epoch: $te,
			session_id: $sid, tool: $tool, operation: $op, file_path: $fp,
			lines_added: $la, lines_removed: $lr, bytes: $by,
			edit_count: $ec, content_sha256: $digest,
			added_snippets: [$snip], transcript_path: $tp
		}
		+ (if $turn != "" then {turn: ($turn | tonumber)} else {} end)
		+ (if $pk != "" then {provenance_kind: $pk} else {} end)
		+ (if $cs != "" then {content_scope: $cs} else {} end)' 2>/dev/null
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bats test/bats/lineage-record.bats
shellcheck -S error -x plugins/lineage/scripts/lib/lineage-record.sh
```

Expected: all PASS, including every pre-existing test, shellcheck silent.

- [ ] **Step 6: Commit**

Use the `/commit` skill. Suggested message:

```text
feat(lineage): let a record say how much of the change it holds :label:

A shell edit has no tool_input to read content from, so build_record takes
an override for what git found. Two optional qualifiers ride along:
provenance_kind separates an authored edit from formatter churn, and
content_scope marks whether the captured content is exactly this change or
includes earlier uncommitted work.

Both are emitted only when set, so Edit/Write/MultiEdit records come out
byte-identical to before.

Refs ecosystem-449.13
```

---

### Task 4: Wire the Bash matcher

**Depends on:** Tasks 2 and 3.

**Files:**

- Modify: `plugins/lineage/hooks/hooks.json` — add a `Bash` matcher
- Modify: `plugins/lineage/scripts/hooks/lineage-post-tool-use.sh` — branch on tool
- Modify: `plugins/lineage/config.json` — extend `ignore_globs`
- Modify: `plugins/lineage/scripts/lib/lineage-config.sh:69` — the duplicated default in the accessor's jq fallback
- Test: `test/bats/lineage-shell-edit.bats` (create)

**Interfaces:**

- Consumes: everything from Tasks 2 and 3.
- Produces: the user-visible behavior. Nothing depends on this.

**The lockfile trap.** `ignore_globs` defaults to `["**/.git/**","**/node_modules/**","**/dist/**","**/*.lock"]`. `**/*.lock` does **not** match `package-lock.json` or `pnpm-lock.yaml`, so without this change every `npm ci` writes a record for a multi-thousand-line diff. The default is duplicated in two places — `config.json` and the jq fallback in `lineage-config.sh` — and both must be updated or the shipped default and the runtime default disagree.

- [ ] **Step 1: Write the failing test**

Create `test/bats/lineage-shell-edit.bats`:

```bash
#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
  HOOK="${PLUGIN_ROOT}/scripts/hooks/lineage-post-tool-use.sh"

  source "${PLUGIN_ROOT}/scripts/lib/lineage-project-key.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git
  printf 'one\n' > "${PROJECT_REPO}/tracked.txt"
  git -C "$PROJECT_REPO" add tracked.txt
  git -C "$PROJECT_REPO" commit -qm "seed"

  PROJECT_KEY=$(lineage_project_key "$PROJECT_REPO")
  LEDGER="${ONLOOKER_DIR}/lineage/${PROJECT_KEY}/changes.jsonl"
}

_bash_input() {
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-shell" --arg cmd "$1" \
    '{cwd: $cwd, session_id: $sid, tool_name: "Bash",
      tool_input: {command: $cmd}, hook_event_name: "PostToolUse"}'
}

_run_hook() { printf '%s' "$(_bash_input "$1")" | bash "$HOOK"; }

@test "first Bash call seeds a baseline and records nothing" {
  run bash -c "printf '%s' '$(_bash_input "echo hi")' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "$LEDGER" ]
}

@test "a shell edit to a tracked file is recorded" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  _run_hook "cat >> tracked.txt <<EOF"
  [ -f "$LEDGER" ] || return 1
  run jq -r 'select(.tool == "Bash") | .file_path' "$LEDGER"
  [[ "$output" == *"tracked.txt"* ]]
}

@test "the record is tagged shell_edit and authored" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  _run_hook "cat >> tracked.txt <<EOF"
  run jq -r 'select(.tool == "Bash") | "\(.operation) \(.provenance_kind)"' "$LEDGER"
  [ "$output" = "shell_edit authored" ]
}

@test "a git switch is tagged tool_generated" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  _run_hook "git switch -c other"
  run jq -r 'select(.tool == "Bash") | .provenance_kind' "$LEDGER"
  [ "$output" = "tool_generated" ]
}

@test "a Bash call that changes nothing records nothing" {
  _run_hook "echo seed"
  _run_hook "ls -la"
  [ ! -f "$LEDGER" ]
}

@test "the baseline lives under lineage-baselines, not lineage" {
  _run_hook "echo seed"
  [ -f "${ONLOOKER_DIR}/lineage-baselines/${PROJECT_KEY}/sess-shell.json" ] || return 1
  [ ! -d "${ONLOOKER_DIR}/lineage/${PROJECT_KEY}/sess-shell.json" ]
}

@test "lockfiles are ignored" {
  _run_hook "echo seed"
  printf '{}\n' > "${PROJECT_REPO}/package-lock.json"
  git -C "$PROJECT_REPO" add package-lock.json
  git -C "$PROJECT_REPO" commit -qm "add lock"
  printf '{"a":1}\n' > "${PROJECT_REPO}/package-lock.json"
  _run_hook "npm ci"
  if [ -f "$LEDGER" ]; then
    run jq -r 'select(.tool == "Bash") | .file_path' "$LEDGER"
    [[ "$output" != *"package-lock.json"* ]]
  fi
}

@test "a non-git cwd exits 0 and records nothing" {
  outside="${BATS_TEST_TMPDIR}/nogit"
  mkdir -p "$outside"
  input=$(jq -cn --arg cwd "$outside" --arg sid "s2" \
    '{cwd: $cwd, session_id: $sid, tool_name: "Bash",
      tool_input: {command: "echo hi"}, hook_event_name: "PostToolUse"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "Edit still records exactly as before" {
  input=$(jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-shell" \
    --arg fp "${PROJECT_REPO}/tracked.txt" \
    '{cwd: $cwd, session_id: $sid, tool_name: "Edit",
      tool_input: {file_path: $fp, old_string: "one", new_string: "hello"},
      hook_event_name: "PostToolUse"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1
  run jq -r 'select(.tool == "Edit") | "\(.operation) \(has("provenance_kind"))"' "$LEDGER"
  [ "$output" = "edit false" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bats test/bats/lineage-shell-edit.bats
```

Expected: the Bash tests fail — the hook currently exits early on any tool that is not `Edit`/`Write`/`MultiEdit`. `Edit still records exactly as before` should already pass.

- [ ] **Step 3: Add the Bash matcher to hooks.json**

In `plugins/lineage/hooks/hooks.json`, add a fourth entry to the `PostToolUse` array, matching the existing three exactly in shape:

```json
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PLUGIN_ROOT\"/scripts/hooks/lineage-post-tool-use.sh"
          }
        ]
      }
```

- [ ] **Step 4: Extend ignore_globs in both places**

In `plugins/lineage/config.json`, replace the `ignore_globs` array:

```json
    "ignore_globs": [
      "**/.git/**",
      "**/node_modules/**",
      "**/dist/**",
      "**/*.lock",
      "**/package-lock.json",
      "**/pnpm-lock.yaml",
      "**/yarn.lock",
      "**/bun.lockb"
    ],
```

In `plugins/lineage/scripts/lib/lineage-config.sh:69`, update the duplicated jq fallback to the identical list:

```bash
	lineage_config_get_json '.lineage.ignore_globs // ["**/.git/**","**/node_modules/**","**/dist/**","**/*.lock","**/package-lock.json","**/pnpm-lock.yaml","**/yarn.lock","**/bun.lockb"]' | jq -r '.[]'
```

- [ ] **Step 5: Branch the hook on tool**

In `plugins/lineage/scripts/hooks/lineage-post-tool-use.sh`:

Add the new library to the sourcing block, after `lineage-record.sh`:

```bash
# shellcheck source=../lib/lineage-baseline.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-baseline.sh"
```

Replace the early tool guard:

```bash
case "$TOOL" in
	Edit | Write | MultiEdit) ;;
	*) _done ;;
esac
```

with:

```bash
case "$TOOL" in
	Edit | Write | MultiEdit | Bash) ;;
	*) _done ;;
esac
```

Then, immediately after the `PROJECT_KEY` guard (`[[ -z "$PROJECT_KEY" ]] && _done`), insert the Bash branch. It ends with `_done` in every path, so the existing tool-input logic below is reached only by `Edit`/`Write`/`MultiEdit`:

```bash
# ---------------------------------------------------------------------------
# Bash: git is the source of truth. A shell-shaped edit has no tool_input to
# read a path or content from, so compare the work tree against a rolling
# per-session baseline and record whatever moved (ecosystem-449.13).
# ---------------------------------------------------------------------------
if [[ "$TOOL" == "Bash" ]]; then
	[[ -z "$REPO_ROOT" ]] && _done

	BASELINE_FILE=$(lineage_baseline_path "$PROJECT_KEY" "$SESSION_ID")
	mkdir -p "$(dirname "$BASELINE_FILE")" 2>/dev/null || _done

	BASELINE='{}'
	[[ -f "$BASELINE_FILE" ]] && BASELINE=$(cat "$BASELINE_FILE" 2>/dev/null) || true
	[[ -z "$BASELINE" ]] && BASELINE='{}'

	COMMAND=$(printf '%s' "$TOOL_INPUT" | jq -r '.command // ""' 2>/dev/null) || COMMAND=""
	PROV_KIND=$(lineage_classify_command "$COMMAND")

	# No prior baseline means this is the session's first Bash call. Seed and
	# stop: with nothing to compare against, every dirty file would look new.
	if printf '%s' "$BASELINE" | jq -e 'has("files")' >/dev/null 2>&1; then
		MAX_CHARS=$(lineage_config_max_snippet_chars)
		DO_REDACT=true
		lineage_config_redact_enabled || DO_REDACT=false

		TURN=""
		TRACKER="${ONLOOKER_DIR:-$HOME/.onlooker}/session-trackers/${SESSION_ID}"
		[[ -n "$SESSION_ID" && -f "$TRACKER" ]] && TURN=$(jq -r '.turn_number // empty' "$TRACKER" 2>/dev/null)

		while IFS= read -r REL; do
			[[ -z "$REL" ]] && continue
			_lineage_ignored "$REL" && continue

			SCOPE=$(lineage_content_scope "$BASELINE" "$REL")
			ADDED=$(lineage_added_content "$REPO_ROOT" "$REL")
			[[ -z "$ADDED" ]] && continue

			REC=$(lineage_build_record "$(lineage_ulid)" "$(lineage_now_iso)" \
				"$(lineage_now_epoch)" "$SESSION_ID" "$TURN" "Bash" \
				"${REPO_ROOT}/${REL}" '{}' "$MAX_CHARS" "$DO_REDACT" \
				"$TRANSCRIPT_PATH" "$ADDED" "$PROV_KIND" "$SCOPE")
			[[ -z "$REC" ]] && continue

			if lineage_append "$PROJECT_KEY" "$REC"; then
				EV=$(printf '%s' "$REC" | jq -c --arg pk "$PROJECT_KEY" --arg tuid "$TOOL_USE_ID" '
					{
						project_key: $pk, session_id: .session_id, file_path: .file_path,
						tool: .tool, operation: .operation, change_id: .change_id,
						lines_added: .lines_added, lines_removed: .lines_removed,
						bytes: .bytes, edit_count: .edit_count, content_sha256: .content_sha256,
						provenance_kind: .provenance_kind, content_scope: .content_scope
					}
					+ (if .turn != null then {turn: .turn} else {} end)
					+ (if $tuid != "" then {tool_use_id: $tuid} else {} end)
				' 2>/dev/null)
				[[ -n "$EV" ]] && lineage_emit_event "lineage.change.recorded" "$EV" "$SESSION_ID" || true
			fi
		done < <(lineage_changed_files "$REPO_ROOT" "$BASELINE")
	fi

	# Advance the baseline whether or not anything was recorded, so the next
	# call diffs against current state rather than re-reporting the same edit.
	lineage_baseline_build "$REPO_ROOT" > "$BASELINE_FILE" 2>/dev/null || true
	_done
fi
```

Note: `_lineage_ignored` is defined further down the existing script. Move that function definition **above** this block so it is in scope — bash resolves function definitions at execution time, and the Bash branch runs before the current definition point.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bats test/bats/lineage-shell-edit.bats
shellcheck -S error -x plugins/lineage/scripts/hooks/lineage-post-tool-use.sh
```

Expected: all 9 PASS, shellcheck silent.

- [ ] **Step 7: Confirm nothing regressed**

```bash
npm run test:bats
```

Expected: the full suite green, including every pre-existing `lineage-*.bats` file.

- [ ] **Step 8: Commit**

Use the `/commit` skill. Suggested message:

```text
feat(lineage): record the edits the matcher never saw :satellite:

Adds a Bash matcher. On each shell call lineage diffs the work tree against
a rolling per-session baseline and records what moved, so a heredoc or
sed -i lands in the ledger the same as an Edit. The first call of a session
seeds the baseline and records nothing -- with no prior state every dirty
file would look new.

Also extends ignore_globs. The old list had **/*.lock, which does not match
package-lock.json or pnpm-lock.yaml, so every npm ci would otherwise write
a record for a multi-thousand-line diff. The default was duplicated in
config.json and in the accessor's jq fallback; both are updated, since
disagreeing defaults are how a config silently stops meaning anything.

Refs ecosystem-449.13
```

---

### Task 4.5: Pre-gate the Bash path so a no-op shell call stays cheap

**Depends on:** Task 4.

**Files:**

- Modify: `plugins/lineage/scripts/hooks/lineage-post-tool-use.sh` — move the Bash branch above the shared setup and make that setup lazy
- Modify: `plugins/lineage/scripts/lib/lineage-baseline.sh` — add `lineage_baseline_scope_id`
- Test: `test/bats/lineage-shell-edit.bats` (extend), `test/bats/lineage-baseline.bats` (extend)

**Why this task exists.** Measured on this repo (561 tracked files, 5 dirty) after Task 4:

| path | cost | note |
|---|---|---|
| unmatched tool, early exit | ~60 ms | sourcing only |
| Bash, nothing changed | ~370 ms | was 0 ms — no matcher existed before |
| Edit | ~350 ms | unchanged by this work |
| raw `git status --porcelain -z` | 34 ms | the actual new work |

The detection is cheap. The ~310 ms above the sourcing floor is lineage's pre-existing
per-invocation setup — `lineage_config_load`, `lineage_project_key`, and several config
accessors that each spawn their own `jq`. Before this plan lineage never ran on `Bash` at all,
so that cost went from never to every shell call, and `Bash` outruns `Edit` by roughly 30:1.

The fix is ordering, not optimization: decide whether anything changed **before** paying for
setup that is only needed to write a record.

**The obstacle, and why the baseline gets its own scope id.** The baseline path currently
derives from `PROJECT_KEY`, and resolving that is itself ~39 ms of the cost we are trying to
skip. The baseline is per-session scratch and is never joined to the ledger, so it does not
need to share the ledger's identity. Keying it off a cheap hash of the repo root is enough,
and it keeps the whole pre-gate free of `lineage_project_key`.

**A status-hash pre-gate would be wrong.** Comparing a hash of `git status` output alone
cannot see a second edit to an already-modified file — identical status line, different
content. That is the exact miss Task 2 was built to avoid. The pre-gate must compare per-path
content hashes, which is what `lineage_changed_files` already does.

**Interfaces:**

- Consumes: `lineage_changed_files`, `lineage_baseline_build` from Task 2.
- Produces: `lineage_baseline_scope_id <repo_root>` → first 12 hex of SHA-256 of the repo root.

- [ ] **Step 1: Write the failing tests**

Add to `test/bats/lineage-baseline.bats`:

```bash
@test "scope id is stable and 12 hex chars" {
  a=$(lineage_baseline_scope_id "$PROJECT_REPO")
  b=$(lineage_baseline_scope_id "$PROJECT_REPO")
  [ "$a" = "$b" ] || return 1
  [[ "$a" =~ ^[0-9a-f]{12}$ ]]
}

@test "scope id differs for a different repo root" {
  other="${BATS_TEST_TMPDIR}/other"; mkdir -p "$other"
  a=$(lineage_baseline_scope_id "$PROJECT_REPO")
  b=$(lineage_baseline_scope_id "$other")
  [ "$a" != "$b" ]
}
```

Add to `test/bats/lineage-shell-edit.bats`:

```bash
@test "a no-change Bash call resolves no project key" {
  _run_hook "echo seed"
  run bash -c "printf '%s' '$(_bash_input "ls -la")' | LINEAGE_TRACE_SETUP=1 '$HOOK' 2>&1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"SETUP_DONE"* ]]
}

@test "a changing Bash call does resolve the project key" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  run bash -c "printf '%s' '$(_bash_input "cat >> tracked.txt <<EOF")' | LINEAGE_TRACE_SETUP=1 '$HOOK' 2>&1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"SETUP_DONE"* ]]
}
```

`LINEAGE_TRACE_SETUP` is a test-only probe: when set, the hook prints `SETUP_DONE` to stderr
immediately after the lazy setup block runs. It is the only way to assert from the outside
that the expensive path was skipped, since a skipped setup leaves no artifact.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bats test/bats/lineage-baseline.bats test/bats/lineage-shell-edit.bats
```

Expected: the four new tests fail; every other test in both files still passes.

- [ ] **Step 3: Add the scope id**

In `plugins/lineage/scripts/lib/lineage-baseline.sh`, add beside `lineage_baseline_dir`:

```bash
# Cheap identity for the per-session baseline.
#
# Deliberately NOT lineage_project_key: resolving that shells out for the remote
# URL and costs ~39ms, which is part of the setup the Bash pre-gate exists to
# skip. The baseline is scratch and is never joined to the ledger, so it does
# not need the ledger's identity — only stability within a session.
lineage_baseline_scope_id() {
	local root="${1:-unknown}"
	lineage_sha256 "$root" | cut -c1-12
}
```

Then change `lineage_baseline_path` to take a scope id rather than a project key. Its first
argument is now the scope id; the body is otherwise unchanged.

- [ ] **Step 4: Reorder the hook**

In `plugins/lineage/scripts/hooks/lineage-post-tool-use.sh`, move the whole `if [[ "$TOOL" == "Bash" ]]` block
to sit **immediately after** `REPO_ROOT=$(lineage_project_repo_root "$CWD")` (currently line 78)
and **before** `lineage_config_load` and `PROJECT_KEY=$(lineage_project_key "$CWD")`.

Inside the Bash block, the order becomes:

1. `[[ -z "$REPO_ROOT" ]] && _done`
2. `BASELINE_FILE=$(lineage_baseline_path "$(lineage_baseline_scope_id "$REPO_ROOT")" "$SESSION_ID")`
3. read the baseline; if it has no `files` key, write a fresh one and `_done` (first call seeds)
4. `CHANGED=$(lineage_changed_files "$REPO_ROOT" "$BASELINE")`
5. **if `CHANGED` is empty: rewrite the baseline and `_done` — this is the pre-gate**
6. only now: `lineage_config_load "$REPO_ROOT"`, `PROJECT_KEY=$(lineage_project_key "$CWD")`,
   the accessors, and the existing per-file record loop
7. rewrite the baseline and `_done`

Immediately after step 6's setup calls, add the test probe:

```bash
	[[ -n "${LINEAGE_TRACE_SETUP:-}" ]] && printf 'SETUP_DONE\n' >&2
```

Keep `lineage_config_load` and `lineage_project_key` where they are for the
`Edit`/`Write`/`MultiEdit` path — that path is unchanged by this task and must stay so.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bats test/bats/lineage-baseline.bats test/bats/lineage-shell-edit.bats
shellcheck -S error -x plugins/lineage/scripts/hooks/lineage-post-tool-use.sh
shellcheck -S error -x plugins/lineage/scripts/lib/lineage-baseline.sh
```

Expected: all PASS, shellcheck silent.

- [ ] **Step 6: Measure the improvement**

```bash
cd <this repo>
INPUT=$(jq -cn --arg cwd "$PWD" '{cwd:$cwd, session_id:"lat", tool_name:"Bash", tool_input:{command:"echo hi"}, hook_event_name:"PostToolUse"}')
for i in 1 2 3 4 5; do
  s=$(python3 -c 'import time;print(int(time.time()*1000))')
  printf '%s' "$INPUT" | env ONLOOKER_DIR=/tmp/lat-check CLAUDE_PLUGIN_ROOT="$PWD/plugins/lineage" \
    bash plugins/lineage/scripts/hooks/lineage-post-tool-use.sh >/dev/null 2>&1
  e=$(python3 -c 'import time;print(int(time.time()*1000))')
  echo "run $i: $((e-s)) ms"
done
```

Baseline to beat: ~370 ms. Target: under ~150 ms for the no-change case. Record the real
numbers in the report. If it does not improve materially, say so rather than reporting the
target — a pre-gate that does not gate is worth knowing about.

- [ ] **Step 7: Full suite**

```bash
npm run test:bats
```

Do NOT pipe this through `tail` — `tail` on a pipe buffers until EOF, so the output stays
empty for the whole run and looks like a hang. Redirect to a file and read it.

- [ ] **Step 8: Commit**

Use the `/commit` skill. Suggested message:

```text
perf(lineage): decide before paying setup on a shell call :zap:

A Bash call that changed nothing cost ~370ms, because the hook resolved
config and the project key before asking whether there was anything to
record. lineage never ran on Bash before this plan, so that went from never
to every shell call, and Bash outruns Edit about 30:1.

The detection was never the expensive part -- git status is 34ms. Setup is,
so the Bash path now runs the comparison first and only pays for setup when
there is a record to write.

The baseline gets its own cheap scope id rather than the project key, whose
resolution is itself part of the cost being skipped. It is per-session
scratch and never joined to the ledger, so it does not need the ledger's
identity.

Refs ecosystem-449.13
```

---

### Task 5: Prune the new store, document the limits, measure the cost

**Depends on:** Task 4.

**Files:**

- Modify: `scripts/onlooker-store-prune.mjs` — the `STORES` allowlist
- Modify: `test/bats/onlooker-store-prune.bats` — a case for the new store
- Modify: `plugins/lineage/README.md` — the hook table and a limitations section

**Interfaces:**

- Consumes: the baseline store from Task 2.
- Produces: the measurement `ecosystem-449.11` needs.

- [ ] **Step 1: Write the failing test**

In `test/bats/onlooker-store-prune.bats`, add `"${ONLOOKER_DIR}/lineage-baselines/abc123"` to the `mkdir -p` list in `setup()`, then add:

```bash
@test "prunes stale lineage baselines but keeps fresh ones" {
  printf '{}' > "${ONLOOKER_DIR}/lineage-baselines/abc123/old.json"
  printf '{}' > "${ONLOOKER_DIR}/lineage-baselines/abc123/fresh.json"
  _age_days "${ONLOOKER_DIR}/lineage-baselines/abc123/old.json" 5

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/lineage-baselines/abc123/old.json" ] || return 1
  [ -f "${ONLOOKER_DIR}/lineage-baselines/abc123/fresh.json" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bats test/bats/onlooker-store-prune.bats
```

Expected: the new test fails — `lineage-baselines` is not in `STORES`, so nothing is scanned and `old.json` survives.

- [ ] **Step 3: Add the store to the allowlist**

Two changes are needed, not one. `pruneStore` currently does `if (!entry.isFile()) continue;`, so it reads only files sitting directly in the store directory. Every existing store is flat; `lineage-baselines` is partitioned by project key, so its files sit one level down and an allowlist entry alone would scan zero files and silently report success — exactly the failure this store-bounding effort exists to prevent.

First, add the entry to `STORES`. It is `scratch`, matching `session-trackers`: a baseline is meaningless once its session ends.

```javascript
  { name: 'lineage-baselines', segments: ['lineage-baselines'], policy: 'scratch', nested: true },
```

Then teach `pruneStore` about one level of nesting. Replace its opening — from `const dir = join(...)` through the `readdirSync` try/catch — with:

```javascript
function pruneStore(root, store, opts, now) {
  const base = join(root, ...store.segments);
  const result = { name: store.name, scanned: 0, deleted: 0, reclaimedBytes: 0 };
  if (!existsSync(base)) return result;

  const cutoff =
    store.policy === 'scratch' ? now - opts.scratchMaxAgeHours * HOUR_MS : now - opts.retentionDays * DAY_MS;

  // Most stores are flat. lineage-baselines is partitioned by project key, so
  // its files live one level down — a flat read would scan nothing and report
  // success, which is how a store silently stops being pruned.
  let dirs = [base];
  if (store.nested === true) {
    try {
      dirs = readdirSync(base, { withFileTypes: true })
        .filter((e) => e.isDirectory())
        .map((e) => join(base, e.name));
    } catch {
      return result; // Unreadable directory: fail soft.
    }
  }

  for (const dir of dirs) {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue; // Unreadable subdirectory: skip, don't fail the run.
    }
```

Keep the existing `for (const entry of entries) { ... }` body exactly as it is, then close the new outer loop with one extra `}` before `return result;`. The `cutoff` calculation moves above the loop, so delete the original one that sat between `existsSync` and `readdirSync`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bats test/bats/onlooker-store-prune.bats
npm run lint:check
```

Expected: all PASS; biome clean. If biome reformats, run `./node_modules/.bin/biome format --write scripts/onlooker-store-prune.mjs`.

- [ ] **Step 5: Document the limits in lineage's README**

In `plugins/lineage/README.md`, add `Bash` to the hook table's matcher column, and add this section after "Content-anchored provenance":

```markdown
### What shell-shaped edits can and cannot tell you

Lineage watches `Bash` as well as the edit tools, so a change made with a
heredoc, `sed -i`, or a short script still lands in the ledger. It gets there a
different way: git is asked what changed, rather than the tool being asked what
it did. Two fields say what that record is worth.

`provenance_kind` separates an authored edit from mechanical churn — a
formatter, a package manager, a branch switch. Classification reads the command
string, and **anything unrecognized is recorded as `authored`**. An
unclassified writer therefore shows up as noise rather than disappearing, which
is the failure this exists to prevent.

`content_scope` is the honest caveat. When the file was clean beforehand,
`delta` means the captured content is exactly this change. When it was already
modified, `cumulative` means the content also includes earlier uncommitted
work, because git diffs against the last commit and not against the last edit.
**`cumulative` is the common case**, since agents usually work with a dirty
tree. The content-anchored lookup tolerates it — a line is attributed to a
slightly later change rather than to nothing — but a `cumulative` record is a
weaker claim than a `delta` one.
```

- [ ] **Step 6: Measure the cost on the hot path**

This is the number `ecosystem-449.11` depends on, and the check `ecosystem-449.14` shows inspector failed. Restart the session so the new hook registers, then:

```bash
python3 ~/.onlooker/logs/hook-rollup.py <new-session-id>
```

Compare `PostToolUse / lineage-post-tool-use` on `Bash` against the ~35ms `tool-sequence-tracker` baseline. Record the p50 and p95 in `ecosystem-449.13`.

If the p50 on Bash exceeds roughly 150ms, stop and report rather than shipping. Bash outruns `Edit` by about 30:1, so this cost is paid per shell call for a whole session — the "cheap per-edit loop" claim has to survive contact with a real number.

- [ ] **Step 7: Full CI pass**

```bash
npm run test:ci
```

Expected: shellcheck, bats, schema, bus coverage, biome, markdownlint, and the manifest/reference linters all green. No `test/bus-coverage.json` change is needed — no new event *type* is introduced.

- [ ] **Step 8: Commit and open the PR**

Use the `/commit` skill, then `/git-workflow:pr`. Suggested commit:

```text
chore(lineage): bound the baseline store and state the caveats :broom:

Baselines are per-session scratch, so the prune script needs to know about
them. They deliberately live outside lineage/, which is on the durable
never-touch list -- a per-session file there would recreate ecosystem-449.2
inside the store that bead just bounded.

README now says what a shell-detected record is worth: that unrecognized
commands are recorded as authored rather than dropped, and that cumulative
content is the common case, not the exception.

Refs ecosystem-449.13
```

---

## Self-review notes

**Spec coverage.** §3 detection → Task 2 (`lineage_candidate_paths` enumerates modified AND untracked, `lineage_changed_files` compares per-path content shas) and Task 4 (wiring). §4 baseline location → Task 2 `lineage_baseline_dir`, asserted in Task 2 Step 1 and again in Task 4. §4 `provenance_kind` / `content_scope` → Tasks 2 and 3, emitted in Task 4. §5 schema → Task 1, gated by the Global Constraint that Task 3 waits for the release. §6 `git status` cost → Task 5 Step 6, with a stated abort threshold. §6 lockfile noise → Task 4 Step 4, both duplicated defaults. §6 non-git → Task 2 (`lineage_candidate_paths` returns empty) and Task 4 (`REPO_ROOT` guard), tested in both. §7 testing → every listed case appears in Task 2 Step 1 or Task 4 Step 1. §8 out of scope → inspector is `ecosystem-6dv`, not this plan.

**Type consistency.** `lineage_build_record`'s three new trailing parameters are `added_override`, `prov_kind`, `content_scope` in Task 3's implementation, and are passed positionally in that order in Task 4's hook block. Record field names `provenance_kind` and `content_scope` match the schema enum values in Task 1 (`authored`/`tool_generated`, `delta`/`cumulative`) and the assertions in Tasks 2–4.

**Known risk carried deliberately.** Task 4 skips a changed file when `lineage_added_content` is empty — a pure deletion produces no added lines and so is not recorded. Lineage is content-anchored and cannot answer "why does this line exist?" for a line that no longer exists, so a deletion-only record would carry no queryable content. Worth its own bead if deletion provenance is ever wanted; out of scope here.

**One judgment call flagged for review.** Task 5 Step 3 changes `pruneStore` itself rather than only the allowlist. Every existing store is flat, so supporting a project-key-partitioned store needs one level of directory recursion — a real change to shipped, already-released code, not a config addition.
