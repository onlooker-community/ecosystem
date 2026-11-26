#!/usr/bin/env node
// The versions a lesson's stack entries were observed on. See
// librarian-lesson-observe.sh for the contract. Reads git objects only, so a
// working-tree edit made after the session is never mistaken for what the
// session ran on.
//
// Usage: node librarian-lesson-observe.mjs <onlooker_dir> <project_key> <observed_at> <stack_json>

import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const GIT_TIMEOUT_MS = 5000;

// Lowercase, then drop a trailing ".js" or "js": "Vite.js" and "vite" are
// the same entry, as are "Next.js" and "next".
export const normalize = (name) => name.toLowerCase().replace(/\.?js$/, '') || name.toLowerCase();

const git = (repo, args) => {
  try {
    return execFileSync('git', ['-C', repo, ...args], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: GIT_TIMEOUT_MS,
    });
  } catch {
    return null;
  }
};

const parseJson = (text) => {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
};

// project_key -> repo_root, from each librarian store's manifest.json.
export function registeredRepos(onlookerDir) {
  const repos = new Map();
  const root = path.join(onlookerDir, 'librarian');
  let keys = [];
  try {
    keys = readdirSync(root);
  } catch {
    return repos;
  }
  for (const key of keys) {
    let manifest = null;
    try {
      manifest = parseJson(readFileSync(path.join(root, key, 'manifest.json'), 'utf8'));
    } catch {}
    if (manifest?.repo_root) repos.set(key, manifest.repo_root);
  }
  return repos;
}

// The last commit at or before the session, or HEAD when there is none.
export function commitAt(repo, observedAt) {
  const sha = git(repo, ['rev-list', '-1', `--before=${observedAt}`, 'HEAD'])?.trim();
  if (sha) return { sha, basis: 'session_commit' };
  const head = git(repo, ['rev-parse', 'HEAD'])?.trim();
  return head ? { sha: head, basis: 'head' } : null;
}

// A later source never replaces an exact one with a declared range.
const RANK = { manifest: 1, lockfile: 2, mise: 2, workflow: 2, component: 2 };

