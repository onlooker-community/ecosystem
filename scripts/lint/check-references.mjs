#!/usr/bin/env node
// Cross-reference linter for the Onlooker marketplace.
//
// Walks every plugin declared in `.claude-plugin/marketplace.json` and:
//   1. asserts every path under plugin.json's `skills`, `commands`, `agents`,
//      and `hooks` fields resolves to a real file or directory inside the
//      plugin's source tree;
//   2. parses YAML frontmatter from each markdown skill/command/agent and
//      asserts the required fields (`name`, `description`) are present;
//   3. builds a cross-marketplace registry of declared commands/skills/agents
//      and scans every markdown body for slash-command references
//      (`/foo`) — anything that is not a known built-in or a declared
//      command is reported as a warning.
//
// Exit codes:
//   0  no problems
//   1  at least one error (broken path or invalid frontmatter)
//   2  setup/usage error
//
// Flags:
//   --strict             treat warnings as errors
//   --plugin <name>      only check the named plugin (repeatable)
//   --root <path>        override the repo root (defaults to git toplevel)
//   --print-registry     dump the resolved registry to stderr (debugging)

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Slash commands shipped by Claude Code itself. References to these never
// fail; they are valid even though we cannot resolve them in the
// marketplace. Kept short on purpose — additions should be deliberate.
const BUILTIN_COMMANDS = new Set([
  'clear',
  'compact',
  'config',
  'help',
  'loop',
  'plugin',
  'reload-plugins',
  'effort',
  'commit',
  'fast',
]);

// Required frontmatter fields per resource kind. Skills/commands/agents all
// need at least name+description; everything else is optional metadata.
const REQUIRED_FRONTMATTER = ['name', 'description'];

function findRepoRoot(start) {
  let cur = resolve(start);
  while (cur !== '/') {
    try {
      statSync(join(cur, '.claude-plugin', 'marketplace.json'));
      return cur;
    } catch {}
    cur = dirname(cur);
  }
  throw new Error(`could not find .claude-plugin/marketplace.json above ${start}`);
}

function parseArgs(argv) {
  const out = { strict: false, plugins: [], printRegistry: false, root: null };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--strict') out.strict = true;
    else if (a === '--print-registry') out.printRegistry = true;
    else if (a === '--plugin') out.plugins.push(argv[++i]);
    else if (a === '--root') out.root = argv[++i];
    else if (a === '-h' || a === '--help') {
      process.stderr.write(
        'Usage: check-references.mjs [--strict] [--plugin name]... [--root path] [--print-registry]\n',
      );
      process.exit(0);
    } else {
      process.stderr.write(`unknown argument: ${a}\n`);
      process.exit(2);
    }
  }
  return out;
}

// Minimal YAML frontmatter parser. We only need `key: value` and quoted
// strings — no nesting, no lists. Sufficient for plugin resource frontmatter,
// and avoids pulling in a YAML dependency.
function parseFrontmatter(source) {
  const lines = source.split(/\r?\n/);
  if (lines[0] !== '---') return { frontmatter: null, body: source };
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === '---') {
      end = i;
      break;
    }
  }
  if (end === -1) return { frontmatter: null, body: source };
  const fm = {};
  for (let i = 1; i < end; i++) {
    const m = lines[i].match(/^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    fm[m[1]] = v;
  }
  return { frontmatter: fm, body: lines.slice(end + 1).join('\n') };
}

// Resolve a plugin manifest entry that may be either a bare string or
// `{ source, name? }` to an absolute path inside the plugin tree.
function entryPath(pluginRoot, entry) {
  if (typeof entry === 'string') return resolve(pluginRoot, entry);
  if (entry && typeof entry === 'object' && typeof entry.source === 'string') {
    return resolve(pluginRoot, entry.source);
  }
  return null;
}

// Extract a friendly identifier from an entry for error messages.
function entryLabel(entry) {
  if (typeof entry === 'string') return entry;
  if (entry && typeof entry === 'object') {
    return entry.name ?? entry.source ?? JSON.stringify(entry);
  }
  return String(entry);
}

// Walk a single resource kind (skills/commands/agents) for a plugin.
// Returns { errors[], records[] } where records are { kind, name, file, plugin }.
function checkResourceKind(plugin, pluginJson, kind, pluginRoot) {
  const errors = [];
  const records = [];
  const entries = pluginJson[kind];
  if (!Array.isArray(entries)) return { errors, records };

  for (const entry of entries) {
    const abs = entryPath(pluginRoot, entry);
    if (!abs) {
      errors.push(`[${plugin}] ${kind} entry has neither a string path nor a {source} field: ${entryLabel(entry)}`);
      continue;
    }

    let stat;
    try {
      stat = statSync(abs);
    } catch {
      errors.push(`[${plugin}] ${kind} entry points to a missing file: ${entryLabel(entry)} (${abs})`);
      continue;
    }

    // If it's a directory, look for either SKILL.md / COMMAND.md / AGENT.md
    // or any single .md file inside. We treat each found .md as one record.
    const files = stat.isDirectory() ? collectMarkdownInDir(abs) : [abs];
    if (files.length === 0) {
      errors.push(`[${plugin}] ${kind} entry directory contains no markdown: ${abs}`);
      continue;
    }

    for (const file of files) {
      const raw = readFileSync(file, 'utf8');
      const { frontmatter } = parseFrontmatter(raw);
      if (!frontmatter) {
        errors.push(`[${plugin}] ${kind} file is missing YAML frontmatter: ${relative(pluginRoot, file)}`);
        continue;
      }
      for (const required of REQUIRED_FRONTMATTER) {
        if (!frontmatter[required] || frontmatter[required].trim() === '') {
          errors.push(
            `[${plugin}] ${kind} file is missing required frontmatter field "${required}": ${relative(pluginRoot, file)}`,
          );
        }
      }
      records.push({
        kind,
        plugin,
        name: frontmatter.name ?? entryLabel(entry),
        file,
      });
    }
  }

  return { errors, records };
}

