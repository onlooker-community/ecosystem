#!/usr/bin/env node
// Arithmetic for the lesson-transform batch measurement (ONL-110).
//
// Pure aggregation. The GATE VERDICT is not recomputed here — the harness calls
// production's librarian_lesson_gate and records what it said, so this file
// cannot drift from the gate it reports on. What it does compute is the
// per-criterion view the gate deliberately does not expose: the gate names only
// the FIRST floored criterion it finds, which is the right behavior for a gate
// and useless for "which criterion fails most often".
//
// THE FLOOR IS A MINIMUM across the judges that scored a criterion, not their
// mean. Using the mean lets one judge's finding be diluted by others who did
// not look, and weakens every floor as the panel grows. Weighting uses the
// mean; only the floor is a minimum. test/node/lesson-transform-stats.test.mjs
// pins that distinction against hand-computed numbers.
//
// A criterion NO judge scored is `unscored`, never a failure: absence is not a
// zero, and librarian_lesson_gate refuses such a panel rather than floor-
// failing it. Unscored candidates leave the pass-rate denominator too, so a
// panel that skipped disclosure cannot quietly inflate its pass rate.
//
// Usage: lesson-transform-stats.mjs <samples.json>   (prints stats.json)

import { readFileSync } from 'node:fs';

const round4 = (x) => Math.round(x * 10000) / 10000;
const rate = (num, den) => (den === 0 ? null : round4(num / den));
const mean = (xs) => (xs.length === 0 ? null : round4(xs.reduce((a, b) => a + b, 0) / xs.length));

/** Tally one string into a histogram object, skipping empty keys. */
function bump(hist, key) {
  if (key === undefined || key === null || key === '') return;
  hist[key] = (hist[key] || 0) + 1;
}

export function computeStats({ rubric, candidates = [], ...passthrough } = {}) {
  const criteria = (rubric?.criteria ?? []).filter(
    (c) => typeof c?.name === 'string' && typeof c?.min_pass === 'number',
  );

  // Transform buckets, over EVERY attempted artifact. A batch whose transform
  // mostly failed is a different finding from one whose judges mostly failed,
  // and collapsing them is how a transform regression reads as a judge result.
  const transform = {
    attempted: candidates.length,
    proposed: 0,
    declined: 0,
    skipped: 0,
    unavailable: 0,
  };
  // Every bucket matches on PREFIX. librarian_lesson_transform_one returns
  // `proposed:<id>` and `proposed:<id>:unscoped`, never a bare `proposed`, so
  // an equality check here silently reports zero proposals for a batch that
  // transformed perfectly — which is exactly what it did until the bats run
  // caught it. The node fixtures had used the bare literal, so the arithmetic
  // tests agreed with the bug.
  for (const c of candidates) {
    const o = String(c?.transform_outcome ?? '');
    if (o.startsWith('declined')) transform.declined += 1;
    else if (o.startsWith('skipped')) transform.skipped += 1;
    else if (o.startsWith('unavailable')) transform.unavailable += 1;
    else if (o.startsWith('proposed')) transform.proposed += 1;
  }

  // Only candidates that actually reached a panel are measurable.
  const judged = candidates.filter((c) => Array.isArray(c?.verdicts) && c.verdicts.length > 0);

  const gate = {
    passed: 0,
    failed: 0,
    pass_rate: null,
    reasons: {},
    failed_criterion: {},
  };
  for (const c of judged) {
    if (c.gate?.passed === true) gate.passed += 1;
    else gate.failed += 1;
    bump(gate.reasons, c.gate?.reason);
    bump(gate.failed_criterion, c.gate?.failed_criterion);
  }
  gate.pass_rate = rate(gate.passed, judged.length);

  // Per-judge-type pass rates. The whole premise of ONL-110 is that standard
  // passes while adversarial fails, so this split is the headline number.
  const judges = {};
  for (const c of judged) {
    for (const v of c.verdicts) {
      const t = typeof v?.judge_type === 'string' ? v.judge_type : 'unknown';
      judges[t] ??= { n: 0, passed: 0, pass_rate: null, mean_score: null, _scores: [] };
      judges[t].n += 1;
      if (v?.passed === true) judges[t].passed += 1;
      if (typeof v?.score === 'number') judges[t]._scores.push(v.score);
    }
  }
  for (const t of Object.keys(judges)) {
    judges[t].pass_rate = rate(judges[t].passed, judges[t].n);
    judges[t].mean_score = mean(judges[t]._scores);
    delete judges[t]._scores;
  }

  const out = {};
  for (const c of criteria) {
    const entry = {
      min_pass: c.min_pass,
      weight: c.weight ?? null,
      floor_pass: 0,
      floor_fail: 0,
      unscored: 0,
      pass_rate: null,
      min_mean: null,
      by_judge: {},
    };
    const minima = [];
    const perJudge = {};

    for (const cand of judged) {
      const scores = [];
      for (const v of cand.verdicts) {
        const s = v?.criterion_scores?.[c.name];
        if (typeof s !== 'number') continue;
        scores.push(s);
        const t = typeof v?.judge_type === 'string' ? v.judge_type : 'unknown';
        perJudge[t] ??= { scores: [], pass: 0 };
        perJudge[t].scores.push(s);
        if (s >= c.min_pass) perJudge[t].pass += 1;
      }
      if (scores.length === 0) {
        entry.unscored += 1;
        continue;
      }
      const lowest = Math.min(...scores);
      minima.push(lowest);
      if (lowest >= c.min_pass) entry.floor_pass += 1;
      else entry.floor_fail += 1;
    }

    entry.pass_rate = rate(entry.floor_pass, entry.floor_pass + entry.floor_fail);
    entry.min_mean = mean(minima);
    for (const [t, d] of Object.entries(perJudge)) {
      entry.by_judge[t] = {
        n: d.scores.length,
        pass_rate: rate(d.pass, d.scores.length),
        mean: mean(d.scores),
      };
    }
    out[c.name] = entry;
  }

  return {
    ...passthrough,
    rubric_id: rubric?.id ?? null,
    score_threshold: rubric?.score_threshold ?? null,
    gate_policy: rubric?.gate_policy ?? null,
    n: judged.length,
    transform,
    gate,
    judges,
    criteria: out,
  };
}

// CLI: read samples.json, print stats.json.
if (import.meta.url === `file://${process.argv[1]}`) {
  const path = process.argv[2];
  if (!path) {
    process.stderr.write('usage: lesson-transform-stats.mjs <samples.json>\n');
    process.exit(2);
  }
  const samples = JSON.parse(readFileSync(path, 'utf8'));
  process.stdout.write(`${JSON.stringify(computeStats(samples), null, 2)}\n`);
}
