#!/usr/bin/env bats

# The vendored hook-health lib: clock, record shape, and fail-soft behavior.
# See docs/superpowers/specs/2026-08-29-hook-health-instrumentation-design.md

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/scripts/lib/hook-health.sh"
	HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
}

@test "the log path derives from ONLOOKER_DIR" {
	[ "$(hook_health_log_path)" = "$HEALTH_LOG" ]
}

@test "the clock returns epoch milliseconds as 13 digits" {
	local ms
	ms=$(_hook_health_now_ms)
	[[ "$ms" =~ ^[0-9]{13}$ ]] || return 1
	# Sanity: within a decade of the date this was written.
	[ "$ms" -gt 1700000000000 ]
}

@test "a success record lands with the hook name and a duration" {
	hook_health_register "unit-test-hook"
	hook_health_success
	[ -f "$HEALTH_LOG" ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.hook == "unit-test-hook"
		and .status == "success"
		and .error == null
		and (.duration_ms | type) == "number"
		and .duration_ms >= 0
	' >/dev/null
}

@test "a failure record carries the status and the error text" {
	hook_health_register "failing-hook"
	hook_health_failure "exit_code=3"
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.status == "failure" and .error == "exit_code=3"
	' >/dev/null
}

@test "context from the hook JSON lands on the record" {
	hook_health_register "ctx-hook"
	hook_health_context '{"session_id":"sess-1","tool_name":"Write","hook_event_name":"PostToolUse"}'
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.session_id == "sess-1"
		and .tool_name == "Write"
		and .hook_event == "PostToolUse"
	' >/dev/null
}

@test "absent context leaves the optional fields null, not empty strings" {
	hook_health_register "bare-hook"
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.session_id == null and .tool_name == null and .hook_event == null
	' >/dev/null
}

@test "registering without writing produces no record" {
	hook_health_register "never-finished"
	[ ! -f "$HEALTH_LOG" ]
}

@test "an unwritable log directory does not fail the caller" {
	export ONLOOKER_HOOK_HEALTH_LOG="/proc/nonexistent/nope/hook-health.jsonl"
	hook_health_register "fail-soft-hook"
	run hook_health_success
	[ "$status" -eq 0 ]
}

@test "an exiting hook logs success without an explicit call" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'trapped-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "trapped-hook" and .status == "success"' >/dev/null
}

@test "a nonzero exit is recorded as a failure with the exit code" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'crashing-hook'
		exit 7
	"
	[ "$status" -eq 7 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.status == "failure" and .error == "exit_code=7"' >/dev/null
}

# The regression this whole task exists for. Modeled on the real pattern in
# assayer-stop.sh and tribunal-stop-gate.sh.
@test "a pre-existing EXIT trap still runs after registering" {
	local victim="${BATS_TEST_TMPDIR}/prompt-file"
	touch "$victim"
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		trap 'rm -f \"${victim}\"' EXIT
		hook_health_register 'polite-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	# The prior handler ran: the temp file is gone.
	[ ! -f "$victim" ] || return 1
	# And we still got our record.
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "polite-hook"' >/dev/null
}

@test "a pre-existing trap containing single quotes survives chaining" {
	local victim="${BATS_TEST_TMPDIR}/quoted file"
	touch "$victim"
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		trap \"rm -f '${victim}'\" EXIT
		hook_health_register 'quoted-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$victim" ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "quoted-hook"' >/dev/null
}

# librarian's classifier disarms its own EXIT trap with a bare `trap - EXIT`.
# That is safe only because production always calls it inside a command
# substitution, where the clear wipes the subshell's own copy and leaves the
# caller's health trap intact. Calling it directly would eat the health trap, so
# this pins the call shape: exactly one record. Real call sites are
# librarian-session-end.sh:222 and :467.
@test "librarian_classifier_call in a subshell leaves exactly one health record" {
	local stub_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_bin"
	cat > "${stub_bin}/claude" <<-'STUB'
		#!/usr/bin/env bash
		printf '%s' '{"type":"project","title":"t","body":"b","confidence":0.9}'
	STUB
	chmod +x "${stub_bin}/claude"

	run bash -c "
		export PATH=\"${stub_bin}:\$PATH\"
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		source '${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-classifier.sh'
		hook_health_register 'librarian-session-end'
		RESPONSE=\$(librarian_classifier_call '{\"summary\":\"s\",\"detail\":\"d\"}' '' 0.2 256)
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	[ -f "$HEALTH_LOG" ] || return 1
	[ "$(grep -c '\"hook\":\"librarian-session-end\"' "$HEALTH_LOG")" -eq 1 ]
}

