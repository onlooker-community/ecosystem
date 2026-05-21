#!/usr/bin/env node
/**
 * Canonical Onlooker event helpers for bash hooks.
 * Uses @onlooker-community/schema for envelope shape and validation.
 */
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  createEvent,
  TOOL_AGENT_COMPLETE,
  TOOL_AGENT_SPAWN,
  TOOL_FILE_EDIT,
  TOOL_FILE_READ,
  TOOL_FILE_WRITE,
  TOOL_SHELL_EXEC,
  TOOL_WEB_FETCH,
  validate,
} from '@onlooker-community/schema';

export function ensureMachineId(onlookerDir) {
  const path = join(onlookerDir, 'machine_id');
  if (existsSync(path)) {
    return readFileSync(path, 'utf8').trim();
  }
  mkdirSync(onlookerDir, { recursive: true });
  const id = randomUUID();
  writeFileSync(path, `${id}\n`, 'utf8');
  return id;
}

/** File-backed monotonic sequence (per ONLOOKER_DIR). */
export function nextSequence(onlookerDir) {
  const path = join(onlookerDir, 'event-sequence');
  let current = 0;
  if (existsSync(path)) {
    const parsed = Number.parseInt(readFileSync(path, 'utf8').trim(), 10);
    if (!Number.isNaN(parsed)) current = parsed;
  }
  writeFileSync(path, String(current + 1), 'utf8');
  return current;
}

export function buildCanonicalEvent({
  onlookerDir,
  runtime = 'claude-code',
  adapter_id,
  plugin,
  session_id,
  event_type,
  payload,
  cost_usd,
  token_count,
}) {
  const event = createEvent({
    runtime,
    adapter_id,
    plugin,
    machine_id: ensureMachineId(onlookerDir),
    session_id,
    event_type,
    payload,
    cost_usd,
    token_count,
  });
  event.sequence = nextSequence(onlookerDir);
  return event;
}

function summarizeText(value, maxLen = 1000) {
  if (value == null) return undefined;
  const text = String(value).replace(/\s+/g, ' ').trim();
  if (!text) return undefined;
  return text.length > maxLen ? `${text.slice(0, maxLen)}…` : text;
}

function extractPath(toolInput, toolResponse) {
  return toolInput?.file_path ?? toolInput?.path ?? toolResponse?.filePath ?? toolResponse?.path ?? undefined;
}

/**
 * Map Claude Code PostToolUse / PostToolUseFailure hook input to a canonical event.
 * Returns null when the tool is not mapped to a schema event type.
 */
