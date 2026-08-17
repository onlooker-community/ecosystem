#!/usr/bin/env bats

# Unit coverage for the --type and --scope narrowing.
#
# Both flags were documented in SKILL.md while run-audit.sh read neither, so a
# user who passed them got a silent full audit (ecosystem-9og). The end-to-end
# proof that they now change what runs lives in cartographer-run-audit.bats;
# this file pins the decision logic those tests depend on.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh"
}

# ── Type validity ────────────────────────────────────────────────────────────

@test "every documented finding type is accepted" {
	local t
	for t in contradiction dead_rule stale_ref scope_collision undocumented_entity; do
		cartographer_filter_valid_type "$t" || return 1
	done
}

# The published schema's finding_type enum and this list are the same five
# values; a type valid here that the schema rejects would emit nothing.
@test "the accepted types match the schema enum exactly" {
	local schema="${REPO_ROOT}/node_modules/@onlooker-community/schema/schemas/payload/plugins-memory.json"
	[ -f "$schema" ] || skip "schema package not installed"
	local from_schema from_lib
	from_schema=$(jq -r '.["$defs"]["cartographer.issue.found"].properties.finding_type.enum //
	                     .definitions["cartographer.issue.found"].properties.finding_type.enum
	                     | sort | join(" ")' "$schema")
	from_lib=$(printf '%s\n' $CARTOGRAPHER_FINDING_TYPES | sort | tr '\n' ' ' | sed 's/ $//')
	[ "$from_schema" = "$from_lib" ]
}

@test "an unknown type is rejected" {
	run cartographer_filter_valid_type "not_a_type"
	[ "$status" -ne 0 ]
}

@test "an empty type is rejected, so callers must check before filtering" {
	run cartographer_filter_valid_type ""
	[ "$status" -ne 0 ]
}

# ── Which analyzers run ──────────────────────────────────────────────────────

@test "no filter runs every analyzer" {
	local a
	for a in contradiction stale_ref scope_collision undocumented_entity; do
		cartographer_filter_wants "$a" "" || return 1
	done
}

@test "a type filter runs only its own analyzer" {
	cartographer_filter_wants "stale_ref" "stale_ref" || return 1
	run cartographer_filter_wants "scope_collision" "stale_ref"
	[ "$status" -ne 0 ] || return 1
	run cartographer_filter_wants "undocumented_entity" "stale_ref"
	[ "$status" -ne 0 ] || return 1
	run cartographer_filter_wants "contradiction" "stale_ref"
	[ "$status" -ne 0 ]
}

# contradiction and dead_rule come out of one LLM pass, so either request must
# run that analyzer. Skipping it for dead_rule would silently produce nothing.
@test "dead_rule runs the contradiction analyzer" {
	cartographer_filter_wants "contradiction" "dead_rule"
}

@test "asking for dead_rule still skips the unrelated analyzers" {
	run cartographer_filter_wants "stale_ref" "dead_rule"
	[ "$status" -ne 0 ] || return 1
	run cartographer_filter_wants "undocumented_entity" "dead_rule"
	[ "$status" -ne 0 ]
}

# ── Filtering the results ────────────────────────────────────────────────────

FINDINGS='[{"type":"contradiction","file_a":"a"},{"type":"dead_rule","file_a":"b"}]'

@test "no filter passes findings through untouched" {
	run cartographer_filter_findings "$FINDINGS" ""
	[ "$output" = "$FINDINGS" ]
}

# The shared LLM pass returns both types, so the unrequested one is dropped here.
@test "the co-emitted type is dropped from the results" {
	run bash -c "source '${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh'
	             cartographer_filter_findings '$FINDINGS' 'dead_rule' | jq -c '[.[].type]'"
	[ "$output" = '["dead_rule"]' ]
}

@test "filtering to the other co-emitted type keeps only it" {
	run bash -c "source '${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh'
	             cartographer_filter_findings '$FINDINGS' 'contradiction' | jq -c '[.[].type]'"
	[ "$output" = '["contradiction"]' ]
}

@test "a type present in no finding yields an empty array, not an error" {
	run cartographer_filter_findings "$FINDINGS" "stale_ref"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "[]" ]
}

@test "malformed findings json degrades to empty rather than aborting" {
	run cartographer_filter_findings "not json" "stale_ref"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "[]" ]
}

# ── Scope ────────────────────────────────────────────────────────────────────

FILES='["/repo/CLAUDE.md","/repo/plugins/tribunal/CLAUDE.md","/repo/plugins/echo/CLAUDE.md"]'

@test "no scope passes the file list through untouched" {
	run cartographer_filter_scope "$FILES" "/repo" ""
	[ "$output" = "$FILES" ]
}

@test "a repo-relative scope keeps only files beneath it" {
	run bash -c "source '${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh'
	             cartographer_filter_scope '$FILES' '/repo' 'plugins/tribunal' | jq -c ."
	[ "$output" = '["/repo/plugins/tribunal/CLAUDE.md"]' ]
}

@test "an absolute scope works too" {
	run bash -c "source '${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh'
	             cartographer_filter_scope '$FILES' '/repo' '/repo/plugins/echo' | jq -c ."
	[ "$output" = '["/repo/plugins/echo/CLAUDE.md"]' ]
}

@test "a trailing slash on the scope does not change the match" {
	run bash -c "source '${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh'
	             cartographer_filter_scope '$FILES' '/repo' 'plugins/tribunal/' | jq -c 'length'"
	[ "$output" = "1" ]
}

@test "a leading ./ on the scope does not change the match" {
	run bash -c "source '${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh'
	             cartographer_filter_scope '$FILES' '/repo' './plugins/tribunal' | jq -c 'length'"
	[ "$output" = "1" ]
}

# A sibling whose name merely starts with the scope string is not inside it.
# Prefix matching without the separator would pull plugins/echo-legacy into a
# scope of plugins/echo.
@test "a sibling sharing a name prefix is not swept in" {
	local files='["/repo/plugins/echo/CLAUDE.md","/repo/plugins/echo-legacy/CLAUDE.md"]'
	run bash -c "source '${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh'
	             cartographer_filter_scope '$files' '/repo' 'plugins/echo' | jq -c ."
	[ "$output" = '["/repo/plugins/echo/CLAUDE.md"]' ]
}

@test "scoping to an exact file path keeps that file" {
	run bash -c "source '${PLUGIN_ROOT}/scripts/lib/cartographer-filter.sh'
	             cartographer_filter_scope '$FILES' '/repo' 'CLAUDE.md' | jq -c ."
	[ "$output" = '["/repo/CLAUDE.md"]' ]
}

@test "a scope matching nothing yields an empty list" {
	run cartographer_filter_scope "$FILES" "/repo" "does/not/exist"
	[ "$output" = "[]" ]
}
