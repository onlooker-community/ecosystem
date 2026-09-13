# Config root resolution implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move repo-root resolution inside `config_load_plugin` so no call site can
pick a wrong root, and split settings layers 4 and 5 across the worktree and parent
checkouts respectively.

**Architecture:** `config_load_plugin` takes the session cwd instead of a repo root
and derives both roots itself in one `git rev-parse` call. Layer 4
(`.claude/settings.json`, committed, branch-scoped) resolves against the worktree;
layer 5 (`.claude/settings.local.json`, gitignored, machine-scoped) resolves against
the parent checkout. Seventeen call sites change from a root to `$CWD`; sixteen
already pass `$CWD` and are fixed by the loader without edits.

**Tech Stack:** bash (vendored shared libs), bats-core, jq, git plumbing.

**Spec:** `docs/superpowers/specs/2026-09-13-config-root-resolution-design.md`

## Global Constraints

- **Indentation is tabs** in `.sh` and `.bats` files under `scripts/` and `plugins/`.
- **`shellcheck -S error` must pass** — `npm run test:shellcheck` covers `*.sh` and `*.bats`.
- **Non-final `[[ ]]` and `!` assertions in bats need `|| return 1`.** `bats` resolves
  to system bash 3.2 on macOS, where a failing non-final `[[ ]]` does not fail the
  test body. Only the last assertion in a body is safe ungated. Do not swap to `[ ]` —
  these assertions rely on `[[ ]]`-only behavior.
- **Never reference a literal `~/.onlooker`** — always `$ONLOOKER_DIR`.
- **Every bats file sources `test/helpers/setup.bash` and calls `setup_test_env`** first.
- **American English** in comments, commits, and docs.
- **`scripts/lib/config-loader.sh` is canonical.** Never edit a vendored copy under
  `plugins/*/scripts/lib/`; edit the canonical file and run `scripts/sync-shared-libs.sh`.
- **Commit through the `/commit` skill**, never ad hoc `git commit -m`.
- **Open a PR — never push to `main`.** Branch is `fix/config-root-resolution`.
- **No new event types.** Nothing here emits, so `test/bus-coverage.json` is untouched.

---

### Task 1: Loader resolves its own roots

**Files:**
- Modify: `scripts/lib/config-loader.sh:56-100` (the `config_load_plugin` header and body)
- Test: `test/bats/config-loader-roots.bats` (create)
- Propagate: `plugins/*/scripts/lib/config-loader.sh` (16 vendored copies, via script)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `config_load_plugin <plugin_name> <cwd> <output_var>` — argument 2 is now a
    session cwd, not a repo root. Arity and return value unchanged.
  - `_config_resolve_roots <cwd>` — sets `_CONFIG_WORKTREE_ROOT` and
    `_CONFIG_PARENT_ROOT` in the caller's scope. Both are absolute, `pwd -P`
    resolved, or empty when cwd is empty or nonexistent.

- [ ] **Step 1: Write the failing test**

Create `test/bats/config-loader-roots.bats`:

