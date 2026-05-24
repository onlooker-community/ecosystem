#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-ulid.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-jury.sh"

	tribunal_config_load ""
}

@test "default empanel produces standard + adversarial" {
	local panel
	panel=$(tribunal_jury_empanel '["standard","adversarial"]')
	[ "$(printf '%s' "$panel" | jq 'length')" = "2" ]
	[ "$(printf '%s' "$panel" | jq -r '.[0].judge_type')" = "standard" ]
	[ "$(printf '%s' "$panel" | jq -r '.[1].judge_type')" = "adversarial" ]
}

@test "each panel member gets a distinct judge_id" {
	local panel
	panel=$(tribunal_jury_empanel '["standard","adversarial","security"]')
	local distinct
	distinct=$(printf '%s' "$panel" | jq -r '[.[].judge_id] | unique | length')
	[ "$distinct" = "3" ]
}

@test "panel members get model from config" {
	local panel m
	panel=$(tribunal_jury_empanel '["standard"]')
	m=$(printf '%s' "$panel" | jq -r '.[0].model')
	[ "$m" = "claude-opus-4-7" ]
}

@test "maintainability degrades to standard with warning" {
	run bash -c '
		source "${REPO_ROOT}/plugins/tribunal/scripts/lib/tribunal-config.sh"
		source "${REPO_ROOT}/plugins/tribunal/scripts/lib/tribunal-ulid.sh"
		source "${REPO_ROOT}/plugins/tribunal/scripts/lib/tribunal-jury.sh"
		CLAUDE_PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal" tribunal_config_load ""
		tribunal_jury_empanel "[\"maintainability\"]" 2>&1
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"degrading to standard"* ]]
	[[ "$output" == *"standard"* ]]
}

@test "meta type is refused in jury panel" {
	local panel
	panel=$(tribunal_jury_empanel '["standard","meta"]' 2>/dev/null)
	[ "$(printf '%s' "$panel" | jq 'length')" = "1" ]
	[ "$(printf '%s' "$panel" | jq -r '.[0].judge_type')" = "standard" ]
}

@test "subagent mapping is canonical per judge_type" {
	local panel
	panel=$(tribunal_jury_empanel '["standard","security","adversarial"]')
	[ "$(printf '%s' "$panel" | jq -r '.[0].subagent')" = "tribunal-judge-standard" ]
	[ "$(printf '%s' "$panel" | jq -r '.[1].subagent')" = "tribunal-judge-security" ]
	[ "$(printf '%s' "$panel" | jq -r '.[2].subagent')" = "tribunal-judge-adversarial" ]
}

@test "to_schema_judges strips internal subagent field" {
	local panel schema
	panel=$(tribunal_jury_empanel '["standard"]')
	schema=$(tribunal_jury_to_schema_judges "$panel")
	# subagent must NOT appear in the schema-shape output
	[ "$(printf '%s' "$schema" | jq -r '.[0] | has("subagent")')" = "false" ]
	# but judge_id, judge_type, model_id must
	[ "$(printf '%s' "$schema" | jq -r '.[0] | has("judge_id")')" = "true" ]
	[ "$(printf '%s' "$schema" | jq -r '.[0] | has("judge_type")')" = "true" ]
	[ "$(printf '%s' "$schema" | jq -r '.[0] | has("model_id")')" = "true" ]
}
