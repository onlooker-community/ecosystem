import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';
import { derivePending } from '../../scripts/lib/derive-pending-applies-to.mjs';

// Drives the same candidate corpus through two independent validation
// mechanisms and asserts they agree:
//
//   1. librarian_lesson_validate_candidate (bash + jq), the runtime gate —
//      ajv is unavailable at runtime because installed marketplace plugins
//      ship no node_modules (ADR-005), so this is a hand-written mirror.
//   2. ajv against the vendored lesson-evidence and lesson-applies-to
//      sub-schemas, the contract the jq rules are meant to mirror.
//
// The jq rules and the vendored schemas have been proven able to disagree
// in both directions (a jq-too-loose direction and a jq-too-strict
// direction), so this is not a redundant check against the drift-guard in
// lesson-schema-drift.test.mjs, which only confirms the vendored files
// themselves are present, valid JSON, and pinned to the right provenance —
// it never exercises the jq rules against them.
//
// The vendored evidence schema declares `format: "date-time"` on
// observed_at. ajv ignores unknown formats without the ajv-formats package,
// which is deliberately not a dependency here (see ADR-005 and the F4
// review note) — validity for that field comes entirely from the sibling
// `pattern` keyword, which ajv always enforces regardless of format
// support. `strict: false` only silences the resulting "unknown format
// ignored" warning; it does not weaken the comparison.

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const SCHEMA_DIR = join(REPO_ROOT, 'plugins', 'librarian', 'schema');
const VALIDATE_LIB = join(REPO_ROOT, 'plugins', 'librarian', 'scripts', 'lib', 'librarian-lesson-validate.sh');

const evidenceSchema = JSON.parse(readFileSync(join(SCHEMA_DIR, 'lesson-evidence.subschema.json'), 'utf8'));
const appliesToSchema = JSON.parse(readFileSync(join(SCHEMA_DIR, 'lesson-applies-to.subschema.json'), 'utf8'));

const ajv = new Ajv({ strict: false, allErrors: true, logger: false });
const validateEvidence = ajv.compile(evidenceSchema);
const validateAppliesTo = ajv.compile(appliesToSchema);

// The pending-state counterpart, local and deliberately not upstream. jq's
// transform-side validator is paired with THIS schema; the confirmed-side one
// stays paired with the vendored contract above. That is what keeps agreement
// total on both sides instead of leaving `unscoped` as a documented hole.
const appliesToPendingSchema = JSON.parse(
  readFileSync(join(SCHEMA_DIR, 'lesson-applies-to-pending.local.schema.json'), 'utf8'),
);
const validateAppliesToPending = ajv.compile(appliesToPendingSchema);

// True when the local pending schema accepts the applies_to half, paired with
// jqAccepts(candidate) the way schemaAccepts is paired with the confirmed one.
function pendingSchemaAccepts(candidate) {
  return validateEvidence(candidate.evidence) && validateAppliesToPending(candidate.applies_to);
}

// True when both vendored sub-schemas accept their half of the candidate.
// Only these two fields are covered by a vendored schema — claim, rationale,
// and the versions-keys-subset-of-stack cross-field rule are jq-only checks
// with no schema counterpart (JSON Schema cannot express the latter), so the
// corpus below always holds those fixed at a schema-satisfying value and
// varies only the fields the two vendored sub-schemas actually constrain.
function schemaAccepts(candidate) {
  return validateEvidence(candidate.evidence) && validateAppliesTo(candidate.applies_to);
}

// Shells out to the real runtime gate rather than reimplementing its logic,
// so this test tracks the actual function, not a description of it.
function jqAccepts(candidate, fn = 'librarian_lesson_validate_candidate') {
  const result = spawnSync('bash', ['-c', `source '${VALIDATE_LIB}' && ${fn} "$CANDIDATE_JSON"`], {
    env: { ...process.env, CANDIDATE_JSON: JSON.stringify(candidate) },
    encoding: 'utf8',
  });
  return result.status === 0;
}

function baseCandidate() {
  return {
    claim: 'Vitest 4 cannot import vite/module-runner on Vite 5',
    rationale: 'vite/module-runner ships in Vite 6; Vitest 4 assumes it exists.',
    evidence: {
      artifact_ids: ['01KZ45MKAM734ZS7JK24D2DK0R'],
      session_ids: ['sess-1'],
      project_key: '6a7678979e31',
      observed_at: '2026-08-03T15:59:48Z',
      resolution: 'Pin vitest to 3.x until Vite 6 lands.',
    },
    applies_to: {
      stack: ['vite'],
      scope: { kind: 'versioned', versions: { vite: '<6' } },
      file_patterns: [],
      task_kinds: [],
    },
  };
}

