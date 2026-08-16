# Cartographer `undocumented_entity` Phase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give cartographer a disk → doc analysis phase so an entity that exists on disk and is mentioned in no instruction file becomes visible.

**Architecture:** A new pure-bash analyzer library, `cartographer-omission.sh`, enumerates configured globs under the repo root and word-boundary-greps each entity's name across the instruction corpus. It is invoked as a third analysis inside `run_synthesize`, alongside `stale_ref` and `scope_collision`, and returns findings in the same shape so the existing hash-enrichment and emit loops handle it unchanged. No model call.

**Tech Stack:** bash (targeting 3.2 — macOS system bash), `jq`, `grep -E`, bats for tests.

**Spec:** `docs/superpowers/specs/2026-08-16-cartographer-undocumented-entity-design.md`
**Tracked by:** `ecosystem-3eu`

## Global Constraints

- All hook and library code is bash. No Python, no Node entry points. Shelling out to `node` for event emission is allowed.
- Event types follow `<plugin>.<noun>.<verb>`. **This plan emits no new event type** — findings ride the existing `cartographer.issue.found`.
- Runtime artifacts go under `${ONLOOKER_DIR:-$HOME/.onlooker}/`. Never hardcode `~/.onlooker`.
- American English in all comments, identifiers, and docs.
- Tests target bash 3.2 semantics: any **non-final** `[[ ]]` assertion in a bats body must be gated with `|| return 1`, or it does not fail the test on macOS.
- Config defaults live in `plugins/cartographer/config.json` under the `cartographer` namespace key.
- `npm run test:ci` must pass — it adds shellcheck and the manifest/reference linters on top of the tests.

## Out of scope, deliberately

Two pre-existing bugs sit adjacent to this work. **Do not fix either one in this branch.**

- **`ecosystem-q4d` (P1)** — both cartographer event payloads are off-contract with the published schema, so `cartographer.issue.found` never validates. Findings from this phase land on disk correctly and their bus event is broken in exactly the same way as the existing four phases. That is expected. Do not touch the emit path.
- **`ecosystem-88v` (P2)** — `run-audit.sh` never calls `cartographer_config_load` at the top level, and does not export `PLUGIN_ROOT`, so the `cartographer_config_load` calls inside the three analysis sub-shells fail too. **Task 3 works around this** by setting `PLUGIN_ROOT` inside its own sub-shell. That inline assignment is intentional, is commented as such, and should be removed once `88v` lands.

## File Structure

| File | Responsibility |
|------|----------------|
| `plugins/cartographer/scripts/lib/cartographer-omission.sh` | **Create.** The analyzer. Enumeration, mention test, finding construction, cap. Nothing else. |
| `plugins/cartographer/scripts/lib/cartographer-config.sh` | **Modify.** Four accessors for the new config block. |
| `plugins/cartographer/config.json` | **Modify.** Shipped defaults. |
| `plugins/cartographer/scripts/run-audit.sh` | **Modify.** Wire the analyzer into `run_synthesize`; guard on targeted audits. |
| `test/bats/cartographer-omission.bats` | **Create.** Analyzer unit tests. |
| `test/bats/cartographer-config.bats` | **Modify.** Config accessor tests. |
| `plugins/cartographer/README.md` | **Modify.** Phase list and config block. |
| `plugins/cartographer/skills/cartographer/SKILL.md` | **Modify.** `--phase` values and frontmatter description. |

The analyzer lives in its own file rather than being appended to `cartographer-analyze.sh` because that file is exclusively LLM-calling analyzers sharing one prompt-and-parse idiom. This one calls no model and shares none of it.

---

### Task 1: Config surface

**Files:**

- Modify: `plugins/cartographer/config.json`
- Modify: `plugins/cartographer/scripts/lib/cartographer-config.sh:66-80`
- Test: `test/bats/cartographer-config.bats`

**Interfaces:**

