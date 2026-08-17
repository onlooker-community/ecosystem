#!/usr/bin/env bash
# cartographer-filter.sh — narrow an audit to one finding type or one subtree.
#
# SKILL.md documented a --phase flag and a --scope flag that run-audit.sh never
# read, so both silently ran a full audit (ecosystem-9og). The vocabulary was
# wrong too: --phase listed finding TYPES, while the pipeline's phases are
# discover/extract/relate/synthesize/emit. The flag is --type here for that
# reason — it narrows what the audit looks FOR, not which stage runs.
#
# The five types do not map one-to-one onto analyzer calls:
#
#   contradiction        \_ one LLM pass emits either type, so neither can be
#   dead_rule            /  requested without running the other
#   stale_ref            — its own call
#   scope_collision      — its own call
#   undocumented_entity  — its own call
#
# So narrowing works in two steps: skip the analyzers that cannot produce the
# requested type, then drop any findings the surviving analyzers produced that
# were not asked for. Skipping is where the savings are — each analyzer skipped
# is an LLM call not made.

CARTOGRAPHER_FINDING_TYPES="contradiction dead_rule stale_ref scope_collision undocumented_entity"

# True when a type filter is set and valid.
#
# An unrecognized value is rejected rather than silently matching nothing: a
# typo that quietly produced an empty audit would look exactly like a clean
# repo, which is the failure this whole issue is about.
#
# Usage: cartographer_filter_valid_type <type>
cartographer_filter_valid_type() {
	local want="${1:-}"
	[[ -z "$want" ]] && return 1
	local t
	for t in $CARTOGRAPHER_FINDING_TYPES; do
		[[ "$t" == "$want" ]] && return 0
	done
	return 1
}

# True when the analyzer should run under the active filter.
#
# An empty filter means no filter, so everything runs. The contradiction
# analyzer answers to both of the types it can emit.
#
# Usage: cartographer_filter_wants <analyzer> <type_filter>
#   analyzer: contradiction | stale_ref | scope_collision | undocumented_entity
cartographer_filter_wants() {
	local analyzer="${1:-}" filter="${2:-}"
	[[ -z "$filter" ]] && return 0
	[[ -z "$analyzer" ]] && return 1

	if [[ "$analyzer" == "contradiction" ]]; then
		[[ "$filter" == "contradiction" || "$filter" == "dead_rule" ]]
		return
	fi
	[[ "$analyzer" == "$filter" ]]
}

# Drop findings whose type was not requested.
#
# Only the contradiction analyzer can return a type other than the one asked
# for, but filtering the whole set is simpler than special-casing it and stays
# correct if an analyzer gains a second output type later.
#
# Usage: cartographer_filter_findings <findings_json> <type_filter>
cartographer_filter_findings() {
	local findings="${1:-[]}" filter="${2:-}"
	if [[ -z "$filter" ]]; then
		printf '%s' "$findings"
		return 0
	fi
	printf '%s' "$findings" \
		| jq -c --arg t "$filter" '[.[] | select(.type == $t)]' 2>/dev/null \
		|| printf '[]'
}

# Restrict a discovered-file list to those under a subtree.
#
# The scope narrows which instruction files are ANALYZED; it deliberately does
# not become the repo root, because stale_ref resolves path-like tokens against
# the real root and would otherwise report every path outside the scope as
# broken.
#
# A scope matching nothing yields an empty list, which is a legitimate answer —
# the caller decides whether that is worth reporting.
#
# Usage: cartographer_filter_scope <files_json> <repo_root> <scope_path>
cartographer_filter_scope() {
	local files="${1:-[]}" repo_root="${2:-}" scope="${3:-}"
	if [[ -z "$scope" ]]; then
		printf '%s' "$files"
		return 0
	fi

	# Accept a repo-relative scope or an absolute one.
	local abs="$scope"
	[[ "$abs" != /* ]] && abs="${repo_root%/}/${scope#./}"
	abs="${abs%/}"

	printf '%s' "$files" \
		| jq -c --arg p "$abs" '[.[] | select(. == $p or startswith($p + "/"))]' 2>/dev/null \
		|| printf '[]'
}
