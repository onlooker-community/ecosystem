# Echo Pairwise Discrimination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure whether a pairwise judge discriminates between documents more reliably than it discriminates one document from itself, so ONL-103's choice between "sharpen the rubric" and "go pairwise" is decided by evidence rather than preference.

**Architecture:** A new pairwise prompt builder added beside the existing scoring prompt in `echo-judge-prompt.sh`; a pure stats module (`pairwise-stats.mjs`) that turns recorded verdicts into the four metrics and a pass/fail against the kill criterion; and a runner (`measure-pairwise-discrimination.sh`) that spends the judge calls and hands the raw verdicts to the stats module. The split is the same one ONL-102 used: the expensive half is a manual script, the arithmetic half is exhaustively unit-tested without spending a token.

**Tech Stack:** bash (hooks/runners), `node:test` + `node:assert/strict` (arithmetic), bats (plumbing, against a stubbed `claude`), `jq` for all JSON construction.

## Global Constraints

- Nothing in echo's runtime changes. `echo-stop-gate.sh`, `config.json`, and the baseline format are untouched. `drift_threshold` stays `0.28`.
- Corpus is the six files from ONL-102; comparisons are between *different documents*, not synthetic edits.
- Verdict vocabulary is exactly `better` / `worse` / `same`, plus a `confidence` float. These map onto echo's existing `improved` / `degraded` / `neutral`.
- Both presentation orders of every cross pair are evaluated. Single-order measurement is not acceptable — position bias manufactures discrimination that looks real.
- Kill criterion, fixed before any run: `self_tie_rate >= 0.90`, `cross_antisymmetry >= 0.80`, `true_discrimination > false_discrimination`.
- Default `--repeats 2`. At R=2 the run is 72 judge calls (6 self × 2, plus 15 pairs × 2 orders × 2).
- The **runner** is never wired into `npm test` — a suite costing 72 Haiku calls is one nobody runs. Its **bats test** is, and must be: `test:bats` runs `scripts/test/run-bats.sh test/bats` with no exclusions, `echo-measure-judge-spread.bats` is already in that run, and the stub makes it free. Do not exclude the new file.
- Every run stamps the model and a `sha256` of `echo-judge-prompt.sh`. A measurement taken against a different prompt does not transfer.
- The pairwise prompt lives in `echo-judge-prompt.sh`, never copied into the runner. Two copies of a prompt drift apart silently.
- American English in all comments, commits, and docs.
- Shell: `set -uo pipefail` in the runner (matching `measure-judge-spread.sh`, which deliberately omits `-e`).
- Non-final `[[ ]]` and `!` assertions in bats need `|| return 1`. Under macOS bash 3.2 a failing non-final `[[ ]]` does not fail the test body.
- Commits route through `/git-workflow:commit`. Do not hand-write `git commit -m`.

---

### Task 1: The pairwise prompt

**Files:**
- Modify: `plugins/echo/scripts/lib/echo-judge-prompt.sh` (append a second function; leave `echo_build_judge_prompt` byte-identical)
- Test: `test/bats/echo-pairwise-prompt.bats` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `echo_build_pairwise_prompt <rel_path_a> <content_a> <rel_path_b> <content_b>` — writes a prompt to stdout instructing the judge to return `{"verdict": "better"|"worse"|"same", "confidence": 0.0..1.0, "reason": "..."}`, where `better` means **document B is better than document A**.

- [ ] **Step 1: Write the failing test**

Create `test/bats/echo-pairwise-prompt.bats`:

```bash
#!/usr/bin/env bats

# The pairwise prompt behind ONL-103.
#
# echo's absolute rubric has a signal-to-noise of 0.61: it cannot reliably tell
# two different documents apart, and telling two VERSIONS of one document apart
# is harder. Pairwise comparison needs no stable absolute scale, which is the
# thing the measurement says is missing.
#
# This file pins the prompt's contract. The prompt is the whole experiment --
# a measurement taken against a different prompt does not transfer -- so the
# parts the stats depend on are asserted explicitly.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh"
}

@test "the pairwise prompt names both documents and both bodies" {
	run echo_build_pairwise_prompt "a/one.md" "BODY-ALPHA" "b/two.md" "BODY-BETA"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"a/one.md"* ]] || return 1
	[[ "$output" == *"BODY-ALPHA"* ]] || return 1
	[[ "$output" == *"b/two.md"* ]] || return 1
	[[ "$output" == *"BODY-BETA"* ]] || return 1
}

@test "the pairwise prompt fixes the verdict vocabulary" {
	run echo_build_pairwise_prompt "a.md" "A" "b.md" "B"
	[[ "$output" == *'"verdict"'* ]] || return 1
	[[ "$output" == *"better"* ]] || return 1
	[[ "$output" == *"worse"* ]] || return 1
	[[ "$output" == *"same"* ]] || return 1
	[[ "$output" == *'"confidence"'* ]] || return 1
}

# A model asked to compare two things is reluctant to call a tie, and the
# self-comparison arm depends entirely on it being willing to. If self_tie_rate
# fails for THIS reason it is a prompt defect, not evidence that pairwise
# cannot work, so the permission is explicit and pinned.
@test "the pairwise prompt says identical input is expected" {
	run echo_build_pairwise_prompt "a.md" "A" "b.md" "B"
	[[ "$output" == *"identical"* ]] || return 1
}

@test "the pairwise prompt defines better as referring to document B" {
	run echo_build_pairwise_prompt "a.md" "A" "b.md" "B"
	[[ "$output" == *"DOCUMENT B"* ]] || return 1
}

@test "the scoring prompt is unchanged by the pairwise addition" {
	run echo_build_judge_prompt "x.md" "XBODY"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Score on these criteria"* ]] || return 1
	[[ "$output" == *'"score"'* ]] || return 1
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats test/bats/echo-pairwise-prompt.bats`
Expected: FAIL — `echo_build_pairwise_prompt: command not found` on the first four tests. The fifth (scoring prompt unchanged) passes already.