- Consumes: `cartographer_config_get`, `cartographer_config_get_json` (existing, same file).
- Produces: `cartographer_config_undocumented_enabled` → `"true"`/`"false"`; `cartographer_config_undocumented_globs` → JSON array; `cartographer_config_undocumented_exclude` → JSON array; `cartographer_config_undocumented_max_findings` → integer. Task 3 calls all four.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/cartographer-config.bats`:

```bash
@test "undocumented_entity: defaults ship enabled with plugin and skill globs" {
  cartographer_config_load ""
  local enabled globs max
  enabled=$(cartographer_config_undocumented_enabled)
  globs=$(cartographer_config_undocumented_globs)
  max=$(cartographer_config_undocumented_max_findings)
  [ "$enabled" = "true" ]
  [ "$max" = "20" ]
  [ "$(printf '%s' "$globs" | jq -r 'length')" = "2" ]
  [ "$(printf '%s' "$globs" | jq -r '.[0]')" = "plugins/*/" ]
}

@test "undocumented_entity: user settings can disable the phase" {
  mkdir -p "${HOME}/.claude"
  printf '%s\n' '{"cartographer":{"undocumented_entity":{"enabled":false}}}' \
    > "${HOME}/.claude/settings.json"
  cartographer_config_load ""
  local enabled max
  enabled=$(cartographer_config_undocumented_enabled)
  max=$(cartographer_config_undocumented_max_findings)
  [ "$enabled" = "false" ]
  [ "$max" = "20" ]
}

@test "undocumented_entity: repo settings replace the glob list wholesale" {
  local repo="${BATS_TEST_TMPDIR}/repo-glob"
  mkdir -p "${repo}/.claude"
  printf '%s\n' '{"cartographer":{"undocumented_entity":{"globs":["agents/*/"]}}}' \
    > "${repo}/.claude/settings.json"
  cartographer_config_load "$repo"
  local globs
  globs=$(cartographer_config_undocumented_globs)
  [ "$(printf '%s' "$globs" | jq -r 'length')" = "1" ]
  [ "$(printf '%s' "$globs" | jq -r '.[0]')" = "agents/*/" ]
}

@test "undocumented_entity: exclude defaults to empty" {
  cartographer_config_load ""
  local excl
  excl=$(cartographer_config_undocumented_exclude)
  [ "$(printf '%s' "$excl" | jq -r 'length')" = "0" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/bats/cartographer-config.bats`
Expected: FAIL — `cartographer_config_undocumented_enabled: command not found`.

- [ ] **Step 3: Add the config defaults**

In `plugins/cartographer/config.json`, add a sibling to `exclude_paths` inside the `cartographer` object (mind the comma on the `exclude_paths` line):

```json
    "exclude_paths": ["node_modules", ".git", "vendor", ".venv", "dist", ".next", ".nuxt", "build", "__pycache__"],
    "undocumented_entity": {
      "enabled": true,
      "globs": ["plugins/*/", "skills/*/"],
      "exclude": [],
      "max_findings": 20
    }
```

- [ ] **Step 4: Add the accessors**

Append to `plugins/cartographer/scripts/lib/cartographer-config.sh`:

```bash
# ── undocumented_entity phase ──────────────────────────────────────────────────
# Disk → doc detection. Unlike the other phases these are read inside the
# analysis sub-shell rather than by the orchestrator; see run-audit.sh and
# ecosystem-88v for why.

cartographer_config_undocumented_enabled() {
	local v
	v=$(cartographer_config_get '.cartographer.undocumented_entity.enabled')
	printf '%s' "${v:-true}"
}

cartographer_config_undocumented_globs() {
	cartographer_config_get_json \
		'.cartographer.undocumented_entity.globs // ["plugins/*/","skills/*/"]'
}

cartographer_config_undocumented_exclude() {
	cartographer_config_get_json '.cartographer.undocumented_entity.exclude // []'
}

cartographer_config_undocumented_max_findings() {
	local v
	v=$(cartographer_config_get '.cartographer.undocumented_entity.max_findings')
	printf '%s' "${v:-20}"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/bats/cartographer-config.bats`
Expected: PASS, all tests including the four pre-existing ones.

- [ ] **Step 6: Break one assertion on purpose**

Temporarily change `[ "$enabled" = "false" ]` to `[ "$enabled" = "true" ]` in the disable test, re-run, and confirm it **fails**. Revert. A test that passes either way reports coverage that does not exist.

- [ ] **Step 7: Commit**

```bash
git add plugins/cartographer/config.json \
        plugins/cartographer/scripts/lib/cartographer-config.sh \
        test/bats/cartographer-config.bats
```

Then run `/commit` — do not hand-write `git commit -m`. Suggested subject:
`feat(cartographer): add config for the disk-to-doc phase :gear:`

---

### Task 2: Detection library

**Files:**

- Create: `plugins/cartographer/scripts/lib/cartographer-omission.sh`
- Test: `test/bats/cartographer-omission.bats` (create)

**Interfaces:**

- Consumes: nothing from Task 1. This library is standalone and takes every input as a parameter, matching how the analyzers in `cartographer-analyze.sh` are written.
- Produces: `cartographer_analyze_undocumented_entity <files_json> <repo_root> <globs_json> <exclude_json> <max_findings>` → prints a JSON array on stdout. Task 3 calls it. Also `_cartographer_name_mentioned <name> <files_json>` → exit 0 if mentioned; private, but bats tests it directly.

- [ ] **Step 1: Write the failing tests**

Create `test/bats/cartographer-omission.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/cartographer-omission.sh"

  FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${FIXTURE_REPO}/plugins/alpha" \
           "${FIXTURE_REPO}/plugins/beta" \
           "${FIXTURE_REPO}/skills/solo"
  DOC="${FIXTURE_REPO}/CLAUDE.md"
  printf '# Doc\nThe alpha plugin does things.\n' > "$DOC"
  CORPUS=$(jq -n --arg f "$DOC" '[$f]')
}

@test "flags an entity whose name appears nowhere in the corpus" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [[ "$(printf '%s' "$out" | jq -r 'length')" == "1" ]] || return 1
  [[ "$(printf '%s' "$out" | jq -r '.[0].excerpt_a')" == "beta" ]] || return 1
  [ "$(printf '%s' "$out" | jq -r '.[0].type')" = "undocumented_entity" ]
}

@test "does not flag an entity the corpus mentions" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [ "$(printf '%s' "$out" | jq -r '[.[] | select(.excerpt_a == "alpha")] | length')" = "0" ]
}

