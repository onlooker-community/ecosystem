#!/usr/bin/env node
// Guards the vendored lesson sub-schemas against silent drift.
//
// plugins/librarian/schema/*.subschema.json are copied out of the
// published lesson contract (see PROVENANCE.json) because ajv is
// unavailable at runtime (ADR-005); the jq rules in
// librarian-lesson-validate.sh mirror these files by hand. This check
// only confirms the provenance pin and JSON validity survive edits — it
// cannot compare against the upstream schema until schema.onlooker.dev
// publishes lesson schemas.
//
// Exit codes:
//   0  no problems
//   1  provenance pin changed or a vendored file is missing/invalid

import { readFileSync } from 'node:fs';

const dir = 'plugins/librarian/schema';
let failures = 0;
const fail = (m) => {
  console.error(`check-lesson-schema: ${m}`);
  failures++;
};

try {
  const prov = JSON.parse(readFileSync(`${dir}/PROVENANCE.json`, 'utf8'));
  if (prov.schema_version !== 2) fail(`expected schema_version 2, got ${prov.schema_version}`);
  for (const f of ['lesson-evidence.subschema.json', 'lesson-applies-to.subschema.json']) {
    JSON.parse(readFileSync(`${dir}/${f}`, 'utf8'));
  }
} catch (err) {
  fail(err.message);
}

if (failures > 0) process.exit(1);
console.log('check-lesson-schema: ok');
