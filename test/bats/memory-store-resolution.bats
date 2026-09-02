#!/usr/bin/env bats
#
# Resolution of the typed memory store path, for curator and librarian.
#
# Both plugins reach the user's memory store through a template in their
# config.json. Two defects lived in that resolution and neither had a test:
#
#   ecosystem-449.18 — the template hardcoded `.claude`, and the resolvers
#   interpolated only ${HOME} and ${CLAUDE_PROJECT_ENCODED}. Claude Code
#   exports CLAUDE_CONFIG_DIR to hook processes, so on any machine that sets
#   it (this one uses ~/.claude-personal) both plugins resolved a directory
#   that does not exist, found nothing, and reported nothing. The substrate
#   had already solved this at validate-path.sh:19; these two ignored it.
#
#   ecosystem-18f — librarian expanded the template with `eval echo`, so a
#   value supplied by a cloned repo's .claude/settings.json ran as a command
#   at SessionEnd.
#
# Neither was visible because the existing curator tests deliberately bypass
# the template: "Bypass the ${CLAUDE_PROJECT_ENCODED} template by overriding
# memory_store_path to an absolute path" (curator-session-start.bats:33).
# Resolution itself had no coverage at all.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# shellcheck disable=SC1091
	source "${REPO_ROOT}/plugins/curator/scripts/lib/curator-memory-reader.sh"
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-storage.sh"

	TEMPLATE='${CLAUDE_CONFIG_DIR}/projects/${CLAUDE_PROJECT_ENCODED}/memory'
	export CLAUDE_PROJECT_ENCODED="-tmp-fixture-repo"
}

# ---------------------------------------------------------------------------
# CLAUDE_CONFIG_DIR is honored
# ---------------------------------------------------------------------------

@test "curator resolves the store under CLAUDE_CONFIG_DIR when one is exported" {
	export CLAUDE_CONFIG_DIR="${BATS_TEST_TMPDIR}/custom-config"
	run curator_memory_resolve_path "$TEMPLATE"
	[ "$output" = "${BATS_TEST_TMPDIR}/custom-config/projects/-tmp-fixture-repo/memory" ]
}

@test "librarian resolves the store under CLAUDE_CONFIG_DIR when one is exported" {
	export CLAUDE_CONFIG_DIR="${BATS_TEST_TMPDIR}/custom-config"
	run librarian_memory_resolve_path "$TEMPLATE"
	[ "$output" = "${BATS_TEST_TMPDIR}/custom-config/projects/-tmp-fixture-repo/memory" ]
}

# The default install has no CLAUDE_CONFIG_DIR, so the fallback has to keep
# landing on $HOME/.claude — same value validate-path.sh:19 falls back to.
@test "curator falls back to \$HOME/.claude when no config dir is exported" {
	unset CLAUDE_CONFIG_DIR
	run curator_memory_resolve_path "$TEMPLATE"
	[ "$output" = "${HOME}/.claude/projects/-tmp-fixture-repo/memory" ]
}

@test "librarian falls back to \$HOME/.claude when no config dir is exported" {
	unset CLAUDE_CONFIG_DIR
	run librarian_memory_resolve_path "$TEMPLATE"
	[ "$output" = "${HOME}/.claude/projects/-tmp-fixture-repo/memory" ]
}

# A user who already pinned the old ${HOME}-based template in their settings
# must not have it broken by the new default.
@test "the legacy \${HOME}-based template still resolves" {
	unset CLAUDE_CONFIG_DIR
	run librarian_memory_resolve_path '${HOME}/.claude/projects/${CLAUDE_PROJECT_ENCODED}/memory'
	[ "$output" = "${HOME}/.claude/projects/-tmp-fixture-repo/memory" ]
}

# ---------------------------------------------------------------------------
# ecosystem-18f: the template is data, never shell
# ---------------------------------------------------------------------------
#
# librarian-session-end.sh ran `eval echo "$MEMORY_STORE_PATH"` on a value the
# config loader sources from <repo>/.claude/settings.json, so cloning a repo
# was enough to execute a command as the user at SessionEnd. Proven before the
# fix: a template of '$(touch PROOF)/memory' created the file and resolved to
# '/memory'.
#
# Both of these were checked against an eval-based mutant and fail there, so
# they are not passing by accident.

@test "a path containing a command substitution is data, not a command" {
	local canary="${BATS_TEST_TMPDIR}/PROOF"
	run librarian_memory_resolve_path "\$(touch ${canary})/memory"

	[ ! -e "$canary" ] || return 1
	[ "$output" = "\$(touch ${canary})/memory" ]
}

@test "a path containing backticks is data, not a command" {
	local canary="${BATS_TEST_TMPDIR}/PROOF_BACKTICK"
	run librarian_memory_resolve_path "\`touch ${canary}\`/memory"

	[ ! -e "$canary" ] || return 1
	[ "$output" = "\`touch ${canary}\`/memory" ]
}

@test "curator is injection-free on the same input" {
	local canary="${BATS_TEST_TMPDIR}/PROOF_CURATOR"
	run curator_memory_resolve_path "\$(touch ${canary})/memory"

	[ ! -e "$canary" ] || return 1
	[ "$output" = "\$(touch ${canary})/memory" ]
}

# ---------------------------------------------------------------------------
# An unresolvable template yields nothing rather than a half-expanded path
# ---------------------------------------------------------------------------

@test "an unresolved project placeholder yields empty, not a literal placeholder" {
	unset CLAUDE_PROJECT_ENCODED
	run librarian_memory_resolve_path "$TEMPLATE"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "an explicit encoded argument overrides the unset environment variable" {
	unset CLAUDE_PROJECT_ENCODED
	export CLAUDE_CONFIG_DIR="${BATS_TEST_TMPDIR}/custom-config"
	run librarian_memory_resolve_path "$TEMPLATE" "-explicit-encoding"
	[ "$output" = "${BATS_TEST_TMPDIR}/custom-config/projects/-explicit-encoding/memory" ]
}
