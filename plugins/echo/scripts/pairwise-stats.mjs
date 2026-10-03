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