```bash
#!/usr/bin/env bats
#
# config_load_plugin resolves its own roots (ecosystem-449.37 acceptance 5).
#
# The loader used to take a repo root and build both repo-scoped layers from it.
# Any string was accepted, so a wrong one produced no error, no event and no test
# failure — the layers simply did not exist and the plugin ran on shipped
# defaults. Three bugs came out of that hole (ecosystem-ber, ecosystem-68z, and
# the two categories below).
#
# It now takes the session cwd and derives both roots itself:
#
#   layer 4  <worktree>/.claude/settings.json        committed, branch-scoped
#   layer 5  <parent>/.claude/settings.local.json    gitignored, machine-scoped
#
# Driven from a real `git worktree add` rather than a simulated layout, because
# --git-common-dir only returns a relative path in a real checkout and only
# returns an absolute one in a real linked worktree. A faked directory tree
# exercises neither branch.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# A throwaway plugin so layer 1 (shipped defaults) is under test control.
	PLUGIN_DIR="${BATS_TEST_TMPDIR}/fakeplugin"
	mkdir -p "$PLUGIN_DIR"
	# Shaped like a real plugin config.json: a plugin_name key beside a
	# plugin-scoped block. Layer 1 is merged whole, layers 2-5 only by that key.
	printf '%s\n' '{"plugin_name":"probe","probe":{"value":"SHIPPED_DEFAULT"}}' \
		> "${PLUGIN_DIR}/config.json"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "${MAIN}/sub/dir" "${MAIN}/.claude"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email test@example.com
	git -C "$MAIN" config user.name test
	printf '%s\n' '{"probe":{"value":"MAIN_L4"}}' > "${MAIN}/.claude/settings.json"
	printf '%s\n' '{"probe":{"local":"MAIN_L5"}}' > "${MAIN}/.claude/settings.local.json"
	git -C "$MAIN" add -A
	git -C "$MAIN" commit -qm init

	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch
	mkdir -p "${WT}/.claude" "${WT}/sub/dir"
	printf '%s\n' '{"probe":{"value":"WORKTREE_L4"}}' > "${WT}/.claude/settings.json"

	# shellcheck source=../../scripts/lib/config-loader.sh
	source "${REPO_ROOT}/scripts/lib/config-loader.sh"
}

# config_load_plugin sets its output variable in the caller's scope, and
# config_get reads it back by name, so a local here is visible to both.
_value_from() {
	local probe_config=""
	config_load_plugin "probe" "$1" "probe_config"
	config_get "probe_config" '.probe.value'
}

_local_from() {
	local probe_config=""
	config_load_plugin "probe" "$1" "probe_config"
	config_get "probe_config" '.probe.local'
}

@test "a subdirectory cwd still resolves layer 4" {
	# Category B: the loader built ${cwd}/.claude/settings.json with no upward
	# walk, so a session started anywhere but the root read shipped defaults.
	run _value_from "${MAIN}/sub/dir"
	[ "$output" = "MAIN_L4" ]
}

@test "a worktree cwd reads the worktree's layer 4, not the parent's" {
	# Category A. Both trees carry a settings.json with a DIFFERENT value, so
	# this cannot pass by one of them being absent.
	run _value_from "$WT"
	[ "$output" = "WORKTREE_L4" ]
}

@test "a worktree cwd reads the parent's layer 5" {
	# settings.local.json is gitignored, so `git worktree add` never copies it
	# and it exists only in the main checkout. Resolving layer 5 against the
	# worktree would silently drop every local override in a worktree session.
	run _local_from "$WT"
	[ "$output" = "MAIN_L5" ]
}

@test "a worktree subdirectory resolves the worktree, not the parent" {
	# Both defects composed. --git-common-dir is relative to CWD, so resolving
	# it from the toplevel instead of from cwd climbs one level too far here.
	run _value_from "${WT}/sub/dir"
	[ "$output" = "WORKTREE_L4" ]
}

@test "layer 5 still outranks layer 4 across the two roots" {
	# Only the roots moved; precedence order is unchanged.
	printf '%s\n' '{"probe":{"value":"MAIN_L5_WINS"}}' \
		> "${MAIN}/.claude/settings.local.json"
	run _value_from "$WT"
	[ "$output" = "MAIN_L5_WINS" ]
}

@test "a non-git cwd reads its own .claude/settings.json" {
	# .claude/settings.json is a Claude Code concept, not a git one. 19 of the
	# 36 bats files that write a settings fixture never git init at all.
	local plain="${BATS_TEST_TMPDIR}/plain"
	mkdir -p "${plain}/.claude"
	printf '%s\n' '{"probe":{"value":"PLAIN_L4"}}' > "${plain}/.claude/settings.json"
	run _value_from "$plain"
	[ "$output" = "PLAIN_L4" ]
}

@test "a cwd with no .claude falls back to shipped defaults" {
	local bare="${BATS_TEST_TMPDIR}/bare"
	mkdir -p "$bare"
	run _value_from "$bare"
	[ "$output" = "SHIPPED_DEFAULT" ]
}

@test "an empty cwd falls back to shipped defaults" {
	run _value_from ""
	[ "$output" = "SHIPPED_DEFAULT" ]
}

@test "a repo root passed as cwd still resolves" {
	# The vendored-copy guarantee: a caller that still passes a root is passing
	# a valid cwd, so there is no flag day across the 16 copies.
	run _value_from "$MAIN"
	[ "$output" = "MAIN_L4" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/config-loader-roots.bats`

