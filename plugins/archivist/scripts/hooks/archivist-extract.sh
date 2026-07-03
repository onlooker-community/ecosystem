#!/usr/bin/env bash
# Archivist PreCompact extraction hook.
#
# Triggered by PreCompact (manual + auto). Reads the transcript tail, asks
# `claude -p` for a structured JSON extraction of decisions, dead ends, and
# open questions, validates referenced paths against the current repo, and
# writes ULID-keyed artifacts under ~/.onlooker/archivist/<project-key>/.
#
# Hook contract:
#   - Always exits 0 and approves compaction. Never blocks.
#   - Skips work if there is no git context (no project key).
#   - Errors from `claude -p` are swallowed; the worst case is "no new memory
#     for this compact", never "compaction failed".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Ecosystem substrate (validate-path.sh) lives in the sibling ecosystem plugin.
# Prefer the env var the harness sets; fall back to walking up to the repo
# root in dev checkouts.
_ECOSYSTEM_ROOT="${ONLOOKER_ECOSYSTEM_ROOT:-}"
if [[ -z "$_ECOSYSTEM_ROOT" ]]; then
	# In the marketplace repo, plugins/archivist/scripts/hooks is 4 dirs
	# below the ecosystem root.
	_candidate="$(cd "${PLUGIN_ROOT}/../.." 2>/dev/null && pwd)"
	if [[ -f "${_candidate}/scripts/lib/validate-path.sh" ]]; then
		_ECOSYSTEM_ROOT="$_candidate"
	fi
fi

if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
fi

# shellcheck source=../lib/archivist-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-project-key.sh"
# shellcheck source=../lib/archivist-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-ulid.sh"
# shellcheck source=../lib/archivist-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"
# shellcheck source=../lib/archivist-config.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-config.sh"
# shellcheck source=../lib/archivist-events.sh
CLAUDE_PLUGIN_ROOT="${_ECOSYSTEM_ROOT:-$PLUGIN_ROOT}" source "${PLUGIN_ROOT}/scripts/lib/archivist-events.sh"

# Always approve compaction at exit, no matter what happened above.
_approve() {
	jq -cn --arg reason "${1:-Compaction approved}" \
		'{decision: "approve", reason: $reason}'
}

INPUT=$(cat)
trap '_approve "Archivist extraction errored out, compaction approved anyway"' ERR

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""
TRIGGER=$(printf '%s' "$INPUT" | jq -r '.trigger // "auto"' 2>/dev/null) || TRIGGER="auto"
CUSTOM_INSTRUCTIONS=$(printf '%s' "$INPUT" | jq -r '.custom_instructions // ""' 2>/dev/null) || CUSTOM_INSTRUCTIONS=""

REPO_ROOT=$(archivist_project_repo_root "$CWD")
PROJECT_KEY=$(archivist_project_key "$CWD")

# Config requires repo_root to scan settings.json overlay; load anyway with
# best-effort empty fallback.
archivist_config_load "$REPO_ROOT"

if [[ -z "$PROJECT_KEY" || -z "$REPO_ROOT" ]]; then
	_approve "Archivist: no git context, nothing to extract"
	exit 0
fi

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
	_approve "Archivist: no transcript available"
	exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
	_approve "Archivist: claude CLI not on PATH, skipping extraction"
	exit 0
fi

# ----------------------------------------------------------------------------
# Build the extraction prompt from the transcript tail.
# ----------------------------------------------------------------------------

TRANSCRIPT_TAIL_CHARS=$(archivist_config_get '.archivist.extraction.transcript_tail_chars')
[[ -z "$TRANSCRIPT_TAIL_CHARS" || "$TRANSCRIPT_TAIL_CHARS" == "null" ]] && TRANSCRIPT_TAIL_CHARS=60000

MAX_OUTPUT_TOKENS=$(archivist_config_get '.archivist.extraction.max_output_tokens')
[[ -z "$MAX_OUTPUT_TOKENS" || "$MAX_OUTPUT_TOKENS" == "null" ]] && MAX_OUTPUT_TOKENS=1500

EXTRACTION_MODEL=$(archivist_config_get '.archivist.extraction.model')
[[ -z "$EXTRACTION_MODEL" || "$EXTRACTION_MODEL" == "null" ]] && EXTRACTION_MODEL=""

# Take the last N chars of the transcript file. Using a portable approach
# (tail -c works on macOS and Linux).
TRANSCRIPT_TAIL=$(tail -c "$TRANSCRIPT_TAIL_CHARS" "$TRANSCRIPT_PATH" 2>/dev/null) || TRANSCRIPT_TAIL=""

