#!/usr/bin/env bash
# Lineage PostToolUse hook (Edit / Write / MultiEdit / Bash).
#
# Records per-change provenance into the per-project change ledger and emits a
# lean lineage.change.recorded event. Kept cheap: metadata + a redacted,
# size-capped snippet of the added content + a digest — no transcript parsing
# (the prompt is resolved lazily at /lineage query time). Bash is handled
# separately: it carries no file_path or content in tool_input, so it diffs
# the work tree against a rolling per-session baseline instead (see below).
# The Edit/Write/MultiEdit path still records from tool_input as before, but
# also advances that same baseline for the file it just touched, so a later
# Bash call doesn't see the edit as new work and record it a second time.
#
# Hook contract: always exits 0; never blocks the tool. Skips silently when
# disabled, when the path is ignored, or when the file is outside the repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "lineage-post-tool-use"

# shellcheck source=../lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=../lib/lineage-config.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-config.sh"
# shellcheck source=../lib/lineage-events.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-events.sh"
# shellcheck source=../lib/lineage-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-project-key.sh"
# shellcheck source=../lib/lineage-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-ulid.sh"
# shellcheck source=../lib/lineage-redact.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-redact.sh"
# shellcheck source=../lib/lineage-record.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-record.sh"
# shellcheck source=../lib/lineage-baseline.sh
source "${PLUGIN_ROOT}/scripts/lib/lineage-baseline.sh"

INPUT=$(cat)
hook_health_context "$INPUT"
_done() { exit 0; }

# Held only while the Bash branch's baseline read → decide → rebuild cycle is
# in flight (see below). Released on every exit path via the trap, including
# the many early `_done` returns in that cycle — lock_release is a documented
# no-op when nothing is held, so this fires harmlessly for every other exit
# from the script too.
_BASELINE_LOCK=""
_release_baseline_lock() { [[ -n "$_BASELINE_LOCK" ]] && lock_release "$_BASELINE_LOCK"; }
trap _release_baseline_lock EXIT

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL=""
TOOL_INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null) || TOOL_INPUT="{}"
TOOL_USE_ID=$(printf '%s' "$INPUT" | jq -r '.tool_use_id // ""' 2>/dev/null) || TOOL_USE_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""

case "$TOOL" in
	Edit | Write | MultiEdit | Bash) ;;
	*) _done ;;
esac

# Skip ignored paths. Supports the common glob shapes in config:
#   **/<dir>/**  → path-segment match ;  **/*.<ext> → suffix match.
#
# Defined here, ahead of the Bash branch below, rather than at its original
# call site further down: bash resolves function definitions at execution
# time, and the Bash branch (which also calls this) runs before that point.
_lineage_ignored() {
	local path="$1" glob core
	while IFS= read -r glob; do
		[[ -z "$glob" ]] && continue
		core="$glob"
		core="${core#\*\*/}"
		core="${core%/\*\*}"
		case "$core" in
			\*.*) [[ "$path" == *"${core#\*}" ]] && return 0 ;;
			*) [[ "/$path/" == *"/$core/"* ]] && return 0 ;;
		esac
	done < <(lineage_config_ignore_globs)
	return 1
}

[[ -z "$CWD" ]] && CWD="$(pwd)"
REPO_ROOT=$(lineage_project_repo_root "$CWD")

