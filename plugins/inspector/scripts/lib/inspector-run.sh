#!/usr/bin/env bash
# inspector-run.sh — execute the configured checks for a single touched file.
#
# Reads:   $INSPECTOR_FILE, $INSPECTOR_FILE_RELATIVE, $INSPECTOR_REPO_ROOT,
#          $INSPECTOR_PROJECT_KEY, $INSPECTOR_TOOL_NAME
# Emits:   inspector.check.passed / .failed / .skipped (per check), then
#          inspector.run.completed (once).
# Writes:  a compact per-file summary to stdout, intended to be shown to the
#          agent as PostToolUse additional context.

set -uo pipefail

_inspector_now_ms() {
	if date +%s%3N &>/dev/null && [[ "$(date +%s%3N)" =~ ^[0-9]{13}$ ]]; then
		date +%s%3N
	else
		python3 -c 'import time; print(int(time.time() * 1000))'
	fi
}

# Substitute ${file}, ${file_relative}, ${repo_root} in each argv element.
_inspector_expand_argv() {
	local raw_argv_json="$1"
	jq -c \
		--arg file "$INSPECTOR_FILE" \
		--arg rel "$INSPECTOR_FILE_RELATIVE" \
		--arg root "$INSPECTOR_REPO_ROOT" \
		'map(
			gsub("\\$\\{file\\}"; $file)
			| gsub("\\$\\{file_relative\\}"; $rel)
			| gsub("\\$\\{repo_root\\}"; $root)
		)' <<<"$raw_argv_json"
}

# Run a single check. Stdout: the captured combined output, truncated to
# output_excerpt_max_bytes. Exit code: the underlying command's exit, or 124 on
# timeout, or 127 when the command is not on PATH.
_inspector_invoke_check() {
	local expanded_json="$1"
	local timeout_s="$2"
	local max_bytes="$3"

	# Build argv array from JSON for safe execution.
	# bash 3.2 (macOS default) has no `mapfile`; collect with a while-read loop.
	local expanded_argv=()
	local _line
	while IFS= read -r _line; do
		expanded_argv+=("$_line")
	done < <(jq -r '.[]' <<<"$expanded_json")
	local cmd="${expanded_argv[0]:-}"
	if [[ -z "$cmd" ]]; then
		printf 'inspector: empty argv\n'
		return 127
	fi
	if ! command -v "$cmd" >/dev/null 2>&1; then
		return 127
	fi

	local output_file rc=0
	output_file=$(mktemp -t inspector-out.XXXXXX 2>/dev/null) \
		|| output_file="/tmp/inspector-out.$$"

	if command -v timeout >/dev/null 2>&1; then
		timeout "${timeout_s}s" "${expanded_argv[@]}" >"$output_file" 2>&1
		rc=$?
	else
		"${expanded_argv[@]}" >"$output_file" 2>&1
		rc=$?
	fi

	# Truncate output for the event payload and the agent-facing line.
	local bytes=0
	bytes=$(wc -c <"$output_file" 2>/dev/null || printf '0')
	if (( bytes > max_bytes )); then
		head -c "$max_bytes" "$output_file"
		printf '\n…[truncated]\n'
	else
		cat "$output_file"
	fi
	rm -f "$output_file"
	return "$rc"
}

# Count issues from output — best-effort. One non-empty, non-whitespace line per
# issue, ignoring trivial header/footer markers. Returns the literal string
# "null" when the output is empty or only whitespace.
_inspector_count_issues() {
	local text="$1"
	[[ -z "$text" ]] && { printf 'null'; return; }
	local count
	count=$(printf '%s' "$text" | grep -cE '^[^[:space:]]' || true)
	if [[ -z "$count" || "$count" == "0" ]]; then
		printf 'null'
	else
		printf '%s' "$count"
	fi
}

