# Lesson Unconfirm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a human a way back from a confirmed lesson, before the jury has seen it.

**Architecture:** Two tasks. The first adds the snapshot to `librarian_lesson_confirm` and the `librarian_lesson_unconfirm` state transition beside it, in the same lib — they are one mechanism and a reviewer cannot sensibly accept one without the other. The second surfaces it as a CLI verb and a skill route.

**Tech Stack:** bash, `jq`, `bats`.

**Spec:** `docs/superpowers/specs/2026-08-11-lesson-unconfirm-design.md`

## Global Constraints

- Bash only. `jq` for JSON. TAB-indented. `shellcheck -S error -x` must be clean.
- Always `${ONLOOKER_DIR:-$HOME/.onlooker}` — never a literal `~/.onlooker`.
- **Never inline braces in a parameter-expansion default.** `${N:-{\}}` and `${N:-{}}` are both wrong. Default in a separate statement: `local p="${3:-}"` then `[ -z "$p" ] && p='{}'`. Guarded by `test/bats/emit-payload-default.bats`.
- bats runs under macOS bash 3.2, where a failing **non-final** `[[ ]]` does not fail the test. Use `[ ]`, or append `|| return 1`. Break each new assertion once to confirm it discriminates.
- **This stage must never invoke a model.** No `claude`, no network.
- **No event emission.** `librarian.lesson.*` is unregistered in `@onlooker-community/schema` 2.11.0; the emitter exits 1 on an unknown `event_type`.
- `unconfirm` proceeds only from `confirmed`. Every other status is refused, naming it.
- American English. Commit style `<type>(<scope>): <subject> :emoji:` with a why-focused body.

## File Structure

| File | Responsibility |
|---|---|
| `plugins/librarian/scripts/lib/librarian-lesson-review.sh` | Modified: snapshot on confirm; new `librarian_lesson_unconfirm` |
| `plugins/librarian/scripts/lib/librarian-cli.sh` | Modified: `lessons unconfirm` verb + dispatch arm |
| `plugins/librarian/skills/librarian/SKILL.md` | Modified: verb table and walk |
| `test/bats/librarian-lesson-review.bats` | Modified: append coverage for both tasks |

**Why the snapshot and the verb are one task.** The snapshot exists only to serve `unconfirm`; shipping it alone adds a field nothing reads, and shipping `unconfirm` alone leaves the justification case half-broken. A reviewer would reject either in isolation.

---

### Task 1: The snapshot and the unconfirm transition

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-review.sh`
- Test: `test/bats/librarian-lesson-review.bats` (append)

**Interfaces:**
- Consumes: `librarian_lessons_dir <key>` (existing).
- Produces: `librarian_lesson_unconfirm <key> <lesson_id>` → exit 0 on success or when already `pending`; exit 1 on `passed`, an unrecognized status, or a missing lesson. On success from `confirmed`: sets `status: "pending"`, removes `visibility`, `confirmed_at`, and `candidate_before_confirm`, and restores `.candidate` from the snapshot when one exists.
- Also produces: `librarian_lesson_confirm` now writes `candidate_before_confirm` **only** when it rewrites scope.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-review.bats`. The file already defines `_review_setup`, `_seed_pending`, `_evidence`, `_candidate`, `_versioned`, `_indep` — reuse them.

