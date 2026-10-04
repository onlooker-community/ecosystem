#!/usr/bin/env bats
#
# Shipped path defaults must match layouts that exist outside this repository.
#
# ecosystem-449.15. echo shipped watch_paths defaulting to
# ["plugins/*/agents/*.md"], a shape that describes this marketplace repo and
# essentially nothing else. A consumer without that layout installed echo,
# registered its Stop hook, paid the cost, and matched nothing — forever,
# silently, with no warning and no event. cartographer shipped the same class
# of default in undocumented_entity.globs (["plugins/*/", "skills/*/"]).
#
# The failure mode is an absence, so nothing catches it: exit 0, no output,
# indistinguishable from "nothing changed". These tests assert the defaults
# against layouts actually observed on disk, so a repo-shaped default cannot
# be reintroduced without a test naming the repo it would exclude.
#
# ONL-103 retired echo's stop gate and watch_paths went with it, so the echo
# arm of this file is gone. Worth knowing how it went: once the key was absent
# jq returned null, three of its four tests failed loudly — and the fourth,
# which asserted the defaults do NOT match ordinary source files, passed
# VACUOUSLY, because a negated match over an empty pattern list always
# succeeds. cartographer carries the guard now, plus the generic sweep at the
# bottom, which reads every plugin config and so covers plugins added later.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

# Returns 0 if any pattern in the JSON array matches the path.
_matches_any() {
	local path="$1" patterns_json="$2" pat
	while IFS= read -r pat; do
		[[ -z "$pat" ]] && continue
		# shellcheck disable=SC2053
		[[ "$path" == $pat ]] && return 0
	done < <(printf '%s' "$patterns_json" | jq -r '.[]')
	return 1
}

_carto_globs() { jq -c '.cartographer.undocumented_entity.globs' "${REPO_ROOT}/plugins/cartographer/config.json"; }

# cartographer expands its globs with real pathname globbing under `shopt -s
# nullglob` (cartographer-omission.sh:69), where `*` does NOT cross `/`. That
# is a different matcher from echo's `[[ $f == $pat ]]`, so this test expands
# the globs for real against a fixture tree rather than reusing _matches_any.
@test "cartographer's default globs are not limited to this repo's layout" {
	local fixture="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "${fixture}/.claude/agents" "${fixture}/plugins/tribunal"

	local found glob
	found=""
	shopt -s nullglob
	while IFS= read -r glob; do
		[[ -z "$glob" ]] && continue
		local matches=( "${fixture}"/${glob} )
		[[ ${#matches[@]} -gt 0 ]] && found+="${matches[*]} "
	done < <(_carto_globs | jq -r '.[]')
	shopt -u nullglob

	[[ "$found" == *".claude/agents"* ]] || { echo "missed .claude/agents/ (found: $found)"; return 1; }
	[[ "$found" == *"plugins/tribunal"* ]] || { echo "regressed this repo (found: $found)"; return 1; }
	true
}

# The guard against reintroduction: no shipped default may consist ONLY of
# patterns rooted at plugins/ or skills/, because that is the shape unique to
# a marketplace repo.
@test "no shipped path default is exclusively marketplace-shaped" {
	local f name arrays
	for f in "${REPO_ROOT}"/plugins/*/config.json; do
		name=$(basename "$(dirname "$f")")
		arrays=$(jq -r '
			[paths(type == "array") as $p
			 | {k: ($p | join(".")), v: getpath($p)}]
			| .[]
			| select(.v | length > 0)
			| select(all(.v[]; type == "string"))
			| select(all(.v[]; test("^(plugins|skills)/")))
			| .k' "$f" 2>/dev/null)
		[[ -z "$arrays" ]] || { echo "$name ships a marketplace-only default at: $arrays"; return 1; }
	done
	true
}