- [ ] **Step 3: Write minimal implementation**

Append to `plugins/echo/scripts/lib/echo-judge-prompt.sh`, after `echo_build_judge_prompt`:

```bash
# The pairwise comparison prompt (ONL-103).
#
# The absolute rubric above has a measured signal-to-noise of 0.61 -- it cannot
# reliably separate two different documents, and separating two versions of one
# document is harder. A pairwise verdict needs no stable absolute scale, which
# is exactly what that measurement says is missing.
#
# "better" always refers to DOCUMENT B. Stating the direction in the prompt
# rather than inferring it from argument order is what makes the antisymmetry
# check meaningful: a judge that prefers slot two produces discrimination that
# looks excellent and means nothing, and the only way to see that is to run
# both orders and compare.
#
# The tie permission is load-bearing. A model asked to compare is reluctant to
# call two things equal, and the self-comparison arm measures nothing else. A
# self_tie_rate that fails because the prompt never invited a tie is a prompt
# defect masquerading as a finding about pairwise comparison.
#
# Exposes:
#   echo_build_pairwise_prompt <rel_a> <content_a> <rel_b> <content_b>
echo_build_pairwise_prompt() {
	local rel_a="$1" content_a="$2" rel_b="$3" content_b="$4"
	printf '%s\n' 'You are comparing two agent prompt files. Return JSON only — no prose, no markdown fences.'
	printf '\n'
	printf '%s\n' 'Output schema (exactly these keys):'
	printf '%s\n' '{'
	printf '%s\n' '  "verdict": "better" | "worse" | "same",'
	printf '%s\n' '  "confidence": 0.0..1.0,'
	printf '%s\n' '  "reason": "1-2 sentences naming the deciding difference."'
	printf '%s\n' '}'
	printf '\n'
	printf '%s\n' 'The verdict is about DOCUMENT B, relative to DOCUMENT A:'
	printf '%s\n' '  "better" — DOCUMENT B is the better prompt file'
	printf '%s\n' '  "worse"  — DOCUMENT B is the worse prompt file'
	printf '%s\n' '  "same"   — neither is meaningfully better'
	printf '\n'
	printf '%s\n' 'Judge on: role clarity, unambiguous output format, criterion coverage, and internal consistency.'
	printf '\n'
	printf '%s\n' 'The two documents may be identical. That is expected and common — answer "same" when they are, and whenever the difference between them does not favor either one.'
	printf '\n'
	printf '%s\n' "---DOCUMENT A: ${rel_a}---"
	printf '%s\n' "$content_a"
	printf '%s\n' '---END DOCUMENT A---'
	printf '\n'
	printf '%s\n' "---DOCUMENT B: ${rel_b}---"
	printf '%s\n' "$content_b"
	printf '%s\n' '---END DOCUMENT B---'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats test/bats/echo-pairwise-prompt.bats`
Expected: PASS, 5 tests.

Then confirm nothing else moved: `npm run test:shellcheck && bats test/bats/echo-measure-judge-spread.bats`
Expected: shellcheck clean; the ONL-102 harness tests still pass.

- [ ] **Step 5: Commit**

Use `/git-workflow:commit`. Stage exactly:

```bash
git add plugins/echo/scripts/lib/echo-judge-prompt.sh test/bats/echo-pairwise-prompt.bats
```

Message should say the direction convention is in the prompt because antisymmetry depends on it, and that the tie permission is load-bearing for the self arm.

---

### Task 2: The statistics

**Files:**
- Create: `plugins/echo/scripts/pairwise-stats.mjs`
- Test: `test/node/pairwise-stats.test.mjs` (create)

**Interfaces:**
- Consumes: nothing from Task 1 at runtime. Its input is a JSON document the Task 3 runner writes.
- Produces:
  - `export function selfTieRate(verdicts)` → number in `[0,1]`, rounded to 4dp
  - `export function crossAntisymmetry(pairs)` → number in `[0,1]`, rounded to 4dp
  - `export function trueDiscrimination(pairs)` → number in `[0,1]`, rounded to 4dp
  - `export function pairwiseStats(doc)` → the full report object, shape below
  - `export const KILL = { selfTie: 0.9, antisymmetry: 0.8 }`
  - CLI: `node pairwise-stats.mjs <verdicts.json>` prints the report as JSON on stdout

Input document shape (what Task 3 writes):

```json
{
  "model": "claude-haiku-4-5-20251001",
  "prompt_sha256": "…",
  "measured_at": "2026-10-03T19:00:00Z",
  "repeats": 2,
  "self": [
    { "path": "a.md", "verdicts": ["same", "same"] }
  ],
  "cross": [
    { "a": "a.md", "b": "b.md", "ab": ["better", "better"], "ba": ["worse", "worse"] }
  ]
}
```

`pairwiseStats` returns:

```json
{
  "model": "…", "prompt_sha256": "…", "measured_at": "…", "repeats": 2,
  "self_tie_rate": 1.0,
  "false_discrimination": 0.0,
  "cross_antisymmetry": 1.0,
  "true_discrimination": 1.0,
  "counts": { "self_comparisons": 2, "cross_pairs": 1 },
  "kill": {
    "self_tie_pass": true,
    "antisymmetry_pass": true,
    "discrimination_pass": true,
    "verdict": "proceed"
  }
}
```

- [ ] **Step 1: Write the failing test**

Create `test/node/pairwise-stats.test.mjs`:

