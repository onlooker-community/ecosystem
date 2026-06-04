#!/usr/bin/env bats

# Exercises the deterministic claim verifier: assayer_classify_claim and
# assayer_audit_verdict. Pure logic — no LLM, no schema, no filesystem.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-verify.sh"
}

CMDS_FAILING_TEST='[{"command":"npm test","is_error":true,"excerpt":"1 failed, 32 passed"},{"command":"git status","is_error":false,"excerpt":""}]'

@test "tests_pass claim is contradicted by a failing test command" {
	run assayer_classify_claim '{"text":"tests pass","type":"tests_pass","command_keyword":"test","confidence":0.9}' "$CMDS_FAILING_TEST"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.verdict')" = "contradicted" ]
	[ "$(printf '%s' "$output" | jq -r '.evidence_command')" = "npm test" ]
	[ "$(printf '%s' "$output" | jq -r '.excerpt')" = "1 failed, 32 passed" ]
}

@test "build_succeeds claim is corroborated by a passing build" {
	run assayer_classify_claim '{"text":"build is green","type":"build_succeeds","command_keyword":"build","confidence":0.9}' \
		'[{"command":"npm run build","is_error":false,"excerpt":"done"}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.verdict')" = "corroborated" ]
}

@test "claim with no matching command is unverified (no_matching_command)" {
	run assayer_classify_claim '{"text":"lint clean","type":"lint_clean","command_keyword":"lint","confidence":0.9}' \
		'[{"command":"npm test","is_error":false,"excerpt":""}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.verdict')" = "unverified" ]
	[ "$(printf '%s' "$output" | jq -r '.reason')" = "no_matching_command" ]
}

@test "generic claim with no keyword is unverified (ambiguous)" {
	run assayer_classify_claim '{"text":"deploy healthy","type":"generic","command_keyword":"","confidence":0.9}' \
		"$CMDS_FAILING_TEST"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.verdict')" = "unverified" ]
	[ "$(printf '%s' "$output" | jq -r '.reason')" = "ambiguous" ]
}

@test "most recent matching command wins (fix-and-rerun)" {
	# Failing test first, passing test after a fix — the later run is authoritative.
	run assayer_classify_claim '{"text":"tests pass now","type":"tests_pass","command_keyword":"test","confidence":0.9}' \
		'[{"command":"npm test","is_error":true,"excerpt":"fail"},{"command":"npm test","is_error":false,"excerpt":"pass"}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.verdict')" = "corroborated" ]
}

@test "types_check claim matches a tsc command" {
	run assayer_classify_claim '{"text":"types check out","type":"types_check","command_keyword":"","confidence":0.9}' \
		'[{"command":"npx tsc --noEmit","is_error":true,"excerpt":"TS2345"}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.verdict')" = "contradicted" ]
}

@test "command_keyword matches when type is generic" {
	run assayer_classify_claim '{"text":"migration ran","type":"generic","command_keyword":"migrate","confidence":0.9}' \
		'[{"command":"rails db:migrate","is_error":false,"excerpt":"migrated"}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.verdict')" = "corroborated" ]
}

@test "empty claim defaults to unverified ambiguous" {
	run assayer_classify_claim "" "$CMDS_FAILING_TEST"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.verdict')" = "unverified" ]
}

@test "audit verdict is contradictions_found when any contradiction" {
	[ "$(assayer_audit_verdict 1 3 0)" = "contradictions_found" ]
}

@test "audit verdict is clean with corroborations and no contradictions" {
	[ "$(assayer_audit_verdict 0 2 1)" = "clean" ]
}

@test "audit verdict is clean when only unverified claims" {
	[ "$(assayer_audit_verdict 0 0 2)" = "clean" ]
}

@test "audit verdict is nothing_to_verify when all counts zero" {
	[ "$(assayer_audit_verdict 0 0 0)" = "nothing_to_verify" ]
}
