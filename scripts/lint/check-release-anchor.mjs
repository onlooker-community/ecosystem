#!/usr/bin/env node
// Guards the root ecosystem version against the downgrade that has now shipped
// twice (ONL-175).
//
// WHAT GOES WRONG. A bare `Release-As: 0.9.0` footer on 39b3bba (#375,
// 2026-09-24) is applied by release-please to EVERY component, not just the one
// the author meant. It only sees that commit when it scans far enough back,
// which it does whenever the root cannot be anchored to a real
// `ecosystem-v<version>` tag. Twice now the anchor was lost and the footer
// resurfaced:
//
//   #378 (2026-09-24)  0.61.10 -> 0.9.0, repaired by hand
//   #444 (2026-10-15)  0.71.2  -> 0.9.0, repaired by hand
//
// 0.9.0 is BELOW every real release, and the version does not stay on paper:
// release-please writes it to .claude-plugin/plugin.json via extra-files, the
// marketplace propagates that to disk, and an install already at 0.70.x or
// 0.71.x never moves forward again because 0.9.0 sorts lower. The always-on
// substrate every other plugin depends on gets pinned where no client accepts
// it.
//
// Both occurrences were noticed by a human reading a release diff, and both
// shipped before anyone noticed. Nothing in the repo looked for it.
//
// THE INVARIANT. The root version must never sit below the highest released
// `ecosystem-v*` tag. That holds in both legitimate states — on a release PR
// the version is a pending bump ABOVE the highest tag, and on main it equals
// one — so the check has no false-positive shape, and it fires on exactly the
// state that strands installs. Run on a release PR, it blocks the downgrade
// before merge rather than after.
//
// WHAT IT DELIBERATELY DOES NOT CATCH. The intermediate unanchored state is
// invisible here, and that is a property of the data rather than a gap in the
// check: after #440 wrote an untagged 0.71.2 while the highest tag was 0.71.1,
// the repo looked *identical* to a healthy pending release. Nothing
// distinguishes "bumped and never tagged" from "bumped, tag pending" at that
// moment. What this catches is the consequence, which is the part that does
// damage — and it catches it every time, on the release PR that proposes it.
//
// Comparison is numeric per component, never lexical. 0.9.0 vs 0.71.1 is the
// whole bug: lexically "0.9.0" > "0.71.1" because '9' > '7', so a string
// compare would declare the downgrade healthy. test/node/check-release-anchor.test.mjs
// pins that case and its mirror image (0.70.10 vs 0.70.9).
//
// Exit codes:
//   0  ok
//   1  the root version is below the highest released tag, or the three
//      carriers disagree
//   2  cannot verify (no ecosystem-v* tags visible) or setup/usage error
//
// Flags:
//   --root <path>   override the repo root
//   --json          machine-readable output

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const TAG_PREFIX = 'ecosystem-v';
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

/** Parse "x.y.z" into a comparable triple, or null when it is not one. */
function parse(version) {
  const m = SEMVER.exec(String(version ?? '').trim());
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

/** Numeric per-component compare. Returns <0, 0 or >0. */
function compare(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] - b[i];
  }
  return 0;
}

/**
 * The whole check, as a pure function over values the CLI gathers.
 *
 * Returns { ok, cannotVerify, findings, highestTag }.
 */
export function checkReleaseAnchor({ pluginVersion, packageVersion, manifestVersion, tags = [] }) {
  const findings = [];

  // The three carriers must agree before comparing anything: a disagreement
  // means one of them was written by something that did not write the others,
  // and which one is "the" version becomes a guess.
  const carriers = [
    ['.claude-plugin/plugin.json', pluginVersion],
    ['package.json', packageVersion],
    ['.release-please-manifest.json ["."]', manifestVersion],
  ];
  const distinct = [...new Set(carriers.map(([, v]) => v))];
  if (distinct.length > 1) {
    findings.push(
      `the three root version carriers disagree: ${carriers
        .map(([name, v]) => `${name}=${v}`)
        .join(
          ', ',
        )} — release-please writes all three together, so a split means one was edited by hand or a release half-applied`,
    );
  }

  // plugin.json is the one compared against tags: it is what extra-files
  // writes and what the plugin system reads, so it is the one that strands an
  // install.
  const current = parse(pluginVersion);
  if (!current) {
    findings.push(`.claude-plugin/plugin.json version is not semver-shaped: ${pluginVersion}`);
    return { ok: false, cannotVerify: false, findings, highestTag: null };
  }

  const released = tags
    .filter((t) => typeof t === 'string' && t.startsWith(TAG_PREFIX))
    .map((t) => ({ tag: t, v: parse(t.slice(TAG_PREFIX.length)) }))
    .filter((e) => e.v !== null);

  // Never a quiet pass. actions/checkout does not fetch tags by default, so a
  // check that returned ok on an empty list would report success in CI forever
  // while verifying nothing — the exact shape of a gate that passes
  // vacuously.
  if (released.length === 0) {
    findings.push(
      `no ${TAG_PREFIX}* tags are visible, so the root version cannot be checked against its releases — fetch tags (actions/checkout needs fetch-tags: true) rather than treating this as a pass`,
    );
    return { ok: false, cannotVerify: true, findings, highestTag: null };
  }

  released.sort((a, b) => compare(a.v, b.v));
  const highest = released[released.length - 1];

  if (compare(current, highest.v) < 0) {
    findings.push(
      `.claude-plugin/plugin.json is ${pluginVersion}, below the highest released tag ${highest.tag} — a downgrade. The marketplace propagates this version to disk, and an install at ${highest.tag.slice(TAG_PREFIX.length)} will never move forward because ${pluginVersion} sorts lower (ONL-175)`,
    );
  }

  return {
    ok: findings.length === 0,
    cannotVerify: false,
    findings,
    highestTag: highest.tag,
  };
}

// --- CLI -------------------------------------------------------------------

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

function gitTags(root) {
  const out = execFileSync('git', ['tag', '-l', `${TAG_PREFIX}*`], {
    cwd: root,
    encoding: 'utf8',
  });
  return out.split('\n').filter(Boolean);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  let root = resolve(join(dirname(fileURLToPath(import.meta.url)), '..', '..'));
  let asJson = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--root') root = resolve(argv[++i]);
    else if (argv[i] === '--json') asJson = true;
    else {
      process.stderr.write(`check-release-anchor: unknown argument ${argv[i]}\n`);
      process.exit(2);
    }
  }

  let result;
  try {
    result = checkReleaseAnchor({
      pluginVersion: readJson(join(root, '.claude-plugin', 'plugin.json')).version,
      packageVersion: readJson(join(root, 'package.json')).version,
      manifestVersion: readJson(join(root, '.release-please-manifest.json'))['.'],
      tags: gitTags(root),
    });
  } catch (err) {
    process.stderr.write(`check-release-anchor: ${err.message}\n`);
    process.exit(2);
  }

  if (asJson) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else if (result.ok) {
    process.stdout.write(`check-release-anchor: ok (root at or above ${result.highestTag})\n`);
  } else {
    for (const f of result.findings) process.stdout.write(`  ${f}\n`);
    process.stdout.write(`check-release-anchor: ${result.findings.length} finding(s)\n`);
  }

  if (result.cannotVerify) process.exit(2);
  process.exit(result.ok ? 0 : 1);
}
