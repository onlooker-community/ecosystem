import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';

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
