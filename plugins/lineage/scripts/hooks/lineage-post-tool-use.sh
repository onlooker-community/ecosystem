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

# Held only while the Bash branch's baseline read → decide → rebuild cycle is
# in flight (see below). Released on every exit path via the trap, including
# the many early `_done` returns in that cycle — lock_release is a documented
# no-op when nothing is held, so this fires harmlessly for every other exit
# from the script too.
#
# Installed BEFORE hook_health_register (below), not after: hook-health's
# register captures whatever EXIT trap is already in place and chains it
# after logging (see hook-health.sh's hook_health_register). Installing our
# trap after register would instead clobber hook-health's own EXIT trap —
# our handler would still release the lock, but hook-health would never get
# a turn, so it silently logs nothing to hook-health.jsonl. This is safe
# even though _release_baseline_lock calls lock_release from
# portable-lock.sh, sourced further below: bash resolves function bodies at
# call time, and the trap itself only fires at exit, by which point
# portable-lock.sh has been sourced (and if the script exits before that,
# _BASELINE_LOCK is still empty, so the call is skipped entirely).
_BASELINE_LOCK=""
_release_baseline_lock() { [[ -n "$_BASELINE_LOCK" ]] && lock_release "$_BASELINE_LOCK"; }
trap _release_baseline_lock EXIT

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

# One jq pass for every field this hook can need, instead of the ten it used
# to spawn. jq was 25 forks and ~66ms of a ~227ms invocation (ecosystem-6ce);
# ten of those were this file re-parsing the same payload one key at a time.
#
# Fields come back NUL-delimited and are read straight into variables. NUL is
# the one byte a path cannot contain, and reading beats `eval "$(jq @sh ...)"`
# because nothing here is ever re-parsed as shell -- a file path holding $(...)
# or a quote is inert either way, but only this way is it obviously so.
#
# Order is load-bearing: it must match the assignments below.
_LINEAGE_FIELDS=()
while IFS= read -r -d '' _lineage_field; do
	_LINEAGE_FIELDS+=("$_lineage_field")
