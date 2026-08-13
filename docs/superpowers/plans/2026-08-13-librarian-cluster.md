# Librarian Follow-up Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close four small librarian defects found during the lesson-promotion epic — `ecosystem-a3b`, `qx5`, `wqd`, `mpt`.

**Architecture:** Four independent fixes in four different files. No interaction between them beyond Task 1 relocating a helper that Task 4's file already uses.

**Tech Stack:** bash (macOS bash 3.2 compatible), `jq`, bats.

## Global Constraints

- Bash 3.2: no associative arrays, no `${var^^}`, no `mapfile`.
- **bats runs under macOS system bash 3.2, where a failing NON-FINAL `[[ ]]` does NOT fail the test.** Every non-final `[[ ]]` needs `|| return 1`; single-bracket `[ ]` gates on its own.
- **A test asserting empty stdout alongside a required stderr reason MUST use `run --separate-stderr`** — plain `run` merges them, making the assertion unsatisfiable by any correct implementation.
- **Every new test must fail when its fix is reverted.** This codebase has shipped five tests that passed for a reason other than the one they claimed, every one caught in review rather than by the suite. The recurring shape: a downstream guard makes an upstream guard's test pass regardless of whether the upstream guard exists. When you write a test, ask what it would do if the code under test were deleted.
- Failure returns non-zero, writes nothing, reason on stderr.
- No event emission. `$ONLOOKER_DIR`, never a hardcoded `~/.onlooker`. American English.
- Commit via the `/commit` contract: `<type>(<scope>): <subject> :emoji:`, subject ≤72 chars including the emoji, why-focused body.

## File Structure

| File | Task |
|---|---|
| `plugins/librarian/scripts/lib/librarian-lesson-storage.sh` | 1 — gains the shared atomic-write helper |
| `plugins/librarian/scripts/lib/librarian-lesson-promote.sh` | 1 (helper removed), 4 (validation added) |
| `plugins/librarian/scripts/lib/librarian-lesson-review.sh` | 1 — three writes become atomic |
| `plugins/librarian/scripts/lib/librarian-lesson-judge.sh` | 2 — silent returns gain reasons |
| `plugins/librarian/scripts/lib/librarian-cli.sh` | 2 — `case "$rc"` gains a default arm |
| `plugins/librarian/scripts/lib/librarian-author-key.sh` | 3 — digest hex check |

---

### Task 1: Make the three proposal writes atomic (`ecosystem-a3b`)

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-storage.sh`, `librarian-lesson-promote.sh`, `librarian-lesson-review.sh`
- Test: `test/bats/librarian-lesson-review.bats`

**Interfaces:**
- Produces: `librarian_lesson_write_atomic <path> <content>` in `librarian-lesson-storage.sh` — temp file in the same directory, then `mv`. Returns non-zero without touching `<path>` on any failure.

`confirm`, `unconfirm`, and `pass` each write with `printf '%s\n' "$updated" > "$path"`, which **truncates before writing**. An interrupted write leaves a zero-byte proposal that every verb then refuses with "unrecognized status: " and `list_pending` hides — permanently stuck, and `unconfirm`, the recovery verb, cannot recover it either.

- [ ] **Step 1: Move the helper into storage**

`_librarian_lesson_write_atomic` already exists in `librarian-lesson-promote.sh`. Move it verbatim into `librarian-lesson-storage.sh`, renamed `librarian_lesson_write_atomic` (no leading underscore — it is no longer private to promote), and delete it from promote. Update promote's two call sites to the new name.

Both `review` and `promote` already depend on storage, so this is the direction dependencies already run.

```bash
# Write a file atomically: temp in the same directory, then mv.
#
# `printf > "$path"` truncates before writing, so an interrupted write leaves
# a zero-byte file. For a proposal that is permanently stuck: every verb
# refuses it with "unrecognized status: " and list_pending hides it, so even
# unconfirm — the recovery verb — cannot bring it back.
#
# Usage: librarian_lesson_write_atomic <path> <content>
librarian_lesson_write_atomic() {
	local path="$1"
	local content="$2"
	local tmp
	tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || return 1
	printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
	mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}
