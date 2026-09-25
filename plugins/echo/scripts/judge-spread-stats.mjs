// Statistics behind echo's drift_threshold (ONL-102).
//
// echo classifies drift by comparing a STORED single judge sample against a
// FRESH single judge sample. So the quantity that should set drift_threshold is
// |delta| between two independent samples of identical content -- not the
// standard deviation of scores, and not a number anyone picked.
//
// Pure: takes samples in, returns statistics out, touches nothing. The
// expensive half (actually calling the judge 30 times) lives in
// measure-judge-spread.sh, so these numbers can be tested exhaustively without
// spending a single token.

const MIN_SAMPLES = 4;

// Ceiling on disjoint-pair enumeration. 2M runs in about a second; the next
// sample count up from there is several minutes and reads as a hang.
const MAX_PAIRS = 2_000_000;

/** n choose k, iteratively so it stays exact for the sizes here. */
function choose(n, k) {
  if (k < 0 || k > n) return 0;
  let result = 1;
  for (let i = 1; i <= k; i += 1) {
    result = (result * (n - k + i)) / i;
  }
  return Math.round(result);
}

/**
 * Round to 4 decimals, matching what echo-stop-gate.sh does to DELTA.
 *
 * Without this, 0.85 - 0.8 reports as 0.050000000000000044 and every
 * percentile in the output carries a tail of float noise.
 */
export function round4(x) {
  return Math.round(x * 10000) / 10000;
}

/** Every unordered pair's absolute difference: C(n,2) values. */
export function pairwiseAbsDeltas(scores) {
  const out = [];
  for (let i = 0; i < scores.length; i += 1) {
    for (let j = i + 1; j < scores.length; j += 1) {
      out.push(round4(Math.abs(scores[i] - scores[j])));
    }
  }
  return out;
}

/**
 * Nearest-rank percentile.
 *
 * Deliberately not interpolating: judge scores land on round values like 0.80
 * and 0.85, and interpolation would report a threshold that no observation
 * supports. Nearest-rank always returns a delta that actually occurred.
 */
export function percentile(xs, p) {
  if (xs.length === 0) return Number.NaN;
  const sorted = [...xs].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  const clamped = Math.min(Math.max(rank, 1), sorted.length);
  return sorted[clamped - 1];
}

export function median(xs) {
  const sorted = [...xs].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/** Every combination of `k` indices drawn from `pool`, as arrays of indices. */
function combinations(pool, k) {
  if (k === 0) return [[]];
  if (pool.length < k) return [];
  const [head, ...rest] = pool;
  const withHead = combinations(rest, k - 1).map((c) => [head, ...c]);
  return [...withHead, ...combinations(rest, k)];
}

/**
 * |delta| between the medians of every pair of DISJOINT k-subsets.
 *
 * A median-of-k evaluation consumes k fresh samples, so two independent
 * median-of-k evaluations are two disjoint k-subsets. Allowing them to share a
 * sample would compare an evaluation partly against itself and understate the
 * spread -- which would make N-sampling look better than it is, the one error
 * that would invalidate the whole exercise.
 *
 * Each unordered pair is counted once: of two disjoint subsets, exactly one
 * contains the smaller minimum index, so requiring a[0] < b[0] de-duplicates.
 *
 * Note on confidence: the pairs are disjoint WITHIN a pair, so each delta is an
 * honest independent-vs-independent comparison and the estimator is unbiased.
 * They are not independent OF EACH OTHER, though, since they are drawn from the
 * same n samples. So the effective sample size behind a percentile is far below
 * the pair count, and the interval around it is wider than the count suggests.
 */
export function disjointMedianPairDeltas(scores, k) {
  const n = scores.length;
  if (n < 2 * k) return [];

  // Pair count is C(n,k) * C(n-k,k) / 2, and it explodes: N=10 gives 126 pairs
  // for k=5, N=19 gives 11,639,628. Enumerating that is indistinguishable from
  // a hang, and `--samples 20` is an entirely reasonable thing to try. Count
  // first, refuse loudly, rather than appearing to freeze.
  const pairCount = (choose(n, k) * choose(n - k, k)) / 2;
  if (pairCount > MAX_PAIRS) {
    throw new Error(
      `too many pairs: ${n} samples at k=${k} is ${pairCount.toLocaleString()} disjoint pairs, over the ${MAX_PAIRS.toLocaleString()} cap — measure with fewer samples per file, or raise the cap knowingly`,
    );
  }

  const indices = Array.from({ length: n }, (_, i) => i);
  const out = [];
  for (const a of combinations(indices, k)) {
    const remaining = indices.filter((i) => !a.includes(i));
    for (const b of combinations(remaining, k)) {
      if (a[0] > b[0]) continue;
      out.push(round4(Math.abs(median(a.map((i) => scores[i])) - median(b.map((i) => scores[i])))));
    }
  }
  return out;
}

function summarize(deltas) {
  return {
    pairCount: deltas.length,
    p50: percentile(deltas, 50),
    p95: percentile(deltas, 95),
    max: deltas.length ? Math.max(...deltas) : Number.NaN,
  };
}

/**
 * @param {Record<string, number[]>} samples  file path -> judge scores
 */
export function judgeSpreadStats(samples) {
  const perFile = {};
  const pooled = { single: [], median3: [], median5: [] };

  for (const [path, scores] of Object.entries(samples)) {
    if (scores.length < MIN_SAMPLES) {
      throw new Error(
        `${path}: ${scores.length} samples, need at least ${MIN_SAMPLES} — a percentile off fewer is not worth reporting`,
      );
    }
    const single = pairwiseAbsDeltas(scores);
    const median3 = disjointMedianPairDeltas(scores, 3);
    const median5 = disjointMedianPairDeltas(scores, 5);

    perFile[path] = {
      n: scores.length,
      scores: [...scores],
      min: Math.min(...scores),
      max: Math.max(...scores),
      distinct: [...new Set(scores)].sort((a, b) => a - b),
      single: summarize(single),
      median3: summarize(median3),
      median5: summarize(median5),
    };

    pooled.single.push(...single);
    pooled.median3.push(...median3);
    pooled.median5.push(...median5);
  }

  return {
    perFile,
    overall: {
      single: summarize(pooled.single),
      median3: summarize(pooled.median3),
      median5: summarize(pooled.median5),
    },
  };
}

// CLI: measure-judge-spread.sh pipes its raw samples.json through here.
// Kept behind an entrypoint check so importing the module for tests runs
// nothing.
if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  const { readFileSync } = await import('node:fs');
  const path = process.argv[2];
  if (!path) {
    process.stderr.write('usage: judge-spread-stats.mjs <samples.json>\n');
    process.exit(2);
  }
  const raw = JSON.parse(readFileSync(path, 'utf8'));
  process.stdout.write(`${JSON.stringify(judgeSpreadStats(raw.samples), null, 2)}\n`);
}
