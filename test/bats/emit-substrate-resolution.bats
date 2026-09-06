#!/usr/bin/env bats
#
# Guards how the fail-soft emit libs resolve the ecosystem substrate.
#
# librarian, curator and historian each glob-discover onlooker-event.mjs under
# the shared plugin cache, then re-derive an ecosystem root from the match with
# two dirnames. The match is .../ecosystem/<v>/scripts/lib/onlooker-event.mjs,
# so two dirnames strip lib/ and the filename and land on .../<v>/scripts. The
# caller appends scripts/lib/onlooker-event.mjs to that, yielding
# .../<v>/scripts/scripts/lib/onlooker-event.mjs. No such file exists, the -f
# guard short-circuits, and every event is dropped in silence.
#
# Nothing downstream can see it. Fail-soft cannot distinguish "nothing to emit"
# from "cannot find the emitter", so the hooks fire, return success, and advance
# their watermarks while the plugin's entire event stream is gone. librarian,
# curator and historian each emitted their last event at 2026-08-03T21:25:45 and
# no instrument registered a change (ecosystem-449.34).
#
# archivist-events.sh:31-33 globs the same way but returns the matched .mjs
# directly instead of re-deriving a root, and so cannot double. That is the
# shape these three should have.
#
# The glob carries a second, independent defect: it takes the first match in
# lexical order, which is not version order. The fixture pins three versions
# where the two orders disagree in both directions -- lexically 0.33.1 < 0.49.2
# < 0.9.0, but 0.49.2 is highest -- so neither `head -1` nor `tail -1` can pass
# by accident.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

# The emit libs that re-derive a root rather than returning the glob match.
_doubling_emit_libs() {
	printf '%s\n' librarian curator historian
}

# Build a plugin cache mirroring the real layout:
#
#   <cache>/ecosystem/<v>/scripts/lib/onlooker-event.mjs
#   <cache>/<plugin>/1.0.0/scripts/lib/<plugin>-emit.sh
#
# so plugin_root/../../ecosystem/* matches exactly as it does on disk. No
# onlooker-event.mjs is placed at <cache>/scripts/lib, so resolution falls
# through the direct-sibling branch and reaches the glob under test.
_resolve_against_fixture() {
	local plugin="$1"
	local cache="${BATS_TEST_TMPDIR}/cache-${plugin}"
	rm -rf "$cache"

	local v
	for v in 0.9.0 0.33.1 0.49.2; do
		mkdir -p "${cache}/ecosystem/${v}/scripts/lib"
		printf '// ecosystem %s\n' "$v" \
			>"${cache}/ecosystem/${v}/scripts/lib/onlooker-event.mjs"
	done

	mkdir -p "${cache}/${plugin}/1.0.0/scripts/lib"
	cp "${REPO_ROOT}/plugins/${plugin}/scripts/lib/${plugin}-emit.sh" \
		"${cache}/${plugin}/1.0.0/scripts/lib/${plugin}-emit.sh"

	(
		unset ONLOOKER_ECOSYSTEM_ROOT
		# shellcheck disable=SC1090
		source "${cache}/${plugin}/1.0.0/scripts/lib/${plugin}-emit.sh" >/dev/null 2>&1
		"_${plugin}_resolve_event_js"
	)
}

# Without this, a typo in _doubling_emit_libs would make every test below pass
# over an empty list and report coverage that does not exist.
@test "every emit lib named here exists in the repo" {
	local plugin
	while IFS= read -r plugin; do
		[ -f "${REPO_ROOT}/plugins/${plugin}/scripts/lib/${plugin}-emit.sh" ]
	done < <(_doubling_emit_libs)
	[ "$(_doubling_emit_libs | wc -l | tr -d ' ')" -eq 3 ]
}

@test "every emit lib resolves to a substrate file that exists" {
	local plugin resolved offenders=""
	while IFS= read -r plugin; do
		resolved="$(_resolve_against_fixture "$plugin")"
		if [ ! -f "$resolved" ]; then
			offenders+="${plugin} -> ${resolved}"$'\n'
		fi
	done < <(_doubling_emit_libs)
	[ -z "$offenders" ] || {
		printf 'unresolvable substrate path:\n%s' "$offenders" >&2
		return 1
	}
}

@test "every emit lib binds the highest version, not the lexically first" {
	local plugin resolved offenders=""
	while IFS= read -r plugin; do
		resolved="$(_resolve_against_fixture "$plugin")"
		case "$resolved" in
		*/ecosystem/0.49.2/scripts/lib/onlooker-event.mjs) ;;
		*) offenders+="${plugin} -> ${resolved}"$'\n' ;;
		esac
	done < <(_doubling_emit_libs)
	[ -z "$offenders" ] || {
		printf 'expected ecosystem 0.49.2:\n%s' "$offenders" >&2
		return 1
	}
}

# The behavioral tests above prove the resolution is correct today. This one
# stops the re-derivation shape from coming back in a lib the fixture forgot.
@test "no emit lib re-derives an ecosystem root from a glob match" {
	local hits
	hits=$(cd "$REPO_ROOT" && grep -rn 'dirname "\$(dirname' \
		--include="*-emit.sh" --include="*-events.sh" plugins/ || true)
	[ -z "$hits" ] || {
		printf 'emit lib re-derives a root by nested dirname:\n%s\n' "$hits" >&2
		return 1
	}
}
