#!/usr/bin/env bats
# SessionStart surfacer for stale plugin pins (ecosystem-449.59).
#
# The age rule is the thing under test: an expired cache must never produce a
# claim of currency. Everything else is plumbing around that.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	load_validate_path
	export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
	HOOK="${REPO_ROOT}/scripts/hooks/plugin-currency-surfacer.sh"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git

	source "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh"
	source "${REPO_ROOT}/scripts/lib/plugin-currency-cache.sh"
	CACHE=$(plugin_currency_cache_path "$(onlooker_project_key "$PROJECT_REPO")")
}

_input() {
	jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-currency" \
		'{cwd: $cwd, session_id: $sid, hook_event_name: "SessionStart", source: "startup"}'
}

_run_hook() {
	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
}

_seed_now() {
	mkdir -p "$(dirname "$CACHE")"
	jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson f "$1" \
		'{checked_at: $t, findings: $f}' >"$CACHE"
}

_seed_aged() {
	mkdir -p "$(dirname "$CACHE")"
	jq -n --arg t "$(relative_iso_days_ago "$1")" --argjson f "$2" \
		'{checked_at: $t, findings: $f}' >"$CACHE"
}

_disable() {
	mkdir -p "${PROJECT_REPO}/.claude"
	jq -n '{plugin_currency: {enabled: false}}' >"${PROJECT_REPO}/.claude/settings.json"
}

_context() {
	printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

_break_node() {
	STUB_BIN="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$STUB_BIN"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_BIN}/node"
	chmod +x "${STUB_BIN}/node"
	printf '%s' "$STUB_BIN"
}

@test "always exits 0" {
	_seed_now '[]'
	_run_hook
	[ "$status" -eq 0 ]
}

@test "emits a valid SessionStart envelope even with nothing to say" {
	_seed_now '[]'
	_run_hook
	printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
}

@test "disabled is a clean no-op that still names itself" {
	_disable
	_run_hook
	[ "$status" -eq 0 ] || return 1
	grep '"event_type":"onlooker.currency.skipped"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.skip_reason == "disabled"' >/dev/null
}

@test "a fresh cache is read without re-probing" {
	_seed_now '[]'
	_run_hook
	grep '"event_type":"onlooker.currency.skipped"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.skip_reason == "cache_fresh"' >/dev/null || return 1
	! grep -q '"event_type":"onlooker.currency.checked"' "$ONLOOKER_EVENTS_LOG" || return 1
}

@test "surfaces nothing when the fresh cache is clean" {
	_seed_now '[]'
	_run_hook
	[ -z "$(_context)" ]
}

@test "a fresh cache with findings surfaces and carries its answer age" {
	_seed_now '[{"reason":"clone_behind","subject":"onlooker-community","effective":"6caacd39","available":"ff773b41"}]'
	_run_hook
	grep '"event_type":"onlooker.currency.stale"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.findings_count == 1 and .payload.answer_age_seconds >= 0' >/dev/null || return 1
	[ -n "$(_context)" ]
}

# THE AGE RULE. When freshness cannot be established, never claim currency.
# An expired cache alone does not trigger this: the hook re-probes, and a
# successful probe legitimately establishes the answer. The rule binds when the
# probe ALSO cannot run -- that is the state where a lesser implementation would
# fall back to the stale cache and report it as current.
@test "an expired cache with no way to probe says unchecked, never current" {
	_seed_aged 1 '[]'
	local stub; stub=$(_break_node)
	run bash -c "printf '%s' '$(_input)' | PATH='${stub}:$PATH' '$HOOK'"
	! _context | grep -qi 'current' || return 1
	_context | grep -qi 'unchecked'
}

@test "an expired cache that re-probes clean is silent rather than reassuring" {
	# surface_when_current defaults false, so a genuinely current result says
	# nothing at all. Silence here is a positive result, not a failure to speak.
	_seed_aged 1 '[]'
	_run_hook
	[ -z "$(_context)" ] || return 1
	grep -q '"event_type":"onlooker.currency.checked"' "$ONLOOKER_EVENTS_LOG"
}

@test "an expired cache reports unchecked rather than replaying old findings as fresh" {
	_seed_aged 1 '[{"reason":"clone_behind","subject":"onlooker-community"}]'
	_run_hook
	! _context | grep -qi 'current' || return 1
	! grep -q '"skip_reason":"cache_fresh"' "$ONLOOKER_EVENTS_LOG" || return 1
	[ "$status" -eq 0 ]
}

@test "a failed probe leaves the previous checked_at untouched" {
	_seed_aged 1 '[]'
	local before; before=$(jq -r '.checked_at' "$CACHE")
	# Shadow only `node`, so the probe fails while jq stays available and the
	# hook actually reaches the failure branch.
	local stub; stub=$(_break_node)
	run bash -c "printf '%s' '$(_input)' | PATH='${stub}:$PATH' '$HOOK'"
	local after; after=$(jq -r '.checked_at' "$CACHE")
	[ "$before" = "$after" ] || return 1
	[ "$status" -eq 0 ]
}

@test "no git context is named rather than silently skipped" {
	local plain="${BATS_TEST_TMPDIR}/plain"
	mkdir -p "$plain"
	run bash -c "printf '%s' '$(jq -cn --arg cwd "$plain" '{cwd: $cwd, session_id: "s", hook_event_name: "SessionStart"}')' | '$HOOK'"
	[ "$status" -eq 0 ] || return 1
	grep '"event_type":"onlooker.currency.skipped"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.skip_reason == "no_git_context"' >/dev/null
}

# CLAUDE.md's warning is that a hook which skips hook_health_register is
# invisible to latency measurement silently, with no error and no test failure.
# test/bats/hook-health.bats enforces this, but only globs
# plugins/*/scripts/hooks/*.sh -- substrate hooks in scripts/hooks/ fall outside
# it, so this hook asserts its own record rather than assuming one.
@test "reports itself to hook-health" {
	_seed_now '[]'
	_run_hook
	local log; log="${ONLOOKER_DIR}/logs/hook-health.jsonl"
	[ -f "$log" ] || return 1
	grep -q '"plugin-currency-surfacer"' "$log"
}

@test "the hook-health record carries the session context" {
	_seed_now '[]'
	_run_hook
	local log; log="${ONLOOKER_DIR}/logs/hook-health.jsonl"
	grep '"plugin-currency-surfacer"' "$log" \
		| jq -e 'select(.session_id == "sess-currency") | .hook_event == "SessionStart"' >/dev/null
}
