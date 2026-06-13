#!/usr/bin/env bats

# Exercises the Inspector PostToolUse hook's end-to-end behavior.
# Uses fake check commands (sh -c) so the suite has no external lint deps.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/inspector"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/inspector-post-write.sh"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${REPO}/src" "${REPO}/.claude" "${REPO}/node_modules/foo"
	git -C "$REPO" init -q
	git -C "$REPO" remote add origin "https://example.com/test-${BATS_TEST_NUMBER}.git"
	printf 'sample\n' >"${REPO}/src/sample.ts"
	printf 'sample\n' >"${REPO}/src/sample.py"
	printf 'sample\n' >"${REPO}/node_modules/foo/index.ts"
}

_input() {
	local cwd="${1:-$REPO}" tool="${2:-Edit}" path="${3:-${REPO}/src/sample.ts}"
	jq -n --arg cwd "$cwd" --arg tool "$tool" --arg p "$path" --arg sid "test-${BATS_TEST_NUMBER}" \
		'{cwd:$cwd, session_id:$sid, tool_name:$tool, tool_input:{file_path:$p}}'
}

_settings() {
	cat >"${REPO}/.claude/settings.json"
}

_event_count() {
	local et="$1"
	if [[ -f "$ONLOOKER_EVENTS_LOG" ]]; then
		jq -c "select(.event_type == \"$et\")" "$ONLOOKER_EVENTS_LOG" | wc -l | tr -d ' '
	else
		printf '0'
	fi
}

_run_hook() {
	local input="$1"
	printf '%s' "$input" | ONLOOKER_DIR="$ONLOOKER_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK"
}

@test "exits 0 silently when inspector.enabled is false (default)" {
	run _run_hook "$(_input)"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ ! -f "$ONLOOKER_EVENTS_LOG" ] || [ "$(_event_count inspector.run.completed)" = "0" ]
}

@test "exits 0 when tool_name is not Write/Edit/MultiEdit" {
	echo '{"inspector":{"enabled":true,"checks":{".ts":[{"name":"t","kind":"lint","argv":["true"]}]}}}' | _settings
	run _run_hook "$(_input "$REPO" "Bash")"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(_event_count inspector.run.completed)" = "0" ]
}

@test "recursion guard: INSPECTOR_NESTED=1 causes immediate exit 0" {
	echo '{"inspector":{"enabled":true,"checks":{".ts":[{"name":"t","kind":"lint","argv":["true"]}]}}}' | _settings
	run bash -c "printf '%s' '$(_input)' | INSPECTOR_NESTED=1 ONLOOKER_DIR='$ONLOOKER_DIR' CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(_event_count inspector.run.completed)" = "0" ]
}

@test "files in excluded_paths emit a single .skipped event and produce no agent output" {
	echo '{"inspector":{"enabled":true,"checks":{".ts":[{"name":"t","kind":"lint","argv":["true"]}]}}}' | _settings
	run _run_hook "$(_input "$REPO" "Write" "${REPO}/node_modules/foo/index.ts")"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(_event_count inspector.check.skipped)" = "1" ]
	[ "$(_event_count inspector.run.completed)" = "0" ]
	# The skipped reason must be excluded_path.
	[ "$(jq -r 'select(.event_type=="inspector.check.skipped").payload.reason' "$ONLOOKER_EVENTS_LOG")" = "excluded_path" ]
}

@test "extensions with no configured checks emit a single .skipped with no_extension_match" {
	echo '{"inspector":{"enabled":true,"checks":{".ts":[{"name":"t","kind":"lint","argv":["true"]}]}}}' | _settings
	run _run_hook "$(_input "$REPO" "Edit" "${REPO}/src/sample.py")"
	[ "$status" -eq 0 ]
	[ "$(_event_count inspector.check.skipped)" = "1" ]
	[ "$(jq -r 'select(.event_type=="inspector.check.skipped").payload.reason' "$ONLOOKER_EVENTS_LOG")" = "no_extension_match" ]
}