```bash
@test "confirm without a justification writes no snapshot" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	run jq -e 'has("candidate_before_confirm")' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -ne 0 ]
}

@test "confirm with a justification snapshots the pre-rewrite candidate" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git aborts on a dirty tree regardless of version"
	run jq -e '.candidate_before_confirm.applies_to.scope.kind == "versioned"' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "unconfirm returns a confirmed lesson to pending and clears the decision" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	run jq -e '.status == "pending" and (has("visibility") | not) and (has("confirmed_at") | not)' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "the round trip leaves the proposal byte-identical to its pre-confirm state" {
	_review_setup
	id=$(_seed_pending)
	before="${BATS_TEST_TMPDIR}/before.json"
	cp "${LESSONS_DIR}/proposals/${id}.json" "$before"

	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public" "git behavior is stable across versions"
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"

	run diff <(jq -S . "$before") <(jq -S . "${LESSONS_DIR}/proposals/${id}.json")
	[ "$status" -eq 0 ]
}

@test "unconfirm restores versioned scope after a justification confirm" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "stable across versions"
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	run jq -e '.candidate.applies_to.scope.kind == "versioned"
	           and (has("candidate_before_confirm") | not)' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "after unconfirm a fresh confirm at a different visibility succeeds" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "private"
	[ "$status" -eq 0 ]
	run jq -e '.status == "confirmed" and .visibility == "private"' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "unconfirm from pending is a no-op success" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	run jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "unconfirm refuses a passed lesson and leaves the ledger untouched" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_pass "$PROJECT_KEY" "$id" "not worth sharing"
	before_lines=$(wc -l < "${LESSONS_DIR}/passed.jsonl")

	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	run jq -e '.status == "passed"' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
	[ "$(wc -l < "${LESSONS_DIR}/passed.jsonl")" -eq "$before_lines" ]
}

@test "unconfirm refuses an unrecognized status and names it" {
	_review_setup
	id=$(_seed_pending)
	tmp="${BATS_TEST_TMPDIR}/mut.json"
	jq '.status = "judging"' "${LESSONS_DIR}/proposals/${id}.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/${id}.json"

	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	[[ "$output" == *"judging"* ]] || return 1
}

@test "unconfirm refuses a lesson that does not exist" {
	_review_setup
	run librarian_lesson_unconfirm "$PROJECT_KEY" "01KZNOSUCHLESSON0000000000"
	[ "$status" -ne 0 ]
}

@test "unconfirm never invokes a model" {
	_review_setup
	stub="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub"
	printf '#!/usr/bin/env bash\necho "MODEL WAS INVOKED" >&2\nexit 42\n' > "${stub}/claude"
	chmod +x "${stub}/claude"
	PATH="${stub}:${PATH}"

	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	[[ "$output" != *"MODEL WAS INVOKED"* ]] || return 1
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: the snapshot tests fail on a missing `candidate_before_confirm`; the rest fail with `librarian_lesson_unconfirm: command not found`. The 50 existing tests still pass.

- [ ] **Step 3: Snapshot the pre-rewrite candidate in `librarian_lesson_confirm`**

The rewrite block currently reads:

```bash
	if [[ -n "$justification" ]]; then
		candidate=$(printf '%s' "$candidate" | jq -c \
			--arg j "$justification" \
			'.applies_to.scope = {kind: "version_independent", justification: $j}' 2>/dev/null) || return 1
	fi
```

Capture the original before overwriting it:

```bash
	# Snapshot the candidate before the rewrite, so unconfirm can put it back.
	# Only when we actually rewrite: a plain confirm never touches .candidate,
	# so a snapshot there would be dead weight that unconfirm has to reason
	# about. Absence of the field means "nothing was mutated".
	local candidate_before=""
	if [[ -n "$justification" ]]; then
		candidate_before="$candidate"
		candidate=$(printf '%s' "$candidate" | jq -c \
			--arg j "$justification" \
			'.applies_to.scope = {kind: "version_independent", justification: $j}' 2>/dev/null) || return 1
	fi
```

Then extend the write. It currently reads:

```bash
	updated=$(printf '%s' "$proposal" | jq \
		--arg v "$visibility" --arg t "$now" --argjson c "$candidate" \
		'. * {status: "confirmed", visibility: $v, confirmed_at: $t} | .candidate = $c' 2>/dev/null) || return 1
