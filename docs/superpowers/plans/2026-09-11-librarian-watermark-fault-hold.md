# Librarian Watermark Fault Hold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop librarian advancing its scan watermark past artifacts it could not judge because the durability markers were unavailable, so those artifacts are reconsidered on a later scan instead of being lost.

**Architecture:** One flag computed once after the durability filter and consulted at every watermark write below it. A configured ceiling bounds how large the held backlog may grow; past it the scan advances and reports each abandoned artifact with a distinct drop reason rather than dropping them silently.

**Tech Stack:** Bash 3.2 (macOS default), `jq`, BATS 1.5+, `@onlooker-community/schema` (JSON Schema + hand-written TypeScript types, vitest).

## Global Constraints

- **Two repositories, ordered.** `onlooker-community/schema` ships the enum value and must be released to npm before the ecosystem repo can use it. Ecosystem worktree: `/Users/meaganwaller/src/github.com/onlooker-community/ecosystem-449.55` on branch `fix/hold-watermark-through-marker-fault`. Schema worktree: `/Users/meaganwaller/src/github.com/onlooker-community/schema-449.55` on branch `feat/librarian-retry-cap-reason`.
- **Bash 3.2.** No associative arrays, no `mapfile`, no `${var^^}`. Target macOS's system bash.
- **Edit tracked files with Edit/Write, never `sed -i` or heredocs.** The `lineage` and `inspector` plugins hook `PostToolUse` on `Edit`/`Write`/`MultiEdit`; a shell edit moves the same bytes with no provenance record.
- **Commits go through the `/commit` skill.** Conventional commits, American English, mood emoji reflecting the change rather than the type.
- **New drop reason string:** `retry_cap_exceeded` — exact spelling, used identically in both repos.
- **New config key:** `.librarian.scan.max_fault_retry_artifacts`, default `500`.
- **Fault reason keyed on:** `filter_markers_unavailable` — never `filter_marker_missing`, which is an ordinary verdict.
- **Ecosystem test command:** `ONLOOKER_VALIDATE=1 ONLOOKER_TEST_REPORT_DIR="$PWD/test/tmp-emission-report" bats test/bats/<file>`
- **Shellcheck** is not on `PATH`; invoke it as `$(mise which shellcheck)`.

---

### Task 1: Widen the reason-reconciliation test to cover the hook

The guard added in `#314` scans only `librarian-durability.sh`. The hook emits three more drop reasons today (`classified_null`, `duplicate`, `low_confidence`) that it never checks, and the new reason in Task 4 is assigned in the hook too. This must land first so the later tasks are actually protected.

**Files:**
- Modify: `test/bats/librarian-durability.bats` (the `every drop reason the filter can produce survives the emitter` test)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a test that fails whenever any `librarian.candidate.dropped` reason literal in `plugins/librarian/scripts/lib/librarian-durability.sh` or `plugins/librarian/scripts/hooks/librarian-session-end.sh` is missing from the installed schema enum.

- [ ] **Step 1: Confirm the current test's blind spot**

Run from the ecosystem worktree:

```bash
grep -oE '\-\-arg reason "[a-z_]+"' plugins/librarian/scripts/hooks/librarian-session-end.sh \
  | sed 's/.*"\(.*\)"/\1/' | sort -u
```

Expected output — three reasons the current test never checks:

```
classified_null
duplicate
low_confidence
```

- [ ] **Step 2: Rename the test and widen its source set**

Replace the test's name line and its `reasons=` assignment. The name changes because it no longer describes only the filter:

```bash
@test "every drop reason either source can emit survives the emitter" {
```

Replace the `reasons=$(...)` command substitution with:

```bash
	local reasons
	reasons=$( {
		grep -oE 'kept: false, reason: "[a-z_]+"' \
			"${PLUGIN_ROOT}/scripts/lib/librarian-durability.sh"
		grep -oE -- '--arg reason "[a-z_]+"' \
			"${PLUGIN_ROOT}/scripts/hooks/librarian-session-end.sh"
	} | sed 's/.*"\(.*\)"/\1/' | sort -u )
	[ -n "$reasons" ]
```

