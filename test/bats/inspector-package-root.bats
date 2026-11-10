#!/usr/bin/env bats

# ONL-214. ${package_root} names the package that owns the touched file: the
# nearest ancestor of ${file}, up to ${repo_root}, that holds a package.json.
# Without it a workspace-scoped typecheck cannot be expressed — `tsc --noEmit
# ${file}` ignores the package tsconfig and reported 8 spurious errors against a
# clean onlooker tree, and `turbo typecheck` from ${repo_root} checks the whole
# repo on every edit.
#
# Driven end to end through the PostToolUse hook, the way production calls it.
# The check records the argument it was handed into a file, so each test
# asserts the exact path substituted rather than only that a check ran.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	if ! grep -q "inspector.check.passed" \
		"${BATS_TEST_DIRNAME}/../../node_modules/@onlooker-community/schema/schemas/event.v1.json" 2>/dev/null; then
		skip "installed @onlooker-community/schema has no inspector.* types yet"
	fi

	PLUGIN_ROOT="${REPO_ROOT}/plugins/inspector"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/inspector-post-write.sh"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	# A pnpm-style workspace: a root manifest plus one under packages/web, with
	# the touched file two directories below the package manifest so the walk
	# has to climb more than one level.
	REPO="${BATS_TEST_TMPDIR}/ws/repo"
	mkdir -p "${REPO}/.claude" "${REPO}/packages/web/src/deep" "${REPO}/scripts"
	git -C "$REPO" init -q
	git -C "$REPO" remote add origin "https://example.com/test-${BATS_TEST_NUMBER}.git"
	printf '{}\n' >"${REPO}/package.json"
	printf '{}\n' >"${REPO}/packages/web/package.json"
	printf 'x\n' >"${REPO}/packages/web/src/deep/App.ts"
	printf 'x\n' >"${REPO}/scripts/tool.ts"

	# The hook canonicalizes paths, and BATS_TEST_TMPDIR sits under a symlink
	# on macOS (/var -> /private/var), so expected values must be canonical too.
	REPO_CANON=$(cd "$REPO" && pwd -P)
	RECORD="${BATS_TEST_TMPDIR}/recorded"
}

# Configure one .ts check whose argv contains <arg>; the check writes its
# expanded value to $RECORD.
_record_check() {
	local arg="$1"
	jq -n --arg arg "$arg" --arg out "$RECORD" '{inspector: {checks: {".ts": [{
		name: "rec", kind: "typecheck",
		argv: ["sh", "-c", "printf %s \"$1\" >\"$2\"", "sh", $arg, $out]
	}]}}}' >"${REPO}/.claude/settings.json"
}

_run_hook_on() {
	local path="$1"
	jq -n --arg cwd "$REPO" --arg p "$path" --arg sid "test-${BATS_TEST_NUMBER}" \
		'{cwd:$cwd, session_id:$sid, tool_name:"Edit", tool_input:{file_path:$p}}' \
		| ONLOOKER_DIR="$ONLOOKER_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK"
}

@test "package_root is the nearest ancestor with a package.json, not the repo root" {
	_record_check '${package_root}'
	run _run_hook_on "${REPO}/packages/web/src/deep/App.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$(cat "$RECORD")" = "${REPO_CANON}/packages/web" ]
}

@test "package_root falls back to the repo root when only the root has a manifest" {
	_record_check '${package_root}'
	run _run_hook_on "${REPO}/scripts/tool.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$(cat "$RECORD")" = "$REPO_CANON" ]
}

@test "package_root falls back to the repo root when no manifest exists at all" {
	rm "${REPO}/package.json" "${REPO}/packages/web/package.json"
	_record_check '${package_root}'
	run _run_hook_on "${REPO}/packages/web/src/deep/App.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$(cat "$RECORD")" = "$REPO_CANON" ]
}

# The walk stops at ${repo_root}. A manifest above it belongs to some other
# project — a parent directory, or the main checkout a worktree sits inside —
# and handing it to `tsc -p` would check the wrong code.
@test "package_root never climbs above the repo root" {
	rm "${REPO}/package.json" "${REPO}/packages/web/package.json"
	printf '{}\n' >"${BATS_TEST_TMPDIR}/ws/package.json"
	_record_check '${package_root}'
	run _run_hook_on "${REPO}/packages/web/src/deep/App.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$(cat "$RECORD")" = "$REPO_CANON" ]
}

@test "package_root is substituted inside a larger argument" {
	_record_check '--project=${package_root}/tsconfig.json'
	run _run_hook_on "${REPO}/packages/web/src/deep/App.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$(cat "$RECORD")" = "--project=${REPO_CANON}/packages/web/tsconfig.json" ]
}

@test "a package directory whose name contains a space survives substitution" {
	mkdir -p "${REPO}/packages/my web/src"
	printf '{}\n' >"${REPO}/packages/my web/package.json"
	printf 'x\n' >"${REPO}/packages/my web/src/a.ts"
	_record_check '${package_root}'
	run _run_hook_on "${REPO}/packages/my web/src/a.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$(cat "$RECORD")" = "${REPO_CANON}/packages/my web" ]
}

# The existing placeholders must expand exactly as before alongside the new one.
@test "file, file_relative and repo_root still expand next to package_root" {
	_record_check '${repo_root}|${file_relative}|${file}|${package_root}'
	run _run_hook_on "${REPO}/packages/web/src/deep/App.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$(cat "$RECORD")" = "${REPO_CANON}|packages/web/src/deep/App.ts|${REPO_CANON}/packages/web/src/deep/App.ts|${REPO_CANON}/packages/web" ]
}