# Public entrypoint. Iterates the configured checks for the file's extension.
inspector_run() {
	local checks_json="${1:-[]}"
	local timeout_per_check
	timeout_per_check=$(inspector_config_timeout_per_check)
	local total_timeout
	total_timeout=$(inspector_config_total_timeout)
	local max_bytes
	max_bytes=$(inspector_config_output_excerpt_max_bytes)
	local show_clean=0
	inspector_config_show_clean_runs && show_clean=1

	local check_count
	check_count=$(jq 'length' <<<"$checks_json")

	local run_start
	run_start=$(_inspector_now_ms)
	local passed=0 failed=0 skipped=0 ran=0

	# Buffer agent-facing output so we only print the file header when at least
	# one issue (or, when show_clean is set, one check) is worth reporting.
	local agent_lines=()
	local issues_seen=0

	local i
	for (( i = 0; i < check_count; i++ )); do
		# Budget check before each run.
		local now_ms
		now_ms=$(_inspector_now_ms)
		if (( (now_ms - run_start) >= (total_timeout * 1000) )); then
			local rem
			rem=$(jq -c --argjson i "$i" '.[$i:]' <<<"$checks_json")
			local rem_count
			rem_count=$(jq 'length' <<<"$rem")
			local j
			for (( j = 0; j < rem_count; j++ )); do
				local r_name r_kind
				r_name=$(jq -r --argjson j "$j" '.[$j].name // "check"' <<<"$rem")
				r_kind=$(jq -r --argjson j "$j" '.[$j].kind // "lint"' <<<"$rem")
				_inspector_emit_skipped "$r_name" "$r_kind" "total_budget_exhausted"
				(( skipped++ ))
			done
			break
		fi

		local check_name check_kind argv_raw
		check_name=$(jq -r --argjson i "$i" '.[$i].name' <<<"$checks_json")
		check_kind=$(jq -r --argjson i "$i" '.[$i].kind' <<<"$checks_json")
		argv_raw=$(jq -c --argjson i "$i" '.[$i].argv' <<<"$checks_json")
		local argv_expanded
		argv_expanded=$(_inspector_expand_argv "$argv_raw")

		local check_start
		check_start=$(_inspector_now_ms)
		local output rc=0
		output=$(_inspector_invoke_check "$argv_expanded" "$timeout_per_check" "$max_bytes")
		rc=$?
		local check_end
		check_end=$(_inspector_now_ms)
		local dur=$(( check_end - check_start ))

		if (( rc == 127 )); then
			# Tool not on PATH.
			_inspector_emit_skipped "$check_name" "$check_kind" "tool_missing"
			(( skipped++ ))
			continue
		fi

		if (( rc == 124 )); then
			# Timed out — emit skipped + a single agent-facing line.
			_inspector_emit_skipped "$check_name" "$check_kind" "timeout"
			agent_lines+=("  · $check_name timed out after ${timeout_per_check}s")
			(( skipped++ ))
			(( issues_seen++ ))
			continue
		fi

		(( ran++ ))
		if (( rc == 0 )); then
			(( passed++ ))
			_inspector_emit_passed "$check_name" "$check_kind" "$argv_expanded" "$dur"
			if (( show_clean )); then
				agent_lines+=("  ✓ $check_name (${dur}ms)")
			fi
		else
			(( failed++ ))
			local issue_count
			issue_count=$(_inspector_count_issues "$output")
			_inspector_emit_failed "$check_name" "$check_kind" "$argv_expanded" "$dur" "$rc" "$issue_count" "$output"
			local issues_label="${issue_count}"
			if [[ "$issues_label" == "null" ]]; then
				issues_label="issues"
			else
				issues_label="${issues_label} issue(s)"
			fi
			agent_lines+=("  ✗ $check_name (${issues_label}, exit ${rc})")
			# Append up to 6 issue lines for at-a-glance context.
			local snippet
			snippet=$(printf '%s\n' "$output" | grep -E '^[^[:space:]]' | head -n 6 || true)
			while IFS= read -r line; do
				[[ -z "$line" ]] && continue
				agent_lines+=("      $line")
			done <<<"$snippet"
			(( issues_seen++ ))
		fi
	done

	local run_end
	run_end=$(_inspector_now_ms)
	local run_dur=$(( run_end - run_start ))

	_inspector_emit_run_completed "$ran" "$passed" "$failed" "$skipped" "$run_dur"

	if (( issues_seen > 0 )) || (( show_clean && (passed + failed) > 0 )); then
		printf 'inspector: %s\n' "$INSPECTOR_FILE_RELATIVE"
		printf '%s\n' "${agent_lines[@]}"
	fi
}