```javascript
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  KILL,
  crossAntisymmetry,
  pairwiseStats,
  selfTieRate,
  trueDiscrimination,
} from '../../plugins/echo/scripts/pairwise-stats.mjs';

// The statistics behind ONL-103. echo's absolute rubric scores identical
// content with a within-file sd of 0.079 against a between-file signal of
// 0.048 -- signal/noise 0.61. These functions ask the pairwise equivalent:
// does the judge report a difference MORE often between two documents than
// between one document and itself? Both sides are rates of the same event, so
// they are directly comparable, which the first draft of the spec got wrong.

describe('selfTieRate', () => {
  it('is 1 when every self comparison says same', () => {
    assert.equal(selfTieRate([{ path: 'a', verdicts: ['same', 'same'] }]), 1);
  });

  it('is 0 when no self comparison says same', () => {
    assert.equal(selfTieRate([{ path: 'a', verdicts: ['better', 'worse'] }]), 0);
  });

  it('counts across files, not per file', () => {
    // 3 of 4 comparisons tie.
    const r = selfTieRate([
      { path: 'a', verdicts: ['same', 'same'] },
      { path: 'b', verdicts: ['same', 'better'] },
    ]);
    assert.equal(r, 0.75);
  });

  it('is 0 for no data rather than NaN', () => {
    assert.equal(selfTieRate([]), 0);
  });
});

describe('crossAntisymmetry', () => {
  it('counts better/worse in opposite orders as antisymmetric', () => {
    const r = crossAntisymmetry([
      { a: 'a', b: 'b', ab: ['better'], ba: ['worse'] },
    ]);
    assert.equal(r, 1);
  });

  it('counts same/same as antisymmetric', () => {
    const r = crossAntisymmetry([{ a: 'a', b: 'b', ab: ['same'], ba: ['same'] }]);
    assert.equal(r, 1);
  });

  // The position-bias signature: whichever document sits in slot B wins. Both
  // orders say "better", which is self-contradictory, and a judge doing this
  // produces discrimination that looks excellent and means nothing.
  it('counts better/better as NOT antisymmetric', () => {
    const r = crossAntisymmetry([
      { a: 'a', b: 'b', ab: ['better'], ba: ['better'] },
    ]);
    assert.equal(r, 0);
  });

  it('counts a tie against a preference as NOT antisymmetric', () => {
    const r = crossAntisymmetry([{ a: 'a', b: 'b', ab: ['same'], ba: ['worse'] }]);
    assert.equal(r, 0);
  });

  it('averages over repeats within a pair', () => {
    // repeat 1 antisymmetric, repeat 2 not.
    const r = crossAntisymmetry([
      { a: 'a', b: 'b', ab: ['better', 'better'], ba: ['worse', 'better'] },
    ]);
    assert.equal(r, 0.5);
  });

  it('is 0 for no data rather than NaN', () => {
    assert.equal(crossAntisymmetry([]), 0);
  });
});

describe('trueDiscrimination', () => {
  it('requires a non-tie verdict consistent across every repeat and both orders', () => {
    const r = trueDiscrimination([
      { a: 'a', b: 'b', ab: ['better', 'better'], ba: ['worse', 'worse'] },
    ]);
    assert.equal(r, 1);
  });

  it('does not count a pair the judge called same', () => {
    const r = trueDiscrimination([
      { a: 'a', b: 'b', ab: ['same', 'same'], ba: ['same', 'same'] },
    ]);
    assert.equal(r, 0);
  });

  it('does not count a pair whose verdict flipped between repeats', () => {
    const r = trueDiscrimination([
      { a: 'a', b: 'b', ab: ['better', 'worse'], ba: ['worse', 'better'] },
    ]);
    assert.equal(r, 0);
  });

  it('does not count a pair that fails antisymmetry', () => {
    const r = trueDiscrimination([
      { a: 'a', b: 'b', ab: ['better', 'better'], ba: ['better', 'better'] },
    ]);
    assert.equal(r, 0);
  });

  it('is a share of pairs', () => {
    const r = trueDiscrimination([
      { a: 'a', b: 'b', ab: ['better'], ba: ['worse'] },
      { a: 'a', b: 'c', ab: ['same'], ba: ['same'] },
    ]);
    assert.equal(r, 0.5);
  });
});

describe('pairwiseStats', () => {
  const doc = {
    model: 'm',
    prompt_sha256: 'deadbeef',
    measured_at: '2026-10-03T19:00:00Z',
    repeats: 2,
    self: [
      { path: 'a.md', verdicts: ['same', 'same'] },
      { path: 'b.md', verdicts: ['same', 'same'] },
    ],
    cross: [
      { a: 'a.md', b: 'b.md', ab: ['better', 'better'], ba: ['worse', 'worse'] },
    ],
  };

  it('carries the provenance stamps through unchanged', () => {
    const s = pairwiseStats(doc);
    assert.equal(s.model, 'm');
    assert.equal(s.prompt_sha256, 'deadbeef');
    assert.equal(s.measured_at, '2026-10-03T19:00:00Z');
    assert.equal(s.repeats, 2);
  });

  it('reports false_discrimination as the complement of self_tie_rate', () => {
    const s = pairwiseStats(doc);
    assert.equal(s.self_tie_rate, 1);
    assert.equal(s.false_discrimination, 0);
  });

  it('says proceed when all three criteria hold', () => {
    const s = pairwiseStats(doc);
    assert.equal(s.kill.verdict, 'proceed');
    assert.equal(s.kill.self_tie_pass, true);
    assert.equal(s.kill.antisymmetry_pass, true);
    assert.equal(s.kill.discrimination_pass, true);
  });

  it('says stop when the judge cannot recognize identical content', () => {
    const bad = {
      ...doc,
      self: [{ path: 'a.md', verdicts: ['better', 'worse'] }],
    };
    const s = pairwiseStats(bad);
    assert.equal(s.kill.self_tie_pass, false);
    assert.equal(s.kill.verdict, 'stop');
  });

  // The whole question, in one case: the judge claims a difference on identical
  // content as often as it does between different documents. That is noise
  // wearing a verdict's clothes.
  it('says stop when true_discrimination does not exceed false_discrimination', () => {
    const bad = {
      ...doc,
      self: [{ path: 'a.md', verdicts: ['same', 'better'] }],
      cross: [{ a: 'a.md', b: 'b.md', ab: ['same', 'same'], ba: ['same', 'same'] }],
    };
    const s = pairwiseStats(bad);
    assert.equal(s.true_discrimination, 0);
    assert.equal(s.false_discrimination, 0.5);
    assert.equal(s.kill.discrimination_pass, false);
    assert.equal(s.kill.verdict, 'stop');
  });

  it('counts the comparisons it used', () => {
    const s = pairwiseStats(doc);
    assert.equal(s.counts.self_comparisons, 4);
    assert.equal(s.counts.cross_pairs, 1);
  });

  it('exposes the thresholds it judged against', () => {
    assert.equal(KILL.selfTie, 0.9);
    assert.equal(KILL.antisymmetry, 0.8);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/node/pairwise-stats.test.mjs`