```

- [ ] **Step 2: Write the failing test**

Append to `test/bats/librarian-lesson-review.bats`. **A read-only-directory test would NOT discriminate** — it prevents the open entirely, so the old truncating code also leaves the original intact. The honest discriminator is that the write goes through a temp file at all, so spy on `mv`:

```bash
@test "confirm writes the proposal atomically, never truncating in place" {
	# `printf > path` truncates first, so an interrupted write leaves a
	# zero-byte proposal that every verb refuses and list_pending hides —
	# unrecoverable even by unconfirm. A read-only-dir test would NOT catch
	# this: it blocks the open entirely, so the truncating code also leaves
	# the original intact. What distinguishes atomic from not is that the
	# write lands somewhere else first, so spy on the rename.
	_review_setup
	local id
	id=$(_seed_pending)

	local marker="${BATS_TEST_TMPDIR}/mv-called"
	rm -f "$marker"
	mv() { printf '%s -> %s\n' "$1" "$2" >> "$marker"; command mv "$@"; }

	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"

	[ -f "$marker" ]
	grep -q "proposals/${id}.json" "$marker" || return 1
	[ "$(jq -r '.status' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/${id}.json")" = "confirmed" ]
	unset -f mv
}
```

Add the equivalent for `pass` and for `unconfirm`, each seeding the state that verb requires.

- [ ] **Step 3: Run to verify they fail**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: the three new tests FAIL — `mv` is never called by the truncating writes.

- [ ] **Step 4: Convert the three sites**

Replace each `printf '%s\n' "$updated" > "$path"` in `librarian-lesson-review.sh` (three sites: `confirm`, `unconfirm`, `pass`) with:

```bash
	librarian_lesson_write_atomic "$path" "$updated"
```

Preserve each site's existing return semantics — the function already returns non-zero on failure, so a bare call at the end of a function propagates correctly. Where a site is not the final statement, keep the existing `|| return 1`.

- [ ] **Step 5: Run to verify they pass, then prove they discriminate**

Run: `bats test/bats/librarian-lesson-review.bats` — expect PASS.

Then in a **fresh `git worktree`**, revert one site to `printf > "$path"` and confirm only that site's test fails. Remove the worktree.

- [ ] **Step 6: Lint and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-storage.sh
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-review.sh
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-promote.sh
bats test/bats/librarian-lesson-promote.bats
```

Commit subject: `fix(librarian): stop a killed write from bricking a proposal :lock:`

---

