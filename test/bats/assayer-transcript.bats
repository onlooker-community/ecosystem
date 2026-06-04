#!/usr/bin/env bats

# Exercises the transcript reader against a synthetic JSONL transcript shaped
# like a real Claude Code session log.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-transcript.sh"

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	{
		# An assistant turn that runs a passing build, then a failing test.
		printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Running the build."},{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"npm run build"}}]}}'
		printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"build ok"}]}}'
		printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"t2","input":{"command":"npm test"}}]}}'
		printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"1 failed"}]}}'
		# A non-Bash tool call should be ignored.
		printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","id":"t3","input":{"file_path":"x"}}]}}'
		# Final assistant message with the claims.
		printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done. The build passes and the tests are green."}]}}'
	} >"$TRANSCRIPT"
}

@test "final assistant message returns the last text turn" {
	run assayer_final_assistant_message "$TRANSCRIPT" 6000
	[ "$status" -eq 0 ]
	[ "$output" = "Done. The build passes and the tests are green." ]
}

@test "final assistant message truncates to max_chars" {
	run assayer_final_assistant_message "$TRANSCRIPT" 10
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 10 ]
}

@test "missing transcript yields empty final message" {
	run assayer_final_assistant_message "${BATS_TEST_TMPDIR}/nope.jsonl" 6000
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "collects Bash commands with their is_error status" {
	run assayer_collect_commands "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" -eq 2 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].command')" = "npm run build" ]
	[ "$(printf '%s' "$output" | jq -r '.[0].is_error')" = "false" ]
	[ "$(printf '%s' "$output" | jq -r '.[1].command')" = "npm test" ]
	[ "$(printf '%s' "$output" | jq -r '.[1].is_error')" = "true" ]
}

@test "captures the failing command's output excerpt" {
	run assayer_collect_commands "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[1].excerpt')" = "1 failed" ]
}

@test "non-Bash tool calls are excluded" {
	run assayer_collect_commands "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	# Only the two Bash commands, never the Read call.
	[ "$(printf '%s' "$output" | jq '[.[] | select(.command | contains("file"))] | length')" -eq 0 ]
}

@test "missing transcript yields empty command array" {
	run assayer_collect_commands "${BATS_TEST_TMPDIR}/nope.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
}