Expected: FAIL — cannot find module `pairwise-stats.mjs`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/echo/scripts/pairwise-stats.mjs`:

```javascript
// Statistics behind echo's pairwise discrimination measurement (ONL-103).
//
// ONL-102 measured the absolute rubric: within-file sd 0.079 against a
// between-file signal of 0.048, signal/noise 0.61. The rubric cannot reliably
// separate two different documents, and echo's real job -- separating two
// versions of one document -- is harder than that.
//
// This module asks the pairwise form of the same question. Both headline rates
// are expressed as "the judge reported a difference", so they are directly
// comparable:
//
//   false_discrimination = 1 - self_tie_rate   claimed a difference where none exists
//   true_discrimination  = consistent, antisymmetric, non-tie verdict on a real pair
//
// The spec's first draft compared two quantities with different units and asked
// whether one exceeded the other, which meant nothing. This is the fix.
//
// Pure: verdicts in, statistics out, touches nothing. The expensive half
// (72 judge calls) lives in measure-pairwise-discrimination.sh, so these
// numbers are tested exhaustively without spending a token.

/** The kill criterion, fixed before the first run so it cannot be moved after. */
export const KILL = { selfTie: 0.9, antisymmetry: 0.8 };

/** Round to 4 decimals, matching judge-spread-stats.mjs. */
function round4(x) {
  return Math.round(x * 10000) / 10000;
}

/**
 * Share of self comparisons (a document against itself) that returned "same".
 * A judge unwilling to call identical content identical measures nothing else.
 */
export function selfTieRate(selfEntries) {
  let total = 0;
  let ties = 0;
  for (const entry of selfEntries ?? []) {
    for (const v of entry.verdicts ?? []) {
      total += 1;
      if (v === 'same') ties += 1;
    }
  }
  if (total === 0) return 0;
  return round4(ties / total);
}

/**
 * One repeat is antisymmetric when the two presentation orders agree: a
 * preference in one direction must reverse when the documents swap places, and
 * a tie must stay a tie.
 *
 * better/better is the position-bias signature -- whichever document sits in
 * slot B wins -- and it is self-contradictory, not a strong signal.
 */
function repeatIsAntisymmetric(ab, ba) {
  if (ab === 'same' && ba === 'same') return true;
  if (ab === 'better' && ba === 'worse') return true;
  if (ab === 'worse' && ba === 'better') return true;
  return false;
}

/** Mean, over pairs, of the share of repeats that were antisymmetric. */
export function crossAntisymmetry(pairs) {
  const list = pairs ?? [];
  if (list.length === 0) return 0;
  let acc = 0;
  for (const p of list) {
    const ab = p.ab ?? [];
    const ba = p.ba ?? [];
    const n = Math.min(ab.length, ba.length);
    if (n === 0) continue;
    let ok = 0;
    for (let i = 0; i < n; i += 1) {
      if (repeatIsAntisymmetric(ab[i], ba[i])) ok += 1;
    }
    acc += ok / n;
  }
  return round4(acc / list.length);
}

/**
 * Share of pairs the judge discriminated: a non-tie verdict, identical across
 * every repeat, and antisymmetric in both orders.
 *
 * All three conditions are required. A verdict that flips between runs is not
 * discrimination, and one that only holds in a single presentation order is
 * position bias.
 */
export function trueDiscrimination(pairs) {
  const list = pairs ?? [];
  if (list.length === 0) return 0;
  let discriminated = 0;
  for (const p of list) {
    const ab = p.ab ?? [];
    const ba = p.ba ?? [];
    const n = Math.min(ab.length, ba.length);
    if (n === 0) continue;
    const first = ab[0];
    if (first === 'same') continue;
    let ok = true;
    for (let i = 0; i < n; i += 1) {
      if (ab[i] !== first) { ok = false; break; }
      if (!repeatIsAntisymmetric(ab[i], ba[i])) { ok = false; break; }
    }
    if (ok) discriminated += 1;
  }
  return round4(discriminated / list.length);
}

/** The full report, including the pass/fail the run exists to produce. */
export function pairwiseStats(doc) {
  const selfEntries = doc.self ?? [];
  const pairs = doc.cross ?? [];

  const self_tie_rate = selfTieRate(selfEntries);
  const false_discrimination = round4(1 - self_tie_rate);
  const cross_antisymmetry = crossAntisymmetry(pairs);
  const true_discrimination = trueDiscrimination(pairs);

  const self_tie_pass = self_tie_rate >= KILL.selfTie;
  const antisymmetry_pass = cross_antisymmetry >= KILL.antisymmetry;
  const discrimination_pass = true_discrimination > false_discrimination;

  let self_comparisons = 0;
  for (const entry of selfEntries) self_comparisons += (entry.verdicts ?? []).length;

  return {
    model: doc.model,
    prompt_sha256: doc.prompt_sha256,
    measured_at: doc.measured_at,
    repeats: doc.repeats,
    self_tie_rate,
    false_discrimination,
    cross_antisymmetry,
    true_discrimination,
    counts: { self_comparisons, cross_pairs: pairs.length },
    kill: {
      self_tie_pass,
      antisymmetry_pass,
      discrimination_pass,
      verdict:
        self_tie_pass && antisymmetry_pass && discrimination_pass ? 'proceed' : 'stop',
    },
  };
}