@test "finding carries the entity as file_a and a null file_b" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [[ "$(printf '%s' "$out" | jq -r '.[0].file_a')" == "${FIXTURE_REPO}/plugins/beta" ]] || return 1
  [[ "$(printf '%s' "$out" | jq -r '.[0].file_b')" == "null" ]] || return 1
  [ "$(printf '%s' "$out" | jq -r '.[0].severity')" = "warning" ]
}

@test "word boundary: a longer word containing the name does not count as a mention" {
  printf '# Doc\nWe do a lot of counseling here.\n' > "$DOC"
  mkdir -p "${FIXTURE_REPO}/plugins/counsel"
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [ "$(printf '%s' "$out" | jq -r '[.[] | select(.excerpt_a == "counsel")] | length')" = "1" ]
}

@test "word boundary: a hyphenated name is not matched inside a longer hyphenated token" {
  printf '# Doc\nSee my-list-prompt-rules-thing for details.\n' > "$DOC"
  mkdir -p "${FIXTURE_REPO}/skills/list-prompt-rules"
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["skills/*/"]' '[]' 20)
  [ "$(printf '%s' "$out" | jq -r '[.[] | select(.excerpt_a == "list-prompt-rules")] | length')" = "1" ]
}

@test "word boundary: a name bounded by slashes counts as a mention" {
  printf '# Doc\nSee plugins/beta/ for details.\n' > "$DOC"
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [ "$(printf '%s' "$out" | jq -r '[.[] | select(.excerpt_a == "beta")] | length')" = "0" ]
}

@test "exclude filters a matched path by substring" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/","skills/*/"]' '["skills/"]' 20)
  [[ "$(printf '%s' "$out" | jq -r 'length')" == "1" ]] || return 1
  [ "$(printf '%s' "$out" | jq -r '.[0].excerpt_a')" = "beta" ]
}

@test "max_findings caps the result and reports the drop count on stderr" {
  local out err
  err="${BATS_TEST_TMPDIR}/err.txt"
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/","skills/*/"]' '[]' 1 2>"$err")
  [[ "$(printf '%s' "$out" | jq -r 'length')" == "1" ]] || return 1
  grep -q "1 candidate" "$err"
}

@test "a glob matching nothing yields an empty array" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["nonexistent/*/"]' '[]' 20)
  [ "$out" = "[]" ]
}

@test "an empty corpus yields an empty array rather than flagging everything" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    '[]' "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [ "$out" = "[]" ]
}

