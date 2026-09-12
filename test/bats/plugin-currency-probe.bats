#!/usr/bin/env bats
# Detached currency probe (ecosystem-449.59).
#
# These exist because 13 hook tests missed a bug the first manual run found:
# check-plugin-installs exits 1 WHEN IT HAS FINDINGS, which is a successful
# probe with something to say, and the hook was treating it as a failure. Every
# test here drives the real exit-code contract rather than a stub of our own
# expectations.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
	source "${REPO_ROOT}/scripts/lib/plugin-currency-cache.sh"
	source "${REPO_ROOT}/scripts/lib/plugin-currency-probe.sh"

	# Resolve the real node BEFORE any stub shadows it on PATH. Without this a
	# test that stubs node cannot then use node for anything else -- which is
	# how this very test first "failed", validating the stub's canned output.
	REAL_NODE="$(command -v node)"
	CACHE="${BATS_TEST_TMPDIR}/probe.json"
	STUB="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB"
}

# Stub `node` so it emits $1 on stdout and exits $2, standing in for
# check-plugin-installs without touching the network.
_stub_node() {
	cat >"${STUB}/node" <<STUBEOF
#!/usr/bin/env bash
printf '%s' '$1'
exit $2
STUBEOF
	chmod +x "${STUB}/node"
	export PATH="${STUB}:${PATH}"
}

@test "exit 1 with findings is a SUCCESSFUL probe and the cache is written" {
	_stub_node '{"status":"failed","findings":[{"reason":"clone_behind","marketplace":"onlooker-community"}]}' 1
	plugin_currency_probe_run "$PWD" "$CACHE" 5 onlooker-community
	[ -f "$CACHE" ] || return 1
	jq -e '.findings[0].reason == "clone_behind"' "$CACHE" >/dev/null
}

@test "exit 0 with no findings writes an empty findings array" {
	_stub_node '{"status":"ok","findings":[]}' 0
	plugin_currency_probe_run "$PWD" "$CACHE" 5 onlooker-community
	jq -e '.findings == [] and (.checked_at | length) > 0' "$CACHE" >/dev/null
}

@test "exit 2 is a real failure and leaves the cache untouched" {
	jq -n --arg t "$(relative_iso_days_ago 1)" '{checked_at:$t, findings:[]}' >"$CACHE"
	local before; before=$(jq -r '.checked_at' "$CACHE")
	_stub_node 'check-plugin-installs: unknown argument --nope' 2
	run plugin_currency_probe_run "$PWD" "$CACHE" 5 onlooker-community
	[ "$status" -ne 0 ] || return 1
	[ "$(jq -r '.checked_at' "$CACHE")" = "$before" ]
}

@test "a failure never creates a cache where none existed" {
	_stub_node '' 2
	run plugin_currency_probe_run "$PWD" "$CACHE" 5 onlooker-community
	[ "$status" -ne 0 ] || return 1
	[ ! -f "$CACHE" ]
}

@test "unparseable output is a failure, not an empty findings list" {
	# Exit 0 but garbage on stdout must not be cached as "nothing wrong".
	_stub_node 'not json at all' 0
	run plugin_currency_probe_run "$PWD" "$CACHE" 5 onlooker-community
	[ "$status" -ne 0 ] || return 1
	[ ! -f "$CACHE" ]
}

@test "the cache write is atomic — no temp file survives" {
	_stub_node '{"findings":[]}' 0
	plugin_currency_probe_run "$PWD" "$CACHE" 5 onlooker-community
	run bash -c "ls $(dirname "$CACHE")"
	[[ "$output" != *".tmp"* ]] || return 1
	[ -f "$CACHE" ]
}

# A sample of what check-plugin-installs ACTUALLY emits, copied from a real run
# rather than written to match the schema. The schema wants
# {reason, subject, effective, available} with additionalProperties:false; the
# check emits {plugin, marketplace, head, remoteHead, lastFetchAttempt}. Caching
# the raw shape produced a payload that failed validation invisibly, because the
# runtime emitter fails open without ONLOOKER_VALIDATE=1 (ADR-005).
REAL_CLONE_BEHIND='{"status":"failed","findings":[{"plugin":null,"reason":"clone_behind","marketplace":"onlooker-community","head":"ff773b41c5df2b23bc98e78d6dbaf52fd349cd67","remoteHead":"9bd5a3f949d2e95c7e22a67c8752396f60660f33","lastFetchAttempt":"2026-09-12T15:55:17.739Z"}]}'

REAL_STALE_INSTALL='{"status":"failed","findings":[{"plugin":"mise@meaganewaller-marketplace","reason":"stale_install","effective":"1.1.0","available":"1.1.1","source":"marketplace"}]}'

@test "maps a real clone_behind finding onto the schema shape" {
	_stub_node "$REAL_CLONE_BEHIND" 1
	plugin_currency_probe_run "$PWD" "$CACHE" 5 onlooker-community
	jq -e '.findings[0].subject == "onlooker-community"' "$CACHE" >/dev/null || return 1
	jq -e '.findings[0] | has("marketplace") | not' "$CACHE" >/dev/null || return 1
	jq -e '.findings[0] | has("lastFetchAttempt") | not' "$CACHE" >/dev/null
}

@test "maps a real stale_install finding onto the schema shape" {
	_stub_node "$REAL_STALE_INSTALL" 1
	plugin_currency_probe_run "$PWD" "$CACHE" 5
	jq -e '.findings[0].subject == "mise@meaganewaller-marketplace"' "$CACHE" >/dev/null || return 1
	jq -e '.findings[0].effective == "1.1.0" and .findings[0].available == "1.1.1"' "$CACHE" >/dev/null || return 1
	jq -e '.findings[0] | has("source") | not' "$CACHE" >/dev/null
}

@test "a mapped finding actually validates against the published schema" {
	# The point of the mapping. Validate through the canonical emitter with
	# ONLOOKER_VALIDATE=1 rather than eyeballing keys.
	_stub_node "$REAL_CLONE_BEHIND" 1
	plugin_currency_probe_run "$PWD" "$CACHE" 5 onlooker-community
	local findings; findings=$(jq -c '.findings' "$CACHE")
	local event; event=$(jq -cn --argjson f "$findings" \
		'{plugin:"onlooker", session_id:"t", event_type:"onlooker.currency.stale",
		  payload:{findings_count:($f|length), answer_age_seconds:0, findings:$f}}')
	run bash -c "printf '%s' '$event' | ONLOOKER_DIR='$ONLOOKER_DIR' ONLOOKER_VALIDATE=1 '$REAL_NODE' '${REPO_ROOT}/scripts/lib/onlooker-event.mjs' emit"
	[ "$status" -eq 0 ] || { echo "VALIDATION FAILED: $output" >&2; return 1; }
}
