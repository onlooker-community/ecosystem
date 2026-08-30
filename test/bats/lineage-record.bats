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
	KEY="proj0123abcd"
}

@test "Edit record captures operation, line counts, snippet, and digest" {
	local ti rec
	ti=$(jq -nc '{file_path:"src/a.py", old_string:"a\nb", new_string:"a\nb\nc"}')
	rec=$(lineage_build_record "CID1" "2026-06-12T00:00:00Z" 1781280000 "sess1" "5" "Edit" "src/a.py" "$ti" 4000 true "")
	[ "$(jq -r '.tool' <<<"$rec")" = "Edit" ]
	[ "$(jq -r '.operation' <<<"$rec")" = "edit" ]
	[ "$(jq -r '.lines_added' <<<"$rec")" = "3" ]
	[ "$(jq -r '.lines_removed' <<<"$rec")" = "2" ]
	[ "$(jq -r '.turn' <<<"$rec")" = "5" ]
	[ "$(jq -r '.added_snippets[0]' <<<"$rec")" = "a
b
c" ]
	[ -n "$(jq -r '.content_sha256' <<<"$rec")" ]
}

@test "Write record is operation=create with no removed lines" {
	local ti rec
	ti=$(jq -nc '{file_path:"README.md", content:"line1\nline2"}')
	rec=$(lineage_build_record "CID2" "2026-06-12T00:00:00Z" 1781280000 "sess1" "" "Write" "README.md" "$ti" 4000 true "")
	[ "$(jq -r '.tool' <<<"$rec")" = "Write" ]
	[ "$(jq -r '.operation' <<<"$rec")" = "create" ]
	[ "$(jq -r '.lines_added' <<<"$rec")" = "2" ]
	[ "$(jq -r '.lines_removed' <<<"$rec")" = "0" ]
}

@test "turn is omitted when empty" {
	local ti rec
	ti=$(jq -nc '{file_path:"README.md", content:"x"}')
	rec=$(lineage_build_record "CID3" "2026-06-12T00:00:00Z" 1781280000 "sess1" "" "Write" "README.md" "$ti" 4000 true "")
	[ "$(jq -r 'has("turn")' <<<"$rec")" = "false" ]
}

@test "MultiEdit record reports edit_count and joins added content" {
	local ti rec
	ti=$(jq -nc '{file_path:"src/b.py", edits:[{old_string:"x", new_string:"x1"},{old_string:"y", new_string:"y1\ny2"}]}')
	rec=$(lineage_build_record "CID4" "2026-06-12T00:00:00Z" 1781280000 "sess1" "2" "MultiEdit" "src/b.py" "$ti" 4000 true "")
	[ "$(jq -r '.tool' <<<"$rec")" = "MultiEdit" ]
	[ "$(jq -r '.operation' <<<"$rec")" = "multi_edit" ]
	[ "$(jq -r '.edit_count' <<<"$rec")" = "2" ]
	[ "$(jq -r '.lines_added' <<<"$rec")" = "3" ]
	[[ "$(jq -r '.added_snippets[0]' <<<"$rec")" == *"y2"* ]]
}

@test "append writes one line per record (append-only)" {
	local ti r1 r2
	ti=$(jq -nc '{file_path:"src/a.py", content:"a"}')
	r1=$(lineage_build_record "CID-A" "2026-06-12T00:00:00Z" 1781280000 "s" "1" "Write" "src/a.py" "$ti" 4000 true "")
	r2=$(lineage_build_record "CID-B" "2026-06-12T00:00:01Z" 1781280001 "s" "2" "Write" "src/a.py" "$ti" 4000 true "")
	lineage_append "$KEY" "$r1"
	lineage_append "$KEY" "$r2"
	local path
	path=$(lineage_record_path "$KEY")
	[ -f "$path" ]
	[ "$(wc -l < "$path")" -eq 2 ]
	[ "$(jq -rs '.[0].change_id' "$path")" = "CID-A" ]
	[ "$(jq -rs '.[1].change_id' "$path")" = "CID-B" ]
}

@test "redaction disabled keeps the raw snippet" {
	local ti rec
	ti=$(jq -nc '{file_path:"x", content:"plain text body"}')
	rec=$(lineage_build_record "CID5" "2026-06-12T00:00:00Z" 1781280000 "s" "1" "Write" "x" "$ti" 4000 false "")
	[ "$(jq -r '.added_snippets[0]' <<<"$rec")" = "plain text body" ]
}

@test "operation maps Bash to shell_edit" {
  run _lineage_operation "Bash"
  [ "$output" = "shell_edit" ]
}

@test "build_record uses the added override when given" {
  run lineage_build_record "cid1" "2026-01-01T00:00:00Z" "0" "sess" "1" \
    "Bash" "/repo/f.txt" '{}' "4000" "false" "" "added from git" "authored" "delta"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" | jq -e '.added_snippets[0] == "added from git"' >/dev/null
}

@test "build_record carries provenance_kind and content_scope" {
  run lineage_build_record "cid2" "2026-01-01T00:00:00Z" "0" "sess" "1" \
    "Bash" "/repo/f.txt" '{}' "4000" "false" "" "x" "tool_generated" "cumulative"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" \
    | jq -e '.provenance_kind == "tool_generated" and .content_scope == "cumulative"' >/dev/null
}

@test "build_record omits the new fields for a normal Edit" {
  run lineage_build_record "cid3" "2026-01-01T00:00:00Z" "0" "sess" "1" \
    "Edit" "/repo/f.txt" '{"new_string":"hello"}' "4000" "false" ""
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" | jq -e 'has("provenance_kind") == false' >/dev/null || return 1
  printf '%s' "$output" | jq -e '.added_snippets[0] == "hello"' >/dev/null
}
