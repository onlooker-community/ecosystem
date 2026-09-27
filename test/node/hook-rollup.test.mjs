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

function health(
  hook,
  hookEvent,
  durationMs,
  {
    sid = SID,
    toolName = null,
    status = 'success',
    runId = null,
    pluginName = 'ecosystem',
    pluginVersion = '0.63.0',
  } = {},
) {
  return {
    timestamp: '2026-09-05T12:00:00Z',
    hook,
    status,
    run_id: runId,
    duration_ms: durationMs,
    error: null,
    session_id: sid,
    hook_event: hookEvent,
    tool_name: toolName,
    plugin_name: pluginName,
    plugin_version: pluginVersion,
  };
}

// A start breadcrumb, as hook_health_register writes it (ecosystem-449.66).
// Deliberately carries no session_id, hook_event, or duration_ms: register runs
// before the hook reads stdin, so none of those are known yet. Fixtures that
// invented them would hide exactly the handling this file is testing.
function started(hook, runId, startMs = 1757073600000) {
  return {
    timestamp: '2026-09-05T12:00:00Z',
    hook,
    status: 'started',
    run_id: runId,
    start_ms: startMs,
    host_pid: 4242,
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
  it('reports per-hook n/p50 and a per-event cost, span beside sum', () => {
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
    assert.match(r.stdout, /per-event cost/);
    // Both columns are labeled, so a reader cannot mistake the sum for what the
    // session waited. This used to assert only that a heading existed.
    assert.match(r.stdout, /span/);
    assert.match(r.stdout, /sum/);

    // The sums themselves, which this test never pinned: PreToolUse takes the
    // median of [40, 60], the other two events have one sample each.
    const j = JSON.parse(run(s, '--json').stdout);
    assert.equal(j.per_event_total_ms.PreToolUse, 60);
    assert.equal(j.per_event_total_ms.PostToolUse, 100);
    assert.equal(j.per_event_total_ms.SessionStart, 120);

    // These fixtures carry no start breadcrumbs, so no span is computable at
    // all - and every record says so rather than reporting a zero-width span.
    assert.deepEqual(j.per_event_span_ms, {});
    assert.equal(j.span_unpaired, 4);
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

  // ecosystem-449.66. register now writes a start breadcrumb, so the log holds
  // two lines per fire. These pin that the extra line neither inflates the
  // latency stats nor trips the contamination guard.
  describe('start breadcrumbs (ecosystem-449.66)', () => {
    it('does not count a breadcrumb as a latency sample', () => {
      const s = scaffold();
      writeLines(s.health, [
        started('session-start-tracker', 'run-1'),
        health('session-start-tracker', 'SessionStart', 120, { runId: 'run-1' }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s, '--json');
      assert.equal(r.code, 0);
      const report = JSON.parse(r.stdout);
      // One fire, not two: n must count the terminal record only.
      assert.equal(report.records, 1);
      const row = report.rows.find((x) => x.hook === 'session-start-tracker');
      assert.equal(row.n, 1);
      // And no bogus group from the breadcrumb's absent hook_event.
      assert.equal(report.rows.length, 1);
    });

    it('does not let breadcrumbs trip the contamination guard', () => {
      const s = scaffold();
      // Two breadcrumbs plus two terminal records for one SessionStart fire
      // each. Counting breadcrumbs as fires would report excess and exit 1.
      writeLines(s.health, [
        started('session-start-tracker', 'run-1'),
        health('session-start-tracker', 'SessionStart', 100, { runId: 'run-1' }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s);
      assert.equal(r.code, 0);
      assert.doesNotMatch(r.stderr, /CONTAMINATED/);
    });

    it('reports a terminated run rather than burying it in the histogram', () => {
      const s = scaffold();
      writeLines(s.health, [
        started('librarian-session-end', 'run-1'),
        health('librarian-session-end', 'SessionEnd', 1502, {
          runId: 'run-1',
          status: 'terminated',
        }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s);
      assert.equal(r.code, 0);
      assert.match(r.stdout, /TERMINATED: 1 run\(s\) were killed/);
      // The duration is the deadline, and the output must say so rather than
      // letting 1502ms read as a slow-but-healthy run.
      assert.match(r.stdout, /deadlines, not workloads/);
    });

    it('reports a start with no terminal record as an orphan', () => {
      const s = scaffold();
      writeLines(s.health, [
        // Killed by SIGKILL: a breadcrumb and nothing else, since no trap ran.
        started('librarian-session-end', 'run-orphan'),
        started('session-start-tracker', 'run-1'),
        health('session-start-tracker', 'SessionStart', 100, { runId: 'run-1' }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s, '--json');
      assert.equal(r.code, 0);
      const report = JSON.parse(r.stdout);
      assert.equal(report.orphaned_starts.total, 1);
      assert.equal(report.orphaned_starts.by_hook['librarian-session-end'], 1);
      // The paired one must not be counted as orphaned.
      assert.equal(report.orphaned_starts.by_hook['session-start-tracker'], undefined);
    });

    it('does not invent orphans out of records written before run_id existed', () => {
      const s = scaffold();
      const legacy = { timestamp: '2026-08-01T12:00:00Z', hook: 'old-hook', status: 'started' };
      writeLines(s.health, [
        legacy,
        started('session-start-tracker', 'run-1'),
        health('session-start-tracker', 'SessionStart', 100, { runId: 'run-1' }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s, '--json');
      assert.equal(r.code, 0);
      // A breadcrumb with no run_id is unpairable in both directions. Calling it
      // orphaned would read an outage out of old data.
      assert.equal(JSON.parse(r.stdout).orphaned_starts.total, 0);
    });
  });

  // ------------------------------------------------------------------ versions
  //
  // ecosystem-9eg / ONL-21. A /clear mints a new session_id inside the SAME
  // process, so plugin code stays pinned at what the process started with while
  // every timestamp says post-release. A session that straddles a release mixes
  // two versions for one plugin, and a rollup that averages across them reports
  // a number belonging to neither.
  describe('plugin version attribution', () => {
    it('reports the versions a session actually ran', () => {
      const s = scaffold();
      writeLines(s.health, [
        started('session-start-tracker', 'run-1'),
        health('session-start-tracker', 'SessionStart', 100, { runId: 'run-1' }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s, '--json');
      assert.equal(r.code, 0);
      const report = JSON.parse(r.stdout);
      assert.deepEqual(report.versions.by_plugin.ecosystem, ['0.63.0']);
      assert.deepEqual(report.versions.skewed, []);
    });

    it('refuses a session that ran two versions of one plugin', () => {
      const s = scaffold();
      writeLines(s.health, [
        started('session-start-tracker', 'run-1'),
        health('session-start-tracker', 'SessionStart', 100, { runId: 'run-1', pluginVersion: '0.62.2' }),
        started('turn-tracker', 'run-2'),
        health('turn-tracker', 'UserPromptSubmit', 40, { runId: 'run-2', pluginVersion: '0.63.0' }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s, '--json');
      // Exits nonzero for the same reason contaminated data does: a measurement
      // that silently spans two versions is the defect, not a warning about it.
      assert.equal(r.code, 1);
      assert.match(r.stderr, /SKEW/);
      assert.match(r.stderr, /0\.62\.2/);
      assert.match(r.stderr, /0\.63\.0/);
    });

    it('still measures a skewed session when told to, bucketed per version', () => {
      const s = scaffold();
      writeLines(s.health, [
        started('session-start-tracker', 'run-1'),
        health('session-start-tracker', 'SessionStart', 100, { runId: 'run-1', pluginVersion: '0.62.2' }),
        started('turn-tracker', 'run-2'),
        health('turn-tracker', 'UserPromptSubmit', 40, { runId: 'run-2', pluginVersion: '0.63.0' }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s, '--allow-skewed', '--json');
      assert.equal(r.code, 0);
      const report = JSON.parse(r.stdout);
      assert.deepEqual(report.versions.skewed, ['ecosystem']);
      // Bucketing is what makes the refusal above non-destructive: excluding the
      // whole session would discard the measurement, and at this release cadence
      // the long sessions that carry the most samples are the likeliest to skew.
      assert.equal(report.versions.per_version['ecosystem@0.62.2'].records, 1);
      assert.equal(report.versions.per_version['ecosystem@0.63.0'].records, 1);
    });
  });

  // -------------------------------------------------------------------- spans
  //
  // per_event_total_ms sums per-hook medians, which is only the real cost if
  // hooks run one after another. They do not: the four PostToolUse hooks on one
  // Edit start within 12ms of each other. So the sum overstates what a session
  // actually waits by 2-3x, and it is the number the rollout budgets are stated
  // against - onlooker-8ud58k was filed at 1055-1275ms for an edit that cost
  // about 270ms of wall clock.
  describe('wall-clock span', () => {
    it('reports the span of overlapping hooks, not their sum', () => {
      const s = scaffold();
      const T = 1757073600000;
      writeLines(s.health, [
        started('session-start-tracker', 'run-1', T),
        health('session-start-tracker', 'SessionStart', 100, { runId: 'run-1' }),
        started('memory-recall-tracker', 'run-2', T + 5),
        health('memory-recall-tracker', 'SessionStart', 200, { runId: 'run-2' }),
        started('archivist-inject', 'run-3', T + 10),
        health('archivist-inject', 'SessionStart', 300, {
          runId: 'run-3',
          pluginName: 'archivist',
          pluginVersion: '0.7.6',
        }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s, '--json');
      assert.equal(r.code, 0);
      const report = JSON.parse(r.stdout);
      // Last to finish is archivist-inject at T+10+300; first to start is T.
      assert.equal(report.per_event_span_ms.SessionStart, 310);
      // The sum is kept, because a budget stated against it still needs reading.
      assert.equal(report.per_event_total_ms.SessionStart, 600);
    });

    it('treats a hook with no paired start as unmeasurable, not as zero', () => {
      const s = scaffold();
      const T = 1757073600000;
      writeLines(s.health, [
        started('session-start-tracker', 'run-1', T),
        health('session-start-tracker', 'SessionStart', 100, { runId: 'run-1' }),
        // No breadcrumb for this one, so its interval is unknown.
        health('memory-recall-tracker', 'SessionStart', 900, { runId: 'run-2' }),
      ]);
      writeLines(s.events, [event('session.start')]);
      const r = run(s, '--json');
      assert.equal(r.code, 0);
      const report = JSON.parse(r.stdout);
      // 900ms is excluded from the span rather than folded in at start 0, which
      // would have reported 900 and looked authoritative.
      assert.equal(report.per_event_span_ms.SessionStart, 100);
      assert.equal(report.span_unpaired, 1);
    });
  });
});