if [[ -z "$TRANSCRIPT_TAIL" ]]; then
	_approve "Archivist: empty transcript tail"
	exit 0
fi

PROMPT_FILE=$(mktemp -t archivist-prompt.XXXXXX 2>/dev/null) || PROMPT_FILE="/tmp/archivist-prompt.$$"
trap 'rm -f "$PROMPT_FILE"; _approve "Archivist extraction errored out, compaction approved anyway"' ERR
trap 'rm -f "$PROMPT_FILE"' EXIT

{
	printf '%s\n' 'You are extracting structured session memory from a Claude Code transcript that is about to be compacted (context truncated). Return JSON only — no prose, no markdown fences.'
	printf '\n'
	printf '%s\n' 'Output schema (JSON, exactly these keys):'
	printf '%s\n' '{'
	printf '%s\n' '  "decisions": [ { "summary": "...", "detail": "...", "files": ["relative/path.ts"] } ],'
	printf '%s\n' '  "dead_ends": [ { "summary": "...", "detail": "what was tried and why it did not work", "files": [] } ],'
	printf '%s\n' '  "open_questions": [ { "summary": "...", "detail": "...", "files": [] } ]'
	printf '%s\n' '}'
	printf '\n'
	printf '%s\n' 'Rules:'
	printf '%s\n' '- Only include items that would meaningfully help a future session continue this work. Skip routine status updates.'
	printf '%s\n' '- "summary" is a single declarative sentence under 120 chars.'
	printf '%s\n' '- "detail" is optional and should add why/how context, not restate the summary.'
	printf '%s\n' '- "files" should list repository-relative paths that the item references. Omit absolute paths and paths outside this repo.'
	printf '%s\n' '- Prefer reusable rules ("decisions") over event recaps. Decisions outlive specific bugs.'
	printf '%s\n' '- Return at most 6 decisions, 6 dead_ends, 6 open_questions. If none qualify in a category, return an empty array.'
	printf '%s\n' '- Output a single JSON object on one line, parseable by JSON.parse.'
	if [[ -n "$CUSTOM_INSTRUCTIONS" ]]; then
		printf '\n'
		printf 'Additional user-provided focus: %s\n' "$CUSTOM_INSTRUCTIONS"
	fi
	printf '\n'
	printf 'Repository root: %s\n' "$REPO_ROOT"
	printf '\n'
	printf '%s\n' '---BEGIN TRANSCRIPT TAIL---'
	printf '%s\n' "$TRANSCRIPT_TAIL"
	printf '%s\n' '---END TRANSCRIPT TAIL---'
} > "$PROMPT_FILE"

# ----------------------------------------------------------------------------
# Invoke `claude -p`. We rely on its default JSON-only output mode when asked
# for JSON in the prompt; we don't pass --output-format because we want the
# raw text we asked for.
# ----------------------------------------------------------------------------

CLAUDE_ARGS=(-p --max-turns 1)
[[ -n "$EXTRACTION_MODEL" ]] && CLAUDE_ARGS+=(--model "$EXTRACTION_MODEL")

# 90-second hard ceiling on extraction so a hung LLM call never blocks the
# user's compaction more than that.
EXTRACTION_TIMEOUT=90

