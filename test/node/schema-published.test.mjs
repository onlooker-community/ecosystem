import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { Ajv2020 } from 'ajv/dist/2020.js';
import _addFormats from 'ajv-formats';
import { buildCanonicalEvent } from '../../scripts/lib/onlooker-event.mjs';

// The runtime emitter is dependency-free and fails open (it never drops events
// in an installed plugin — see scripts/lib/onlooker-event.mjs). This test is the
// other half of that contract: it proves the emitter's output still conforms to
// the canonical schemas PUBLISHED at https://schema.onlooker.dev — the contract
// downstream consumers (the onlooker agent, the backend) actually validate
// against. Schema drift that would silently pass at runtime is caught here.
//
// Network-resilient: when the published endpoint is unreachable (offline dev,
// CI without egress) the test skips rather than failing red.

const addFormats = _addFormats.default ?? _addFormats;
const BASE = 'https://schema.onlooker.dev/schemas';

async function fetchJson(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status}`);
  return res.json();
}

// Representative events the emitter produces, paired with the payload schema
// file each event family maps to.
const SAMPLES = [
  {
    event_type: 'session.start',
    payloadFile: 'session.json',
    payload: { working_directory: '/tmp', git_branch: 'main' },
  },
  { event_type: 'session.prompt', payloadFile: 'session.json', payload: { turn_number: 2, input_summary: 'hello' } },
  { event_type: 'tool.shell.exec', payloadFile: 'tool.json', payload: { command: 'ls -la', exit_code: 0 } },
  {
    event_type: 'skill.invoked',
    payloadFile: 'skill.json',
    payload: { skill_name: 'commit', invocation_source: 'tool' },
  },
  { event_type: 'task.start', payloadFile: 'task.json', payload: { task_summary: 'implement the thing' } },
];

test('emitter output conforms to the published schemas at schema.onlooker.dev', async (t) => {
  let envelope;
  const payloadDocs = new Map();
  try {
    envelope = await fetchJson(`${BASE}/event.v1.json`);
    for (const file of new Set(SAMPLES.map((s) => s.payloadFile))) {
      payloadDocs.set(file, await fetchJson(`${BASE}/payload/${file}`));
    }
  } catch (err) {
    t.skip(`published schemas unreachable (${err.message}); skipping live-contract check`);
    return;
  }

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validateEnvelope = ajv.compile(envelope);

  const tmp = mkdtempSync(join(tmpdir(), 'onlooker-published-'));
  try {
    for (const sample of SAMPLES) {
      const event = buildCanonicalEvent({
        onlookerDir: tmp,
        plugin: 'onlooker',
        session_id: 'published-contract-test',
        event_type: sample.event_type,
        payload: sample.payload,
      });

      assert.ok(
        validateEnvelope(event),
        `published envelope rejected ${sample.event_type}: ${ajv.errorsText(validateEnvelope.errors)}`,
      );

      const def = payloadDocs.get(sample.payloadFile)?.$defs?.[sample.event_type];
      assert.ok(def, `published payload/${sample.payloadFile} has no $defs entry for ${sample.event_type}`);

      const validatePayload = ajv.compile(def);
      assert.ok(
        validatePayload(event.payload),
        `published payload schema rejected ${sample.event_type}: ${ajv.errorsText(validatePayload.errors)}`,
      );
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