# ---------------------------------------------------------------------------
# Bash: git is the source of truth. A shell-shaped edit has no tool_input to
# read a path or content from, so compare the work tree against a rolling
# per-session baseline and record whatever moved (ecosystem-449.13).
#
# This branch runs BEFORE lineage_config_load / lineage_project_key on
# purpose (ecosystem-449.13 task 4.5): that setup costs roughly 25ms per call
# (config load + several jq-backed accessors + the project-key remote-URL
# lookup), and Bash outruns Edit roughly 30:1. Deciding whether anything
# changed first, via lineage_changed_files' per-path content shas, means a
# no-op shell call — the common case — never pays for setup it doesn't need.
# The baseline itself is keyed by a cheap scope id (a hash of the repo root)
# rather than the project key, since resolving the project key is part of
# the cost being skipped; the baseline is per-session scratch and is never
# joined to the ledger, so it doesn't need the ledger's identity.
#
# The whole read → decide → rebuild cycle below runs under a lock on the
# baseline file (ecosystem-449.13 I3). Parallel Bash calls within one turn
# are routine, and without a lock every concurrent hook reads the same
# not-yet-advanced baseline, independently decides the same pending change
# is new, and records it once each — lineage_append's internal lock keeps any
# single write from corrupting the ledger, but it can't stop that many
# well-formed, duplicate records from landing. Holding this lock across the
# full cycle (not just the read) means whichever hook gets there first fully
# records the change and advances the baseline before anyone else is let in,
# so the next hook to acquire the lock sees a baseline that already accounts
# for the change and finds nothing left to do.
# ---------------------------------------------------------------------------
if [[ "$TOOL" == "Bash" ]]; then
	[[ -z "$REPO_ROOT" ]] && _done

	BASELINE_FILE=$(lineage_baseline_path "$(lineage_baseline_scope_id "$REPO_ROOT")" "$SESSION_ID")
	mkdir -p "$(dirname "$BASELINE_FILE")" 2>/dev/null || _done

	BASELINE_LOCK="${BASELINE_FILE}.lock"
	lock_acquire "$BASELINE_LOCK" 5 || _done
	_BASELINE_LOCK="$BASELINE_LOCK"

	BASELINE='{}'
	[[ -f "$BASELINE_FILE" ]] && BASELINE=$(cat "$BASELINE_FILE" 2>/dev/null) || true
	[[ -z "$BASELINE" ]] && BASELINE='{}'

	# No prior baseline means this is the session's first Bash call. Seed and
	# stop: with nothing to compare against, every dirty file would look new.
	if ! printf '%s' "$BASELINE" | jq -e 'has("files")' >/dev/null 2>&1; then
		_seed=$(lineage_baseline_build "$REPO_ROOT")
		[[ -n "$_seed" ]] && lineage_baseline_write "$BASELINE_FILE" "$_seed"
		_done
	fi

	CHANGED=$(lineage_changed_files "$REPO_ROOT" "$BASELINE")

	# Pre-gate: nothing moved, so there is nothing to record. Advance the
	# baseline (a no-op here, but keeps the file's mtime/shape consistent)
	# and stop before paying for config load or the project key.
	if [[ -z "$CHANGED" ]]; then
		_noop=$(lineage_baseline_build "$REPO_ROOT")
		[[ -n "$_noop" ]] && lineage_baseline_write "$BASELINE_FILE" "$_noop"
		_done
	fi

	lineage_config_load "$REPO_ROOT"
	PROJECT_KEY=$(lineage_project_key "$CWD")
	[[ -n "${LINEAGE_TRACE_SETUP:-}" ]] && printf 'SETUP_DONE\n' >&2
	[[ -z "$PROJECT_KEY" ]] && _done

	COMMAND=$(printf '%s' "$TOOL_INPUT" | jq -r '.command // ""' 2>/dev/null) || COMMAND=""
	PROV_KIND=$(lineage_classify_command "$COMMAND")

	MAX_CHARS=$(lineage_config_max_snippet_chars)
	DO_REDACT=true
	lineage_config_redact_enabled || DO_REDACT=false

	TURN=""
	TRACKER="${ONLOOKER_DIR:-$HOME/.onlooker}/session-trackers/${SESSION_ID}"
	[[ -n "$SESSION_ID" && -f "$TRACKER" ]] && TURN=$(jq -r '.turn_number // empty' "$TRACKER" 2>/dev/null)

	while IFS= read -r REL; do
		[[ -z "$REL" ]] && continue
		_lineage_ignored "$REL" && continue

		SCOPE=$(lineage_content_scope "$BASELINE" "$REL")
		ADDED=$(lineage_added_content "$REPO_ROOT" "$REL")
		REMOVED=$(lineage_removed_content "$REPO_ROOT" "$REL")
		# Skip only when git reports neither side. A pure deletion has no
		# added content, and skipping on that alone lost the change for
		# good, since the baseline advances either way.
		[[ -z "$ADDED" && -z "$REMOVED" ]] && continue

		REC=$(lineage_build_record "$(lineage_ulid)" "$(lineage_now_iso)" \
			"$(lineage_now_epoch)" "$SESSION_ID" "$TURN" "Bash" \
			"${REPO_ROOT}/${REL}" '{}' "$MAX_CHARS" "$DO_REDACT" \
			"$TRANSCRIPT_PATH" "$ADDED" "$PROV_KIND" "$SCOPE" "$REMOVED")
		[[ -z "$REC" ]] && continue

		if lineage_append "$PROJECT_KEY" "$REC"; then
			EV=$(printf '%s' "$REC" | jq -c --arg pk "$PROJECT_KEY" --arg tuid "$TOOL_USE_ID" '
				{
					project_key: $pk, session_id: .session_id, file_path: .file_path,
					tool: .tool, operation: .operation, change_id: .change_id,
					lines_added: .lines_added, lines_removed: .lines_removed,
					bytes: .bytes, edit_count: .edit_count, content_sha256: .content_sha256,
					provenance_kind: .provenance_kind, content_scope: .content_scope
				}
				+ (if .turn != null then {turn: .turn} else {} end)
				+ (if $tuid != "" then {tool_use_id: $tuid} else {} end)
			' 2>/dev/null)
			[[ -n "$EV" ]] && lineage_emit_event "lineage.change.recorded" "$EV" "$SESSION_ID" || true
		fi
	done < <(printf '%s\n' "$CHANGED")

	# Advance the baseline whether or not anything was recorded, so the next
	# call diffs against current state rather than re-reporting the same edit.
	_final=$(lineage_baseline_build "$REPO_ROOT")
	[[ -n "$_final" ]] && lineage_baseline_write "$BASELINE_FILE" "$_final"
	_done
fi

lineage_config_load "$REPO_ROOT"

PROJECT_KEY=$(lineage_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && _done

FILE_PATH=""
case "$TOOL" in
	MultiEdit)
		# MultiEdit applies to one file via a top-level file_path; some shapes
		# nest file_path per edit, so fall back to the first edit's.
		FILE_PATH=$(printf '%s' "$TOOL_INPUT" | jq -r '.file_path // .edits[0].file_path // ""' 2>/dev/null) || FILE_PATH=""
		# If edits carry distinct per-file paths spanning more than one file,
		# skip to avoid misattribution. (Future: split into one record per file.)
		unique_count=$(printf '%s' "$TOOL_INPUT" | jq -r '[.edits[]?.file_path // empty] | unique | length' 2>/dev/null) || unique_count=0
		[[ "${unique_count:-0}" -gt 1 ]] && _done
		;;
	*)
		FILE_PATH=$(printf '%s' "$TOOL_INPUT" | jq -r '.file_path // .path // ""' 2>/dev/null) || FILE_PATH=""
		;;