Expected: **exactly four FAIL** — the subdirectory, worktree-layer-5,
worktree-subdirectory, and layer-5-precedence tests.

The other five PASS already, and that is correct. Today's loader uses whatever
root it is handed, so passing `$WT` happens to read `$WT` — "a worktree cwd reads
the worktree's layer 4" is a **pin**, not a driver. It exists so the change cannot
regress the case it already gets right. Same for the non-git, no-`.claude`,
empty-cwd and repo-root tests.

If more than four fail, the fixture is wrong. If fewer than four fail, the test is
not reaching the defect — fix that before writing any implementation.

- [ ] **Step 3: Add the resolver to the canonical loader**

In `scripts/lib/config-loader.sh`, insert immediately above `config_load_plugin`:

```bash
# Resolve the two repo-scoped roots from a session cwd.
#
# Sets, in the caller's scope:
#   _CONFIG_WORKTREE_ROOT  --show-toplevel      the tree this session is in
#   _CONFIG_PARENT_ROOT    --git-common-dir/..  the main checkout
#
# The two are the same in a normal checkout and differ in a linked worktree,
# where the parent is where a gitignored settings.local.json actually lives.
#
# Resolution lives here rather than at the call sites on purpose. Thirty-three
# callers each picking a root is how ecosystem-ber, ecosystem-68z and
# ecosystem-449.37 all happened: a wrong root is accepted silently and reads as
# "no config" rather than as an error. No caller picks one now, so none can pick
# a wrong one.
#
# Memoized on cwd. Hooks are one process per fire, so the cache cannot outlive a
# single invocation.
_config_resolve_roots() {
	local cwd="${1:-}"

	_CONFIG_WORKTREE_ROOT=""
	_CONFIG_PARENT_ROOT=""

	if [[ -z "$cwd" || ! -d "$cwd" ]]; then
		return 0
	fi

	if [[ "${_CONFIG_ROOTS_CWD:-}" == "$cwd" ]]; then
		_CONFIG_WORKTREE_ROOT="${_CONFIG_ROOTS_WORKTREE:-}"
		_CONFIG_PARENT_ROOT="${_CONFIG_ROOTS_PARENT:-}"
		return 0
	fi

	# One fork for both answers; git emits them in argument order. Two separate
	# rev-parse calls measured ~9.7ms against ~4.8ms for this, and hook cost is
	# already a live concern (ecosystem-449.29, 449.43, ff7, 6ce).
	local out=""
	out=$(git -C "$cwd" rev-parse --show-toplevel --git-common-dir 2>/dev/null) || out=""

	local toplevel="" common_dir=""
	if [[ -n "$out" ]]; then
		toplevel=$(printf '%s\n' "$out" | sed -n '1p')
		common_dir=$(printf '%s\n' "$out" | sed -n '2p')
	fi

	if [[ -n "$toplevel" ]]; then
		_CONFIG_WORKTREE_ROOT=$(cd "$toplevel" 2>/dev/null && pwd -P) \
			|| _CONFIG_WORKTREE_ROOT=""
	fi

	# --git-common-dir is relative in a normal checkout (".git" from the root,
	# "../.git" from a subdirectory) and absolute in a linked worktree. It is
	# relative to CWD, not to the toplevel — resolving it from the toplevel
	# climbs one level too far for any session started in a subdirectory.
	if [[ -n "$common_dir" ]]; then
		if [[ "$common_dir" != /* ]]; then
			common_dir=$(cd "$cwd" && cd "$common_dir" 2>/dev/null && pwd -P) \
				|| common_dir=""
		fi
		if [[ -n "$common_dir" && -d "$common_dir" ]]; then
			_CONFIG_PARENT_ROOT=$(cd "${common_dir}/.." 2>/dev/null && pwd -P) \
				|| _CONFIG_PARENT_ROOT=""
		fi
	fi

	# Outside a repo git answers nothing, but .claude/settings.json is a Claude
	# Code concept rather than a git one and a plain directory can carry one.
	# Fall back to cwd so a non-git project keeps its config. There is no upward
	# walk here: outside git there is no defined project boundary to walk to.
	if [[ -z "$_CONFIG_WORKTREE_ROOT" ]]; then
		_CONFIG_WORKTREE_ROOT="$cwd"
	fi
	if [[ -z "$_CONFIG_PARENT_ROOT" ]]; then
		_CONFIG_PARENT_ROOT="$_CONFIG_WORKTREE_ROOT"
	fi

	_CONFIG_ROOTS_CWD="$cwd"
	_CONFIG_ROOTS_WORKTREE="$_CONFIG_WORKTREE_ROOT"
	_CONFIG_ROOTS_PARENT="$_CONFIG_PARENT_ROOT"
	return 0
}
```

