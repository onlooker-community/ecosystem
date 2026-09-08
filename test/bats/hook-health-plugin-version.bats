#!/usr/bin/env bats

# Every hook-health row states which plugin code wrote it.
#
# ecosystem-9eg. /clear mints a new session_id inside the SAME process, and
# plugin code is pinned at process start, so a cleared session looks
# post-release by every timestamp available while still running the
# pre-release plugin. Measured 2026-09-07: session c8fc83ed began 41 minutes
# after lineage 0.5.1 was installed and ran 0.5.0 for its whole life.
#
# The fix is to stop inferring. The lib's own path is version-pinned in the
# installed layout, so it can name the version that wrote each row.
#
# See docs/superpowers/specs/2026-09-07-session-plugin-version-provenance-design.md

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
}

# Stage a copy of the canonical lib at an arbitrary path and emit one record
# from it, so the derivation is exercised against a real layout rather than a
# stubbed variable. Echoes the record.
_row_from_layout() {
	local libdir="$1"
	mkdir -p "$libdir"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${libdir}/hook-health.sh"
	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "layout-probe"
		hook_health_success
	' _ "${libdir}/hook-health.sh" >/dev/null 2>&1
	tail -n 1 "$HEALTH_LOG"
}

@test "the released layout yields both the plugin name and its version" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/cache/onlooker-community/lineage/0.5.1/scripts/lib")
	printf '%s' "$row" | jq -e '
		.plugin_name == "lineage" and .plugin_version == "0.5.1"
	' >/dev/null
}

# A prerelease directory is still a release layout.
@test "a prerelease version directory is recognized" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/cache/onlooker-community/echo/1.2.3-rc.1/scripts/lib")
	printf '%s' "$row" | jq -e '
		.plugin_name == "echo" and .plugin_version == "1.2.3-rc.1"
	' >/dev/null
}

# A working-tree run is NOT a release. Null is the honest label -- it says
# "written by an unreleased copy" and keeps dev rows from being mistaken for
# a released version during a rollout measurement.
@test "a dev checkout yields the name with a null version" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/ecosystem/plugins/lineage/scripts/lib")
	printf '%s' "$row" | jq -e '
		.plugin_name == "lineage" and .plugin_version == null
	' >/dev/null
}

# The substrate published from the marketplace looks like any other plugin.
@test "the substrate reports itself by name and version" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.53.2/scripts/lib")
	printf '%s' "$row" | jq -e '
		.plugin_name == "ecosystem" and .plugin_version == "0.53.2"
	' >/dev/null
}

# Fail-soft: an unrecognizable path must still produce a usable record.
@test "an unexpected layout nulls both fields and still writes the row" {
	local row
	row=$(_row_from_layout "${BATS_TEST_TMPDIR}/somewhere/odd")
	printf '%s' "$row" | jq -e '
		.plugin_name == null and .plugin_version == null
		and .hook == "layout-probe" and .status == "success"
	' >/dev/null
}

# host_pid is what makes /clear visible: two session_ids sharing one host_pid
# is a cleared session, not two processes.
@test "host_pid records the shell's parent process" {
	source "${REPO_ROOT}/scripts/lib/hook-health.sh"
	hook_health_register "pid-probe"
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e --argjson want "$PPID" '.host_pid == $want' >/dev/null
}

@test "the three fields survive into every vendored copy" {
	local missing=() f
	for f in "${REPO_ROOT}"/plugins/*/scripts/lib/hook-health.sh; do
		[[ -f "$f" ]] || continue
		grep -q '_hook_health_derive_origin' "$f" || missing+=("${f#"${REPO_ROOT}/"}")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		printf 'vendored copies without the derivation:\n'
		printf '  %s\n' "${missing[@]}"
		return 1
	fi
	true
}

# The installed layout is a standalone tree with no ecosystem checkout above
# it. This is the shape that broke ecosystem-ber and ecosystem-449.35/36.
@test "derivation works from a copied-out standalone plugin tree" {
	local standalone="${BATS_TEST_TMPDIR}/standalone/onlooker-community/inspector/9.9.9"
	mkdir -p "$standalone"
	cp -R "${REPO_ROOT}/plugins/inspector/." "${standalone}/"

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "standalone-probe"
		hook_health_success
	' _ "${standalone}/scripts/lib/hook-health.sh" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "inspector" and .plugin_version == "9.9.9"
	' >/dev/null
}
