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
#
# Fixing that ordering added a third defect: cost. The fix compared versions
# pairwise, forking a `printf | sort | tail` for every cached ecosystem, and ran
# it when the lib was sourced rather than when it emitted. With 47 versions
# cached that was ~140ms per hook run, on librarian's and curator's SessionStart
# and on every historian UserPromptSubmit, whether or not anything was emitted,
# and it grew with every release (ONL-271). The libs now defer to the vendored
# substrate-resolve.sh, which orders the whole glob in one sort, and only on
# the first emit.

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
#   <cache>/<plugin>/1.0.0/scripts/lib/            (the plugin's whole lib dir)
#
# so plugin_root/../../ecosystem/* matches exactly as it does on disk. No
# onlooker-event.mjs is placed at <cache>/scripts/lib, so resolution falls
# through the direct-sibling branch and reaches the glob under test. The lib
# dir is copied whole because the emit lib sources the substrate-resolve.sh
# vendored beside it.
#
# Usage: _build_fixture <plugin> [version...]   (prints the cache path)
_build_fixture() {
	local plugin="$1"
	shift
	local cache="${BATS_TEST_TMPDIR}/cache-${plugin}"
	rm -rf "$cache"

	local v
	for v in "$@"; do
		mkdir -p "${cache}/ecosystem/${v}/scripts/lib"
		printf '// ecosystem %s\n' "$v" \
			>"${cache}/ecosystem/${v}/scripts/lib/onlooker-event.mjs"
		# The resolver keys on validate-path.sh, the emit libs on
		# onlooker-event.mjs. Both must be present or the two disagree about
		# which versions exist at all.
		printf '# ecosystem %s\n' "$v" \
			>"${cache}/ecosystem/${v}/scripts/lib/validate-path.sh"
	done

	mkdir -p "${cache}/${plugin}/1.0.0/scripts"
	cp -R "${REPO_ROOT}/plugins/${plugin}/scripts/lib" "${cache}/${plugin}/1.0.0/scripts/lib"
	printf '%s' "$cache"
}

_resolve_against_fixture() {
	local plugin="$1" cache
	cache="$(_build_fixture "$plugin" 0.9.0 0.33.1 0.49.2)"

	(
		unset ONLOOKER_ECOSYSTEM_ROOT
		# shellcheck disable=SC1090
		source "${cache}/${plugin}/1.0.0/scripts/lib/${plugin}-emit.sh" >/dev/null 2>&1
		"_${plugin}_resolve_event_js"
	)
}

