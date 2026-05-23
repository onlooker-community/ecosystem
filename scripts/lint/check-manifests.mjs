#!/usr/bin/env node
// Manifest validator for the Onlooker marketplace.
//
// Asserts that .claude-plugin/marketplace.json and every plugin's
// .claude-plugin/plugin.json match the Claude Code plugin schema, and that
// our own conventions hold:
//
//   * marketplace.json plugins[] entries MUST NOT carry a `version` field
//     (the drift trap — plugin.json's version silently wins at runtime, so
//     setting both is documented as harmful in plugins-reference).
//   * plugin.json `name` matches its marketplace entry name (no surprise
//     renames).
//   * plugin.json `name` is kebab-case (matches plugin loader conventions).
//   * plugin.json `version` is semver-shaped.
//   * resource arrays (skills/commands/agents) and mcpServers/hooks fields
//     have the expected types.
//
// Exit codes:
//   0  ok
//   1  one or more schema violations
//   2  setup/usage error
//
// Flags:
//   --strict             treat warnings (unknown fields, missing optional
//                        recommended fields) as errors
//   --root <path>        override the repo root
//   --plugin <name>      only validate the named plugin (repeatable)

import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SEMVER = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const KEBAB_CASE = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/;

// Fields we recognize on each manifest. Unknown fields trigger a warning
// (typo detection). New fields should be added here as Claude Code's schema
// evolves.
const KNOWN_MARKETPLACE_FIELDS = new Set(['name', 'owner', 'metadata', 'plugins', '$schema']);
const KNOWN_MARKETPLACE_PLUGIN_FIELDS = new Set([
  'name',
  'source',
  'description',
  'author',
  'homepage',
  'repository',
  'license',
  'keywords',
  'tags',
]);
const KNOWN_PLUGIN_JSON_FIELDS = new Set([
  'name',
  'version',
  'description',
  'author',
  'homepage',
  'repository',
  'license',
  'skills',
  'commands',
  'agents',
  'mcpServers',
  'hooks',
  'keywords',
  '$schema',
]);
const KNOWN_HOOK_EVENTS = new Set([
  'PreToolUse',
  'PostToolUse',
  'PostToolUseFailure',
  'PermissionRequest',
  'PermissionDenied',
  'SessionStart',
  'SessionEnd',
  'Notification',
  'SubagentStart',
  'PreCompact',
  'PostCompact',
  'SubagentStop',
  'ConfigChange',
  'CwdChanged',
  'FileChanged',
  'StopFailure',
  'InstructionsLoaded',
  'Elicitation',
  'ElicitationResult',
  'UserPromptSubmit',
  'UserPromptExpansion',
  'Stop',
  'TeammateIdle',
  'TaskCreated',
  'TaskCompleted',
  'WorktreeCreate',
  'WorktreeRemove',
]);

function findRepoRoot(start) {
  let cur = resolve(start);
  while (cur !== '/') {
    if (existsSync(join(cur, '.claude-plugin', 'marketplace.json'))) return cur;
    cur = dirname(cur);
  }
  throw new Error(`could not find .claude-plugin/marketplace.json above ${start}`);
}

function parseArgs(argv) {
  const out = { strict: false, plugins: [], root: null };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--strict') out.strict = true;
    else if (a === '--plugin') out.plugins.push(argv[++i]);
    else if (a === '--root') out.root = argv[++i];
    else if (a === '-h' || a === '--help') {
      process.stderr.write('Usage: check-manifests.mjs [--strict] [--plugin name]... [--root path]\n');
      process.exit(0);
    } else {
      process.stderr.write(`unknown argument: ${a}\n`);
      process.exit(2);
    }
  }
  return out;
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    return { __readError: `cannot read ${label} at ${path}: ${err.message}` };
  }
}

function validateMarketplace(marketplace, errors, warnings) {
  if (!isPlainObject(marketplace)) {
    errors.push('marketplace.json must be a JSON object');
    return;
  }
  if (typeof marketplace.name !== 'string' || marketplace.name.length === 0) {
    errors.push('marketplace.json: `name` is required and must be a non-empty string');
  }
  if (!Array.isArray(marketplace.plugins)) {
    errors.push('marketplace.json: `plugins` is required and must be an array');
  }
  if (marketplace.owner !== undefined && !isPlainObject(marketplace.owner)) {
    errors.push('marketplace.json: `owner` must be an object when present');
  }
  if (marketplace.owner && typeof marketplace.owner.name !== 'string') {
    errors.push('marketplace.json: `owner.name` is required when `owner` is present');
  }
  for (const key of Object.keys(marketplace)) {
    if (!KNOWN_MARKETPLACE_FIELDS.has(key)) {
      warnings.push(`marketplace.json: unknown top-level field "${key}"`);
    }
  }
}

function validateMarketplacePluginEntry(entry, index, errors, warnings) {
  const label = `marketplace.json plugins[${index}]`;
  if (!isPlainObject(entry)) {
    errors.push(`${label}: must be an object`);
    return;
  }
  if (typeof entry.name !== 'string' || !KEBAB_CASE.test(entry.name)) {
    errors.push(`${label}: \`name\` is required and must be kebab-case (got ${JSON.stringify(entry.name)})`);
  }
  if (typeof entry.source !== 'string' || entry.source.length === 0) {
    errors.push(`${label}: \`source\` is required and must be a string`);
  }
  if ('version' in entry) {
    errors.push(
      `${label}: \`version\` MUST NOT be set in marketplace.json — Claude Code reads version from each plugin's own plugin.json, and setting both is a documented drift hazard.`,
    );
  }
  for (const key of Object.keys(entry)) {
    if (!KNOWN_MARKETPLACE_PLUGIN_FIELDS.has(key)) {
      warnings.push(`${label}: unknown field "${key}"`);
    }
  }
}

