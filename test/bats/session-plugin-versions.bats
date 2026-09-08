#!/usr/bin/env bats

# The live read path for ecosystem-9eg: what is THIS session actually running?
#
# Reads observed hook-health rows rather than installed_plugins.json, because
# the manifest reports what is on disk and the session may have pinned older
# code at process start. That gap is the entire bug.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
	mkdir -p "$(dirname "$HEALTH_LOG")"
	SCRIPT="${REPO_ROOT}/scripts/session-plugin-versions.sh"
}

_row() {
	jq -cn --arg n "$1" --arg v "$2" --argjson p "$3" \
		'{hook:"h", status:"success", plugin_name:$n, plugin_version:$v, host_pid:$p}' \
		>> "$HEALTH_LOG"
}

@test "reports the distinct plugin versions for the given host pid" {
	_row lineage 0.5.1 4242
	_row lineage 0.5.1 4242
	_row echo 0.5.2 4242
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
	[[ "$output" == *"echo 0.5.2"* ]]
	[[ "$output" == *"lineage 0.5.1"* ]]
	[ "$(printf '%s\n' "$output" | grep -c lineage)" -eq 1 ]
}

@test "ignores rows belonging to another host process" {
	_row lineage 0.5.1 4242
	_row lineage 0.5.0 9999
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
	[[ "$output" == *"0.5.1"* ]]
	[[ "$output" != *"0.5.0"* ]]
}

# The mixed-version window this bead was filed for: one plugin, two versions,
# one process. Surfacing it is the point -- collapsing it would hide the bug.
@test "surfaces a plugin running two versions in one process" {
	_row lineage 0.5.0 4242
	_row lineage 0.5.1 4242
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c '^lineage ')" -eq 2 ]
}

@test "labels an unreleased working-tree copy rather than printing null" {
	jq -cn '{hook:"h", plugin_name:"lineage", plugin_version:null, host_pid:4242}' >> "$HEALTH_LOG"
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
	[[ "$output" == *"lineage"* ]]
	[[ "$output" == *"(working tree)"* ]]
	[[ "$output" != *"null"* ]]
}

@test "says so plainly when the process has no rows yet" {
	_row lineage 0.5.1 4242
	run bash "$SCRIPT" --pid 1234
	[ "$status" -eq 0 ]
	[[ "$output" == *"no hook-health rows"* ]]
}

@test "an absent log is not an error" {
	rm -f "$HEALTH_LOG"
	run bash "$SCRIPT" --pid 4242
	[ "$status" -eq 0 ]
}
