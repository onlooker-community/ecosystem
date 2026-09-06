#!/usr/bin/env bash
# Locate the ecosystem substrate from inside an installed plugin.
#
# Every hook that needs $ONLOOKER_DIR / $ONLOOKER_EVENTS_LOG has to find
# validate-path.sh before it can source it, and an installed plugin cannot
# assume where that is: it may sit beside an ecosystem checkout, or alone in a
# version-keyed plugin cache with the ecosystem several directories away. This
# answers that one question and nothing else.
#
# This file is vendored. scripts/lib/ecosystem-root.sh is canonical, and a
# byte-identical copy sits in every plugins/<name>/scripts/lib/. Edit the
# canonical one, then run scripts/sync-shared-libs.sh to propagate it;
# test/bats/shared-lib-vendoring.bats fails on any copy that drifts.
#
# WHY THIS IS A LIB AND NOT FIVE LINES IN EACH HOOK. It was five lines in each
# hook -- fifteen copies of one glob loop, and every copy carried the same two
# defects (ecosystem-449.36, ecosystem-449.35). Fixing them fifteen times is
# how the second one survived the first repair of the first.
#
# Usage:
#   source "${PLUGIN_ROOT}/scripts/lib/ecosystem-root.sh"
#   _ECOSYSTEM_ROOT="$(onlooker_ecosystem_root)"
#   if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
#   	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
#   fi
#
# The caller keeps its own -f guard. This function answers "where is the
# ecosystem, if anywhere", and an empty answer is a real state -- a plugin
# installed with no ecosystem above it -- not an error to report.

# Resolved at source time from this file's OWN path, never from a caller's
# $PLUGIN_ROOT. That variable is read from whatever scope did the sourcing, so
# a sub-shell inheriting CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would resolve
# to nothing while still exiting 0 (ecosystem-88v, ecosystem-7bj). This lib is
# always at <plugin_root>/scripts/lib/, so two levels up is the plugin root in
# either layout.
_ONLOOKER_ECOSYSTEM_ROOT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print the ecosystem root, or nothing if there is none. "No ecosystem here" is
# a real state rather than an error -- a plugin installed with nothing above it
# -- so it prints nothing and leaves the decision to the caller's own -f guard.
#
# The exit status is deliberately not part of the contract: every caller reads
# this through command substitution and branches on the -f guard, never on $?.
# What matters is that a path only ever reaches stdout when it was resolved
# from a validate-path.sh that was seen to exist.
#
# $1 - plugin root to search from. Defaults to this lib's own plugin, which is
#      what every hook wants; tests pass one explicitly to drive a fixture.
onlooker_ecosystem_root() {
	# An explicit pin wins over discovery. The bats suite exports this to point
	# every plugin at the checkout under test, and a hook that consulted the
	# glob anyway would silently exercise an installed copy instead.
	if [[ -n "${ONLOOKER_ECOSYSTEM_ROOT:-}" ]]; then
		printf '%s' "$ONLOOKER_ECOSYSTEM_ROOT"
		return 0
	fi

	local plugin_root="${1:-}"
	if [[ -z "$plugin_root" ]]; then
		plugin_root="$(cd "${_ONLOOKER_ECOSYSTEM_ROOT_LIB_DIR}/../.." 2>/dev/null && pwd)"
	fi
	[[ -n "$plugin_root" ]] || return 0

	# The monorepo and sibling-checkout layout: plugins/<name> sits two levels
	# under the ecosystem root itself. Checked first because it is exact --
	# there is no version to choose between.
	local candidate
	candidate="$(cd "${plugin_root}/../.." 2>/dev/null && pwd)"
	if [[ -n "$candidate" && -f "${candidate}/scripts/lib/validate-path.sh" ]]; then
		printf '%s' "$candidate"
		return 0
	fi

	# The installed layout: <cache>/<plugin>/<v>/ beside <cache>/ecosystem/<v>/.
	#
	# THREE dirnames, not two (ecosystem-449.36). The match is
	# .../ecosystem/<v>/scripts/lib/validate-path.sh; stripping only lib/ and
	# the filename lands on .../<v>/scripts, and the caller's guard then looks
	# for .../<v>/scripts/scripts/lib/validate-path.sh and finds nothing. The
	# substrate went unsourced, and because sourcing it is what exports
	# ONLOOKER_EVENTS_LOG, that failed silently in both directions.
	#
	# NEWEST, not first (ecosystem-449.35). Glob expansion is lexicographic,
	# so 0.33.1 sorted ahead of 0.49.2 and a break-on-first-hit bound whatever
	# sorted first -- a month stale, on every installed plugin measured.
	# sort -V orders by version on both BSD/macOS and GNU. Fixing only the
	# doubling would have started sourcing that stale copy for real, which is
	# why the two have to move together.
	local newest=""
	while IFS= read -r candidate; do
		[[ -f "$candidate" ]] && newest="$candidate"
	done < <(printf '%s\n' "${plugin_root}/../../ecosystem/"*/scripts/lib/validate-path.sh | sort -V)
	# An unmatched glob expands to the literal pattern; the -f test above is
	# what keeps that from being mistaken for a hit.
	[[ -n "$newest" ]] || return 0

	(cd "$(dirname "$(dirname "$(dirname "$newest")")")" 2>/dev/null && pwd)
}
