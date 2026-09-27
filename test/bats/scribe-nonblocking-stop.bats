#!/usr/bin/env bats
#
# scribe's Stop hook must not block the turn on the Haiku distillation pass.
#
# ONL-41. scribe-stop.sh states its own contract in its header — "Always exits
# 0. Never blocks Stop." — and then called scribe_distill inline, which runs a
# `claude -p` pass over the whole transcript under a 60s timeout. Measured in
# one session on 2026-09-26: Stop fired five times and distillation ran on
# three of them, at 53.6s, 40.9s and 45.1s. Median Stop cost for that session
# was 40.9s. The other three Stop hooks were 95-253ms throughout, so scribe
# accounted for essentially all of it.
#
# TWO DIFFERENT FAULTS WEAR THE SAME BEAD, and only the second is left. The
# 751ms-6.3s the bead was filed for was jq-per-line turn counting, already
# fixed by the streaming pass (see scribe-extract.sh:58) — ecosystem-449.43
# read that as the LLM path and it never was. What remains IS the LLM path, and
# it only shows up on the ~4% of fires that get past min_turns, which is why a
# pooled p50 of 65ms hides it completely. Measure per session, not pooled.
#
# Detaching it needs a lock, which inline execution made unnecessary: Stop
# fires once per TURN, so with a 40-54s pass and turns closer together than
# that, two distillations would otherwise run at once and write the same
# <date>-<session>.md. Same hazard assayer documents in
# assayer-nonblocking-stop.bats, handled the way cartographer handles its audit.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/scribe"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/scribe-stop.sh"

	# min_turns defaults to 3, and scribe_count_turns counts only user entries
	# whose message.content is a STRING. A fixture that missed that would skip
	# distillation entirely and pass every test below for the wrong reason.
	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	_append_user_turn "why is the gate failing"
	_append_user_turn "try it on the other branch"
	_append_user_turn "now write that up"

	CLAUDE_CALLED="${BATS_TEST_TMPDIR}/claude_called"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	_install_claude_stub 5 0
	export PATH="${STUB_BIN}:${PATH}"

	DISTILL_LOG="${ONLOOKER_DIR}/scribe/distill.log"
}

# The whole point of the change is that the pass outlives the hook — which means
# it also outlives the test. Left alone, its mkdir races bats removing the tree
# underneath it and cleanup fails with "rm: Permission denied". Waiting for the
# lock to clear is waiting for the pass to finish, since run-distill.sh releases
# it on exit.
teardown() {
	local waited=0
	while [[ "$waited" -lt 25 ]]; do
		if [[ "$waited" -ge 2 ]] &&
			! compgen -G "${ONLOOKER_DIR}"/scribe/sessions/*.distill.lock.d >/dev/null 2>&1; then
			break
		fi
		sleep 1
		waited=$((waited + 1))
	done
}

# sleep_s controls how long the pass takes; exit_rc lets a test drive the
# failure path, which is the one whose diagnostics went missing before.
_install_claude_stub() {
	local sleep_s="${1:-5}" exit_rc="${2:-0}"
	cat >"${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
printf 'x\n' >> "${CLAUDE_CALLED}"
sleep ${sleep_s}
if [[ ${exit_rc} -ne 0 ]]; then
	printf 'stub-claude: deliberate failure for the stderr test\n' >&2
	exit ${exit_rc}
fi
printf '%s' '{"summary":"s","problem":"p","decisions":[],"tradeoffs":[],"constraints":[],"out_of_scope":[]}'
STUB
	chmod +x "${STUB_BIN}/claude"
}

_append_user_turn() {
	jq -cn --arg t "$1" '{type:"user", message:{content:$t}}' >>"$TRANSCRIPT"
}

_run_hook() {
	jq -cn --arg cwd "$BATS_TEST_TMPDIR" --arg sid "${1:-sess-nb}" --arg tp "$TRANSCRIPT" \
		'{cwd:$cwd, session_id:$sid, transcript_path:$tp, hook_event_name:"Stop"}' | "$HOOK" 2>/dev/null
}

_wait_for_claude() {
	local waited=0
	while [[ ! -s "$CLAUDE_CALLED" && "$waited" -lt 20 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
}

# THE regression test. The stub sleeps 5s, so the inline implementation takes
# ~5s here; the bound is 3s, which fails loudly against it while staying clear
# of CI jitter on the detached path, which spawns and returns.
@test "Stop returns without waiting for the distillation pass" {
	local start end
	start=$(date +%s)
	_run_hook >/dev/null
	end=$(date +%s)
	[ "$((end - start))" -lt 3 ]
}

@test "Stop stays silent on stdout while distillation runs detached" {
	local out
	out=$(_run_hook)
	[ -z "$out" ]
}

# Deferral must not mean cancellation — the whole point is that the artifact
# still gets written, just not on the turn's clock.
@test "the distillation still runs after the hook returns" {
	_run_hook >/dev/null
	_wait_for_claude
	[ -s "$CLAUDE_CALLED" ] || {
		echo "distillation never ran"
		return 1
	}
}

# Inline execution serialized this for free. Detached, Stop fires again on the
# next turn while the first pass is still running, and both would write the
# same <date>-<session>.md and bill a second Haiku pass for it.
@test "a second Stop declines while a distillation is already running" {
	_run_hook sess-lock >/dev/null
	_wait_for_claude
	_run_hook sess-lock >/dev/null
	# Give a second launcher time to reach the stub if it was going to.
	sleep 2
	local calls
	calls=$(wc -l <"$CLAUDE_CALLED" | tr -d '[:space:]')
	[ "$calls" -eq 1 ] || {
		echo "expected 1 distillation, got ${calls}"
		return 1
	}
}

# scribe threw away the CLI's stderr once already and the flag bug that caused
# survived 13,201 sessions with zero events (ONL-30). Detaching must not
# recreate that: a pass that fails after the hook has returned is invisible
# unless its stderr lands somewhere on disk.
@test "a failing detached pass leaves its stderr on disk" {
	_install_claude_stub 0 1
	_run_hook sess-err >/dev/null
	local waited=0
	while [[ ! -s "$DISTILL_LOG" && "$waited" -lt 15 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
	[ -s "$DISTILL_LOG" ] || {
		echo "no distill log at ${DISTILL_LOG}"
		return 1
	}
}
