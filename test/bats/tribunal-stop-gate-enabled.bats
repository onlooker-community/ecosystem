#!/usr/bin/env bats

# The Stop gate's off switch, and how it reports a judge that never answered
# (ecosystem-449.32).
#
# tribunal-stop-hook.bats already has a case named "hook exits 0 silently when
# stop_hook.enabled is false (default)". It passes, and it always did — because
# `claude` is not on PATH in the test environment, so the gate bails at the
# command -v check regardless of config. It asserted the off switch worked
# without ever exercising it.
#
# Every case here puts a `claude` stub ON PATH that records its invocation, so
# "the gate did not run a model" is a claim the test can actually falsify.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/tribunal-stop-gate.sh"
	export ONLOOKER_HOOK_HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_HOOK_HEALTH_LOG")"
	# Exported the way tribunal-events.bats does. setup_test_env alone does not
	# set it — validate-path.sh is what normally exports it, and this file does
	# not load it — so every assertion against the bus would otherwise read an
	# empty path and fail for a reason unrelated to the gate.
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	(cd "$REPO" && printf 'initial\n' > README.md && git add README.md && git commit -q -m init)
	# Dirty the tree so skip_if_no_file_changes cannot be what stops the gate.
	printf 'uncommitted\n' >> "${REPO}/README.md"

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	printf '{"role":"user","content":"hi"}\n' > "$TRANSCRIPT"

	# The stub records that a model was invoked. Its presence is the assertion.
	CLAUDE_MARKER="${BATS_TEST_TMPDIR}/claude-was-invoked"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
printf 'invoked\n' >> "${CLAUDE_MARKER}"
printf '%s' '{"score":0.9,"passed":true,"judge_type":"standard","feedback_summary":"ok","confidence":0.9}'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_settings() {
	mkdir -p "${REPO}/.claude"
	printf '%s\n' "$1" > "${REPO}/.claude/settings.json"
}

_run_hook() {
	local input
	input=$(jq -n --arg cwd "$REPO" --arg tp "$TRANSCRIPT" --arg sid "sess-stop-1" \
		'{cwd: $cwd, transcript_path: $tp, session_id: $sid, hook_event_name: "Stop"}')
	run bash -c "printf '%s' '$input' | '$HOOK'"
}

@test "stop_hook.enabled false runs no model, even with claude on PATH" {
	_settings '{"tribunal":{"stop_hook":{"enabled":false,"skip_if_no_file_changes":false}}}'
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$CLAUDE_MARKER" ]
}

@test "an absent stop_hook.enabled runs no model (off by default)" {
	# The documented default. Nothing in config says enabled, so nothing runs.
	_settings '{"tribunal":{"stop_hook":{"skip_if_no_file_changes":false}}}'
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$CLAUDE_MARKER" ]
}

@test "stop_hook.enabled true does run the model" {
	# The other half of the switch: proving the false cases above are the config
	# taking effect, not the gate being inert for some unrelated reason.
	_settings '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}'
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[ -f "$CLAUDE_MARKER" ]
}

@test "a judge that times out is not recorded as a successful run" {
	# `timeout 60 claude ... || RESPONSE=""` collapses a timeout into the same
	# empty-response path as a judge that answered with nothing, and the hook
	# then exits 0 — so hook-health logs success and the 60s spend is invisible.
	_settings '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}'
	cat > "${STUB_BIN}/timeout" <<'STUB'
#!/usr/bin/env bash
exit 124
STUB
	chmod +x "${STUB_BIN}/timeout"
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[ -f "$ONLOOKER_HOOK_HEALTH_LOG" ] || return 1
	run jq -rs '[.[] | select(.hook == "tribunal-stop-gate") | .status] | join(",")' "$ONLOOKER_HOOK_HEALTH_LOG"
	[[ "$output" != *"success"* ]]
}

# --- the gate now says why it judged nothing (ONL-172) ----------------------
#
# The cases above prove the off switch stops the model. They cannot prove the
# BUS learns anything, and it did not: check-plugin-liveness read tribunal as a
# broken emitter across 3398 hook runs while stop_hook.enabled was false,
# because the absence of gate.passed/blocked cannot tell a disabled gate from a
# broken one. Widening its window did not clarify that — it reported the plugin
# `live` on 1076 events that all predated the off-switch, so no window read it
# correctly.

