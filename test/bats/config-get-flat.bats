#!/usr/bin/env bats

# config_get answers a plain path (.a.b.c) from a flat table that
# config_load_plugin builds in the same jq that merges the layers, instead of
# starting a jq per read (ONL-292). Every test here holds the table to one
# standard: config_get must print exactly what the jq it replaced would print,
# and fail exactly when that jq would fail.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/scripts/lib/config-loader.sh"
	FX_ROOT="${BATS_TEST_TMPDIR}/fx-plugin"
	mkdir -p "$FX_ROOT"
}

# What config_get printed before the table: jq -r on the path, with a JSON null
# mapped to "", and jq's own exit status.
_ref() {
	local v
	v=$(printf '%s' "${!1}" | jq -r "$2" 2>/dev/null) || return 1
	[[ "$v" == "null" ]] && v=""
	printf '%s' "$v"
}

# Usage: _compare <config_var> <path>...
# Prints one line per path where config_get and the reference disagree.
_compare() {
	local var="$1" p a b as bs
	shift
	for p in "$@"; do
		a=$(config_get "$var" "$p"); as=$?
		b=$(_ref "$var" "$p"); bs=$?
		if [[ "$a" != "$b" || "$as" -ne "$bs" ]]; then
			printf '%s: config_get[%s]=%q jq[%s]=%q\n' "$p" "$as" "$a" "$bs" "$b"
		fi
	done
}

# Every plain path in the merged config, plus a missing key under each and a
# missing key two levels down: a missing key under an object reads as null,
# under a scalar jq errors, and under an array jq indexes.
_probe_paths() {
	local p
	while IFS= read -r p; do
		printf '%s\n%s\n%s\n' "$p" "${p}.zz_missing" "${p}.zz_missing.deeper"
	done < <(printf '%s' "${!1}" | jq -r '
		paths
		| select(all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")))
		| "." + join(".")')
	printf '%s\n' ".zz_missing" ".zz_missing.deeper"
}

_load_fixture() {
	printf '%s' "$1" >"${FX_ROOT}/config.json"
	CLAUDE_PLUGIN_ROOT="$FX_ROOT" config_load_plugin fx "" FXCFG
}

@test "config_get agrees with jq on every path of every shipped config" {
	local d name diffs="" paths=()
	for d in "${REPO_ROOT}"/plugins/*/ "${REPO_ROOT}/"; do
		[[ -f "${d}config.json" ]] || continue
		name=$(basename "$d")
		CLAUDE_PLUGIN_ROOT="${d%/}" config_load_plugin "$name" "" SHIPPED
		paths=()
		while IFS= read -r p; do paths+=("$p"); done < <(_probe_paths SHIPPED)
		diffs+=$(_compare SHIPPED "${paths[@]}")
	done
	[ -z "$diffs" ] || { printf '%s\n' "$diffs"; return 1; }
}

@test "config_get agrees with jq on values a line-oriented table cannot hold" {
	_load_fixture '{"fx": {
		"int": 100, "exp": 1e3, "float": 1.0, "negzero": -0, "big": 12345678901234567890,
		"t": true, "f": false, "nul": null, "nullstr": "null", "empty": "",
		"tab": "a\tb", "nl": "a\nb", "cr": "a\rb", "accent": "héllo", "emoji": "🙂",
		"spaces": "  padded  ", "marker1": "\u0001", "marker2": "\u0002",
		"arr": [1, 2], "objarr": [{"a": 1}], "nested": {"deep": {"leaf": "x"}},
		"dash-key": {"inner": 1}, "emptyobj": {}
	}}'
	local paths=()
	while IFS= read -r p; do paths+=("$p"); done < <(_probe_paths FXCFG)
	paths+=(".fx.dash" ".fx.arr.x" ".fx.nested.deep.leaf.more")
	local diffs
	diffs=$(_compare FXCFG "${paths[@]}")
	[ -z "$diffs" ] || { printf '%s\n' "$diffs"; return 1; }
}

@test "a plain path is answered without starting jq" {
	_load_fixture '{"fx": {"a": {"b": "hit"}}}'
	local shim="${BATS_TEST_TMPDIR}/shim" real
	real=$(command -v jq)
	mkdir -p "$shim"
	cat >"${shim}/jq" <<SHIM
#!/usr/bin/env bash
printf 'x\n' >>"${BATS_TEST_TMPDIR}/jq-starts"
exec "$real" "\$@"
SHIM
	chmod +x "${shim}/jq"
	local v missing
	v=$(PATH="${shim}:${PATH}" config_get FXCFG '.fx.a.b')
	missing=$(PATH="${shim}:${PATH}" config_get FXCFG '.fx.a.nope')
	[ "$v" = "hit" ] || return 1
	[ -z "$missing" ] || return 1
	[ ! -e "${BATS_TEST_TMPDIR}/jq-starts" ]
}

@test "a config variable reassigned after loading is read with jq, not the stale table" {
	_load_fixture '{"fx": {"a": "loaded"}}'
	FXCFG='{"fx": {"a": "reassigned"}}'
	[ "$(config_get FXCFG '.fx.a')" = "reassigned" ]
}

@test "a config variable set without loading is read with jq" {
	# shellcheck disable=SC2034
	NEVERLOADED='{"fx": {"a": "direct", "f": false}}'
	[ "$(config_get NEVERLOADED '.fx.a')" = "direct" ] || return 1
	[ "$(config_get NEVERLOADED '.fx.f')" = "false" ]
}

@test "the merged JSON is unchanged by the table, in a C and a UTF-8 locale" {
	# The loader cuts the table out of jq's output by character offset, which is
	# only sound because the table is ASCII. Non-ASCII content in the JSON
	# after it must come through intact either way.
	printf '%s' '{"fx": {"accent": "héllo", "n": 1e3, "o": {"k": "v"}}}' >"${FX_ROOT}/config.json"
	local want loc got
	want=$(jq -n --slurpfile c "${FX_ROOT}/config.json" '$c[0]')
	for loc in C en_US.UTF-8; do
		got=$(LC_ALL="$loc" bash -c '
			source "$1"
			CLAUDE_PLUGIN_ROOT="$2" config_load_plugin fx "" CFG
			printf "%s\n%s\n%s" "$CFG" "$(config_get CFG .fx.accent)" "$(config_get CFG .fx.o.k)"
		' _ "${REPO_ROOT}/scripts/lib/config-loader.sh" "$FX_ROOT")
		[ "$got" = "${want}"$'\n'"héllo"$'\n'"v" ] || { printf '%s: %q\n' "$loc" "$got"; return 1; }
	done
}

@test "a config whose defaults do not parse reads every path as empty" {
	printf '{not json' >"${FX_ROOT}/config.json"
	CLAUDE_PLUGIN_ROOT="$FX_ROOT" config_load_plugin fx "" FXCFG
	[ "$(config_get FXCFG '.fx.a')" = "" ] || return 1
	[ "$(_ref FXCFG '.fx.a')" = "" ]
}
