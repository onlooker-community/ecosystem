#!/usr/bin/env bash
# backfill.sh — embed stored chunks that have no vector (ONL-207).
#
# run-index.sh stores every chunk whether or not the embedder answered, which
# is the right fail-soft call for a detached SessionEnd pass. But the retriever
# is embedding-only, so a chunk stored without a vector is unreachable, and
# nothing ever came back for it. When ollama stopped on 2026-10-21 and nobody
# restarted it, four days of sessions indexed that way: 15,019 chunks across
# 380 session files, every one invisible to retrieval.
#
# This walks the store and embeds those chunks in place. It never re-chunks or
# re-sanitizes: the stored body_redacted is what retrieval will show, so it is
# also exactly what gets embedded.
#
# Usage:
#   backfill.sh [--dry-run] [--project <key>]
#
#   --dry-run          count what would be embedded; touch nothing, call nothing
#   --project <key>    only this project key (default: every project in the store)
#
# Config is read from the current directory, the same way a hook reads it from
# the session cwd. Run it from the project whose embedder settings apply.
#
# Exit status: 0 when the walk finished (individual chunk failures are counted
# and reported, not fatal); 1 when it refused to start or stopped early.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# The config loader finds the shipped defaults through this variable, not
# through PLUGIN_ROOT. Run by path, nothing else sets it, and every default,
# the embedder backend included, would silently read as unset.
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=./lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=./lib/historian-config.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-config.sh"
# shellcheck source=./lib/historian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-storage.sh"
# shellcheck source=./lib/historian-emit.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-emit.sh"
# shellcheck source=./lib/historian-embedder.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-embedder.sh"

