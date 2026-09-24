import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  disjointMedianPairDeltas,
  judgeSpreadStats,
  median,
  pairwiseAbsDeltas,
  percentile,
} from '../../plugins/echo/scripts/judge-spread-stats.mjs';

// The statistics behind ONL-102. echo classifies drift by comparing a stored
// single judge sample against a fresh single judge sample, so the quantity that
// decides drift_threshold is |delta| between two INDEPENDENT samples of the
// same content. Everything here computes that, for single samples and for
// median-of-k evaluations.

describe('pairwiseAbsDeltas', () => {
  it('returns every unordered pair once', () => {
    // C(3,2) = 3 pairs, not 6 ordered ones and not 9 including self-pairs.
    assert.deepEqual(pairwiseAbsDeltas([0.8, 0.85, 0.9]).sort(), [0.05, 0.05, 0.1]);
  });

  it('rounds away float error so 0.85 - 0.8 is 0.05', () => {
    // Bare subtraction gives 0.050000000000000044, which would make every
    // reported percentile an unreadable tail of digits.
    assert.deepEqual(pairwiseAbsDeltas([0.8, 0.85]), [0.05]);
  });

  it('is zero throughout when the judge never moved', () => {
    assert.deepEqual(pairwiseAbsDeltas([0.8, 0.8, 0.8]), [0, 0, 0]);
  });
});

describe('percentile', () => {
  it('uses nearest-rank, so p95 of ten values is the tenth', () => {
    // ceil(0.95 * 10) = 10 -> index 9. Interpolating between ranks would
    // invent a threshold no observation supports.
    const xs = [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1];
    assert.equal(percentile(xs, 95), 0.1);
  });

  it('p50 of ten values is the fifth', () => {
    const xs = [0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1];
    assert.equal(percentile(xs, 50), 0.05);
  });

  it('sorts its input rather than trusting the caller', () => {
    assert.equal(percentile([0.3, 0.1, 0.2], 100), 0.3);
  });
});

describe('median', () => {
  it('averages the middle two when the count is even', () => {
    assert.equal(median([1, 2, 3, 4]), 2.5);
  });

  it('takes the middle one when the count is odd', () => {
    assert.equal(median([3, 1, 2]), 2);
  });
});

describe('disjointMedianPairDeltas', () => {
  // A median-of-k evaluation consumes k fresh samples, so two independent
  // median-of-k evaluations are two DISJOINT k-subsets. Pairs that share a
  // sample would compare an evaluation partly against itself and understate
  // the spread -- the exact error that would make N-sampling look better than
  // it is.
  it('pairs disjoint 5-subsets of 10, giving C(10,5)/2 pairs', () => {
    const scores = Array.from({ length: 10 }, (_, i) => i / 10);
    assert.equal(disjointMedianPairDeltas(scores, 5).length, 126);
  });

  it('pairs disjoint 3-subsets of 10, giving C(10,3)*C(7,3)/2 pairs', () => {
    const scores = Array.from({ length: 10 }, (_, i) => i / 10);
    assert.equal(disjointMedianPairDeltas(scores, 3).length, 2100);
  });

  it('never pairs a subset with one that shares a sample', () => {
    // Six samples split 0.1/0.9, k=3: C(6,3)/2 = 10 disjoint pairs. Any triple
    // holding two or more 0.1s has median 0.1 and its complement necessarily
    // has median 0.9, so every pair separates fully. A implementation that
    // allowed overlap would produce pairs with delta 0 and break this.
    const deltas = disjointMedianPairDeltas([0.1, 0.1, 0.1, 0.9, 0.9, 0.9], 3);
    assert.equal(deltas.length, 10);
    assert.deepEqual([...new Set(deltas)], [0.8]);
  });

  it('returns nothing when the samples cannot fill two disjoint subsets', () => {
    assert.deepEqual(disjointMedianPairDeltas([0.1, 0.2, 0.3], 2), []);
  });
});

describe('judgeSpreadStats', () => {
  const samples = {
    'a.md': [0.8, 0.85, 0.7, 0.9, 0.75, 0.8, 0.85, 0.7, 0.9, 0.8],
    'b.md': [0.6, 0.65, 0.6, 0.7, 0.6, 0.65, 0.6, 0.7, 0.65, 0.6],
  };

  it('reports each file separately, because spread may be a property of the file', () => {
    const stats = judgeSpreadStats(samples);
    assert.deepEqual(Object.keys(stats.perFile).sort(), ['a.md', 'b.md']);
    assert.equal(stats.perFile['a.md'].n, 10);
    assert.equal(stats.perFile['a.md'].min, 0.7);
    assert.equal(stats.perFile['a.md'].max, 0.9);
  });

  it('pools every file into the overall single-sample figure', () => {
    // 2 files x C(10,2) = 90 pairs. The threshold has to hold across the
    // watched set, not be fitted to one document.
    const stats = judgeSpreadStats(samples);
    assert.equal(stats.overall.single.pairCount, 90);
  });

  it('carries median-of-3 and median-of-5 arms alongside the single-sample one', () => {
    const stats = judgeSpreadStats(samples);
    for (const arm of ['single', 'median3', 'median5']) {
      assert.ok(Number.isFinite(stats.overall[arm].p95), `${arm} p95 should be a number`);
    }
  });

  it('shows median-of-5 spread no wider than single-sample spread', () => {
    // The whole premise of ONL-102's revised design: averaging away sampling
    // error is what makes a usable threshold possible at all. If this ever
    // fails, N-sampling is not the lever and the ADR is wrong.
    const stats = judgeSpreadStats(samples);
    assert.ok(
      stats.overall.median5.p95 <= stats.overall.single.p95,
      `median5 p95 ${stats.overall.median5.p95} should not exceed single p95 ${stats.overall.single.p95}`,
    );
  });

  it('collapses to zero spread when the judge is perfectly stable', () => {
    const stats = judgeSpreadStats({ 'stable.md': Array(10).fill(0.8) });
    assert.equal(stats.overall.single.p95, 0);
    assert.equal(stats.overall.median5.p95, 0);
  });

  it('rejects a file with too few samples rather than reporting a thin percentile', () => {
    assert.throws(() => judgeSpreadStats({ 'thin.md': [0.8, 0.9] }), /at least/i);
  });
});

describe('disjointMedianPairDeltas cost guard', () => {
  it('refuses a sample count whose pair enumeration would not finish', () => {
    // n=19, k=5 is C(19,5)*C(14,5)/2 = 11,639,628 pairs. Enumerating that
    // looks exactly like a hang, and --samples 20 is a plausible thing to try.
    const scores = Array.from({ length: 19 }, (_, i) => i / 19);
    assert.throws(() => disjointMedianPairDeltas(scores, 5), /too many pairs/i);
  });

  it('still allows the documented N=10 workflow', () => {
    const scores = Array.from({ length: 10 }, (_, i) => i / 10);
    assert.equal(disjointMedianPairDeltas(scores, 5).length, 126);
  });
});
