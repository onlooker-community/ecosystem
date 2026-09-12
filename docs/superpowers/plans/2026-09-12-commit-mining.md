# Commit Mining Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** archivist mines commit messages into artifacts on `SessionEnd`, so the lesson pipeline has an input that does not depend on compaction.

**Architecture:** One new lib of pure text functions — splitting a squashed body into authored messages, normalizing one, deriving its id — and one new hook that walks `git log` from a watermark and writes artifacts through the storage lib archivist already has.

**Tech Stack:** Bash, bats, jq. No new dependency.

**Spec:** `onlooker` repo, `docs/superpowers/specs/2026-09-12-commit-mining-design.md`.

## Global Constraints

- **No model call.** The judgment already exists upstream in the message and downstream in librarian's gates. A second filter here would duplicate one that works.
- **Ids are content-addressed**, derived from the normalized message text — never from the commit SHA, which squash merging destroys.
- **The watermark advances only after artifacts are durably written.** `ecosystem-449.55` is what the inverse costs.
- **Default branch only.** One source, one carrying commit, one id.
- **Use `archivist_project_key`**, the function archivist's other two hooks already call. Do not vendor the substrate copy — verified identical on 2026-09-12, and the miner writes to archivist's own store, so consistency *within* that store is what matters.
- Tests are bats under `test/bats/`. Run `npm test`; shellcheck must pass at `-S error`.

## Two corrections to the spec

**It is not blocked.** The spec says this waits on `feat/plugin-currency-surfacer` for a substrate project-key helper. Archivist has shipped `archivist_project_key` all along, its sibling hooks call it, and it produces a byte-identical key *(measured — both return `ee2cfbe428c7` for this repository)*. Vendoring the substrate copy would also mean adding it to `ON_DEMAND_LIBS` and hand-copying it first, which `shared-lib-vendoring.bats` polices. None of that is needed.

**The watermark does not go in `manifest.json`.** `archivist_storage_write_manifest` rewrites that file wholesale from a fixed shape, so any field added beside its keys is clobbered on the next write. The watermark lives in its own `mined.json`, the same separation the CLI made for its cursor and for the same reason.

## File Structure

| File | Responsibility |
|---|---|
| `plugins/archivist/scripts/lib/archivist-mine.sh` (new) | Pure text: split a squashed body, normalize a message, derive its id. No I/O. |
| `plugins/archivist/scripts/hooks/archivist-mine.sh` (new) | The hook: read the watermark, walk `git log`, write artifacts, advance. |
| `plugins/archivist/hooks/hooks.json` (modify) | Bind the hook to `SessionEnd`. |
| `test/bats/archivist-mine.bats` (new) | The lib's tests. |

The lib is pure so that the two things most worth testing exhaustively — the split and the id — are testable without a repository, a store, or a hook payload.

---

### Task 1: Splitting, normalizing, and the id

**Files:**
- Create: `plugins/archivist/scripts/lib/archivist-mine.sh`
- Create: `test/bats/archivist-mine.bats`

**Interfaces:**
- Consumes: `_archivist_ulid_encode` from `archivist-ulid.sh`.
- Produces:
  - `archivist_mine_split <body>` — prints one normalized message per record, NUL-separated.
  - `archivist_mine_normalize <message>` — strips a leading `* `, trims trailing whitespace.
  - `archivist_mine_id <normalized_message> <commit_epoch_ms>` — prints a 26-char ULID.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	source "${PLUGIN_ROOT}/scripts/lib/archivist-ulid.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-mine.sh"
}

@test "a bulletless body is one message" {
	# A single-commit pull request squashes to its body verbatim, with no
	# bullet at all — measured on 17ae546.
	run archivist_mine_split "Fixed the thing.

Because the old path dropped events."
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | tr -cd '\0' | wc -c)" -eq 0 ]
}

