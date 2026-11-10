#!/usr/bin/env bash
# Archivist's commit miner, run detached and off the SessionEnd clock.
#
# Usage: archivist-mine-worker.sh <project-key> <repo-root> <cwd>
#
# The SessionEnd hook used to run this loop inline, inside the 1500ms the CLI
# gives the whole SessionEnd batch. Up to date it costs ~50ms, but a session
# that spans a run of merges hands it a backlog: 0.10.4 was killed at 1786ms
# 18 pull requests behind, and every kill prints "Hook cancelled" in the
# terminal as the user exits (ONL-293). Nothing was lost -- the watermark moves
# per commit and the cap drains a backlog over sessions -- but the hook shared
# its deadline with librarian, bursar and the session-end tracker, and a cap
# small enough to always fit would be one the slowest machine sets.
#
# Detaching it, the way librarian's classifier is detached, takes the loop off
# that clock entirely. Librarian's archivist scan windows on mtime (ONL-200),
# so an artifact written here after that scan falls into the next window
# rather than being lost.

set -uo pipefail

PROJECT_KEY="${1:-}"
REPO_ROOT="${2:-}"
CWD="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./hook-health.sh
source "${SCRIPT_DIR}/hook-health.sh"
hook_health_register "archivist-mine-worker"

[[ -z "$PROJECT_KEY" || -z "$REPO_ROOT" ]] && hook_health_exit 0
[[ -z "$CWD" ]] && CWD="$REPO_ROOT"

# shellcheck source=./archivist-ulid.sh
source "${SCRIPT_DIR}/archivist-ulid.sh"
# shellcheck source=./archivist-mine.sh
source "${SCRIPT_DIR}/archivist-mine.sh"
# shellcheck source=./archivist-storage.sh
source "${SCRIPT_DIR}/archivist-storage.sh"

PROJECT_DIR="$(archivist_project_dir "$PROJECT_KEY")"
mkdir -p "$PROJECT_DIR" 2>/dev/null || hook_health_exit 0

# ---------------------------------------------------------------------------
# One miner per project
#
# Two sessions ending together each spawn a worker. Overlapping runs write the
# same content-addressed ids, so the artifacts survive it, but the watermark
# does not: a worker that started earlier can checkpoint an older commit over
# a newer one and re-walk the range. mkdir is the atomic test-and-set, and the
# lock records its owner's pid so a SIGKILL or a reboot cannot wedge it -- the
# same shape as librarian's classify-queue lock (ONL-118). Declining is not a
# failure: the run already in flight will reach HEAD, or the next session will.
# ---------------------------------------------------------------------------
MINE_LOCK="${PROJECT_DIR}/mine.lock"
_mine_lock_stale() {
	local owner=""
	[[ -f "${MINE_LOCK}/pid" ]] && owner=$(cat "${MINE_LOCK}/pid" 2>/dev/null)
	if [[ "$owner" =~ ^[0-9]+$ ]]; then
		! kill -0 "$owner" 2>/dev/null
	else
		[[ -n "$(find "$MINE_LOCK" -maxdepth 0 -mmin +1440 2>/dev/null)" ]]
	fi
}
if ! mkdir "$MINE_LOCK" 2>/dev/null; then
	_mine_lock_stale || hook_health_exit 0
	rm -rf "$MINE_LOCK" 2>/dev/null
	mkdir "$MINE_LOCK" 2>/dev/null || hook_health_exit 0
fi
printf '%s\n' "$$" > "${MINE_LOCK}/pid" 2>/dev/null || true

