#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-redact.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-record.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-query.sh"

	KEY="projqueryabc"
	FILE="src/a.py"
	# Two changes to the same file, appended oldest-first.
	local dir
	dir=$(lineage_record_dir "$KEY")
	mkdir -p "$dir"
	{
		jq -nc '{change_id:"C1", ts:"2026-06-12T00:00:01Z", ts_epoch:1, session_id:"s1", turn:2, tool:"Edit", operation:"edit", file_path:"src/a.py", added_snippets:["def foo():"], transcript_path:""}'
		jq -nc '{change_id:"C2", ts:"2026-06-12T00:00:02Z", ts_epoch:2, session_id:"s1", turn:5, tool:"Edit", operation:"edit", file_path:"src/a.py", added_snippets:["    return 42"], transcript_path:""}'
	} > "${dir}/changes.jsonl"
}

@test "changes_for_file returns records newest-first" {
	run lineage_changes_for_file "$KEY" "$FILE"
	[ "$status" -eq 0 ]
	local first
	first=$(printf '%s\n' "$output" | head -1)
	[ "$(jq -r '.change_id' <<<"$first")" = "C2" ]
}

@test "match_line content-anchors a line to the change that introduced it" {
	local rec
	rec=$(lineage_match_line "$KEY" "$FILE" "return 42")
	[ "$(jq -r '.change_id' <<<"$rec")" = "C2" ]

	rec=$(lineage_match_line "$KEY" "$FILE" "def foo")
	[ "$(jq -r '.change_id' <<<"$rec")" = "C1" ]
}

@test "match_line returns nothing for content no change introduced" {
	run lineage_match_line "$KEY" "$FILE" "nonexistent content"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "match_line ignores an empty needle" {
	run lineage_match_line "$KEY" "$FILE" "   "
	[ -z "$output" ]
}

@test "resolve_prompt reads historian's chunk for the turn range" {
	local hist="${ONLOOKER_DIR}/historian/${KEY}/sessions"
	mkdir -p "$hist"
	printf '%s\n' '{"session_id":"s1","start_turn_index":1,"end_turn_index":6,"body_redacted":"user: write the foo function\n\nassistant: done"}' \
		> "${hist}/s1.jsonl"
	run lineage_resolve_prompt "$KEY" "s1" "5" "" "historian_then_transcript"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.resolved_via' <<<"$output")" = "historian" ]
	[[ "$(jq -r '.prompt' <<<"$output")" == *"write the foo function"* ]]
}

@test "resolve_prompt falls back to the transcript when historian has nothing" {
	local tp="${BATS_TEST_TMPDIR}/transcript.jsonl"
	{
		printf '%s\n' '{"role":"user","content":"first prompt"}'
		printf '%s\n' '{"role":"assistant","content":"ok"}'
		printf '%s\n' '{"role":"user","content":"second prompt about bar"}'
	} > "$tp"
	run lineage_resolve_prompt "$KEY" "s2" "2" "$tp" "historian_then_transcript"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.resolved_via' <<<"$output")" = "transcript" ]
	[[ "$(jq -r '.prompt' <<<"$output")" == *"second prompt about bar"* ]]
}

@test "resolve_prompt reports none when neither source is available" {
	run lineage_resolve_prompt "$KEY" "s3" "1" "" "historian_then_transcript"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.resolved_via' <<<"$output")" = "none" ]
	[ "$(jq -r '.prompt' <<<"$output")" = "" ]
}

# The ledger's own word, when it has one. content_scope is written only by the
# Bash path, which derives a record from a git diff and so cannot always say
# the captured content is only this change.
@test "scope_kind reports the ledger's content_scope when the record carries one" {
	[ "$(lineage_scope_kind "cumulative" "Bash")" = "cumulative" ]
	[ "$(lineage_scope_kind "delta" "Bash")" = "delta" ]
}

# An Edit/Write/MultiEdit record has no content_scope and needs none: the tool
# reported what it changed, so the captured content is that change and nothing
# else. Absent must not be rendered as doubt for these.
@test "scope_kind calls a tool-reported change exact" {
	[ "$(lineage_scope_kind "" "Edit")" = "exact" ]
	[ "$(lineage_scope_kind "" "Write")" = "exact" ]
	[ "$(lineage_scope_kind "" "MultiEdit")" = "exact" ]
}

# jq renders a missing field as the string "null" unless the caller defaults it.
# Treating that as a scope would print "null" at the user.
@test "scope_kind treats a literal null as absent" {
	[ "$(lineage_scope_kind "null" "Edit")" = "exact" ]
}

# A Bash record with no content_scope predates the field. Nothing about it says
# the content is only this change, and nothing says it isn't.
@test "scope_kind says unknown for a shell record with no scope" {
	[ "$(lineage_scope_kind "" "Bash")" = "unknown" ]
}

@test "scope_note names uncommitted work as what widens a cumulative answer" {
	run lineage_scope_note "cumulative" "Bash"
	[ "$status" -eq 0 ]
	[[ "$output" == *"uncommitted"* ]]
}

@test "scope_note does not hedge an exact answer" {
	run lineage_scope_note "" "Edit"
	[ "$status" -eq 0 ]
	[[ "$output" != *"uncommitted"* ]]
	[ -n "$output" ]
}

@test "scope_note says every kind something, so no answer renders blank" {
	local kind
	for kind in cumulative delta exact unknown; do
		run lineage_scope_note "$kind" "Bash"
		[ "$status" -eq 0 ]
		[ -n "$output" ]
	done
}

# "by a Bash" is the phrasing this replaces.
@test "tool_phrase names Bash as what it actually was" {
	[ "$(lineage_tool_phrase "Bash")" = "a shell command" ]
}

@test "tool_phrase gets the article right for a vowel-initial tool" {
	[ "$(lineage_tool_phrase "Edit")" = "an Edit" ]
	[ "$(lineage_tool_phrase "Write")" = "a Write" ]
	[ "$(lineage_tool_phrase "MultiEdit")" = "a MultiEdit" ]
}

# A tool lineage has never seen must still read as a sentence.
@test "tool_phrase articles an unknown tool by its first letter" {
	[ "$(lineage_tool_phrase "Oracle")" = "an Oracle" ]
	[ "$(lineage_tool_phrase "Patch")" = "a Patch" ]
}

@test "tool_phrase does not produce a bare article for an empty tool" {
	run lineage_tool_phrase ""
	[ "$status" -eq 0 ]
	[ "$output" = "an unknown tool" ]
}
