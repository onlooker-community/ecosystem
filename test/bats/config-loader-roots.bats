#!/usr/bin/env bats
#
# config_load_plugin resolves its own roots (ecosystem-449.37 acceptance 5).
#
# The loader used to take a repo root and build both repo-scoped layers from it.
# Any string was accepted, so a wrong one produced no error, no event and no test
# failure — the layers simply did not exist and the plugin ran on shipped
# defaults. Three bugs came out of that hole (ecosystem-ber, ecosystem-68z, and
# the two categories below).
#
# It now takes the session cwd and derives both roots itself:
#
#   layer 4  <worktree>/.claude/settings.json        committed, branch-scoped
#   layer 5  <parent>/.claude/settings.local.json    gitignored, machine-scoped
#
# Driven from a real `git worktree add` rather than a simulated layout, because
# --git-common-dir only returns a relative path in a real checkout and only
# returns an absolute one in a real linked worktree. A faked directory tree
# exercises neither branch.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# A throwaway plugin so layer 1 (shipped defaults) is under test control.
	# Shaped like a real plugin config.json: a plugin_name key beside a
	# plugin-scoped block. Layer 1 is merged whole, layers 2-5 only by that key.
	PLUGIN_DIR="${BATS_TEST_TMPDIR}/fakeplugin"
	mkdir -p "$PLUGIN_DIR"
	printf '%s\n' '{"plugin_name":"probe","probe":{"value":"SHIPPED_DEFAULT"}}' \
		> "${PLUGIN_DIR}/config.json"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "${MAIN}/sub/dir" "${MAIN}/.claude"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email test@example.com
	git -C "$MAIN" config user.name test
	# settings.local.json must be IGNORED, not committed. setup_test_env points
	# GIT_CONFIG_GLOBAL at /dev/null and unsets XDG_CONFIG_HOME, so the real
	# machine's ~/.config/git/ignore does not apply here. Without this file the
	# fixture commits settings.local.json, `git worktree add` checks a copy into
	# the worktree, and the layer-5 test passes by reading THAT copy — proving
	# nothing about which root it came from.
	printf '%s\n' '.claude/settings.local.json' > "${MAIN}/.gitignore"
	printf '%s\n' '{"probe":{"value":"MAIN_L4"}}' > "${MAIN}/.claude/settings.json"
	printf '%s\n' '{"probe":{"local":"MAIN_L5"}}' > "${MAIN}/.claude/settings.local.json"
	git -C "$MAIN" add -A
	git -C "$MAIN" commit -qm init

	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch
	mkdir -p "${WT}/.claude" "${WT}/sub/dir"
	printf '%s\n' '{"probe":{"value":"WORKTREE_L4"}}' > "${WT}/.claude/settings.json"

	# The fixture only models the real world if the worktree genuinely lacks a
	# local override. Assert it rather than trust it — this is the condition the
	# layer-5 tests depend on, and it broke silently once already.
	[ ! -e "${WT}/.claude/settings.local.json" ]

	# shellcheck source=../../scripts/lib/config-loader.sh
	source "${REPO_ROOT}/scripts/lib/config-loader.sh"
}

# config_load_plugin sets its output variable in the caller's scope, and
# config_get reads it back by name, so a local here is visible to both.
_value_from() {
	# Set by config_load_plugin via printf -v and read back by config_get via
	# indirect expansion, so shellcheck cannot see either use.
	# shellcheck disable=SC2034
	local probe_config=""
	config_load_plugin "probe" "$1" "probe_config"
	config_get "probe_config" '.probe.value'
}

_local_from() {
	# Set by config_load_plugin via printf -v and read back by config_get via
	# indirect expansion, so shellcheck cannot see either use.
	# shellcheck disable=SC2034
	local probe_config=""
	config_load_plugin "probe" "$1" "probe_config"
	config_get "probe_config" '.probe.local'
}

@test "a subdirectory cwd still resolves layer 4" {
	# Category B: the loader built ${cwd}/.claude/settings.json with no upward
	# walk, so a session started anywhere but the root read shipped defaults.
	run _value_from "${MAIN}/sub/dir"
	[ "$output" = "MAIN_L4" ]
}

@test "a worktree cwd reads the worktree's layer 4, not the parent's" {
	# Category A. Both trees carry a settings.json with a DIFFERENT value, so
	# this cannot pass by one of them being absent.
	run _value_from "$WT"
	[ "$output" = "WORKTREE_L4" ]
}

@test "a worktree cwd reads the parent's layer 5" {
	# settings.local.json is gitignored, so `git worktree add` never copies it
	# and it exists only in the main checkout. Resolving layer 5 against the
	# worktree would silently drop every local override in a worktree session.
	run _local_from "$WT"
	[ "$output" = "MAIN_L5" ]
}

@test "a worktree subdirectory resolves the worktree, not the parent" {
	# Both defects composed. --git-common-dir is relative to CWD, so resolving
	# it from the toplevel instead of from cwd climbs one level too far here.
	run _value_from "${WT}/sub/dir"
	[ "$output" = "WORKTREE_L4" ]
}

@test "layer 5 still outranks layer 4 across the two roots" {
	# Only the roots moved; precedence order is unchanged.
	printf '%s\n' '{"probe":{"value":"MAIN_L5_WINS"}}' \
		> "${MAIN}/.claude/settings.local.json"
	run _value_from "$WT"
	[ "$output" = "MAIN_L5_WINS" ]
}

@test "a non-git cwd reads its own .claude/settings.json" {
	# .claude/settings.json is a Claude Code concept, not a git one. 19 of the
	# 36 bats files that write a settings fixture never git init at all.
	local plain="${BATS_TEST_TMPDIR}/plain"
	mkdir -p "${plain}/.claude"
	printf '%s\n' '{"probe":{"value":"PLAIN_L4"}}' > "${plain}/.claude/settings.json"
	run _value_from "$plain"
	[ "$output" = "PLAIN_L4" ]
}

@test "a cwd with no .claude falls back to shipped defaults" {
	local bare="${BATS_TEST_TMPDIR}/bare"
	mkdir -p "$bare"
	run _value_from "$bare"
	[ "$output" = "SHIPPED_DEFAULT" ]
}

@test "an empty cwd falls back to shipped defaults" {
	run _value_from ""
	[ "$output" = "SHIPPED_DEFAULT" ]
}

@test "a repo root passed as cwd still resolves" {
	# The vendored-copy guarantee: a caller that still passes a root is passing
	# a valid cwd, so there is no flag day across the 16 copies.
	run _value_from "$MAIN"
	[ "$output" = "MAIN_L4" ]
}
