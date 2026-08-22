#!/usr/bin/env node
// Managed-block fence checker.
//
// Tools like `bd setup` own the text between a `<!-- BEGIN ... -->` and
// `<!-- END ... -->` marker pair and rewrite it verbatim on every run. Any
// `markdownlint --fix` we apply inside such a block is silently undone the next
// time anyone regenerates it. Because CI runs `lint:check` (markdownlint with
// no `--fix`), that churn lands as a red build that looks unrelated to whatever
// the person was actually doing.
//
// The fix is to fence each block with markdownlint-disable/enable comments
// placed *outside* the BEGIN/END markers, so the generator cannot clobber them.
// This script asserts that every managed block in every tracked markdown file
// carries such a fence, covering the rules the generated text is known to trip.
//
// Exit codes:
//   0  ok
//   1  one or more unfenced or malformed managed blocks
//   2  setup/usage error
//
// Flags:
//   --root <path>   override the repo root (used by the tests)

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Rules the `bd`-generated blocks trip. MD034 fires because the generator
// writes bare URLs where markdownlint wants angle brackets; MD012 because it
// leaves consecutive blank lines; MD024 because two different `bd` subcommands
// each emit a "Beads Issue Tracker" heading into the same file.
const REQUIRED_RULES = ['MD012', 'MD024', 'MD034'];

const BEGIN_MARKER = /^<!--\s*BEGIN\s+\S.*-->\s*$/;
const END_MARKER = /^<!--\s*END\s+\S.*-->\s*$/;
const DISABLE_COMMENT = /^<!--\s*markdownlint-disable\s+(.*?)\s*-->\s*$/;
const ENABLE_COMMENT = /^<!--\s*markdownlint-enable\s+(.*?)\s*-->\s*$/;

function parseArgs(argv) {
  const args = { root: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--root') {
      args.root = argv[++i];
      if (!args.root) usageError('--root requires a path');
    } else {
      usageError(`unknown argument: ${argv[i]}`);
    }
  }
  return args;
}

function usageError(message) {
  process.stderr.write(`check-managed-blocks: ${message}\n`);
  process.exit(2);
}

// Minimal .markdownlintignore support, matching the two pattern shapes the file
// actually uses: a directory prefix ("node_modules/") and a recursive basename
// glob ("**/CHANGELOG.md"). Anything else is compared literally. Kept
// deliberately small -- if the ignore file grows richer patterns, reach for a
// real glob matcher rather than extending this.
function loadIgnorePatterns(root) {
  const ignorePath = join(root, '.markdownlintignore');
  if (!existsSync(ignorePath)) return [];
  return readFileSync(ignorePath, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '' && !line.startsWith('#'));
}

function isIgnored(relPath, patterns) {
  for (const pattern of patterns) {
    if (pattern.endsWith('/')) {
      if (relPath === pattern.slice(0, -1) || relPath.startsWith(pattern)) return true;
    } else if (pattern.startsWith('**/')) {
      const basename = pattern.slice(3);
      if (relPath === basename || relPath.endsWith(`/${basename}`)) return true;
    } else if (relPath === pattern) {
      return true;
    }
  }
  return false;
}

function trackedMarkdownFiles(root) {
  let stdout;
  try {
    stdout = execFileSync('git', ['ls-files', '-z', '*.md'], { cwd: root, encoding: 'utf8' });
  } catch (err) {
    usageError(`could not list tracked files under ${root}: ${err.message}`);
  }
  return stdout.split('\0').filter((path) => path !== '');
}

function rulesFrom(match) {
  return match[1].split(/\s+/).filter((rule) => rule !== '');
}

function missingRules(declared) {
  return REQUIRED_RULES.filter((rule) => !declared.includes(rule));
}

// Walks one file and reports every managed block that is not correctly fenced.
function checkFile(relPath, contents, errors) {
  const lines = contents.split('\n');

  for (let i = 0; i < lines.length; i++) {
    if (!BEGIN_MARKER.test(lines[i])) continue;

    const beginLine = lines[i];
    const beginNo = i + 1;
    const label = `${relPath}:${beginNo}`;

    // Locate the matching END before judging the fence, so an unterminated
    // block is reported as exactly one error rather than cascading.
    let endIndex = -1;
    for (let j = i + 1; j < lines.length; j++) {
      if (BEGIN_MARKER.test(lines[j])) break; // nested/overlapping: stop looking
      if (END_MARKER.test(lines[j])) {
        endIndex = j;
        break;
      }
    }

    if (endIndex === -1) {
      errors.push(`${label}: managed block "${beginLine.trim()}" has no matching <!-- END ... --> marker`);
      continue;
    }

    const before = i > 0 ? lines[i - 1] : '';
    const disable = before.match(DISABLE_COMMENT);
    if (!disable) {
      errors.push(
        `${label}: managed block is not fenced -- the line directly above it must be ` +
          `"<!-- markdownlint-disable ${REQUIRED_RULES.join(' ')} -->", found ${JSON.stringify(before)}`,
      );
    } else {
      const missing = missingRules(rulesFrom(disable));
      if (missing.length > 0) {
        errors.push(`${label}: markdownlint-disable above this block omits ${missing.join(', ')}`);
      }
    }

    const after = endIndex + 1 < lines.length ? lines[endIndex + 1] : '';
    const enable = after.match(ENABLE_COMMENT);
    if (!enable) {
      errors.push(
        `${relPath}:${endIndex + 1}: managed block is not closed -- the line directly below its END marker ` +
          `must be "<!-- markdownlint-enable ${REQUIRED_RULES.join(' ')} -->", found ${JSON.stringify(after)}`,
      );
    } else {
      const missing = missingRules(rulesFrom(enable));
      if (missing.length > 0) {
        errors.push(`${relPath}:${endIndex + 2}: markdownlint-enable below this block omits ${missing.join(', ')}`);
      }
    }

    i = endIndex;
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const here = dirname(fileURLToPath(import.meta.url));
  const root = resolve(args.root ?? join(here, '..', '..'));

  if (!existsSync(root)) usageError(`root does not exist: ${root}`);

  const ignorePatterns = loadIgnorePatterns(root);
  const errors = [];
  let blockCount = 0;
  let fileCount = 0;

  for (const relPath of trackedMarkdownFiles(root)) {
    if (isIgnored(relPath, ignorePatterns)) continue;

    const absPath = join(root, relPath);
    if (!existsSync(absPath)) continue; // staged deletion; nothing to check

    const contents = readFileSync(absPath, 'utf8');
    if (!contents.includes('<!--')) continue; // fast path: no comments, no markers

    checkFile(relPath, contents, errors);

    const found = (contents.match(new RegExp(BEGIN_MARKER.source, 'gm')) ?? []).length;
    if (found > 0) {
      fileCount++;
      blockCount += found;
    }
  }

  for (const e of errors) process.stderr.write(`error: ${e}\n`);

  if (errors.length > 0) {
    process.stderr.write(
      `check-managed-blocks: ${errors.length} error(s) across ${blockCount} managed block(s)\n` +
        'Fence generated blocks so `bd setup` cannot undo `markdownlint --fix`. See ecosystem-55g.\n',
    );
    process.exit(1);
  }

  process.stdout.write(`check-managed-blocks: ok (${blockCount} managed block(s) in ${fileCount} file(s))\n`);
}

main();
