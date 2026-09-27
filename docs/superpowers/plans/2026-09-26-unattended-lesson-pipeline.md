# Unattended Lesson Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a lesson reach the pool with no human step — the model supplies the version-independence justification, an unattended jury judges it against a stricter rubric, and it waits in a local hold before `sync` can ship it.

**Architecture:** Two new LLM stages in the detached classify worker (auto-confirm, auto-jury) plus a hold directory and a SessionStart sweep. The auto path reuses the human path verbatim: the transform still emits `scope: {kind: "unscoped"}` and auto-confirm calls the existing `librarian_lesson_confirm`, so no validator changes. Who asserted the scope is recorded in the proposal envelope as `asserted_by`, which selects a stricter rubric and triggers the hold.

**Tech Stack:** bash 3.2-compatible shell, `jq`, `claude -p --agent` for judge dispatch, bats-core for tests.

**Spec:** `docs/superpowers/specs/2026-09-26-automatic-lesson-promotion-design.md` (commit `bc3e910`). Read it before Task 1 — every decision below has a `D<n>` there.

**Tracking:** bead `ecosystem-kjy618`, Linear [ONL-111](https://linear.app/onlooker/issue/ONL-111).

## Global Constraints

- **Commits route through `/git-workflow:commit`.** Never craft `git commit -m` by hand.
- **American English** in code, comments, docs and commit messages.
- **Branch:** `meagan/onl-111-unattended-lesson-pipeline`, already cut from `origin/main` at `942d3ac`. Never push to `main`; the work lands via PR.
- **The pool entry is `ZLesson`, a strictObject — an extra key fails ingest.** Never add a field to the object `librarian_lesson_promote` builds for `approved/`. `shippable_after` goes in the **proposal envelope** (`proposals/<id>.json`), never in the pool entry. This is the single easiest way to break this feature in a way that only shows up at `sync`.
- **No LLM call on the `SessionEnd` path** (ADR-003). Both new LLM stages belong in `plugins/librarian/scripts/lib/librarian-classify-worker.sh`, which already runs detached with a 120s per-call timeout.
- **Never source anything under `plugins/tribunal/`** (ADR-002). Judges are dispatched **by name** with `claude -p --agent tribunal-judge-standard` / `-adversarial`.
- **`lesson_auto.enabled` defaults to `false`, and the disabled path must behave exactly as today.** A test asserts this.
- **The sweep runs regardless of `lesson_auto.enabled`** (D5). Gating it on the flag strands every held lesson the moment the flag is turned off.
- **A cost-control skip must never write a decline.** A decline is terminal (`librarian_lesson_seen` reads `declined.jsonl`).
- **For a single test file run `scripts/test/run-bats.sh <file>` directly.** Do **not** use `npm run test:bats -- <file>` — that passes the directory *and* the file to bats, which executes the file's tests zero times and exits 0 (ONL-109). `npm run test:bats` with no arguments is correct for the whole suite. Only one bats run at a time: the runner `rm -rf`s a shared report directory.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `plugins/librarian/scripts/lib/librarian-lesson-storage.sh` | `approved_held/` in `storage_init`; helpers to list held lessons and read/stamp `shippable_after` | 1 |
| `plugins/librarian/scripts/lib/librarian-lesson-promote.sh` | Route a model-asserted pool entry to `approved_held/` and stamp the envelope | 1 |
| `plugins/librarian/scripts/hooks/librarian-session-start.sh` | The sweep, and one surfaced line naming what is queued to leave | 2 |
| `plugins/librarian/scripts/lib/librarian-cli.sh` | `lessons queue`, `lessons veto` | 3 |
| `plugins/librarian/scripts/lib/librarian-lesson-review.sh` | `confirm` records `asserted_by` | 4 |
| `plugins/librarian/scripts/lib/librarian-lesson-rubric.sh` | Rubric selection keyed on `(visibility, asserted_by)` | 4 |
| `plugins/librarian/scripts/lib/librarian-lesson-judge.sh` | Pass the proposal's `asserted_by` into rubric selection | 4 |
| `plugins/librarian/config.json` | `lesson-promotion-public-auto` rubric; the `lesson_auto` block | 4, 6 |
| `plugins/librarian/scripts/lib/librarian-lesson-auto.sh` | **New.** The auto-confirm justification call and the auto-jury dispatch | 5, 6 |
| `plugins/librarian/scripts/lib/librarian-classify-worker.sh` | Stages 6 and 7, gated on `enabled`, with the jury cap | 5, 6 |
| `test/bats/librarian-lesson-hold.bats` | **New.** Hold, sweep, queue, veto | 1, 2, 3 |
| `test/bats/librarian-lesson-auto.bats` | **New.** `asserted_by`, rubric selection, auto-confirm, auto-jury | 4, 5, 6 |

Tasks 1–3 are the veto window and land first; they are inert until Task 5 writes an `asserted_by: "model"` envelope, which is what makes that order safe (spec, Shipping order).

---

### Task 1: Hold a model-asserted lesson instead of shipping it

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-storage.sh` (`librarian_lesson_storage_init`), `plugins/librarian/scripts/lib/librarian-lesson-promote.sh` (the approved branch, around `:164`)
- Test: `test/bats/librarian-lesson-hold.bats` (new)

**Interfaces:**
- Produces: `approved_held/` under `librarian_lessons_dir <key>`; `librarian_lesson_held_dir <key>` printing its path; a `shippable_after` field (RFC3339) on the proposal envelope. Task 2 consumes both.
- Consumes: nothing. `asserted_by` is read with a `// "human"` default, so this task is complete and testable before anything writes it.

- [ ] **Step 1: Write the failing tests**

Create `test/bats/librarian-lesson-hold.bats`. Model `setup()` and the project scaffolding on `test/bats/librarian-lesson-review.bats`'s `_review_setup` (`:80`), which inits a repo, resolves `PROJECT_KEY`, sets `LESSONS_DIR` and calls `librarian_config_load`. Seed a judged proposal by writing the envelope directly — reaching `approved` through the real path means empaneling a jury, and `librarian-lesson-review.bats` already sets a precedent for forcing status on disk with its `_set_status` helper (`:400`).

```bash
_seed_judged() {
	# $1 = lesson id, $2 = asserted_by ("human" or "model")
	local id="$1" asserted="$2"
	jq -cn --arg id "$id" --arg a "$asserted" \
		--argjson cand "$(_candidate "$(_indep)")" \
		'{id: $id, status: "approved", visibility: "public",
		  artifact_id: "01KZ45MKAM734ZS7JK24D2DK0R", candidate: $cand,
		  asserted_by: $a, judged_at: "2026-09-26T12:00:00Z",
		  verdict: {passed: true, judges: [{passed: true}, {passed: true}]}}' \
		> "${LESSONS_DIR}/proposals/${id}.json"
}

@test "storage_init creates approved_held" {
	_hold_setup
	[ -d "${LESSONS_DIR}/approved_held" ]
}

@test "a model-asserted lesson is promoted into approved_held, not approved" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	run librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	[ "$status" -eq 0 ]
	[ -f "${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670K.json" ]
	[ ! -f "${LESSONS_DIR}/approved/01M3B87J7046SJE5BECNMP670K.json" ]
}

@test "the hold stamps shippable_after on the envelope, never on the pool entry" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	run librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	[ "$status" -eq 0 ]
	jq -e '.shippable_after | type == "string"' \
		"${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670K.json"
	# ZLesson is a strictObject: an extra key fails ingest at sync.
	jq -e 'has("shippable_after") | not' \
		"${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670K.json"
}

@test "a human-asserted lesson still goes straight to approved" {
	_hold_setup
	_seed_judged 01M33440PGTWP4QMMG1BVA52DR human
	run librarian_lesson_promote "$PROJECT_KEY" 01M33440PGTWP4QMMG1BVA52DR
	[ "$status" -eq 0 ]
	[ -f "${LESSONS_DIR}/approved/01M33440PGTWP4QMMG1BVA52DR.json" ]
	[ ! -f "${LESSONS_DIR}/approved_held/01M33440PGTWP4QMMG1BVA52DR.json" ]
}

@test "an envelope with no asserted_by is treated as human" {
	_hold_setup
	_seed_judged 01M3ASXRSRGY9TXKV045NK8V7G human
	# Remove the field entirely: every proposal written before this change.
	tmp=$(mktemp); jq 'del(.asserted_by)' \
		"${LESSONS_DIR}/proposals/01M3ASXRSRGY9TXKV045NK8V7G.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M3ASXRSRGY9TXKV045NK8V7G.json"
	run librarian_lesson_promote "$PROJECT_KEY" 01M3ASXRSRGY9TXKV045NK8V7G
	[ "$status" -eq 0 ]
	[ -f "${LESSONS_DIR}/approved/01M3ASXRSRGY9TXKV045NK8V7G.json" ]
}
```

The three setups used across Tasks 1–6, defined once here. Copy `_evidence`, `_candidate`,
`_indep` and `_unscoped` verbatim from `librarian-lesson-review.bats:15-27` into whichever new
file needs them:

```bash
_hold_setup() {
	for lib in librarian-project-key librarian-ulid librarian-storage \
		librarian-lesson-storage librarian-lesson-validate librarian-config \
		librarian-lesson-promote; do
		# shellcheck disable=SC1091
		source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh"
	done
	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-hold.git
	PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"
	librarian_config_load "$PROJECT_REPO"
}

# Task 3 only: adds the CLI and the emitter on top.
_hold_cli_setup() {
	_hold_setup
	for lib in librarian-emit librarian-cli; do
		# shellcheck disable=SC1091
		source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh"
	done
}

# Tasks 4-6: adds review, rubric, judge, transform (for the JSON extractor) and
# the auto lib. librarian-lesson-transform.sh MUST be sourced before
# librarian-lesson-auto.sh, which calls _librarian_lesson_extract_json_object.
_auto_setup() {
	_hold_setup
	for lib in librarian-lesson-review librarian-lesson-rubric \
		librarian-lesson-judge librarian-lesson-transform librarian-emit \
		librarian-cli librarian-lesson-auto; do
		# shellcheck disable=SC1091
		source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh"
	done
}
```

`_auto_setup` sources `librarian-lesson-auto.sh`, which does not exist until Task 5 — so Task 4's
tests must drop it from that list and Task 5 adds it back. Note that in Task 4's Step 1 rather
than discovering it at run time.

- [ ] **Step 2: Run them and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-hold.bats`
Expected: the first three FAIL (`approved_held` does not exist and promote knows nothing about holding). The last two PASS already — today every lesson goes to `approved/` — and they are the regression guards for Step 3.

- [ ] **Step 3: Create the hold directory and a path helper**

In `librarian-lesson-storage.sh`, beside `librarian_lessons_dir`:

```bash
# The hold: an approved lesson that is not yet allowed to leave the machine.
#
# `onlooker sync` reads lessons/approved/*.json and nothing else (see
# apps/cli/src/lessons.ts in the onlooker repo), so holding a lesson is just
# keeping it out of that directory. That is the whole mechanism — no field on
# the pool entry, no change to sync, no change to the pool contract.
#
# Usage: librarian_lesson_held_dir <key>
librarian_lesson_held_dir() {
	local key="$1"
	printf '%s/approved_held' "$(librarian_lessons_dir "$key")"
}
```

and extend `storage_init`'s `mkdir`:

```bash
	mkdir -p "$dir/proposals" "$dir/approved" "$dir/approved_held" 2>/dev/null
```

- [ ] **Step 4: Route the pool entry and stamp the envelope**

In `librarian-lesson-promote.sh`'s approved branch, replace the `pool_path` assignment (currently `pool_path="${dir}/approved/${lesson_id}.json"`, around `:164`) with a routed one. Read `asserted_by` from the envelope near where `current_status` is read:

```bash
	local asserted_by
	asserted_by=$(jq -r '.asserted_by // "human"' "$path" 2>/dev/null)
	[[ -z "$asserted_by" || "$asserted_by" == "null" ]] && asserted_by="human"
```

then, in place of the old assignment:

```bash
		# A model-asserted lesson is held: nobody chose to publish it, so it
		# waits where sync cannot see it until the veto window elapses. A
		# human-asserted one is unchanged — the attended path is not penalized.
		if [[ "$asserted_by" == "model" ]]; then
			pool_path="$(librarian_lesson_held_dir "$key")/${lesson_id}.json"
		else
			pool_path="${dir}/approved/${lesson_id}.json"
		fi
```

Then, immediately after the successful pool write and before the function returns, stamp the window onto the **envelope** for a held lesson. Put it beside the existing `promoted_at` stamp (around `:233`) so one `jq` writes both, rather than reading and writing the file twice:

Replace only the `updated=$(jq ...)` line in that block. Everything around it — the
`stamp_fail_msg`, the empty/null check, and the `librarian_lesson_write_atomic` call — stays
exactly as it is, because the ordering note above it explains why every failure past this point
must report on stderr rather than return bare:

```bash
	local updated stamp_fail_msg
	stamp_fail_msg=$(printf "Lesson %s: terminal record written but promoted_at could not be stamped; re-run 'lessons promote %s'." \
		"$lesson_id" "$lesson_id")

	# shippable_after goes on the ENVELOPE, never on the pool entry: the entry
	# is ZLesson, a strictObject, and an extra key fails ingest at sync. One jq
	# writes both stamps, so a held lesson can never end up with promoted_at and
	# no window.
	if [[ "$asserted_by" == "model" ]]; then
		local window shippable
		window=$(librarian_config_get '.librarian.lesson_auto.veto_window_hours' 2>/dev/null)
		case "$window" in ''|null) window=72 ;; esac
		# -v+NH is BSD (macOS), -d is GNU. The order matters: BSD date accepts
		# -d as an entirely different flag, so GNU must be the fallback.
		shippable=$(date -u -v"+${window}H" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
			|| shippable=$(date -u -d "+${window} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
		if [[ -z "$shippable" ]]; then
			printf '%s\n' "$stamp_fail_msg" >&2
			return 1
		fi
		updated=$(jq --arg t "$now" --arg s "$shippable" \
			'.promoted_at = $t | .shippable_after = $s' "$path" 2>/dev/null) || {
			printf '%s\n' "$stamp_fail_msg" >&2
			return 1
		}
	else
		updated=$(jq --arg t "$now" '.promoted_at = $t' "$path" 2>/dev/null) || {
			printf '%s\n' "$stamp_fail_msg" >&2
			return 1
		}
	fi
```

A `shippable` that came back empty from both `date` forms must fail rather than write an
unbounded hold: an envelope with `promoted_at` and no `shippable_after` is a lesson the sweep
will never move (it fails closed on an unreadable window, Task 2), so it would sit in the hold
forever with no diagnostic.

- [ ] **Step 5: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-hold.bats`
Expected: all five PASS.

- [ ] **Step 6: Run the full suite and commit**

Run: `npm run test:ci` (capture npm's own exit status — do not pipe it to `tail`, or you read `tail`'s status instead)
Expected: PASS.

Then `/git-workflow:commit`: a `feat(librarian)` change adding the hold, whose body explains that the window is a directory because `sync` reads `approved/` only, and that `shippable_after` is on the envelope because the pool entry is a strictObject. `Refs ONL-111`.

---

### Task 2: Sweep the hold at SessionStart

**Files:**
- Modify: `plugins/librarian/scripts/hooks/librarian-session-start.sh` (after `PROJECT_KEY` resolves, around `:73`; the surfaced line near `:119`)
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-storage.sh` (the sweep itself, so it is unit-testable without the hook)
- Test: `test/bats/librarian-lesson-hold.bats`

**Interfaces:**
- Consumes: Task 1's `librarian_lesson_held_dir` and `shippable_after`.
- Produces: `librarian_lesson_sweep_held <key>` printing each swept lesson id, one per line; `librarian_lesson_count_held <key>` printing an integer. Task 3 consumes the count.

- [ ] **Step 1: Write the failing tests**

```bash
@test "the sweep moves a held lesson whose window has elapsed" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	# Backdate the window so it is already past.
	tmp=$(mktemp); jq '.shippable_after = "2020-01-01T00:00:00Z"' \
		"${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670K.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670K.json"

	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	[[ "$output" == *"01M3B87J7046SJE5BECNMP670K"* ]]
	[ -f "${LESSONS_DIR}/approved/01M3B87J7046SJE5BECNMP670K.json" ]
	[ ! -f "${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670K.json" ]
}

@test "the sweep leaves a held lesson whose window has not elapsed" {
	_hold_setup
	_seed_judged 01M33440PGTWP4QMMG1BVA52DR model
	librarian_lesson_promote "$PROJECT_KEY" 01M33440PGTWP4QMMG1BVA52DR
	tmp=$(mktemp); jq '.shippable_after = "2099-01-01T00:00:00Z"' \
		"${LESSONS_DIR}/proposals/01M33440PGTWP4QMMG1BVA52DR.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M33440PGTWP4QMMG1BVA52DR.json"

	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ -f "${LESSONS_DIR}/approved_held/01M33440PGTWP4QMMG1BVA52DR.json" ]
}

