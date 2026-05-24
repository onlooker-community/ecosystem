#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-ulid.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-verdict.sh"

	KEY="abc123def456"
	TASK_ID=$(tribunal_ulid)
	ITER_ID=$(tribunal_ulid)
}

@test "ulid is 26 chars" {
	local u
	u=$(tribunal_ulid)
	[ "${#u}" -eq 26 ]
}

@test "init_task creates task directory" {
	tribunal_init_task "$KEY" "$TASK_ID"
	[ -d "${ONLOOKER_DIR}/tribunal/${KEY}/${TASK_ID}" ]
}

@test "init_iteration creates iteration + verdicts dirs" {
	tribunal_init_iteration "$KEY" "$TASK_ID" "$ITER_ID"
	[ -d "${ONLOOKER_DIR}/tribunal/${KEY}/${TASK_ID}/iteration-${ITER_ID}/verdicts" ]
}

@test "write_project_manifest stores remote + repo_root" {
	tribunal_write_project_manifest "$KEY" "https://example.com/r.git" "/tmp/repo"
	local m
	m=$(jq -r '.remote_url' "${ONLOOKER_DIR}/tribunal/${KEY}/manifest.json")
	[ "$m" = "https://example.com/r.git" ]
	[ "$(jq -r '.source' "${ONLOOKER_DIR}/tribunal/${KEY}/manifest.json")" = "local" ]
}

@test "write_task_manifest stores rubric snapshot" {
	local rubric='{"id":"default","criteria":[{"name":"a","weight":1.0,"min_pass":0.5}],"score_threshold":0.75,"max_iterations":3,"judge_types":["standard"],"gate_policy":"majority","aggregation_method":"mean"}'
	tribunal_write_task_manifest "$KEY" "$TASK_ID" "do the thing" "default" "$rubric"
	local path="${ONLOOKER_DIR}/tribunal/${KEY}/${TASK_ID}/manifest.json"
	[ -f "$path" ]
	[ "$(jq -r '.task_summary' "$path")" = "do the thing" ]
	[ "$(jq -r '.rubric.gate_policy' "$path")" = "majority" ]
}

@test "write_actor_output writes actor.md" {
	tribunal_write_actor_output "$KEY" "$TASK_ID" "$ITER_ID" "# work"
	local path="${ONLOOKER_DIR}/tribunal/${KEY}/${TASK_ID}/iteration-${ITER_ID}/actor.md"
	[ -f "$path" ]
	[[ "$(cat "$path")" == "# work" ]]
}

@test "write_judge_verdict writes one file per judge_id" {
	local v='{"score":0.8,"passed":true,"judge_type":"standard"}'
	tribunal_write_judge_verdict "$KEY" "$TASK_ID" "$ITER_ID" "judge-1" "$v"
	tribunal_write_judge_verdict "$KEY" "$TASK_ID" "$ITER_ID" "judge-2" "$v"
	local count
	count=$(find "${ONLOOKER_DIR}/tribunal/${KEY}/${TASK_ID}/iteration-${ITER_ID}/verdicts" -name '*.json' -type f | wc -l | tr -d ' ')
	[ "$count" = "2" ]
}

@test "write_iteration_artifact persists named JSON files" {
	tribunal_write_iteration_artifact "$KEY" "$TASK_ID" "$ITER_ID" "consensus" '{"aggregated_score":0.8,"passed":true}'
	[ -f "${ONLOOKER_DIR}/tribunal/${KEY}/${TASK_ID}/iteration-${ITER_ID}/consensus.json" ]
}