# Count the `sort` processes a step starts, against a cache of N versions.
# A logging `sort` shim on PATH stands in for the forks: the defect forked one
# pipeline per cached version, and sort is the one command in every pipeline.
#
# Usage: _sorts_while <plugin> <n-versions> <source|resolve>
_sorts_while() {
	local plugin="$1" n="$2" step="$3" cache i versions=()
	for ((i = 1; i <= n; i++)); do versions+=("0.${i}.0"); done
	cache="$(_build_fixture "$plugin" "${versions[@]}")"

	local shim="${BATS_TEST_TMPDIR}/shim" log="${BATS_TEST_TMPDIR}/sort-calls"
	local real_sort
	real_sort="$(command -v sort)"
	mkdir -p "$shim"
	printf '#!/bin/sh\necho x >>"%s"\nexec "%s" "$@"\n' "$log" "$real_sort" >"${shim}/sort"
	chmod +x "${shim}/sort"
	: >"$log"

	(
		unset ONLOOKER_ECOSYSTEM_ROOT
		lib="${cache}/${plugin}/1.0.0/scripts/lib/${plugin}-emit.sh"
		if [ "$step" = resolve ]; then
			# shellcheck disable=SC1090
			source "$lib" >/dev/null 2>&1
			: >"$log"
			PATH="${shim}:${PATH}" "_${plugin}_resolve_event_js" >/dev/null
		else
			# shellcheck disable=SC1090
			PATH="${shim}:${PATH}" source "$lib" >/dev/null 2>&1
		fi
	)
	wc -l <"$log" | tr -d ' '
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

# The cost half (ONL-271). Sourcing is what every hook pays, emitting or not,
# so it must fork nothing on the cache's behalf.
@test "sourcing an emit lib starts no sort, however many ecosystems are cached" {
	local plugin calls offenders=""
	while IFS= read -r plugin; do
		calls="$(_sorts_while "$plugin" 20 source)"
		[ "$calls" -eq 0 ] || offenders+="${plugin}: ${calls} sorts"$'\n'
	done < <(_doubling_emit_libs)
	[ -z "$offenders" ] || {
		printf 'sourcing forked per cached version:\n%s' "$offenders" >&2
		return 1
	}
}

# Resolving may sort, but once for the whole glob, not once per version. Two
# cache sizes, so a per-version loop cannot pass at either.
@test "resolving the emitter starts the same number of sorts at 2 and 20 cached ecosystems" {
	local plugin few many offenders=""
	while IFS= read -r plugin; do
		few="$(_sorts_while "$plugin" 2 resolve)"
		many="$(_sorts_while "$plugin" 20 resolve)"
		if [ "$many" -ne "$few" ] || [ "$many" -gt 1 ]; then
			offenders+="${plugin}: ${few} sorts at 2, ${many} at 20"$'\n'
		fi
	done < <(_doubling_emit_libs)
	[ -z "$offenders" ] || {
		printf 'resolution scales with the cache:\n%s' "$offenders" >&2
		return 1
	}
}

# Deferring resolution to the first emit must not lose the events. Drives the
# real emitter through each lib from an installed-layout tree, with the repo
# linked in as the only cached ecosystem.
_probe_event() {
	case "$1" in
	librarian) printf '%s\t%s' librarian.scan.started '{"trigger":"session_end"}' ;;
	curator) printf '%s\t%s' curator.scan.started '{"mode":"cheap"}' ;;
	historian) printf '%s\t%s' historian.embedder.unavailable '{"backend":"ollama"}' ;;
	esac
}

@test "every emit lib still emits after resolving lazily" {
	local plugin cache probe log offenders=""
	log="${ONLOOKER_DIR}/logs/lazy-probe.jsonl"
	mkdir -p "$(dirname "$log")"
	while IFS= read -r plugin; do
		cache="${BATS_TEST_TMPDIR}/installed-${plugin}"
		rm -rf "$cache"
		mkdir -p "${cache}/ecosystem" "${cache}/${plugin}/1.0.0/scripts"
		ln -s "$REPO_ROOT" "${cache}/ecosystem/9.9.9"
		cp -R "${REPO_ROOT}/plugins/${plugin}/scripts/lib" "${cache}/${plugin}/1.0.0/scripts/lib"
		probe="$(_probe_event "$plugin")"
		: >"$log"
		(
			unset ONLOOKER_ECOSYSTEM_ROOT
			export ONLOOKER_EVENTS_LOG="$log"
			# shellcheck disable=SC1090
			source "${cache}/${plugin}/1.0.0/scripts/lib/${plugin}-emit.sh"
			"${plugin}_emit" "${probe%%$'\t'*}" "sess-lazy" "${probe#*$'\t'}"
		)
		grep -q "\"event_type\":\"${probe%%$'\t'*}\"" "$log" ||
			offenders+="${plugin}"$'\n'
	done < <(_doubling_emit_libs)
	[ -z "$offenders" ] || {
		printf 'emitted nothing after lazy resolution:\n%s' "$offenders" >&2
		return 1
	}
}

# The behavioral tests prove these four libs are right today. This stops a
# fifth from growing its own walk of the cache: substrate-resolve.sh is the
# one place that orders it, and every vendored copy is byte-identical.
@test "no plugin lib walks the ecosystem cache except substrate-resolve.sh" {
	local hits
	hits=$(cd "$REPO_ROOT" && grep -rln 'ecosystem/"\*' --include='*.sh' plugins/*/scripts |
		grep -v '/substrate-resolve\.sh$' || true)
	[ -z "$hits" ] || {
		printf 'walks the ecosystem cache by hand; call onlooker_resolve_substrate:\n%s\n' "$hits" >&2
		return 1
	}
}
