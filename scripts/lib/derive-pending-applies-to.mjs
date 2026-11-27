#!/usr/bin/env node
// The pending-state applies_to schema is the vendored one with
// version_independent swapped for unscoped in the with_stack branch. Derived,
// never hand-edited, so it can't drift from the contract it shadows.
//
// Usage: node scripts/lib/derive-pending-applies-to.mjs --write
// then ./node_modules/.bin/biome format --write plugins/librarian/schema/*.json,
// since lint:check holds these files to biome layout (the test compares parsed
// JSON, so formatting never changes what it checks).

import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const UNSCOPED = {
  type: 'object',
  properties: { kind: { type: 'string', const: 'unscoped' } },
  required: ['kind'],
  additionalProperties: false,
};

export function derivePending(appliesTo) {
  const out = structuredClone(appliesTo);
  const withStack = out.anyOf.find((b) => b.title === 'with_stack');
  if (!withStack) throw new Error('vendored applies_to has no with_stack branch');
  const kinds = withStack.properties.scope.oneOf;
  const i = kinds.findIndex((k) => k.properties?.kind?.const === 'version_independent');
  if (i < 0) throw new Error('with_stack scope has no version_independent member');
  kinds[i] = UNSCOPED;
  return out;
}

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.join(here, '..', '..', 'plugins', 'librarian', 'schema');
if (process.argv.includes('--write')) {
  const vendored = JSON.parse(readFileSync(path.join(dir, 'lesson-applies-to.subschema.json'), 'utf8'));
  writeFileSync(
    path.join(dir, 'lesson-applies-to-pending.local.schema.json'),
    `${JSON.stringify(derivePending(vendored), null, 2)}\n`,
  );
}