@test "a passing check emits .passed and silences agent-facing stdout by default" {
	echo '{"inspector":{"enabled":true,"checks":{".ts":[{"name":"clean","kind":"lint","argv":["true"]}]}}}' | _settings
	run _run_hook "$(_input)"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(_event_count inspector.check.passed)" = "1" ]
	[ "$(_event_count inspector.run.completed)" = "1" ]
}

@test "show_clean_runs surfaces the file header for passing checks" {
	echo '{"inspector":{"enabled":true,"show_clean_runs":true,"checks":{".ts":[{"name":"clean","kind":"lint","argv":["true"]}]}}}' | _settings
	run _run_hook "$(_input)"
	[ "$status" -eq 0 ]
	[[ "$output" == *"inspector: src/sample.ts"* ]]
	[[ "$output" == *"✓ clean"* ]]
}

@test "a failing check emits .failed with exit_code and surfaces issue lines to the agent" {
	cat <<'EOF' | _settings
{"inspector":{"enabled":true,"checks":{".ts":[
	{"name":"broken","kind":"lint","argv":["sh","-c","echo 'src/sample.ts:1:1 - Bad'; exit 2"]}
]}}}
EOF
	run _run_hook "$(_input)"
	[ "$status" -eq 0 ]
	[[ "$output" == *"inspector: src/sample.ts"* ]]
	[[ "$output" == *"✗ broken"* ]]
	[[ "$output" == *"src/sample.ts:1:1 - Bad"* ]]
	[ "$(_event_count inspector.check.failed)" = "1" ]
	[ "$(jq -r 'select(.event_type=="inspector.check.failed").payload.exit_code' "$ONLOOKER_EVENTS_LOG")" = "2" ]
}

@test "a missing tool emits .skipped with tool_missing and produces no agent output" {
	echo '{"inspector":{"enabled":true,"checks":{".ts":[{"name":"ghost","kind":"lint","argv":["this-tool-does-not-exist"]}]}}}' | _settings
	run _run_hook "$(_input)"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(_event_count inspector.check.skipped)" = "1" ]
	[ "$(jq -r 'select(.event_type=="inspector.check.skipped").payload.reason' "$ONLOOKER_EVENTS_LOG")" = "tool_missing" ]
}

@test "run.completed aggregates pass/fail/skip counts" {
	cat <<'EOF' | _settings
{"inspector":{"enabled":true,"checks":{".ts":[
	{"name":"clean", "kind":"lint",      "argv":["true"]},
	{"name":"broken","kind":"typecheck", "argv":["sh","-c","echo 'oops'; exit 1"]},
	{"name":"ghost", "kind":"lint",      "argv":["this-tool-does-not-exist"]}
]}}}
EOF
	run _run_hook "$(_input)"
	[ "$status" -eq 0 ]
	local completed
	completed=$(jq -c 'select(.event_type=="inspector.run.completed").payload' "$ONLOOKER_EVENTS_LOG")
	[ "$(echo "$completed" | jq -r '.checks_run')" = "2" ]
	[ "$(echo "$completed" | jq -r '.checks_passed')" = "1" ]
	[ "$(echo "$completed" | jq -r '.checks_failed')" = "1" ]
	[ "$(echo "$completed" | jq -r '.checks_skipped')" = "1" ]
}

@test "argv is expanded with the touched file path" {
	echo '{"inspector":{"enabled":true,"checks":{".ts":[{"name":"echo-file","kind":"lint","argv":["sh","-c","echo $1; test -n \"$1\"","--","${file}"]}]}}}' | _settings
	run _run_hook "$(_input)"
	[ "$status" -eq 0 ]
	local argv
	argv=$(jq -c 'select(.event_type=="inspector.check.passed").payload.argv' "$ONLOOKER_EVENTS_LOG")
	# The last argv slot should now hold the resolved touched file path.
	[[ "$(echo "$argv" | jq -r '.[-1]')" == *"src/sample.ts" ]]
}