esac
[[ -z "$FILE_PATH" ]] && _done

# Skip ignored paths (function defined above, ahead of the Bash branch).
_lineage_ignored "$FILE_PATH" && _done

# Skip files outside the repo (best-effort). Resolve the file's directory to a
# real path so the prefix test survives symlinked roots (e.g. macOS /var →
# /private/var, where REPO_ROOT is already realpath-resolved).
if [[ -n "$REPO_ROOT" && "$FILE_PATH" == /* ]]; then
	_file_dir=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P) || _file_dir=""
	if [[ -n "$_file_dir" && "$_file_dir" != "$REPO_ROOT" && "$_file_dir"/ != "$REPO_ROOT"/* ]]; then
		_done
	fi
fi

# Turn number (best-effort) from the substrate session tracker.
TURN=""
TRACKER="${ONLOOKER_DIR:-$HOME/.onlooker}/session-trackers/${SESSION_ID}"
[[ -n "$SESSION_ID" && -f "$TRACKER" ]] && TURN=$(jq -r '.turn_number // empty' "$TRACKER" 2>/dev/null)

MAX_CHARS=$(lineage_config_max_snippet_chars)
DO_REDACT=true
lineage_config_redact_enabled || DO_REDACT=false
CHANGE_ID=$(lineage_ulid)
TS=$(lineage_now_iso)
TS_EPOCH=$(lineage_now_epoch)

RECORD=$(lineage_build_record "$CHANGE_ID" "$TS" "$TS_EPOCH" "$SESSION_ID" "$TURN" \
	"$TOOL" "$FILE_PATH" "$TOOL_INPUT" "$MAX_CHARS" "$DO_REDACT" "$TRANSCRIPT_PATH")
[[ -z "$RECORD" ]] && _done

if lineage_append "$PROJECT_KEY" "$RECORD"; then
	# Lean bus event: metadata + digest only — never the added content.
	EV=$(printf '%s' "$RECORD" | jq -c --arg pk "$PROJECT_KEY" --arg tuid "$TOOL_USE_ID" '
		{
			project_key: $pk, session_id: .session_id, file_path: .file_path,
			tool: .tool, operation: .operation, change_id: .change_id,
			lines_added: .lines_added, lines_removed: .lines_removed,
			bytes: .bytes, edit_count: .edit_count, content_sha256: .content_sha256
		}
		+ (if .turn != null then {turn: .turn} else {} end)
		+ (if $tuid != "" then {tool_use_id: $tuid} else {} end)
	' 2>/dev/null)
	[[ -n "$EV" ]] && lineage_emit_event "lineage.change.recorded" "$EV" "$SESSION_ID" || true

	# Advance the Bash rolling baseline too, so a later Bash call — even one
	# that writes nothing — does not see this Edit/Write/MultiEdit change as
	# new work and re-record it as a "Bash"/shell_edit duplicate. Without
	# this, that duplicate is the NEWER record, and lineage_match_line's
	# newest-wins lookup returns it instead of the true Edit/Write/MultiEdit
	# record it displaced (ecosystem-449.13 C2).
	#
	# Only when a baseline file already exists for this scope/session: if
	# none exists yet, the Bash branch's own seed-and-stop step builds one
	# from current disk state on its first call, which already reflects this
	# change — nothing to advance ahead of.
	if [[ -n "$REPO_ROOT" ]]; then
		_baseline_scope_id=$(lineage_baseline_scope_id "$REPO_ROOT")
		_baseline_file=$(lineage_baseline_path "$_baseline_scope_id" "$SESSION_ID")
		if [[ -f "$_baseline_file" ]]; then
			_rel_path="$FILE_PATH"
			if [[ "$FILE_PATH" == /* ]]; then
				_file_dir=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P) || _file_dir=""
				if [[ -n "$_file_dir" ]]; then
					_abs_file_path="${_file_dir}/$(basename "$FILE_PATH")"
					_rel_path="${_abs_file_path#"$REPO_ROOT"/}"
				fi
			fi
			_new_sha=$(lineage_file_sha "$FILE_PATH")
			if [[ -n "$_new_sha" ]]; then
				# Same lock the Bash branch's read → decide → rebuild cycle
				# takes on this file (ecosystem-449.13 I3): without it, this
				# read-modify-write could race a concurrent Bash hook's full
				# rebuild and either clobber it or get clobbered, and — before
				# the atomic write below — a failed `jq` here could leave a
				# zero-byte baseline the same way a bare `>` redirect would.
				_baseline_lock="${_baseline_file}.lock"
				if lock_acquire "$_baseline_lock" 5; then
					_updated_baseline=$(jq -c --arg k "$_rel_path" --arg v "$_new_sha" \
						'.files[$k]=$v' "$_baseline_file" 2>/dev/null)
					[[ -n "$_updated_baseline" ]] && lineage_baseline_write "$_baseline_file" "$_updated_baseline"
					lock_release "$_baseline_lock"
				fi
			fi
		fi
	fi
fi

_done