// Kept behind an entrypoint check so importing the module for tests runs
// nothing, matching judge-spread-stats.mjs.
if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  const { readFileSync } = await import('node:fs');
  const path = process.argv[2];
  if (!path) {
    process.stderr.write('usage: pairwise-stats.mjs <verdicts.json>\n');
    process.exit(2);
  }
  const doc = JSON.parse(readFileSync(path, 'utf8'));
  process.stdout.write(`${JSON.stringify(pairwiseStats(doc), null, 2)}\n`);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/node/pairwise-stats.test.mjs`
Expected: PASS, 24 tests.

Then confirm the whole node suite is still green: `npm run test:schema`
Expected: PASS, 0 fail.

- [ ] **Step 5: Break one assertion on purpose**

Temporarily change `repeatIsAntisymmetric` so `better`/`better` returns `true`, re-run `node --test test/node/pairwise-stats.test.mjs`, and confirm the test named `counts better/better as NOT antisymmetric` fails. Revert.

A test that passes whether or not the code is correct reports coverage that does not exist, and this is the single assertion that separates real discrimination from position bias.

- [ ] **Step 6: Commit**

Use `/git-workflow:commit`. Stage exactly:

```bash
git add plugins/echo/scripts/pairwise-stats.mjs test/node/pairwise-stats.test.mjs
```

Message should say both headline rates are expressed as the same event so they are comparable, and that `better`/`better` is counted as a failure because it is the position-bias signature.

---

### Task 3: The runner

**Files:**
- Create: `plugins/echo/scripts/measure-pairwise-discrimination.sh` (mode `755`)
- Test: `test/bats/echo-measure-pairwise.bats` (create)

**Interfaces:**
- Consumes: `echo_build_pairwise_prompt` (Task 1); `pairwise-stats.mjs` CLI (Task 2); `echo_config_load`, `echo_config_model`, `echo_config_timeout` from `plugins/echo/scripts/lib/echo-config.sh`.
- Produces: `verdicts.json` and `stats.json` under `--out DIR`, plus a human summary on stdout. No other task consumes it.

CLI: `measure-pairwise-discrimination.sh [--repeats N] [--out DIR] [--dry-run] [FILE...]`

- [ ] **Step 1: Write the failing test**

Create `test/bats/echo-measure-pairwise.bats`:

```bash
#!/usr/bin/env bats

# The harness behind ONL-103.
#
# The 72 real judge calls are manual. Nothing here spends a token: the stub
# stands in for the judge so the plumbing can be tested exhaustively. A test
# suite that costs 72 Haiku calls is a trap nobody runs -- the same reasoning
# that keeps the measure-* scripts themselves out of npm test, while this file
# runs in it for free.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	HARNESS="${PLUGIN_ROOT}/scripts/measure-pairwise-discrimination.sh"

	SUBJECT_DIR="${BATS_TEST_TMPDIR}/subjects"
	mkdir -p "$SUBJECT_DIR"
	printf '# Reviewer\n\nA well-specified agent.\n' > "${SUBJECT_DIR}/one.md"
	printf '# Auditor\n\nAnother one.\n' > "${SUBJECT_DIR}/two.md"
	printf '# Scribe\n\nA third.\n' > "${SUBJECT_DIR}/three.md"

	OUT_DIR="${BATS_TEST_TMPDIR}/out"
	CALL_LOG="${BATS_TEST_TMPDIR}/calls"
	PROMPT_LOG="${BATS_TEST_TMPDIR}/prompts"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	# Answers from the prompt itself so both orders stay consistent: B better
	# when B's body sorts later, "same" when the bodies match. That makes the
	# stubbed run antisymmetric by construction, which is what the plumbing
	# assertions need -- the real judge's behavior is the open question.
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
printf '%s' "$prompt" >> "${PROMPT_LOG}"
printf 'call\n' >> "${CALL_LOG}"
a=$(printf '%s' "$prompt" | sed -n '/---DOCUMENT A:/,/---END DOCUMENT A---/p' | sed '1d;$d')
b=$(printf '%s' "$prompt" | sed -n '/---DOCUMENT B:/,/---END DOCUMENT B---/p' | sed '1d;$d')
if [[ "$a" == "$b" ]]; then
	printf '{"verdict":"same","confidence":0.9,"reason":"identical"}'
elif [[ "$b" > "$a" ]]; then
	printf '{"verdict":"better","confidence":0.8,"reason":"b"}'
else
	printf '{"verdict":"worse","confidence":0.8,"reason":"a"}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
	export PROMPT_LOG CALL_LOG
}

@test "dry-run reports the call count and spends nothing" {
	run "$HARNESS" --dry-run --repeats 2 \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md" "${SUBJECT_DIR}/three.md"
	[ "$status" -eq 0 ] || return 1
	# 3 self x 2 repeats + 3 pairs x 2 orders x 2 repeats = 6 + 12 = 18
	[[ "$output" == *"18"* ]] || return 1
	[ ! -f "$CALL_LOG" ]
}

@test "a real run spends exactly the calls it predicted" {
	run "$HARNESS" --repeats 2 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md" "${SUBJECT_DIR}/three.md"
	[ "$status" -eq 0 ] || return 1
	[ "$(wc -l < "$CALL_LOG" | tr -d ' ')" -eq 18 ]
}

@test "the self arm compares a document against its own content" {
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.self | length == 1' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.self[0].verdicts == ["same"]' "${OUT_DIR}/verdicts.json" >/dev/null
}

@test "every cross pair is evaluated in both orders" {
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.cross | length == 1' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.cross[0].ab | length == 1' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.cross[0].ba | length == 1' "${OUT_DIR}/verdicts.json" >/dev/null
}

