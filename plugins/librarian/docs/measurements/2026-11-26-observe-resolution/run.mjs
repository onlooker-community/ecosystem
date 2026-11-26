#!/usr/bin/env node
// Rollout step 2's measurement: how often Observe versions a stored
// candidate's stack. Reads the lesson store and the repos; writes only
// results.jsonl beside this file. No model call.
//
// Usage: node run.mjs [onlooker_dir] [concepts_file]
//   onlooker_dir   default: ~/.onlooker
//   concepts_file  default: concepts.txt beside this file
// Env: RESULTS_OUT=<path> writes results there instead of beside this file;
//   RESULTS_OUT=none writes nothing. Use it for a comparison run, such as an
//   empty concepts_file, so the committed results.jsonl stays untouched.

import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { observe } from '../../../scripts/lib/librarian-lesson-observe.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const onlookerDir = process.argv[2] ?? path.join(os.homedir(), '.onlooker');
const conceptsFile = process.argv[3] ?? path.join(here, 'concepts.txt');
const store = path.join(onlookerDir, 'librarian');
const concepts = new Set(
  readFileSync(conceptsFile, 'utf8')
    .split('\n')
    .map((l) => l.trim().toLowerCase())
    .filter(Boolean),
);

let nonString = 0;
const rows = [];
for (const key of readdirSync(store)) {
  let files = [];
  try {
    files = readdirSync(path.join(store, key, 'lessons/proposals')).filter((f) => f.endsWith('.json'));
  } catch {
    continue;
  }
  for (const f of files) {
    const p = JSON.parse(readFileSync(path.join(store, key, 'lessons/proposals', f), 'utf8'));
    const c = p.candidate ?? {};
    const raw = Array.isArray(c.applies_to?.stack) ? c.applies_to.stack : [];
    const stack = raw.filter((s) => typeof s === 'string');
    nonString += raw.length - stack.length;
    const observedAt = c.evidence?.observed_at;
    const projectKey = c.evidence?.project_key ?? key;
    const tools = stack.filter((s) => !concepts.has(s.toLowerCase()));
    const result = observedAt
      ? observe({ onlookerDir, projectKey, observedAt, stack: tools })
      : { observed_on: {}, unresolved: tools };
    rows.push({
      id: p.id,
      key: projectKey,
      stack,
      concepts: stack.filter((s) => concepts.has(s.toLowerCase())),
      observed_on: result.observed_on,
      unresolved: result.unresolved,
    });
  }
}
if (process.env.RESULTS_OUT !== 'none') {
  const out = process.env.RESULTS_OUT ?? path.join(here, 'results.jsonl');
  writeFileSync(out, `${rows.map((r) => JSON.stringify(r)).join('\n')}\n`);
}

const tally = (xs) =>
  xs.reduce((m, x) => {
    m[x] = (m[x] ?? 0) + 1;
    return m;
  }, {});
const outcome = (r) =>
  r.stack.length === 0
    ? 'empty_stack'
    : r.unresolved.length === 0 && Object.keys(r.observed_on).length === 0
      ? 'concepts_only'
      : r.unresolved.length === 0
        ? 'fully_resolved'
        : Object.keys(r.observed_on).length > 0
          ? 'partly'
          : 'none';
const entries = rows.flatMap((r) => Object.values(r.observed_on).map((o) => `${o.source}/${o.basis}`));

console.log(
  JSON.stringify(
    {
      candidates: rows.length,
      non_string_stack_elements: nonString,
      outcomes: tally(rows.map(outcome)),
      observed_by_source: tally(entries),
      top_unresolved: Object.entries(tally(rows.flatMap((r) => r.unresolved)))
        .sort((a, b) => b[1] - a[1])
        .slice(0, 25),
    },
    null,
    2,
  ),
);
