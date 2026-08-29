#!/usr/bin/env bats

# The blocking contract shared by every gate in the ecosystem.
#
# compass, warden, and hard-mode governor are the only plugins that can stop a
# tool call. They each do it by writing a JSON decision to stdout on PreToolUse
# and exiting 0. That payload shape is the entire contract — get it wrong and
# the gate degrades into a silent no-op while every plugin-level test stays
# green, because those tests only assert what the plugin writes, never that
# Claude Code honors it.
#
# This file pins the shape in one place for all three gates, and carries a
# live canary (opt-in) that verifies Claude Code still honors it.
#
# See ecosystem-449.1 and docs/superpowers/specs/2026-08-29-dogfooding-rollout-design.md.

setup() {
	# Captured before setup_test_env repoints HOME. Only the live canary uses
	# it — Claude Code reads its credentials from the real home, and under an
	# isolated one it exits "Not logged in" without ever attempting a write.
	REAL_HOME="$HOME"

	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

# The documented PreToolUse deny contract.
#
# Claude Code documents exactly one way for a PreToolUse hook to deny a tool
# call: hookSpecificOutput.permissionDecision. The legacy top-level
# {"decision":"block"} shape also blocks today but appears in no documentation,
# so it can be dropped without notice. Gates must emit the documented shape,
# and must not emit both — with two decisions present, precedence is undefined.
_assert_pretooluse_deny() {
	local payload="$1"

	printf '%s' "$payload" | jq -e '
		.hookSpecificOutput.hookEventName == "PreToolUse"
		and .hookSpecificOutput.permissionDecision == "deny"
		and (.hookSpecificOutput.permissionDecisionReason | type) == "string"
		and (.hookSpecificOutput.permissionDecisionReason | length) > 0
	' >/dev/null || return 1

	printf '%s' "$payload" | jq -e 'has("decision") | not' >/dev/null || return 1
}

# ---------------------------------------------------------------------------
# warden — blocks whenever the session's content gate is closed.
# ---------------------------------------------------------------------------
@test "warden denies with the documented permissionDecision shape" {
	local plugin_root="${REPO_ROOT}/plugins/warden"
	export CLAUDE_PLUGIN_ROOT="$plugin_root"
	# shellcheck disable=SC1091
	source "${plugin_root}/scripts/lib/warden-gate-state.sh"

	local sid="bats-gate-contract-warden"
	warden_gate_close "$sid" \
		'{"threat_id":"01TEST","source_type":"web_fetch","threat_type":"prompt_injection","confidence":0.9,"source_url":"https://evil.test"}'

	local input
	input=$(jq -cn --arg sid "$sid" --arg cwd "$BATS_TEST_TMPDIR" \
		'{session_id:$sid, cwd:$cwd, tool_name:"Write", hook_event_name:"PreToolUse"}')

	run bash -c "printf '%s' '$input' | '${plugin_root}/scripts/hooks/warden-pre-tool-use.sh'"
	[ "$status" -eq 0 ] || return 1
	_assert_pretooluse_deny "$output"
}

# ---------------------------------------------------------------------------
# compass — blocks when the evaluator panel fails to converge.
# ---------------------------------------------------------------------------
@test "compass denies with the documented permissionDecision shape" {
	local plugin_root="${REPO_ROOT}/plugins/compass"
	export CLAUDE_PLUGIN_ROOT="$plugin_root"
	# shellcheck disable=SC1091
	source "${plugin_root}/scripts/lib/compass-config.sh"
	# shellcheck disable=SC1091
	source "${plugin_root}/scripts/lib/compass-events.sh"
	# shellcheck disable=SC1091
	source "${plugin_root}/scripts/lib/compass-sanitizer.sh"
	# shellcheck disable=SC1091
	source "${plugin_root}/scripts/lib/compass-transcript.sh"
	# shellcheck disable=SC1091
	source "${plugin_root}/scripts/lib/compass-evaluator.sh"
	# shellcheck disable=SC1091
	source "${plugin_root}/scripts/lib/compass-gate.sh"

	compass_config_load ""

	local sid="bats-gate-contract-compass"
	mkdir -p "${ONLOOKER_DIR}/compass/sessions"
	cat > "${ONLOOKER_DIR}/compass/sessions/${sid}.json" <<-EOF
		{
		  "session_id": "${sid}",
		  "turn_check_count": 0,
		  "cooldown": [],
		  "circuit_breaker": {"state":"closed","consecutive_failures":0,"opened_at":null}
		}
	EOF

	# Panel disagrees and is unsure — the gate's block path.
	compass_evaluate() {
		printf '{"decision":"fail","confidence":0.21,"stddev":0.34,"primary_concern":"target","rationale":"stub","sample_count":5}'
		return 0
	}

	run compass_run_gate "Write" "/tmp/unclear.txt" "write" \
		"$(printf 'do the thing with the file we discussed %.0s' {1..5})" \
		"$sid" "" ""
	_assert_pretooluse_deny "$output"
}

# ---------------------------------------------------------------------------
# governor — blocks a subagent spawn once the ceiling is exceeded.
# ---------------------------------------------------------------------------
@test "governor denies with the documented permissionDecision shape" {
	local plugin_root="${REPO_ROOT}/plugins/governor"
	export CLAUDE_PLUGIN_ROOT="$plugin_root"

	# The gate lock lives beside the ledger. Without this directory
	# lock_acquire fails, the gate short-circuits to lock_timeout, and the
	# ceiling is never evaluated.
	mkdir -p "${ONLOOKER_DIR}/governance/ledgers"

	# A one-token budget puts any spawn past the hard-stop ceiling, which
	# blocks regardless of enforcement mode.
	export ONLOOKER_SESSION_BUDGET_TOKENS=1

	local input
	input=$(jq -cn --arg cwd "$BATS_TEST_TMPDIR" \
		'{session_id:"bats-gate-contract-governor", cwd:$cwd, tool_name:"Task",
		  hook_event_name:"PreToolUse",
		  tool_input:{description:"spawn", prompt:"do a large amount of work"}}')

	run bash -c "printf '%s' '$input' | '${plugin_root}/scripts/hooks/governor-pre-tool-use.sh'"
	[ "$status" -eq 0 ] || return 1
	_assert_pretooluse_deny "$output"
}

# ---------------------------------------------------------------------------
# Live canary — does Claude Code still honor the shape we emit?
# ---------------------------------------------------------------------------
# Every test above asserts what a gate writes. None of them proves Claude Code
# acts on it, which is the regression the plugin-level suite structurally
# cannot see. This is the automated form of the wave 0 three-arm experiment:
# register a hook that emits nothing but our deny payload, ask Claude Code to
# write a file, and check the file never appears.
#
# Opt-in: it costs a real API call and needs credentials, so CI skips it.
#   ONLOOKER_GATE_E2E=1 bats test/bats/gate-block-contract.bats
@test "Claude Code honors the deny payload end to end (live canary)" {
	[ -n "${ONLOOKER_GATE_E2E:-}" ] \
		|| skip "set ONLOOKER_GATE_E2E=1 to run the live Claude Code contract canary"
	command -v claude >/dev/null 2>&1 \
		|| skip "claude CLI not on PATH"

	local workspace="${BATS_TEST_TMPDIR}/canary"
	mkdir -p "${workspace}/.claude"

	cat > "${workspace}/deny-hook.sh" <<-HOOK
		#!/usr/bin/env bash
		# Emits nothing but the documented deny payload the gates produce.
		# The marker records that this hook is what ran, so a deny arriving
		# from somewhere else can't be mistaken for our contract holding.
		touch "${workspace}/hook-fired"
		printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Gate contract canary — this write must not land."}}'
		exit 0
	HOOK
	chmod +x "${workspace}/deny-hook.sh"

	jq -n --arg cmd "${workspace}/deny-hook.sh" '{
		hooks: {
			PreToolUse: [
				{matcher: "Write", hooks: [{type: "command", command: $cmd}]}
			]
		}
	}' > "${workspace}/.claude/settings.json"

	# cd rather than `env -C`: BSD env (macOS) has no -C, and a failed
	# invocation would leave canary.txt absent for the wrong reason, passing
	# the assertions below vacuously.
	run bash -c "cd '${workspace}' && HOME='${REAL_HOME}' claude -p \
		--settings '${workspace}/.claude/settings.json' \
		--permission-mode acceptEdits \
		'Use the Write tool to create a file named canary.txt containing the word hello. Do not use Bash.'"

	# A denied tool call is still a normal turn, so Claude Code exits 0. These
	# two assertions are what keep the test honest: without them, a CLI that
	# never ran (bad flag, no credentials) would satisfy the missing-file
	# check for a reason that has nothing to do with the gate.
	[ "$status" -eq 0 ] || return 1
	[ -f "${workspace}/hook-fired" ] || return 1

	# The control arm of this experiment — same setup with a hook that emits
	# nothing — creates the file. Its absence here is the contract holding.
	[ ! -f "${workspace}/canary.txt" ]
}
