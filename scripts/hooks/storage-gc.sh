#!/usr/bin/env bash
# Onlooker Storage GC
# Invoked by SessionEnd (matcher: *).
#
# Runs scripts/onlooker-store-prune.mjs at most once per interval_hours, so the
# store's retention windows apply without anyone remembering to run the prune
# (ONL-44). It went unrun from August to November and the backlog reached 61k
# files.
#
# THE PRUNE RUNS DETACHED. A dry run alone measured 1.9s against the real store,
# and a plugin's SessionEnd hook is killed at 1500ms whatever hooks.json says.
# This hook only decides whether a run is due and launches it, so it costs a
# stamp check on almost every session. The run's report lands in
# storage-gc/last-run.json.
#
# The stamp is touched when a run LAUNCHES, not when it finishes: a run that
# fails waits a full interval rather than being retried by every session that
# ends in the meantime.
#
# Hook contract:
#   - Always exits 0. Never blocks session end.
#   - Never creates ~/.onlooker for a user who has none.

set -uo pipefail # No -e: never block session termination

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read before registering: hook-health's start breadcrumb creates
# $ONLOOKER_DIR/logs, which would make an absent store look present.
ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}"
STORE_PRESENT=0
[[ -d "$ONLOOKER_DIR" ]] && STORE_PRESENT=1

# shellcheck source=../lib/hook-health.sh
source "$SCRIPT_DIR/../lib/hook-health.sh"
hook_health_register "storage-gc"

# shellcheck source=../lib/config-loader.sh
source "$SCRIPT_DIR/../lib/config-loader.sh"

INPUT=$(cat 2>/dev/null || true)
hook_health_context "$INPUT"

(( STORE_PRESENT )) || hook_health_exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
[[ -z "$CWD" ]] && CWD="$(pwd)"

_STORAGE_GC_CONFIG="{}"
config_load_plugin "storage_gc" "$CWD" "_STORAGE_GC_CONFIG"

[[ "$(config_get _STORAGE_GC_CONFIG '.storage_gc.enabled')" == "false" ]] && hook_health_exit 0

INTERVAL_HOURS=$(config_get_int _STORAGE_GC_CONFIG '.storage_gc.interval_hours' 24)
SCRATCH_HOURS=$(config_get_int _STORAGE_GC_CONFIG '.storage_gc.scratch_max_age_hours' 48)
RETENTION_DAYS=$(config_get_int _STORAGE_GC_CONFIG '.storage_gc.retention_days' 90)

GC_DIR="${ONLOOKER_DIR}/storage-gc"
STAMP="${GC_DIR}/last-run"
REPORT="${GC_DIR}/last-run.json"
LOCK="${GC_DIR}/run.lock"

# find -mmin is the portable mtime test: stat's flags differ between BSD and GNU.
if [[ -f "$STAMP" && -n "$(find "$STAMP" -mmin "-$((INTERVAL_HOURS * 60))" 2>/dev/null)" ]]; then
	hook_health_exit 0
fi

mkdir -p "$GC_DIR" 2>/dev/null || hook_health_exit 0

# A run that was killed outright never removes its lock, and the sweep would
# stop for good the first time that happened. No run on a real store takes
# anywhere near an hour.
if [[ -d "$LOCK" && -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]]; then
	rmdir "$LOCK" 2>/dev/null || true
fi

# mkdir is the atomic test-and-set: two sessions ending together launch one run.
mkdir "$LOCK" 2>/dev/null || hook_health_exit 0
touch "$STAMP" 2>/dev/null || true

PRUNE="${SCRIPT_DIR}/../onlooker-store-prune.mjs"

# setsid detaches from the controlling terminal so ending the session does not
# SIGHUP the run mid-flight; nohup alone on macOS, where setsid is absent. The
# report is written to a temp file and renamed, so a reader never sees half.
_sweep() {
	trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
	node "$PRUNE" --dir "$ONLOOKER_DIR" \
		--scratch-max-age-hours "$SCRATCH_HOURS" \
		--retention-days "$RETENTION_DAYS" \
		--json >"${REPORT}.tmp" 2>/dev/null \
		&& mv "${REPORT}.tmp" "$REPORT"
}
export -f _sweep
export ONLOOKER_DIR PRUNE SCRATCH_HOURS RETENTION_DAYS REPORT LOCK
if command -v setsid >/dev/null 2>&1; then
	nohup setsid bash -c _sweep >/dev/null 2>&1 &
else
	nohup bash -c _sweep >/dev/null 2>&1 &
fi
disown 2>/dev/null || true

hook_health_exit 0
