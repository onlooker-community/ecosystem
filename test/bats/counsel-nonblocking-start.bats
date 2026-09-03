#!/usr/bin/env bats
#
# counsel's SessionStart hook must never block on synthesis.
#
# ecosystem-449.19. counsel_generate_brief was called synchronously from the
# hook, and its evaluator ships timeout: 90. The synthesis_interval_days gate
# limits how OFTEN that happens, not how LONG it takes — so roughly once a week
# a session start blocked on an LLM call with a 90-second ceiling. librarian
# already had an explicit budget check for the 1.5s SessionEnd cap
# (librarian-session-end.sh:181-201); counsel had nothing.
#
# The brief is weekly, so deferring it one session costs nothing: synthesis is
# spawned detached and the result is injected at the NEXT session start.
#
# The wall-clock assertion is the load-bearing one. Every other test here
# passes against the blocking implementation too — it produced the right brief,
# it just took 90 seconds to do it.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	# load_validate_path, not setup_test_env: this hook reads the event bus, so
	# $ONLOOKER_EVENTS_LOG has to be resolved and its directory created. It also
	# repoints CLAUDE_PLUGIN_ROOT at the repo root, so set the plugin root after.
	load_validate_path

	PLUGIN_ROOT="${REPO_ROOT}/plugins/counsel"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/counsel-session-start.sh"

	WORK="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$WORK"
	git -C "$WORK" init -q
	git -C "$WORK" config user.email test@example.com
	git -C "$WORK" config user.name test

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/counsel-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/counsel-project-key.sh"
	counsel_config_load "$WORK"
	PROJECT_KEY=$(counsel_project_key "$WORK")
	BRIEFS_DIR=$(counsel_project_dir "$PROJECT_KEY")

	# A slow claude stub. If the hook waits for synthesis, it waits 5s.
	CLAUDE_CALLED="${BATS_TEST_TMPDIR}/claude_called"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
printf 'x\n' >> "${CLAUDE_CALLED}"
sleep 5
cat <<'JSON'
{"summary":"SYNTH_MARKER","patterns":[],"recommendations":[],"wins":[],"watch":[]}
JSON
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	# Enough events on the bus to clear capture.min_events.
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	local i
	for i in $(seq 1 40); do
		jq -cn --arg i "$i" '{event_type:"tool.file.edit", timestamp:(now|todate),
			session_id:"s", plugin:"ecosystem", payload:{n:$i}}' >> "$ONLOOKER_EVENTS_LOG"
	done
}

_input() {
	jq -cn --arg cwd "$WORK" --arg sid "${1:-sess-1}" \
		'{cwd:$cwd, session_id:$sid, hook_event_name:"SessionStart"}'
}

_run_hook() { printf '%s' "$(_input "${1:-sess-1}")" | "$HOOK" 2>/dev/null; }

_seed_brief() {
	mkdir -p "$BRIEFS_DIR"
	printf '# Weekly brief\n\nBRIEF_MARKER body text.\n' > "${BRIEFS_DIR}/${1:-2026-01}.md"
}

# THE regression test. Against the blocking implementation this takes ~5s
# because the stub sleeps; the bound is 3s so it fails loudly there while
# staying clear of CI jitter on the non-blocking path (which does no LLM work
# at all and returns in well under a second).
@test "SessionStart returns without waiting for synthesis" {
	local start end
	start=$(date +%s)
	_run_hook >/dev/null
	end=$(date +%s)
	[ "$((end - start))" -lt 3 ]
}

@test "SessionStart still emits well-formed hook JSON while refreshing" {
	local out
	out=$(_run_hook)
	printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
}

# Deferral must not mean cancellation: a stale brief has to actually get
# refreshed, just not on this session's clock. Bounded poll rather than a fixed
# sleep, so a fast machine does not wait and a slow one does not flake.
@test "a stale brief is refreshed in the background, not skipped" {
	_run_hook >/dev/null
	local waited=0
	while [[ ! -s "$CLAUDE_CALLED" && "$waited" -lt 15 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
	[ -s "$CLAUDE_CALLED" ] || { echo "synthesis never ran (waited ${waited}s)"; return 1; }
}

@test "an existing brief is injected as additionalContext" {
	_seed_brief
	local out
	out=$(_run_hook)
	printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'BRIEF_MARKER'
}

# The brief is a weekly digest, not a banner. Injecting it on every session
# until it ages out would put it in front of the user seven times.
@test "a brief is injected once, not on every subsequent session" {
	_seed_brief
	_run_hook sess-1 >/dev/null
	local out
	out=$(_run_hook sess-2)
	local ctx
	ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
	[[ "$ctx" != *BRIEF_MARKER* ]] || { echo "re-injected on the second session"; return 1; }
	true
}

# Several sessions can start at once (a worktree sweep, a restart). Each one
# seeing a stale brief must not spawn its own synthesis.
@test "concurrent session starts do not each spawn a synthesis" {
	_run_hook a >/dev/null
	_run_hook b >/dev/null
	_run_hook c >/dev/null
	local waited=0
	while [[ ! -s "$CLAUDE_CALLED" && "$waited" -lt 15 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
	local calls
	calls=$(wc -l < "$CLAUDE_CALLED" 2>/dev/null | tr -d ' ')
	[ "${calls:-0}" -le 1 ] || { echo "spawned ${calls} syntheses for 3 session starts"; return 1; }
}
