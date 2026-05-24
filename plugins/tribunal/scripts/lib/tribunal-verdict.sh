#!/usr/bin/env bash
# Verdict persistence for Tribunal.
#
# Writes per-iteration artifacts under:
#   $ONLOOKER_DIR/tribunal/<project-key>/<task_id>/iteration-<iteration_id>/
#     actor.md
#     jury.json
#     verdicts/<judge_id>.json
#     consensus.json
#     dissent.json   (optional)
#     meta.json
#     gate.json
#
# Plus task-level files at <task_id>/{manifest,session-start,session-complete}.json.
#
# Requires tribunal-project-key.sh to be sourced.

tribunal_storage_root() {
	local base="${ONLOOKER_DIR:-$HOME/.onlooker}"
	printf '%s/tribunal' "$base"
}

tribunal_project_dir() {
	local key="$1"
	printf '%s/%s' "$(tribunal_storage_root)" "$key"
}

tribunal_task_dir() {
	local key="$1"
	local task_id="$2"
	printf '%s/%s' "$(tribunal_project_dir "$key")" "$task_id"
}

tribunal_iteration_dir() {
	local key="$1"
	local task_id="$2"
	local iteration_id="$3"
	printf '%s/iteration-%s' "$(tribunal_task_dir "$key" "$task_id")" "$iteration_id"
}

tribunal_init_task() {
	local key="$1"
	local task_id="$2"
	[[ -z "$key" || -z "$task_id" ]] && return 1
	mkdir -p "$(tribunal_task_dir "$key" "$task_id")" 2>/dev/null
}

tribunal_init_iteration() {
	local key="$1"
	local task_id="$2"
	local iteration_id="$3"
	[[ -z "$key" || -z "$task_id" || -z "$iteration_id" ]] && return 1
	mkdir -p "$(tribunal_iteration_dir "$key" "$task_id" "$iteration_id")/verdicts" 2>/dev/null
}

# Write the project-level manifest (one per project key, refreshed each task).
tribunal_write_project_manifest() {
	local key="$1"
	local remote_url="$2"
	local repo_root="$3"
	[[ -z "$key" ]] && return 1
	mkdir -p "$(tribunal_project_dir "$key")" 2>/dev/null

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	jq -n \
		--arg key "$key" \
		--arg remote "$remote_url" \
		--arg root "$repo_root" \
		--arg now "$now" \
		'{
			project_key: $key,
			remote_url: (if $remote == "" then null else $remote end),
			repo_root: (if $root == "" then null else $root end),
			last_task_at: $now,
			source: "local"
		}' > "$(tribunal_project_dir "$key")/manifest.json"
}

# Write the per-task manifest with the active rubric snapshot.
tribunal_write_task_manifest() {
	local key="$1"
	local task_id="$2"
	local task_summary="$3"
	local rubric_id="$4"
	local rubric_json="$5"
	[[ -z "$key" || -z "$task_id" ]] && return 1
	tribunal_init_task "$key" "$task_id" || return 1

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	jq -n \
		--arg task_id "$task_id" \
		--arg summary "$task_summary" \
		--arg rubric_id "$rubric_id" \
		--argjson rubric "$rubric_json" \
		--arg now "$now" \
		'{
			task_id: $task_id,
			task_summary: $summary,
			rubric_id: $rubric_id,
			rubric: $rubric,
			started_at: $now
		}' > "$(tribunal_task_dir "$key" "$task_id")/manifest.json"
}

# Append-time helpers for each per-iteration artifact. Each takes the full JSON
# blob the caller wants persisted (typically the same payload it just emitted as
# a canonical event).
tribunal_write_actor_output() {
	local key="$1" task_id="$2" iteration_id="$3" body="$4"
	tribunal_init_iteration "$key" "$task_id" "$iteration_id" || return 1
	printf '%s\n' "$body" > "$(tribunal_iteration_dir "$key" "$task_id" "$iteration_id")/actor.md"
}

tribunal_write_iteration_artifact() {
	local key="$1" task_id="$2" iteration_id="$3" name="$4" json="$5"
	tribunal_init_iteration "$key" "$task_id" "$iteration_id" || return 1
	printf '%s\n' "$json" > "$(tribunal_iteration_dir "$key" "$task_id" "$iteration_id")/${name}.json"
}

tribunal_write_judge_verdict() {
	local key="$1" task_id="$2" iteration_id="$3" judge_id="$4" verdict_json="$5"
	tribunal_init_iteration "$key" "$task_id" "$iteration_id" || return 1
	printf '%s\n' "$verdict_json" \
		> "$(tribunal_iteration_dir "$key" "$task_id" "$iteration_id")/verdicts/${judge_id}.json"
}
