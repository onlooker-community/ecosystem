#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-rubric.sh"

	tribunal_config_load ""
}

@test "default rubric loads from builtins" {
	tribunal_rubric_load ""
	local r id
	r=$(tribunal_rubric_get "default")
	[ -n "$r" ]
	id=$(printf '%s' "$r" | jq -r '.id')
	[ "$id" = "default" ]
}

@test "default rubric id resolves to 'default'" {
	local id
	id=$(tribunal_rubric_default_id)
	[ "$id" = "default" ]
}

@test "default rubric passes validation" {
	tribunal_rubric_load ""
	local r
	r=$(tribunal_rubric_get "default")
	run tribunal_rubric_validate "$r"
	[ "$status" -eq 0 ]
}

@test "project rubric override by id replaces builtin" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	cat > "${repo}/.claude/tribunal.json" <<'EOF'
{
  "rubrics": [
    {
      "id": "default",
      "criteria": [
        { "name": "tests", "weight": 1.0, "min_pass": 0.9 }
      ],
      "score_threshold": 0.9,
      "max_iterations": 5,
      "judge_types": ["standard"],
      "gate_policy": "strict",
      "aggregation_method": "min"
    }
  ]
}
EOF
	tribunal_rubric_load "$repo"
	local r mi gp
	r=$(tribunal_rubric_get "default")
	mi=$(printf '%s' "$r" | jq -r '.max_iterations')
	gp=$(printf '%s' "$r" | jq -r '.gate_policy')
	[ "$mi" = "5" ]
	[ "$gp" = "strict" ]
}

@test "named rubric from project file is reachable by id" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	cat > "${repo}/.claude/tribunal.json" <<'EOF'
{
  "rubrics": [
    {
      "id": "security-tight",
      "criteria": [
        { "name": "security", "weight": 1.0, "min_pass": 0.95 }
      ],
      "score_threshold": 0.95,
      "max_iterations": 3,
      "judge_types": ["standard", "security"],
      "gate_policy": "unanimous",
      "aggregation_method": "min"
    }
  ]
}
EOF
	tribunal_rubric_load "$repo"
	local r
	r=$(tribunal_rubric_get "security-tight")
	[ -n "$r" ]
	[ "$(printf '%s' "$r" | jq -r '.id')" = "security-tight" ]
}

@test "missing rubric id returns empty" {
	tribunal_rubric_load ""
	local r
	r=$(tribunal_rubric_get "does-not-exist")
	[ -z "$r" ]
}

@test "validate rejects weights summing != 1" {
	local r='{"id":"bad","criteria":[{"name":"a","weight":0.4,"min_pass":0.5},{"name":"b","weight":0.4,"min_pass":0.5}],"score_threshold":0.75,"max_iterations":3,"judge_types":["standard"],"gate_policy":"majority","aggregation_method":"mean"}'
	run tribunal_rubric_validate "$r"
	[ "$status" -ne 0 ]
}

@test "validate rejects invalid gate_policy" {
	local r='{"id":"bad","criteria":[{"name":"a","weight":1.0,"min_pass":0.5}],"score_threshold":0.75,"max_iterations":3,"judge_types":["standard"],"gate_policy":"democracy","aggregation_method":"mean"}'
	run tribunal_rubric_validate "$r"
	[ "$status" -ne 0 ]
}

@test "validate rejects out-of-range score_threshold" {
	local r='{"id":"bad","criteria":[{"name":"a","weight":1.0,"min_pass":0.5}],"score_threshold":1.5,"max_iterations":3,"judge_types":["standard"],"gate_policy":"majority","aggregation_method":"mean"}'
	run tribunal_rubric_validate "$r"
	[ "$status" -ne 0 ]
}
