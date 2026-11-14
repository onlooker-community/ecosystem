// Tests for scripts/lint/check-agents-mirror.mjs. Each test writes an AGENTS.md
// and a CLAUDE.md into a temp dir, runs the linter against it as a subprocess,
// and asserts on exit code + emitted output.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const LINTER = join(REPO_ROOT, 'scripts', 'lint', 'check-agents-mirror.mjs');

const START = '<!-- mirror-of-claude-md:start -->';
const END = '<!-- mirror-of-claude-md:end -->';

function fixture(agents, claude) {
  const root = mkdtempSync(join(tmpdir(), 'check-mirror-'));
  writeFileSync(join(root, 'AGENTS.md'), agents);
  writeFileSync(join(root, 'CLAUDE.md'), claude);
  const r = spawnSync('node', [LINTER, '--root', root], { encoding: 'utf8' });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

const BODY = ['## Layout', '', 'Rule one.', '', '## Conventions', '', '- Rule two.'].join('\n');

function agentsWith(body, { head = '# Agent Instructions\n\nCodex-only preamble.\n', tail = '' } = {}) {
  return `${head}\n${START}\n${body}\n${END}\n${tail}`;
}

function claudeWith(body) {
  return `# Project Agent Instructions\n\n${body}\n`;
}

describe('check-agents-mirror', () => {
  it('passes when the mirrored section matches CLAUDE.md after its title', () => {
    const r = fixture(agentsWith(BODY, { tail: '\nCodex block.\n' }), claudeWith(BODY));
    assert.equal(r.code, 0, r.stderr);
  });

  it('fails on a drifted line, naming it in both files', () => {
    const drifted = BODY.replace('Rule one.', 'Rule one, stale.');
    const r = fixture(agentsWith(drifted), claudeWith(BODY));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /AGENTS\.md:\d+/);
    assert.match(r.stderr, /CLAUDE\.md:\d+/);
    assert.match(r.stderr, /Rule one, stale\./);
  });

  it('fails on a rule CLAUDE.md has and AGENTS.md lacks', () => {
    const r = fixture(agentsWith(BODY), claudeWith(`${BODY}\n- Rule three.`));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /Rule three\./);
  });

  it('ignores differences inside a generated block', () => {
    const block = (hash) =>
      `<!-- BEGIN BEADS INTEGRATION hash:${hash} -->\ngenerated ${hash}\n<!-- END BEADS INTEGRATION -->`;
    const r = fixture(agentsWith(`${BODY}\n\n${block('aaa')}`), claudeWith(`${BODY}\n\n${block('bbb')}`));
    assert.equal(r.code, 0, r.stderr);
  });

  it('still fails when text moves out of a generated block', () => {
    const block = '<!-- BEGIN BEADS INTEGRATION -->\ngenerated\n<!-- END BEADS INTEGRATION -->';
    const r = fixture(agentsWith(`${BODY}\n\n${block}\n\nAfter.`), claudeWith(`${BODY}\n\n${block}`));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /After\./);
  });

  it('fails when AGENTS.md has no mirror markers', () => {
    const r = fixture(`# Agent Instructions\n\n${BODY}\n`, claudeWith(BODY));
    assert.equal(r.code, 1);
    assert.match(r.stderr, /mirror-of-claude-md:start/);
  });
});
