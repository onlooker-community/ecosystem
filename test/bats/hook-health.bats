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

# A nested `claude` inherits the parent's exported _HOOK_SESSION_ID, so the
# payload must win or every hook that child fires is filed under the parent.
# That mis-attribution is what made 93 separate sessions look like one session
# re-firing SessionStart 93 times (ecosystem-449.27).
@test "the payload session_id beats an inherited _HOOK_SESSION_ID" {
	export _HOOK_SESSION_ID="parent-session"
	hook_health_register "nested-hook"
	hook_health_context '{"session_id":"child-session","hook_event_name":"SessionStart"}'
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '.session_id == "child-session"' >/dev/null
}

# The inverse must not regress: several plugins parse their own payload and set
# _HOOK_SESSION_ID before sourcing, then hand hook_health_context a payload that
# may carry no session_id at all. Overriding unconditionally would blank those.
@test "a caller-set session id survives a payload that carries none" {
	_HOOK_SESSION_ID="caller-set"
	hook_health_register "caller-hook"
	hook_health_context '{"hook_event_name":"Stop"}'
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '.session_id == "caller-set"' >/dev/null
}

@test "an explicitly empty payload session_id does not blank a caller-set id" {
	_HOOK_SESSION_ID="caller-set"
	hook_health_register "empty-sid-hook"
	hook_health_context '{"session_id":"","hook_event_name":"Stop"}'
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '.session_id == "caller-set"' >/dev/null
}

# tool_name and hook_event are never exported by any plugin, so they keep the
# original caller-wins semantics. Pinned so the fix stays scoped to session_id.
@test "caller-set tool_name and hook_event still win over the payload" {
	_HOOK_TOOL_NAME="CallerTool"
	_HOOK_EVENT="CallerEvent"
	hook_health_register "scope-hook"
	hook_health_context '{"session_id":"s","tool_name":"PayloadTool","hook_event_name":"PayloadEvent"}'
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.tool_name == "CallerTool" and .hook_event == "CallerEvent"
	' >/dev/null
}

# Since ecosystem-449.66 register DOES write: the start breadcrumb, which is
# what makes a SIGKILLed hook legible. What must still be absent is a TERMINAL
# record — registering alone has never been, and must never become, evidence
# that a hook finished.
@test "registering without writing produces a breadcrumb but no terminal record" {
	hook_health_register "never-finished"
	[ -f "$HEALTH_LOG" ] || return 1
	[ "$(jq -sc '[.[] | select(.status == "started")] | length' "$HEALTH_LOG")" -eq 1 ] || return 1
	[ "$(jq -sc '[.[] | select(.status != "started")] | length' "$HEALTH_LOG")" -eq 0 ]
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
		hook_health_exit 0
	"
	[ "$status" -eq 0 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "trapped-hook" and .status == "success"' >/dev/null
}

@test "a nonzero exit is recorded as a failure with the exit code" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'crashing-hook'
		hook_health_exit 7
	"
	[ "$status" -eq 7 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.status == "failure" and .error == "exit_code=7"' >/dev/null
}

# The contract inversion from ecosystem-449.66, stated directly: a bare `exit`
# is no longer evidence of success, because the EXIT trap cannot tell one from a
# kill. This is what makes hook_health_exit load-bearing rather than cosmetic,
# and it is why the enforcing test below bans a bare exit in a registering hook.
@test "an exit that never marks completion is recorded as terminated" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'unmarked-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.hook == "unmarked-hook" and .status == "terminated"
	' >/dev/null
}

# hook_health_success / hook_health_failure are themselves statements that the
# hook reached a decision, so they must imply completion. If they did not, every
# hook that writes its own record explicitly would be reported as terminated.
@test "an explicit success call counts as completion" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'explicit-hook'
		hook_health_success
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	[ "$(jq -sc '[.[] | select(.hook == "explicit-hook" and .status != "started")] | length' "$HEALTH_LOG")" -eq 1 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.status == "success"' >/dev/null
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
	# One breadcrumb and exactly one TERMINAL record. The hazard this pins is a
	# subshell producing a SECOND terminal record, which the breadcrumb count
	# would not reveal (ecosystem-449.66 added the breadcrumb, not a second
	# terminal write).
	[ "$(jq -sc '[.[] | select(.hook == "librarian-session-end" and .status == "started")] | length' "$HEALTH_LOG")" -eq 1 ] || return 1
	[ "$(jq -sc '[.[] | select(.hook == "librarian-session-end" and .status != "started")] | length' "$HEALTH_LOG")" -eq 1 ]
}

