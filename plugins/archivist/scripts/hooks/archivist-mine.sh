#!/usr/bin/env bash
# Archivist SessionEnd mining hook.
#
# Reads first-parent commits on whatever branch is checked out (HEAD, not the
# default branch) since a watermark, turns each authored message into an
# artifact, and writes them through the same storage the PreCompact extractor
# uses. Mining a feature branch and then its squash on main yields the same
# content-addressed id, so the second pass overwrites rather than duplicates.
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
# The mining itself runs in scripts/lib/archivist-mine-worker.sh, detached. This
# hook only decides whether there is anything to mine, so it returns well inside
# SessionEnd's 1500ms however far behind the watermark is (ONL-293).
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

# shellcheck source=../lib/onlooker-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
# shellcheck source=../lib/archivist-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"

INPUT=$(cat 2>/dev/null || printf '')
hook_health_context "$INPUT"
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
[[ -z "$CWD" ]] && CWD="$(pwd)"

onlooker_project_resolve "$CWD"
PROJECT_KEY="$ONLOOKER_PROJECT_KEY"
# No git context means no store to write into, and nothing to mine.
[[ -z "$PROJECT_KEY" ]] && hook_health_exit 0

REPO_ROOT=$(onlooker_project_repo_root "$CWD")
[[ -z "$REPO_ROOT" ]] && hook_health_exit 0

# The common case, and the only one decided here: the watermark already names
# HEAD. Anything else -- new commits, a stale watermark, none at all -- is the
# worker's to sort out under its lock, so this check never has to agree with
# the worker's range logic, only to be a cheap way of not spawning one.
MINED_PATH="$(archivist_project_dir "$PROJECT_KEY")/mined.json"
if [[ -f "$MINED_PATH" ]]; then
	WATERMARK=$(jq -r '.last_sha // ""' "$MINED_PATH" 2>/dev/null) || WATERMARK=""
	HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse -q --verify HEAD 2>/dev/null) || HEAD_SHA=""
	[[ -n "$WATERMARK" && "$WATERMARK" == "$HEAD_SHA" ]] && hook_health_exit 0
fi

# Detached, following librarian's _spawn_one: output discarded, stdin closed,
# disowned so SessionEnd does not wait on it. fd 3 is closed too, or a bats
# test running this hook would wait on the worker through it.
#
# ARCHIVIST_MINE_WORKER is a test seam; ARCHIVIST_MINE_FOREGROUND runs the
# worker inline so a test can assert on what it wrote without racing it.
WORKER="${ARCHIVIST_MINE_WORKER:-${PLUGIN_ROOT}/scripts/lib/archivist-mine-worker.sh}"
[[ -f "$WORKER" ]] || hook_health_exit 0

if [[ "${ARCHIVIST_MINE_FOREGROUND:-}" == "1" ]]; then
	bash "$WORKER" "$PROJECT_KEY" "$REPO_ROOT" "$CWD" </dev/null >/dev/null 2>&1
else
	bash "$WORKER" "$PROJECT_KEY" "$REPO_ROOT" "$CWD" </dev/null >/dev/null 2>&1 3>&- &
	disown 2>/dev/null || true
fi

hook_health_exit 0
