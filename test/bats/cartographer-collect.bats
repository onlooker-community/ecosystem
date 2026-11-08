#!/usr/bin/env bats

# Global instruction-file discovery. Claude Code exports CLAUDE_CONFIG_DIR to
# hooks, and on an install that relocates its config dir, $HOME/.claude usually
# does not exist. Cartographer hardcoded $HOME/.claude here, so it never saw
# the user's global CLAUDE.md or rules/, and scope_collision, which compares
# project rules against global ones, had nothing to compare and reported clean
# (ONL-276).

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/cartographer-collect.sh"

	# The harness sets CLAUDE_HOME; production hooks never get it.
	unset CLAUDE_HOME

	CONFIG_DIR="${HOME}/.claude-personal"
	mkdir -p "${CONFIG_DIR}/rules" "${HOME}/.claude/rules"
	printf '# relocated\n' >"${CONFIG_DIR}/CLAUDE.md"
	printf '# relocated rule\n' >"${CONFIG_DIR}/rules/style.md"
	printf '# default\n' >"${HOME}/.claude/CLAUDE.md"
	printf '# default rule\n' >"${HOME}/.claude/rules/default.md"
}

@test "collects the global CLAUDE.md and rules from CLAUDE_CONFIG_DIR" {
	export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
	run cartographer_collect_global_files
	[ "$status" -eq 0 ] || return 1

	[[ "$output" == *"${CONFIG_DIR}/CLAUDE.md"* ]] || return 1
	[[ "$output" == *"${CONFIG_DIR}/rules/style.md"* ]] || return 1
	[[ "$output" != *"${HOME}/.claude/"* ]]
}

@test "falls back to \$HOME/.claude when CLAUDE_CONFIG_DIR is unset" {
	unset CLAUDE_CONFIG_DIR
	run cartographer_collect_global_files
	[ "$status" -eq 0 ] || return 1

	[[ "$output" == *"${HOME}/.claude/CLAUDE.md"* ]] || return 1
	[[ "$output" == *"${HOME}/.claude/rules/default.md"* ]] || return 1
	[[ "$output" != *"${CONFIG_DIR}"* ]]
}

@test "prefers CLAUDE_HOME over CLAUDE_CONFIG_DIR, as config-loader.sh does" {
	export CLAUDE_CONFIG_DIR="${HOME}/.claude"
	export CLAUDE_HOME="$CONFIG_DIR"
	run cartographer_collect_global_files
	[ "$status" -eq 0 ] || return 1

	[[ "$output" == *"${CONFIG_DIR}/CLAUDE.md"* ]] || return 1
	[[ "$output" != *"${HOME}/.claude/"* ]]
}

@test "prints nothing when the config dir has no instruction files" {
	export CLAUDE_CONFIG_DIR="${HOME}/.claude-empty"
	mkdir -p "$CLAUDE_CONFIG_DIR"
	run cartographer_collect_global_files
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}