### Task 2: Give the silent failures a reason (`ecosystem-qx5`)

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-judge.sh`, `librarian-cli.sh`
- Test: `test/bats/librarian-lesson-judge.bats`

`librarian_lesson_judge` returns 1 with no output on several paths: empty `key`/`lesson_id`, `librarian_lesson_rubric_get` failing after visibility already validated, the two `jq -cn` verdict-construction failures, and the final write's `jq` failure. `librarian_cli_lessons_judge`'s `case "$rc"` has arms only for `0` and `2`, so nothing prints at either layer and the user sees an exit code with no explanation.

- [ ] **Step 1: Write the failing test**

Append to `test/bats/librarian-lesson-judge.bats`:

```bash
@test "a rubric missing from config is refused with a reason, not silently" {
	# Reachable by config drift: the visibility map still names a rubric that
	# librarian.lesson_judging.rubrics no longer defines. State stays safe —
	# nothing is written — but a user sees only an exit code.
	_seed_confirmed "cfg01" "org"
	_LIBRARIAN_CONFIG=$(printf '%s' "$_LIBRARIAN_CONFIG" | jq 'del(.librarian.lesson_judging.rubrics)')

	run --separate-stderr librarian_lesson_judge "$PROJECT_KEY" "cfg01" "$(_verdicts_pass)"
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
	[[ "$stderr" == *"rubric"* ]] || return 1
	[ "$(_status_of cfg01)" = "confirmed" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL on the `$stderr` assertion — the path currently prints nothing.

- [ ] **Step 3: Add the reasons**

Give every bare `return 1` in `librarian_lesson_judge` a `printf … >&2` naming what failed, matching the style of its siblings (`'Lesson %s not found.\n'`, `'Lesson %s is not confirmed; its status is: %s\n'`). At minimum:

- missing `key` or `lesson_id` → `author-key`-style usage message
- `librarian_lesson_rubric_get` failing → name the rubric id that is missing from config
- each `jq -cn` verdict-construction failure → say the verdict could not be built
- the final write failure → say the verdict could not be recorded

Then add a default arm to `librarian_cli_lessons_judge`'s `case "$rc"` so an unexplained non-zero still says something:

```bash
		*)
			printf 'Lesson %s could not be judged (exit %d); see above.\n' "$lesson_id" "$rc"
			;;
```

- [ ] **Step 4: Run, then prove it discriminates**

Run the judge suite — expect PASS. Then in a **fresh `git worktree`**, revert the rubric-missing message to a bare `return 1` and confirm the new test fails. Remove the worktree.

- [ ] **Step 5: Lint and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-judge.sh
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-cli.sh
bats test/bats/librarian-lesson-judge.bats
bats test/bats/librarian-lesson-promote.bats
```

Commit subject: `fix(librarian): say why judging failed instead of just exiting :speech_balloon:`

---

### Task 3: Check the digest's shape, not just its width (`ecosystem-wqd`)

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-author-key.sh`
- Test: `test/bats/librarian-author-key.bats`

`librarian_author_key` sanity-checks the HMAC subprocess's output with `[[ "${#digest}" -eq 64 ]]` — length only. A subprocess exiting 0 and printing 64 non-hex characters passes, gets truncated to 32, and is returned as an `author_key`, violating the interface's own contract and failing the contract's `/^[0-9a-f]{32}$/` at ingest.

- [ ] **Step 1: Write the failing test**

Append to `test/bats/librarian-author-key.bats`:

```bash
@test "a 64-character non-hex digest is refused, not truncated and returned" {
	# The width check alone cannot tell a digest from 64 arbitrary bytes.
	# Requires a misbehaving node, which is a serious precondition — but a
	# subprocess can misbehave for reasons other than compromise, and a
	# non-hex key fails the contract's own /^[0-9a-f]{32}$/ at ingest.
	_fixed_secret
	local stub_bin
	stub_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_bin"
	cat > "${stub_bin}/node" <<'STUB'
#!/usr/bin/env bash
printf 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
STUB
	chmod +x "${stub_bin}/node"

	local old_path="$PATH"
	export PATH="${stub_bin}:${PATH}"
	run --separate-stderr librarian_author_key "public"
	export PATH="$old_path"

	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	[[ "$stderr" == *"malformed"* ]] || return 1
}
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — the current check passes a 64-character non-hex string and returns `zzzz…` truncated to 32.

- [ ] **Step 3: Anchor the check**

Replace the width-only check with an anchored hex check on the raw digest, before truncation. Keep it fail-closed — non-zero, empty stdout, reason on stderr:

```bash
	if ! printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$'; then
		printf 'author-key: HMAC returned a malformed digest (expected 64 lowercase hex characters).\n' >&2
		return 1
	fi
```

**The three golden vectors must still pass unchanged.** If they move, the derivation changed — stop and report rather than updating them.

- [ ] **Step 4: Run, then prove it discriminates**

Run the author-key suite — expect PASS, golden vectors unchanged. Then in a **fresh `git worktree`**, revert to the width-only check and confirm the new test fails. Remove the worktree.

- [ ] **Step 5: Lint and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-author-key.sh
bats test/bats/librarian-author-key.bats
```

Commit subject: `fix(librarian): refuse a digest that is not 64 hex :closed_lock_with_key:`

---

### Task 4: Handle malformed proposals consistently (`ecosystem-mpt`)

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-promote.sh`
- Test: `test/bats/librarian-lesson-promote.bats`

Measured shapes, all `org`/`approved`: `verdict.judges: null` **accepted** (`consensus {judges:0, agreed:0}` — byte-identical to a legitimate private entry but carrying `source: "org"`, so unlike a private entry it *will* sync and fail ingest); `verdict.judges: "two"` refused; `judges` as an **object** accepted; no `candidate` accepted with the exact 13 keys and null values; no `judged_at` accepted with `decided_at: null`.

Three accepted, one refused, for the same class of corruption.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-promote.bats`, one per shape:

```bash
_promote_refuses_shape() {
	# $1 = id, $2 = jq program mutating the seeded proposal
	local id="$1" mutate="$2"
	_seed_judged "$id" "org" "approved" "$(_two_passing)"
	local p
	p="$(_dir)/proposals/${id}.json"
	local tmp="${BATS_TEST_TMPDIR}/${id}.json"
	jq "$mutate" "$p" > "$tmp" && mv "$tmp" "$p"

	run --separate-stderr librarian_lesson_promote "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	[ ! -f "$(_dir)/approved/${id}.json" ]
	[ "$(jq -r 'has("promoted_at")' "$p")" = "false" ]
}

@test "a null judges array is refused, not read as a jury-less lesson" {
	# The worst shape: consensus {judges:0, agreed:0} is byte-identical to a
	# legitimate private entry, but carries source "org" — so unlike a private
	# entry it WILL sync, and then fail ingest on ZConsensus.judges >= 1.
	_promote_refuses_shape "mal01" '.verdict.judges = null'
}

@test "a judges object rather than an array is refused" {
	_promote_refuses_shape "mal02" '.verdict.judges = {"a":{"passed":true}}'
}

@test "a proposal missing its candidate is refused" {
	# Currently produces the exact 13 ZLesson keys with null claim/rationale/
	# evidence/applies_to — it passes the key-set test while being empty.
	_promote_refuses_shape "mal03" 'del(.candidate)'
}

@test "a proposal missing judged_at is refused" {
	_promote_refuses_shape "mal04" 'del(.judged_at)'
}

@test "a well-formed proposal still promotes" {
	# The guard must not reject anything the pipeline actually produces.
	_seed_judged "ok01" "org" "approved" "$(_two_passing)"
	run librarian_lesson_promote "$PROJECT_KEY" "ok01"
	[ "$status" -eq 0 ]
	[ -f "$(_dir)/approved/ok01.json" ]
}
```

- [ ] **Step 2: Run to verify they fail**

Expected: `mal01`, `mal02`, `mal03`, `mal04` FAIL (currently accepted); `ok01` passes.

- [ ] **Step 3: Validate what promote actually reads**

Add one guard in `librarian_lesson_promote`, before building the entry, checking exactly the fields the mapping consumes. Emit one message naming what is missing:

```bash
	# Validate the fields the entry mapping reads. Without this, a corrupt
	# proposal produces a well-formed-but-empty pool entry that passes the
	# key-set check and fails at ingest — and a null judges array yields a
	# consensus byte-identical to a legitimate private entry while carrying a
	# syncing source.
	local missing
	missing=$(jq -r '
		[ (if (.candidate.claim | type) != "string" then "candidate.claim" else empty end),
		  (if (.candidate.rationale | type) != "string" then "candidate.rationale" else empty end),
		  (if (.candidate.evidence | type) != "object" then "candidate.evidence" else empty end),
		  (if (.candidate.applies_to | type) != "object" then "candidate.applies_to" else empty end),
		  (if (.judged_at | type) != "string" then "judged_at" else empty end),
		  (if (.verdict.judges | type) != "array" then "verdict.judges" else empty end)
		] | join(", ")' "$path" 2>/dev/null) || missing="unreadable"
	if [[ -n "$missing" ]]; then
		printf 'Lesson %s is malformed; cannot promote (bad or missing: %s).\n' \
			"$lesson_id" "$missing" >&2
		return 1
	fi
```

Place it in the `approved` branch only — a `rejected` proposal writes a declined row and never builds an entry, so requiring `candidate` fields of it would refuse rejections the pipeline legitimately produces. **Confirm that against the rejected-path tests before committing.**

- [ ] **Step 4: Run, then prove it discriminates**

Run the promote suite — expect PASS including the pre-existing 25. Then in a **fresh `git worktree`**, delete the guard and confirm exactly the four new refusal tests fail. Remove the worktree.

- [ ] **Step 5: Lint, full suite, and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-promote.sh
npm run test:ci
```

Read each exit code from `$?` directly — never through a pipe.

Commit subject: `fix(librarian): refuse a corrupt proposal instead of promoting it :shield:`

---

## Spec coverage

| Bead | Acceptance | Task |
|---|---|---|
| `a3b` | All three proposal writes atomic; an interrupted write leaves the prior proposal intact | 1 |
| `qx5` | Every non-zero return from `librarian_lesson_judge` produces a message identifying the failure | 2 |
| `wqd` | A subprocess returning 64 non-hex characters is refused, not truncated and returned; golden vectors unchanged | 3 |
| `mpt` | All malformed shapes produce the same outcome rather than three accepted and one refused | 4 |