- [ ] **Step 4: Point `config_load_plugin` at the resolver**

In `scripts/lib/config-loader.sh`, change the argument doc block from:

```bash
#   $2 = repo root (or empty for no-repo defaults)
```

to:

```bash
#   $2 = session cwd (or empty for no-repo defaults). NOT a repo root — the
#        loader resolves the worktree and parent roots from it itself.
```

Change the local declaration from:

```bash
	local repo_root="${2:-}"
```

to:

```bash
	local cwd="${2:-}"
```

and replace these two lines:

```bash
	[[ -n "$repo_root" ]] && repo_file="${repo_root}/.claude/settings.json"
	[[ -n "$repo_root" ]] && repo_local_file="${repo_root}/.claude/settings.local.json"
```

with:

```bash
	# Layer 4 is committed and therefore branch-scoped: a worktree must see its
	# own branch's copy. Layer 5 is gitignored and therefore machine-scoped:
	# `git worktree add` never copies it, so it lives only in the parent.
	_config_resolve_roots "$cwd"
	if [[ -n "$_CONFIG_WORKTREE_ROOT" ]]; then
		repo_file="${_CONFIG_WORKTREE_ROOT}/.claude/settings.json"
	fi
	if [[ -n "$_CONFIG_PARENT_ROOT" ]]; then
		repo_local_file="${_CONFIG_PARENT_ROOT}/.claude/settings.local.json"
	fi
```

- [ ] **Step 5: Update the precedence block in the loader header**

Replace lines 49-54 of `scripts/lib/config-loader.sh`:

```bash
# Precedence (latest wins):
#   1. plugin config.json (shipped defaults)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
```

with:

```bash
# Precedence (latest wins):
#   1. plugin config.json (shipped defaults)
#   2. <claude_dir>/settings.json
#   3. <claude_dir>/settings.local.json (local overrides user)
#   4. <worktree>/.claude/settings.json        committed, branch-scoped
#   5. <parent>/.claude/settings.local.json    gitignored, machine-scoped
#
# Layers 4 and 5 resolve against DIFFERENT roots. settings.json is committed, so
# a worktree on a feature branch must see its own copy — the dogfooding rollout
# stages plugin enablement through exactly that file. settings.local.json is
# gitignored, so `git worktree add` never copies it and it exists only in the
# main checkout; resolving it against the worktree would silently drop every
# local override in a worktree session. See ecosystem-449.37 and ADR-004.
```

- [ ] **Step 6: Run the new test to verify it passes**

Run: `bats test/bats/config-loader-roots.bats`
Expected: 9 tests, all PASS.

- [ ] **Step 7: Propagate to the 16 vendored copies**

```bash
scripts/sync-shared-libs.sh
git status --short plugins/
```

Expected: 16 modified `plugins/*/scripts/lib/config-loader.sh`. Verify none drifted:

```bash
scripts/sync-shared-libs.sh --check && echo "SYNC OK"
```

- [ ] **Step 8: Run the full suite to catch back-compat fallout**

```bash
npm run test:bats
echo "BATS_EXIT=$?"
```

Run each leg separately — never pipe the command into something that reads `$?`,
because the pipe's exit code masks the command's.

