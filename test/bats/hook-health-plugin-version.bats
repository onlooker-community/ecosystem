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

# ---------------------------------------------------------------------------
# ecosystem-449.50 — first source wins.
#
# Fourteen plugin hooks source their own vendored hook-health.sh, register,
# and then source the substrate's validate-path.sh, which re-sources
# hook-health.sh from its OWN directory (validate-path.sh:71). The re-source
# re-runs both the initializers and the derivation with BASH_SOURCE now
# pointing into the ecosystem tree, so last-source-wins relabeled every one of
# those hooks as the substrate. Measured 2026-09-09: librarian-session-start,
# curator-session-start, archivist-inject, tribunal-stop-gate, assayer-stop
# and echo-stop-gate all stamped ecosystem 0.54.0.
#
# The ordering the fix relies on holds across all fourteen: every one sources
# its vendored copy strictly before the substrate's validate-path.sh.
# ---------------------------------------------------------------------------

# Stage a substrate release tree complete enough to source validate-path.sh.
_stage_substrate() {
	local root="$1" f
	mkdir -p "${root}/scripts/lib"
	for f in validate-path.sh hook-health.sh portable-lock.sh; do
		cp "${REPO_ROOT}/scripts/lib/${f}" "${root}/scripts/lib/${f}"
	done
}

@test "re-sourcing a second copy does not relabel the row" {
	local plugin="${BATS_TEST_TMPDIR}/cache/onlooker-community/curator/0.5.0/scripts/lib"
	local substrate="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.54.1/scripts/lib"
	mkdir -p "$plugin" "$substrate"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${plugin}/hook-health.sh"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${substrate}/hook-health.sh"

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "double-source-probe"
		source "$2"
		hook_health_success
	' _ "${plugin}/hook-health.sh" "${substrate}/hook-health.sh" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "curator" and .plugin_version == "0.5.0"
	' >/dev/null
}

# The real path: the substrate is reached through validate-path.sh, exactly as
# the fourteen affected hooks reach it.
@test "sourcing the substrate's validate-path.sh preserves the plugin identity" {
	local plugin="${BATS_TEST_TMPDIR}/cache/onlooker-community/librarian/0.18.0/scripts/lib"
	local substrate="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.54.1"
	mkdir -p "$plugin"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${plugin}/hook-health.sh"
	_stage_substrate "$substrate"

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "validate-path-probe"
		CLAUDE_PLUGIN_ROOT="$3" source "$2"
		hook_health_success
	' _ "${plugin}/hook-health.sh" "${substrate}/scripts/lib/validate-path.sh" "$substrate" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "librarian" and .plugin_version == "0.18.0"
	' >/dev/null
}

# Guard against over-fixing. An ecosystem hook sources only validate-path.sh,
# so the substrate's own copy is the first one and must still name itself.
@test "the substrate still labels its own hooks when it is the first source" {
	local substrate="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.54.1"
	_stage_substrate "$substrate"

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		CLAUDE_PLUGIN_ROOT="$2" source "$1"
		hook_health_register "substrate-only-probe"
		hook_health_success
	' _ "${substrate}/scripts/lib/validate-path.sh" "$substrate" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "ecosystem" and .plugin_version == "0.54.1"
	' >/dev/null
}

# An unrecognizable first copy stays null rather than inheriting the
# substrate's identity. Null says "written by a copy we cannot name"; adopting
# the substrate's name would be the same wrong answer 449.50 is about.
@test "an unidentifiable first source is not backfilled by a later one" {
	local odd="${BATS_TEST_TMPDIR}/somewhere/odd"
	local substrate="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.54.1/scripts/lib"
	mkdir -p "$odd" "$substrate"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${odd}/hook-health.sh"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${substrate}/hook-health.sh"

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "odd-first-probe"
		source "$2"
		hook_health_success
	' _ "${odd}/hook-health.sh" "${substrate}/hook-health.sh" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == null and .plugin_version == null
	' >/dev/null
}