function miseTools(text) {
  const tools = {};
  let inTools = false;
  for (const line of text.split('\n')) {
    if (/^\s*\[/.test(line)) {
      inTools = /^\s*\[tools\]\s*$/.test(line);
      continue;
    }
    const m = inTools && line.match(/^\s*"?([^"=\s]+)"?\s*=\s*(.+)$/);
    if (!m) continue;
    // "aqua:BurntSushi/ripgrep" -> "ripgrep"
    const name = m[1].split(/[:/]/).pop();
    const version = m[2]
      .replace(/["[\]]/g, '')
      .split(',')[0]
      .trim();
    if (version) tools[name] = version;
  }
  return tools;
}

const cache = new Map();

// normalized name -> {version, source}, from the manifests at one commit.
// componentsOnly restricts it to what a repo says about itself, which is all
// another project's repo is consulted for.
export function indexAt(repo, sha, { componentsOnly = false } = {}) {
  const cacheKey = `${repo}\0${sha}\0${componentsOnly}`;
  if (cache.has(cacheKey)) return cache.get(cacheKey);

  const index = new Map();
  const put = (name, version, source) => {
    if (!name || !version) return;
    const key = normalize(name);
    const prev = index.get(key);
    if (!prev || RANK[source] > RANK[prev.source]) index.set(key, { version, source });
  };
  const show = (p) => git(repo, ['show', `${sha}:${p}`]);

  const files = (git(repo, ['ls-tree', '-r', '--name-only', sha]) ?? '')
    .split('\n')
    .filter((p) => p && !p.split('/').includes('node_modules') && p.split('/').length <= 6);

  for (const p of files) {
    const base = path.posix.basename(p);
    if (base === 'plugin.json' && p.includes('.claude-plugin/')) {
      const j = parseJson(show(p));
      put(j?.name, j?.version, 'component');
    } else if (base === 'package.json') {
      const j = parseJson(show(p));
      put(j?.name, j?.version, 'component');
      if (componentsOnly) continue;
      for (const field of ['dependencies', 'devDependencies', 'peerDependencies']) {
        for (const [n, v] of Object.entries(j?.[field] ?? {})) put(n, v, 'manifest');
      }
    } else if (componentsOnly) {
    } else if (base === 'package-lock.json') {
      const j = parseJson(show(p));
      for (const [k, v] of Object.entries(j?.packages ?? {})) {
        if (k.startsWith('node_modules/')) put(k.replace(/^.*node_modules\//, ''), v?.version, 'lockfile');
      }
    } else if (base === 'pnpm-lock.yaml') {
      for (const m of (show(p) ?? '').matchAll(/^\s{2}'?\/?((?:@[^/@\s]+\/)?[^@\s'/]+)@(\d[^(:'\s]*)/gm)) {
        put(m[1], m[2], 'lockfile');
      }
    } else if (base === 'uv.lock') {
      for (const m of (show(p) ?? '').matchAll(/^name = "([^"]+)"\nversion = "([^"]+)"/gm)) {
        put(m[1], m[2], 'lockfile');
      }
    } else if (base === 'Gemfile.lock') {
      // Only the four-space lines under a specs: block are resolved gems;
      // six-space lines are their dependency constraints.
      for (const m of (show(p) ?? '').matchAll(/^ {4}([A-Za-z0-9_.-]+) \(([^)]+)\)$/gm)) {
        put(m[1], m[2], 'lockfile');
      }
    } else if (base === 'mise.toml' || base === '.mise.toml') {
      for (const [n, v] of Object.entries(miseTools(show(p) ?? ''))) put(n, v, 'mise');
    } else if (/^\.github\/workflows\/[^/]+\.ya?ml$/.test(p)) {
      for (const m of (show(p) ?? '').matchAll(/uses:\s*([^@\s]+)@([^\s#]+)/g)) {
        const action = m[1].split('/')[1] ?? m[1];
        put(action.replace(/-action$/, ''), m[2].replace(/^v/, ''), 'workflow');
      }
    }
  }

  cache.set(cacheKey, index);
  return index;
}

export function observe({ onlookerDir, projectKey, observedAt, stack, probe = true }) {
  const observed_on = {};
  const unresolved = [];
  const repos = registeredRepos(onlookerDir);

  const own = repos.get(projectKey);
  const ownAt = own ? commitAt(own, observedAt) : null;
  const ownIndex = ownAt ? indexAt(own, ownAt.sha) : new Map();

  const others = [];
  for (const [key, repo] of repos) {
    if (key === projectKey || repo === own) continue;
    const at = commitAt(repo, observedAt);
    if (at) others.push({ index: indexAt(repo, at.sha, { componentsOnly: true }), basis: at.basis });
  }

  for (const entry of stack) {
    // The stack is model-written JSON; a non-string must not throw away the
    // entries that are fine.
    if (typeof entry !== 'string') {
      unresolved.push(entry);
      continue;
    }
    const key = normalize(entry);
    const hit = ownIndex.get(key);
    if (hit) {
      observed_on[entry] = { version: hit.version, source: hit.source, basis: ownAt.basis };
      continue;
    }
    const elsewhere = others.find((o) => o.index.get(key));
    if (elsewhere) {
      const c = elsewhere.index.get(key);
      observed_on[entry] = { version: c.version, source: 'component', basis: elsewhere.basis };
      continue;
    }
    const probed = probe ? probeTool(key) : null;
    if (probed) {
      observed_on[entry] = probed;
      continue;
    }
    unresolved.push(entry);
  }

  return { observed_on, unresolved };
}

const PROBE_TIMEOUT_MS = 2000;

// Only these are ever run. Each is the tool's own version flag, so probing
// one can't do anything else. The machine is read when the transform runs,
// not when the session did, which is why every probe says basis "machine".
const PROBES = {
  bash: ['bash', ['--version']],
  git: ['git', ['--version']],
  node: ['node', ['--version']],
  npm: ['npm', ['--version']],
  jq: ['jq', ['--version']],
  sqlite: ['sqlite3', ['--version']],
  sqlite3: ['sqlite3', ['--version']],
  awk: ['awk', ['--version']],
  grep: ['grep', ['--version']],
  sed: ['sed', ['--version']],
  // uname -r is the Darwin kernel, not the macOS release; sw_vers is the release.
  macos: ['sw_vers', ['-productVersion']],
  darwin: ['uname', ['-r']],
  linux: ['uname', ['-r']],
};

// awk, grep and sed differ between BSD and GNU builds in ways a lesson can
// depend on, and a version number alone doesn't say which.
const FLAVORED = new Set(['awk', 'grep', 'sed']);

function probeTool(key) {
  const probe = PROBES[key];
  if (!probe) return null;
  let out;
  try {
    out = execFileSync(probe[0], probe[1], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: PROBE_TIMEOUT_MS,
    });
  } catch {
    return null;
  }
  const line = out.split('\n').find((l) => l.trim()) ?? '';
  const version = line.match(/\d+\.\d+(?:\.\d+)?|\d{8}/)?.[0];
  if (!version) return null;
  const result = { version, source: 'probe', basis: 'machine' };
  // BSD grep says "(BSD grep, GNU compatible)", so BSD is checked first.
  if (FLAVORED.has(key)) result.flavor = line.includes('BSD') ? 'bsd' : line.includes('GNU') ? 'gnu' : 'bsd';
  return result;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [onlookerDir, projectKey, observedAt, stackJson] = process.argv.slice(2);
  const stack = parseJson(stackJson);
  if (onlookerDir && projectKey && observedAt && Array.isArray(stack)) {
    process.stdout.write(`${JSON.stringify(observe({ onlookerDir, projectKey, observedAt, stack }))}\n`);
  }
}