function withEvidence(overrides) {
  const candidate = baseCandidate();
  candidate.evidence = { ...candidate.evidence, ...overrides };
  return candidate;
}

function withAppliesTo(overrides) {
  const candidate = baseCandidate();
  candidate.applies_to = { ...candidate.applies_to, ...overrides };
  return candidate;
}

function withRange(range) {
  return withAppliesTo({ scope: { kind: 'versioned', versions: { vite: range } } });
}

function assertAgree(name, candidate, expected) {
  const jq = jqAccepts(candidate);
  const schema = schemaAccepts(candidate);
  assert.equal(jq, schema, `${name}: jq=${jq} schema=${schema} disagree`);
  assert.equal(jq, expected, `${name}: expected ${expected}, jq validator said ${jq}`);
}

describe('lesson validator / vendored schema agreement', () => {
  it('agree on a well-formed baseline candidate', () => {
    assertAgree('baseline', baseCandidate(), true);
  });

  // ONL-108: a commit-mined lesson has no session. Both mechanisms must agree
  // that an empty list is valid and an empty string is not.
  it('agree that no session ids is accepted', () => {
    assertAgree('empty session_ids', withEvidence({ session_ids: [] }), true);
  });

  it('agree that an empty session id is rejected', () => {
    assertAgree('blank session id', withEvidence({ session_ids: [''] }), false);
  });

  it('agree that an extra evidence property is rejected (additionalProperties: false)', () => {
    assertAgree('extra evidence key', withEvidence({ confidence: 0.9 }), false);
  });

  it('agree that an empty string in stack is rejected (minLength: 1 on items)', () => {
    assertAgree('empty stack entry', withAppliesTo({ stack: ['vite', ''] }), false);
  });

  it('agree that a non-string in file_patterns is rejected (items type: string)', () => {
    assertAgree('non-string file_patterns entry', withAppliesTo({ file_patterns: [123] }), false);
  });

  it('agree that a leading-zero lower bound is accepted (>=05)', () => {
    assertAgree('leading-zero range', withRange('>=05'), true);
  });

  it('agree that an extra applies_to property is rejected (additionalProperties: false)', () => {
    assertAgree('extra applies_to key', withAppliesTo({ extra: true }), false);
  });

  it('agree that a non-string in task_kinds is rejected (items type: string)', () => {
    assertAgree('non-string task_kinds entry', withAppliesTo({ task_kinds: [true] }), false);
  });

  const rangeCorpus = [
    ['<6', true],
    ['>=4', true],
    ['>=4 <6', true],
    ['^5.4.21', false],
    ['~5', false],
    ['5.x', false],
    ['>=0', false],
    ['>=05', true],
  ];

  for (const [range, expected] of rangeCorpus) {
    it(`agree on range "${range}" (expect ${expected ? 'accept' : 'reject'})`, () => {
      assertAgree(`range ${range}`, withRange(range), expected);
    });
  }
});

describe('confirmed validator', () => {
  it('agrees with the schema on a well-formed version_independent candidate', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = {
      kind: 'version_independent',
      justification: 'git aborts checkout on a dirty tree regardless of version.',
    };
    assert.equal(jqAccepts(candidate, 'librarian_lesson_validate_confirmed'), true);
    assert.equal(schemaAccepts(candidate), true);
  });

  it('agrees with the schema in rejecting an empty justification', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = { kind: 'version_independent', justification: '' };
    assert.equal(jqAccepts(candidate, 'librarian_lesson_validate_confirmed'), false);
    assert.equal(schemaAccepts(candidate), false);
  });

  it('still refuses version_independent through the transform validator', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = {
      kind: 'version_independent',
      justification: 'git aborts checkout on a dirty tree regardless of version.',
    };
    // The schema permits this branch; the transform's gate deliberately does not.
    assert.equal(schemaAccepts(candidate), true);
    assert.equal(jqAccepts(candidate), false);
  });
});

