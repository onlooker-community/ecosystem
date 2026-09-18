#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	source "${PLUGIN_ROOT}/scripts/lib/librarian-archivist-reader.sh"

	PROJECT_KEY="deadbeef1234"
	ARTIFACT_DIR="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
}

# Seed one archivist artifact. Shape mirrors archivist's storage.sh.
_seed() {
	local kind="$1" id="$2" created_at="$3"
	mkdir -p "${ARTIFACT_DIR}/${kind}"
	jq -n --arg id "$id" --arg created_at "$created_at" \
		--arg summary "summary ${id}" \
		--arg detail "A detail long enough to clear the forty character gate for ${id}." \
		'{id: $id, kind: "decision", created_at: $created_at, updated_at: $created_at,
		  summary: $summary, detail: $detail, files: [], session_id: "s1"}' \
		> "${ARTIFACT_DIR}/${kind}/${id}.json"
}

# Put a counting wrapper for jq on PATH. Each invocation appends one byte to
# $JQ_COUNT_FILE and then delegates to the real binary, so the count is exact
# and the reader's behavior is unchanged.
_count_jq_spawns() {
	local real_jq
	real_jq=$(command -v jq)
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	export JQ_COUNT_FILE="${BATS_TEST_TMPDIR}/jq-count"
	: > "$JQ_COUNT_FILE"
	cat > "${STUB_BIN}/jq" <<STUB
#!/usr/bin/env bash
printf 'x' >> "${JQ_COUNT_FILE}"
exec "${real_jq}" "\$@"
STUB
	chmod +x "${STUB_BIN}/jq"
	export PATH="${STUB_BIN}:${PATH}"
}

@test "returns empty array when the project has no archivist directory" {
	run librarian_archivist_load_since "nosuchkey00" ""
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" -eq 0 ]
}

@test "returns empty array when the artifact directories exist but are empty" {
	# Guards a bash 3.2 trap, which is what bats resolves to on macOS: under
	# `set -u` (which the hook sets) expanding "${files[@]}" on an EMPTY array
	# aborts with "unbound variable", while ${#files[@]} on the same array is
	# fine. A batched reader has to short-circuit on the count before it ever
	# expands the list, and only this case proves it does.
	mkdir -p "${ARTIFACT_DIR}/decisions" "${ARTIFACT_DIR}/dead_ends"

	run bash -c "set -u; source '${PLUGIN_ROOT}/scripts/lib/librarian-archivist-reader.sh'; librarian_archivist_load_since '${PROJECT_KEY}' ''"
	[ "$status" -eq 0 ] || return 1
	[ "$(printf '%s' "$output" | jq 'length')" -eq 0 ]
}

@test "returns every artifact when the watermark is empty" {
	_seed decisions a1 "$(relative_iso_days_ago 3)"
	_seed dead_ends b1 "$(relative_iso_days_ago 2)"
	_seed open_questions c1 "$(relative_iso_days_ago 1)"

	run librarian_archivist_load_since "$PROJECT_KEY" ""
	[ "$status" -eq 0 ] || return 1
	[ "$(printf '%s' "$output" | jq 'length')" -eq 3 ]
}

@test "returns only artifacts strictly newer than the watermark" {
	_seed decisions old1 "$(relative_iso_days_ago 10)"
	_seed decisions new1 "$(relative_iso_days_ago 1)"
	local watermark
	watermark=$(relative_iso_days_ago 5)

	run librarian_archivist_load_since "$PROJECT_KEY" "$watermark"
	[ "$status" -eq 0 ] || return 1
	[ "$(printf '%s' "$output" | jq 'length')" -eq 1 ] || return 1
	[ "$(printf '%s' "$output" | jq -r '.[0].id')" = "new1" ]
}

@test "an artifact exactly at the watermark is excluded" {
	local watermark
	watermark=$(relative_iso_days_ago 5)
	_seed decisions edge "$watermark"

	run librarian_archivist_load_since "$PROJECT_KEY" "$watermark"
	[ "$status" -eq 0 ] || return 1
	[ "$(printf '%s' "$output" | jq 'length')" -eq 0 ]
}

@test "results are sorted chronologically" {
	_seed decisions late "$(relative_iso_days_ago 1)"
	_seed decisions early "$(relative_iso_days_ago 9)"
	_seed decisions middle "$(relative_iso_days_ago 5)"

	run librarian_archivist_load_since "$PROJECT_KEY" ""
	[ "$status" -eq 0 ] || return 1
	[ "$(printf '%s' "$output" | jq -r '[.[].id] | join(",")')" = "early,middle,late" ]
}

@test "one malformed artifact does not blank the whole scan" {
	# A single corrupt file must cost only itself. The per-file read tolerated
	# this naturally; any batched read has to keep the guarantee explicitly,
	# because a batch parse aborts on the first bad byte.
	_seed decisions good1 "$(relative_iso_days_ago 2)"
	_seed decisions good2 "$(relative_iso_days_ago 1)"
	printf 'not json at all {{{' > "${ARTIFACT_DIR}/decisions/broken.json"

	run librarian_archivist_load_since "$PROJECT_KEY" ""
	[ "$status" -eq 0 ] || return 1
	[ "$(printf '%s' "$output" | jq 'length')" -eq 2 ]
}

@test "read cost does not scale with the size of the artifact corpus" {
	# The defect this pins: the reader spawned TWO jq processes per artifact
	# file — `jq '.'` to parse it, then `jq -r '.created_at'` to compare it to
	# the watermark — walking the entire corpus before the watermark could
	# exclude anything. On a real 703-artifact project that measured 3.4s
	# against the CLI's 1500ms SessionEnd abort window, so the hook was killed
	# mid-read on essentially every session and did no work at all.
	#
	# Asserted as a subprocess count rather than a wall-clock budget: the cost
	# is the spawns, and a count is exact on any machine under any load.
	local i
	for i in $(seq 1 60); do
		_seed decisions "art${i}" "$(relative_iso_days_ago 2)"
	done

	_count_jq_spawns

	run librarian_archivist_load_since "$PROJECT_KEY" ""
	[ "$status" -eq 0 ] || return 1
	[ "$(printf '%s' "$output" | jq 'length')" -eq 60 ] || return 1

	local spawns
	spawns=$(wc -c < "$JQ_COUNT_FILE" | tr -d ' ')
	# A handful of fixed calls is fine; anything proportional to 60 is the bug.
	[ "$spawns" -le 10 ]
}
