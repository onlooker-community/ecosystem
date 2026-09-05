import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const ROLLUP = join(REPO_ROOT, 'scripts', 'hook-rollup.mjs');

const SID = 'sess-under-test';

function scaffold() {
  const root = mkdtempSync(join(tmpdir(), 'hook-rollup-'));
  return {
    root,
    health: join(root, 'hook-health.jsonl'),
    events: join(root, 'onlooker-events.jsonl'),
  };
}

function writeLines(path, records) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${records.map((r) => JSON.stringify(r)).join('\n')}\n`);
}

function health(hook, hookEvent, durationMs, { sid = SID, toolName = null, status = 'success' } = {}) {
  return {
    timestamp: '2026-09-05T12:00:00Z',
    hook,
    status,
    duration_ms: durationMs,
    error: null,
    session_id: sid,
    hook_event: hookEvent,
    tool_name: toolName,
  };
}

function event(eventType, { sid = SID } = {}) {
  return { event_type: eventType, session_id: sid, timestamp: '2026-09-05T12:00:00Z', payload: {} };
}

function run(s, ...args) {
  const r = spawnSync('node', [ROLLUP, SID, '--health', s.health, '--events', s.events, ...args], {
    encoding: 'utf8',
    env: { ...process.env, ONLOOKER_DIR: s.root },
  });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

// One SessionStart fire, one session.start event: consistent, nothing nested.
function cleanSession() {
  const s = scaffold();
  writeLines(s.health, [
    health('session-start-tracker', 'SessionStart', 120),
    health('tool-sequence-tracker', 'PreToolUse', 40, { toolName: 'Edit' }),
    health('tool-history-tracker', 'PostToolUse', 60, { toolName: 'Edit' }),
  ]);
  writeLines(s.events, [event('session.start')]);
  return s;
}

describe('hook-rollup', () => {
  it('reports per-hook n/p50 and a per-event sum of medians', () => {
    const s = scaffold();
    writeLines(s.health, [
      health('tool-sequence-tracker', 'PreToolUse', 40, { toolName: 'Edit' }),
      health('tool-sequence-tracker', 'PreToolUse', 60, { toolName: 'Edit' }),
      health('tool-history-tracker', 'PostToolUse', 100, { toolName: 'Edit' }),
      health('session-start-tracker', 'SessionStart', 120),
    ]);
    writeLines(s.events, [event('session.start')]);

    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /tool-sequence-tracker/);
    assert.match(r.stdout, /per-event total/);
  });

  it('ignores records belonging to other sessions', () => {
    const s = scaffold();
    writeLines(s.health, [
      health('session-start-tracker', 'SessionStart', 120),
      health('tool-history-tracker', 'PostToolUse', 999, { sid: 'someone-else' }),
    ]);
    writeLines(s.events, [event('session.start')]);

    const r = run(s, '--json');
    assert.equal(r.code, 0, r.stderr);
    const report = JSON.parse(r.stdout);
    assert.equal(report.records, 1);
  });

  // The ecosystem-449.27 signature: many SessionStart fires filed under one
  // session while the event log shows a single session.start. Those extra fires
  // belonged to nested `claude -p` sessions.
  it('fails loudly when hook fires exceed events (mis-attributed nesting)', () => {
    const s = scaffold();
    const fires = Array.from({ length: 12 }, () => health('session-start-tracker', 'SessionStart', 120));
    writeLines(s.health, fires);
    writeLines(s.events, [event('session.start')]);

    const r = run(s);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /contaminat/i);
    assert.match(r.stderr, /11/); // 12 fires - 1 event - 0 compactions
  });

  it('does not flag excess fires that compactions explain', () => {
    const s = scaffold();
    // 3 SessionStart fires, 1 session.start event, 2 compactions.
    // source=compact suppresses the emit, so this is legitimate.
    writeLines(s.health, [
      health('session-start-tracker', 'SessionStart', 120),
      health('session-start-tracker', 'SessionStart', 120),
      health('session-start-tracker', 'SessionStart', 120),
    ]);
    writeLines(s.events, [event('session.start'), event('session.compact'), event('session.compact')]);

    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
  });

  it('reports contamination in the json report too', () => {
    const s = scaffold();
    writeLines(s.health, [
      health('session-start-tracker', 'SessionStart', 120),
      health('session-start-tracker', 'SessionStart', 120),
    ]);
    writeLines(s.events, [event('session.start')]);

    const r = run(s, '--json');
    assert.equal(r.code, 1);
    const report = JSON.parse(r.stdout);
    assert.equal(report.contamination.contaminated, true);
    assert.equal(report.contamination.unexplained_excess, 1);
  });

  it('still prints the table under --allow-contaminated, exiting 0', () => {
    const s = scaffold();
    writeLines(s.health, [
      health('session-start-tracker', 'SessionStart', 120),
      health('session-start-tracker', 'SessionStart', 120),
    ]);
    writeLines(s.events, [event('session.start')]);

    const r = run(s, '--allow-contaminated');
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /session-start-tracker/);
    assert.match(r.stderr, /contaminat/i); // still warns
  });

  it('skips the contamination check when the event log is absent', () => {
    const s = cleanSession();
    const r = run(s, '--events', join(s.root, 'no-such-events.jsonl'));
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /skipped|unavailable/i);
  });

  it('lists ecosystem hooks that produced no records as unsampled', () => {
    const s = cleanSession();
    const r = run(s);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /unsampled/i);
    assert.match(r.stdout, /worktree-tracker/);
  });

  it('counts null durations separately rather than treating them as zero', () => {
    const s = scaffold();
    writeLines(s.health, [
      health('turn-tracker', 'UserPromptSubmit', 80),
      health('turn-tracker', 'UserPromptSubmit', null),
    ]);
    writeLines(s.events, [event('session.start')]);

    const r = run(s, '--json');
    assert.equal(r.code, 0, r.stderr);
    const report = JSON.parse(r.stdout);
    const row = report.rows.find((x) => x.hook === 'turn-tracker');
    assert.equal(row.n, 2);
    assert.equal(row.nulls, 1);
    assert.equal(row.p50, 80);
  });

  // A session id that matches nothing produced a clean bill of health: zero
  // fires minus zero events is zero excess. A typo must not read as healthy.
  it('exits 2 when no records match the session id', () => {
    const s = cleanSession();
    const r = spawnSync('node', [ROLLUP, 'no-such-session', '--health', s.health, '--events', s.events], {
      encoding: 'utf8',
    });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /no records/i);
  });

  it('names the id-prefix trap when nothing matches', () => {
    const s = cleanSession();
    const r = spawnSync('node', [ROLLUP, SID.slice(0, 6), '--health', s.health, '--events', s.events], {
      encoding: 'utf8',
    });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /full session id|prefix/i);
  });

  it('exits 2 when the health log does not exist', () => {
    const s = scaffold();
    writeLines(s.events, [event('session.start')]);
    const r = run(s, '--health', join(s.root, 'missing.jsonl'));
    assert.equal(r.code, 2);
  });
});