@test "the run stamps the model and the prompt fingerprint" {
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.prompt_sha256 | length == 64' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.model | length > 0' "${OUT_DIR}/verdicts.json" >/dev/null
}

@test "it writes a stats report carrying the kill verdict" {
	run "$HARNESS" --repeats 2 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.kill.verdict == "proceed" or .kill.verdict == "stop"' "${OUT_DIR}/stats.json" >/dev/null || return 1
	jq -e 'has("self_tie_rate") and has("true_discrimination")' "${OUT_DIR}/stats.json" >/dev/null
}

# The self arm is the cheapest possible kill: 6 of the 72 calls at R=1. Running
# it first means a judge that cannot recognize identical content costs almost
# nothing to rule out.
@test "the self arm runs before the cross arm" {
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	first_a=$(sed -n '/---DOCUMENT A:/{s/---DOCUMENT A: //;s/---//;p;q;}' "$PROMPT_LOG")
	first_b=$(grep -m1 -- '---DOCUMENT B:' "$PROMPT_LOG" | sed 's/---DOCUMENT B: //;s/---//')
	[ "$first_a" = "$first_b" ]
}

@test "an unreadable file is rejected before any judge call" {
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" "${SUBJECT_DIR}/nope.md"
	[ "$status" -ne 0 ] || return 1
	[ ! -f "$CALL_LOG" ]
}

