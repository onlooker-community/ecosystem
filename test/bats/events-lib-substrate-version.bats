#!/usr/bin/env bats
#
# Guards which ecosystem the per-plugin events libs emit THROUGH.
#
# Each `<plugin>-events.sh` locates the ecosystem's onlooker-event.mjs, and the
# last resort is a glob over the shared plugin cache. Glob expansion is
# lexicographic rather than semver, so `0.33.1` sorts ahead of `0.49.2` and a
# return-on-first-hit binds the oldest cached ecosystem (ecosystem-449.35).
#
# This is the quiet half of the pair fixed in ecosystem-449.36. There the
# derivation was also doubled, so nothing resolved and emission stopped dead.
# Here the path is correct, so events land, schema validation passes, and
# hook-health stays green — while the emission runs through whatever semantics
# a months-old substrate had. Measured on a real cache: first lexical match
# 0.33.1, newest 0.49.6, the two copies of onlooker-event.mjs 88 diff-lines
# apart, and both stamping schema_version 1.0 so nothing downstream flags it.
#
# The fixture pins three versions where lexical and version order disagree in
# BOTH directions — lexically 0.33.1 < 0.49.2 < 0.9.0, but 0.49.2 is highest —
# so neither `head -1` nor `tail -1` can pass by accident.
#
# The population is derived from the tree rather than listed, so a plugin added
# later is covered without anyone remembering to add it here.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

# Every plugin whose events lib resolves the substrate for itself.
#
# Keyed on the resolution FUNCTION, not on the glob it used to contain. An
# earlier draft derived the population from the glob pattern — which this
# change removes — so the list emptied itself the moment the fix landed and
# every behavioral test below started passing over nothing. The count
# assertion in the first test is what caught that, and is why it is here.
_events_lib_plugins() {
	local f plugin
	for f in "${REPO_ROOT}"/plugins/*/scripts/lib/*-events.sh; do
		[ -f "$f" ] || continue
		plugin="$(basename "$(dirname "$(dirname "$(dirname "$f")")")")"
		grep -q "^_${plugin}_event_js_path()" "$f" || continue
		printf '%s\n' "$plugin"
	done
}

# Build a plugin cache mirroring the real installed layout:
#
#   <cache>/ecosystem/<v>/scripts/lib/onlooker-event.mjs
#   <cache>/<plugin>/1.0.0/...           (the whole plugin tree)
#
# so plugin_root/../../ecosystem/* matches exactly as it does on disk. The
# plugin is copied whole rather than file-by-file because these libs source
# their siblings, and a partial copy would fail for reasons unrelated to the
# defect under test.
_resolve_against_fixture() {
	local plugin="$1"
	local cache="${BATS_TEST_TMPDIR}/cache-${plugin}"
	rm -rf "$cache"

	local v
	for v in 0.9.0 0.33.1 0.49.2; do
		mkdir -p "${cache}/ecosystem/${v}/scripts/lib"
		printf '// ecosystem %s\n' "$v" \
			>"${cache}/ecosystem/${v}/scripts/lib/onlooker-event.mjs"
		# The resolver keys on validate-path.sh, the events libs on
		# onlooker-event.mjs. Both must be present or the two disagree about
		# which versions exist at all.
		printf '# ecosystem %s\n' "$v" \
			>"${cache}/ecosystem/${v}/scripts/lib/validate-path.sh"
	done

	mkdir -p "${cache}/${plugin}"
	cp -R "${REPO_ROOT}/plugins/${plugin}" "${cache}/${plugin}/1.0.0"

	(
		unset ONLOOKER_ECOSYSTEM_ROOT
		unset _ONLOOKER_EVENT_JS
		export CLAUDE_PLUGIN_ROOT="${cache}/${plugin}/1.0.0"
		# shellcheck disable=SC1090
		source "${cache}/${plugin}/1.0.0/scripts/lib/${plugin}-events.sh" >/dev/null 2>&1
		"_${plugin}_event_js_path"
	)
}

# Without this, a broken derivation would make every test below pass over an
# empty list and report coverage that does not exist.
@test "the derived events-lib population is non-empty and every entry resolves" {
	local plugin count=0
	while IFS= read -r plugin; do
		[ -n "$plugin" ] || continue
		[ -f "${REPO_ROOT}/plugins/${plugin}/scripts/lib/${plugin}-events.sh" ]
		count=$((count + 1))
	done < <(_events_lib_plugins)
	[ "$count" -ge 12 ]
}

@test "every events lib resolves to a substrate file that exists" {
	local plugin resolved offenders=""
	while IFS= read -r plugin; do
		[ -n "$plugin" ] || continue
		resolved="$(_resolve_against_fixture "$plugin")"
		if [ ! -f "$resolved" ]; then
			offenders+="${plugin} -> ${resolved}"$'\n'
		fi
	done < <(_events_lib_plugins)
	[ -z "$offenders" ] || {
		printf 'unresolvable substrate path:\n%s' "$offenders" >&2
		return 1
	}
}

@test "every events lib binds the highest version, not the lexically first" {
	local plugin resolved offenders=""
	while IFS= read -r plugin; do
		[ -n "$plugin" ] || continue
		resolved="$(_resolve_against_fixture "$plugin")"
		case "$resolved" in
		*/ecosystem/0.49.2/scripts/lib/onlooker-event.mjs) ;;
		*) offenders+="${plugin} -> ${resolved}"$'\n' ;;
		esac
	done < <(_events_lib_plugins)
	[ -z "$offenders" ] || {
		printf 'expected ecosystem 0.49.2:\n%s' "$offenders" >&2
		return 1
	}
}

# The behavioral tests above prove today's resolution is correct. This one
# stops the shape from coming back in a lib the sweep forgot — which is how
# thirteen copies of it accumulated. Any file that walks the ecosystem glob
# must also order the matches; taking whichever the shell hands over first is
# the defect itself.
@test "no lib takes the first match from the ecosystem glob without ordering it" {
	local f offenders="" rel
	for f in "${REPO_ROOT}"/plugins/*/scripts/lib/*.sh; do
		[ -f "$f" ] || continue
		grep -q 'ecosystem/"\*/' "$f" || continue
		grep -qE 'sort -V|sort -t\.|onlooker_resolve_substrate' "$f" && continue
		rel="${f#"${REPO_ROOT}/"}"
		offenders+="${rel}"$'\n'
	done
	[ -z "$offenders" ] || {
		printf 'walks the ecosystem glob with no version ordering:\n%s' "$offenders" >&2
		return 1
	}
}
