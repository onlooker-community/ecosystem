#!/usr/bin/env bats
#
# assayer's Stop hook must never block the turn on claim extraction.
#
# ecosystem-449.24. assayer-stop.sh called `timeout 60 claude -p` inline on
# every Stop. Measured on the bus over 09-03..09-04: p50 10562ms, p95 53328ms,
# max 62766ms — 58% of all hook time across every plugin. One 77-turn session
# spent 1004.9s of its 1737.3s total hook time here.
#
# Same shape as counsel's ecosystem-449.19, with one difference that drives the
# whole design: counsel synthesizes from the append-only event log, which is
# safe to re-read later. assayer reads transcript_path, which KEEPS GROWING. A
# detached child that re-read it would audit a later turn's final message and
# silently attribute one turn's claims to another. So the parent snapshots the
# inputs (measured at 135ms) and the child works from the frozen copy.
#
# "audits the snapshot, not a later turn" is the test that pins that down; the
# wall-clock test is the one that fails loudly against the blocking version.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	load_validate_path

	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/assayer-stop.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	(cd "$REPO" && printf 'initial\n' >README.md && git add README.md && git commit -q -m init)

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-project-key.sh"
	PROJECT_KEY=$(assayer_project_key "$REPO")
	ASSAYER_DIR="${ONLOOKER_DIR}/assayer/${PROJECT_KEY}"

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	_append_turn "All tests pass."

	# The stub records the prompt it was handed, then sleeps. If the hook waits
	# for extraction, it waits 5 seconds.
	SEEN_PROMPT="${BATS_TEST_TMPDIR}/seen_prompt"
	CLAUDE_CALLED="${BATS_TEST_TMPDIR}/claude_called"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat > "${SEEN_PROMPT}"
printf 'x\n' >> "${CLAUDE_CALLED}"
sleep 5
printf '%s' '[{"text":"All tests pass.","type":"tests_pass","command_keyword":"test","confidence":0.9}]'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_append_turn() {
	jq -cn --arg t "$1" \
		'{type:"assistant", message:{content:[{type:"text", text:$t}]}}' >>"$TRANSCRIPT"
}

_run_hook() {
	jq -cn --arg cwd "$REPO" --arg sid "${1:-sess-nb}" --arg tp "$TRANSCRIPT" \
		'{cwd:$cwd, session_id:$sid, transcript_path:$tp}' | "$HOOK" 2>/dev/null
}

_wait_for_claude() {
	local waited=0
	while [[ ! -s "$CLAUDE_CALLED" && "$waited" -lt 20 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
}

# THE regression test. The stub sleeps 5s, so the blocking implementation takes
# ~5s here; the bound is 3s, which fails loudly there while staying clear of CI
# jitter on the non-blocking path (which spawns and returns).
@test "Stop returns without waiting for claim extraction" {
	local start end
	start=$(date +%s)
	_run_hook >/dev/null
	end=$(date +%s)
	[ "$((end - start))" -lt 3 ]
}

@test "Stop stays silent on stdout while the audit runs detached" {
	local out
	out=$(_run_hook)
	[ -z "$out" ]
}

# Deferral must not mean cancellation.
@test "the extraction still runs in the background" {
	_run_hook >/dev/null
	_wait_for_claude
	[ -s "$CLAUDE_CALLED" ] || { echo "extraction never ran"; return 1; }
}

# The correctness test that counsel did not need. The transcript grows after the
# hook returns; the detached child must audit the message the turn actually
# ended on, not whatever landed later.
@test "the audit reads the snapshot, not a later turn" {
	_run_hook >/dev/null
	_append_turn "The build is green and lint is clean."
	_wait_for_claude
	grep -q 'All tests pass' "$SEEN_PROMPT" || { echo "snapshot missing original message"; return 1; }
	grep -q 'build is green' "$SEEN_PROMPT" && { echo "child re-read the transcript and picked up a later turn"; return 1; }
	true
}