@test "the same entity produces an identical finding hash across two runs" {
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/cartographer-analyze.sh"
  local a b h1 h2
  a=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  b=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  h1=$(cartographer_finding_hash "undocumented_entity" \
    "$(printf '%s' "$a" | jq -r '.[0].file_a')" \
    "$(printf '%s' "$a" | jq -r '.[0].excerpt_a')" "" "")
  h2=$(cartographer_finding_hash "undocumented_entity" \
    "$(printf '%s' "$b" | jq -r '.[0].file_a')" \
    "$(printf '%s' "$b" | jq -r '.[0].excerpt_a')" "" "")
  [[ -n "$h1" ]] || return 1
  [ "$h1" = "$h2" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/bats/cartographer-omission.bats`
Expected: FAIL — the source in `setup()` errors, no such file.

- [ ] **Step 3: Write the implementation**

Create `plugins/cartographer/scripts/lib/cartographer-omission.sh`:

```bash
#!/usr/bin/env bash
# cartographer-omission.sh — disk → doc detection.
#
# Every other analysis phase starts from the text of the instruction files and
# tests what it finds against the filesystem. This one runs the other way: it
# enumerates entities on disk and checks each is mentioned somewhere in the
# corpus. An entity nothing names produces no token for stale_ref to extract
# and no rule for contradiction to compare, which is why omissions were
# previously invisible to every phase.
#
# Detection is a grep — no model call. A model would only help judge whether an
# omission MATTERS, which is a sharper question than the drift that motivated
# this. See docs/superpowers/specs/2026-08-16-cartographer-undocumented-entity-design.md
#
# Usage:
#   cartographer_analyze_undocumented_entity <files_json> <repo_root> \
#       <globs_json> <exclude_json> <max_findings>
#
# Prints a JSON array of findings on stdout in the same shape the analyzers in
# cartographer-analyze.sh return, so run_synthesize merges it without special
# handling. Diagnostics go to stderr, which run-audit.sh appends to audit.log.

# Word-boundary mention test.
#
# Boundaries are hand-rolled rather than \b because entity names contain
# hyphens, and \b treats '-' as a non-word character: \blist-prompt-rules\b
# would also match inside "my-list-prompt-rules-thing". Bounding on
# [^A-Za-z0-9_-] instead means a hyphenated name matches only when genuinely
# standalone, while a name inside a path ("plugins/beta/") still counts.
_cartographer_name_mentioned() {
	local name="$1"
	local files_json="$2"

	local escaped
	escaped=$(printf '%s' "$name" | sed 's/[][\.*^$(){}?+|\\]/\\&/g')

	local fpath
	while IFS= read -r fpath; do
		[[ -z "$fpath" || ! -f "$fpath" ]] && continue
		if grep -qE "(^|[^A-Za-z0-9_-])${escaped}([^A-Za-z0-9_-]|\$)" "$fpath" 2>/dev/null; then
			return 0
		fi
	done < <(printf '%s' "$files_json" | jq -r '.[]' 2>/dev/null)
	return 1
}

cartographer_analyze_undocumented_entity() {
	local files_json="${1:-[]}"
	local repo_root="${2:?repo_root required}"
	local globs_json="${3:-[]}"
	local exclude_json="${4:-[]}"
	local max_findings="${5:-20}"

	# An empty corpus cannot document anything, so every entity would look
	# undocumented. Refuse rather than emit a burst of false findings that the
	# emit phase would dedup-sentinel and never re-evaluate.
	local corpus_count
	corpus_count=$(printf '%s' "$files_json" | jq 'length' 2>/dev/null || printf '0')
	[[ "${corpus_count:-0}" -eq 0 ]] && { printf '[]'; return 0; }

	local findings="[]"
	local emitted=0 dropped=0
	local root="${repo_root%/}"

	# nullglob so an unmatched pattern expands to nothing rather than to itself.
	# Restore the prior setting — this library is sourced, not run.
	local had_nullglob=0
	shopt -q nullglob && had_nullglob=1
	shopt -s nullglob

	local glob match
	while IFS= read -r glob; do
		[[ -z "$glob" ]] && continue
		# shellcheck disable=SC2086 # unquoted on purpose: this is the glob expansion
		for match in ${root}/$glob; do
			[[ -e "$match" ]] || continue

			local trimmed="${match%/}"
			local name relpath
			name=$(basename "$trimmed")
			relpath="${trimmed#"${root}"/}"

			local excluded=0 excl
			while IFS= read -r excl; do
				[[ -z "$excl" ]] && continue
				[[ "$relpath" == *"$excl"* ]] && { excluded=1; break; }
			done < <(printf '%s' "$exclude_json" | jq -r '.[]' 2>/dev/null)
			[[ "$excluded" -eq 1 ]] && continue

			_cartographer_name_mentioned "$name" "$files_json" && continue

			if [[ "$emitted" -ge "$max_findings" ]]; then
				dropped=$(( dropped + 1 ))
				continue
			fi

			local finding
			finding=$(jq -n \
				--arg fa "$trimmed" \
				--arg n "$name" \
				--arg rp "$relpath" \
				'{
					type: "undocumented_entity",
					severity: "warning",
					file_a: $fa,
					excerpt_a: $n,
					file_b: null,
					excerpt_b: null,
					description: ($n + " exists at " + $rp
						+ " but is not mentioned in any instruction file."),
					suggested_fix: ("Document " + $n
						+ " in CLAUDE.md, or exclude its path from cartographer.undocumented_entity.")
				}')
			findings=$(printf '%s' "$findings" | jq --argjson f "$finding" '. + [$f]')
			emitted=$(( emitted + 1 ))
		done
	done < <(printf '%s' "$globs_json" | jq -r '.[]' 2>/dev/null)

	[[ "$had_nullglob" -eq 0 ]] && shopt -u nullglob

	# Say what was dropped. A silent truncation reads as "this is everything".
	if [[ "$dropped" -gt 0 ]]; then
		printf 'undocumented_entity: capped at %s findings, %s candidate(s) dropped\n' \
			"$max_findings" "$dropped" >&2
	fi

	printf '%s' "$findings"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/bats/cartographer-omission.bats`
Expected: PASS, 11 tests.

- [ ] **Step 5: Run shellcheck**

Run: `npm run test:shellcheck`
Expected: clean. The only suppression is the deliberate `SC2086` on the glob-expansion line; if shellcheck flags anything else, fix the code rather than adding a suppression.

- [ ] **Step 6: Break one assertion on purpose**

In the hyphen boundary test, temporarily change the expected `1` to `0`, re-run, confirm it **fails**, revert. That test is the one most likely to silently pass for the wrong reason.

- [ ] **Step 7: Commit**

```bash
git add plugins/cartographer/scripts/lib/cartographer-omission.sh \
        test/bats/cartographer-omission.bats
```

Then run `/commit`. Suggested subject:
`feat(cartographer): detect entities no instruction file mentions :mag:`

---

### Task 3: Pipeline integration and documentation

**Files:**

- Modify: `plugins/cartographer/scripts/run-audit.sh:142-197` (`run_synthesize`) and the header comment at lines 7-12
- Modify: `plugins/cartographer/README.md`
- Modify: `plugins/cartographer/skills/cartographer/SKILL.md:3` and `:112`
- Test: `test/bats/cartographer-omission.bats` (append integration tests)

**Interfaces:**

- Consumes: `cartographer_analyze_undocumented_entity` (Task 2); `cartographer_config_undocumented_enabled` / `_globs` / `_exclude` / `_max_findings` (Task 1).
- Produces: nothing new for later tasks. This is the last task.

- [ ] **Step 1: Write the failing integration tests**

Append to `test/bats/cartographer-omission.bats`:

```bash
# Stubs `claude` so the three LLM phases make no real call, then runs a full
# audit. Any extra env the caller needs is exported before calling this.
_run_audit() {
  local stub="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "[]"\n' > "${stub}/claude"
  chmod +x "${stub}/claude"

  PATH="${stub}:${PATH}" \
  CARTOGRAPHER_DIR="${BATS_TEST_TMPDIR}/state" \
  CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO" \
  CARTOGRAPHER_TRIGGER="manual" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "${PLUGIN_ROOT}/scripts/run-audit.sh"
}

# run_emit writes findings with a bare `jq`, which pretty-prints — the file
# contains `"type": "undocumented_entity"` with a space. Parse rather than grep.
_findings_of_type() {
  local dir="${BATS_TEST_TMPDIR}/state/findings"
  local count=0 f
  [[ -d "$dir" ]] || { printf '0'; return 0; }
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    if [[ "$(jq -r '.type // ""' "$f" 2>/dev/null)" == "undocumented_entity" ]]; then
      count=$(( count + 1 ))
    fi
  done
  printf '%s' "$count"
}

@test "integration: a full audit records the undocumented entity on disk" {
  _run_audit
  [ "$(_findings_of_type)" = "1" ]
}

@test "integration: a targeted post-write audit records no undocumented entity" {
  export CARTOGRAPHER_TARGET_FILE="$DOC"
  _run_audit
  [ "$(_findings_of_type)" = "0" ]
}

@test "integration: enabled=false suppresses the phase" {
  mkdir -p "${FIXTURE_REPO}/.claude"
  printf '%s\n' '{"cartographer":{"undocumented_entity":{"enabled":false}}}' \
    > "${FIXTURE_REPO}/.claude/settings.json"
  _run_audit
  [ "$(_findings_of_type)" = "0" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/bats/cartographer-omission.bats`
Expected: the first integration test FAILS with `0 != 1`; the other two pass vacuously (nothing runs the phase yet). Only the first proves anything at this point.

- [ ] **Step 3: Source the new library in run-audit.sh**

After line 32 (`source "$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh"`), add:

```bash
source "$PLUGIN_ROOT/scripts/lib/cartographer-omission.sh"
```

- [ ] **Step 4: Wire the phase into run_synthesize**

In `run_synthesize`, immediately after the `scope_findings=$(...)` assignment and before the `# Merge all raw findings` comment, insert:

```bash
	# Disk → doc. Skipped on targeted post-write audits: DISCOVERED_FILES is a
	# single file there, so grepping it for every entity name would report
	# nearly the whole enumeration as undocumented, and the emit phase would
	# dedup-sentinel those false findings permanently. scope_collision already
	# no-ops on targeted runs for the same reason.
	#
	# Config is read inside the sub-shell rather than passed in, because the
	# orchestrator's own config is never loaded (ecosystem-88v). PLUGIN_ROOT is
	# assigned here because run-audit.sh does not export it, which is why the
	# sibling phases' cartographer_config_load calls fail. Remove both
	# workarounds when 88v lands.
	local omission_findings="[]"
	if [[ -z "$TARGET_FILE" ]]; then
		omission_findings=$($_TIMEOUT_CMD "$_phase_timeout" bash -c \
			"PLUGIN_ROOT='$PLUGIN_ROOT'
			 source '$PLUGIN_ROOT/scripts/lib/cartographer-config.sh'
			 source '$PLUGIN_ROOT/scripts/lib/cartographer-omission.sh'
			 cartographer_config_load '$REPO_ROOT'
			 [[ \"\$(cartographer_config_undocumented_enabled)\" == 'true' ]] \
			   || { printf '[]'; exit 0; }
			 cartographer_analyze_undocumented_entity '$DISCOVERED_FILES' '$REPO_ROOT' \
			   \"\$(cartographer_config_undocumented_globs)\" \
			   \"\$(cartographer_config_undocumented_exclude)\" \
			   \"\$(cartographer_config_undocumented_max_findings)\"" \
			2>>"$CARTOGRAPHER_DIR/audit.log") || omission_findings="[]"
	fi
```

- [ ] **Step 5: Merge the findings**

Replace the `raw_all=$(jq -n ...)` block with:

```bash
	local raw_all
	raw_all=$(jq -n \
		--argjson relate "${RELATE_FINDINGS:-[]}" \
		--argjson stale "${stale_findings:-[]}" \
		--argjson scope "${scope_findings:-[]}" \
		--argjson omission "${omission_findings:-[]}" \
		'$relate + $stale + $scope + $omission')
```

- [ ] **Step 6: Update the file header comment**

In `run-audit.sh`, change line 11 from:

```text
#   4. synthesize — stale_ref + scope_collision + finding hash computation
```

to:

```text
#   4. synthesize — stale_ref + scope_collision + undocumented_entity + hash
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bats test/bats/cartographer-omission.bats`
Expected: PASS, 14 tests.

- [ ] **Step 8: Verify against this repository**

Run:

```bash
CARTOGRAPHER_DIR="$(mktemp -d)" \
CARTOGRAPHER_REPO_ROOT="$PWD" \
CARTOGRAPHER_TRIGGER=manual \
CLAUDE_PLUGIN_ROOT="$PWD/plugins/cartographer" \
  bash plugins/cartographer/scripts/run-audit.sh
```

Expected: exactly one `undocumented_entity` finding, for `skills/list-prompt-rules`. All 16 plugins are documented and `docs/adr/` is never enumerated. If a second finding appears, the enumeration is too broad — do not proceed until it is one.

- [ ] **Step 9: Update the README**

In `plugins/cartographer/README.md`, add a row to the "What it detects" table
after the `scope_collision` row at line 16:

```markdown
| `undocumented_entity` | Something that exists on disk — a plugin, a skill — that no instruction file mentions |
```

Then add to the "Configuration" section, after the `exclude_paths` note at
line 75:

````markdown
### Detecting omissions

Every other check reads the instruction files and tests what it finds against
the filesystem. `undocumented_entity` runs the other way: it enumerates
entities on disk and flags any whose name appears in no instruction file. That
is the one kind of drift the other checks structurally cannot see — something
absent produces no reference to follow.

```json
{
  "cartographer": {
    "undocumented_entity": {
      "enabled": true,
      "globs": ["plugins/*/", "skills/*/"],
      "exclude": [],
      "max_findings": 20
    }
  }
}
```

`globs` are relative to the repository root, and a glob matching nothing is
simply inert — the defaults do nothing in a repository without those
directories. The list is deliberately opt-in: most of a repository has no
business being named in `CLAUDE.md`, so only classes where you expect the
documentation to be *complete* belong here.

**Note:** as with `exclude_paths`, overriding `globs` or `exclude` replaces the
entire list rather than extending it. Repeat the defaults alongside your
additions if you mean to extend.
````

- [ ] **Step 10: Update the skill**

In `plugins/cartographer/skills/cartographer/SKILL.md`:

- Line 112: change the `--phase` list to `contradiction`, `stale_ref`, `dead_rule`, `scope_collision`, or `undocumented_entity`.
- Line 3 frontmatter `description`: add omissions to what it audits for, e.g. `...dead rules, scope collisions, and entities no instruction file mentions.`

The finding renderers at lines 65 and 135 read `.type` and `.description` generically — **do not change them.**

- [ ] **Step 11: Confirm CLAUDE.md needs no change**

The cartographer row in the plugin map describes the hook surface, not the phases. Read it and confirm. If it does mention phases, update it.

- [ ] **Step 12: Run the full CI suite**

Run: `npm run test:ci`
Expected: PASS — shellcheck, bats, schema, biome, markdownlint, manifest and reference linters.

- [ ] **Step 13: Commit**

```bash
git add plugins/cartographer/scripts/run-audit.sh \
        plugins/cartographer/README.md \
        plugins/cartographer/skills/cartographer/SKILL.md \
        test/bats/cartographer-omission.bats
```

Then run `/commit`. Suggested subject:
`feat(cartographer): run the omission phase in every full audit :eyes:`

- [ ] **Step 14: Close the bead and open the PR**

```bash
bd close ecosystem-3eu --reason="undocumented_entity phase ships; detection, config, wiring, tests, docs"
```

Then open a PR with `/git-workflow:pr`. Never push to `main` — release-please needs every change to travel through a PR. Note in the PR body that `ecosystem-q4d` and `ecosystem-88v` were found during this work and deliberately left out.

---

## Notes for the implementer

**Why the sub-shell looks awkward.** The three sibling phases pass config in as positional parameters. This one reads config inside its own sub-shell instead. That is not a style preference — the orchestrator never loads config (`ecosystem-88v`), so a value read at the top of `run-audit.sh` would always be the shipped default and the `enabled: false` off-switch would be inert. The `PLUGIN_ROOT='...'` assignment is there for the same reason. Both go away when `88v` lands; the comment in the code says so.

**Do not "fix" the emit path.** You will notice while testing that no `cartographer.issue.found` event reaches `$ONLOOKER_EVENTS_LOG`. That is `ecosystem-q4d`, it predates this work, and it affects all five phases equally. Findings on disk are the correct assertion surface for these tests.

**bash 3.2.** `mapfile`/`readarray` are unavailable. Do not reach for them. `shopt -s nullglob` and `while read` are the portable idioms, and both are used above.
