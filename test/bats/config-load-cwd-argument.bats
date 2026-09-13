#!/usr/bin/env bats
#
# Guards that no hook hands *_config_load a project-key root.
#
# config_load_plugin resolves the worktree and parent roots from a session cwd
# itself (ecosystem-449.37). A caller can no longer pick a wrong root, but it can
# still hand the resolver the wrong INPUT, and passing a project-key root is the
# mistake that reads as correct: *_project_repo_root deliberately resolves a
# linked worktree to its parent checkout, so a worktree session would resolve to
# the parent and read a different branch's config.
#
# Covers all hooks at once so plugin 17 cannot quietly reintroduce the pattern.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

_hooks() {
	find "${REPO_ROOT}/plugins" -path '*/scripts/hooks/*.sh' -type f | sort
}

# Without this, a typo in _hooks would make the test below pass over an empty
# list and report coverage that does not exist.
@test "the hook glob matches at least one file" {
	local count
	count=$(_hooks | wc -l | tr -d ' ')
	[ "$count" -gt 0 ]
}

@test "no hook passes a project-key root into *_config_load" {
	local offenders=""
	local hook
	while IFS= read -r hook; do
		if grep -qE '_config_load[[:space:]]+"\$\{?REPO_ROOT' "$hook"; then
			offenders+="${hook#"${REPO_ROOT}/"} (\$REPO_ROOT)"$'\n'
		fi
		if grep -qE '_config_load[[:space:]]+"\$\(.*_project_repo_root' "$hook"; then
			offenders+="${hook#"${REPO_ROOT}/"} (inline *_project_repo_root)"$'\n'
		fi
	done < <(_hooks)

	[ -z "$offenders" ] || {
		printf 'hooks passing a project-key root to *_config_load:\n%s' "$offenders" >&2
		return 1
	}
}