Note the `--` before `--arg`: without it `grep` parses the pattern as options and fails.

- [ ] **Step 3: Run the test and verify it still passes**

```bash
ONLOOKER_VALIDATE=1 ONLOOKER_TEST_REPORT_DIR="$PWD/test/tmp-emission-report" \
  bats test/bats/librarian-durability.bats
```

Expected: all tests pass. All seven reasons are already in schema 2.18.1, so widening finds no new violation — it only removes the blind spot.

- [ ] **Step 4: Prove the widened test has teeth**

Temporarily add a bogus reason to the hook to confirm the test now sees hook literals. Edit `plugins/librarian/scripts/hooks/librarian-session-end.sh` line 241, changing `--arg reason "classified_null"` to `--arg reason "definitely_not_in_the_enum"`, then run the test.

Expected: FAIL, naming `definitely_not_in_the_enum`.

Then revert that edit with `git checkout -- plugins/librarian/scripts/hooks/librarian-session-end.sh` and re-run to confirm it passes again. Do not commit the bogus value.

- [ ] **Step 5: Commit**

Use the `/commit` skill with this context: widened the drop-reason reconciliation guard to cover the hook as well as the filter, closing a blind spot over three live reasons and making the Task 4 literal enforceable.

Files to stage: `test/bats/librarian-durability.bats`

---

### Task 2: Add `retry_cap_exceeded` to the schema enum

**Files:**
- Modify: `schemas/payload/plugins-memory.json` (the `librarian.candidate.dropped` reason enum)
- Modify: `src/types.ts` (`LibrarianCandidateDroppedPayload.reason`)
- Modify: `src/validate.test.ts` (the existing `it.each` case list for drop reasons)

Work in the schema worktree: `/Users/meaganwaller/src/github.com/onlooker-community/schema-449.55`.

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `"retry_cap_exceeded"` as a valid `librarian.candidate.dropped` reason, published to npm so Task 3 can bump to it.

- [ ] **Step 1: Add the failing test case**

In `src/validate.test.ts`, find the existing parameterized test that reads:

```ts
	it.each([
		"filter_drop_pattern",
		"filter_markers_unavailable",
	])("accepts the %s drop reason the filter can emit", (reason) => {
```

Add the new reason to the list:

```ts
	it.each([
		"filter_drop_pattern",
		"filter_markers_unavailable",
		"retry_cap_exceeded",
	])("accepts the %s drop reason the filter can emit", (reason) => {
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
npm test -- src/validate.test.ts -t "drop reason"
```

Expected: FAIL for `retry_cap_exceeded` with `expected true, received false` — the validator rejects a reason absent from the enum. The other two cases pass.

- [ ] **Step 3: Add the value to the JSON Schema**

In `schemas/payload/plugins-memory.json`, in the `librarian.candidate.dropped` reason enum, add `"retry_cap_exceeded"` after `"detail_too_short"`:

```json
					"enum": [
						"duplicate",
						"low_confidence",
						"classified_null",
						"filter_marker_missing",
						"filter_markers_unavailable",
						"filter_repetition_missing",
						"filter_drop_pattern",
						"detail_too_short",
						"retry_cap_exceeded"
					]
```

- [ ] **Step 4: Add the value to the hand-written types**

`src/types.ts` is hand-written and only cross-checked by `generate-types`, so it must be updated in lockstep. In `LibrarianCandidateDroppedPayload`, add the member after `"detail_too_short"`:

```ts
		| "detail_too_short"
		/** The fault backlog outgrew the retry ceiling and was abandoned. */
		| "retry_cap_exceeded";
```

Make sure the semicolon moves from `"detail_too_short"` to the new final member.

- [ ] **Step 5: Run the test to verify it passes**

```bash
npm test -- src/validate.test.ts -t "drop reason"
```

Expected: PASS, 3 tests.

- [ ] **Step 6: Run the full gates**

```bash
npm test && npm run typecheck && npm run validate-schemas && npm run build && npm run ci
```

Expected: all exit 0. `npm run ci` runs biome and must report no errors — if it reports a format difference, run `npm run format:fix` and re-run.

