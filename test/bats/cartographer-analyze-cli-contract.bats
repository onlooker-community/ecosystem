#!/usr/bin/env bats

# The `claude` CLI has no --max-tokens option. It rejects the flag before it
# reads stdin, writes "error: unknown option '--max-tokens'" to stderr, and
# exits 1 — verified against the installed CLI, not inferred from docs.
#
# Every `claude` stub in this suite accepted whatever flags it was handed, so
# all three of cartographer's LLM analyzers failed in milliseconds against the
# real CLI while the suite reported green. counsel (#79) and scribe both hit
# this and fixed it; cartographer kept all three call sites (ecosystem-449.63).
#
# The stub below reproduces the CLI's actual argument contract. That fidelity is
# the only thing that makes these tests worth anything: a permissive stub is
# what let the defect live.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$FIXTURE_REPO"
	# A contradiction for the relate pass, and an unresolvable path token so
	# stale_ref's bash pre-pass produces a candidate instead of short-circuiting
	# before it ever reaches the model.
	printf '# Root\nAlways use tabs.\nNever use tabs.\nSee ./docs/gone.md for details.\n' \
		> "${FIXTURE_REPO}/CLAUDE.md"
	mkdir -p "$CLAUDE_HOME"
	printf '# Global\nAlways prefer spaces.\n' > "${CLAUDE_HOME}/CLAUDE.md"

	PROJECT_FILES=$(jq -cn --arg p "${FIXTURE_REPO}/CLAUDE.md" '[$p]')
	GLOBAL_FILES=$(jq -cn --arg p "${CLAUDE_HOME}/CLAUDE.md" '[$p]')

	export CLAUDE_ARGV_LOG="${BATS_TEST_TMPDIR}/claude-argv"
	: > "$CLAUDE_ARGV_LOG"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_ARGV_LOG"
for arg in "$@"; do
	if [ "$arg" = "--max-tokens" ]; then
		printf "error: unknown option '--max-tokens'\n" >&2
		exit 1
	fi
done
cat >/dev/null
printf '%s' '[{"type":"contradiction","severity":"warning","file_a":"a","excerpt_a":"x","file_b":"b","excerpt_b":"y","description":"d","suggested_fix":"f"}]'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	source "${PLUGIN_ROOT}/scripts/lib/cartographer-analyze.sh"
}

@test "contradiction analysis survives the CLI's real argument contract" {
	run cartographer_analyze_contradiction "$PROJECT_FILES" "claude-haiku-4-5-20251001" 2048 10
	[ "$status" -eq 0 ] || return 1
	[ "$output" != "[]" ] || return 1
	[[ "$output" == *'"type": "contradiction"'* || "$output" == *'"type":"contradiction"'* ]]
}

@test "stale_ref analysis survives the CLI's real argument contract" {
	run cartographer_analyze_stale_ref "$PROJECT_FILES" "$FIXTURE_REPO" "claude-haiku-4-5-20251001" 2048 10
	[ "$status" -eq 0 ] || return 1
	[ "$output" != "[]" ]
}

@test "scope_collision analysis survives the CLI's real argument contract" {
	run cartographer_analyze_scope_collision "$GLOBAL_FILES" "$PROJECT_FILES" "claude-haiku-4-5-20251001" 2048 10
	[ "$status" -eq 0 ] || return 1
	[ "$output" != "[]" ]
}

@test "no analyzer passes --max-tokens to the CLI" {
	cartographer_analyze_contradiction "$PROJECT_FILES" "m" 2048 10 >/dev/null
	cartographer_analyze_stale_ref "$PROJECT_FILES" "$FIXTURE_REPO" "m" 2048 10 >/dev/null
	cartographer_analyze_scope_collision "$GLOBAL_FILES" "$PROJECT_FILES" "m" 2048 10 >/dev/null
	# Vacuous-pass guard: prove the analyzers actually reached the CLI before
	# concluding they reached it without the flag.
	[ -s "$CLAUDE_ARGV_LOG" ] || return 1
	[ "$(grep -c -- '-p' "$CLAUDE_ARGV_LOG")" -eq 3 ] || return 1
	! grep -q -- '--max-tokens' "$CLAUDE_ARGV_LOG"
}

# The flag bug survived because a hard CLI failure and a quiet "no findings"
# looked identical from the outside: stderr went to /dev/null, so audit.log
# recorded "phase=relate timeout or error" and never the reason. Same fix scribe
# made — keep the stderr, surface it only when the call actually failed.

@test "a CLI failure reports the reason instead of swallowing it" {
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf "error: unknown option '--some-future-flag'\n" >&2
exit 1
STUB
	chmod +x "${STUB_BIN}/claude"

	run cartographer_analyze_contradiction "$PROJECT_FILES" "m" 2048 10
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"--some-future-flag"* ]]
}

@test "CLI chatter on a successful call is not propagated" {
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'NOISY-DEPRECATION-WARNING\n' >&2
printf '%s' '[]'
STUB
	chmod +x "${STUB_BIN}/claude"

	run cartographer_analyze_contradiction "$PROJECT_FILES" "m" 2048 10
	[ "$status" -eq 0 ] || return 1
	[[ "$output" != *"NOISY-DEPRECATION-WARNING"* ]]
}

# `claude -p` without --max-turns may run a multi-turn agentic loop with tools.
# An auditor has no business doing that: it is a read-only reviewer, and the cap
# is what keeps one analyzer pass from turning into an open-ended session.
# counsel and scribe both pass it; cartographer never did.
#
# It is not a speed fix. Measured against this repo's CLAUDE.md (17.5KB) with the
# real analyzer prompt: 146s uncapped, 143s capped. The phase budget, not the
# turn count, is what these calls actually exceed (ecosystem-449.64).
@test "analyzers cap the CLI at a single turn" {
	cartographer_analyze_contradiction "$PROJECT_FILES" "m" 2048 10 >/dev/null
	[ -s "$CLAUDE_ARGV_LOG" ] || return 1
	grep -q -- '--max-turns 1' "$CLAUDE_ARGV_LOG"
}

# `(( x++ ))` evaluates to the PRE-increment value, so the first iteration with
# x=0 makes the arithmetic command return exit status 1. Under errexit bash 4+
# aborts on it; bash 3.2 does not. bats resolves `#!/usr/bin/env bash`, which is
# 3.2 on macOS and 5.x on CI, so this is invisible locally and fatal in CI.
#
# run-audit.sh already guards all five of its increments with `|| true`, and the
# plugin's own SKILL.md documents that idiom -- cartographer-analyze.sh:145 was
# the one instance that missed it, unreached until a caller ran under errexit.
_modern_bash() {
	local b major
	for b in /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
		[ -x "$b" ] || continue
		major=$("$b" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null) || continue
		if [ "${major:-0}" -ge 4 ]; then printf '%s' "$b"; return 0; fi
	done
	return 1
}

@test "analyzers survive being called under errexit on bash 4+" {
	local sh
	sh=$(_modern_bash) || skip "no bash >= 4 on this host"
	run "$sh" -c '
		set -e
		source "$1"
		cartographer_analyze_stale_ref "$2" "$3" m 2048 10 >/dev/null
		cartographer_analyze_contradiction "$2" m 2048 10 >/dev/null
	' _ "${PLUGIN_ROOT}/scripts/lib/cartographer-analyze.sh" "$PROJECT_FILES" "$FIXTURE_REPO"
	[ "$status" -eq 0 ]
}
