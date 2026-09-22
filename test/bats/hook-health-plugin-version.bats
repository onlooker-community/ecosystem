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

# ---------------------------------------------------------------------------
# A hook that sources the lib relative to its own directory reaches it by a
# path that still carries the `..`: "$SCRIPT_DIR/../lib/hook-health.sh"
# expands to <root>/scripts/hooks/../lib/hook-health.sh. The walk checks each
# component by name rather than stripping blindly, so it read `..` where it
# expected `scripts` and took the unrecognizable-shape branch.
#
# plugin-currency-surfacer is the only substrate hook that sources hook-health
# first. The other fourteen reach it through validate-path.sh, which sources
# from its own already-clean directory and wins under first-source-wins, so
# the `..` path never became the derivation they used. It alone wrote null:
# measured 2026-09-20, all 1,315 of its rows unattributed, and the only
# unattributed hook among the 48,029 rows since 2026-09-19.
# ---------------------------------------------------------------------------

@test "a path through a hooks/.. segment still names the plugin" {
	local root="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.61.7"
	mkdir -p "${root}/scripts/lib" "${root}/scripts/hooks"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${root}/scripts/lib/hook-health.sh"

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "dotdot-probe"
		hook_health_success
	' _ "${root}/scripts/hooks/../lib/hook-health.sh" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "ecosystem" and .plugin_version == "0.61.7"
	' >/dev/null
}

# Guard against over-fixing. Collapsing `..` must make a legitimate shape
# recognizable, not make an unrecognizable one pass: this path collapses to
# /somewhere/odd, which is still not <root>/scripts/lib.
@test "a .. segment does not rescue a layout that is still unrecognizable" {
	local odd="${BATS_TEST_TMPDIR}/somewhere/odd"
	mkdir -p "$odd"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "${odd}/hook-health.sh"

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "odd-dotdot-probe"
		hook_health_success
	' _ "${odd}/../odd/hook-health.sh" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == null and .plugin_version == null
	' >/dev/null
}

# ---------------------------------------------------------------------------
# lib_schema must name the same copy plugin_name/plugin_version came from.
#
# The three fields exist to be read together: 449.31 added lib_schema so a
# rollup could partition rows by which copy's derivation produced the
# attribution on them, rather than assuming every row in a mixed-version
# window used one scheme. That only holds if all three describe one copy.
#
# They do not get the same protection. _ONLOOKER_PLUGIN_NAME/_VERSION are
# derived once behind the _ONLOOKER_PLUGIN_ORIGIN_DERIVED sentinel
# (hook-health.sh:184) -- first source wins. _ONLOOKER_LIB_FINGERPRINT
# (hook-health.sh:54) is a plain assignment outside that guard, re-run by
# every re-source, and both writers read it live at write time (:368, :606) --
# last source wins.
#
# The existing double-source tests above cannot see this: they copy the same
# canonical lib to both paths, so the two stamps are byte-identical. These
# stage two copies that differ ONLY in the stamp, which is the one variable
# under test.
#
# Field evidence, 2026-09-21: 4 rows reading tribunal 1.5.3 / 6431e405ebd9 and
# 3 reading librarian 0.18.8 / 6431e405ebd9, where both plugins' own vendored
# copies can only carry the older f25060e27474.
# ---------------------------------------------------------------------------

# Copy the canonical lib and restamp it, so two copies differ only in the
# fingerprint constant. Restamping rather than editing the body keeps the
# derivation logic identical across both copies.
_stamped_copy() {
	local dest="$1" stamp="$2"
	mkdir -p "${dest%/*}"
	sed "s/^_ONLOOKER_LIB_FINGERPRINT=.*/_ONLOOKER_LIB_FINGERPRINT=\"${stamp}\"/" \
		"${REPO_ROOT}/scripts/lib/hook-health.sh" > "$dest"
	# Fail loudly if the constant ever stops matching that pattern, rather
	# than silently staging two identically-stamped copies and passing.
	grep -q "^_ONLOOKER_LIB_FINGERPRINT=\"${stamp}\"$" "$dest"
}