- [ ] **Step 7: Commit**

Use the `/commit` skill with this context: added `retry_cap_exceeded` so librarian can say an artifact was abandoned because the fault backlog outgrew its retry ceiling, which is a different fact from any existing drop reason.

Files to stage: `schemas/payload/plugins-memory.json`, `src/types.ts`, `src/validate.test.ts`

- [ ] **Step 8: Open the PR and stop**

Use the `git-workflow:pr` skill. **This task ends here.** Task 3 cannot start until this PR merges, release-please publishes the new version, and it appears on npm. Verify with:

```bash
npm view @onlooker-community/schema version
```

Do not proceed while that still prints `2.18.1`.

---

### Task 3: Bump the ecosystem to the released schema

**Files:**
- Modify: `package.json` (`@onlooker-community/schema` range)
- Modify: `package-lock.json`

Back in the ecosystem worktree.

**Interfaces:**
- Consumes: the schema version published by Task 2.
- Produces: an installed schema whose enum contains `retry_cap_exceeded`, so Task 4's literal validates.

- [ ] **Step 1: Bump the dependency**

Substitute the actual published version for `<VERSION>`:

```bash
npm install @onlooker-community/schema@^<VERSION> --package-lock-only
npm ci
```

- [ ] **Step 2: Verify the new reason now validates**

```bash
node -e '
const s = require("@onlooker-community/schema");
const e = {id:"00000000-0000-4000-8000-000000000000",schema_version:"1.0",runtime:"claude-code",
  plugin:"librarian",machine_id:"00000000-0000-4000-8000-000000000000",
  timestamp:new Date().toISOString(),session_id:"s1",sequence:0,
  event_type:"librarian.candidate.dropped",payload:{reason:"retry_cap_exceeded"},redacted:false};
console.log(JSON.stringify(s.validate(e).valid));'
```

Expected: `true`. If `false`, the wrong version installed — check `jq -r .version node_modules/@onlooker-community/schema/package.json`.

- [ ] **Step 3: Run the reconciliation test**

```bash
ONLOOKER_VALIDATE=1 ONLOOKER_TEST_REPORT_DIR="$PWD/test/tmp-emission-report" \
  bats test/bats/librarian-durability.bats
```

Expected: all pass (still 6 tests — the new reason is not emitted by any source yet).

- [ ] **Step 4: Commit**

Use the `/commit` skill with this context: bumped the schema so `retry_cap_exceeded` is available to the watermark hold.

Files to stage: `package.json`, `package-lock.json`

---

### Task 4: Hold the watermark through a marker fault

**Files:**
- Modify: `plugins/librarian/config.json` (add `max_fault_retry_artifacts` to `.librarian.scan`)
- Modify: `plugins/librarian/scripts/hooks/librarian-session-end.sh` (lines 165-186, 197, 499)
- Test: `test/bats/librarian-watermark-hold.bats` (create)

**Interfaces:**
- Consumes: `retry_cap_exceeded` validating (Task 3); `librarian_durability_filter` returning `{kept, dropped[]}` where each drop is `{artifact_id, reason}`.
- Produces: shell variables `FAULT_DROPS` (integer) and `SHOULD_ADVANCE` (`0` or `1`) in the hook, consulted at both watermark writes below the filter.

- [ ] **Step 1: Write the failing test**

Create `test/bats/librarian-watermark-hold.bats`. This drives the real hook end to end, so copy the entire `setup()` function from `test/bats/librarian-session-end.bats` (lines 14-78) verbatim along with the `_seed_artifact`, `_hook_input` and `_settings` helpers. The hook needs the full fake environment those build; a partial copy will fail in ways that look like product bugs.

The helper signatures, so the calls below are not guesswork:

- `_seed_artifact <kind> <id> <summary> <detail> [created_at]` — four required arguments. `created_at` defaults to `$FIXTURE_CREATED_AT`, one day ago.
- `_settings` — reads JSON on **stdin** and writes it to `${PROJECT_REPO}/.claude/settings.json`. `setup()` already creates that directory.
- `$HOOK` — the session-end hook path. `$LIBRARIAN_DIR` — where `last_scan.json` lives. `$ONLOOKER_EVENTS_LOG` — the event log.