# A real plugin hook, driven end to end, must name itself in the health log.
@test "a real plugin hook records its own latency" {
	local plugin_root="${REPO_ROOT}/plugins/lineage"
	export CLAUDE_PLUGIN_ROOT="$plugin_root"
	export ONLOOKER_HOOK_HEALTH_LOG="$HEALTH_LOG"

	local target="${BATS_TEST_TMPDIR}/edited.txt"
	printf 'hello\n' > "$target"

	local input
	input=$(jq -cn --arg f "$target" --arg cwd "$BATS_TEST_TMPDIR" \
		'{session_id:"hh-test", cwd:$cwd, tool_name:"Write",
		  hook_event_name:"PostToolUse",
		  tool_input:{file_path:$f, content:"hello"}}')

	run bash -c "printf '%s' '$input' | '${plugin_root}/scripts/hooks/lineage-post-tool-use.sh'"
	[ "$status" -eq 0 ] || return 1
	[ -f "$HEALTH_LOG" ] || return 1
	grep -q '"hook":"lineage-post-tool-use"' "$HEALTH_LOG"
}

# Guard: a `trap ... EXIT` installed after hook_health_register silently
# REPLACES the health-record trap instead of extending it — trap installs
# replace, they don't stack, and hook_health_register's own chaining only
# protects a trap that predates it. Four hooks hit this for real (assayer,
# archivist, echo, tribunal all trap their own PROMPT_FILE cleanup on EXIT
# after registering); this pins it so it can't come back.
@test "no plugin hook installs a trap EXIT after hook_health_register" {
	local hooks=()
	while IFS= read -r -d '' f; do
		hooks+=("$f")
	done < <(find "${REPO_ROOT}/plugins" -path '*/scripts/hooks/*.sh' -print0)

	# The glob must match at least one hook, or every assertion below passes
	# vacuously over an empty list.
	[ "${#hooks[@]}" -gt 0 ] || return 1

	# cartographer's `trap ... EXIT` lines live inside a `nohup setsid bash -c
	# "..."` string — a detached background child with its own trap table
	# that the parent shell's hook_health_register never touches. Genuinely
	# safe. Explicit allowlist rather than a regex that tries to detect
	# string nesting: honest and won't rot.
	local allowlisted=("cartographer-post-write.sh" "cartographer-session-start.sh")

	local offenders=()
	local f base register_line trap_line skip a
	for f in "${hooks[@]}"; do
		base=$(basename "$f")
		skip=0
		for a in "${allowlisted[@]}"; do
			[ "$base" = "$a" ] && skip=1 && break
		done
		[ "$skip" -eq 1 ] && continue

		# Match the actual call (a quote follows), not a comment that merely
		# mentions hook_health_register — the fixed hooks below explain the
		# hoist in a comment that names the function itself.
		register_line=$(grep -nE 'hook_health_register[[:space:]]*"' "$f" | head -n1 | cut -d: -f1)
		[ -z "$register_line" ] && continue

		trap_line=$(grep -nE '^[[:space:]]*trap[[:space:]].*EXIT' "$f" \
			| awk -F: -v rl="$register_line" '$1 > rl {print $1; exit}')
		[ -n "$trap_line" ] && offenders+=("${f}:${trap_line} (register at ${register_line})")
	done

	if [ "${#offenders[@]}" -gt 0 ]; then
		printf 'trap EXIT installed after hook_health_register:\n' >&2
		printf '  %s\n' "${offenders[@]}" >&2
		return 1
	fi
}
