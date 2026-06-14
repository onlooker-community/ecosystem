#!/usr/bin/env bats

# Validates every emitted inspector.* event against @onlooker-community/schema.
#
# The inspector.* event types ship in @onlooker-community/schema; until the
# installed version includes them, these tests skip rather than fail. Once the
# ecosystem's schema dependency is bumped to a release that carries them, they
# run for real.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/inspector"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export CLAUDE_SESSION_ID="bats-session-$$"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/inspector-events.sh"
}

_require_inspector_schema() {
	if ! grep -q "inspector.check.passed" \
		"${REPO_ROOT}/node_modules/@onlooker-community/schema/schemas/event.v1.json" 2>/dev/null; then
		skip "installed @onlooker-community/schema has no inspector.* types yet"
	fi
}

_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

@test "inspector.check.passed validates" {
	_require_inspector_schema
	local p
	p=$(jq -n '{
		file_path: "/repo/src/a.ts",
		file_path_relative: "src/a.ts",
		tool_name: "Edit",
		check_name: "biome",
		check_kind: "lint",
		argv: ["biome", "check", "/repo/src/a.ts"],
		duration_ms: 124,
		project_key: "a1b2c3d4e5f6"
	}')
	inspector_emit_event "inspector.check.passed" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "inspector.check.failed validates" {
	_require_inspector_schema
	local p
	p=$(jq -n '{
		file_path: "/repo/src/a.ts",
		file_path_relative: "src/a.ts",
		tool_name: "Edit",
		check_name: "tsc",
		check_kind: "typecheck",
		argv: ["tsc", "--noEmit"],
		duration_ms: 980,
		exit_code: 2,
		issue_count: 3,
		output_excerpt: "src/a.ts:42:5 - Type error",
		output_truncated: false,
		project_key: "a1b2c3d4e5f6"
	}')
	inspector_emit_event "inspector.check.failed" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "inspector.check.failed validates with null issue_count" {
	_require_inspector_schema
	local p
	p=$(jq -n '{
		file_path: "/repo/src/a.ts",
		tool_name: "Edit",
		check_name: "mystery-linter",
		check_kind: "lint",
		exit_code: 1,
		issue_count: null
	}')
	inspector_emit_event "inspector.check.failed" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "inspector.check.skipped (per-check) validates" {
	_require_inspector_schema
	local p
	p=$(jq -n '{
		file_path: "/repo/scripts/deploy.sh",
		file_path_relative: "scripts/deploy.sh",
		tool_name: "Edit",
		check_name: "shellcheck",
		check_kind: "lint",
		reason: "tool_missing",
		project_key: "a1b2c3d4e5f6"
	}')
	inspector_emit_event "inspector.check.skipped" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "inspector.check.skipped (whole-file) validates" {
	_require_inspector_schema
	local p
	p=$(jq -n '{
		file_path: "/repo/node_modules/foo/index.js",
		file_path_relative: "node_modules/foo/index.js",
		tool_name: "Write",
		reason: "excluded_path",
		project_key: "a1b2c3d4e5f6"
	}')
	inspector_emit_event "inspector.check.skipped" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "inspector.run.completed validates" {
	_require_inspector_schema
	local p
	p=$(jq -n '{
		file_path: "/repo/src/a.ts",
		file_path_relative: "src/a.ts",
		tool_name: "Edit",
		checks_run: 2,
		checks_passed: 1,
		checks_failed: 1,
		checks_skipped: 0,
		duration_ms: 1080,
		project_key: "a1b2c3d4e5f6"
	}')
	inspector_emit_event "inspector.run.completed" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "emission rejects an unknown event type" {
	run inspector_emit_event "inspector.no.such.event" '{"file_path":"x"}'
	[ "$status" -ne 0 ]
}

@test "inspector_emit_event returns 1 when payload is empty" {
	run inspector_emit_event "inspector.check.passed" ""
	[ "$status" -ne 0 ]
}