```

Add the snapshot only when one was taken:

```bash
	if [[ -n "$candidate_before" ]]; then
		updated=$(printf '%s' "$proposal" | jq \
			--arg v "$visibility" --arg t "$now" \
			--argjson c "$candidate" --argjson cb "$candidate_before" \
			'. * {status: "confirmed", visibility: $v, confirmed_at: $t}
			 | .candidate = $c
			 | .candidate_before_confirm = $cb' 2>/dev/null) || return 1
	else
		updated=$(printf '%s' "$proposal" | jq \
			--arg v "$visibility" --arg t "$now" --argjson c "$candidate" \
			'. * {status: "confirmed", visibility: $v, confirmed_at: $t}
			 | .candidate = $c' 2>/dev/null) || return 1
	fi
```

Keep `.candidate = $c` as a plain assignment in both branches. It must not be folded into the `*` merge — `*` is recursive, so merging a `version_independent` scope over a stored `versioned` one leaves the old `versions` key behind and produces a candidate that fails its own validator. That is a bug this pipeline already shipped once.

- [ ] **Step 4: Add `librarian_lesson_unconfirm`**

Place it immediately after `librarian_lesson_confirm`:

```bash
# Take back a confirmation, before the jury has seen the lesson.
#
# `confirmed` is otherwise terminal: confirm refuses a differing repeat and
# pass refuses a confirmed lesson. Those guards are correct — they are what
# keeps passed.jsonl from contradicting the proposal it describes — but they
# left no way back from confirming at the wrong visibility, and `public` is
# the tier that leaves this machine.
#
# Proceeds ONLY from `confirmed`. Every other status is refused, which is also
# what makes this forward-safe: when the jury stage introduces a status of its
# own, this verb refuses it through the catch-all with no change here.
#
# Usage: librarian_lesson_unconfirm <key> <lesson_id>
librarian_lesson_unconfirm() {
	local key="$1"
	local lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local current_status
	current_status=$(jq -r '.status // ""' "$path" 2>/dev/null)

	case "$current_status" in
		confirmed) ;;
		pending) return 0 ;;
		passed)
			# Passing is a different decision with its own durable record.
			# Silently moving it back to pending would leave passed.jsonl
			# asserting a decision the proposal contradicts.
			printf 'Lesson %s was passed on, not confirmed; unconfirm does not undo that.\n' "$lesson_id" >&2
			return 1
			;;
		*)
			printf 'Lesson %s has an unrecognized status: %s\n' "$lesson_id" "$current_status" >&2
			return 1
			;;
	esac

	# Restore the pre-confirm candidate when one was snapshotted, and delete
	# the snapshot either way. A stale snapshot left on a pending proposal is
	# indistinguishable from a live one at the next confirm, and would
	# silently revert a later legitimate rewrite.
	local updated
	updated=$(jq '
		(if has("candidate_before_confirm") then .candidate = .candidate_before_confirm else . end)
		| del(.candidate_before_confirm, .visibility, .confirmed_at)
		| .status = "pending"
	' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	printf '%s\n' "$updated" > "$path"
}
```

- [ ] **Step 5: Run the tests**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: all pass — 50 existing plus 11 new.

- [ ] **Step 6: Fault-inject the three guarantees**

Each is a guarantee rather than a behavior. For each: make the change, run the named test, confirm it FAILS, revert, confirm it passes. Report each result.

1. Remove `del(.candidate_before_confirm, ...)`'s `candidate_before_confirm` term → "unconfirm restores versioned scope after a justification confirm" must fail.
2. Change the `passed)` arm to `return 0` → "unconfirm refuses a passed lesson and leaves the ledger untouched" must fail.
3. Remove the `candidate_before` capture in `confirm` → the round-trip test must fail.

If any does NOT fail when injected, say so rather than adjusting the test — that means the guarantee is unverified.

- [ ] **Step 7: Verify and commit**

Run: `shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-review.sh && bats test/bats/librarian-lesson-transform.bats && npm run lint:check`
Expected: shellcheck silent, transform suite unaffected, lint exit 0.

```bash
git add plugins/librarian/scripts/lib/librarian-lesson-review.sh \
        test/bats/librarian-lesson-review.bats
git commit -m "feat(librarian): let a human take back a confirmation :leftwards_arrow_with_hook:"
```

---

### Task 2: The CLI verb and the skill route

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-cli.sh`
- Modify: `plugins/librarian/skills/librarian/SKILL.md`
- Test: `test/bats/librarian-lesson-review.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_unconfirm <key> <lesson_id>` (Task 1); `_librarian_cli_project_key <cwd>` (existing).
- Produces: `librarian_cli lessons unconfirm <lesson_id> [cwd]`.

- [ ] **Step 1: Write the failing tests**

Append. The file already defines `_cli_setup`.

