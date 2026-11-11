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

set -uo pipefail # No -e: never block session startup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/validate-path.sh
source "$SCRIPT_DIR/../lib/validate-path.sh"
# shellcheck source=../lib/onlooker-schema.sh
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"

# Standard hook health instrumentation. hook_register sets up the timer;
# hook_set_context exports _HOOK_SESSION_ID + _HOOK_EVENT_NAME so failures
# attach to the right session in ~/.onlooker/logs/hook-health.jsonl;
# hook_success / hook_failure close the health record.
hook_register "memory-recall-tracker" "Memory Recall Tracker" "Emits memory.recalled per typed memory file present at SessionStart"

INPUT=$(cat 2>/dev/null || true)
hook_set_context "$INPUT" "SessionStart"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null) || SOURCE="startup"
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

# Compaction reloads the session with the same memories still in scope.
# Re-emitting on each compaction would inflate usage counts; skip.
if [[ "$SOURCE" == "compact" ]]; then
	hook_success
	exit 0
fi

# ---------------------------------------------------------------------------
# Resolve project_key through the canonical lib, already sourced by
# onlooker-schema.sh. This hook used to hand-roll its own derivation, which no
# vendoring guard could see, and so emitted the one event carrying two
# independently derived keys: the payload's and the envelope's. Resolving once
# here makes them the same value by construction, and the session cache spares
# the git calls the hand-rolled version paid on every SessionStart (ONL-164).
# test/bats/project-key-single-derivation.bats keeps a derivation from
# reappearing anywhere outside the lib.
# ---------------------------------------------------------------------------

onlooker_project_resolve_cached "$CWD"
PROJECT_KEY="$ONLOOKER_PROJECT_KEY"

if [[ -z "$PROJECT_KEY" ]]; then
	hook_success
	exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the per-project typed-memory store at
# ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<encoded>/memory/. Claude Code encodes the project
# path by replacing path separators with `-` and prepending a leading `-`.
# Prefer $CLAUDE_PROJECT_ENCODED when the harness has populated it; fall
# back to deriving from CWD.
# ---------------------------------------------------------------------------

ENCODED="${CLAUDE_PROJECT_ENCODED:-}"
if [[ -z "$ENCODED" ]]; then
	# Encode the absolute cwd the way Claude Code does: replace BOTH path
	# separators and dots with `-`. Verified against the real directories
	# under $CLAUDE_CONFIG_DIR/projects — none contains a literal dot, and
	# every github.com path renders as github-com.
	#
	# Replacing only `/` produced a directory that cannot exist for any repo
	# cloned under a github.com-style path, so this hook hit `! -d` and exited
	# 0 reporting success while injecting nothing (ecosystem-449.12).
	ABS_CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || ABS_CWD=""
	if [[ -n "$ABS_CWD" ]]; then
		ENCODED=$(printf '%s' "$ABS_CWD" | sed -E 's#[/.]#-#g')
	fi
fi

MEMORY_DIR="${CLAUDE_HOME}/projects/${ENCODED}/memory"
if [[ -z "$ENCODED" || ! -d "$MEMORY_DIR" ]]; then
	hook_success
	exit 0
fi

# ---------------------------------------------------------------------------
# Read the YAML frontmatter `type` of every *.md file (excluding MEMORY.md
# itself, which is the index, not a memory). Skip files whose type isn't one
# of the four valid enum values — emitting anything else would fail schema
# validation and the event would be silently dropped.
#
# All of it runs as one awk, one jq and one node, whatever the file count.
# Walking the files in shell cost 66ms each in process starts: 2445ms at 37
# memories, on every SessionStart, growing with the store (ONL-113).
# ---------------------------------------------------------------------------

memory_files=()
for file in "$MEMORY_DIR"/*.md; do
	[[ -f "$file" ]] || continue
	[[ "${file##*/}" == "MEMORY.md" ]] && continue
	memory_files+=("$file")
done

if [[ ${#memory_files[@]} -eq 0 ]]; then
	hook_success
	exit 0
fi

# Prints `<filename>\t<type>` for the first type in each file's frontmatter.
# Parsed with awk (no python dep, no yq dep).
#
# The pattern allows leading whitespace because Claude Code nests the field
# under `metadata:`, indented — anchoring on `^type:` matched only the shape
# these tests used to seed and nothing real, so every actual memory scored an
# empty type and was skipped (ecosystem-449.12).
#
# `node_type:` sits directly above `type:` in real frontmatter and must not
# match; requiring `type:` immediately after the indent keeps it out.
_extract_types() {
	awk '
		FNR == 1 { in_fm = /^---/; found = 0; next }
		in_fm && /^---/ { in_fm = 0; next }
		in_fm && !found && /^[[:space:]]*type:/ {
			found = 1
			value = $0
			sub(/^[[:space:]]*type:[[:space:]]*/, "", value)
			gsub(/["\047]/, "", value)
			name = FILENAME
			sub(/.*\//, "", name)
			printf "%s\t%s\n", name, value
		}
	' "$@" 2>/dev/null
}

# Use the canonical ecosystem plugin name (matches the
# `${ONLOOKER_PLUGIN_NAME:-onlooker}` default that scripts/lib/
# onlooker-emit.sh and onlooker-event.mjs both fall back to). Other
# substrate-level emissions land under "onlooker" too, so this stays
# consistent with the existing event stream.
local_plugin="${ONLOOKER_PLUGIN_NAME:-onlooker}"

# Untyped or unknown-typed memories don't fit the schema's enum, so they are
# filtered out before recall_position is assigned.
params=$(_extract_types "${memory_files[@]}" | jq -Rrn \
	--arg project_key "$PROJECT_KEY" \
	--arg plugin "$local_plugin" \
	--arg sid "$SESSION_ID" \
	'[inputs | split("\t") | select(.[1] as $t | ["user","feedback","project","reference"] | index($t))]
	| to_entries[]
	| {
		plugin: $plugin,
		session_id: $sid,
		event_type: "memory.recalled",
		payload: {
			project_key: $project_key,
			memory_file: .value[0],
			memory_type: .value[1],
			recall_position: .key
		}
	}
	| tojson') || params=""

if [[ -z "$params" ]]; then
	hook_success
	exit 0
fi

# The emitter reads ONLOOKER_PROJECT_KEY and ONLOOKER_PROJECT_BASIS, exported
# by the resolve above, for the envelope dimension.
# A non-zero exit means a line was dropped; the rest of stdout is still good.
event_json=$(printf '%s\n' "$params" \
	| ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="$local_plugin" \
	  node "$_ONLOOKER_EVENT_JS" emit-batch 2>/dev/null) || true

onlooker_append_event "$event_json" || true

hook_success
exit 0
