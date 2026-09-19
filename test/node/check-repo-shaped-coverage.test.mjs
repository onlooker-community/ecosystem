import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const REGISTRY = join(REPO, 'scripts', 'lib', 'repo-shaped-inputs.json');

function registry() {
  return JSON.parse(readFileSync(REGISTRY, 'utf8'));
}

// Every array of strings where at least one entry looks like a glob. This is
// deliberately mechanical: the point is to notice keys nobody triaged, so it
// must not depend on knowing which ones matter.
function globKeys(obj, path = []) {
  const out = [];
  if (Array.isArray(obj)) {
    if (obj.some((v) => typeof v === 'string' && v.includes('*'))) out.push(path.join('.'));
    return out;
  }
  if (obj && typeof obj === 'object') {
    for (const [k, v] of Object.entries(obj)) out.push(...globKeys(v, [...path, k]));
  }
  return out;
}

function shippedGlobKeys() {
  const plugins = join(REPO, 'plugins');
  const found = [];
  for (const name of readdirSync(plugins)) {
    let cfg;
    try {
      cfg = JSON.parse(readFileSync(join(plugins, name, 'config.json'), 'utf8'));
    } catch {
      continue; // no config, or unreadable — other lints cover that
    }
    for (const key of globKeys(cfg)) found.push({ plugin: name, key });
  }
  return found;
}

// The guard this file exists for. A plugin shipping a new glob-bearing default
// must say whether it is an applicability signal, exactly as a new event type
// must be triaged into test/bus-coverage.json. Silence is the failure mode
// ecosystem-449.15 describes: enabled, green, matching nothing, forever.
test('every glob-bearing config key is triaged as inclusion or excluded', () => {
  const reg = registry();
  const inclusionKeys = new Set(Object.values(reg.inclusion).map((v) => v.config_key));
  const excludedKeys = new Set(Object.keys(reg.excluded));

  const untriaged = shippedGlobKeys().filter(({ key }) => !inclusionKeys.has(key) && !excludedKeys.has(key));

  assert.deepEqual(
    untriaged,
    [],
    `Untriaged glob-bearing config key(s). Add each to scripts/lib/repo-shaped-inputs.json — ` +
      `"inclusion" if a repo with no matches cannot host the plugin, "excluded" with a reason ` +
      `if it is a skip list. Found: ${JSON.stringify(untriaged)}`,
  );
});

test('registered inclusion keys actually exist in their plugin config', () => {
  // A registry entry naming a key that has been renamed away is worse than no
  // entry: it reports applicability from a value nothing reads.
  const reg = registry();
  for (const [plugin, entry] of Object.entries(reg.inclusion)) {
    const cfg = JSON.parse(readFileSync(join(REPO, 'plugins', plugin, 'config.json'), 'utf8'));
    const value = entry.config_key.split('.').reduce((o, k) => (o == null ? o : o[k]), cfg);
    assert.ok(
      Array.isArray(value) && value.length > 0,
      `${plugin}: ${entry.config_key} is missing or empty in plugins/${plugin}/config.json`,
    );
  }
});

test('every inclusion entry says why, so the judgment can be re-checked', () => {
  const reg = registry();
  for (const [plugin, entry] of Object.entries(reg.inclusion)) {
    assert.ok(
      typeof entry.why === 'string' && entry.why.length > 20,
      `${plugin}: inclusion entries need a "why" — the include/exclude call is a judgment, not a fact`,
    );
  }
});
