#!/usr/bin/env bats
#
# Every audit in a session must survive, not just the last one.
#
# ecosystem-449.25. The advisory file was written to audit-<session_id>.json,
# but the Stop hook fires once per TURN, so each turn overwrote the previous
# turn's audit. Session 8d59b376 ran 77 audits over 25.4 hours and left one
# file, holding the final turn's result: claim_count 0, nothing_to_verify.
# 76 audits discarded, and the survivor empty.
#
# The assayer.* events on the bus were never affected — they carry audit_id and
# the log is append-only. This is only the on-disk file.

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

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '[{"text":"All tests pass.","type":"tests_pass","command_keyword":"test","confidence":0.9}]'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

# One turn: its own transcript, so turn 2 does not simply inherit turn 1's text.
_run_turn() {
	local text="$1" sid="${2:-sess-retention}"
	local t="${BATS_TEST_TMPDIR}/t-${RANDOM}.jsonl"
	jq -cn --arg x "$text" \
		'{type:"assistant", message:{content:[{type:"text", text:$x}]}}' >"$t"
	jq -cn --arg cwd "$REPO" --arg sid "$sid" --arg tp "$t" \
		'{cwd:$cwd, session_id:$sid, transcript_path:$tp}' | "$HOOK" >/dev/null 2>&1
}

_count_audits() { find "$ASSAYER_DIR" -name 'audit-*.json' 2>/dev/null | wc -l | tr -d ' '; }

_wait_for_audits() {
	local want="$1" waited=0
	while [[ "$(_count_audits)" -lt "$want" && "$waited" -lt 20 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
}

@test "two audits in one session both survive on disk" {
	_run_turn "All tests pass."
	_run_turn "The build succeeded and lint is clean."
	_wait_for_audits 2
	local n
	n=$(_count_audits)
	[ "$n" -eq 2 ] || { echo "expected 2 audit files, found ${n} (turn 2 overwrote turn 1)"; return 1; }
}

@test "each audit file is named for the audit it holds" {
	_run_turn "All tests pass."
	_wait_for_audits 1
	local f audit_id
	f=$(find "$ASSAYER_DIR" -name 'audit-*.json' | head -1)
	audit_id=$(jq -r '.audit_id' "$f")
	[[ "$(basename "$f")" == *"${audit_id}"* ]] || {
		echo "filename $(basename "$f") does not carry audit_id ${audit_id}"
		return 1
	}
}