RESPONSE=""
if command -v timeout >/dev/null 2>&1; then
	RESPONSE=$(timeout "$EXTRACTION_TIMEOUT" claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
elif command -v gtimeout >/dev/null 2>&1; then
	RESPONSE=$(gtimeout "$EXTRACTION_TIMEOUT" claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
else
	RESPONSE=$(claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>/dev/null) || RESPONSE=""
fi

if [[ -z "$RESPONSE" ]]; then
	_approve "Archivist: extraction returned no output"
	exit 0
fi

# Strip any accidental markdown fences before parsing.
CLEAN_RESPONSE=$(printf '%s' "$RESPONSE" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')

if ! printf '%s' "$CLEAN_RESPONSE" | jq -e '.decisions and .dead_ends and .open_questions' >/dev/null 2>&1; then
	_approve "Archivist: extraction output was not valid JSON"
	exit 0
fi

# ----------------------------------------------------------------------------
# Persist artifacts.
# ----------------------------------------------------------------------------

REMOTE_URL=$(archivist_project_remote_url "$CWD")
archivist_storage_write_manifest "$PROJECT_KEY" "$REMOTE_URL" "$REPO_ROOT" || true

NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WRITE_COUNT=0

for KIND_PAIR in "decisions:decision" "dead_ends:dead_end" "open_questions:open_question"; do
	KIND_DIR="${KIND_PAIR%%:*}"
	KIND_LABEL="${KIND_PAIR##*:}"

	ENTRY_COUNT=$(printf '%s' "$CLEAN_RESPONSE" | jq ".${KIND_DIR} | length" 2>/dev/null) || ENTRY_COUNT=0
	for ((i = 0; i < ENTRY_COUNT; i++)); do
		ENTRY=$(printf '%s' "$CLEAN_RESPONSE" | jq ".${KIND_DIR}[$i]" 2>/dev/null) || continue
		[[ -z "$ENTRY" || "$ENTRY" == "null" ]] && continue

		SUMMARY=$(printf '%s' "$ENTRY" | jq -r '.summary // ""')
		[[ -z "$SUMMARY" ]] && continue

		DETAIL=$(printf '%s' "$ENTRY" | jq -r '.detail // ""')
		PATHS_JSON=$(printf '%s' "$ENTRY" | jq '.files // []')
		CLEAN_PATHS=$(archivist_validate_paths_array "$REPO_ROOT" "$PATHS_JSON")

		ID=$(archivist_ulid)
		ARTIFACT=$(jq -n \
			--arg id "$ID" \
			--arg kind "$KIND_LABEL" \
			--arg project_key "$PROJECT_KEY" \
			--arg now "$NOW_TS" \
			--arg session_id "$SESSION_ID" \
			--arg trigger "$TRIGGER" \
			--arg summary "$SUMMARY" \
			--arg detail "$DETAIL" \
			--argjson files "$CLEAN_PATHS" \
			'{
				id: $id,
				kind: $kind,
				project_key: $project_key,
				source: "local",
				created_at: $now,
				updated_at: $now,
				summary: $summary,
				detail: (if $detail == "" then null else $detail end),
				files: $files,
				session_id: (if $session_id == "" then null else $session_id end),
				trigger: $trigger
			}')

		archivist_storage_write_artifact "$PROJECT_KEY" "$KIND_DIR" "$ID" "$ARTIFACT" >/dev/null \
			&& WRITE_COUNT=$((WRITE_COUNT + 1))
	done
done

# Write an aggregate extract JSON for the artifact browser. This is the
# single-file representation of everything extracted this compact cycle:
# decisions, dead ends, and open questions in one document. The session_id
# doubles as the artifact key so the stable uuid from artifact.FromEvent
# deduplicates re-uploads of the same session.
if [[ "$WRITE_COUNT" -gt 0 && -n "$SESSION_ID" ]]; then
	EXTRACTS_DIR="$(archivist_project_dir "$PROJECT_KEY")/extracts"
	mkdir -p "$EXTRACTS_DIR" 2>/dev/null || true
	EXTRACT_PATH="${EXTRACTS_DIR}/${SESSION_ID}.json"

	AGGREGATE=$(jq -n \
		--argjson decisions "$(printf '%s' "$CLEAN_RESPONSE" | jq '.decisions // []')" \
		--argjson dead_ends "$(printf '%s' "$CLEAN_RESPONSE" | jq '.dead_ends // []')" \
		--argjson open_questions "$(printf '%s' "$CLEAN_RESPONSE" | jq '.open_questions // []')" \
		'{decisions: $decisions, dead_ends: $dead_ends, open_questions: $open_questions}') || AGGREGATE=""

	if [[ -n "$AGGREGATE" ]]; then
		printf '%s\n' "$AGGREGATE" > "$EXTRACT_PATH" 2>/dev/null || true

		SESSION_SHORT="${SESSION_ID:0:8}"
		ARTIFACT_PAYLOAD=$(jq -n \
			--arg plugin "archivist" \
			--arg artifact_kind "extract" \
			--arg artifact_path "$EXTRACT_PATH" \
			--arg artifact_title "Archivist Extract · $SESSION_SHORT" \
			'{plugin: $plugin, artifact_kind: $artifact_kind,
			  artifact_path: $artifact_path, artifact_title: $artifact_title}') || ARTIFACT_PAYLOAD=""
		[[ -n "$ARTIFACT_PAYLOAD" ]] && \
			archivist_emit_event "onlooker.artifact.ready" "$ARTIFACT_PAYLOAD" || true
	fi
fi

_approve "Archivist: wrote ${WRITE_COUNT} artifacts (trigger=${TRIGGER})"
exit 0