DRY_RUN=0
ONLY_PROJECT=""
while (($# > 0)); do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--project)
			ONLY_PROJECT="${2:-}"
			shift
			;;
		*)
			printf 'historian backfill: unknown argument %s\n' "$1" >&2
			exit 1
			;;
	esac
	shift
done

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
# Events need a session id and this is not a session. The skill runs inside
# one, so prefer it when Claude Code exports it.
EVENT_SESSION="${CLAUDE_SESSION_ID:-historian-backfill}"

# A run of consecutive failures this long means the embedder went away, not
# that a few chunks were bad. Stop rather than mark every remaining chunk
# failed: the next run would only find them all again.
MAX_CONSECUTIVE_FAILURES=5

historian_config_load "$(pwd)"

_plural() {
	local n="$1" word="$2"
	if [[ "$n" == "1" ]]; then printf '%s %s' "$n" "$word"; else printf '%s %ss' "$n" "$word"; fi
}

# Project directories only. The store root also holds `sessions/`, where
# run-index.sh keeps its per-session locks, and that is not a project.
_project_dirs() {
	local root dir key
	root=$(historian_storage_root)
	[[ -d "$root" ]] || return 0
	for dir in "$root"/*/; do
		key=$(basename "$dir")
		[[ "$key" =~ ^[0-9a-f]{12}$ ]] || continue
		[[ -n "$ONLY_PROJECT" && "$key" != "$ONLY_PROJECT" ]] && continue
		[[ -d "${dir}sessions" ]] || continue
		printf '%s\n' "${dir%/}"
	done
}

_session_files() {
	local dir f
	while IFS= read -r dir; do
		for f in "$dir"/sessions/*.jsonl; do
			[[ -f "$f" ]] && printf '%s\n' "$f"
		done
	done < <(_project_dirs)
}

# Chunks a pass would embed: no vector, and a body to embed. An empty body is
# not missing a vector, it has nothing to give one.
_count_missing() {
	jq -c 'select((.embedding | type) != "array" or (.embedding | length) == 0)
		| select((.body_redacted // "") != "")' "$1" 2>/dev/null | wc -l | tr -d ' '
}

FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(_session_files)

TOTAL_MISSING=0
SESSIONS_MISSING=0
PROJECTS_MISSING=""
for f in ${FILES[@]+"${FILES[@]}"}; do
	n=$(_count_missing "$f")
	((n > 0)) || continue
	TOTAL_MISSING=$((TOTAL_MISSING + n))
	SESSIONS_MISSING=$((SESSIONS_MISSING + 1))
	PROJECTS_MISSING="${PROJECTS_MISSING}$(basename "$(dirname "$(dirname "$f")")")
"
done
PROJECT_COUNT=$(printf '%s' "$PROJECTS_MISSING" | sort -u | grep -c . || true)

if ((DRY_RUN == 1)); then
	printf 'Would embed %s across %s in %s.\n' \
		"$(_plural "$TOTAL_MISSING" chunk)" "$(_plural "$SESSIONS_MISSING" session)" \
		"$(_plural "$PROJECT_COUNT" project)"
	exit 0
fi

if ((TOTAL_MISSING == 0)); then
	printf 'Nothing to backfill: every stored chunk with a body already has a vector.\n'
	exit 0
fi

BACKEND=$(historian_config_get '.historian.embedder.backend')
[[ -z "$BACKEND" || "$BACKEND" == "null" ]] && BACKEND="none"
MODEL=$(historian_embedder_model)

if ! historian_embedder_available; then
	if [[ "$BACKEND" != "none" ]]; then
		historian_emit "historian.embedder.unavailable" "$EVENT_SESSION" "$(jq -cn \
			--arg backend "$BACKEND" '{ backend: $backend }')"
	fi
	printf 'historian backfill: the embedder is not reachable (backend=%s, model=%s).\n' \
		"$BACKEND" "${MODEL:-none}" >&2
	printf 'Start it (for ollama: `open -ga Ollama`) and run this again. Nothing was changed.\n' >&2
	exit 1
fi

_emit_failed() {
	local reason="$1" attempted="$2" failed="$3" detail="$4"
	historian_emit "historian.embedder.failed" "$EVENT_SESSION" "$(jq -cn \
		--arg backend "$BACKEND" \
		--arg reason "$reason" \
		--argjson attempted "$attempted" \
		--argjson failed "$failed" \
		--arg error_summary "$detail" \
		'{ backend: $backend, reason: $reason, attempted: $attempted, failed: $failed }
		 + (if $error_summary == "" then {} else { error_summary: $error_summary } end)')"
}

# One real embed before touching anything, to learn the vector size this model
# produces. The availability probe above cannot: it reads /api/tags, which
# answers whether or not the model is loaded. A cold load measured 11.24s
# against an 8s request timeout, but ollama keeps loading after the client gives
# up, so a timeout here is retried rather than taken as an answer.
PROBE_DIMS=""
PROBE_ATTEMPTS=0
while ((PROBE_ATTEMPTS < 3)); do
	PROBE_ATTEMPTS=$((PROBE_ATTEMPTS + 1))
	historian_embedder_parse "$(historian_embedder_embed_reported "historian backfill dimension probe")"
	if [[ -n "$HISTORIAN_EMBEDDER_VECTOR" ]]; then
		PROBE_DIMS=$(printf '%s' "$HISTORIAN_EMBEDDER_VECTOR" | jq 'length')
		break
	fi
	[[ "$HISTORIAN_EMBEDDER_REASON" == "timeout" ]] || break
done
if [[ -z "$PROBE_DIMS" ]]; then
	_emit_failed "${HISTORIAN_EMBEDDER_REASON:-request_failed}" "$PROBE_ATTEMPTS" "$PROBE_ATTEMPTS" \
		"$HISTORIAN_EMBEDDER_DETAIL"
	printf 'historian backfill: %s answered its probe but could not embed (%s: %s). Nothing was changed.\n' \
		"$MODEL" "${HISTORIAN_EMBEDDER_REASON:-unknown}" "$HISTORIAN_EMBEDDER_DETAIL" >&2
	exit 1
fi

# Vectors from two models are not comparable: cosine similarity between them is
# noise, and nothing downstream would say so. If the store already holds vectors
# from something other than this model, adding more would quietly mix them, so
# refuse instead. A label settles it when one exists; vectors from before the
# label shipped have only their length to go on.
STORED=$(for f in ${FILES[@]+"${FILES[@]}"}; do
	jq -r 'select((.embedding | type) == "array" and (.embedding | length) > 0)
		| "\(.embedding | length)\t\(.embedding_model // "")"' "$f" 2>/dev/null
done | sort -u)
while IFS=$'\t' read -r dims label; do
	[[ -z "$dims" ]] && continue
	if [[ -n "$label" && "$label" != "$MODEL" ]]; then
		printf 'historian backfill: the store already holds vectors from %s, and the configured model is %s.\n' \
			"$label" "$MODEL" >&2
		printf 'Mixing them would break similarity for every stored chunk. Nothing was changed.\n' >&2
		exit 1
	fi
	if [[ "$dims" != "$PROBE_DIMS" ]]; then
		printf 'historian backfill: stored vectors have %s dimensions, but %s returns %s.\n' \
			"$dims" "$MODEL" "$PROBE_DIMS" >&2
		printf 'They came from a different model. Nothing was changed.\n' >&2
		exit 1
	fi
done <<<"$STORED"

printf 'Embedding %s across %s with %s.\n' \
	"$(_plural "$TOTAL_MISSING" chunk)" "$(_plural "$SESSIONS_MISSING" session)" "$MODEL"

EMBEDDED=0
FAILED=0
SKIPPED_LOCKED=0
CONSECUTIVE=0
STOPPED=0
FAIL_REASONS=""
FAIL_DETAIL=""

# Rewrites one session file. Lines that already have a vector, or that fail to
# embed, are copied through byte for byte; the rest gain embedding and
# embedding_model. The new file replaces the old only once it is complete, so
# an interrupted run leaves the original intact.
_backfill_file() {
	local file="$1" tmp line body changed=0 file_embedded=0 file_missing=0

	tmp="${file}.backfill.$$"
	: >"$tmp" || return 0

	while IFS= read -r line || [[ -n "$line" ]]; do
		if ((STOPPED == 1)); then
			printf '%s\n' "$line" >>"$tmp"
			continue
		fi
		body=$(printf '%s' "$line" | jq -r '
			if ((.embedding | type) == "array" and (.embedding | length) > 0) then empty
			else (.body_redacted // "") end' 2>/dev/null)
		if [[ -z "$body" ]]; then
			printf '%s\n' "$line" >>"$tmp"
			continue
		fi

		file_missing=$((file_missing + 1))
		historian_embedder_parse "$(historian_embedder_embed_reported "$body")"
		if [[ -n "$HISTORIAN_EMBEDDER_VECTOR" ]]; then
			printf '%s' "$line" | jq -c --argjson v "$HISTORIAN_EMBEDDER_VECTOR" --arg m "$MODEL" \
				'. + { embedding: $v, embedding_model: $m }' >>"$tmp"
			changed=1
			file_embedded=$((file_embedded + 1))
			EMBEDDED=$((EMBEDDED + 1))
			CONSECUTIVE=0
		else
			printf '%s\n' "$line" >>"$tmp"
			FAILED=$((FAILED + 1))
			FAIL_REASONS="${FAIL_REASONS}${HISTORIAN_EMBEDDER_REASON}
"
			[[ -z "$FAIL_DETAIL" ]] && FAIL_DETAIL="$HISTORIAN_EMBEDDER_DETAIL"
			# An oversized body fails the same way every time, so it says nothing
			# about whether the embedder is still there.
			if [[ "$HISTORIAN_EMBEDDER_REASON" != "oversized" ]]; then
				CONSECUTIVE=$((CONSECUTIVE + 1))
				((CONSECUTIVE >= MAX_CONSECUTIVE_FAILURES)) && STOPPED=1
			fi
		fi
	done <"$file"

	if ((changed == 1)); then
		mv -f "$tmp" "$file"
	else
		rm -f "$tmp"
	fi
	printf '  %s/%s: %s of %s\n' "$(basename "$(dirname "$(dirname "$file")")")" \
		"$(basename "$file" .jsonl)" "$file_embedded" "$file_missing"
}

for f in ${FILES[@]+"${FILES[@]}"}; do
	((STOPPED == 1)) && break
	n=$(_count_missing "$f")
	((n > 0)) || continue

	# run-index.sh rewrites a session file from scratch under this lock. Without
	# it, a session ending mid-backfill would have one of the two writes lost.
	sid=$(basename "$f" .jsonl)
	lock="${ONLOOKER_DIR}/historian/sessions/${sid}.index.lock"
	mkdir -p "$(dirname "$lock")" 2>/dev/null || true
	if ! lock_acquire "$lock" 0 0; then
		SKIPPED_LOCKED=$((SKIPPED_LOCKED + 1))
		printf '  %s: locked by an indexing run, skipped\n' "$sid"
		continue
	fi
	_backfill_file "$f"
	lock_release "$lock"
done

if ((FAILED > 0)); then
	TOP_REASON=$(printf '%s' "$FAIL_REASONS" \
		| grep -v '^[[:space:]]*$' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
	_emit_failed "${TOP_REASON:-request_failed}" "$((EMBEDDED + FAILED))" "$FAILED" "$FAIL_DETAIL"
fi

printf 'Embedded %s of %s.' "$EMBEDDED" "$(_plural "$TOTAL_MISSING" chunk)"
((FAILED > 0)) && printf ' %s failed (%s).' "$FAILED" "${TOP_REASON:-unknown}"
((SKIPPED_LOCKED > 0)) && printf ' %s skipped while locked.' "$(_plural "$SKIPPED_LOCKED" session)"
printf '\n'

if ((STOPPED == 1)); then
	printf 'historian backfill: stopped after %s failures in a row; the embedder looks to have gone away.\n' \
		"$MAX_CONSECUTIVE_FAILURES" >&2
	printf 'Everything embedded so far is saved. Run this again once it is back.\n' >&2
	exit 1
fi
exit 0