The first test asserts the core behavior:

```bash
@test "a scan whose markers were unavailable does not advance the watermark" {
	# Markers empty => every artifact past the length gate is dropped as a
	# configuration fault, not judged. Advancing here is what put 3,837
	# artifacts permanently behind the watermark (ecosystem-449.55).
	echo '{"librarian":{"durability_filter":{"marker_phrases":[]}}}' | _settings
	_seed_artifact "decisions" "01FAULTHOLD00000000000001" \
		"We chose the queue" \
		"We chose the queue because the old path dropped events on every restart."

	local before
	before=$(cat "${LIBRARIAN_DIR}/last_scan.json" 2>/dev/null || echo "absent")

	run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
	[ "$status" -eq 0 ]

	local after
	after=$(cat "${LIBRARIAN_DIR}/last_scan.json" 2>/dev/null || echo "absent")
	[ "$after" = "$before" ]
}
```

Seeding an artifact matters: with none, the hook bails at line 144 — which writes the watermark on a path this change deliberately leaves alone — and the test would pass without exercising the hold at all. The `[ "$status" -eq 0 ]` assertion is what stops a crashed hook from also looking like a successful hold.

- [ ] **Step 2: Run it to verify it fails**

```bash
ONLOOKER_VALIDATE=1 ONLOOKER_TEST_REPORT_DIR="$PWD/test/tmp-emission-report" \
  bats test/bats/librarian-watermark-hold.bats
```

Expected: FAIL — the watermark advances, so `$after` differs from `$before`.

If it fails for any other reason (missing helper, hook not found), fix the harness until the failure is the assertion itself. A test that errors has not been watched fail.

- [ ] **Step 3: Add the config default**

In `plugins/librarian/config.json`, add the key to the existing `.librarian.scan` object, which currently reads `{"trigger":"SessionEnd","bootstrap_lookback_days":14,"min_detail_chars":40}`:

```json
			"min_detail_chars": 40,
			"max_fault_retry_artifacts": 500
```

- [ ] **Step 4: Compute the flag in the hook**

In `plugins/librarian/scripts/hooks/librarian-session-end.sh`, immediately after the `DROPPED=` assignment (currently line 172), insert:

```bash
# A scan that could not consult its markers has not judged its window, so it
# must not claim to have handled it. Keyed on filter_markers_unavailable and
# never on filter_marker_missing: the latter is an ordinary verdict, and
# holding on it would stall every repo whose artifacts are thin.
FAULT_DROPS=$(printf '%s' "$DROPPED" \
	| jq '[.[] | select(.reason == "filter_markers_unavailable")] | length' 2>/dev/null) \
	|| FAULT_DROPS=0
MAX_FAULT_RETRY=$(librarian_config_get '.librarian.scan.max_fault_retry_artifacts')
[[ -z "$MAX_FAULT_RETRY" || "$MAX_FAULT_RETRY" == "null" ]] && MAX_FAULT_RETRY=500

# Bounded: load_since re-reads every artifact in the window each session, so an
# unbounded hold degrades SessionEnd until the budget bail discards the backlog
# anyway. Past the ceiling we abandon it and say so, per artifact.
SHOULD_ADVANCE=1
RETRY_CAP_HIT=0
if [[ "$FAULT_DROPS" -gt 0 ]]; then
	if [[ "$ARTIFACT_COUNT" -ge "$MAX_FAULT_RETRY" ]]; then
		RETRY_CAP_HIT=1
	else
		SHOULD_ADVANCE=0
	fi
fi
```

- [ ] **Step 5: Relabel abandoned drops**

`retry_cap_exceeded` replaces `filter_markers_unavailable` on those drops rather than adding a second event per artifact. In the drop-emitting loop (currently lines 180-186), change the `librarian_emit` call to pass the substituted reason:

