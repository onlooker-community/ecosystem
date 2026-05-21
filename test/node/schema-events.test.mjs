import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validate } from '@onlooker-community/schema';
import { buildCanonicalEvent, mapHookInputToCanonical } from '../../scripts/lib/onlooker-event.mjs';

const REPO_ROOT = join(fileURLToPath(new URL('../..', import.meta.url)));
const FIXTURES = join(REPO_ROOT, 'test/fixtures/hook-inputs');

function loadFixture(name) {
  return JSON.parse(readFileSync(join(FIXTURES, name), 'utf8'));
}

test('mapHookInputToCanonical maps PostToolUse Read to tool.file.read', () => {
  const hookInput = loadFixture('post-tool-use-read.json');
  const tmpDir = join(REPO_ROOT, 'test/tmp-schema-events');
  const mapped = mapHookInputToCanonical(hookInput, {
    onlookerDir: tmpDir,
    plugin: 'onlooker',
  });

  assert.equal(mapped.valid, true);
  assert.equal(mapped.event.event_type, 'tool.file.read');
  assert.equal(mapped.event.schema_version, '1.0');
  assert.equal(mapped.event.payload.path, '/project/src/main.ts');
  assert.equal(validate(mapped.event).valid, true);
});

test('mapHookInputToCanonical maps PostToolUseFailure Bash to tool.shell.exec', () => {
  const hookInput = loadFixture('post-tool-use-failure-bash.json');
  const tmpDir = join(REPO_ROOT, 'test/tmp-schema-events');
  const mapped = mapHookInputToCanonical(hookInput, {
    onlookerDir: tmpDir,
    plugin: 'onlooker',
  });

  assert.equal(mapped.valid, true);
  assert.equal(mapped.event.event_type, 'tool.shell.exec');
  assert.equal(mapped.event.payload.command, 'npm test');
  assert.equal(mapped.event.payload.blocked, true);
  assert.equal(validate(mapped.event).valid, true);
});

test('buildCanonicalEvent assigns monotonic file-backed sequence', () => {
  const tmpDir = join(REPO_ROOT, 'test/tmp-schema-sequence-isolated');
  const a = buildCanonicalEvent({
    onlookerDir: tmpDir,
    plugin: 'onlooker',
    session_id: 'seq-test',
    event_type: 'tool.file.read',
    payload: { path: '/a' },
  });
  const b = buildCanonicalEvent({
    onlookerDir: tmpDir,
    plugin: 'onlooker',
    session_id: 'seq-test',
    event_type: 'tool.file.read',
    payload: { path: '/b' },
  });

  assert.equal(a.sequence, 0);
  assert.equal(b.sequence, 1);
});