# hook-health.sh owns the EXIT trap, so the lock is released explicitly on the
# way out rather than by a trap of its own that would replace it.
archivist_mine_worker_exit() {
	rm -rf "$MINE_LOCK" 2>/dev/null || true
	hook_health_exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Watermark
#
# Its own file rather than a field in manifest.json, because
# archivist_storage_write_manifest rewrites that document wholesale from a fixed
# shape and would clobber anything added beside its keys.
#
# Read under the lock, not handed over by the hook: a worker that finished
# while this one waited to be spawned has moved it.
# ---------------------------------------------------------------------------
MINED_PATH="${PROJECT_DIR}/mined.json"
WATERMARK=""
if [[ -f "$MINED_PATH" ]]; then
	WATERMARK=$(jq -r '.last_sha // ""' "$MINED_PATH" 2>/dev/null) || WATERMARK=""
fi

# A watermark naming a commit this repository no longer has - a reclone, a
# rewritten history - is not a reason to mine nothing forever. Drop it and
# start over; content-addressed ids make the re-mine an overwrite.
if [[ -n "$WATERMARK" ]] && ! git -C "$REPO_ROOT" cat-file -e "${WATERMARK}^{commit}" 2>/dev/null; then
	WATERMARK=""
fi

RANGE="HEAD"
[[ -n "$WATERMARK" ]] && RANGE="${WATERMARK}..HEAD"

# --first-parent: on a squash-merged repository every commit on the default
# branch is one pull request, and following merge parents would mine branch
# commits whose messages the squash already carries.
COMMITS=$(git -C "$REPO_ROOT" log --first-parent --format='%H %ct' "$RANGE" 2>/dev/null | tail -r 2>/dev/null || \
	git -C "$REPO_ROOT" log --first-parent --reverse --format='%H %ct' "$RANGE" 2>/dev/null)
[[ -z "$COMMITS" ]] && archivist_mine_worker_exit 0

# ---------------------------------------------------------------------------
# Per-run cap
#
# Each commit measured 43-62ms. Inline, inside SessionEnd's 1500ms, a backlog
# past roughly 25 commits could not finish in one run, and before the watermark
# moved per commit that was not a slow run but a stuck one: the dotfiles repo
# sat 182 commits behind, killed at ~1510ms on every session end for almost
# four weeks.
#
# Off the clock the cap no longer guards a deadline, but it still bounds how
# long a worker holds the lock and how much one run can write before a
# session's librarian scan looks. Oldest first, so the newest work is what
# waits, never a gap. 0 means no cap.
# ---------------------------------------------------------------------------
# shellcheck source=./archivist-config.sh
source "${SCRIPT_DIR}/archivist-config.sh"
archivist_config_load "$CWD"
MAX_COMMITS=$(archivist_config_int '.archivist.mining.max_commits_per_run' 10)
if (( MAX_COMMITS > 0 )); then
	# A here-string, not `printf | head`: head closing the pipe early makes printf
	# report a broken pipe on stderr.
	COMMITS=$(head -n "$MAX_COMMITS" <<< "$COMMITS")
fi

# Atomic, because it is written while the run can still be killed: a truncated
# mined.json parses as no watermark, which re-mines the whole history.
archivist_mine_checkpoint() {
	local sha="$1" tmp
	mkdir -p "$(dirname "$MINED_PATH")" 2>/dev/null || return 0
	tmp="${MINED_PATH}.tmp.$$"
	printf '{"last_sha":"%s","at":"%s"}\n' \
		"$sha" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$tmp" 2>/dev/null &&
		mv -f "$tmp" "$MINED_PATH" 2>/dev/null || rm -f "$tmp" 2>/dev/null
	return 0
}

wrote_any=0
write_failed=0
while IFS=' ' read -r sha epoch; do
	[[ -z "$sha" ]] && continue

	body=$(git -C "$REPO_ROOT" log -1 --format='%B' "$sha" 2>/dev/null) || continue
	files=$(git -C "$REPO_ROOT" show --name-only --format='' "$sha" 2>/dev/null | jq -R . | jq -sc 'map(select(length > 0))')
	created=$(date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
	# The session that wrote it, when the commit convention records one.
	session=$(printf '%s' "$body" | sed -n 's/^Claude-Session:.*session_\([A-Za-z0-9]*\).*$/\1/p' | head -1)

	record=""
	while IFS= read -r -d '' record || [[ -n "$record" ]]; do
		[[ -z "$record" ]] && continue

		summary=$(printf '%s' "$record" | head -1)
		detail=$(printf '%s' "$record" | tail -n +2 | sed '/./,$!d')
		# A claim with no rationale. The durability filter downstream would
		# drop it anyway; skipping here keeps the store free of records nothing
		# will ever promote -- and keeps the classifier and the lesson transform
		# from paying a model call each to distill a generated changelog.
		#
		# Covers an absent body AND a body that is only git trailers or
		# separator rules, which is what a release-please or auto-format commit
		# leaves behind once the squash split has consumed its bullets
		# (ONL-170).
		if ! archivist_mine_has_rationale "$detail"; then
			record=""
			continue
		fi

		id=$(archivist_mine_id "$record")
		json=$(jq -n \
			--arg id "$id" \
			--arg key "$PROJECT_KEY" \
			--arg created "$created" \
			--arg summary "$summary" \
			--arg detail "$detail" \
			--argjson files "${files:-[]}" \
			--arg session "$session" \
			'{
				id: $id,
				kind: "decision",
				project_key: $key,
				source: "local",
				created_at: $created,
				updated_at: $created,
				summary: $summary,
				detail: $detail,
				files: $files,
				session_id: (if $session == "" then null else $session end),
				trigger: "commit"
			}' 2>/dev/null) || { record=""; continue; }

		if archivist_storage_write_artifact "$PROJECT_KEY" "decisions" "$id" "$json" >/dev/null 2>&1; then
			wrote_any=1
		else
			write_failed=1
		fi
		record=""
	done < <(archivist_mine_split "$body")

	# The watermark never moves ahead of the artifacts it claims to describe -
	# ecosystem-449.55 is what the inverse costs, and its failure is invisible
	# because the watermark is the thing asserting all is well. So a failed write
	# stops the run here, leaving the watermark on the last commit that landed
	# whole; the next session retries from this commit.
	(( write_failed )) && break

	# The condition is "nothing FAILED", not "something was written". Those came
	# apart once a body of pure metadata became a legitimate skip: a commit that
	# is all release or auto-format noise writes nothing and has still been
	# examined, and gating on wrote_any would re-walk it on every session end
	# forever. $wrote_any stays because it reads as the intent at a glance.
	#
	# After every commit rather than once at the end, so a run that is killed
	# keeps what it finished instead of handing the whole range to the next one.
	archivist_mine_checkpoint "$sha"
done <<< "$COMMITS"

archivist_mine_worker_exit 0
