// The guard that would have caught ONL-175 three times over.
//
// A bare `Release-As: 0.9.0` footer on 39b3bba (2026-09-24) is applied to every
// component whenever release-please scans far enough back to see it, which it
// does whenever the root cannot be anchored to a real tag. That drove the root
// ecosystem version from 0.61.10 to 0.9.0 in September (#378), and again from
// 0.71.2 to 0.9.0 in October (#444) — and 0.9.0 is BELOW every real release, so
// the marketplace propagated it to disk and installs could never move forward.
//
// Both occurrences were caught by a human reading a release diff. Each shipped.
//
// The invariant here is the one that makes the damage unambiguous: the root
// version must never sit below the highest released tag. That is true on a
// release PR (where the version is a pending bump ABOVE the highest tag) and on
// main (where it equals one), so it has no false-positive shape — and it fires
// on exactly the state that strands installs.
//
// Comparison is numeric per component, never lexical. 0.9.0 vs 0.71.1 is the
// whole bug: lexically "0.9.0" > "0.71.1" because '9' > '7', which is precisely
// why a string compare would have declared the downgrade healthy.

import assert from 'node:assert/strict';
import test from 'node:test';

import { checkReleaseAnchor } from '../../scripts/lint/check-release-anchor.mjs';

const TAGS = ['ecosystem-v0.70.7', 'ecosystem-v0.71.0', 'ecosystem-v0.71.1'];

/** All three carriers agreeing on one version, the healthy shape. */
const agreed = (v) => ({ pluginVersion: v, packageVersion: v, manifestVersion: v });

test('a version equal to the highest tag is anchored and fine', () => {
  const r = checkReleaseAnchor({ ...agreed('0.71.1'), tags: TAGS });
  assert.deepEqual(r.findings, []);
  assert.equal(r.ok, true);
});

test('a version above the highest tag is a pending release, not a fault', () => {
  // This is what every release PR looks like: the bump is written before the
  // tag exists. A check that failed here would fire on every release.
  const r = checkReleaseAnchor({ ...agreed('0.72.0'), tags: TAGS });
  assert.deepEqual(r.findings, []);
  assert.equal(r.ok, true);
});

test('a version below the highest tag is reported', () => {
  const r = checkReleaseAnchor({ ...agreed('0.9.0'), tags: TAGS });
  assert.equal(r.ok, false);
  assert.equal(r.findings.length, 1);
  assert.match(r.findings[0], /0\.9\.0/);
  assert.match(r.findings[0], /0\.71\.1/);
});

test('comparison is numeric, not lexical — the actual ONL-175 shape', () => {
  // Lexically "0.9.0" > "0.71.1" because '9' > '7'. A string compare declares
  // the downgrade healthy, which is the one way this check could ship broken
  // and look fine.
  const r = checkReleaseAnchor({ ...agreed('0.9.0'), tags: ['ecosystem-v0.71.1'] });
  assert.equal(r.ok, false);
});

test('a two-digit patch is not read as smaller than a one-digit one', () => {
  // The mirror-image lexical trap: "0.70.10" < "0.70.9" as strings.
  const r = checkReleaseAnchor({
    ...agreed('0.70.10'),
    tags: ['ecosystem-v0.70.9'],
  });
  assert.deepEqual(r.findings, []);
});

test('the highest tag is found regardless of listing order', () => {
  const shuffled = ['ecosystem-v0.71.1', 'ecosystem-v0.9.0', 'ecosystem-v0.70.7'];
  const r = checkReleaseAnchor({ ...agreed('0.9.0'), tags: shuffled });
  assert.equal(r.ok, false);
  assert.match(r.findings[0], /0\.71\.1/);
});

test('plugin.json disagreeing with package.json is reported', () => {
  const r = checkReleaseAnchor({
    pluginVersion: '0.72.0',
    packageVersion: '0.71.1',
    manifestVersion: '0.72.0',
    tags: TAGS,
  });
  assert.equal(r.ok, false);
  assert.ok(r.findings.some((f) => /disagree/i.test(f)));
});

test('the manifest disagreeing is reported too', () => {
  const r = checkReleaseAnchor({
    pluginVersion: '0.72.0',
    packageVersion: '0.72.0',
    manifestVersion: '0.9.0',
    tags: TAGS,
  });
  assert.equal(r.ok, false);
  assert.ok(r.findings.some((f) => /disagree/i.test(f)));
});

test('plugin.json is the version compared against tags', () => {
  // It is the file release-please writes via extra-files and the one the
  // plugin system reads, so it is the one that strands an install.
  const r = checkReleaseAnchor({
    pluginVersion: '0.9.0',
    packageVersion: '0.9.0',
    manifestVersion: '0.9.0',
    tags: TAGS,
  });
  assert.ok(r.findings.some((f) => /plugin\.json/.test(f)));
});

test('no tags at all is a setup error, never a quiet pass', () => {
  // The vacuous-gate shape. actions/checkout does not fetch tags by default,
  // so a check that returned ok on an empty tag list would report success in
  // CI forever while verifying nothing.
  const r = checkReleaseAnchor({ ...agreed('0.9.0'), tags: [] });
  assert.equal(r.ok, false);
  assert.equal(r.cannotVerify, true);
  assert.ok(r.findings.some((f) => /no ecosystem-v\* tags/i.test(f)));
});

test('tags for other components are ignored', () => {
  // The repo tags every plugin in the same namespace.
  const r = checkReleaseAnchor({
    ...agreed('0.71.1'),
    tags: ['tribunal-v1.8.0', 'librarian-v0.23.0', 'ecosystem-v0.71.1'],
  });
  assert.deepEqual(r.findings, []);
});

test('only-other-component tags still count as unverifiable', () => {
  const r = checkReleaseAnchor({
    ...agreed('0.71.1'),
    tags: ['tribunal-v1.8.0', 'librarian-v0.23.0'],
  });
  assert.equal(r.cannotVerify, true);
  assert.equal(r.ok, false);
});

test('a malformed version is reported rather than silently compared', () => {
  const r = checkReleaseAnchor({ ...agreed('not-a-version'), tags: TAGS });
  assert.equal(r.ok, false);
  assert.ok(r.findings.some((f) => /not-a-version/.test(f)));
});