Expected: no new failures. The 19 no-git fixture files are the population at
risk; they are covered by the non-git fallback in step 3. If any fail, the
fallback is wrong — fix the loader, not the test.

- [ ] **Step 9: Shellcheck**

```bash
npm run test:shellcheck
echo "SHELLCHECK_EXIT=$?"
```

Expected: exit 0.

- [ ] **Step 10: Commit**

Use the `/commit` skill. Stage exactly:

```bash
git add scripts/lib/config-loader.sh plugins/*/scripts/lib/config-loader.sh \
        test/bats/config-loader-roots.bats
```

Message shape — `fix(config)`, subject under 72 characters including the emoji,
body explaining why the roots differ rather than what the diff does.

---

### Task 2: Migrate the call sites, guarded by an enforcement test

**Files:**
- Create: `test/bats/config-load-cwd-argument.bats`
- Modify: 14 hooks passing `$REPO_ROOT`, plus `plugins/inspector/scripts/hooks/inspector-post-write.sh:76,82` and `plugins/librarian/scripts/hooks/librarian-session-end.sh:88`

**Interfaces:**
- Consumes: `config_load_plugin <plugin> <cwd> <out>` from Task 1.
- Produces: every `*_config_load` call site in `plugins/*/scripts/hooks/*.sh` passes `"$CWD"`.

- [ ] **Step 1: Write the failing enforcement test**

Create `test/bats/config-load-cwd-argument.bats`:

```bash
#!/usr/bin/env bats
#
# Guards that no hook hands *_config_load a project-key root.
#
# config_load_plugin resolves the worktree and parent roots from a session cwd
# itself (ecosystem-449.37). A caller can no longer pick a wrong root, but it can
# still hand the resolver the wrong INPUT, and passing a project-key root is the
# mistake that reads as correct: *_project_repo_root deliberately resolves a
# linked worktree to its parent checkout, so a worktree session would resolve to
# the parent and read a different branch's config.
#
# Covers all hooks at once so plugin 17 cannot quietly reintroduce the pattern.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

_hooks() {
	find "${REPO_ROOT}/plugins" -path '*/scripts/hooks/*.sh' -type f | sort
}

# Without this, a typo in _hooks would make the test below pass over an empty
# list and report coverage that does not exist.
@test "the hook glob matches at least one file" {
	local count
	count=$(_hooks | wc -l | tr -d ' ')
	[ "$count" -gt 0 ]
}

@test "no hook passes a project-key root into *_config_load" {
	local offenders=""
	local hook
	while IFS= read -r hook; do
		if grep -qE '_config_load[[:space:]]+"\$\{?REPO_ROOT' "$hook"; then
			offenders+="${hook#"${REPO_ROOT}/"} (\$REPO_ROOT)"$'\n'
		fi
		if grep -qE '_config_load[[:space:]]+"\$\(.*_project_repo_root' "$hook"; then
			offenders+="${hook#"${REPO_ROOT}/"} (inline *_project_repo_root)"$'\n'
		fi
	done < <(_hooks)

	[ -z "$offenders" ] || {
		printf 'hooks passing a project-key root to *_config_load:\n%s' "$offenders" >&2
		return 1
	}
}
```

- [ ] **Step 2: Run it to verify it fails and names every offender**

Run: `bats test/bats/config-load-cwd-argument.bats`

Expected: FAIL, with 14 files listed as `($REPO_ROOT)`, `inspector-post-write.sh`
listed once, and `librarian-session-end.sh` listed as
`(inline *_project_repo_root)`. Confirm the count before changing anything — if
it names fewer than 15 files, the regex is wrong and the test would pass over
real offenders.

- [ ] **Step 3: Migrate the `$REPO_ROOT` call sites**

```bash
perl -pi -e 's/(_config_load) "\$REPO_ROOT"/$1 "\$CWD"/' \
  plugins/*/scripts/hooks/*.sh
```

`perl -pi` rather than `sed -i` because `sed -i` needs an empty-string argument
on BSD/macOS and must not have one on GNU/Linux.

- [ ] **Step 4: Migrate librarian's inline call site by hand**

In `plugins/librarian/scripts/hooks/librarian-session-end.sh:88`, change:

