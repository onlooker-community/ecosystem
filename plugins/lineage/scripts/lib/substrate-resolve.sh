#!/usr/bin/env bash
# Locate the ecosystem substrate from inside a plugin.
#
# Every plugin hook needs validate-path.sh (and sometimes onlooker-schema.sh)
# before it can do anything, and the substrate lives in a sibling plugin whose
# location depends on how the plugin was installed. Fourteen hooks each carried
# a byte-identical copy of this lookup, and the copy was wrong in two ways at
# once (ecosystem-449.36, ecosystem-449.35). Fixing it in fourteen places is how
# it stayed broken; there is one implementation now.
#
# This lib is VENDORED into every plugin by scripts/sync-shared-libs.sh, for the
# same reason config-loader.sh and hook-health.sh are: an installed plugin
# publishes rooted at ./plugins/<name> and has no ecosystem checkout above it,
# so a repo-root path resolves in this checkout and nowhere else (ecosystem-ber).
# Edit the canonical copy at scripts/lib/, run the sync script, commit both.
#
# Bootstrapping note: this is the one shared lib a hook must source BEFORE the
# substrate exists, since finding the substrate is its whole job. It therefore
# depends on nothing but bash and coreutils.
#
# Usage, replacing the old inline block:
#   source "${PLUGIN_ROOT}/scripts/lib/substrate-resolve.sh"
#   _ECOSYSTEM_ROOT=$(onlooker_resolve_substrate "$PLUGIN_ROOT")

# Print the ecosystem root, or nothing. Never fails the caller.
#
# Resolution order:
#   1. $ONLOOKER_ECOSYSTEM_ROOT — explicit override, what the test suite sets.
#   2. Dev checkout — plugins/<name> sits two levels below the ecosystem root.
#   3. Installed — the newest ecosystem under the shared plugin cache parent.
onlooker_resolve_substrate() {
	local plugin_root="${1:-${CLAUDE_PLUGIN_ROOT:-}}"

	if [[ -n "${ONLOOKER_ECOSYSTEM_ROOT:-}" ]]; then
		printf '%s' "$ONLOOKER_ECOSYSTEM_ROOT"
		return 0
	fi

	[[ -n "$plugin_root" ]] || return 0

	local candidate
	candidate="$(cd "${plugin_root}/../.." 2>/dev/null && pwd)" || candidate=""
	if [[ -n "$candidate" && -f "${candidate}/scripts/lib/validate-path.sh" ]]; then
		printf '%s' "$candidate"
		return 0
	fi

	# THREE dirnames, not two (ecosystem-449.36). The match is
	# .../ecosystem/<v>/scripts/lib/validate-path.sh; stripping only lib/ and the
	# filename lands on .../<v>/scripts, and every caller then tested
	# .../<v>/scripts/scripts/lib/validate-path.sh and found nothing. Sourcing
	# the substrate is what exports ONLOOKER_EVENTS_LOG, so the miss was silent
	# at both ends: no substrate, and no signal that there was none.
	#
	# NEWEST, not first (ecosystem-449.35). Glob expansion is lexicographic
	# rather than semver, so 0.33.1 sorts ahead of 0.49.2 and taking the first
	# match bound a month-stale substrate. Measured across a real install, all
	# eight installed plugins resolved to 0.33.1 against an active 0.49.2.
	# sort -V orders by version on BSD/macOS and GNU alike.
	local c newest=""
	while IFS= read -r c; do
		# An unmatched glob expands to the literal pattern, so this -f test is
		# what keeps a non-existent path from counting as a hit.
		[[ -f "$c" ]] && newest="$c"
	done < <(printf '%s\n' "${plugin_root}/../../ecosystem/"*/scripts/lib/validate-path.sh | sort -V)

	[[ -n "$newest" ]] || return 0
	(cd "$(dirname "$(dirname "$(dirname "$newest")")")" 2>/dev/null && pwd) || return 0
}