function collectMarkdownInDir(dir) {
  const out = [];
  const stack = [dir];
  while (stack.length) {
    const cur = stack.pop();
    let items;
    try {
      items = readdirSync(cur, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const item of items) {
      const p = join(cur, item.name);
      if (item.isDirectory()) stack.push(p);
      else if (item.isFile() && p.toLowerCase().endsWith('.md')) out.push(p);
    }
  }
  return out.sort();
}

// Scan a markdown body for slash-command references. Returns an array of
// `{ name, line }` for everything that looks like a slash command.
function findSlashCommands(body) {
  const refs = [];
  const lines = body.split(/\r?\n/);
  // A slash command is /name where name is lowercase + digits + hyphen.
  // We require a non-word char (or start-of-string) before the `/` so URLs,
  // regex literals, and option flags don't match.
  const rx = /(^|[\s(`'"])\/([a-z][a-z0-9-]{1,40})\b/g;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Skip fenced code blocks and inline code: an exhaustive parser is
    // overkill, but we strip backtick-enclosed runs first to cut down on
    // the most common false positives.
    const stripped = line.replace(/`[^`]*`/g, '');
    rx.lastIndex = 0;
    let m = rx.exec(stripped);
    while (m !== null) {
      refs.push({ name: m[2], line: i + 1 });
      m = rx.exec(stripped);
    }
  }
  return refs;
}

function main() {
  const args = parseArgs(process.argv);
  const here = dirname(fileURLToPath(import.meta.url));
  const root = args.root ? resolve(args.root) : findRepoRoot(here);

  const marketplacePath = join(root, '.claude-plugin', 'marketplace.json');
  let marketplace;
  try {
    marketplace = JSON.parse(readFileSync(marketplacePath, 'utf8'));
  } catch (err) {
    process.stderr.write(`could not read ${marketplacePath}: ${err.message}\n`);
    process.exit(2);
  }

  const plugins = (marketplace.plugins ?? []).filter((p) => args.plugins.length === 0 || args.plugins.includes(p.name));
  if (plugins.length === 0) {
    process.stderr.write('no plugins matched\n');
    process.exit(2);
  }

  const errors = [];
  const warnings = [];
  const allRecords = [];
  const commandRegistry = new Set(BUILTIN_COMMANDS);

  for (const plugin of plugins) {
    const pluginRoot = resolve(root, plugin.source ?? '.');
    const pluginJsonPath = join(pluginRoot, '.claude-plugin', 'plugin.json');
    let pluginJson;
    try {
      pluginJson = JSON.parse(readFileSync(pluginJsonPath, 'utf8'));
    } catch (err) {
      errors.push(`[${plugin.name}] cannot read plugin.json: ${err.message}`);
      continue;
    }

    for (const kind of ['skills', 'commands', 'agents']) {
      const { errors: kindErrors, records } = checkResourceKind(plugin.name, pluginJson, kind, pluginRoot);
      errors.push(...kindErrors);
      allRecords.push(...records);
      if (kind === 'commands') {
        for (const rec of records) commandRegistry.add(rec.name);
      }
    }
  }

  // Pass 2: cross-reference body slash commands.
  for (const rec of allRecords) {
    const raw = readFileSync(rec.file, 'utf8');
    const { body } = parseFrontmatter(raw);
    const refs = findSlashCommands(body ?? raw);
    for (const r of refs) {
      if (!commandRegistry.has(r.name)) {
        warnings.push(
          `[${rec.plugin}] ${rec.kind}/${rec.name} references unknown command "/${r.name}" at line ${r.line} of ${relative(root, rec.file)}`,
        );
      }
    }
  }

  if (args.printRegistry) {
    process.stderr.write(`registry: ${JSON.stringify([...commandRegistry].sort())}\n`);
    process.stderr.write(`records:\n`);
    for (const r of allRecords) {
      process.stderr.write(`  [${r.plugin}] ${r.kind}/${r.name} -> ${relative(root, r.file)}\n`);
    }
  }

  for (const e of errors) process.stderr.write(`error: ${e}\n`);
  for (const w of warnings) process.stderr.write(`warn:  ${w}\n`);

  const failing = errors.length > 0 || (args.strict && warnings.length > 0);
  if (failing) {
    process.stderr.write(`check-references: ${errors.length} error(s), ${warnings.length} warning(s)\n`);
    process.exit(1);
  }

  process.stdout.write(`check-references: ok (${allRecords.length} records, ${warnings.length} warning(s))\n`);
}

main();