```bash
@test "lessons unconfirm returns a confirmed lesson to pending" {
	_cli_setup
	id=$(_seed_pending)
	librarian_cli lessons confirm "$id" public "$PROJECT_REPO" >/dev/null
	run librarian_cli lessons unconfirm "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	run jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "lessons unconfirm requires a lesson id" {
	_cli_setup
	run librarian_cli lessons unconfirm
	[ "$status" -ne 0 ]
}

@test "lessons unconfirm rejects an unknown flag" {
	_cli_setup
	id=$(_seed_pending)
	librarian_cli lessons confirm "$id" public "$PROJECT_REPO" >/dev/null
	run librarian_cli lessons unconfirm "$id" --force
	[ "$status" -ne 0 ]
	run jq -e '.status == "confirmed"' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "an unknown lessons verb is still rejected" {
	_cli_setup
	run librarian_cli lessons frobnicate
	[ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: the new tests fail with `unknown lessons action: unconfirm`.

- [ ] **Step 3: Add the verb**

Place it after `librarian_cli_lessons_pass`, mirroring that function's flag rejection:

```bash
librarian_cli_lessons_unconfirm() {
	local lesson_id="${1:-}"
	local cwd="${2:-}"
	[[ -z "$lesson_id" ]] && { printf 'usage: librarian_cli lessons unconfirm <lesson_id>\n'; return 1; }

	# Reject a flag-shaped token rather than treating it as cwd. The sibling
	# verbs already do this; a stray flag absorbed as a path resolves to the
	# wrong project key and the verb then reports success against a lesson it
	# never touched.
	case "$cwd" in
		--*) printf 'unknown option: %s\n' "$cwd" >&2; return 1 ;;
	esac

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	librarian_lesson_unconfirm "$key" "$lesson_id" || return 1
	printf 'Unconfirmed %s; it is pending again.\n' "$lesson_id"
}
```

Then add one arm to `librarian_cli_lessons`'s `case`, before the `*)` catch-all:

```bash
		unconfirm) librarian_cli_lessons_unconfirm "$@" ;;
```

- [ ] **Step 4: Run the tests**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: all pass.

- [ ] **Step 5: Update the skill**

In `plugins/librarian/skills/librarian/SKILL.md`, add `unconfirm` to the lessons verb table and to the usage comment line, matching the existing entries' shape:

```
librarian_cli lessons unconfirm <id>    take back a confirmation, before the jury sees it
```

In the walk section, describe it as the way to correct a confirmation made at the wrong visibility, and state that it works only on a `confirmed` lesson — a passed one stays passed, because that decision has its own record.

Read the surrounding text first and match its voice rather than pasting the sentence above verbatim.

- [ ] **Step 6: Verify and commit**

Run: `npm run test:ci` and capture the exit code directly — not through a pipe, since a pipe reports the last command's status rather than npm's.
Expected: exit 0.

```bash
git add plugins/librarian/scripts/lib/librarian-cli.sh \
        plugins/librarian/skills/librarian/SKILL.md \
        test/bats/librarian-lesson-review.bats
git commit -m "feat(librarian): surface unconfirm in the CLI and the review walk :leftwards_arrow_with_hook:"
```

---

## Self-review notes

**Spec coverage.** State rule → Task 1 Step 4; snapshot and its deletion → Task 1 Steps 3–4; surfaces → Task 2; events (none) → nothing emits, enforced by the Global Constraints; the seam to the jury → Task 1's `*)` arm, tested by the `judging` case; testing → each task's Step 1.

**On the `judging` test.** It mutates a proposal's status to a value nothing sets today, purely to prove the catch-all refuses an unrecognized status by name. That is the forward-safety promise to `4z8.3` made executable — without it, the promise is a comment.

**Deliberately absent.** No `judging` status is introduced. No undo for `pass`. No event emission.

**Known risk.** Task 1 modifies `librarian_lesson_confirm`, which took two fix rounds to harden in PR #137 — including the `*`-merge bug that persisted candidates failing their own validator. The round-trip test is the guard: it compares the post-unconfirm proposal against a byte-for-byte copy taken before the confirm, so any field the confirm adds and the unconfirm fails to remove shows up as a diff.
