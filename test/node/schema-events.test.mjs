import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { validate } from '@onlooker-community/schema';
import {
  buildCanonicalEvent,
  mapHookInputToCanonical,
  mapSkillHookInput,
  mapTaskHookInput,
} from '../../scripts/lib/onlooker-event.mjs';

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

test('mapSkillHookInput maps UserPromptExpansion to skill.invoked', () => {
  const hookInput = loadFixture('user-prompt-expansion-skill.json');
  const tmpDir = join(REPO_ROOT, 'test/tmp-schema-events');
  const mapped = mapSkillHookInput(hookInput, {
    onlookerDir: tmpDir,
    plugin: 'onlooker',
  });

  assert.equal(mapped.valid, true);
  assert.equal(mapped.event.event_type, 'skill.invoked');
  assert.equal(mapped.event.payload.skill_name, 'code-review');
  assert.equal(mapped.event.payload.invocation_source, 'slash_command');
  assert.equal(validate(mapped.event).valid, true);
});

test('mapSkillHookInput maps PreToolUse Skill to skill.invoked', () => {
  const hookInput = loadFixture('pre-tool-use-skill.json');
  const tmpDir = join(REPO_ROOT, 'test/tmp-schema-events');
  const mapped = mapSkillHookInput(hookInput, {
    onlookerDir: tmpDir,
    plugin: 'onlooker',
  });

  assert.equal(mapped.valid, true);
  assert.equal(mapped.event.payload.invocation_source, 'tool');
  assert.equal(validate(mapped.event).valid, true);
});

test('mapTaskHookInput maps TaskCreated to task.start', () => {
  const hookInput = loadFixture('task-created.json');
  const tmpDir = join(REPO_ROOT, 'test/tmp-schema-events');
  const mapped = mapTaskHookInput(hookInput, {
    onlookerDir: tmpDir,
    plugin: 'onlooker',
  });

  assert.equal(mapped.valid, true);
  assert.equal(mapped.event.event_type, 'task.start');
  assert.equal(mapped.event.payload.task_summary, 'Implement user authentication');
  assert.equal(validate(mapped.event).valid, true);
});

test('mapTaskHookInput maps TaskCompleted to task.complete', () => {
  const hookInput = loadFixture('task-completed.json');
  const tmpDir = join(REPO_ROOT, 'test/tmp-schema-events');
  const prev = process.env.ONLOOKER_TASK_DURATION_MS;
  process.env.ONLOOKER_TASK_DURATION_MS = '1200';
  const mapped = mapTaskHookInput(hookInput, {
    onlookerDir: tmpDir,
    plugin: 'onlooker',
  });
  if (prev === undefined) delete process.env.ONLOOKER_TASK_DURATION_MS;
  else process.env.ONLOOKER_TASK_DURATION_MS = prev;

  assert.equal(mapped.valid, true);
  assert.equal(mapped.event.event_type, 'task.complete');
  assert.equal(mapped.event.payload.success, true);
  assert.equal(mapped.event.payload.duration_ms, 1200);
  assert.equal(mapped.event.payload.output_summary, 'Add login and signup endpoints');
  assert.equal(validate(mapped.event).valid, true);
});

test('mapHookInputToCanonical routes TaskCreated through task mapping', () => {
  const hookInput = loadFixture('task-created.json');
  const tmpDir = join(REPO_ROOT, 'test/tmp-schema-events');
  const mapped = mapHookInputToCanonical(hookInput, {
    onlookerDir: tmpDir,
    plugin: 'onlooker',
  });

  assert.equal(mapped.valid, true);
  assert.equal(mapped.event.event_type, 'task.start');
});

test('buildCanonicalEvent assigns monotonic file-backed sequence', () => {
  const tmpDir = mkdtempSync(join(tmpdir(), 'onlooker-seq-'));
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
  rmSync(tmpDir, { recursive: true, force: true });
});