@test "lib_schema names the first source, not the last" {
	local plugin="${BATS_TEST_TMPDIR}/cache/onlooker-community/tribunal/1.5.3/scripts/lib"
	local substrate="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.61.8/scripts/lib"
	_stamped_copy "${plugin}/hook-health.sh" "aaaaaaaaaaaa" || return 1
	_stamped_copy "${substrate}/hook-health.sh" "bbbbbbbbbbbb" || return 1

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "fingerprint-double-source-probe"
		source "$2"
		hook_health_success
	' _ "${plugin}/hook-health.sh" "${substrate}/hook-health.sh" >/dev/null 2>&1

	# All three fields describe the copy that won the derivation.
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "tribunal"
		and .plugin_version == "1.5.3"
		and .lib_schema == "aaaaaaaaaaaa"
	' >/dev/null
}

# The real path: the substrate is reached through validate-path.sh, exactly as
# the fourteen affected hooks reach it.
@test "lib_schema survives the substrate's validate-path.sh" {
	local plugin="${BATS_TEST_TMPDIR}/cache/onlooker-community/librarian/0.18.8/scripts/lib"
	local substrate="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.61.8"
	_stamped_copy "${plugin}/hook-health.sh" "aaaaaaaaaaaa" || return 1
	_stage_substrate "$substrate"
	_stamped_copy "${substrate}/scripts/lib/hook-health.sh" "bbbbbbbbbbbb" || return 1

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "fingerprint-validate-path-probe"
		CLAUDE_PLUGIN_ROOT="$3" source "$2"
		hook_health_success
	' _ "${plugin}/hook-health.sh" "${substrate}/scripts/lib/validate-path.sh" "$substrate" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "librarian"
		and .plugin_version == "0.18.8"
		and .lib_schema == "aaaaaaaaaaaa"
	' >/dev/null
}

# The start breadcrumb carries lib_schema too (:383) and is written from the
# same global, so it must agree with the terminal record that closes it --
# otherwise a run_id joins two rows claiming different copies.
@test "the start breadcrumb and terminal record agree on lib_schema" {
	local plugin="${BATS_TEST_TMPDIR}/cache/onlooker-community/tribunal/1.5.3/scripts/lib"
	local substrate="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.61.8/scripts/lib"
	_stamped_copy "${plugin}/hook-health.sh" "aaaaaaaaaaaa" || return 1
	_stamped_copy "${substrate}/hook-health.sh" "bbbbbbbbbbbb" || return 1

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		source "$1"
		hook_health_register "fingerprint-breadcrumb-probe"
		source "$2"
		hook_health_success
	' _ "${plugin}/hook-health.sh" "${substrate}/hook-health.sh" >/dev/null 2>&1

	local run_id
	run_id=$(tail -n 1 "$HEALTH_LOG" | jq -r '.run_id')
	[ -n "$run_id" ] || return 1

	jq -e --arg rid "$run_id" -s '
		map(select(.run_id == $rid))
		| (map(.lib_schema) | unique | length) == 1
	' "$HEALTH_LOG" >/dev/null
}

# Guard against over-fixing. An ecosystem hook sources only validate-path.sh,
# so the substrate's own copy is the first one and its stamp must still land.
@test "the substrate stamps its own fingerprint when it is the first source" {
	local substrate="${BATS_TEST_TMPDIR}/cache/onlooker-community/ecosystem/0.61.8"
	_stage_substrate "$substrate"
	_stamped_copy "${substrate}/scripts/lib/hook-health.sh" "bbbbbbbbbbbb" || return 1

	env HOME="$HOME" ONLOOKER_DIR="$ONLOOKER_DIR" bash -c '
		CLAUDE_PLUGIN_ROOT="$2" source "$1"
		hook_health_register "fingerprint-substrate-only-probe"
		hook_health_success
	' _ "${substrate}/scripts/lib/validate-path.sh" "$substrate" >/dev/null 2>&1

	tail -n 1 "$HEALTH_LOG" | jq -e '
		.plugin_name == "ecosystem"
		and .plugin_version == "0.61.8"
		and .lib_schema == "bbbbbbbbbbbb"
	' >/dev/null
}
