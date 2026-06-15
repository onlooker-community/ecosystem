#!/usr/bin/env bats

# Exercises Inspector's project-key derivation.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/inspector"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/inspector-project-key.sh"
}

@test "produces a 12-char hex key from origin remote" {
	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" remote add origin "https://example.com/widgets.git"

	local key
	key=$(inspector_project_key "$REPO")
	[ "${#key}" = "12" ]
	[[ "$key" =~ ^[0-9a-f]{12}$ ]]
}

@test "remote-derived key is stable across temp clones" {
	REPO_A="${BATS_TEST_TMPDIR}/a"; mkdir -p "$REPO_A"
	REPO_B="${BATS_TEST_TMPDIR}/b"; mkdir -p "$REPO_B"
	git -C "$REPO_A" init -q
	git -C "$REPO_B" init -q
	git -C "$REPO_A" remote add origin "https://example.com/x.git"
	git -C "$REPO_B" remote add origin "https://example.com/x.git"

	local key_a key_b
	key_a=$(inspector_project_key "$REPO_A")
	key_b=$(inspector_project_key "$REPO_B")
	[ "$key_a" = "$key_b" ]
}

@test "falls back to repo root when origin is missing" {
	REPO="${BATS_TEST_TMPDIR}/no-remote"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	local key
	key=$(inspector_project_key "$REPO")
	[ "${#key}" = "12" ]
}

@test "falls back to cwd when not a git repo" {
	NOT_REPO="${BATS_TEST_TMPDIR}/not-git"
	mkdir -p "$NOT_REPO"
	local key
	key=$(inspector_project_key "$NOT_REPO")
	[ "${#key}" = "12" ]
}

@test "project_repo_root returns repo top-level for a git checkout" {
	REPO="${BATS_TEST_TMPDIR}/repo2"
	mkdir -p "$REPO/sub"
	git -C "$REPO" init -q
	local root expected
	root=$(inspector_project_repo_root "$REPO/sub")
	# Canonicalize both sides: macOS git resolves tmp paths through /private/,
	# while $REPO retains the symlinked /var/folders/ prefix.
	expected=$(cd "$REPO" && /bin/pwd -P 2>/dev/null || pwd)
	root=$(cd "$root" && /bin/pwd -P 2>/dev/null || pwd)
	[ "$root" = "$expected" ]
}
