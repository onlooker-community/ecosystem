#!/usr/bin/env bats

# Covers the resolution loop: a finding whose drift is gone stops rendering.
#
# The record has carried resolved:false since the plugin shipped and nothing
# ever flipped it, so fixing the drift a finding reported did not retire the
# finding — it rendered forever (ecosystem-nhi).
#
# Absence of a finding from a run is the evidence used, which is only sound when
# the run looked everywhere. The guard tests below are the substance of this
# file: getting resolution wrong in the permissive direction silently hides live
# findings, which is worse than the stale ones being retired.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/cartographer-resolve.sh"

	FINDINGS_DIR="${BATS_TEST_TMPDIR}/findings"
	mkdir -p "$FINDINGS_DIR"

	# A fixed clock. Real timestamps are epoch seconds, and an audit that starts
	# and finishes inside one second would otherwise make "before the run" and
	# "during the run" indistinguishable.
	AUDIT_START=2000
}

# Seed a finding record in the shape run_emit writes.
_seed() {
	local hash="$1" last_seen="$2" resolved="${3:-false}"
	jq -n --arg h "$hash" --argjson ls "$last_seen" --argjson r "$resolved" \
		'{finding_hash: $h, type: "undocumented_entity", severity: "warning",
		  file_a: "CLAUDE.md", file_b: null, description: "d", suggested_fix: "f",
		  first_seen_at: 1000, last_seen_at: $ls, resolved: $r}' \
		> "${FINDINGS_DIR}/${hash}.json"
}

_field() {
	jq -r ".$2" "${FINDINGS_DIR}/$1.json"
}

@test "a finding not observed this run is resolved" {
	_seed stale 1500
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0
	[ "$output" = "1" ] || return 1
	[ "$(_field stale resolved)" = "true" ]
}

@test "a finding observed this run is left open" {
	_seed fresh 2500
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0
	[ "$output" = "0" ] || return 1
	[ "$(_field fresh resolved)" = "false" ]
}

@test "resolution stamps resolved_at" {
	_seed stale 1500
	cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0 4242 >/dev/null
	[ "$(_field stale resolved_at)" = "4242" ]
}

# Strict <: a record last seen exactly at the cutoff is ambiguous, and the safe
# reading is that it was observed. A stale finding is visible and correctable;
# one wrongly retired is silent.
@test "a finding last seen exactly at the cutoff is left open" {
	_seed boundary "$AUDIT_START"
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0
	[ "$output" = "0" ] || return 1
	[ "$(_field boundary resolved)" = "false" ]
}

@test "an already-resolved finding is not counted again" {
	_seed old 1500 true
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0
	[ "$output" = "0" ]
}

@test "resolves only the absent findings in a mixed store" {
	_seed gone 1500
	_seed here 2500
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0
	[ "$output" = "1" ] || return 1
	[ "$(_field gone resolved)" = "true" ] || return 1
	[ "$(_field here resolved)" = "false" ]
}

# ── The guards ────────────────────────────────────────────────────────────────

# A targeted post-write audit evaluates one file, so nearly every stored finding
# is absent for reasons unrelated to being fixed. Without this it would wipe the
# store on every edit.
@test "a targeted audit resolves nothing" {
	_seed stale 1500
	run cartographer_resolve_absent_findings \
		"$FINDINGS_DIR" "$AUDIT_START" "/repo/CLAUDE.md" 0
	[ "$output" = "0" ] || return 1
	[ "$(_field stale resolved)" = "false" ]
}

# A phase that timed out contributes no findings, which looks identical to its
# findings being gone. A partial run is not evidence of resolution.
@test "a run with a failed phase resolves nothing" {
	_seed stale 1500
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 1
	[ "$output" = "0" ] || return 1
	[ "$(_field stale resolved)" = "false" ]
}

@test "both guards together still resolve nothing" {
	_seed stale 1500
	run cartographer_resolve_absent_findings \
		"$FINDINGS_DIR" "$AUDIT_START" "/repo/CLAUDE.md" 2
	[ "$output" = "0" ]
}

# ── Reopening ─────────────────────────────────────────────────────────────────

# The dedup sentinel outlives resolution, so reintroduced drift comes back as a
# KNOWN finding, not a new one. If refreshing did not clear resolved, the
# renderer would keep hiding it — live drift, permanently invisible.
@test "re-observing a resolved finding reopens it" {
	_seed recurring 1500 true
	cartographer_refresh_finding "${FINDINGS_DIR}/recurring.json" 3000
	[ "$(_field recurring resolved)" = "false" ] || return 1
	[ "$(_field recurring last_seen_at)" = "3000" ]
}

@test "reopening clears the resolved_at stamp" {
	_seed recurring 1500
	cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0 4242 >/dev/null
	[ "$(_field recurring resolved_at)" = "4242" ] || return 1
	cartographer_refresh_finding "${FINDINGS_DIR}/recurring.json" 5000
	[ "$(_field recurring resolved_at)" = "null" ]
}

@test "a reopened finding is resolvable again once the drift goes" {
	_seed recurring 1500 true
	cartographer_refresh_finding "${FINDINGS_DIR}/recurring.json" 3000
	# A later audit that starts after 3000 and does not observe it.
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" 4000 "" 0
	[ "$output" = "1" ] || return 1
	[ "$(_field recurring resolved)" = "true" ]
}

@test "refresh keeps first_seen_at, so recurrence does not rewrite history" {
	_seed recurring 1500 true
	cartographer_refresh_finding "${FINDINGS_DIR}/recurring.json" 3000
	[ "$(_field recurring first_seen_at)" = "1000" ]
}

@test "refresh rejects missing arguments and absent files" {
	run cartographer_refresh_finding "" 3000
	[ "$status" -ne 0 ] || return 1
	run cartographer_refresh_finding "${FINDINGS_DIR}/nope.json" 3000
	[ "$status" -ne 0 ]
}

# ── Edges ─────────────────────────────────────────────────────────────────────

@test "an empty store resolves nothing" {
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0
	[ "$output" = "0" ]
}

@test "a missing findings dir is not an error" {
	run cartographer_resolve_absent_findings \
		"${BATS_TEST_TMPDIR}/nope" "$AUDIT_START" "" 0
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "0" ]
}

@test "a record with no last_seen_at is treated as unobserved" {
	jq -n '{finding_hash: "bare", resolved: false}' > "${FINDINGS_DIR}/bare.json"
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0
	[ "$output" = "1" ]
}

@test "unparsable json is skipped rather than fatal" {
	printf 'not json at all' > "${FINDINGS_DIR}/broken.json"
	_seed stale 1500
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "1" ]
}

@test "missing required arguments are rejected" {
	run cartographer_resolve_absent_findings "" "$AUDIT_START" "" 0
	[ "$status" -ne 0 ] || return 1
	run cartographer_resolve_absent_findings "$FINDINGS_DIR" "" "" 0
	[ "$status" -ne 0 ]
}

@test "the record keeps its other fields when resolved" {
	_seed stale 1500
	cartographer_resolve_absent_findings "$FINDINGS_DIR" "$AUDIT_START" "" 0 >/dev/null
	jq -e '.finding_hash == "stale" and .type == "undocumented_entity"
	       and .first_seen_at == 1000 and .description == "d"' \
		"${FINDINGS_DIR}/stale.json" >/dev/null
}
