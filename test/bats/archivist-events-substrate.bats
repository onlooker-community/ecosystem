#!/usr/bin/env bats

# Which ecosystem emitter archivist emits through (ecosystem-449.35).
#
# _archivist_event_js_path globs the shared plugin cache for
# .../ecosystem/*/scripts/lib/onlooker-event.mjs and returns the first match.
# Glob expansion is lexicographic, not semver, so 0.33.1 sorts ahead of 0.49.2
# and archivist emits through whichever version happens to sort first.
#
# This is the site 449.35 was originally filed against. Unlike the validate-path
# loop in the hooks, there is no doubled dirname here — the matched .mjs is
# returned directly. So the path exists, emission works, schema validation
# passes and hook-health stays green. Nothing anywhere reports that the emitter
# is a month old.
#
# Measured 2026-09-06: 23 cached ecosystem versions, archivist binding 0.33.1
# (Aug 6) against an active 0.49.2 (Sep 6).
#
# Severity is worth stating honestly: the emitted envelope is identical between
# those two versions and neither validates in production, so this is not
# currently corrupting event data. It is a pin that cannot be reasoned about —
# the next substrate change that does alter emit behavior reaches nothing.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	CACHE="${BATS_TEST_TMPDIR}/cache"
	mkdir -p "${CACHE}/archivist/0.4.6/scripts/lib"
	cp "${REPO_ROOT}/plugins/archivist/scripts/lib/archivist-events.sh" \
		"${CACHE}/archivist/0.4.6/scripts/lib/archivist-events.sh"

	# Two cached ecosystems, each with a distinguishable emitter.
	for v in 0.33.1 0.49.2; do
		mkdir -p "${CACHE}/ecosystem/${v}/scripts/lib"
		printf '// emitter %s\n' "$v" > "${CACHE}/ecosystem/${v}/scripts/lib/onlooker-event.mjs"
	done

	# Resolution reads CLAUDE_PLUGIN_ROOT, and the two local candidates it
	# checks first must not exist for the glob branch to be reached.
	export CLAUDE_PLUGIN_ROOT="${CACHE}/archivist/0.4.6"
	unset _ARCHIVIST_EVENT_JS 2>/dev/null || true

	# shellcheck disable=SC1091
	source "${CACHE}/archivist/0.4.6/scripts/lib/archivist-events.sh"
}

@test "resolves an emitter at all from the plugin cache" {
	run _archivist_event_js_path
	[ "$status" -eq 0 ] || return 1
	[ -n "$output" ]
}

@test "emits through the newest cached ecosystem, not the lexically first" {
	run _archivist_event_js_path
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"/ecosystem/0.49.2/"* ]]
}
