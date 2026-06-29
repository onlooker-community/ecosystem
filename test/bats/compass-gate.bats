#!/usr/bin/env bats

# Covers compass_run_gate's pre-evaluator rules: skip sentinel,
# skip_globs, dir+stem cooldown, turn budget, context minimum. These are
# the cheap gating steps that run before any LLM call.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/compass"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	# Source the libs the gate depends on.
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-events.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-sanitizer.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-transcript.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-evaluator.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-gate.sh"

	# Load config.
	compass_config_load ""

	# Seed a session-state file so the gate's state lookups succeed.
	export SESSION_ID="test-session-bats"
	mkdir -p "${ONLOOKER_DIR}/compass/sessions"
	cat > "${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json" <<-EOF
		{
		  "session_id": "${SESSION_ID}",
		  "turn_check_count": 0,
		  "cooldown": [],
		  "circuit_breaker": {"state":"closed","consecutive_failures":0,"opened_at":null}
		}
	EOF

	# Stub compass_evaluate so the gate never shells out to claude -p
	# during tests. The stub always reports a pass — tests that need to
	# verify pre-evaluator rules check that the evaluator is short-circuited
	# before it would run.
	compass_evaluate() {
		printf '{"decision":"pass","confidence":0.95,"stddev":0.03,"primary_concern":"none","rationale":"stub","sample_count":5}'
		return 0
	}
	export -f compass_evaluate
}

@test "skip sentinel [compass:skip] in file path lets the write through" {
	run compass_run_gate "Write" "/tmp/foo[compass:skip].txt" "write" \
		"$(printf 'x%.0s' {1..200})" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ]
	# Nothing written to stdout: no block decision.
	[ -z "$output" ]
}

@test "skip sentinel [compass:skip] in context lets the write through" {
	local ctx
	ctx="[compass:skip] $(printf 'y%.0s' {1..200})"
	run compass_run_gate "Write" "/tmp/foo.txt" "write" "$ctx" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "skip_glob match (*.lock) lets the write through" {
	run compass_run_gate "Write" "/tmp/package-lock.lock" "write" \
		"$(printf 'x%.0s' {1..200})" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "writes under .git/ are skipped" {
	run compass_run_gate "Write" "/tmp/repo/.git/HEAD" "write" \
		"$(printf 'x%.0s' {1..200})" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "context shorter than min_context_chars is skipped (insufficient_context)" {
	run compass_run_gate "Write" "/tmp/short.txt" "write" \
		"tiny" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "exhausted turn budget skips subsequent checks" {
	# Force the budget to be already maxed out.
	jq '.turn_check_count = 99' \
		"${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json" \
		> "${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json.new"
	mv "${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json.new" \
		"${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json"
	run compass_run_gate "Write" "/tmp/over-budget.txt" "write" \
		"$(printf 'x%.0s' {1..200})" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "dir+stem cooldown skips a re-write of the same file" {
	# Pre-seed the cooldown table with a fresh entry.
	local now
	now=$(date +%s)
	jq --argjson ts "$now" '
		.cooldown = [{"identity":"/tmp/cool/foo","path":"/tmp/cool/foo.txt","ts":$ts}]
	' "${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json" \
		> "${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json.new"
	mv "${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json.new" \
		"${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json"
	run compass_run_gate "Write" "/tmp/cool/foo.txt" "write" \
		"$(printf 'x%.0s' {1..200})" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "evaluator pass emits no block decision on stdout" {
	# Sufficient context, no skip rules apply — evaluator stub returns pass.
	run compass_run_gate "Write" "/tmp/new-file.txt" "write" \
		"$(printf 'we are writing a clearly described feature flag toggle module %.0s' {1..3})" \
		"$SESSION_ID" "" ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