@test "a squashed body splits on its bullets" {
	# GitHub concatenates every message behind "* " when a pull request has
	# more than one commit — measured on 4e198fa, eleven of them.
	local body='* first subject

first body because reasons

* second subject

second body because other reasons'
	run archivist_mine_split "$body"
	[ "$status" -eq 0 ]
	# Two records means one NUL separator.
	[ "$(printf '%s' "$output" | tr -cd '\0' | wc -c)" -eq 1 ]
}

@test "normalizing strips the bullet so both sources agree" {
	# The whole point of content addressing: a message read from the branch
	# commit that wrote it and from the squash that carried it must hash the
	# same, and the bullet is the only difference between them.
	local from_branch
	local from_squash
	from_branch=$(archivist_mine_normalize "subject line

body because reasons")
	from_squash=$(archivist_mine_normalize "* subject line

body because reasons")
	[ "$from_branch" = "$from_squash" ]
}

@test "normalizing trims trailing whitespace" {
	local a
	local b
	a=$(archivist_mine_normalize "subject")
	b=$(archivist_mine_normalize "subject

")
	[ "$a" = "$b" ]
}

@test "the id is a well-formed ULID" {
	run archivist_mine_id "subject because reasons" 1788618992794
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]
}

@test "the same message and time always produce the same id" {
	# Idempotence. A re-mine must overwrite its own artifact rather than add a
	# second, and every lesson citing that artifact must keep resolving.
	local a
	local b
	a=$(archivist_mine_id "subject because reasons" 1788618992794)
	b=$(archivist_mine_id "subject because reasons" 1788618992794)
	[ "$a" = "$b" ]
}

@test "different messages at the same instant produce different ids" {
	# Every message in one squashed pull request shares a carrying commit and
	# therefore a timestamp. Only the content half separates them.
	local a
	local b
	a=$(archivist_mine_id "first because reasons" 1788618992794)
	b=$(archivist_mine_id "second because reasons" 1788618992794)
	[ "$a" != "$b" ]
}

@test "ids sort by the carrying commit's time" {
	# ULIDs sort lexicographically by their timestamp prefix, so a pull
	# request's artifacts sort at the moment it landed rather than in whatever
	# order the miner visited them.
	local earlier
	local later
	earlier=$(archivist_mine_id "same text" 1788618992794)
	later=$(archivist_mine_id "same text" 1788618999999)
	[[ "$earlier" < "$later" ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm run test:bats -- test/bats/archivist-mine.bats`
Expected: FAIL — the lib does not exist.

- [ ] **Step 3: Implement the lib**

```bash
#!/usr/bin/env bash
# Turn commit messages into artifact fields.
#
# Pure text. No git, no store, no hook payload — the split and the id are the
# two things most worth testing exhaustively, and keeping them free of I/O
# means their tests state the rules rather than build fixtures.

# Strip a leading "* " bullet and trailing whitespace.
#
# A squashed pull request carries each authored message behind a bullet, and a
# single-commit one carries its body verbatim. Normalizing makes both spell the
# same message, which is what lets the id survive a squash.
archivist_mine_normalize() {
	local message="$1"
	message="${message#\* }"
	# Trailing blank lines differ between the two sources and mean nothing.
	printf '%s' "$(printf '%s' "$message" | sed -e 's/[[:space:]]*$//' -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
}

# Split a squashed body into its authored messages, NUL-separated.
#
# NUL rather than newline because every message contains newlines; a
# line-oriented separator cannot express this.
archivist_mine_split() {
	local body="$1"

	# No bullets means one authored message, carried verbatim.
	if ! printf '%s\n' "$body" | grep -q '^\* '; then
		archivist_mine_normalize "$body"
		return 0
	fi

	local current=""
	local first=1
	while IFS= read -r line; do
		if [[ "$line" == '* '* ]]; then
			if [[ $first -eq 0 ]]; then
				archivist_mine_normalize "$current"
				printf '\0'
			fi
			first=0
			current="$line"
		else
			current="${current}"$'\n'"${line}"
		fi
	done <<< "$body"
	[[ $first -eq 0 ]] && archivist_mine_normalize "$current"
}

# A ULID derived from the message, carried at the given instant.
#
# The randomness half is SHA256 over the normalized message, so the id survives
# a squash, a rebase and a cherry-pick — every one of which rewrites the SHA
# this could otherwise have used. The timestamp half is the carrying commit's
# date, so a pull request's artifacts sort together at the moment it landed.
#
# Usage: archivist_mine_id <normalized_message> <epoch_ms>
archivist_mine_id() {
	local message="$1"
	local epoch_ms="$2"

	local digest
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$message" | shasum -a 256 | cut -c1-20)
	else
		digest=$(printf '%s' "$message" | sha256sum | cut -c1-20)
	fi

	# Eighty bits as two forty-bit halves, matching how archivist_ulid builds
	# its own randomness so both pass through the same encoder.
	local hi=$((16#${digest:0:10}))
	local lo=$((16#${digest:10:10}))

	printf '%s%s%s' \
		"$(_archivist_ulid_encode "$epoch_ms" 10)" \
		"$(_archivist_ulid_encode "$hi" 8)" \
		"$(_archivist_ulid_encode "$lo" 8)"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm run test:bats -- test/bats/archivist-mine.bats`
Expected: PASS, all eight.

- [ ] **Step 5: shellcheck**

Run: `npm run test:shellcheck`
Expected: clean. The `sed` chain in `archivist_mine_normalize` is the likely complaint; simplify rather than suppress.

- [ ] **Step 6: Commit**

```bash
git add plugins/archivist/scripts/lib/archivist-mine.sh test/bats/archivist-mine.bats
git commit -m "feat(archivist): derive an artifact id from what was written :key:"
```

---

### Task 2: The hook

**Files:**
- Create: `plugins/archivist/scripts/hooks/archivist-mine.sh`
- Create: `test/bats/archivist-mine-hook.bats`

**Interfaces:**
- Consumes: Task 1's lib, `archivist_project_key`, `archivist_storage_write_artifact`, `archivist_project_dir`.
- Produces: a hook reading the `SessionEnd` payload on stdin, exiting 0 always.

- [ ] **Step 1: Write the failing tests**

Against a real temporary repository, because the risk here is `git log` parsing and the watermark, and a stub exercises neither:

```bash
#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_DIR="${BATS_TEST_TMPDIR}/onlooker"

	source "${PLUGIN_ROOT}/scripts/lib/archivist-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"
}

# A real repository, because the risk in this hook is git log parsing and the
# watermark, and a stub exercises neither.
make_repo() {
	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name T
	printf 'x\n' > "$REPO/a.txt"
	git -C "$REPO" add .
	git -C "$REPO" commit -q -m "$1"
	KEY=$(archivist_project_key "$REPO")
}

run_hook() {
	printf '{"cwd":"%s","session_id":"s1"}' "$REPO" |
		"${PLUGIN_ROOT}/scripts/hooks/archivist-mine.sh"
}

artifact_count() {
	find "$(archivist_project_dir "$KEY")/decisions" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

@test "mines a commit into an artifact" {
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them on every restart."

	run run_hook
	[ "$status" -eq 0 ]
	[ "$(artifact_count)" -eq 1 ]
	run grep -l "stop dropping events" "$(archivist_project_dir "$KEY")/decisions"/*.json
	[ "$status" -eq 0 ]
}

@test "is idempotent - mining twice leaves one artifact" {
	# The content-addressed id doing its job: a second run overwrites rather
	# than accumulates, so every lesson citing that artifact keeps resolving.
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them."

	run_hook
	rm -f "$(archivist_project_dir "$KEY")/mined.json"
	run_hook

	[ "$(artifact_count)" -eq 1 ]
}

@test "advances the watermark only after writing" {
	# ecosystem-449.55 one layer up: a watermark ahead of its data turns a
	# recoverable interruption into permanent silent loss.
	make_repo "fix(thing): a claim because reasons"
	archivist_storage_init "$KEY"
	chmod 555 "$(archivist_project_dir "$KEY")"

	run run_hook
	chmod 755 "$(archivist_project_dir "$KEY")"

	[ "$status" -eq 0 ]
	[ ! -f "$(archivist_project_dir "$KEY")/mined.json" ]
}

@test "mines nothing when the watermark is current" {
	# Every session after the first takes this path, so it must be cheap and
	# must not rewrite what is already there.
	make_repo "fix(thing): a claim because reasons"
	run_hook
	local before
	before=$(artifact_count)

	run run_hook

	[ "$status" -eq 0 ]
	[ "$(artifact_count)" -eq "$before" ]
}

@test "splits a squashed body into one artifact per message" {
	# What squash merging actually produces: every authored message behind a
	# bullet in one carrying commit.
	make_repo "feat(x): the pull request title (#12)

* first subject

first body because reasons

* second subject

second body because other reasons"

	run run_hook

	[ "$status" -eq 0 ]
	[ "$(artifact_count)" -eq 2 ]
}

@test "exits 0 outside a git repository" {
	# No project key, nothing to do. The hook must never block session end.
	REPO="${BATS_TEST_TMPDIR}/loose"
	mkdir -p "$REPO"

	run run_hook

	[ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `npm run test:bats -- test/bats/archivist-mine-hook.bats`

- [ ] **Step 3: Implement the hook**

Follow `archivist-extract.sh`'s preamble exactly — nesting guard, substrate resolution, `hook_health_register`, and the same "always exit 0" contract. Then:

1. Read `cwd` from the payload; `archivist_project_key "$CWD"`; empty key means no git context, so exit 0.
2. Read the watermark from `$(archivist_project_dir "$key")/mined.json`, defaulting to empty.
3. `git log --first-parent --format=%H%x1f%ct%x1f%s%x1f%b%x1e <watermark>..HEAD` on the default branch only.
4. For each commit: split the body, and for each message build the artifact JSON — `summary` the first line, `detail` the rest, `files` from `git show --name-only`, `session_id` from the `Claude-Session:` trailer, `created_at` from the commit date, `kind` `decisions`, `trigger` `commit`.
5. Write each through `archivist_storage_write_artifact`.
6. Only then write the new watermark.

- [ ] **Step 4: Run the whole suite**

Run: `npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/archivist/scripts/hooks/archivist-mine.sh test/bats/archivist-mine-hook.bats
git commit -m "feat(archivist): mine commits the pipeline never had an input for :pick:"
```

---

### Task 3: Bind it

**Files:**
- Modify: `plugins/archivist/hooks/hooks.json`
- Modify: `plugins/archivist/README.md` if it documents hooks

- [ ] **Step 1: Add the binding**

```json
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PLUGIN_ROOT\"/scripts/hooks/archivist-mine.sh"
          }
        ]
      }
    ]
```

- [ ] **Step 2: Run the whole suite**

Run: `npm test`
Expected: PASS. Any bats file asserting archivist's hook set will need the new event; that is the behavior change, not a broken test.

- [ ] **Step 3: Verify against this repository**

Run the hook by hand with a payload naming this repo, and confirm artifacts appear under `~/.onlooker/archivist/ee2cfbe428c7/decisions/` — a real store, real commits, real ids. Then run it again and confirm the count does not change.

- [ ] **Step 4: Commit**

```bash
git add plugins/archivist/hooks/hooks.json
git commit -m "feat(archivist): extract on session end, not only on compaction :alarm_clock:"
```

---

## Final verification

- [ ] `npm test` and `npm run test:shellcheck`.
- [ ] Mine this repository for real, then re-run and confirm idempotence by file count.
- [ ] Confirm a mined artifact passes librarian's durability filter — it should, on `because`, but measuring beats assuming.
- [ ] Bump the archivist plugin version so the release cuts; a plugin change that never ships is the failure `#141` already demonstrated.