function validatePluginJson(pluginJson, marketplaceName, label, errors, warnings) {
  if (!isPlainObject(pluginJson)) {
    errors.push(`${label}: plugin.json must be a JSON object`);
    return;
  }
  if (typeof pluginJson.name !== 'string' || !KEBAB_CASE.test(pluginJson.name)) {
    errors.push(`${label}: \`name\` is required and must be kebab-case (got ${JSON.stringify(pluginJson.name)})`);
  } else if (pluginJson.name !== marketplaceName) {
    errors.push(
      `${label}: plugin.json \`name\` "${pluginJson.name}" does not match marketplace entry name "${marketplaceName}"`,
    );
  }
  if (typeof pluginJson.version !== 'string' || pluginJson.version.length === 0) {
    errors.push(`${label}: \`version\` is required and must be a non-empty string`);
  } else if (!SEMVER.test(pluginJson.version)) {
    errors.push(`${label}: \`version\` is not semver-shaped (got ${JSON.stringify(pluginJson.version)})`);
  }
  if (typeof pluginJson.description !== 'string' || pluginJson.description.length === 0) {
    errors.push(`${label}: \`description\` is required and must be a non-empty string`);
  }
  for (const field of ['skills', 'commands', 'agents']) {
    if (pluginJson[field] !== undefined && !Array.isArray(pluginJson[field])) {
      errors.push(`${label}: \`${field}\` must be an array when present`);
    }
  }
  if (pluginJson.mcpServers !== undefined && !isPlainObject(pluginJson.mcpServers)) {
    errors.push(`${label}: \`mcpServers\` must be an object when present`);
  }
  for (const key of Object.keys(pluginJson)) {
    if (!KNOWN_PLUGIN_JSON_FIELDS.has(key)) {
      warnings.push(`${label}: unknown field "${key}"`);
    }
  }
}

function validateHooksJson(hooksJson, label, errors, warnings) {
  if (!isPlainObject(hooksJson)) {
    errors.push(`${label}: hooks.json must be a JSON object`);
    return;
  }
  if (!isPlainObject(hooksJson.hooks)) {
    errors.push(`${label}: hooks.json must contain a \`hooks\` object`);
    return;
  }
  for (const [event, value] of Object.entries(hooksJson.hooks)) {
    if (!KNOWN_HOOK_EVENTS.has(event)) {
      warnings.push(`${label}: hooks.json declares unknown event "${event}"`);
    }
    if (!Array.isArray(value)) {
      errors.push(`${label}: hooks.json event "${event}" must be an array`);
      continue;
    }
    for (let i = 0; i < value.length; i++) {
      const matcher = value[i];
      if (!isPlainObject(matcher)) {
        errors.push(`${label}: hooks.json ${event}[${i}] must be an object`);
        continue;
      }
      if (!Array.isArray(matcher.hooks)) {
        errors.push(`${label}: hooks.json ${event}[${i}].hooks must be an array`);
      }
    }
  }
}

function main() {
  const args = parseArgs(process.argv);
  const here = dirname(fileURLToPath(import.meta.url));
  const root = args.root ? resolve(args.root) : findRepoRoot(here);

  const marketplacePath = join(root, '.claude-plugin', 'marketplace.json');
  const marketplace = readJson(marketplacePath, 'marketplace.json');
  if (marketplace.__readError) {
    process.stderr.write(`error: ${marketplace.__readError}\n`);
    process.exit(2);
  }

  const errors = [];
  const warnings = [];

  validateMarketplace(marketplace, errors, warnings);

  const plugins = Array.isArray(marketplace.plugins) ? marketplace.plugins : [];
  const filter = args.plugins.length === 0 ? null : new Set(args.plugins);

  for (let i = 0; i < plugins.length; i++) {
    const entry = plugins[i];
    validateMarketplacePluginEntry(entry, i, errors, warnings);
    if (!isPlainObject(entry) || typeof entry.name !== 'string' || typeof entry.source !== 'string') {
      continue;
    }
    if (filter && !filter.has(entry.name)) continue;

    const pluginRoot = resolve(root, entry.source);
    const pluginJsonPath = join(pluginRoot, '.claude-plugin', 'plugin.json');
    const label = `plugin "${entry.name}"`;
    const pluginJson = readJson(pluginJsonPath, `${label} plugin.json`);
    if (pluginJson.__readError) {
      errors.push(pluginJson.__readError);
      continue;
    }
    validatePluginJson(pluginJson, entry.name, label, errors, warnings);

    // Validate hooks/hooks.json if the plugin appears to ship hooks.
    const hooksJsonPath = join(pluginRoot, 'hooks', 'hooks.json');
    if (existsSync(hooksJsonPath)) {
      const stat = statSync(hooksJsonPath);
      if (stat.isFile()) {
        const hooksJson = readJson(hooksJsonPath, `${label} hooks.json`);
        if (hooksJson.__readError) {
          errors.push(hooksJson.__readError);
        } else {
          validateHooksJson(hooksJson, `${label} (${relative(root, hooksJsonPath)})`, errors, warnings);
        }
      }
    }
  }

  for (const e of errors) process.stderr.write(`error: ${e}\n`);
  for (const w of warnings) process.stderr.write(`warn:  ${w}\n`);

  const failing = errors.length > 0 || (args.strict && warnings.length > 0);
  if (failing) {
    process.stderr.write(`check-manifests: ${errors.length} error(s), ${warnings.length} warning(s)\n`);
    process.exit(1);
  }

  process.stdout.write(`check-manifests: ok (${plugins.length} plugin(s), ${warnings.length} warning(s))\n`);
}

main();