done < <(printf '%s' "$INPUT" | jq -j '
	[ (.session_id // "")
	, (.cwd // "")
	, (.tool_name // "")
	, ((.tool_input // {}) | tojson)
	, (.tool_use_id // "")
	, (.transcript_path // "")
	, (.tool_input.command // "")
	, (.tool_input.file_path // .tool_input.edits[0].file_path // "")
	, ([.tool_input.edits[]?.file_path // empty] | unique | length | tostring)
	, (.tool_input.file_path // .tool_input.path // "")
	] | .[] | . + "\u0000"' 2>/dev/null)

# Defaults cover a jq that failed outright, matching the old per-line `|| VAR=""`.
SESSION_ID=${_LINEAGE_FIELDS[0]:-}
CWD=${_LINEAGE_FIELDS[1]:-}
TOOL=${_LINEAGE_FIELDS[2]:-}
TOOL_INPUT=${_LINEAGE_FIELDS[3]:-}
# NB: not ${_LINEAGE_FIELDS[3]:-{}} — bash appends a stray brace to the
# SET case there, turning {"a":1} into {"a":1}} and corrupting the JSON.
TOOL_USE_ID=${_LINEAGE_FIELDS[4]:-}
TRANSCRIPT_PATH=${_LINEAGE_FIELDS[5]:-}
_TI_COMMAND=${_LINEAGE_FIELDS[6]:-}
_TI_MULTIEDIT_PATH=${_LINEAGE_FIELDS[7]:-}
_TI_MULTIEDIT_UNIQUE=${_LINEAGE_FIELDS[8]:-0}
_TI_FILE_PATH=${_LINEAGE_FIELDS[9]:-}
[[ -z "$TOOL_INPUT" ]] && TOOL_INPUT="{}"

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

# Two roots, two jobs — keeping them apart is ecosystem-449.33.
#
# REPO_ROOT is identity: it resolves a linked worktree to its parent checkout so
# both write to one ledger. It is a valid answer to "whose provenance is this"
# and a wrong answer to "where are the files", because a worktree's files do not
# live under it.
#
# WORKTREE_ROOT is the tree this session is actually in. Every path operation
# below uses it: the containment test, the Bash branch's baseline and diff, and
# the record paths. Using REPO_ROOT for those meant a worktree's edits tested as
# outside the repo and its shell edits diffed the parent's tree instead.
#
# The two lineage_config_load calls below are the deliberate exception: they
# still take REPO_ROOT, so a worktree reads its parent checkout's config. That
# is config resolution rather than a path operation, it is the same question
# every plugin here answers the same way, and ecosystem-449.37 settles it across
# all of them. Left alone here so this change stays one decision wide.
REPO_ROOT=$(lineage_project_repo_root "$CWD")
WORKTREE_ROOT=$(lineage_worktree_root "$CWD")

# Outside a git repo both are empty; in a normal checkout they are equal. Fall
# back so a resolution failure degrades to the old single-root behavior rather
# than disabling the hook.
[[ -z "$WORKTREE_ROOT" ]] && WORKTREE_ROOT="$REPO_ROOT"

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
	[[ -z "$WORKTREE_ROOT" ]] && _done

	BASELINE_FILE=$(lineage_baseline_path "$(lineage_baseline_scope_id "$WORKTREE_ROOT")" "$SESSION_ID")
	mkdir -p "$(dirname "$BASELINE_FILE")" 2>/dev/null || _done

	BASELINE_LOCK="${BASELINE_FILE}.lock"
	if ! lock_acquire "$BASELINE_LOCK" 5; then
		# Report rather than vanish. An abandoned lock is reclaimed by
		# portable-lock.sh's breaker, so reaching here means a live holder is
		# genuinely wedged — and the cost of staying quiet about it is a
		# provenance blackout for the rest of the session that also charges
		# the full timeout to every later shell call, with no symptom anyone
		# would notice (ecosystem-am1).
		#
		# hook-health rather than the event bus: a new event type has to be
		# registered in @onlooker-community/schema and released before it can
		# be emitted, and this signal should not wait on that. hook-health is
		# also where the rollout's latency and failure attribution is already
		# being read from.
		hook_health_failure "baseline_lock_unavailable"
		_done
	fi
	_BASELINE_LOCK="$BASELINE_LOCK"

	BASELINE='{}'
	[[ -f "$BASELINE_FILE" ]] && BASELINE=$(cat "$BASELINE_FILE" 2>/dev/null) || true
	[[ -z "$BASELINE" ]] && BASELINE='{}'

	# No prior baseline means this is the session's first Bash call. Seed and
	# stop: with nothing to compare against, every dirty file would look new.
	if ! printf '%s' "$BASELINE" | jq -e 'has("files")' >/dev/null 2>&1; then
		_seed=$(lineage_baseline_build "$WORKTREE_ROOT")
		[[ -n "$_seed" ]] && lineage_baseline_write "$BASELINE_FILE" "$_seed"
		_done
	fi

	CHANGED=$(lineage_changed_files "$WORKTREE_ROOT" "$BASELINE")

	# Pre-gate: nothing moved, so there is nothing to record. Advance the
	# baseline (a no-op here, but keeps the file's mtime/shape consistent)
	# and stop before paying for config load or the project key.
	if [[ -z "$CHANGED" ]]; then
		_noop=$(lineage_baseline_build "$WORKTREE_ROOT")
		[[ -n "$_noop" ]] && lineage_baseline_write "$BASELINE_FILE" "$_noop"
		_done
	fi

	lineage_config_load "$REPO_ROOT"
	PROJECT_KEY=$(lineage_project_key "$CWD")
	[[ -n "${LINEAGE_TRACE_SETUP:-}" ]] && printf 'SETUP_DONE\n' >&2
	[[ -z "$PROJECT_KEY" ]] && _done

	COMMAND=$_TI_COMMAND
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
		ADDED=$(lineage_added_content "$WORKTREE_ROOT" "$REL")
		REMOVED=$(lineage_removed_content "$WORKTREE_ROOT" "$REL")
		# Skip only when git reports neither side. A pure deletion has no
		# added content, and skipping on that alone lost the change for
		# good, since the baseline advances either way.
		[[ -z "$ADDED" && -z "$REMOVED" ]] && continue

		REC=$(lineage_build_record "$(lineage_ulid)" "$(lineage_now_iso)" \
			"$(lineage_now_epoch)" "$SESSION_ID" "$TURN" "Bash" \
			"${WORKTREE_ROOT}/${REL}" '{}' "$MAX_CHARS" "$DO_REDACT" \
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
	_final=$(lineage_baseline_build "$WORKTREE_ROOT")
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
		FILE_PATH=$_TI_MULTIEDIT_PATH
		# If edits carry distinct per-file paths spanning more than one file,
		# skip to avoid misattribution. (Future: split into one record per file.)
		unique_count=$_TI_MULTIEDIT_UNIQUE
		[[ "${unique_count:-0}" -gt 1 ]] && _done
		;;
	*)
		FILE_PATH=$_TI_FILE_PATH
		;;
esac
[[ -z "$FILE_PATH" ]] && _done

# Resolve to the one spelling the ledger stores, before anything reads it: the
# ignore test, the in-repo test, the record, and the baseline key all have to
# agree on a single string, and the Bash path already writes the resolved one
# (ecosystem-htl).
FILE_PATH=$(lineage_resolve_path "$FILE_PATH")

# Skip ignored paths (function defined above, ahead of the Bash branch).
_lineage_ignored "$FILE_PATH" && _done

# Skip files outside the repo (best-effort). Both sides are realpath-resolved
# now, so this is a plain prefix test.
#
# Tested against WORKTREE_ROOT, not REPO_ROOT (ecosystem-449.33). A linked
# worktree's files live beside the parent checkout, not beneath it, so this
# prefix test against the parent's root failed for every worktree edit and
# dropped it as out-of-repo — silently, since the hook exits 0 either way.
if [[ -n "$WORKTREE_ROOT" && "$FILE_PATH" == /* ]]; then
	_file_dir=$(dirname "$FILE_PATH")
	if [[ "$_file_dir" != "$WORKTREE_ROOT" && "$_file_dir"/ != "$WORKTREE_ROOT"/* ]]; then
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
	if [[ -n "$WORKTREE_ROOT" ]]; then
		_baseline_scope_id=$(lineage_baseline_scope_id "$WORKTREE_ROOT")
		_baseline_file=$(lineage_baseline_path "$_baseline_scope_id" "$SESSION_ID")
		# A cheap pre-check, not the deciding one: it keeps an Edit that
		# precedes any Bash call in the session off the lock entirely. The
		# test that governs the write is the one inside the lock below.
		if [[ -f "$_baseline_file" ]]; then
			# FILE_PATH and WORKTREE_ROOT are both resolved by now, so the
			# strip needs no further path work (ecosystem-htl). The baseline
			# it feeds is built from WORKTREE_ROOT, so the key has to be
			# relative to that same root (ecosystem-449.33).
			_rel_path="${FILE_PATH#"$WORKTREE_ROOT"/}"

			# Same lock the Bash branch's read → decide → rebuild cycle
			# takes on this file (ecosystem-449.13 I3): without it, this
			# read-modify-write could race a concurrent Bash hook's full
			# rebuild and either clobber it or get clobbered, and — before
			# the atomic write below — a failed `jq` here could leave a
			# zero-byte baseline the same way a bare `>` redirect would.
			_baseline_lock="${_baseline_file}.lock"
			if lock_acquire "$_baseline_lock" 5; then
				# Existence and content hash are both read under the lock.
				# Reading them outside it left a window where a parallel Bash
				# call writing this same path had its content stamped into the
				# baseline and went unrecorded (ecosystem-am1).
				if [[ -f "$_baseline_file" ]]; then
					_new_sha=$(lineage_file_sha "$FILE_PATH")
					if [[ -n "$_new_sha" ]]; then
						_updated_baseline=$(jq -c --arg k "$_rel_path" --arg v "$_new_sha" \
							'.files[$k]=$v' "$_baseline_file" 2>/dev/null)
						[[ -n "$_updated_baseline" ]] && lineage_baseline_write "$_baseline_file" "$_updated_baseline"
					fi
				fi
				lock_release "$_baseline_lock"
			fi
		fi
	fi
fi

_done
