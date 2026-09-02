#!/usr/bin/env bats
#
# Where config-loader.sh looks for the USER settings layer.
#
# The loader documents a five-layer precedence chain:
#   defaults < home < home-local < repo < repo-local
#
# Layers 2 and 3 were addressed as a hardcoded "${HOME}/.claude/settings.json"
# (config-loader.sh:78-79). Claude Code exports CLAUDE_CONFIG_DIR to hook
# processes and it is not always $HOME/.claude — this machine uses
# ~/.claude-personal, where $HOME/.claude does not exist at all. So on any
# machine with a custom config dir those two layers were unreachable: a
# user-level plugin override was read from a file that could not be there,
# and silently ignored with no error and no test failure (ecosystem-68z).
#
# The substrate had already solved this at validate-path.sh:19 —
# CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}. config-loader is a
# standalone vendored lib and cannot source validate-path, so it mirrors the
# same chain, in the same order, on purpose.
#
# Every existing *-config.bats writes to "${HOME}/.claude/settings.json" and
# the loader read "${HOME}/.claude/settings.json", so the two agreed and the
# defect was invisible. These tests drive the disagreement directly.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/bursar-config.sh"

	# setup_test_env pins CLAUDE_HOME and clears CLAUDE_CONFIG_DIR. Clear
	# CLAUDE_HOME too so each test states the exact variable it is exercising.
	unset CLAUDE_HOME

	CUSTOM_DIR="${BATS_TEST_TMPDIR}/dot-claude-personal"
	mkdir -p "$CUSTOM_DIR"
}

# The regression test for ecosystem-68z. Before the fix this read the shipped
# default, because the loader looked in $HOME/.claude — which is not merely
# empty here, it does not exist.
@test "a user override under CLAUDE_CONFIG_DIR is applied" {
	export CLAUDE_CONFIG_DIR="$CUSTOM_DIR"
	printf '%s\n' '{"bursar":{"window":"calendar_week"}}' >"${CUSTOM_DIR}/settings.json"
	[ ! -e "${HOME}/.claude/settings.json" ] || return 1

	bursar_config_load ""
	[ "$(bursar_config_window)" = "calendar_week" ]
}

@test "settings.local.json under CLAUDE_CONFIG_DIR overrides settings.json" {
	export CLAUDE_CONFIG_DIR="$CUSTOM_DIR"
	printf '%s\n' '{"bursar":{"week_start":"monday"}}' >"${CUSTOM_DIR}/settings.json"
	printf '%s\n' '{"bursar":{"week_start":"sunday"}}' >"${CUSTOM_DIR}/settings.local.json"

	bursar_config_load ""
	[ "$(bursar_config_week_start)" = "sunday" ]
}

# CLAUDE_HOME first, then CLAUDE_CONFIG_DIR, then $HOME/.claude — the order
# validate-path.sh:19 uses. Pinned so the two cannot drift apart.
@test "CLAUDE_HOME wins over CLAUDE_CONFIG_DIR" {
	local home_dir="${BATS_TEST_TMPDIR}/explicit-claude-home"
	mkdir -p "$home_dir"
	export CLAUDE_HOME="$home_dir"
	export CLAUDE_CONFIG_DIR="$CUSTOM_DIR"
	printf '%s\n' '{"bursar":{"window":"calendar_week"}}' >"${home_dir}/settings.json"
	printf '%s\n' '{"bursar":{"window":"rolling_7d"}}' >"${CUSTOM_DIR}/settings.json"

	bursar_config_load ""
	[ "$(bursar_config_window)" = "calendar_week" ]
}

# A default install exports neither variable, so the original path has to keep
# working. This is what every other *-config.bats depends on.
@test "falls back to \$HOME/.claude when neither variable is set" {
	unset CLAUDE_CONFIG_DIR
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"window":"calendar_week"}}' >"${HOME}/.claude/settings.json"

	bursar_config_load ""
	[ "$(bursar_config_window)" = "calendar_week" ]
}

# Moving the user layer must not reorder the chain around it.
@test "the repo layer still overrides a user layer found via CLAUDE_CONFIG_DIR" {
	export CLAUDE_CONFIG_DIR="$CUSTOM_DIR"
	printf '%s\n' '{"bursar":{"window":"calendar_week"}}' >"${CUSTOM_DIR}/settings.json"

	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"bursar":{"window":"rolling_7d"}}' >"${repo}/.claude/settings.json"

	bursar_config_load "$repo"
	[ "$(bursar_config_window)" = "rolling_7d" ]
}