```bash
for ((i = 0; i < DROPPED_EMIT_COUNT; i++)); do
	DROP=$(printf '%s' "$DROPPED" | jq -c ".[$i]")
	librarian_emit "librarian.candidate.dropped" "$SESSION_ID" "$(jq -cn \
		--argjson drop "$DROP" \
		--argjson cap_hit "$RETRY_CAP_HIT" \
		'{ reason: (if $cap_hit == 1 and $drop.reason == "filter_markers_unavailable"
		            then "retry_cap_exceeded" else $drop.reason end),
		   source_artifact_id: $drop.artifact_id }
		 | with_entries(select(.value != null))')"
done
```

- [ ] **Step 6: Guard both watermark writes below the filter**

Two sites. At the budget-exceeded bail (currently line 197) and at the end-of-scan write (currently line 499), replace:

```bash
librarian_storage_write_last_scan "$PROJECT_KEY" || true
```

with:

```bash
[[ "$SHOULD_ADVANCE" == "1" ]] && { librarian_storage_write_last_scan "$PROJECT_KEY" || true; }
```

Leave the write at line 144 alone — it is upstream of the filter, where `SHOULD_ADVANCE` does not exist yet and an empty window has nothing to lose.

Note the `{ ...; }` grouping: a bare `&&` chain ending in a failing command would make the script's last exit status non-zero.

- [ ] **Step 7: Run the test to verify it passes**

```bash
ONLOOKER_VALIDATE=1 ONLOOKER_TEST_REPORT_DIR="$PWD/test/tmp-emission-report" \
  bats test/bats/librarian-watermark-hold.bats
```

Expected: PASS.

- [ ] **Step 8: Add the remaining cases**

Append these four tests to the same file, mirroring the first test's setup:

```bash
@test "an ordinary missed marker still advances the watermark" {
	# The case that keeps this fix from becoming the bug it fixes. A hold on
	# ordinary verdicts would stall the pipeline permanently on any repo whose
	# artifacts are thin. Markers are left at their shipped defaults here, so
	# this artifact is dropped filter_marker_missing - a real verdict.
	_seed_artifact "decisions" "01ORDINARYMISS0000000001" \
		"Ran the suite" \
		"Ran the suite again this morning and everything went green on the first try."

	run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	[ -f "${LIBRARIAN_DIR}/last_scan.json" ]
	jq -e '.scanned_at' "${LIBRARIAN_DIR}/last_scan.json" >/dev/null
}

@test "a short artifact alone never triggers a hold" {
	_seed_artifact "decisions" "01SHORTDETAIL00000000001" "Fixed it" "too short"

	run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	jq -e '.scanned_at' "${LIBRARIAN_DIR}/last_scan.json" >/dev/null
}

@test "past the ceiling the scan advances and reports the abandonment" {
	echo '{"librarian":{"durability_filter":{"marker_phrases":[]},
	       "scan":{"max_fault_retry_artifacts":1}}}' | _settings
	_seed_artifact "decisions" "01RETRYCAP00000000000001" \
		"We chose the queue" \
		"We chose the queue because the old path dropped events on every restart."

	run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
	[ "$status" -eq 0 ]

	jq -e '.scanned_at' "${LIBRARIAN_DIR}/last_scan.json" >/dev/null
	grep '"event_type":"librarian.candidate.dropped"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e 'select(.payload.reason == "retry_cap_exceeded")' >/dev/null
}

@test "the abandonment reason replaces the fault reason rather than joining it" {
	echo '{"librarian":{"durability_filter":{"marker_phrases":[]},
	       "scan":{"max_fault_retry_artifacts":1}}}' | _settings
	_seed_artifact "decisions" "01RETRYCAP00000000000002" \
		"We chose the queue" \
		"We chose the queue because the old path dropped events on every restart."

	run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
	[ "$status" -eq 0 ]

	local n
	n=$(grep -c '"reason":"filter_markers_unavailable"' "$ONLOOKER_EVENTS_LOG" || true)
	[ "$n" -eq 0 ]
}
```

A ceiling of `1` with a single seeded artifact satisfies `ARTIFACT_COUNT >= MAX_FAULT_RETRY`, which is why these two tests trip the cap without seeding hundreds of files.

