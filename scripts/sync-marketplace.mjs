#!/usr/bin/env node
// Sync `.claude-plugin/marketplace.json` `plugins[].version` from each plugin's
// own `.claude-plugin/plugin.json`. This exists because release-please cannot
// reach above a sub-package's root to bump the shared marketplace manifest
// (it rejects `..` in extra-files paths). Run after release-please opens its
// PR, or in CI to fail on drift.
//
// Usage:
//   node scripts/sync-marketplace.mjs           # write changes
//   node scripts/sync-marketplace.mjs --check   # exit 1 if drift exists, no writes

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const marketplacePath = join(repoRoot, '.claude-plugin', 'marketplace.json');
const checkOnly = process.argv.includes('--check');

const marketplace = JSON.parse(readFileSync(marketplacePath, 'utf8'));
if (!Array.isArray(marketplace.plugins)) {
  console.error('marketplace.json has no plugins[] array');
  process.exit(2);
}

const drift = [];
for (const entry of marketplace.plugins) {
  const source = entry.source ?? '';
  if (typeof source !== 'string' || source.length === 0) {
    console.error(`plugin "${entry.name}" has no source`);
    process.exit(2);
  }

  const pluginJsonPath = join(repoRoot, source, '.claude-plugin', 'plugin.json');
  let pluginJson;
  try {
    pluginJson = JSON.parse(readFileSync(pluginJsonPath, 'utf8'));
  } catch (err) {
    console.error(`cannot read ${pluginJsonPath}: ${err.message}`);
    process.exit(2);
  }

  if (!pluginJson.version) {
    console.error(`${pluginJsonPath} has no .version`);
    process.exit(2);
  }

  if (entry.version !== pluginJson.version) {
    drift.push({ name: entry.name, marketplace: entry.version, plugin: pluginJson.version });
    entry.version = pluginJson.version;
  }
}

if (drift.length === 0) {
  if (!checkOnly) {
    // No-op write to keep idempotency obvious in CI logs.
    console.log('marketplace.json already in sync');
  }
  process.exit(0);
}

if (checkOnly) {
  console.error('marketplace.json is out of sync with plugin.json files:');
  for (const d of drift) {
    console.error(`  - ${d.name}: marketplace=${d.marketplace} plugin=${d.plugin}`);
  }
  console.error('Run `npm run sync:marketplace` to fix.');
  process.exit(1);
}

writeFileSync(marketplacePath, `${JSON.stringify(marketplace, null, 2)}\n`);
console.log('marketplace.json synced:');
for (const d of drift) {
  console.log(`  - ${d.name}: ${d.marketplace} -> ${d.plugin}`);
}
