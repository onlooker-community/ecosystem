// Tests for scripts/lint/check-references.mjs. Each test stands up a
// scratch marketplace under BATS_TEST_TMPDIR-style isolation, runs the
// linter as a subprocess, and asserts on exit code + emitted output.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const LINTER = join(REPO_ROOT, 'scripts', 'lint', 'check-references.mjs');

function scaffold() {
  const root = mkdtempSync(join(tmpdir(), 'check-refs-'));
  mkdirSync(join(root, '.claude-plugin'), { recursive: true });
  return root;
}

function writeJson(p, data) {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, `${JSON.stringify(data, null, 2)}\n`);
}

function writeFile(p, text) {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, text);
}

function run(root, ...args) {
  const r = spawnSync('node', [LINTER, '--root', root, ...args], { encoding: 'utf8' });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

function writeSkill(root, pluginDir, fileRelPath, frontmatter, body = '') {
  const fmLines = ['---', ...Object.entries(frontmatter).map(([k, v]) => `${k}: ${v}`), '---', body];
  writeFile(join(root, pluginDir, fileRelPath), fmLines.join('\n'));
}

describe('check-references', () => {
  it('passes on an empty marketplace', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
    });
    const r = run(root);
    assert.equal(r.code, 0, r.stderr);
  });

  it('passes when skills and commands resolve and have frontmatter', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/think.md'],
      commands: ['./commands/commit.md'],
    });
    writeSkill(root, '.', 'skills/think.md', { name: 'think', description: 'muse' });
    writeSkill(root, '.', 'commands/commit.md', { name: 'commit', description: 'git commit' });
    const r = run(root);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /ok \(2 records/);
  });

  it('fails when a referenced path does not exist', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/missing.md'],
    });
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /points to a missing file/);
  });

  it('fails when a markdown file has no frontmatter', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/bare.md'],
    });
    writeFile(join(root, 'skills/bare.md'), 'no frontmatter here\n');
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /missing YAML frontmatter/);
  });

  it('fails when required frontmatter fields are missing', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/half.md'],
    });
    writeSkill(root, '.', 'skills/half.md', { name: 'half' });
    const r = run(root);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /missing required frontmatter field "description"/);
  });

  it('warns on body references to unknown slash commands', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/refs.md'],
    });
    writeSkill(
      root,
      '.',
      'skills/refs.md',
      { name: 'refs', description: 'x' },
      'Use the /nonexistent-command to bootstrap.',
    );
    const r = run(root);
    // Warnings alone do not fail by default.
    assert.equal(r.code, 0);
    assert.match(r.stderr, /unknown command "\/nonexistent-command"/);
  });

  it('does not warn on built-in slash commands', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/refs.md'],
    });
    writeSkill(root, '.', 'skills/refs.md', { name: 'refs', description: 'x' }, 'Run /help and /clear to reset.');
    const r = run(root);
    assert.equal(r.code, 0);
    assert.doesNotMatch(r.stderr, /unknown command/);
  });

  it('does not warn on commands declared elsewhere in the same marketplace', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [
        { name: 'ecosystem', source: './' },
        { name: 'archivist', source: './plugins/archivist' },
      ],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      commands: ['./commands/pin.md'],
      skills: ['./skills/uses-pin.md'],
    });
    writeSkill(root, '.', 'commands/pin.md', { name: 'pin', description: 'pin a memory' });
    writeSkill(
      root,
      '.',
      'skills/uses-pin.md',
      { name: 'uses-pin', description: 'x' },
      'Call /pin to mark an item as important.',
    );
    writeJson(join(root, 'plugins/archivist/.claude-plugin/plugin.json'), {
      name: 'archivist',
      version: '0.0.1',
    });
    const r = run(root);
    assert.equal(r.code, 0, r.stderr);
    assert.doesNotMatch(r.stderr, /unknown command/);
  });

  it('--strict turns warnings into errors', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/refs.md'],
    });
    writeSkill(root, '.', 'skills/refs.md', { name: 'refs', description: 'x' }, 'Run /nothing-here.');
    const r = run(root, '--strict');
    assert.equal(r.code, 1);
  });

  it('--plugin filters to a single plugin', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [
        { name: 'ecosystem', source: './' },
        { name: 'archivist', source: './plugins/archivist' },
      ],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/missing.md'],
    });
    writeJson(join(root, 'plugins/archivist/.claude-plugin/plugin.json'), {
      name: 'archivist',
      version: '0.0.1',
    });
    const r = run(root, '--plugin', 'archivist');
    // ecosystem has a broken path, but we filtered it out, so this passes.
    assert.equal(r.code, 0, r.stderr);
  });

  it('treats a directory entry as a tree of markdown files', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills'],
    });
    writeSkill(root, '.', 'skills/a.md', { name: 'a', description: 'x' });
    writeSkill(root, '.', 'skills/nested/b.md', { name: 'b', description: 'y' });
    const r = run(root);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /ok \(2 records/);
  });

  it('ignores slash-command-like strings inside backtick spans', () => {
    const root = scaffold();
    writeJson(join(root, '.claude-plugin', 'marketplace.json'), {
      name: 'tm',
      plugins: [{ name: 'ecosystem', source: './' }],
    });
    writeJson(join(root, '.claude-plugin', 'plugin.json'), {
      name: 'ecosystem',
      version: '0.0.1',
      skills: ['./skills/code.md'],
    });
    writeSkill(
      root,
      '.',
      'skills/code.md',
      { name: 'code', description: 'x' },
      'Inline `/should-not-warn` should be ignored.',
    );
    const r = run(root);
    assert.equal(r.code, 0);
    assert.doesNotMatch(r.stderr, /unknown command/);
  });
});