@test "fewer than two files cannot form a cross pair and is rejected" {
	run "$HARNESS" --dry-run --repeats 1 "${SUBJECT_DIR}/one.md"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"two"* ]] || [[ "$output" == *"2"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats test/bats/echo-measure-pairwise.bats`
Expected: FAIL — the harness file does not exist, so every test errors.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/echo/scripts/measure-pairwise-discrimination.sh` and `chmod 755` it:

```bash
#!/usr/bin/env bash
# Measure echo's pairwise discrimination (ONL-103).
#
# WHY THIS EXISTS. ONL-102 set drift_threshold to the measured 0.28 and made
# echo truthful. The same measurement showed why that did not make it useful:
# between-file sd of means 0.048 against a mean within-file sd of 0.079, so
# signal/noise is 0.61. The absolute rubric cannot reliably separate two
# different documents, and echo's real job -- separating two versions of one
# document -- is strictly harder. Median-of-5 only reaches signal/noise near 1,
# at five times the cost of the most expensive hook in the stack.
#
# Pairwise comparison needs no stable absolute scale, which is exactly what is
# missing. This script measures whether it discriminates, BEFORE anything in
# echo changes, because ONL-103's acceptance criterion is itself a measurement.
#
# WHAT IT DOES. Two arms over the same files:
#   self   each document against its own content  -> the noise floor
#   cross  every pair, in BOTH presentation orders -> discrimination + bias
#
# Both orders are not optional. A judge that prefers whichever document sits in
# slot B manufactures discrimination that looks excellent and means nothing,
# and running one order cannot see it.
#
# The self arm runs first: it is the cheapest kill. A judge that will not call
# identical content identical is ruled out for a sixth of the calls.
#
# THIS SCRIPT is never run by npm test -- a full run is 72 judge calls. Its
# tests are: test/bats/echo-measure-pairwise.bats covers the plumbing against
# a stub, and test/node/pairwise-stats.test.mjs covers the arithmetic. Both of
# those DO run in npm test, and cost nothing.
#
# Usage:
#   measure-pairwise-discrimination.sh [--repeats N] [--out DIR] [--dry-run] [FILE...]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_ROOT}/../.." && pwd)"

# shellcheck source=lib/echo-config.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-config.sh"
# shellcheck source=lib/echo-judge-prompt.sh
source "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh"

REPEATS=2
DRY_RUN=0
OUT_DIR=""
FILES=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--repeats) REPEATS="$2"; shift 2 ;;
		--out) OUT_DIR="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help)
			printf 'usage: %s [--repeats N] [--out DIR] [--dry-run] [FILE...]\n' "$(basename "$0")"
			exit 0 ;;
		*) FILES+=("$1"); shift ;;
	esac
done

if [[ "${#FILES[@]}" -eq 0 ]]; then
	printf 'no files given; pass the paths to compare\n' >&2
	exit 1
fi

# A cross pair needs two documents. One file can only measure the noise floor,
# which answers half the question and reads as a complete run.
if [[ "${#FILES[@]}" -lt 2 ]]; then
	printf 'need at least two files to form a cross pair; got %d\n' "${#FILES[@]}" >&2
	exit 1
fi

for f in "${FILES[@]}"; do
	if [[ ! -f "$f" ]]; then
		printf 'not a readable file: %s\n' "$f" >&2
		exit 1
	fi
done

# Mirrors measure-judge-spread.sh, CLAUDE_PLUGIN_ROOT included. The accessors
# read it at call time, so a plain echo_config_load leaves every value empty and
# the run would measure whatever the DEFAULT model is rather than echo's pinned
# judge -- a measurement that describes nothing.
CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$REPO_ROOT"
EVAL_MODEL=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_model)
TIMEOUT_SECS=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_timeout)

N=${#FILES[@]}
PAIRS=$(( N * (N - 1) / 2 ))
SELF_CALLS=$(( N * REPEATS ))
CROSS_CALLS=$(( PAIRS * 2 * REPEATS ))
TOTAL=$(( SELF_CALLS + CROSS_CALLS ))

if [[ "$DRY_RUN" -eq 1 ]]; then
	printf 'would run %d judge calls\n' "$TOTAL"
	printf '  self:  %d  (%d files x %d repeats)\n' "$SELF_CALLS" "$N" "$REPEATS"
	printf '  cross: %d  (%d pairs x 2 orders x %d repeats)\n' "$CROSS_CALLS" "$PAIRS" "$REPEATS"
	printf 'model: %s\n' "$EVAL_MODEL"
	for f in "${FILES[@]}"; do printf '  %s\n' "$f"; done
	exit 0
fi

[[ -z "$OUT_DIR" ]] && OUT_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}/echo/pairwise/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR" || { printf 'cannot create %s\n' "$OUT_DIR" >&2; exit 1; }

# These numbers are a property of ONE prompt judged by ONE model. Stamping both
# is what lets a later reader know whether the measurement still applies.
if command -v shasum >/dev/null 2>&1; then
	PROMPT_SHA=$(shasum -a 256 "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh" | cut -d' ' -f1)
else
	PROMPT_SHA=$(sha256sum "${PLUGIN_ROOT}/scripts/lib/echo-judge-prompt.sh" | cut -d' ' -f1)
fi

PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

# One judge call. Echoes the verdict, or nothing when the response does not
# parse. Callers count usable verdicts rather than attempts.
_ask() {
	local rel_a="$1" body_a="$2" rel_b="$3" body_b="$4"
	echo_build_pairwise_prompt "$rel_a" "$body_a" "$rel_b" "$body_b" > "$PROMPT_FILE"

	local args=(-p --max-turns 1)
	[[ -n "$EVAL_MODEL" ]] && args+=(--model "$EVAL_MODEL")

	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$TIMEOUT_SECS" claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$TIMEOUT_SECS" claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$PROMPT_FILE" 2>/dev/null) || response=""
	fi

	local clean verdict
	clean=$(printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
	verdict=$(printf '%s' "$clean" | jq -r 'select(.verdict == "better" or .verdict == "worse" or .verdict == "same") | .verdict' 2>/dev/null) || verdict=""
	printf '%s' "$verdict"
}

SELF_JSON="${OUT_DIR}/.self.json"
CROSS_JSON="${OUT_DIR}/.cross.json"
printf '[]' > "$SELF_JSON"
printf '[]' > "$CROSS_JSON"

RELS=()
BODIES=()
for f in "${FILES[@]}"; do
	RELS+=("${f#"${REPO_ROOT}/"}")
	BODIES+=("$(cat "$f")")
done

# --- self arm, first: the cheapest kill -------------------------------------
printf 'self arm (%d calls):\n' "$SELF_CALLS" >&2
for i in "${!RELS[@]}"; do
	printf '  %s: ' "${RELS[$i]}" >&2
	csv=""
	for ((r = 0; r < REPEATS; r++)); do
		v=$(_ask "${RELS[$i]}" "${BODIES[$i]}" "${RELS[$i]}" "${BODIES[$i]}")
		if [[ -z "$v" ]]; then printf 'x' >&2; continue; fi
		printf '.' >&2
		csv="${csv}${csv:+,}\"${v}\""
	done
	printf '\n' >&2
	jq --arg p "${RELS[$i]}" --argjson v "[${csv}]" \
		'. + [{path: $p, verdicts: $v}]' "$SELF_JSON" > "${SELF_JSON}.next" \
		&& mv "${SELF_JSON}.next" "$SELF_JSON"
done

# --- cross arm, both orders -------------------------------------------------
printf 'cross arm (%d calls):\n' "$CROSS_CALLS" >&2
for ((i = 0; i < N; i++)); do
	for ((j = i + 1; j < N; j++)); do
		printf '  %s vs %s: ' "${RELS[$i]}" "${RELS[$j]}" >&2
		ab_csv=""
		ba_csv=""
		for ((r = 0; r < REPEATS; r++)); do
			v=$(_ask "${RELS[$i]}" "${BODIES[$i]}" "${RELS[$j]}" "${BODIES[$j]}")
			if [[ -n "$v" ]]; then printf '.' >&2; ab_csv="${ab_csv}${ab_csv:+,}\"${v}\""; else printf 'x' >&2; fi
			v=$(_ask "${RELS[$j]}" "${BODIES[$j]}" "${RELS[$i]}" "${BODIES[$i]}")
			if [[ -n "$v" ]]; then printf '.' >&2; ba_csv="${ba_csv}${ba_csv:+,}\"${v}\""; else printf 'x' >&2; fi
		done
		printf '\n' >&2
		jq --arg a "${RELS[$i]}" --arg b "${RELS[$j]}" \
			--argjson ab "[${ab_csv}]" --argjson ba "[${ba_csv}]" \
			'. + [{a: $a, b: $b, ab: $ab, ba: $ba}]' "$CROSS_JSON" > "${CROSS_JSON}.next" \
			&& mv "${CROSS_JSON}.next" "$CROSS_JSON"
	done
done

VERDICTS_JSON="${OUT_DIR}/verdicts.json"
jq -n \
	--arg model "${EVAL_MODEL:-default}" \
	--arg prompt_sha256 "$PROMPT_SHA" \
	--arg measured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--argjson repeats "$REPEATS" \
	--slurpfile self "$SELF_JSON" \
	--slurpfile cross "$CROSS_JSON" \
	'{model: $model, prompt_sha256: $prompt_sha256, measured_at: $measured_at,
	  repeats: $repeats, self: $self[0], cross: $cross[0]}' > "$VERDICTS_JSON"
rm -f "$SELF_JSON" "$CROSS_JSON"

node "${SCRIPT_DIR}/pairwise-stats.mjs" "$VERDICTS_JSON" > "${OUT_DIR}/stats.json" || {
	printf 'statistics failed; raw verdicts kept at %s\n' "$VERDICTS_JSON" >&2
	exit 1
}

printf '\nverdicts: %s\nstats:    %s\n\n' "$VERDICTS_JSON" "${OUT_DIR}/stats.json"
node -e '
const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const row = (k, v, bar) => `  ${k.padEnd(22)} ${String(v).padEnd(8)} ${bar}`;
console.log("pairwise discrimination:");
console.log(row("self_tie_rate", s.self_tie_rate, s.kill.self_tie_pass ? "pass (>= 0.9)" : "FAIL (>= 0.9)"));
console.log(row("false_discrimination", s.false_discrimination, ""));
console.log(row("cross_antisymmetry", s.cross_antisymmetry, s.kill.antisymmetry_pass ? "pass (>= 0.8)" : "FAIL (>= 0.8)"));
console.log(row("true_discrimination", s.true_discrimination, s.kill.discrimination_pass ? "pass (> false)" : "FAIL (> false)"));
console.log(`\n  verdict: ${s.kill.verdict.toUpperCase()}`);
' "${OUT_DIR}/stats.json"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod 755 plugins/echo/scripts/measure-pairwise-discrimination.sh && bats test/bats/echo-measure-pairwise.bats`
Expected: PASS, 9 tests.

`chmod` matters: rewriting a script through a temp file drops the exec bit, and `bash <path>` hides it while a direct invocation fails.

- [ ] **Step 5: Run the full gates**

Run: `npm run test:shellcheck && npm run test:bats && npm run test:schema && npm run test:bus`
Expected: shellcheck clean; bats 0 failures; schema 0 fail; bus ok.

- [ ] **Step 6: Commit**

Use `/git-workflow:commit`. Stage exactly:

```bash
git add plugins/echo/scripts/measure-pairwise-discrimination.sh test/bats/echo-measure-pairwise.bats
```

Message should say the self arm runs first because it is the cheapest kill, and that both orders are evaluated because position bias is otherwise invisible.

---

### Task 4: Run the measurement and record the result

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-echo-pairwise-discrimination-design.md` (append a Result section)
- Create: `plugins/echo/docs/adr/005-pairwise-vs-absolute-scoring.md` **only if the verdict is `proceed`**

**Interfaces:**
- Consumes: the runner from Task 3.
- Produces: a recorded result, and either an ADR proposing the change or a documented stop.

- [ ] **Step 1: Confirm the cost before spending it**

Run:

```bash
plugins/echo/scripts/measure-pairwise-discrimination.sh --dry-run --repeats 2 \
  .claude/skills/writing-tests/SKILL.md \
  plugins/lineage/skills/lineage/SKILL.md \
  plugins/tribunal/agents/tribunal-actor.md \
  plugins/tribunal/agents/tribunal-judge-adversarial.md \
  plugins/tribunal/agents/tribunal-judge-standard.md \
  plugins/tribunal/agents/tribunal-meta-judge.md
```

Expected: `would run 72 judge calls`, self 12, cross 60, model `claude-haiku-4-5-20251001`.

If any path does not resolve, find the current location of the same six files ONL-102 used and use those. Do not substitute different files — the comparison to signal/noise 0.61 depends on the corpus being identical.

- [ ] **Step 2: Ask the user before spending the calls**

Report the dry-run output and get explicit approval. 72 Haiku calls on the most expensive hook in the stack is not a decision to make silently, and the same courtesy the librarian skill requires before dispatching judges applies here.

- [ ] **Step 3: Run it**

```bash
plugins/echo/scripts/measure-pairwise-discrimination.sh --repeats 2 --out /tmp/echo-pairwise \
  <the same six paths>
```

- [ ] **Step 4: Record the result verbatim**

Append a `## Result` section to the spec containing the `stats.json` table as measured — `self_tie_rate`, `false_discrimination`, `cross_antisymmetry`, `true_discrimination`, and the kill verdict — plus the model and `prompt_sha256` the run stamped.

Record what the numbers say, including when they are inconvenient. If `self_tie_rate` fails, state explicitly whether the failure looks like reluctance to call a tie (most verdicts non-`same` with high confidence and reasons that name no real difference) or an inability to compare, because those point at different next steps and only the raw `reason` strings can tell them apart.

- [ ] **Step 5: Branch on the verdict**

If `proceed`: write `plugins/echo/docs/adr/005-pairwise-vs-absolute-scoring.md` in the format of `004-drift-threshold-from-measured-spread.md` — Status `Proposed`, Context quoting both measurements, Decision to replace absolute scoring with pairwise comparison, Consequences noting that `drift_threshold` becomes obsolete rather than retuned and that baselines must store prior content. Then stop: the implementation is a separate spec.

If `stop`: do not write an ADR. Append the result to the spec, update ONL-103 with the numbers, and say which of the two directions the evidence now favors — most likely "sharpen the rubric", which the issue names as the other option.

- [ ] **Step 6: Commit**

Use `/git-workflow:commit`. Stage the spec and, if written, the ADR.

---

## Self-Review

**Spec coverage.** Every section of the design maps to a task: the prompt and its tie permission → Task 1; the four metrics and the kill criterion → Task 2; the two arms, both orders, self-first ordering, provenance stamping, and the 72-call budget → Task 3; the corpus, the run, and the proceed/stop branch → Task 4. The spec's "Out of scope" is enforced by the Global Constraints and by Task 4 stopping at an ADR.

**Placeholders.** None. Every code step carries the actual file content. Task 4 Step 1 contains a conditional ("if any path does not resolve") but names the exact resolution rule rather than deferring the decision.

**Type consistency.** `verdict` is `better`/`worse`/`same` in the Task 1 prompt, the Task 2 tests and module, and the Task 3 stub and parser. The `verdicts.json` shape in Task 2's Interfaces is byte-compatible with what Task 3's final `jq -n` writes: `model`, `prompt_sha256`, `measured_at`, `repeats`, `self[{path,verdicts}]`, `cross[{a,b,ab,ba}]`. `KILL.selfTie`/`KILL.antisymmetry` are referenced only in Task 2. The runner calls `pairwise-stats.mjs` by the same filename Task 2 creates.

**One gap found and fixed during review:** the runner originally had no guard for a single input file, which would have produced zero cross pairs and a stats report with `true_discrimination: 0` that read as a failed measurement rather than an impossible one. Task 3 now rejects fewer than two files, and `test/bats/echo-measure-pairwise.bats` pins it.
