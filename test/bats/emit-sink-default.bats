#!/usr/bin/env bats
#
# Guards the event sink default across the emit family.
#
# Thirteen plugins reach the log through a *-events.sh library that defaults
# the sink: archivist-events.sh:91 writes to
# ${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}.
# Three reach it through an older *-emit.sh lineage -- librarian, curator and
# historian -- which instead guarded on `[[ -z "${ONLOOKER_EVENTS_LOG:-}" ]] &&
# return 0` and wrote to the bare variable. Those three are the same three that
# carried the doubled-path defect (ecosystem-449.34): one lineage, diverged
# twice from the shape the other thirteen use.
#
# The sink is exported by validate-path.sh:35, which a hook sources out of the
# ecosystem substrate. So the bail made substrate resolution load-bearing for
# emission a second time, after the -f guard already covered it -- and turned
# every substrate defect from "misconfigured" into "silent". librarian, curator
# and historian each emitted their last event at 2026-08-03T21:25:45 and every
# health instrument stayed green, because fail-soft cannot tell "nothing to
# emit" from "nowhere to write it".
#
# MEASURED against the repo copy before the fix: substrate resolves, the file
# exists, librarian_emit returns 0, and nothing is written. The identical call
# with ONLOOKER_EVENTS_LOG exported writes a valid schema_version 1.0 event.
# Same function, same arguments; only the sink differs.
#
# Note what let this survive: every existing events test exports
# ONLOOKER_EVENTS_LOG in setup (echo-events.bats:12 and its siblings), so the
# unset case -- the one production actually hits when the substrate is missing
# -- was never exercised. These tests deliberately leave it unset.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# setup_test_env already unsets ONLOOKER_EVENTS_LOG and points ONLOOKER_DIR
	# at the isolated temp home. Leave the sink unset: that is the condition
	# under test, and exporting it here would restore the blind spot above.
	export CLAUDE_SESSION_ID="bats-session-$$"
}

# plugin|event_type|payload. One real event type per plugin, with a payload
# copied from that plugin's own call site so validation exercises the shape
# production emits.
_emit_cases() {
	cat <<-'CASES'
		librarian|librarian.scan.started|{"trigger":"session_end","artifact_count_in_window":0}
		curator|curator.scan.started|{"mode":"cheap"}
		historian|historian.indexing.started|{"session_id":"bats-sid","transcript_chars":4096}
	CASES
}

# Source the plugin's emit lib and emit one event with the sink unset. The
# plugin lives at plugins/<name>, so plugin_root/../.. is the repo root and
# resolution takes the direct-sibling branch to scripts/lib/onlooker-event.mjs.
_emit_with_sink_unset() {
	local plugin="$1" event_type="$2" payload="$3"
	(
		unset ONLOOKER_EVENTS_LOG
		# shellcheck disable=SC1090
		source "${REPO_ROOT}/plugins/${plugin}/scripts/lib/${plugin}-emit.sh"
		"${plugin}_emit" "$event_type" "bats-sid" "$payload"
	)
}

# Without this, a typo in _emit_cases would make every test below pass over an
# empty list and report coverage that does not exist.
@test "every plugin named in the emit cases has the lib and function it names" {
	local plugin
	while IFS='|' read -r plugin _ _; do
		[ -f "${REPO_ROOT}/plugins/${plugin}/scripts/lib/${plugin}-emit.sh" ]
		grep -q "^${plugin}_emit() {" \
			"${REPO_ROOT}/plugins/${plugin}/scripts/lib/${plugin}-emit.sh"
	done < <(_emit_cases)
	[ "$(_emit_cases | wc -l | tr -d ' ')" -eq 3 ]
}

@test "every emit lib writes to the default sink when ONLOOKER_EVENTS_LOG is unset" {
	local plugin event_type payload default_sink offenders=""
	default_sink="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

	while IFS='|' read -r plugin event_type payload; do
		rm -f "$default_sink"
		_emit_with_sink_unset "$plugin" "$event_type" "$payload"
		if ! grep -q "\"event_type\":\"${event_type}\"" "$default_sink" 2>/dev/null; then
			offenders+="${plugin} wrote nothing to ${default_sink}"$'\n'
		fi
	done < <(_emit_cases)

	[ -z "$offenders" ] || {
		printf 'emit dropped the event with the sink unset:\n%s' "$offenders" >&2
		return 1
	}
}

@test "events written to the default sink validate against the schema" {
	local plugin event_type payload last
	local default_sink="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

	while IFS='|' read -r plugin event_type payload; do
		rm -f "$default_sink"
		_emit_with_sink_unset "$plugin" "$event_type" "$payload"
		last=$(tail -n 1 "$default_sink")
		[ -n "$last" ]
		printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
			node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
	done < <(_emit_cases)
}

# An explicit sink still wins. The default is a fallback, not a redirect: hooks
# and tests that export ONLOOKER_EVENTS_LOG must keep landing where they say.
@test "an exported ONLOOKER_EVENTS_LOG still wins over the default" {
	local plugin event_type payload
	local explicit="${ONLOOKER_DIR}/logs/explicit-sink.jsonl"
	local default_sink="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

	while IFS='|' read -r plugin event_type payload; do
		rm -f "$explicit" "$default_sink"
		(
			export ONLOOKER_EVENTS_LOG="$explicit"
			# shellcheck disable=SC1090
			source "${REPO_ROOT}/plugins/${plugin}/scripts/lib/${plugin}-emit.sh"
			"${plugin}_emit" "$event_type" "bats-sid" "$payload"
		)
		grep -q "\"event_type\":\"${event_type}\"" "$explicit"
		[ ! -f "$default_sink" ]
	done < <(_emit_cases)
}

# The behavioral tests above prove the three named libs default their sink.
# This one stops the bail from returning in a lib the cases forgot -- including
# a plugin added after this file was written.
@test "no emit lib in the family bails on an unset sink" {
	local hits
	hits=$(cd "$REPO_ROOT" && grep -rn 'ONLOOKER_EVENTS_LOG:-}" \]\] && return 0' \
		--include="*-emit.sh" --include="*-events.sh" plugins/ || true)
	[ -z "$hits" ] || {
		printf 'emit lib returns early when the sink is unset:\n%s\n' "$hits" >&2
		return 1
	}
}