@test "a held lesson with no readable envelope is left alone, not shipped" {
	_hold_setup
	_seed_judged 01M3ASXRSRGY9TXKV045NK8V7G model
	librarian_lesson_promote "$PROJECT_KEY" 01M3ASXRSRGY9TXKV045NK8V7G
	rm -f "${LESSONS_DIR}/proposals/01M3ASXRSRGY9TXKV045NK8V7G.json"
	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	# Unknown window must fail closed: a lesson whose window cannot be read
	# must never be shipped by default.
	[ -f "${LESSONS_DIR}/approved_held/01M3ASXRSRGY9TXKV045NK8V7G.json" ]
}

@test "the sweep is idempotent" {
	_hold_setup
	_seed_judged 01M3B93JPGAKHGEQ5KD9N836HD model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B93JPGAKHGEQ5KD9N836HD
	tmp=$(mktemp); jq '.shippable_after = "2020-01-01T00:00:00Z"' \
		"${LESSONS_DIR}/proposals/01M3B93JPGAKHGEQ5KD9N836HD.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M3B93JPGAKHGEQ5KD9N836HD.json"
	librarian_lesson_sweep_held "$PROJECT_KEY"
	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "count_held counts only what is still held" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	run librarian_lesson_count_held "$PROJECT_KEY"
	[ "$output" -eq 1 ]
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-hold.bats`
Expected: the five new tests FAIL with `command not found` (127) — neither function exists. Task 1's five still pass.

- [ ] **Step 3: Implement the sweep**

In `librarian-lesson-storage.sh`:

```bash
# Move every held lesson whose window has elapsed into approved/, printing the
# ids it moved. Deterministic file movement, no LLM work, so it is safe on the
# SessionStart path.
#
# Fails closed on an unreadable window: a held lesson whose envelope is missing
# or whose shippable_after will not parse stays held. The alternative — treating
# unknown as elapsed — would ship exactly the lessons whose provenance is
# already in question.
#
# Usage: librarian_lesson_sweep_held <key>
librarian_lesson_sweep_held() {
	local key="$1"
	[[ -z "$key" ]] && return 1

	local dir held_dir
	dir=$(librarian_lessons_dir "$key")
	held_dir=$(librarian_lesson_held_dir "$key")
	[[ -d "$held_dir" ]] || return 0

	local now file id shippable
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# nullglob so an empty hold yields nothing rather than the literal pattern.
	local had_nullglob=0
	shopt -q nullglob && had_nullglob=1
	shopt -s nullglob
	for file in "${held_dir}"/*.json; do
		id=$(basename "$file" .json)
		shippable=$(jq -r '.shippable_after // ""' \
			"${dir}/proposals/${id}.json" 2>/dev/null) || shippable=""
		[[ -z "$shippable" || "$shippable" == "null" ]] && continue
		# RFC3339 UTC with a fixed width, so a lexical compare is a time
		# compare. Both values are produced by `date -u +%Y-%m-%dT%H:%M:%SZ`.
		[[ "$now" < "$shippable" ]] && continue
		mkdir -p "${dir}/approved" 2>/dev/null
		mv -f "$file" "${dir}/approved/${id}.json" 2>/dev/null || continue
		printf '%s\n' "$id"
	done
	[[ "$had_nullglob" -eq 0 ]] && shopt -u nullglob
	return 0
}

# Usage: librarian_lesson_count_held <key>
librarian_lesson_count_held() {
	local key="$1"
	local held_dir
	held_dir=$(librarian_lesson_held_dir "$key")
	[[ -d "$held_dir" ]] || { printf '0'; return 0; }
	local n
	n=$(find "$held_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
	printf '%s' "${n:-0}"
}
```

- [ ] **Step 4: Call the sweep from the hook and surface the count**

In `librarian-session-start.sh`, after `PROJECT_KEY` is resolved and before the `SKIP_WHEN_ZERO` read:

```bash
# Unconditional: NOT gated on lesson_auto.enabled. Gating it would strand every
# held lesson the moment the flag was turned off — written, judged, approved,
# and invisible forever. Deterministic file movement, no LLM call, so ADR-003
# is satisfied.
librarian_lesson_sweep_held "$PROJECT_KEY" >/dev/null 2>&1 || true

HELD=$(librarian_lesson_count_held "$PROJECT_KEY" 2>/dev/null) || HELD=0
```

and extend the surfaced lines beside `LESSON_LINE` (`:119`):

```bash
HELD_LINE=""
if [[ "${HELD:-0}" -gt 0 ]]; then
	HELD_LINE=$(printf '%s lesson(s) will leave this machine unless vetoed — run /librarian lessons queue' "$HELD")
fi

if [[ -n "$HELD_LINE" ]]; then
	if [[ -n "$CONTEXT" ]]; then
		CONTEXT="${CONTEXT}"$'\n'"${HELD_LINE}"
	else
		CONTEXT="$HELD_LINE"
	fi
fi
```

Place this block after the existing `LESSON_LINE` append so the ordering of the two lines is stable, and confirm `librarian-lesson-storage.sh` is among the libs the hook already sources — if it is not, source it beside the others rather than at the point of use.

- [ ] **Step 5: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-hold.bats`
Expected: all ten PASS.

- [ ] **Step 6: Full suite and commit**

Run: `npm run test:ci`. Then `/git-workflow:commit`: a `feat(librarian)` change adding the sweep, whose body explains why it runs with the flag off and why an unreadable window fails closed. `Refs ONL-111`.

---

### Task 3: See and kill what is waiting

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-cli.sh` (dispatch in `librarian_cli_lessons`, plus two new functions)
- Test: `test/bats/librarian-lesson-hold.bats`

**Interfaces:**
- Consumes: Task 1's `librarian_lesson_held_dir`, Task 2's `librarian_lesson_count_held`.
- Produces: `librarian_cli lessons queue [cwd]` and `librarian_cli lessons veto <id> [reason] [cwd]`.

- [ ] **Step 1: Write the failing tests**

These need the CLI sourced; follow `librarian-lesson-review.bats`'s `_cli_setup` (`:380`), which sources `librarian-config`, `librarian-emit` and `librarian-cli` on top of the review setup.

```bash
@test "lessons queue lists a held lesson with its window" {
	_hold_cli_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	run librarian_cli lessons queue "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"01M3B87J7046SJE5BECNMP670K"* ]]
	[[ "$output" == *"shippable"* ]]
}

@test "lessons queue says so when nothing is held" {
	_hold_cli_setup
	run librarian_cli lessons queue "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nothing is waiting to leave"* ]]
}

@test "lessons veto removes a held lesson and tombstones it" {
	_hold_cli_setup
	_seed_judged 01M33440PGTWP4QMMG1BVA52DR model
	librarian_lesson_promote "$PROJECT_KEY" 01M33440PGTWP4QMMG1BVA52DR
	run librarian_cli lessons veto 01M33440PGTWP4QMMG1BVA52DR "overreaches" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ ! -f "${LESSONS_DIR}/approved_held/01M33440PGTWP4QMMG1BVA52DR.json" ]
	[ ! -f "${LESSONS_DIR}/approved/01M33440PGTWP4QMMG1BVA52DR.json" ]
	tail -n 1 "${LESSONS_DIR}/declined.jsonl" | jq -e '.reason == "vetoed"'
}

@test "lessons veto refuses a lesson that is not held" {
	_hold_cli_setup
	run librarian_cli lessons veto 01M3ASXRSRGY9TXKV045NK8V7G "" "$PROJECT_REPO"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not held"* ]]
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-hold.bats`
Expected: the four new tests FAIL — `unknown lessons action: queue`.

- [ ] **Step 3: Implement both verbs**

Add to `librarian_cli_lessons`'s case, after `reconsider`:

```bash
		queue) librarian_cli_lessons_queue "$@" ;;
		veto) librarian_cli_lessons_veto "$@" ;;
```

and the two functions, following `librarian_cli_lessons_promote`'s arg shape (options, then an optional trailing `[cwd]`):

```bash
# List lessons that are approved but still held, with when each becomes
# shippable. This is the only surface between an unattended promotion and the
# pool, so it prints the claim too — an id alone is not reviewable.
librarian_cli_lessons_queue() {
	local cwd=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--*) printf 'unknown option: %s\n' "$1" >&2; return 1 ;;
			*) cwd="$1"; shift ;;
		esac
	done

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	local dir held_dir file id shippable claim found=0
	dir=$(librarian_lessons_dir "$key")
	held_dir=$(librarian_lesson_held_dir "$key")
	if [[ -d "$held_dir" ]]; then
		for file in "${held_dir}"/*.json; do
			[[ -f "$file" ]] || continue
			found=1
			id=$(basename "$file" .json)
			shippable=$(jq -r '.shippable_after // "unknown"' \
				"${dir}/proposals/${id}.json" 2>/dev/null) || shippable="unknown"
			claim=$(jq -r '.claim // ""' "$file" 2>/dev/null)
			printf '%s  shippable %s  %s\n' "$id" "$shippable" "$claim"
		done
	fi
	[[ "$found" -eq 0 ]] && printf 'Nothing is waiting to leave this machine.\n'
	return 0
}

# Kill a held lesson before it ships. Writes a tombstone so the same content is
# not re-proposed, and a declined row so the ledger records that a human
# overrode the jury.
librarian_cli_lessons_veto() {
	local lesson_id="" reason="" cwd=""
	local positional=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--*) printf 'unknown option: %s\n' "$1" >&2; return 1 ;;
			*)
				case "$positional" in
					0) lesson_id="$1" ;;
					1) reason="$1" ;;
					*) cwd="$1" ;;
				esac
				positional=$((positional + 1))
				shift
				;;
		esac
	done
	[[ -z "$lesson_id" ]] && { printf 'usage: librarian_cli lessons veto <lesson_id> [reason] [cwd]\n'; return 1; }

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	local held_dir path dir artifact_id
	dir=$(librarian_lessons_dir "$key")
	held_dir=$(librarian_lesson_held_dir "$key")
	path="${held_dir}/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s is not held.\n' "$lesson_id" >&2; return 1; }

	artifact_id=$(jq -r '.artifact_id // ""' "${dir}/proposals/${lesson_id}.json" 2>/dev/null)
	rm -f "$path" || return 1
	if [[ -n "$artifact_id" ]]; then
		librarian_lesson_append_declined "$key" "$artifact_id" vetoed "$reason" "" "$lesson_id" || true
	fi
	printf 'Lesson %s vetoed; it will not leave this machine.\n' "$lesson_id"
	return 0
}
```

Check `librarian_lesson_append_declined`'s positional order before wiring the call: it is `<key> <artifact_id> <reason> [detail] [verdict] [lesson_id]`, so the empty fifth argument is the verdict slot and must stay empty.

- [ ] **Step 4: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-hold.bats`
Expected: all fourteen PASS.

- [ ] **Step 5: Document the two verbs in the skill**

In `plugins/librarian/skills/librarian/SKILL.md`, in the request-parsing list near `:21`, add:

```markdown
- `lessons queue` → print held lessons and stop
- `lessons veto <id> [reason]` → kill a held lesson before it ships
```

- [ ] **Step 6: Full suite and commit**

Run: `npm run test:ci`. Then `/git-workflow:commit`: a `feat(librarian)` change adding `queue` and `veto`, body noting that `queue` prints the claim because an id alone is not reviewable. `Refs ONL-111`.

---

### Task 4: Record who asserted the scope, and judge accordingly

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-review.sh` (`librarian_lesson_confirm`), `plugins/librarian/scripts/lib/librarian-lesson-rubric.sh` (`librarian_lesson_rubric_id_for_visibility`), `plugins/librarian/scripts/lib/librarian-lesson-judge.sh` (the `rubric_id` call, `:240`), `plugins/librarian/config.json` (new rubric)
- Test: `test/bats/librarian-lesson-auto.bats` (new)

**Interfaces:**
- Consumes: nothing from Tasks 1–3 at runtime, but Task 1's promote reads the `asserted_by` this task writes.
- Produces: `librarian_lesson_confirm <key> <lesson_id> <visibility> [justification] [asserted_by]` writing `asserted_by` into the envelope (default `"human"`); `librarian_lesson_rubric_id_for_visibility <visibility> [asserted_by]`; the rubric id `lesson-promotion-public-auto`. Tasks 5 and 6 consume the confirm signature.

- [ ] **Step 1: Write the failing tests**

Create `test/bats/librarian-lesson-auto.bats`, reusing the review-style setup (`_candidate`, `_unscoped` from `librarian-lesson-review.bats:27`, `_review_setup`).

```bash
@test "confirm records asserted_by human by default" {
	_auto_setup
	id=$(_seed_pending_unscoped)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	jq -e '.asserted_by == "human"' "${LESSONS_DIR}/proposals/${id}.json"
}

@test "confirm records asserted_by model when told" {
	_auto_setup
	id=$(_seed_pending_unscoped)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version" model
	jq -e '.asserted_by == "model"' "${LESSONS_DIR}/proposals/${id}.json"
	jq -e '.candidate.applies_to.scope.kind == "version_independent"
	   and (.candidate.applies_to.scope | has("versions") | not)' \
		"${LESSONS_DIR}/proposals/${id}.json"
}

@test "rubric selection is unchanged for a human assertion" {
	_auto_setup
	run librarian_lesson_rubric_id_for_visibility public
	[ "$output" = "lesson-promotion-public" ]
	run librarian_lesson_rubric_id_for_visibility org
	[ "$output" = "lesson-promotion" ]
	run librarian_lesson_rubric_id_for_visibility public human
	[ "$output" = "lesson-promotion-public" ]
}

@test "a model assertion selects the auto rubric at every tier" {
	_auto_setup
	run librarian_lesson_rubric_id_for_visibility public model
	[ "$output" = "lesson-promotion-public-auto" ]
	# org omits disclosure entirely, which does not hold once nobody is present.
	run librarian_lesson_rubric_id_for_visibility org model
	[ "$output" = "lesson-promotion-public-auto" ]
}

@test "private runs no jury even for a model assertion" {
	_auto_setup
	run librarian_lesson_rubric_id_for_visibility private model
	[ -z "$output" ]
}

@test "the auto rubric is defined and strictly harder than the public one" {
	_auto_setup
	auto=$(librarian_lesson_rubric_get lesson-promotion-public-auto)
	[ -n "$auto" ]
	human=$(librarian_lesson_rubric_get lesson-promotion-public)
	# Same criteria and weights, every floor at least as high, threshold higher.
	[ "$(printf '%s' "$auto" | jq -c '[.criteria[] | {name, weight}] | sort_by(.name)')" \
	  = "$(printf '%s' "$human" | jq -c '[.criteria[] | {name, weight}] | sort_by(.name)')" ]
	printf '%s' "$auto" | jq -e '.score_threshold == 0.85'
	printf '%s' "$auto" | jq -e '[.criteria[] | .min_pass] | min >= 0.7'
	printf '%s' "$auto" | jq -e '.judge_types | sort == ["adversarial","standard"]'
}

@test "a model-asserted lesson is rejected at a score the human floor would pass" {
	_auto_setup
	id=$(_seed_pending_unscoped)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" public "holds regardless of version" model
	# scope_accuracy 0.75 clears the human floor (0.70) and fails the model one (0.80).
	verdicts='[{"score":0.9,"passed":true,"judge_type":"standard","criterion_scores":{"grounding":0.9,"scope_accuracy":0.75,"generality":0.9,"disclosure":0.99}},
	           {"score":0.9,"passed":true,"judge_type":"adversarial","criterion_scores":{"grounding":0.9,"scope_accuracy":0.75,"generality":0.9,"disclosure":0.99}}]'
	run librarian_lesson_judge "$PROJECT_KEY" "$id" "$verdicts"
	[ "$status" -eq 0 ]
	jq -e '.status == "rejected" and .verdict.failed_criterion == "scope_accuracy"' \
		"${LESSONS_DIR}/proposals/${id}.json"
}
```

`_seed_pending_unscoped` writes a pending proposal whose `candidate.applies_to.scope` is `{"kind":"unscoped"}` and prints its id — copy it from `librarian-lesson-review.bats`.

- [ ] **Step 2: Run and confirm failure**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats`
Expected: FAIL. `asserted_by` is never written, the second rubric argument is ignored, and `lesson-promotion-public-auto` is not in config.

- [ ] **Step 3: Write `asserted_by` in confirm**

In `librarian_lesson_confirm`, add the parameter:

```bash
	local asserted_by="${5:-human}"
	case "$asserted_by" in
		human|model) ;;
		*) printf 'asserted_by must be human or model\n' >&2; return 1 ;;
	esac
```

and include it in the envelope write. Find the `jq` that sets `status`/`visibility` on the confirmed proposal and add `| .asserted_by = $ab` with `--arg ab "$asserted_by"`. It must be the same `jq` invocation that already writes the status transition, so the field cannot land without the transition or vice versa.

- [ ] **Step 4: Key rubric selection on the asserter**

```bash
# Usage: librarian_lesson_rubric_id_for_visibility <visibility> [asserted_by]
#
# asserted_by defaults to "human", so every existing caller keeps today's
# behavior. A MODEL-asserted lesson selects the auto rubric at every tier,
# including org: the org rubric omits `disclosure` on the reasoning that the
# audience is trusted and a human read the text before it went, and neither
# half survives nobody being present.
#
# private still returns the empty string. That tier runs no jury, which is what
# makes cost scale with intent, and an unattended lesson nobody publishes is
# not a reason to start empaneling one.
librarian_lesson_rubric_id_for_visibility() {
	local visibility="${1:-}"
	local asserted_by="${2:-human}"
	case "$visibility" in
		private) printf '' ;;
		org|public)
			if [[ "$asserted_by" == "model" ]]; then
				printf 'lesson-promotion-public-auto'
			elif [[ "$visibility" == "org" ]]; then
				printf 'lesson-promotion'
			else
				printf 'lesson-promotion-public'
			fi
			;;
		*) return 1 ;;
	esac
	return 0
}
```

Then in `librarian-lesson-judge.sh` at the `rubric_id` call (`:240`), read the asserter from the proposal and pass it. The proposal path is already resolved in that function as `$path`:

```bash
	local asserted_by
	asserted_by=$(jq -r '.asserted_by // "human"' "$path" 2>/dev/null)
	[[ -z "$asserted_by" || "$asserted_by" == "null" ]] && asserted_by="human"

	local rubric_id
	rubric_id=$(librarian_lesson_rubric_id_for_visibility "$visibility" "$asserted_by") || {
```

- [ ] **Step 5: Add the auto rubric to config**

Append to `librarian.lesson_judging.rubrics` in `plugins/librarian/config.json`. Criteria and weights are identical to `lesson-promotion-public`; only the floors and `score_threshold` differ:

```json
{
  "id": "lesson-promotion-public-auto",
  "criteria": [
    { "name": "grounding", "weight": 0.32, "min_pass": 0.8 },
    { "name": "scope_accuracy", "weight": 0.24, "min_pass": 0.8 },
    { "name": "generality", "weight": 0.14, "min_pass": 0.7 },
    { "name": "disclosure", "weight": 0.3, "min_pass": 0.95 }
  ],
  "score_threshold": 0.85,
  "judge_types": ["standard", "adversarial"],
  "gate_policy": "majority"
}
```

`judge_types` must match the panel's `judge_type` multiset exactly or `librarian_lesson_judge` returns UNJUDGED — it compares `[.[].judge_type] | sort` against the rubric's sorted list.

- [ ] **Step 6: Run the tests, then the suite, then commit**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats`
Expected: all seven PASS.

Run: `npm run test:ci`
Expected: PASS.

Then `/git-workflow:commit`: a `feat(librarian)` change recording the asserter and selecting a stricter rubric for a model assertion, body explaining why org gets the public-auto rubric and citing the test that proves the bar is really higher. `Refs ONL-111`.

---

### Task 5: Auto-confirm — the model writes the justification

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-lesson-auto.sh`
- Modify: `plugins/librarian/scripts/lib/librarian-classify-worker.sh` (after the stage-5 loop), `plugins/librarian/config.json` (`lesson_auto` block)
- Test: `test/bats/librarian-lesson-auto.bats`

**Interfaces:**
- Consumes: Task 4's `librarian_lesson_confirm <key> <id> <visibility> [justification] [asserted_by]`.
- Produces: `librarian_lesson_auto_justify <candidate_json> [model]` printing a one-line justification or nothing; `librarian_lesson_auto_confirm_one <key> <lesson_id>` printing `confirmed:<id>`, `skipped:no_justification`, or `unavailable`. Task 6 consumes `auto_confirm_one`'s result strings.

- [ ] **Step 1: Write the failing tests**

The `claude` stub pattern is `_transform_setup`'s in `test/bats/librarian-lesson-transform.bats:307`: a script on `PATH` that branches on marker text in the prompt.

```bash
_auto_stub() {
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
if [[ "$prompt" == *"refuse-justification"* ]]; then
  printf '%s' 'REFUSE'
elif [[ "$prompt" == *"why this lesson holds regardless of version"* ]]; then
  printf '%s' 'The failure is a property of the exec boundary, not of any release.'
else
  printf '%s' ''
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

@test "auto_justify returns a one-line justification" {
	_auto_setup; _auto_stub
	run librarian_lesson_auto_justify "$(_candidate "$(_unscoped)")"
	[ "$status" -eq 0 ]
	[[ "$output" == *"exec boundary"* ]]
	[ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -le 1 ]
}

@test "auto_confirm_one confirms a parked candidate as model-asserted" {
	_auto_setup; _auto_stub
	id=$(_seed_pending_unscoped)
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	[ "$output" = "confirmed:${id}" ]
	jq -e '.status == "confirmed" and .asserted_by == "model"
	   and .candidate.applies_to.scope.kind == "version_independent"' \
		"${LESSONS_DIR}/proposals/${id}.json"
}

@test "a refusal leaves the candidate pending for a human and writes no decline" {
	_auto_setup; _auto_stub
	id=$(_seed_pending_unscoped_marked "refuse-justification")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:no_justification" ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
	[ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "an empty model response is infrastructure, not a verdict" {
	_auto_setup; _auto_stub
	rm -f "${STUB_BIN}/claude"
	id=$(_seed_pending_unscoped)
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
}

@test "auto_confirm_one refuses a candidate that is not parked" {
	_auto_setup; _auto_stub
	id=$(_seed_pending)   # versioned scope, needs no justification
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:not_parked" ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
}
```

`_seed_pending_unscoped_marked <marker>` is `_seed_pending_unscoped` with the marker text spliced into the candidate's `claim`, so the stub can select on it.

- [ ] **Step 2: Run and confirm failure**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats`
Expected: the five new tests FAIL with 127 — the functions do not exist.

- [ ] **Step 3: Write the justification caller**

Create `plugins/librarian/scripts/lib/librarian-lesson-auto.sh`. It mirrors `librarian_lesson_call`'s shape in `librarian-lesson-transform.sh` (mktemp prompt file, `-p --max-turns 1`, `timeout`/`gtimeout` fallback, empty response means infrastructure).

```bash
#!/usr/bin/env bash
# Unattended lesson promotion: the model supplies the version-independence
# justification, and the jury runs with nobody present.
#
# Everything here makes LLM calls, so it runs ONLY from the detached classify
# worker — never on the SessionEnd path (ADR-003).
#
# The trust boundary is unchanged from the attended path. The transform still
# emits scope {kind: unscoped}; this file calls the same
# librarian_lesson_confirm a human's walk calls, and records asserted_by so the
# assertion is judged harder (librarian_lesson_rubric_id_for_visibility) and
# held longer (librarian_lesson_promote).

# Ask for one sentence saying why the claim holds regardless of version, or a
# refusal. A refusal is a real answer and leaves the candidate for a human.
#
# The two prohibitions in the prompt are the defects ONL-110 records, which are
# exactly what the adversarial judge attacks: asserting one remedy is required
# when others exist, and claiming anything the cited evidence does not show.
#
# Usage: librarian_lesson_auto_justify <candidate_json> [model]
librarian_lesson_auto_justify() {
	local candidate="$1"
	local model="${2:-}"
	[[ -z "$candidate" ]] && return 0
	command -v claude >/dev/null 2>&1 || return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-auto.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-auto.$$"
	# shellcheck disable=SC2064
	trap "rm -f '$prompt_file'" EXIT

	{
		printf '%s\n' 'You are deciding whether a lesson holds regardless of version.'
		printf '%s\n\n' 'Output ONE sentence, or exactly REFUSE. No markdown, no preamble.'
		printf '%s\n' 'Say REFUSE unless the claim is true independent of any version of any'
		printf '%s\n\n' 'tool named in its stack.'
		printf '%s\n' 'Two things make a justification wrong, and both are refusals:'
		printf '%s\n' '- asserting one remedy is required when other standard remedies exist'
		printf '%s\n\n' '- claiming anything the cited evidence does not actually show'
		printf '%s\n' 'Write why this lesson holds regardless of version:'
		printf '%s\n' '<candidate>'
		printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nrationale: \(.rationale)\nresolution: \(.evidence.resolution)\nstack: \(.applies_to.stack | join(", "))"' 2>/dev/null
		printf '%s\n' '</candidate>'
	} > "$prompt_file" || { rm -f "$prompt_file"; trap - EXIT; return 0; }

	local args=(-p --max-turns 1)
	[[ -n "$model" ]] && args+=(--model "$model")

	local timeout_seconds response=""
	timeout_seconds=$(librarian_config_get '.librarian.lesson_transform.timeout_seconds' 2>/dev/null)
	case "$timeout_seconds" in ''|null) timeout_seconds=120 ;; esac

	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$timeout_seconds" claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$timeout_seconds" claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi

	rm -f "$prompt_file"
	trap - EXIT

	# Collapse to one line and trim: a justification is a single sentence, and
	# a stray newline would corrupt the envelope's shape.
	printf '%s' "$response" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}
```

- [ ] **Step 4: Write the auto-confirm step**

Append to the same file:

```bash
# Auto-confirm one parked candidate. Prints exactly one of:
#   confirmed:<id>             model asserted a scope; now awaiting a jury
#   skipped:not_parked         scope is not unscoped; nothing to assert
#   skipped:no_justification   the model refused; left pending for a human
#   unavailable                infrastructure; nothing written
#
# Usage: librarian_lesson_auto_confirm_one <key> <lesson_id>
librarian_lesson_auto_confirm_one() {
	local key="$1"
	local lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && { printf 'unavailable'; return 0; }

	local path candidate
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'unavailable'; return 0; }
	candidate=$(jq -c '.candidate' "$path" 2>/dev/null) || { printf 'unavailable'; return 0; }

	if ! printf '%s' "$candidate" | jq -e '.applies_to.scope.kind == "unscoped"' >/dev/null 2>&1; then
		printf 'skipped:not_parked'
		return 0
	fi

	local model justification
	model=$(librarian_config_get '.librarian.lesson_transform.model' 2>/dev/null)
	justification=$(librarian_lesson_auto_justify "$candidate" "$model")

	# Empty is infrastructure, not a verdict — the same distinction
	# librarian_lesson_transform_one draws. Leave the artifact untouched.
	[[ -z "$justification" ]] && { printf 'unavailable'; return 0; }
	if [[ "$justification" == REFUSE* ]]; then
		printf 'skipped:no_justification'
		return 0
	fi

	local visibility
	visibility=$(librarian_config_get '.librarian.lesson_auto.visibility' 2>/dev/null)
	case "$visibility" in ''|null) visibility="org" ;; esac

	librarian_lesson_confirm "$key" "$lesson_id" "$visibility" "$justification" model \
		>/dev/null 2>&1 || { printf 'unavailable'; return 0; }
	printf 'confirmed:%s' "$lesson_id"
}
```

- [ ] **Step 5: Add the config block**

In `plugins/librarian/config.json`, under `librarian`:

```json
"lesson_auto": {
  "enabled": false,
  "visibility": "org",
  "veto_window_hours": 72,
  "max_juries_per_scan": 1,
  "judge_model": "claude-haiku-4-5-20251001"
}
```

- [ ] **Step 6: Run the tests, the suite, and commit**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats`
Expected: all twelve PASS.

Run: `npm run test:ci`
Expected: PASS. `shellcheck -S error` covers the new lib.

Then `/git-workflow:commit`: a `feat(librarian)` change adding auto-confirm, body explaining that it calls the same confirm a human's walk calls — so no validator changes — and that the prompt forbids the two defects ONL-110 records. `Refs ONL-111`.

---

### Task 6: Auto-jury — dispatch the named judges from bash

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-auto.sh`, `plugins/librarian/scripts/lib/librarian-classify-worker.sh` (stages 6 and 7)
- Test: `test/bats/librarian-lesson-auto.bats`

**Interfaces:**
- Consumes: Task 5's `librarian_lesson_auto_confirm_one`; Task 4's rubric selection; the existing `librarian_lesson_judge <key> <id> <verdicts_json>`.
- Produces: `librarian_lesson_auto_judge_one <key> <lesson_id>` printing `judged:<id>`, `skipped:unjudged`, or `unavailable`; worker stages 6 and 7.

- [ ] **Step 1: Write the failing tests**

Extend the stub to answer as each judge. `--agent` is how the judge is selected, and the stub sees it in its own argv, not in the prompt — so it must branch on `"$@"`:

```bash
_jury_stub() {
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
agent=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--agent" ]]; then j=$((i + 1)); agent="${!j}"; fi
done
prompt=$(cat)
pass='{"score":0.93,"passed":true,"judge_type":"TYPE","feedback_summary":"ok","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.85,"disclosure":0.97}}'
fail='{"score":0.6,"passed":false,"judge_type":"TYPE","feedback_summary":"no","criterion_scores":{"grounding":0.5,"scope_accuracy":0.4,"generality":0.5,"disclosure":0.97}}'
case "$agent" in
  tribunal-judge-standard)    printf '%s' "${pass//TYPE/standard}" ;;
  tribunal-judge-adversarial)
    if [[ "$prompt" == *"adversary-fails"* ]]; then printf '%s' "${fail//TYPE/adversarial}"
    else printf '%s' "${pass//TYPE/adversarial}"; fi ;;
  *) printf '%s' 'The failure is a property of the exec boundary, not of any release.' ;;
esac
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

@test "auto_judge_one promotes a candidate both judges pass" {
	_auto_setup; _jury_stub
	id=$(_seed_pending_unscoped)
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	run librarian_lesson_auto_judge_one "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	[ "$output" = "judged:${id}" ]
	jq -e '.status == "approved"' "${LESSONS_DIR}/proposals/${id}.json"
	# Model-asserted, so it is held rather than shipped (Task 1).
	[ -f "${LESSONS_DIR}/approved_held/${id}.json" ]
	[ ! -f "${LESSONS_DIR}/approved/${id}.json" ]
}

@test "auto_judge_one records a rejection when the adversary fails it" {
	_auto_setup; _jury_stub
	id=$(_seed_pending_unscoped_marked "adversary-fails")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	run librarian_lesson_auto_judge_one "$PROJECT_KEY" "$id"
	[ "$output" = "judged:${id}" ]
	jq -e '.status == "rejected"' "${LESSONS_DIR}/proposals/${id}.json"
	[ ! -f "${LESSONS_DIR}/approved_held/${id}.json" ]
}

@test "a judge returning nothing leaves the candidate confirmed for a retry" {
	_auto_setup; _jury_stub
	id=$(_seed_pending_unscoped)
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	rm -f "${STUB_BIN}/claude"
	run librarian_lesson_auto_judge_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ]
	jq -e '.status == "confirmed"' "${LESSONS_DIR}/proposals/${id}.json"
	[ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "the worker runs no auto stage when lesson_auto is disabled" {
	_auto_setup; _jury_stub
	mkdir -p "${PROJECT_REPO}/.claude"
	printf '%s\n' '{"librarian":{"lesson_auto":{"enabled":false}}}' \
		> "${PROJECT_REPO}/.claude/settings.json"
	librarian_config_load "$PROJECT_REPO"
	id=$(_seed_pending_unscoped)
	run librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
}

@test "the jury cap stops after N candidates and declines nothing" {
	_auto_setup; _jury_stub
	mkdir -p "${PROJECT_REPO}/.claude"
	printf '%s\n' '{"librarian":{"lesson_auto":{"enabled":true,"max_juries_per_scan":1}}}' \
		> "${PROJECT_REPO}/.claude/settings.json"
	librarian_config_load "$PROJECT_REPO"
	a=$(_seed_pending_unscoped); b=$(_seed_pending_unscoped_other)
	run librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	judged=$(grep -c . <<< "$(jq -r 'select(.status != "pending") | .id' \
		"${LESSONS_DIR}/proposals/"*.json)")
	[ "$judged" -le 2 ]
	# Exactly one reached a jury; the other stays confirmed, never declined.
	[ "$(jq -r -s '[.[] | select(.status == "confirmed")] | length' \
		"${LESSONS_DIR}/proposals/"*.json)" -ge 1 ]
}
```

`_seed_pending_unscoped_other` is `_seed_pending_unscoped` with a different artifact id, so two proposals coexist.

- [ ] **Step 2: Run and confirm failure**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats`
Expected: the five new tests FAIL with 127.

- [ ] **Step 3: Dispatch the jury**

Append to `librarian-lesson-auto.sh`:

```bash
# Dispatch one judge by NAME and print its raw verdict JSON.
#
# `claude -p --agent <name>` resolves a plugin-provided agent, which is what
# lets an unattended jury reuse tribunal's published definitions instead of
# inlining copies of their prompts. ADR-002 forbids sourcing anything under
# plugins/tribunal/ — dispatching by name is explicitly allowed, and this is
# the bash equivalent of the Task-tool dispatch the skill walk performs.
#
# Usage: _librarian_lesson_auto_judge <agent_name> <prompt> [model]
_librarian_lesson_auto_judge() {
	local agent="$1" prompt="$2" model="${3:-}"
	command -v claude >/dev/null 2>&1 || return 0

	local args=(-p --max-turns 1 --agent "$agent")
	[[ -n "$model" ]] && args+=(--model "$model")

	local timeout_seconds response=""
	timeout_seconds=$(librarian_config_get '.librarian.lesson_transform.timeout_seconds' 2>/dev/null)
	case "$timeout_seconds" in ''|null) timeout_seconds=120 ;; esac

	if command -v timeout >/dev/null 2>&1; then
		response=$(printf '%s' "$prompt" | timeout "$timeout_seconds" claude "${args[@]}" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(printf '%s' "$prompt" | gtimeout "$timeout_seconds" claude "${args[@]}" 2>/dev/null) || response=""
	else
		response=$(printf '%s' "$prompt" | claude "${args[@]}" 2>/dev/null) || response=""
	fi

	# Reuse the transform's prose-tolerant extractor: a judge that wrapped its
	# JSON in a sentence is a formatting slip, not a refusal.
	_librarian_lesson_extract_json_object "$response" 2>/dev/null
}

# Judge one confirmed candidate with both judges and record the verdict.
# Prints judged:<id>, skipped:unjudged, or unavailable.
#
# Usage: librarian_lesson_auto_judge_one <key> <lesson_id>
librarian_lesson_auto_judge_one() {
	local key="$1" lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && { printf 'unavailable'; return 0; }

	local path candidate visibility rubric_id rubric
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'unavailable'; return 0; }
	candidate=$(jq -c '.candidate' "$path" 2>/dev/null) || { printf 'unavailable'; return 0; }
	visibility=$(jq -r '.visibility // ""' "$path" 2>/dev/null)
	rubric_id=$(librarian_lesson_rubric_id_for_visibility "$visibility" model) || { printf 'unavailable'; return 0; }
	[[ -z "$rubric_id" ]] && { printf 'unavailable'; return 0; }
	rubric=$(librarian_lesson_rubric_get "$rubric_id") || { printf 'unavailable'; return 0; }

	# Every floored criterion must be scored by SOME judge or the panel is
	# UNJUDGED, so the prompt names them all and says why omitting one is worse
	# than scoring it badly.
	local criteria prompt model
	criteria=$(printf '%s' "$rubric" | jq -r \
		'[.criteria[] | "- \(.name) (weight \(.weight), min_pass \(.min_pass))"] | join("\n")')
	model=$(librarian_config_get '.librarian.lesson_auto.judge_model' 2>/dev/null)
	case "$model" in ''|null) model="claude-haiku-4-5-20251001" ;; esac

	prompt=$(printf '%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n' \
		'Score this lesson candidate for promotion to the shared lesson pool.' \
		'A MODEL asserted that this lesson holds regardless of version; judge that assertion.' \
		'CANDIDATE' \
		"$(printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nrationale: \(.rationale)\nresolution: \(.evidence.resolution)\napplies_to: \(.applies_to | tojson)"')" \
		'RUBRIC — you MUST return a score in [0,1] for EVERY criterion listed. Omitting one makes the whole panel UNJUDGED and the candidate is re-judged at full cost, so an omission prevents a verdict rather than softening it. If you cannot assess one, say so and score your honest worst case.' \
		"$criteria" \
		'Return EXACTLY one JSON object as your final message, no prose around it:' \
		'{"score": <0..1>, "passed": <true|false>, "judge_type": "standard|adversarial", "feedback_summary": "<why>", "criterion_scores": {<each criterion>: <0..1>}}')

	local std adv verdicts
	std=$(_librarian_lesson_auto_judge tribunal-judge-standard "$prompt" "$model")
	adv=$(_librarian_lesson_auto_judge tribunal-judge-adversarial "$prompt" "$model")
	[[ -z "$std" || -z "$adv" ]] && { printf 'unavailable'; return 0; }

	verdicts=$(jq -cn --argjson a "$std" --argjson b "$adv" '[$a, $b]' 2>/dev/null) \
		|| { printf 'unavailable'; return 0; }

	librarian_lesson_judge "$key" "$lesson_id" "$verdicts" >/dev/null 2>&1
	local rc=$?
	case "$rc" in
		0) librarian_lesson_promote "$key" "$lesson_id" >/dev/null 2>&1 || true
		   printf 'judged:%s' "$lesson_id" ;;
		2) printf 'skipped:unjudged' ;;
		*) printf 'unavailable' ;;
	esac
}
```

`_librarian_lesson_extract_json_object` lives in `librarian-lesson-transform.sh`, so the worker must source that before this lib. Confirm the ordering when wiring Step 4 rather than assuming it.

- [ ] **Step 4: Wire the stage into the worker**

Append the stage driver to `librarian-lesson-auto.sh`, so it is testable without running the whole worker:

```bash
# Auto-confirm every parked candidate, then jury as many as the cap allows.
# A no-op unless lesson_auto.enabled is true.
#
# Usage: librarian_lesson_auto_stage <key>
librarian_lesson_auto_stage() {
	local key="$1"
	[[ -z "$key" ]] && return 0

	local enabled
	enabled=$(librarian_config_get '.librarian.lesson_auto.enabled' 2>/dev/null)
	[[ "$enabled" != "true" ]] && return 0

	local cap
	cap=$(librarian_config_get '.librarian.lesson_auto.max_juries_per_scan' 2>/dev/null)
	case "$cap" in ''|null) cap=1 ;; esac

	local id
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		librarian_lesson_auto_confirm_one "$key" "$id" >/dev/null
	done < <(librarian_lesson_list_pending "$key" | jq -r '.[].id' 2>/dev/null)

	# The jury is the expensive step, so it is capped. An over-cap candidate
	# stays `confirmed` and is judged on the next scan — never declined, since
	# a decline is terminal.
	local juried=0
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		[[ "$juried" -ge "$cap" ]] && break
		librarian_lesson_auto_judge_one "$key" "$id" >/dev/null
		juried=$((juried + 1))
	done < <(librarian_lesson_list_by_status "$key" confirmed | jq -r '.[].id' 2>/dev/null)

	return 0
}
```

Then in `librarian-classify-worker.sh`, after the stage-5 loop and **before** the watermark advance and `scan.complete`, source the new lib beside the others and call it:

```bash
librarian_lesson_auto_stage "$PROJECT_KEY" || true
```

Verify `librarian-lesson-review.sh`, `librarian-lesson-rubric.sh`, `librarian-lesson-judge.sh` and `librarian-lesson-promote.sh` are sourced in the worker — stage 5 needs none of them today, so some will be new sources. Add whichever are missing.

- [ ] **Step 5: Run the tests**

Run: `scripts/test/run-bats.sh test/bats/librarian-lesson-auto.bats`
Expected: all seventeen PASS.

- [ ] **Step 6: Full suite**

Run: `npm run test:ci`
Expected: PASS. If `check-bus-coverage` complains, no new event types were added by this plan — investigate a clobbered report (two concurrent bats runs) before suspecting coverage.

- [ ] **Step 7: Commit**

`/git-workflow:commit`: a `feat(librarian)` change adding the unattended jury, body explaining that `claude -p --agent` reuses tribunal's published definitions so ADR-002 holds, that the cap never writes a decline, and that a missing verdict leaves the candidate confirmed for a retry rather than rejecting it. `Refs ONL-111`.

---

## After the plan

- [ ] **Verify end to end on this machine, with the flag on**

There are 463 eligible artifacts in this project. Enable the feature in the repo's own `.claude/settings.json`, park a fresh batch through the transform, and let the auto stage run:

```bash
# in the repo's .claude/settings.json
{"librarian": {"lesson_auto": {"enabled": true, "visibility": "org", "veto_window_hours": 1}}}
```

Then confirm, in order: a parked candidate becomes `confirmed` with `asserted_by: "model"`; a jury runs unattended; the outcome lands in `approved_held/` or the declined ledger; `librarian_cli lessons queue` shows it; and after the window a SessionStart sweep moves it to `approved/` where `onlooker sync` can see it.

**Expect rejections.** ONL-110 records that transform claims fail adversarial review 2 for 2, and the model floors here are strictly higher than the ones those two failed. A run where nothing clears the bar is the predicted outcome, not a bug in this work — the thing to verify is that the *mechanism* runs unattended, not that a lesson lands.

- [ ] **Close out**

`bd close ecosystem-kjy618` once the mechanism is verified, then open the PR with `/git-workflow:pr`. Note in the PR that ONL-13's premise is contested and its description is unedited.
