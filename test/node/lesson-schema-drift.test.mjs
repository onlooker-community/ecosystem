import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const dir = 'plugins/librarian/schema';
const read = (f) => JSON.parse(readFileSync(`${dir}/${f}`, 'utf8'));

test('provenance pins schema_version 2', () => {
  assert.equal(read('PROVENANCE.json').schema_version, 2);
});

test('applies_to keeps a two-branch scope union', () => {
  const appliesTo = read('lesson-applies-to.subschema.json');
  const branches = appliesTo.properties.scope.oneOf;
  assert.equal(branches.length, 2);
  assert.deepEqual(branches.map((b) => b.properties.kind.const).sort(), ['version_independent', 'versioned']);
});

test('the versioned branch requires at least one version and carries the range pattern', () => {
  const appliesTo = read('lesson-applies-to.subschema.json');
  const versioned = appliesTo.properties.scope.oneOf.find((b) => b.properties.kind.const === 'versioned');
  assert.equal(versioned.properties.versions.minProperties, 1);
  assert.ok(versioned.properties.versions.additionalProperties.pattern);
});

test('evidence requires a resolution', () => {
  assert.ok(read('lesson-evidence.subschema.json').required.includes('resolution'));
});