```bash
librarian_config_load "$(librarian_project_repo_root "$CWD")"
```

to:

```bash
librarian_config_load "$CWD"
```

Leave line 96 alone — `REPO_ROOT=$(librarian_project_repo_root "$CWD")` still
feeds `librarian_storage_write_manifest`, which genuinely wants identity.

- [ ] **Step 5: Verify no call site was missed and none was over-matched**

```bash
grep -rn '_config_load ' plugins/*/scripts/hooks/*.sh | grep -v '"\$CWD"'
```

Expected: no output other than the two explanatory comment lines in
`lineage-post-tool-use.sh`.

```bash
grep -rc '_config_load "\$CWD"' plugins/*/scripts/hooks/*.sh | \
  awk -F: '{s+=$2} END {print "call sites now passing CWD:", s}'
```

Expected: `33`.

- [ ] **Step 6: Confirm `$REPO_ROOT` is still used where it should be**

```bash
grep -rn 'REPO_ROOT' plugins/librarian/scripts/hooks/librarian-session-end.sh
```

Expected: the assignment at :96 and its use in `librarian_storage_write_manifest`
remain. A migration that deleted them would move librarian's storage partition
and break acceptance 7.

- [ ] **Step 7: Run the enforcement test to verify it passes**

Run: `bats test/bats/config-load-cwd-argument.bats`
Expected: 2 tests, both PASS.

- [ ] **Step 8: Run the full suite**

```bash
npm run test:bats
echo "BATS_EXIT=$?"
```

Expected: no new failures. Hook tests that stood up a fixture repo and passed its
root as `cwd` keep working — the loader resolves a root to itself.

- [ ] **Step 9: Verify the worktree behavior end to end**

The regression this whole change exists to fix, driven through a real hook rather
than the loader in isolation:

```bash
bats test/bats/tribunal-stop-gate-worktree.bats \
     test/bats/echo-stop-gate-worktree.bats \
     test/bats/lineage-worktree.bats \
     test/bats/archivist-extract-worktree.bats \
     test/bats/scribe-distill-worktree.bats
echo "WORKTREE_EXIT=$?"
```

Expected: exit 0.

- [ ] **Step 10: Commit**

Use the `/commit` skill. Stage the 15 modified hooks plus the new bats file.

---

### Task 3: Reconcile the documentation with the code

**Files:**
- Modify: `plugins/*/scripts/lib/*-config.sh` (16 files — header block and parameter name)
- Modify: `plugins/lineage/scripts/hooks/lineage-post-tool-use.sh:150-154`
- Modify: `docs/adr/004-plugin-config-with-settings-overlay.md`

**Interfaces:**
- Consumes: the loader contract from Task 1.
- Produces: no runtime change. Documentation only.

This task is not cosmetic in this repo. `archivist_validate_repo_path` carried a
docstring claiming it resolved worktree paths against the worktree's toplevel; it
never did, and the wrong docstring was recorded as part of the defect in
`ecosystem-449.37`. Sixteen config libs currently document a precedence that is no
longer what the loader does.

- [ ] **Step 1: Rewrite the 16 config-lib headers and parameter names**

```bash
for lib in plugins/*/scripts/lib/*-config.sh; do
	perl -pi -e '
		s{^#   4\. <repo>/\.claude/settings\.json$}{#   4. <worktree>/.claude/settings.json (committed, branch-scoped)};
		s{^#   5\. <repo>/\.claude/settings\.local\.json \(local overrides project\)$}{#   5. <parent>/.claude/settings.local.json (gitignored, machine-scoped)};
		s{(_config_load) <repo_root>}{$1 <cwd>};
		s{^\tlocal repo_root="\$\{1:-\}"$}{\tlocal cwd="\${1:-}"};
		s{(config_load_plugin "[a-z]+") "\$repo_root"}{$1 "\$cwd"};
	' "$lib"
done
```

- [ ] **Step 2: Verify every lib was rewritten and none was missed**

```bash
grep -rn 'repo_root' plugins/*/scripts/lib/*-config.sh
```

Expected: no output.

