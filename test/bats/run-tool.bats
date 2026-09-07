#!/usr/bin/env bats

# scripts/lint/run-tool.sh — resolve a mise-managed tool without depending on
# the caller's PATH.
#
# ecosystem-7jl. inspector's checks run from a hook, and a hook inherits
# whatever environment the session was launched with. `mise activate` builds its
# PATH from the shell profile, so a session that did not come from an
# interactive shell cannot see shellcheck or biome: the check exits 127,
# inspector records tool_missing, and the repo's main gate is silently absent.
# Measured at 68 skipped against 23 run, split per session — three sessions
# never found the tool, one always did.

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	RUN_TOOL="${REPO_ROOT}/scripts/lint/run-tool.sh"

	# A tool that exists only under a fake mise data dir, so the shim rung is
	# exercised without depending on what this machine happens to have installed.
	export MISE_DATA_DIR="${BATS_TEST_TMPDIR}/mise"
	mkdir -p "${MISE_DATA_DIR}/shims"
	cat > "${MISE_DATA_DIR}/shims/fictional-linter" <<'SHIM'
#!/usr/bin/env bash
printf 'shim ran with: %s\n' "$*"
SHIM
	chmod +x "${MISE_DATA_DIR}/shims/fictional-linter"
}

@test "runs a tool that is already on PATH" {
	run bash "$RUN_TOOL" echo hello there
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "hello there" ]
}

# The failure this exists for: PATH has no entry for the tool, but mise does.
@test "resolves a tool missing from PATH through the mise shims directory" {
	run env PATH="/usr/bin:/bin" MISE_DATA_DIR="$MISE_DATA_DIR" \
		bash "$RUN_TOOL" fictional-linter --check file.sh
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"shim ran with: --check file.sh"* ]]
}

# 127 is load-bearing: it is what inspector reads as tool_missing. A wrapper
# that turned a genuinely absent tool into some other failure would trade a
# precise diagnosis for a confusing one.
@test "a genuinely absent tool still exits 127 so inspector reports tool_missing" {
	run -127 env PATH="/usr/bin:/bin" MISE_DATA_DIR="$MISE_DATA_DIR" \
		bash "$RUN_TOOL" definitely-not-installed-anywhere
	[ "$status" -eq 127 ]
}

@test "arguments containing spaces survive the handoff" {
	run bash "$RUN_TOOL" echo "two words" "and more"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "two words and more" ]
}

@test "a missing tool name is a usage error, not a silent success" {
	run bash "$RUN_TOOL"
	[ "$status" -eq 2 ]
}

@test "XDG_DATA_HOME is honored when MISE_DATA_DIR is unset" {
	local xdg="${BATS_TEST_TMPDIR}/xdg"
	mkdir -p "${xdg}/mise/shims"
	cp "${MISE_DATA_DIR}/shims/fictional-linter" "${xdg}/mise/shims/"
	run env -u MISE_DATA_DIR PATH="/usr/bin:/bin" XDG_DATA_HOME="$xdg" \
		bash "$RUN_TOOL" fictional-linter ok
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"shim ran with: ok"* ]]
}

# Turns the fix into a rule. Every bare-name tool in the committed inspector
# config must route through the wrapper, or the next tool added reintroduces
# exactly this bug — which is how markdownlint ended up the only safe one.
@test "every bare-name check in .claude/settings.json routes through run-tool.sh" {
	local bad
	bad=$(jq -r '
		.inspector.checks // {} | to_entries[]
		| .key as $ext | .value[]
		| select((.argv[0] | test("/")) | not)
		| "\($ext):\(.name)"' "${REPO_ROOT}/.claude/settings.json")
	if [[ -n "$bad" ]]; then
		printf 'checks invoking a bare tool name (will 127 without mise on PATH):\n%s\n' "$bad"
		return 1
	fi
	true
}
