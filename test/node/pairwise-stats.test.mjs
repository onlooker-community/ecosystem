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

  // A pair with zero usable repeats (both ab and ba empty, or both missing) must
  // not be included in the denominator. Missing data is not measured failure --
  // following ONL-102's precedent, absorbing failures into a short sample count
  // can delete a whole analysis arm without saying so.
  it('excludes pairs with zero usable repeats from the rate denominator', () => {
    const r = crossAntisymmetry([
      { a: 'a', b: 'b', ab: ['better'], ba: ['worse'] },
      { a: 'a', b: 'c', ab: [], ba: [] },
    ]);
    // Only the first pair contributes: it is antisymmetric, so the rate is 1, not 0.5
    assert.equal(r, 1);
  });

  // Mismatched lengths (e.g., one order succeeded 2 times, the other 1 time)
  // must be handled by using only paired repeats where both orders have verdicts.
  it('uses only paired repeats when ab and ba lengths differ', () => {
    const r = crossAntisymmetry([
      { a: 'a', b: 'b', ab: ['better', 'better'], ba: ['worse'] },
    ]);
    // Only 1 paired repeat: ab[0]='better', ba[0]='worse' -- antisymmetric.
    // Rate is computed from the 1 paired repeat only, giving 1, not involving the longer array.
    assert.equal(r, 1);
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

  // A pair with zero usable repeats must not be included in the share denominator.
  // Missing data is not a failure to discriminate -- following ONL-102's precedent.
  it('excludes pairs with zero usable repeats from the share denominator', () => {
    const r = trueDiscrimination([
      { a: 'a', b: 'b', ab: ['better'], ba: ['worse'] },
      { a: 'a', b: 'c', ab: [], ba: [] },
    ]);
    // Only the first pair counts: it discriminates, so the share is 1, not 0.5
    assert.equal(r, 1);
  });

  // Mismatched lengths must be handled by using only paired repeats.
  it('uses only paired repeats when ab and ba lengths differ', () => {
    const r = trueDiscrimination([
      { a: 'a', b: 'b', ab: ['better', 'better'], ba: ['worse'] },
    ]);
    // Only 1 paired repeat: ab[0]='better', ba[0]='worse', consistent and
    // antisymmetric across that one repeat. Share is computed from the 1
    // paired repeat only, giving 1, not involving the longer array.
    assert.equal(r, 1);
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

  it('reports usable counts separately from attempted counts', () => {
    const bad = {
      ...doc,
      cross: [
        { a: 'a.md', b: 'b.md', ab: ['better', 'better'], ba: ['worse'] },
        { a: 'a.md', b: 'c.md', ab: [], ba: [] },
      ],
    };
    const s = pairwiseStats(bad);
    assert.equal(s.counts.cross_pairs, 2); // attempted
    assert.equal(s.counts.cross_pairs_usable, 1); // only first pair has usable repeats
    assert.equal(s.counts.repeats_dropped, 1); // one repeat in first pair is dropped
  });
});
