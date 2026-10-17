// Arithmetic for the lesson-transform batch measurement (ONL-110 / 1z07vm.1).
//
// The harness itself costs 3 model calls per candidate, so none of the
// arithmetic is exercised by running it. Everything computable from a verdict
// set is pinned here instead, exhaustively, against hand-computed numbers.
//
// The one rule worth restating: a criterion's floor is the MINIMUM across the
// judges that scored it, not their mean (librarian_lesson_gate says so in
// comment, and dilutes nothing as the panel grows). Weighting uses the mean.
// Getting those two backwards is the defect this file exists to catch.

import assert from 'node:assert/strict';
import test from 'node:test';

import { computeStats } from '../../plugins/librarian/scripts/lesson-transform-stats.mjs';

const RUBRIC = {
  id: 'lesson-promotion-public',
  criteria: [
    { name: 'grounding', weight: 0.32, min_pass: 0.7 },
    { name: 'scope_accuracy', weight: 0.24, min_pass: 0.7 },
    { name: 'generality', weight: 0.14, min_pass: 0.6 },
    { name: 'disclosure', weight: 0.3, min_pass: 0.9 },
  ],
  score_threshold: 0.75,
  gate_policy: 'majority',
};

// Usage: verdict('standard', 0.9, true, {grounding: 0.9, ...})
const verdict = (judge_type, score, passed, criterion_scores) => ({
  judge_type,
  score,
  passed,
  criterion_scores,
});

// transform_outcome carries the id: librarian_lesson_transform_one returns
// `proposed:<ulid>`, or `proposed:<ulid>:unscoped` for a parked claim. Using a
// bare 'proposed' here is what let a prefix bug through once already.
const candidate = (overrides = {}) => ({
  artifact_id: '01M4PD9CBE2F2QTH6D5690K1W6',
  lesson_id: '01M4PD9CBE2F2QTH6D5690K1W7',
  transform_outcome: 'proposed:01M4PD9CBE2F2QTH6D5690K1W7',
  verdicts: [],
  aggregate: 0,
  gate: { passed: false, reason: 'criterion_floor' },
  ...overrides,
});

const allHigh = { grounding: 0.9, scope_accuracy: 0.9, generality: 0.9, disclosure: 0.95 };

test('n counts only candidates that reached a verdict', () => {
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [
      candidate({ verdicts: [verdict('standard', 0.9, true, allHigh)] }),
      candidate({ transform_outcome: 'declined:transform_invalid', verdicts: [] }),
      candidate({ transform_outcome: 'unavailable', verdicts: [] }),
    ],
  });
  assert.equal(s.n, 1);
  assert.equal(s.transform.attempted, 3);
  assert.equal(s.transform.proposed, 1);
  assert.equal(s.transform.declined, 1);
  assert.equal(s.transform.unavailable, 1);
});

test('a criterion floor uses the minimum across judges, not the mean', () => {
  // mean(0.95, 0.55) = 0.75, which clears nothing; min = 0.55 < 0.9 floor.
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [
      candidate({
        verdicts: [
          verdict('standard', 0.9, true, { ...allHigh, disclosure: 0.95 }),
          verdict('adversarial', 0.6, false, { ...allHigh, disclosure: 0.55 }),
        ],
      }),
    ],
  });
  assert.equal(s.criteria.disclosure.floor_fail, 1);
  assert.equal(s.criteria.disclosure.floor_pass, 0);
  assert.equal(s.criteria.disclosure.pass_rate, 0);
  assert.equal(s.criteria.disclosure.min_mean, 0.55);
});

test('per-judge pass rates separate standard from adversarial', () => {
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [
      candidate({
        verdicts: [verdict('standard', 0.9, true, allHigh), verdict('adversarial', 0.6, false, allHigh)],
      }),
      candidate({
        verdicts: [verdict('standard', 0.85, true, allHigh), verdict('adversarial', 0.62, false, allHigh)],
      }),
    ],
  });
  assert.equal(s.judges.standard.pass_rate, 1);
  assert.equal(s.judges.adversarial.pass_rate, 0);
  assert.equal(s.judges.standard.n, 2);
  assert.equal(s.judges.adversarial.n, 2);
});

