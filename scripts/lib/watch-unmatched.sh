#!/usr/bin/env bash
# Watch-unmatched signal (ecosystem-449.21).
#
# GOVERNING RULE
#   Each mode mirrors its plugin's real matcher.
#
# A plugin that exits 0 and emits nothing looks exactly like a plugin with
# nothing to report. This lib answers the one question that separates them:
# do these configured patterns match zero paths in this repository at all?
# That is a property of repo plus config, not of the turn -- which is why it
# is marker-gated rather than emitted on every fire.
#
# The check must agree with the matcher it describes. Echo matches git-tracked
# paths; cartographer expands globs against the filesystem and so sees
# untracked and gitignored paths too. One scanner would disagree with one of
# them and invent misconfigurations that are not there.
#
# This lib will be VENDORED via scripts/sync-shared-libs.sh's ON_DEMAND_LIBS
# (only echo and cartographer source it, not every plugin -- SHARED_LIBS would
# mint copies nothing reads): an installed plugin publishes rooted at
# ./plugins/<name> and has no ecosystem checkout above it, so a repo-root path
# resolves in this checkout and nowhere else (ecosystem-ber).

# Default re-arm window. A deliberate constant, not config: pure edge-triggering
# makes a misconfiguration emitted once on day 1 invisible to a query over the
# last two days, which is the exact ambiguity this signal exists to remove.
_ONLOOKER_WATCH_TTL_HOURS_DEFAULT=168

_onlooker_watch_sha256_first12() {
	local input="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

# Seconds since epoch for an ISO-8601 UTC stamp, or empty when unparseable.
# python3 rather than `date`: -d vs -v diverges between GNU and BSD/macOS.
_onlooker_watch_epoch() {
	python3 -c '
import datetime, sys
try:
    d = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
    print(int(d.replace(tzinfo=datetime.timezone.utc).timestamp()))
except Exception:
    sys.exit(1)
' "$1" 2>/dev/null
}

# The ":-$HOME/.onlooker" fallback is load-bearing, not decoration. This is
# called from echo-stop-gate.sh at a point ABOVE where that hook establishes its
# own ONLOOKER_BASE (line 173), so a bare "${ONLOOKER_DIR:-}" would resolve to
# "/watch-unmatched/..." and fail to write with no error anyone would see. Both
# call-site hooks already use exactly this fallback (echo-stop-gate.sh:173,
# cartographer-session-start.sh:49); the env var still wins where it is set,
# which is what CLAUDE.md item 3 requires.
onlooker_watch_marker_path() {
	printf '%s/watch-unmatched/%s/%s.json' \
		"${ONLOOKER_DIR:-$HOME/.onlooker}" "${1:-unknown}" "${2:-unknown}"
}

# Hash over the SORTED pattern list. Reordering watch_paths is not a change in
# meaning and must not re-arm the signal; editing one is and must.
onlooker_watch_patterns_hash() {
	local sorted
	sorted=$(printf '%s' "${1:-[]}" | jq -cS 'sort' 2>/dev/null) || return 1
	[[ -z "$sorted" || "$sorted" == "null" ]] && return 1
	_onlooker_watch_sha256_first12 "$sorted"
}

# Due when: no marker, hash differs, stamp missing/unparseable, or age > ttl.
# Every unknown resolves to "due" -- under-reporting a live misconfiguration is
# the failure this bead exists to fix, so ambiguity errs toward emitting.
onlooker_watch_marker_due() {
	local path="${1:-}" hash="${2:-}" ttl_hours="${3:-$_ONLOOKER_WATCH_TTL_HOURS_DEFAULT}"
	[[ -f "$path" ]] || return 0

	local stored_hash stored_at then now
	stored_hash=$(jq -r '.patterns_hash // ""' "$path" 2>/dev/null) || return 0
	[[ "$stored_hash" != "$hash" ]] && return 0

	stored_at=$(jq -r '.last_emitted // ""' "$path" 2>/dev/null) || return 0
	[[ -z "$stored_at" ]] && return 0

	then=$(_onlooker_watch_epoch "$stored_at") || return 0
	[[ -z "$then" ]] && return 0
	now=$(date +%s)
	(( now - then > ttl_hours * 3600 )) && return 0
	return 1
}

# Write-then-rename: concurrent sessions in one project race on this file, and
# a torn write that still parses would be worse than one that does not.
onlooker_watch_marker_write() {
	local path="${1:-}" hash="${2:-}"
	[[ -z "$path" ]] && return 1
	mkdir -p "$(dirname "$path")" 2>/dev/null || return 1

	local tmp="${path}.tmp.$$"
	if ! jq -n --arg h "$hash" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{patterns_hash: $h, last_emitted: $t}' >"$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

onlooker_watch_marker_clear() {
	[[ -n "${1:-}" ]] && rm -f "$1" 2>/dev/null
	return 0
}