# librarian's lesson transform disarms its own EXIT trap the same way the
# classifier does above (librarian-lesson-transform.sh:169 and :193). Safe
# only because production always calls it inside a command substitution:
# librarian-session-end.sh:471 calls librarian_lesson_transform_one, whose
# own call to librarian_lesson_call at librarian-lesson-transform.sh:256 is
# itself a command substitution. This pins that call shape: exactly one
# record. If either level ever becomes a direct call, the health trap gets
# eaten silently — this test exists to catch that.
@test "librarian_lesson_call in a subshell leaves exactly one health record" {
	local stub_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_bin"
	cat > "${stub_bin}/claude" <<-'STUB'
		#!/usr/bin/env bash
		printf '%s' '{"eligible":false,"reason":"no_versions"}'
	STUB
	chmod +x "${stub_bin}/claude"

	run bash -c "
		export PATH=\"${stub_bin}:\$PATH\"
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		source '${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-config.sh'
		source '${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-lesson-transform.sh'
		hook_health_register 'librarian-session-end'
		RAW=\$(librarian_lesson_call '{\"summary\":\"s\",\"detail\":\"d\"}' '')
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	[ -f "$HEALTH_LOG" ] || return 1
	# One breadcrumb and exactly one TERMINAL record. The hazard this pins is a
	# subshell producing a SECOND terminal record, which the breadcrumb count
	# would not reveal (ecosystem-449.66 added the breadcrumb, not a second
	# terminal write).
	[ "$(jq -sc '[.[] | select(.hook == "librarian-session-end" and .status == "started")] | length' "$HEALTH_LOG")" -eq 1 ] || return 1
	[ "$(jq -sc '[.[] | select(.hook == "librarian-session-end" and .status != "started")] | length' "$HEALTH_LOG")" -eq 1 ]
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

# Completeness guard: every plugin hook must call hook_health_register, or
# it is invisible to latency measurement and every other test in this file
# stays green regardless. The trap-ordering guard below only checks hooks
# that already register — a hook merged without a register line at all skips
# its own `continue` there and is never flagged. This is the test that
# catches that hook. Not pinned to a count, so adding a plugin hook doesn't
# fail this test by itself — only an unregistered one does.
@test "every plugin hook calls hook_health_register" {
	local hooks=()
	while IFS= read -r -d '' f; do
		hooks+=("$f")
	done < <(find "${REPO_ROOT}/plugins" -path '*/scripts/hooks/*.sh' -print0)

	# The glob must match at least one hook, or the loop below passes
	# vacuously over an empty list.
	[ "${#hooks[@]}" -gt 0 ] || return 1

	local offenders=()
	local f
	for f in "${hooks[@]}"; do
		# Match the actual call (a quote follows the name), not a comment
		# that merely mentions hook_health_register — several hooks now
		# explain the trap hoist in a comment that names the function.
		grep -qE 'hook_health_register[[:space:]]*"' "$f" || offenders+=("$f")
	done

	if [ "${#offenders[@]}" -gt 0 ]; then
		printf 'plugin hooks missing hook_health_register:\n' >&2
		printf '  %s\n' "${offenders[@]}" >&2
		return 1
	fi
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

# ---------------------------------------------------------------------------
# Measurement accuracy: ecosystem-449.7 (unmeasurable vs fast) and
# ecosystem-449.9 (write-path subprocesses inside the measured window).
# ---------------------------------------------------------------------------

# A duration that could not be computed must be distinguishable from a hook
# that genuinely took under a millisecond. Both used to write 0, so a bad
# stamp or a backward clock step silently deflated the mean that
# hook_health_summary reports and the rollout reads.
@test "an unmeasurable duration records null, not zero" {
	hook_health_register "bad-stamp-hook"
	_HOOK_START_MS="not-a-number"
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '.duration_ms == null' >/dev/null
}

@test "a backward clock step records null rather than a bogus duration" {
	hook_health_register "time-traveling-hook"
	# A start stamp in the future is what a backward NTP correction looks like
	# from inside the window.
	_HOOK_START_MS=$(( $(_hook_health_now_ms) + 60000 ))
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '.duration_ms == null' >/dev/null
}

@test "a real hook records a numeric duration, not null" {
	hook_health_register "real-hook"
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '(.duration_ms | type) == "number" and .duration_ms >= 0' >/dev/null
}

# The write path used to run dirname and mkdir -p between the two clock reads,
# so their cost landed inside every reported duration. mkdir is now skipped
# once the log exists -- this pins that the skip did not break first-write.
@test "the log directory is created on first write and reused after" {
	rm -rf "$(dirname "$HEALTH_LOG")"
	hook_health_register "first-write-hook"
	hook_health_success
	[ -f "$HEALTH_LOG" ] || return 1

	hook_health_register "second-write-hook"
	hook_health_success
	# Four lines, not two: since ecosystem-449.66 each fire writes a start
	# breadcrumb as well as its terminal record. The breadcrumb is now the
	# first write, so it is also the one that has to create the directory.
	[ "$(wc -l < "$HEALTH_LOG" | tr -d ' ')" -eq 4 ] || return 1
	[ "$(jq -sc '[.[] | select(.status == "started")] | length' "$HEALTH_LOG")" -eq 2 ]
}

# Loose bound only. The real improvement (a ~7.25ms floor down to ~3.15ms) is
# not asserted numerically here: a tight timing assertion would be flaky on a
# loaded machine or slower box, and a flaky test is worse than none. This
# catches a catastrophic regression, nothing subtler.
#
# RECALIBRATED from 50ms to 150ms by ecosystem-449.66, which made the instrument
# write two records per fire instead of one. The bound was chosen when it wrote
# one, and the second append is not free: measured in this fixture on a loaded
# host, baseline passed 8/8 while the breadcrumb version passed 3/8, with
# duration_ms landing at 42-52 against 18-23. Bisected to the append itself —
# not the escaping or formatting, which together cost 0.27ms.
#
# The append is now excluded from the window wherever a free clock lets it be
# (see hook_health_register), but bash 3.2 has no free clock, and buying the
# exclusion there with another jq fork would cost more than the append does.
# So on macOS the reported duration still carries it.
#
# Raising a bound to make a test pass deserves suspicion, so: what this test is
# for is catching catastrophe — a jq-per-line Stop cost, an accidental network
# call, a sleep. Those are seconds, and 150ms still catches every one of them.
# What it can no longer do is notice a few extra milliseconds, which it could
# not reliably do at 50 either once the host was busy.
@test "a hook that does no work reports a small duration" {
	hook_health_register "trivial-hook"
	hook_health_success
	local observed
	observed=$(tail -n 1 "$HEALTH_LOG" | jq -r '.duration_ms')
	# Report the number when it blows. This used to fail through a bare
	# `jq -e`, which prints nothing, so a CI failure said only that the budget
	# was missed -- not whether by 1ms or by 200, and therefore not whether the
	# cause was a real regression or a slow runner. Diagnosing one cost a round
	# trip that the number would have answered outright.
	[ "$observed" != "null" ] || { echo "duration_ms was null, not measured" >&2; return 1; }
	[ "$observed" -lt 150 ] || { echo "duration_ms=${observed}, budget 150" >&2; return 1; }
}

# Re-registering in one process used to OVERWRITE _HOOK_PRIOR_EXIT_CMD with our
# own handler, discarding the caller's original trap. The second register saw
# `_hook_health_on_exit $?` as "the prior trap" and captured that instead. Net
# effect: a hook that registers twice silently loses the cleanup it was
# supposed to preserve — the exact failure chaining exists to prevent.
@test "re-registering preserves the caller's original exit trap" {
	local victim="${BATS_TEST_TMPDIR}/original-cleanup-ran"
	run bash -c "
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		trap 'touch \"${victim}\"' EXIT
		hook_health_register first;  hook_health_success
		hook_health_register second; hook_health_success
		hook_health_register third
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	[ -f "$victim" ]
}

# ecosystem-449.8: register at a consistent point, or the durations are not
# comparable between plugins. Sourcing validate-path.sh costs ~7.4ms, so a hook
# that registers after it under-reports by that much against one that does not
# -- and the rollout compares plugins against each other and against one budget.
# With the floor now at ~3.15ms, a 7.4ms placement gap is larger than the
# instrument's own noise.
#
# hook-health.sh is self-contained and needs nothing but PLUGIN_ROOT, so it can
# always be sourced first. Anything sourced before it lands inside the window.
@test "every plugin hook registers before sourcing anything else" {
	local hooks=()
	while IFS= read -r f; do hooks+=("$f"); done \
		< <(find "${REPO_ROOT}/plugins" -path '*/scripts/hooks/*.sh' -type f | sort)
	[ "${#hooks[@]}" -gt 0 ] || return 1

	local offenders="" f reg src
	for f in "${hooks[@]}"; do
		reg=$(grep -n '^[[:space:]]*hook_health_register "' "$f" | head -1 | cut -d: -f1)
		# Completeness is a separate test; skip unwired hooks here.
		[ -n "$reg" ] || continue
		# Catches `source X`, `. X`, and `VAR=y source X`.
		src=$(grep -nE '(^|[[:space:]])(source|\.)[[:space:]]+["$/a-zA-Z]' "$f" \
			| grep -v 'hook-health.sh' | head -1 | cut -d: -f1)
		[ -n "$src" ] || continue
		if [ "$src" -lt "$reg" ]; then
			offenders+="$(basename "$f")(src@${src}<reg@${reg}) "
		fi
	done
	[ -z "$offenders" ] || { echo "registers after another source: $offenders" >&2; return 1; }
}

# ecosystem-449.66. The twin of the test above, and what keeps the completion
# contract from rotting: once a hook has registered, every path out of it must
# go through hook_health_exit, or the EXIT trap cannot tell that exit from a
# kill and records it as terminated.
#
# Scoped to lines AFTER the lib is sourced. The *_NESTED re-entry guards run
# before it and must stay a plain `exit`: hook_health_exit is not defined yet
# there, so calling it would exit 127 instead of 0, and a guard that returns
# before registering is not a measured run in the first place.
#
# Heredoc bodies are skipped — they are data a hook writes out, not code it runs.
@test "every registering hook routes its exits through hook_health_exit" {
	local hooks=()
	while IFS= read -r f; do hooks+=("$f"); done \
		< <(find "${REPO_ROOT}/plugins" -path '*/scripts/hooks/*.sh' -type f -print \
		    ; find "${REPO_ROOT}/scripts/hooks" -name '*.sh' -type f -print)
	[ "${#hooks[@]}" -gt 0 ] || return 1

	local offenders="" f src bare
	for f in "${hooks[@]}"; do
		grep -q 'hook_health_register' "$f" || continue
		src=$(grep -nE '^[[:space:]]*(source|\.)[[:space:]].*hook-health\.sh' "$f" | head -1 | cut -d: -f1)
		[ -n "$src" ] || continue

		bare=$(awk -v start="$src" '
			NR <= start { next }
			{
				line = $0
				if (inhere) { if (line ~ ("^[ \t]*" delim "[ \t]*$")) inhere = 0; next }
				if (match(line, /<<-?[ \t]*.?[A-Za-z_][A-Za-z0-9_]*/)) {
					d = substr(line, RSTART, RLENGTH)
					sub(/^<<-?[ \t]*.?/, "", d)
					delim = d; inhere = 1; next
				}
				probe = line; sub(/^[ \t]+/, "", probe)
				if (probe ~ /^#/) next
				scan = line
				gsub(/hook_health_exit/, "SAFE", scan)
				gsub(/builtin[ \t]+exit/, "SAFE", scan)
				if (scan ~ /(^|[ \t;&|(])exit([ \t]+[-$0-9]|[ \t]*$|[ \t]*[;)])/) print NR
			}' "$f")

		if [ -n "$bare" ]; then
			offenders+="$(basename "$f"):$(echo "$bare" | tr '\n' ',') "
		fi
	done
	[ -z "$offenders" ] || { echo "bare exit after registering: $offenders" >&2; return 1; }
}