export function mapHookInputToCanonical(hookInput, options) {
  const { onlookerDir, plugin, runtime = 'claude-code', adapter_id = 'ecosystem.hooks' } = options;

  const toolName = hookInput?.tool_name;
  const hookEvent = hookInput?.hook_event_name ?? 'PostToolUse';
  const isFailure = hookEvent === 'PostToolUseFailure';
  const toolInput = hookInput?.tool_input ?? {};
  const toolResponse = hookInput?.tool_response ?? {};
  const sessionId = hookInput?.session_id ?? 'unknown';
  const durationMs = hookInput?.duration_ms;

  let eventType;
  let payload;

  switch (toolName) {
    case 'Read': {
      const path = extractPath(toolInput, toolResponse);
      if (!path) return null;
      eventType = TOOL_FILE_READ;
      payload = { path };
      const content = toolResponse?.content;
      if (typeof content === 'string') {
        const lines = content.split('\n').length;
        payload.lines_read = lines;
        payload.file_size_bytes = content.length;
      }
      break;
    }
    case 'Write': {
      const path = extractPath(toolInput, toolResponse);
      if (!path) return null;
      eventType = TOOL_FILE_WRITE;
      payload = {
        path,
        operation: toolResponse?.success === false ? 'overwrite' : 'create',
      };
      break;
    }
    case 'Edit': {
      const path = extractPath(toolInput, toolResponse);
      if (!path) return null;
      eventType = TOOL_FILE_EDIT;
      payload = { path };
      break;
    }
    case 'Bash': {
      const command = toolInput?.command;
      if (!command) return null;
      eventType = TOOL_SHELL_EXEC;
      payload = {
        command,
        exit_code: isFailure ? 1 : Number.isFinite(toolResponse?.exit_code) ? toolResponse.exit_code : 0,
        duration_ms: durationMs,
        working_directory: toolInput?.cwd ?? hookInput?.cwd,
        blocked: isFailure ? true : undefined,
      };
      if (payload.blocked === undefined) delete payload.blocked;
      break;
    }
    case 'WebFetch': {
      const url = toolInput?.url;
      if (!url) return null;
      eventType = TOOL_WEB_FETCH;
      payload = {
        url,
        status_code: toolResponse?.status_code,
        blocked: isFailure ? true : undefined,
      };
      if (payload.blocked === undefined) delete payload.blocked;
      break;
    }
    case 'Agent': {
      const subagentId = toolInput?.agent_id ?? hookInput?.tool_use_id ?? 'unknown';
      if (hookEvent === 'PreToolUse') {
        eventType = TOOL_AGENT_SPAWN;
        payload = {
          subagent_id: subagentId,
          agent_name: toolInput?.subagent_type,
          task_summary: toolInput?.description,
        };
      } else {
        eventType = TOOL_AGENT_COMPLETE;
        payload = {
          subagent_id: subagentId,
          success: !isFailure && toolResponse?.success !== false,
          agent_name: toolInput?.subagent_type,
          duration_ms: durationMs,
          output_summary: isFailure
            ? summarizeText(hookInput?.error)
            : summarizeText(toolInput?.description ?? toolResponse?.status),
        };
        if (!payload.output_summary) delete payload.output_summary;
      }
      break;
    }
    default:
      return null;
  }

  const event = buildCanonicalEvent({
    onlookerDir,
    runtime,
    adapter_id,
    plugin,
    session_id: sessionId,
    event_type: eventType,
    payload,
  });

  const result = validate(event);
  if (!result.valid) {
    return { valid: false, errors: result.errors, event_type: eventType };
  }
  return { valid: true, event: result.event };
}

function readStdin() {
  return new Promise((resolve) => {
    const chunks = [];
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => chunks.push(c));
    process.stdin.on('end', () => resolve(chunks.join('')));
  });
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  const onlookerDir = process.env.ONLOOKER_DIR ?? join(process.env.HOME ?? '/tmp', '.onlooker');
  const plugin = process.env.ONLOOKER_PLUGIN_NAME ?? 'onlooker';

  if (command === 'validate') {
    const raw = await readStdin();
    const parsed = JSON.parse(raw || '{}');
    const result = validate(parsed);
    if (!result.valid) {
      console.error(JSON.stringify(result.errors, null, 2));
      process.exit(1);
    }
    console.log(JSON.stringify(result.event));
    return;
  }

  if (command === 'emit-from-hook') {
    const raw = await readStdin();
    const hookInput = JSON.parse(raw || '{}');
    const mapped = mapHookInputToCanonical(hookInput, { onlookerDir, plugin });
    if (!mapped) {
      process.exit(0);
    }
    if (!mapped.valid) {
      console.error(JSON.stringify(mapped.errors, null, 2));
      process.exit(1);
    }
    console.log(JSON.stringify(mapped.event));
    return;
  }

  if (command === 'emit') {
    let params;
    const fileArg = args.find((a) => a.startsWith('--params='));
    if (fileArg) {
      params = JSON.parse(readFileSync(fileArg.slice(9), 'utf8'));
    } else {
      params = JSON.parse(await readStdin());
    }
    const event = buildCanonicalEvent({
      onlookerDir,
      plugin: params.plugin ?? plugin,
      runtime: params.runtime ?? 'claude-code',
      adapter_id: params.adapter_id,
      session_id: params.session_id,
      event_type: params.event_type,
      payload: params.payload,
    });
    const result = validate(event);
    if (!result.valid) {
      console.error(JSON.stringify(result.errors, null, 2));
      process.exit(1);
    }
    console.log(JSON.stringify(result.event));
    return;
  }

  console.error(`Usage: onlooker-event.mjs <validate|emit-from-hook|emit>`);
  process.exit(2);
}

const isMain = process.argv[1]?.endsWith('onlooker-event.mjs') ?? false;
if (isMain) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