_inspector_emit_passed() {
	local name="$1" kind="$2" argv_json="$3" dur="$4"
	local payload
	payload=$(jq -n \
		--arg file "$INSPECTOR_FILE" \
		--arg rel "$INSPECTOR_FILE_RELATIVE" \
		--arg tool "$INSPECTOR_TOOL_NAME" \
		--arg name "$name" \
		--arg kind "$kind" \
		--arg pk "$INSPECTOR_PROJECT_KEY" \
		--argjson argv "$argv_json" \
		--argjson dur "$dur" \
		'{file_path:$file,file_path_relative:$rel,tool_name:$tool,check_name:$name,check_kind:$kind,argv:$argv,duration_ms:$dur,project_key:$pk}')
	inspector_emit_event "inspector.check.passed" "$payload" || true
}

_inspector_emit_failed() {
	local name="$1" kind="$2" argv_json="$3" dur="$4" rc="$5" issues="$6" output="$7"
	local issues_arg
	if [[ "$issues" == "null" ]]; then
		issues_arg="null"
	else
		issues_arg="$issues"
	fi
	local truncated="false"
	[[ "$output" == *"…[truncated]"* ]] && truncated="true"
	local payload
	payload=$(jq -n \
		--arg file "$INSPECTOR_FILE" \
		--arg rel "$INSPECTOR_FILE_RELATIVE" \
		--arg tool "$INSPECTOR_TOOL_NAME" \
		--arg name "$name" \
		--arg kind "$kind" \
		--arg pk "$INSPECTOR_PROJECT_KEY" \
		--arg output "$output" \
		--argjson argv "$argv_json" \
		--argjson dur "$dur" \
		--argjson rc "$rc" \
		--argjson issues "$issues_arg" \
		--argjson truncated "$truncated" \
		'{file_path:$file,file_path_relative:$rel,tool_name:$tool,check_name:$name,check_kind:$kind,argv:$argv,duration_ms:$dur,exit_code:$rc,issue_count:$issues,output_excerpt:$output,output_truncated:$truncated,project_key:$pk}')
	inspector_emit_event "inspector.check.failed" "$payload" || true
}

_inspector_emit_skipped() {
	local name="$1" kind="$2" reason="$3"
	local payload
	payload=$(jq -n \
		--arg file "$INSPECTOR_FILE" \
		--arg rel "$INSPECTOR_FILE_RELATIVE" \
		--arg tool "$INSPECTOR_TOOL_NAME" \
		--arg name "$name" \
		--arg kind "$kind" \
		--arg reason "$reason" \
		--arg pk "$INSPECTOR_PROJECT_KEY" \
		'{file_path:$file,file_path_relative:$rel,tool_name:$tool,check_name:$name,check_kind:$kind,reason:$reason,project_key:$pk}')
	inspector_emit_event "inspector.check.skipped" "$payload" || true
}

inspector_emit_whole_file_skipped() {
	local reason="$1"
	local payload
	payload=$(jq -n \
		--arg file "${INSPECTOR_FILE:-}" \
		--arg rel "${INSPECTOR_FILE_RELATIVE:-}" \
		--arg tool "${INSPECTOR_TOOL_NAME:-}" \
		--arg reason "$reason" \
		--arg pk "${INSPECTOR_PROJECT_KEY:-}" \
		'{file_path:$file,file_path_relative:$rel,tool_name:$tool,reason:$reason,project_key:$pk}')
	inspector_emit_event "inspector.check.skipped" "$payload" || true
}

_inspector_emit_run_completed() {
	local ran="$1" passed="$2" failed="$3" skipped="$4" dur="$5"
	local payload
	payload=$(jq -n \
		--arg file "$INSPECTOR_FILE" \
		--arg rel "$INSPECTOR_FILE_RELATIVE" \
		--arg tool "$INSPECTOR_TOOL_NAME" \
		--arg pk "$INSPECTOR_PROJECT_KEY" \
		--argjson ran "$ran" \
		--argjson passed "$passed" \
		--argjson failed "$failed" \
		--argjson skipped "$skipped" \
		--argjson dur "$dur" \
		'{file_path:$file,file_path_relative:$rel,tool_name:$tool,checks_run:$ran,checks_passed:$passed,checks_failed:$failed,checks_skipped:$skipped,duration_ms:$dur,project_key:$pk}')
	inspector_emit_event "inspector.run.completed" "$payload" || true
}