```bash
grep -rc '<worktree>/.claude/settings.json' plugins/*/scripts/lib/*-config.sh | \
  awk -F: '{s+=$2} END {print "libs documenting the split:", s}'
```

Expected: `16`.

- [ ] **Step 3: Confirm the rewrite changed no behavior**

```bash
npm run test:bats
echo "BATS_EXIT=$?"
```

Expected: no new failures. The parameter is positional, so renaming the local is
inert — this run proves it rather than assuming it.

- [ ] **Step 4: Settle the lineage deferral comment**

In `plugins/lineage/scripts/hooks/lineage-post-tool-use.sh`, replace lines 150-154:

```bash
# The two lineage_config_load calls below are the deliberate exception: they
# still take REPO_ROOT, so a worktree reads its parent checkout's config. That
# is config resolution rather than a path operation, it is the same question
# every plugin here answers the same way, and ecosystem-449.37 settles it across
# all of them. Left alone here so this change stays one decision wide.
```

with:

```bash
# The two lineage_config_load calls below take CWD, not REPO_ROOT. The loader
# resolves both repo-scoped roots itself and splits the layers across them:
# settings.json from the worktree because it is committed and therefore
# branch-scoped, settings.local.json from the parent because it is gitignored
# and therefore machine-scoped. Settled for all sixteen plugins at once in
# ecosystem-449.37 acceptance 5.
```

- [ ] **Step 5: Record the consequence in ADR-004**

Append to the `## Consequences` section of
`docs/adr/004-plugin-config-with-settings-overlay.md`:

```markdown
- Project-level layers 4 and 5 resolve against **different roots**.
  `.claude/settings.json` is committed and therefore branch-scoped, so it is read
  from the worktree the session is actually in; `.claude/settings.local.json` is
  gitignored and therefore machine-scoped, so `git worktree add` never copies it
  and it is read from the parent checkout. `config_load_plugin` takes a session
  cwd and derives both roots itself rather than accepting one — three bugs
  (`ecosystem-ber`, `ecosystem-68z`, `ecosystem-449.37`) all traced to a caller
  supplying a root that was silently wrong. See
  `docs/superpowers/specs/2026-09-13-config-root-resolution-design.md`.
```

- [ ] **Step 6: Shellcheck and full CI locally**

```bash
npm run test:ci
echo "CI_EXIT=$?"
```

Expected: exit 0.

- [ ] **Step 7: Commit**

Use the `/commit` skill. Stage the 16 config libs, the lineage hook, and ADR-004.

---

### Task 4: Record the decisions and open the PR

**Files:**
- No source changes. Beads and PR only.

**Interfaces:**
- Consumes: Tasks 1-3 complete and committed.
- Produces: `ecosystem-449.37` acceptance 5 answered; a child bead recording category B.

- [ ] **Step 1: File the category B bead**

```bash
bd create "config_load_plugin drops both project settings layers when the session starts in a subdirectory" \
  --type bug \
  --priority 1 \
  --deps "discovered-from:ecosystem-449.37" \
  --description "config_load_plugin built \${root}/.claude/settings.json directly from whatever root it was handed, with no upward walk. Sixteen call sites across bursar, compass, governor, scribe and warden passed the session cwd straight off the hook payload, so any session started in a subdirectory of the repo resolved both project layers to paths that do not exist and ran on shipped defaults.

Silent on every path: no error, no event, no test failure. Verified against the real loader --

  repo root passed in -> FROM_REPO_SETTINGS
  subdir   passed in -> SHIPPED_DEFAULT

OBSERVED, not theoretical. Eight sessions recorded in onlooker state started in a subdirectory: onlooker/apps/web (4), onlooker/apps/web/src (3), onlooker/packages/brand (1). For all eight, those five plugins ran with no project config at all.

Shares a signature with ecosystem-ber and ecosystem-68z: config resolves to shipped defaults, exit 0, nothing reports it. Fixed by moving root resolution inside the loader so no call site picks a root." \
  --acceptance "1. A session started in a subdirectory of a git repo resolves layer 4 from the repo root.
2. The fix is structural -- no call site supplies a root.
3. Covered by test/bats/config-loader-roots.bats driven from a real git worktree.
4. The non-git case still reads its own .claude/settings.json, since 19 of 36 settings fixtures never git init."
```