test('gate outcomes are tallied by reason', () => {
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [
      candidate({
        verdicts: [verdict('standard', 0.9, true, allHigh)],
        gate: { passed: true, reason: 'gate_passed' },
      }),
      candidate({
        verdicts: [verdict('standard', 0.9, true, allHigh)],
        gate: { passed: false, reason: 'criterion_floor', failed_criterion: 'disclosure' },
      }),
      candidate({
        verdicts: [verdict('standard', 0.9, true, allHigh)],
        gate: { passed: false, reason: 'criterion_floor', failed_criterion: 'grounding' },
      }),
      candidate({
        verdicts: [verdict('standard', 0.9, true, allHigh)],
        gate: { passed: false, reason: 'jury_not_majority' },
      }),
    ],
  });
  assert.equal(s.gate.passed, 1);
  assert.equal(s.gate.failed, 3);
  assert.equal(s.gate.pass_rate, 0.25);
  assert.deepEqual(s.gate.reasons, { gate_passed: 1, criterion_floor: 2, jury_not_majority: 1 });
  assert.deepEqual(s.gate.failed_criterion, { disclosure: 1, grounding: 1 });
});

test('a criterion no judge scored is unscored, not a failure', () => {
  // Absence is not a zero — librarian_lesson_gate refuses such a panel rather
  // than floor-failing it, so the stats must not report it as a floor failure.
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [
      candidate({
        verdicts: [verdict('standard', 0.9, true, { grounding: 0.9, scope_accuracy: 0.9, generality: 0.9 })],
      }),
    ],
  });
  assert.equal(s.criteria.disclosure.unscored, 1);
  assert.equal(s.criteria.disclosure.floor_fail, 0);
  assert.equal(s.criteria.disclosure.floor_pass, 0);
  assert.equal(s.criteria.disclosure.pass_rate, null);
});

test('pass rate denominators exclude unscored candidates', () => {
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [
      candidate({ verdicts: [verdict('standard', 0.9, true, allHigh)] }),
      candidate({
        verdicts: [verdict('standard', 0.9, true, { ...allHigh, disclosure: 0.5 })],
      }),
      candidate({
        verdicts: [verdict('standard', 0.9, true, { grounding: 0.9 })],
      }),
    ],
  });
  // 3 candidates, one did not score disclosure: 1 of 2 scored ones pass.
  assert.equal(s.criteria.disclosure.unscored, 1);
  assert.equal(s.criteria.disclosure.pass_rate, 0.5);
});

test('an empty batch reports zeroes rather than dividing by zero', () => {
  const s = computeStats({ rubric: RUBRIC, candidates: [] });
  assert.equal(s.n, 0);
  assert.equal(s.gate.pass_rate, null);
  assert.equal(s.criteria.disclosure.pass_rate, null);
  assert.ok(Number.isFinite(s.transform.attempted));
});

test('every rubric criterion appears in the output, even one never scored', () => {
  const s = computeStats({ rubric: RUBRIC, candidates: [] });
  assert.deepEqual(Object.keys(s.criteria).sort(), ['disclosure', 'generality', 'grounding', 'scope_accuracy']);
  assert.equal(s.criteria.disclosure.min_pass, 0.9);
  assert.equal(s.criteria.grounding.min_pass, 0.7);
});

test('rates are rounded to four places so a report is readable', () => {
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [
      candidate({ verdicts: [verdict('standard', 0.9, true, allHigh)] }),
      candidate({ verdicts: [verdict('standard', 0.9, true, allHigh)] }),
      candidate({
        verdicts: [verdict('standard', 0.9, true, { ...allHigh, disclosure: 0.1 })],
      }),
    ],
  });
  assert.equal(s.criteria.disclosure.pass_rate, 0.6667);
});

test('transform outcomes are bucketed by prefix, not by equality', () => {
  // librarian_lesson_transform_one never returns a bare 'proposed'.
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [
      candidate({ transform_outcome: 'proposed:01M4PD9CBE2F2QTH6D5690K1W7' }),
      candidate({ transform_outcome: 'proposed:01M4PD9CBE2F2QTH6D5690K1W8:unscoped' }),
      candidate({ transform_outcome: 'declined:schema_invalid' }),
      candidate({ transform_outcome: 'declined:no_resolution' }),
      candidate({ transform_outcome: 'skipped:seen' }),
      candidate({ transform_outcome: 'skipped:unscoped_cap' }),
      candidate({ transform_outcome: 'unavailable' }),
    ],
  });
  assert.equal(s.transform.attempted, 7);
  assert.equal(s.transform.proposed, 2);
  assert.equal(s.transform.declined, 2);
  assert.equal(s.transform.skipped, 2);
  assert.equal(s.transform.unavailable, 1);
});

test('a parked candidate still counts as proposed', () => {
  const s = computeStats({
    rubric: RUBRIC,
    candidates: [candidate({ transform_outcome: 'proposed:01M4PD9CBE2F2QTH6D5690K1W8:unscoped' })],
  });
  assert.equal(s.transform.proposed, 1);
  assert.equal(s.transform.declined, 0);
});
