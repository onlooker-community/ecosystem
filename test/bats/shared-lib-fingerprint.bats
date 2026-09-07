#!/usr/bin/env bats

# Every vendored copy of a fingerprinted lib carries a stamp matching its bytes.
#
# ecosystem-449.31. hook-health.sh is vendored into every plugin and plugins
# install independently, so one session can run the substrate on one copy and
# its plugins on another; records from that window mixed two attribution
# schemes with nothing to separate them. The stamp goes in the record so a
# rollup can partition rows by which copy wrote them.
#
# It is derived from the file's bytes rather than declared, because a version
# directory's name, its package.json, and its mtime have each been caught
# disagreeing with the contents they label. A hand-bumped constant would be a
# fourth such label -- so these tests exist to stop it becoming one.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/scripts/lib-fingerprint.sh"
}

@test "the canonical hook-health.sh stamp matches its own content" {
	local f="${REPO_ROOT}/scripts/lib/hook-health.sh"
	[ "$(lib_fingerprint_stamped "$f")" = "$(lib_fingerprint "$f")" ]
}

@test "every vendored copy carries a stamp matching its content" {
	local bad=() f
	for f in "${REPO_ROOT}"/plugins/*/scripts/lib/hook-health.sh; do
		[[ -f "$f" ]] || continue
		[[ "$(lib_fingerprint_stamped "$f")" == "$(lib_fingerprint "$f")" ]] \
			|| bad+=("${f#"${REPO_ROOT}/"}")
	done
	if [[ ${#bad[@]} -gt 0 ]]; then
		printf 'stamp does not match content:\n'
		printf '  %s\n' "${bad[@]}"
		return 1
	fi
	true
}

# The point of vendoring is that every copy is identical, so every stamp should
# be too. A copy that is in sync but stamped differently would mean the stamp is
# not a function of the content.
@test "all copies share one fingerprint" {
	local seen f fp
	seen=$(for f in "${REPO_ROOT}"/scripts/lib/hook-health.sh "${REPO_ROOT}"/plugins/*/scripts/lib/hook-health.sh; do
		[[ -f "$f" ]] && lib_fingerprint_stamped "$f"
	done | sort -u | wc -l | tr -d ' ')
	[ "$seen" = "1" ]
}

@test "editing a lib without restamping is caught by sync --check" {
	local work="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${work}/scripts/lib" "${work}/plugins/demo/scripts/lib"
	cp "${REPO_ROOT}/scripts/lib-fingerprint.sh" "${work}/scripts/"
	cp "${REPO_ROOT}/scripts/sync-shared-libs.sh" "${work}/scripts/"
	# portable-lock.sh is on-demand rather than shared, but sync still requires
	# the canonical copy to exist before it will run at all.
	for lib in hook-health.sh config-loader.sh substrate-resolve.sh portable-lock.sh; do
		cp "${REPO_ROOT}/scripts/lib/${lib}" "${work}/scripts/lib/${lib}"
		cp "${REPO_ROOT}/scripts/lib/${lib}" "${work}/plugins/demo/scripts/lib/${lib}"
	done

	run bash "${work}/scripts/sync-shared-libs.sh" --check
	[ "$status" -eq 0 ] || return 1

	# A behavioral edit with the stamp left alone — the exact mistake the
	# fingerprint exists to prevent going unnoticed.
	printf '\n# behavioral change\n' >> "${work}/scripts/lib/hook-health.sh"
	cp "${work}/scripts/lib/hook-health.sh" "${work}/plugins/demo/scripts/lib/hook-health.sh"

	run bash "${work}/scripts/sync-shared-libs.sh" --check
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"stale fingerprint"* ]]
}

@test "stamping is idempotent and content-derived" {
	local f="${BATS_TEST_TMPDIR}/lib.sh"
	cp "${REPO_ROOT}/scripts/lib/hook-health.sh" "$f"
	# Already correct: reports no change.
	run lib_fingerprint_stamp "$f"
	[ "$status" -ne 0 ] || return 1

	local before after
	before=$(lib_fingerprint_stamped "$f")
	printf '\n# changed\n' >> "$f"
	lib_fingerprint_stamp "$f"
	after=$(lib_fingerprint_stamped "$f")
	[[ "$before" != "$after" ]] || return 1
	[ "$(lib_fingerprint_stamped "$f")" = "$(lib_fingerprint "$f")" ]
}
