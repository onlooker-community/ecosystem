#!/usr/bin/env bash
# Archivist SessionEnd mining hook.
#
# Reads commits on the default branch since a watermark, turns each authored
# message into an artifact, and writes them through the same storage the
# PreCompact extractor uses.
#
# Why this exists alongside archivist-extract: that hook has fired zero times on
# the machine that dogfoods this marketplace, because compaction is its only
# trigger and compaction is a proxy for context pressure rather than for
# insight. A long uneventful session compacts and gets mined; a short one where
# something was learned does not.
#
# And the distillation has usually already happened. A commit body written under
# a convention that demands "why" is a claim with its rationale attached, by the
# agent that made it, at the moment it understood it. This reads that rather
# than paying a model to reconstruct it from a transcript later.
#
# Hook contract:
#   - Always exits 0. Session end is never blocked.
#   - Skips silently with no git context (no project key).
#   - Makes no model call, so unlike the extractor it cannot recurse.

set -uo pipefail

# Uniformity with the other archivist hooks. This one calls no model, so the
# nested case cannot arise the way it could for the extractor - kept so the
# family reads the same way rather than because a loop is reachable here.
[[ "${ARCHIVIST_NESTED:-}" == "1" ]] && exit 0
export ARCHIVIST_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "archivist-mine"

# shellcheck source=../lib/archivist-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-project-key.sh"
# shellcheck source=../lib/archivist-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-ulid.sh"
# shellcheck source=../lib/archivist-mine.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-mine.sh"
# shellcheck source=../lib/archivist-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"

INPUT=$(cat 2>/dev/null || printf '')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
[[ -z "$CWD" ]] && CWD="$(pwd)"

PROJECT_KEY=$(archivist_project_key "$CWD")
# No git context means no store to write into, and nothing to mine.
[[ -z "$PROJECT_KEY" ]] && exit 0

REPO_ROOT=$(archivist_project_repo_root "$CWD")
[[ -z "$REPO_ROOT" ]] && exit 0

# ---------------------------------------------------------------------------
# Watermark
#
# Its own file rather than a field in manifest.json, because
# archivist_storage_write_manifest rewrites that document wholesale from a fixed
# shape and would clobber anything added beside its keys.
# ---------------------------------------------------------------------------
MINED_PATH="$(archivist_project_dir "$PROJECT_KEY")/mined.json"
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
[[ -z "$COMMITS" ]] && exit 0

HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || exit 0

wrote_any=0
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
		# A subject with no body is a claim with no rationale. The durability
		# filter downstream would drop it anyway; skipping here keeps the store
		# free of records nothing will ever promote.
		[[ -z "$detail" ]] && { record=""; continue; }

		id=$(archivist_mine_id "$record" "$((epoch * 1000))")
		json=$(jq -n \
			--arg id "$id" \
			--arg key "$PROJECT_KEY" \
			--arg created "$created" \
			--arg summary "$summary" \
			--arg detail "$detail" \
			--argjson files "${files:-[]}" \
			--arg session "${session:-unknown}" \
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
				session_id: $session,
				trigger: "commit"
			}' 2>/dev/null) || { record=""; continue; }

		if archivist_storage_write_artifact "$PROJECT_KEY" "decisions" "$id" "$json" >/dev/null 2>&1; then
			wrote_any=1
		fi
		record=""
	done < <(archivist_mine_split "$body")
done <<< "$COMMITS"

# Only now. The watermark never moves ahead of the artifacts it claims to
# describe - ecosystem-449.55 is what the inverse costs, and its failure is
# invisible because the watermark is the thing asserting all is well.
if [[ $wrote_any -eq 1 ]]; then
	printf '{"last_sha":"%s","at":"%s"}\n' \
		"$HEAD_SHA" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$MINED_PATH" 2>/dev/null || true
fi

exit 0