describe('unscoped is a pending-only shape', () => {
  const unscoped = () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = { kind: 'unscoped' };
    return candidate;
  };

  it('the transform validator and the local pending schema agree it is accepted', () => {
    assert.equal(jqAccepts(unscoped()), true);
    assert.equal(pendingSchemaAccepts(unscoped()), true);
  });

  it('the vendored pool schema rejects it, so it can never be a pool shape', () => {
    assert.equal(schemaAccepts(unscoped()), false);
  });

  it('the confirmed validator refuses it, so it can never leave the queue', () => {
    assert.equal(jqAccepts(unscoped(), 'librarian_lesson_validate_confirmed'), false);
  });

  it('the local pending schema refuses version_independent, so a model cannot mint it', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = {
      kind: 'version_independent',
      justification: 'holds regardless of version',
    };
    assert.equal(pendingSchemaAccepts(candidate), false);
  });

  it('agrees that unscoped carrying versions is rejected on both sides', () => {
    const candidate = baseCandidate();
    candidate.applies_to.scope = { kind: 'unscoped', versions: { vite: '<6' } };
    assert.equal(jqAccepts(candidate), false);
    assert.equal(pendingSchemaAccepts(candidate), false);
  });
});

describe('lesson-contract 2.2.0 shapes', () => {
  const noStack = () => {
    const c = baseCandidate();
    c.applies_to = { stack: [], scope: { kind: 'no_stack' }, file_patterns: [], task_kinds: [], topics: ['testing'] };
    return c;
  };
  const observed = (extra = {}) =>
    withEvidence({
      observed_on: { vite: { version: '5.4.21', source: 'lockfile', basis: 'session_commit' } },
      unresolved: [],
      ...extra,
    });

  it('the pending schema is exactly the derivation of the vendored one', () => {
    assert.deepEqual(appliesToPendingSchema, derivePending(appliesToSchema));
  });

  it('agree that a no_stack candidate with topics is accepted', () => {
    assertAgree('no_stack', noStack(), true);
    assert.equal(jqAccepts(noStack(), 'librarian_lesson_validate_confirmed'), true);
    assert.equal(pendingSchemaAccepts(noStack()), true);
  });

  it('agree that an empty stack under versioned is rejected', () => {
    assertAgree('empty stack versioned', withAppliesTo({ stack: [] }), false);
  });

  it('agree that no_stack beside a non-empty stack is rejected', () => {
    assertAgree('no_stack with stack', withAppliesTo({ scope: { kind: 'no_stack' } }), false);
  });

  it('agree that topics on a with-stack candidate are accepted', () => {
    assertAgree('topics', withAppliesTo({ topics: ['bundling'] }), true);
  });

  it('agree that an empty topic is rejected', () => {
    assertAgree('empty topic', withAppliesTo({ topics: [''] }), false);
  });

  it('agree that observed_on and unresolved are accepted', () => {
    assertAgree('observed', observed(), true);
  });

  it('agree that an observation with a flavor is accepted', () => {
    assertAgree(
      'flavor',
      observed({ observed_on: { vite: { version: '20200816', source: 'probe', basis: 'machine', flavor: 'bsd' } } }),
      true,
    );
  });

  for (const [name, obs] of [
    ['an unknown source', { version: '1.0.0', source: 'guess', basis: 'head' }],
    ['a truncated source', { version: '1.0.0', source: 'lock', basis: 'head' }],
    ['a non-string source', { version: '1.0.0', source: 7, basis: 'head' }],
    ['an unknown basis', { version: '1.0.0', source: 'lockfile', basis: 'today' }],
    ['an empty version', { version: '', source: 'lockfile', basis: 'head' }],
    ['an extra observation key', { version: '1.0.0', source: 'lockfile', basis: 'head', note: 'x' }],
    ['a missing basis', { version: '1.0.0', source: 'lockfile' }],
  ]) {
    it(`agree that ${name} is rejected`, () => {
      assertAgree(name, observed({ observed_on: { vite: obs } }), false);
    });
  }

  // JSON Schema can't express these, so jq alone enforces them, mirroring the
  // contract's ingest rules in onlooker apps/api/src/lessons/rules.ts.
  it('jq refuses an observed_on key outside stack', () => {
    const c = observed({ observed_on: { react: { version: '18.2.0', source: 'manifest', basis: 'head' } } });
    assert.equal(schemaAccepts(c), true);
    assert.equal(jqAccepts(c), false);
  });

  it('jq refuses an unresolved entry outside stack', () => {
    const c = observed({ unresolved: ['Sentry'] });
    assert.equal(schemaAccepts(c), true);
    assert.equal(jqAccepts(c), false);
  });

  it('jq refuses an entry both observed and unresolved', () => {
    const c = observed({ unresolved: ['vite'] });
    assert.equal(schemaAccepts(c), true);
    assert.equal(jqAccepts(c), false);
  });

  it('the pending schema refuses unscoped beside an empty stack', () => {
    const c = noStack();
    c.applies_to.scope = { kind: 'unscoped' };
    assert.equal(pendingSchemaAccepts(c), false);
    assert.equal(jqAccepts(c), false);
  });
});