_skip_reasons() {
	[ -f "$ONLOOKER_EVENTS_LOG" ] || return 1
	jq -rs '[.[] | select(.event_type == "tribunal.gate.skipped") | .payload.reason] | join(",")' \
		"$ONLOOKER_EVENTS_LOG"
}

@test "a disabled gate reports why instead of saying nothing" {
	_settings '{"tribunal":{"stop_hook":{"enabled":false,"skip_if_no_file_changes":false}}}'
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$CLAUDE_MARKER" ] || return 1
	run _skip_reasons
	[ "$output" = "disabled" ]
}

@test "the skipped event is a schema-valid envelope" {
	# tribunal.gate.skipped landed in @onlooker-community/schema 3.1.0. Before
	# that release the emitter would have rejected it under ONLOOKER_VALIDATE=1
	# and the line would never reach the log at all.
	_settings '{"tribunal":{"stop_hook":{"enabled":false,"skip_if_no_file_changes":false}}}'
	_run_hook
	[ "$status" -eq 0 ] || return 1
	run bash -c "tail -n 1 '$ONLOOKER_EVENTS_LOG' | ONLOOKER_DIR='$ONLOOKER_DIR' node '${REPO_ROOT}/scripts/lib/onlooker-event.mjs' validate"
	[ "$status" -eq 0 ]
}

@test "a clean tree reports no_file_changes, not silence" {
	# The highest-volume skip on a real machine, and the one most likely to be
	# mistaken for a dead plugin.
	_settings '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":true}}}'
	git -C "$REPO" checkout -- README.md
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$CLAUDE_MARKER" ] || return 1
	run _skip_reasons
	[ "$output" = "no_file_changes" ]
}

@test "a missing transcript reports no_transcript" {
	_settings '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}'
	rm -f "$TRANSCRIPT"
	_run_hook
	[ "$status" -eq 0 ] || return 1
	run _skip_reasons
	[ "$output" = "no_transcript" ]
}

@test "a judge timeout reports judge_timeout, where a model call was spent" {
	# One of the four post-dispatch reasons. These are the shapes where a Stop
	# paid for a judge and got no verdict, which is what made the spend
	# invisible in ecosystem-449.32 — reported on the bus now, not just in
	# hook-health.
	_settings '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}'
	cat > "${STUB_BIN}/timeout" <<'STUB'
#!/usr/bin/env bash
exit 124
STUB
	chmod +x "${STUB_BIN}/timeout"
	_run_hook
	[ "$status" -eq 0 ] || return 1
	run _skip_reasons
	[ "$output" = "judge_timeout" ]
}

@test "a judge answering unparseable JSON reports judge_unparseable" {
	_settings '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}'
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
printf 'invoked\n' >> "${CLAUDE_MARKER}"
printf '%s' 'I have thoughts but no verdict object.'
STUB
	chmod +x "${STUB_BIN}/claude"
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[ -f "$CLAUDE_MARKER" ] || return 1
	run _skip_reasons
	[ "$output" = "judge_unparseable" ]
}

@test "a gate that actually judges emits no skip" {
	# The success path must not claim a skip. _done takes its reason as an
	# optional argument precisely so the last caller, after the full chain is
	# emitted, stays silent.
	_settings '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}'
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[ -f "$CLAUDE_MARKER" ] || return 1
	run _skip_reasons
	[ "$output" = "" ] || return 1
	grep -q '"event_type":"tribunal.gate.passed"' "$ONLOOKER_EVENTS_LOG"
}

@test "the skip carries no task_id, which the schema refuses" {
	# gate.passed and gate.blocked both require one. A skipped gate never minted
	# a task, and a payload claiming otherwise would not validate — so if this
	# ever regresses, the event stops appearing rather than appearing wrong.
	_settings '{"tribunal":{"stop_hook":{"enabled":false,"skip_if_no_file_changes":false}}}'
	_run_hook
	[ "$status" -eq 0 ] || return 1
	run jq -rs '[.[] | select(.event_type == "tribunal.gate.skipped") | (.payload | keys | join("+"))] | join(",")' "$ONLOOKER_EVENTS_LOG"
	[ "$output" = "reason" ]
}
