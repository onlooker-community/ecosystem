#!/usr/bin/env bash
# Onlooker Memory Recall Tracker
# Invoked by SessionStart (matcher: *) when a session boots, resumes, or
# restarts after compaction. Emits one canonical `memory.recalled` event
# per typed-memory file present at the project's per-checkout memory
# store path. This approximates the substrate signal "these memories are
# now in the model's context for the session about to begin".
#
# Curator's usage tracker (and any future plugin that reasons about how
# often a memory is in scope) depends on this. The signal is coarse —
# per-session-load rather than per-recall — but actionable in aggregate.
#
# Hook contract:
#   - Always exits 0. Never blocks SessionStart.
#   - No-ops when there is no project memory store, no git context, or
#     when the source is `compact` (compaction is metadata-only; the
#     same memories remain in scope, so re-emitting would double-count).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/validate-path.sh
source "$SCRIPT_DIR/../lib/validate-path.sh"
# shellcheck source=../lib/onlooker-schema.sh
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"

INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null) || SOURCE="startup"
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

# Compaction reloads the session with the same memories still in scope.
# Re-emitting on each compaction would inflate usage counts; skip.
if [[ "$SOURCE" == "compact" ]]; then
	exit 0
fi

# ---------------------------------------------------------------------------
# Resolve project_key (SHA256-of-remote-URL with repo-root fallback). This is
# the same scheme every memory-flavored plugin uses for its own storage —
# see plugins/librarian/scripts/lib/librarian-project-key.sh, etc.
# ---------------------------------------------------------------------------

_memory_sha256_first12() {
	local input="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

PROJECT_KEY=""
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
	if [[ -n "$REMOTE" ]]; then
		PROJECT_KEY=$(_memory_sha256_first12 "remote:${REMOTE}")
	else
		ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
		if [[ -n "$ROOT" ]]; then
			ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P)
			PROJECT_KEY=$(_memory_sha256_first12 "root:${ROOT}")
		fi
	fi
fi

[[ -z "$PROJECT_KEY" ]] && exit 0

# ---------------------------------------------------------------------------
# Resolve the per-project typed-memory store at
# ~/.claude/projects/<encoded>/memory/. Claude Code encodes the project
# path by replacing path separators with `-` and prepending a leading `-`.
# Prefer $CLAUDE_PROJECT_ENCODED when the harness has populated it; fall
# back to deriving from CWD.
# ---------------------------------------------------------------------------

ENCODED="${CLAUDE_PROJECT_ENCODED:-}"
if [[ -z "$ENCODED" ]]; then
	# Encode the absolute cwd: drop leading slash, swap remaining `/` for
	# `-`, prepend the leading `-`.
	ABS_CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || ABS_CWD=""
	if [[ -n "$ABS_CWD" ]]; then
		ENCODED=$(printf '%s' "$ABS_CWD" | sed -E 's#/#-#g')
	fi
fi

MEMORY_DIR="${CLAUDE_HOME}/projects/${ENCODED}/memory"
[[ -z "$ENCODED" || ! -d "$MEMORY_DIR" ]] && exit 0

# ---------------------------------------------------------------------------
# Walk every *.md file (excluding MEMORY.md itself, which is the index, not
# a memory). For each, parse the YAML frontmatter's `type` field. Skip
# files whose type isn't one of the four valid enum values — emitting
# anything else would fail schema validation and the event would be
# silently dropped.
# ---------------------------------------------------------------------------

_extract_type() {
	local path="$1"
	[[ -f "$path" ]] || return 0
	# Parse frontmatter type via awk + sed (no python dep, no yq dep).
	awk '
		NR == 1 && /^---/ { in_fm = 1; next }
		in_fm && /^---/ { exit }
		in_fm
	' "$path" 2>/dev/null \
		| sed -nE 's/^type:[[:space:]]*(.*)$/\1/p' \
		| head -1 \
		| tr -d '"' \
		| tr -d "'"
}

position=0
for file in "$MEMORY_DIR"/*.md; do
	[[ -f "$file" ]] || continue
	fname=$(basename "$file")
	[[ "$fname" == "MEMORY.md" ]] && continue

	memory_type=$(_extract_type "$file")
	case "$memory_type" in
		user|feedback|project|reference)
			;;
		*)
			# Untyped or unknown-typed memories don't fit the schema's
			# enum. Skip silently rather than tank schema validation.
			continue
			;;
	esac

	payload=$(jq -cn \
		--arg project_key "$PROJECT_KEY" \
		--arg memory_file "$fname" \
		--arg memory_type "$memory_type" \
		--argjson recall_position "$position" \
		'{
			project_key: $project_key,
			memory_file: $memory_file,
			memory_type: $memory_type,
			recall_position: $recall_position
		}')

	params=$(jq -cn \
		--arg plugin "ecosystem" \
		--arg sid "$SESSION_ID" \
		--arg type "memory.recalled" \
		--argjson payload "$payload" \
		'{ plugin: $plugin, session_id: $sid, event_type: $type, payload: $payload }')

	event_json=$(printf '%s' "$params" \
		| ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="ecosystem" \
		  node "$_ONLOOKER_EVENT_JS" emit 2>/dev/null) || event_json=""
	[[ -z "$event_json" ]] && continue

	onlooker_append_event "$event_json" || true
	position=$((position + 1))
done

exit 0