**One case from the spec is deliberately not tested here, and the gap is real.** The spec's table lists "fault drops on the budget-exceeded exit → watermark unchanged". `BUDGET_THRESHOLD_MS=1000` is a bare literal at line 195, not a config key and not injectable, and the suite's existing `budget_exceeded` test emits that event directly rather than driving the hook down the path. Covering it would need either a timing-dependent test — which would be flaky on a loaded machine, and flaky tests get muted — or an env override on a production constant, which is scope beyond the approved design.

So the `:197` guard ships verified by inspection only. Do not claim otherwise in the PR. If that trade is unacceptable, stop and raise it rather than inventing a timing test: making the threshold injectable is a reasonable follow-up, but it is a separate decision.

- [ ] **Step 9: Run the whole file**

```bash
ONLOOKER_VALIDATE=1 ONLOOKER_TEST_REPORT_DIR="$PWD/test/tmp-emission-report" \
  bats test/bats/librarian-watermark-hold.bats
```

Expected: 5 passing.

- [ ] **Step 10: Run the full suite and every gate**

```bash
rm -rf test/tmp-emission-report
ONLOOKER_VALIDATE=1 ONLOOKER_TEST_REPORT_DIR="$PWD/test/tmp-emission-report" bats test/bats
git ls-files -z '*.sh' '*.bats' | xargs -0 "$(mise which shellcheck)" -S error -x
npm run test:schema && npm run test:bus && npm run lint:check \
  && npm run lint:manifests && npm run lint:references && npm run lint:lesson-schema
```

Expected: 0 failures, every gate exit 0. `librarian-session-end.bats` must still pass — it exercises the normal advance path and is the regression guard for Step 6.

- [ ] **Step 11: Commit**

Use the `/commit` skill with this context: a scan that could not read its markers no longer claims to have handled its window; bounded by a configured ceiling so a permanent misconfiguration cannot grow the window without limit, and the abandonment is reported per artifact rather than happening silently.

Files to stage: `plugins/librarian/config.json`, `plugins/librarian/scripts/hooks/librarian-session-end.sh`, `test/bats/librarian-watermark-hold.bats`

---

### Task 5: Correct the false deferral claim in the schema description

The `budget_exceeded` enum description states "Retained artifacts are reconsidered on a later scan, so it is a deferral rather than a loss." The code advances the watermark at line 197, so they are not. Fixing the behavior is out of scope and separately filed; the description should not keep asserting something untrue.

**Files:**
- Modify: `schemas/payload/plugins-memory.json` (the `librarian.scan.complete` outcome description)

Work in the schema worktree. This can ride along with Task 2's PR if it has not merged yet; otherwise it is its own small PR.

- [ ] **Step 1: Rewrite the description**

Find the `librarian.scan.complete` `outcome` property description and replace the `budget_exceeded` sentence with:

```
budget_exceeded means the scan abandoned classification to stay inside the SessionEnd budget. Retained artifacts are NOT currently reconsidered: the watermark advances on this path, so they fall outside the next scan's window.
```

Leave the `empty` and `skipped` sentences exactly as they are.

- [ ] **Step 2: Run the gates**

```bash
npm test && npm run validate-schemas && npm run ci
```

Expected: all exit 0. No test asserts on description text, so this is documentation-only.

- [ ] **Step 3: Commit**

Use the `/commit` skill with this context: the description promised a deferral the code does not perform; state what actually happens until the behavior is fixed.

Files to stage: `schemas/payload/plugins-memory.json`

---

## Definition of done

- `bats test/bats` passes with zero failures in the ecosystem worktree.
- `npm test` passes in the schema worktree.
- Shellcheck, schema, bus, manifests, references and lesson-schema gates all exit 0.
- A marker-fault scan leaves `last_scan.json` byte-identical; a clean scan advances it.
- A fault scan past the ceiling advances and emits `retry_cap_exceeded`, and emits no `filter_markers_unavailable` for those same artifacts.
- `ecosystem-449.55` updated with the merged PR numbers, and a new bead filed for the budget-exceeded path's independent defect if one does not already exist.

**Known gap, to be stated in the PR rather than papered over:** the `:197` guard has no automated test, for the reason given in Task 4 Step 8. Everything else in the spec's test table is covered.
