#!/usr/bin/env bash
# Probe cache for the plugin-currency surfacer (ecosystem-449.59).
#
# GOVERNING INVARIANT
#   Absence of a finding in an EXPIRED cache is not evidence of currency.
#
# Every consumer must treat "not fresh" as "unknown", never as "current".
# Breaking this recreates the outage the surfacer exists to catch: a detector
# that answers from a stale cache with no signal that it is stale is doing
# exactly what refs/remotes/origin/<branch> does. Two instruments have already
# produced wrong conclusions this way in this epic -- that ref reported a behind
# clone as current, and lastUpdated read without installedAt made never-updated
# pins look freshly updated (ecosystem-o2s).
#
# Hence: every failure mode below returns "not fresh" rather than guessing.
# Missing file, unreadable file, missing checked_at, unparseable checked_at --
# all of them mean we do not know, and not knowing is never currency.

# Path to the probe cache for a project key.
# Usage: path=$(plugin_currency_cache_path "$project_key")
plugin_currency_cache_path() {
	printf '%s/currency/%s/probe.json' "${ONLOOKER_DIR:-}" "${1:-unknown}"
}

# Age of the cached answer in seconds, or empty when it cannot be determined.
# Empty is load-bearing: callers must not read it as zero.
# Usage: age=$(plugin_currency_cache_age_seconds "$path")
plugin_currency_cache_age_seconds() {
	local path="${1:-}" stamp then_ts now
	[[ -f "$path" ]] || return 0

	stamp=$(jq -r '.checked_at // empty' "$path" 2>/dev/null) || return 0
	[[ -n "$stamp" ]] || return 0

	# python3 for portable parsing: `date -d` is GNU and `date -j -f` is BSD,
	# and this lib ships to both.
	then_ts=$(python3 -c 'import sys, datetime
try:
    print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))
except Exception:
    pass' "$stamp" 2>/dev/null) || return 0
	[[ -n "$then_ts" ]] || return 0

	now=$(date -u +%s)
	printf '%s' "$(( now - then_ts ))"
}

# True (0) only when the cache exists, parses, and is younger than the ttl.
# Usage: if plugin_currency_cache_is_fresh "$path" "$ttl_hours"; then ...
plugin_currency_cache_is_fresh() {
	local path="${1:-}" ttl_hours="${2:-6}" age
	age=$(plugin_currency_cache_age_seconds "$path")
	[[ -n "$age" ]] || return 1
	[[ "$age" -lt $(( ttl_hours * 3600 )) ]]
}

# Write findings with checked_at stamped now.
#
# Callers must NOT call this after a failed probe. Restamping checked_at on an
# answer we did not actually re-verify is the precise failure this lib exists to
# prevent: it makes a stale answer look fresh, which is worse than no cache.
# Usage: plugin_currency_cache_write "$path" "$findings_json"
plugin_currency_cache_write() {
	local path="${1:-}" findings="${2:-[]}"
	[[ -n "$path" ]] || return 1
	mkdir -p "$(dirname "$path")" || return 1
	# Write-then-rename. The probe runs detached, so a session can be reading
	# this file while another writes it; a partial write would read back as an
	# unparseable cache, which is survivable, but a torn one that still parses
	# would not be.
	local tmp="${path}.tmp.$$"
	if ! jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson f "$findings" \
		'{checked_at: $t, findings: $f}' >"$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}