- [ ] **Step 2: Record the acceptance-5 answer on the parent bead**

```bash
bd update ecosystem-449.37 --append-notes "ACCEPTANCE 5 ANSWERED 2026-09-13 on fix/config-root-resolution.

The root is no longer a call-site decision. config_load_plugin takes the session
cwd and derives both roots itself in one git rev-parse, so the question 'which
root does this plugin get' has one answer for all sixteen.

The layers split, because the two files have different natures:
  layer 4  <worktree>/.claude/settings.json      committed  -> branch-scoped
  layer 5  <parent>/.claude/settings.local.json  gitignored -> machine-scoped

Resolving both against the worktree would silently drop layer 5 in every worktree
session, since git worktree add never copies a gitignored file -- the original
mistake at smaller scale. Resolving both against the parent would stop a branch
configuring itself, which is what the dogfooding rollout uses layer 4 to do.

SCOPE WAS WIDER THAN THE BEAD RECORDED. The bead lists ten plugins passing
REPO_ROOT. Two corrections:
  - inspector is NOT among them. inspector_project_repo_root resolves through
    --show-toplevel, so its layer 4 was already worktree-correct. That is the
    asymmetry that surfaced ecosystem-449.33.
  - a second, unrecorded defect sits beside it: sixteen call sites across five
    plugins passed the raw session cwd, so a session started in a subdirectory
    read no project config at all. Filed as a child of this bead.

Exact shape: 33 call sites, 17 changed. 14 category A across 13 hooks, 2
inspector, 1 written inline at librarian-session-end.sh:88, 16 already passing
CWD and fixed inside the loader without edits.

Spec: docs/superpowers/specs/2026-09-13-config-root-resolution-design.md" \
  --append-acceptance "Acceptance 5 answered: cwd, resolved by the loader. Layer 4 from the worktree, layer 5 from the parent. Recorded above."
```

If `--append-acceptance` is not a supported flag, drop it — `--append-notes`
carries the record and acceptance 5 asks only that the decision be recorded in
the issue.

- [ ] **Step 3: Final verification before the PR**

Run each leg separately, and never pipe a command into something that reads `$?`:

```bash
npm run test:bats;       echo "BATS=$?"
npm run test:schema;     echo "SCHEMA=$?"
npm run test:bus;        echo "BUS=$?"
npm run test:shellcheck; echo "SHELLCHECK=$?"
npm run lint:check;      echo "LINT=$?"
```

Expected: every leg exits 0. Record the actual numbers in the PR body — do not
claim green without them.

- [ ] **Step 4: Rebase onto current main**

```bash
git fetch origin
git rebase origin/main
```

- [ ] **Step 5: Open the PR**

Use the `/git-workflow:pr` skill. The PR body should lead with the two things a
reviewer will not expect: that the bead's scope was wrong in two directions
(inspector was never affected; a second defect was unrecorded), and that layers 4
and 5 deliberately resolve against different roots.

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| The rule (three roots) | 1 (loader), 3 (docs) |
| Config splits across the first two | 1, steps 4-5 |
| Loader change, one fork | 1, step 3 |
| Non-git fallback | 1, step 3; tested step 1 |
| Backward compatibility | 1, step 1 (final test), step 8 |
| Call sites, 17 of 33 | 2, steps 3-6 |
| Documentation touched | 3, all steps |
| Testing, 9 cases | 1, step 1 |
| Enforcement | 2, steps 1-2 |
| Beads | 4, steps 1-2 |
| Known limit (no walk outside git) | 1, step 3 comment |
| Acceptance 7 (keys do not move) | 2, step 6 |

**Placeholder scan:** none — every step carries the literal code or command.

**Type consistency:** `_config_resolve_roots` sets `_CONFIG_WORKTREE_ROOT` and
`_CONFIG_PARENT_ROOT`; both names are used identically in Task 1 steps 3 and 4.
`config_load_plugin`'s second parameter is `cwd` in the loader (Task 1) and in
all 16 wrappers (Task 3).
