#!/usr/bin/env bats
#
# What compass does with the model's reply. ONL-36 and ONL-143.
#
# The evaluator forwarded model output into two places that cannot take
# arbitrary strings, and neither was validated:
#
#   primary_concern -> a closed schema enum. An off-enum value makes the payload
#                      invalid, and the emitter fails open (ADR-005), so the
#                      event is SILENTLY DROPPED -- compass denies a write and
#                      the bus has no record it did.
#   score           -> awk. It was interpolated into awk SOURCE, so a crafted
#                      score executed as awk code; and because awk reads a bare
#                      word as an uninitialized variable worth 0, an
#                      unvalidated non-numeric score silently became a 0 sample
#                      and dragged the mean toward a block.
#
# These drive the evaluator through a driver script that sets the same
# `set -uo pipefail` compass's HOOKS set, because the libs carry no `set` line
# of their own -- a bats file that merely sources them runs without set -u. See
# compass-config-int.bats for the full reasoning; the same constraint applies
# here even though these particular defects are not set -u dependent.
#
# compass_evaluate is called with its output redirected to a file rather than
# captured in $(...), so its printed payload can be inspected directly.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/compass"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	export SESSION_ID="test-session-evaluator-output"
	mkdir -p "${ONLOOKER_DIR}/compass/sessions"
	cat > "${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json" <<-EOF
		{
		  "session_id": "${SESSION_ID}",
		  "turn_check_count": 0,
		  "cooldown": [],
		  "circuit_breaker": {"state":"closed","consecutive_failures":0,"opened_at":null}
		}
	EOF

	GATE_CWD="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${GATE_CWD}/.claude"
	LONG_CONTEXT="$(printf 'x%.0s' {1..200})"
	EVAL_OUT="${BATS_TEST_TMPDIR}/eval.json"

	# Where an injected awk system() call would land. Its ABSENCE is the
	# assertion in the injection test.
	INJECTION_MARKER="${BATS_TEST_TMPDIR}/INJECTED"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	# Emits whatever the test puts in STUB_SCORE / STUB_CONCERN, so each case
	# controls exactly what the "model" returned.
	cat > "${STUB_BIN}/claude" <<-'STUB'
		#!/usr/bin/env bash
		cat >/dev/null
		jq -cn --arg s "${STUB_SCORE:-0.9}" --arg c "${STUB_CONCERN:-none}" \
			'{score: $s, primary_concern: $c, one_line_rationale: "stub"}'
	STUB
	chmod +x "${STUB_BIN}/claude"

	DRIVER="${BATS_TEST_TMPDIR}/drive-eval.sh"
	cat > "$DRIVER" <<-'DRV'
		#!/usr/bin/env bash
		set -uo pipefail
		for lib in compass-config compass-events compass-sanitizer \
		           compass-transcript compass-evaluator; do
			# shellcheck disable=SC1090
			source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/${lib}.sh"
		done
		compass_config_load "${GATE_CWD:-}"
		compass_evaluate "Write" "/tmp/subject.txt" "write" \
			"shall I refactor the parser?" "$GATE_CTX" "$SESSION_ID" > "$EVAL_OUT" || true
		printf 'EVAL_REACHED_END\n'
	DRV
	chmod +x "$DRIVER"
}

_evaluate() {
	run env PATH="${STUB_BIN}:${PATH}" \
		CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ONLOOKER_DIR="$ONLOOKER_DIR" HOME="$HOME" \
		SESSION_ID="$SESSION_ID" GATE_CWD="$GATE_CWD" GATE_CTX="$LONG_CONTEXT" \
		EVAL_OUT="$EVAL_OUT" \
		STUB_SCORE="${1:-0.9}" STUB_CONCERN="${2:-none}" \
		bash "$DRIVER"
}

# --- sanity -----------------------------------------------------------------
# Without this, a driver or stub broken for any unrelated reason would make
# every test below fail and look exactly like a missing guard.
@test "a well-formed model reply still produces a usable evaluation" {
	_evaluate 0.9 scope
	[[ "$output" == *"EVAL_REACHED_END"* ]] || return 1
	jq -e '.decision == "pass" and .confidence == 0.9 and .primary_concern == "scope"' \
		"$EVAL_OUT" >/dev/null
}

# --- ONL-36: the enum -------------------------------------------------------

@test "an off-enum primary_concern is clamped to none, not forwarded" {
	# "ambiguous_scope" is the value that surfaced this -- plausible-looking,
	# and not one of the five the schema allows. Forwarded, it makes the payload
	# invalid and the fail-open emitter drops the event entirely.
	_evaluate 0.9 ambiguous_scope
	[[ "$output" == *"EVAL_REACHED_END"* ]] || return 1
	jq -e '.primary_concern == "none"' "$EVAL_OUT" >/dev/null
}

@test "each of the five allowed concerns still passes through unchanged" {
	local c
	for c in scope target context destructive none; do
		_evaluate 0.9 "$c"
		jq -e --arg c "$c" '.primary_concern == $c' "$EVAL_OUT" >/dev/null || {
			echo "concern $c was not preserved"
			return 1
		}
	done
}

# --- ONL-143: the score -----------------------------------------------------

@test "a non-numeric score is discarded, not silently read as zero" {
	# awk assigns a bare word the value 0, so unvalidated this became a 0 sample
	# and dragged the mean toward a block with nothing logged. Discarding is the
	# honest outcome: min_valid_samples already exists to say "too few usable
	# samples", whereas a coerced 0 would be invented data.
	_evaluate high none
	[[ "$output" == *"EVAL_REACHED_END"* ]] || return 1
	jq -e '.error == "insufficient_valid_samples" and .sample_count == 0' \
		"$EVAL_OUT" >/dev/null
}

@test "an out-of-range score is discarded so confidence cannot leave 0..1" {
	# confidence IS the mean, and the schema constrains it to 0..1. A score of 5
	# produced confidence 5.0000, an invalid payload, and another silently
	# dropped event -- ONL-36's complaint by a second route.
	_evaluate 5 none
	[[ "$output" == *"EVAL_REACHED_END"* ]] || return 1
	jq -e '.error == "insufficient_valid_samples"' "$EVAL_OUT" >/dev/null || return 1
	# And nothing out of range leaked into the payload.
	jq -e '.confidence == null or (.confidence >= 0 and .confidence <= 1)' \
		"$EVAL_OUT" >/dev/null
}

@test "a crafted score does not execute as awk code" {
	# The scores were interpolated into awk SOURCE, so this ran. awk offers
	# system(), which makes it command execution rather than stray output.
	# Measured before the fix: the marker file appeared.
	#
	# A harmless touch into the test's own tmpdir, asserted by ABSENCE.
	_evaluate "0; system(\"touch ${INJECTION_MARKER}\")" none
	[[ "$output" == *"EVAL_REACHED_END"* ]] || return 1

	[ ! -f "$INJECTION_MARKER" ] || {
		echo "awk executed model-supplied text: $INJECTION_MARKER was created"
		return 1
	}

	# And the sample was refused rather than coerced to the leading 0.
	jq -e '.error == "insufficient_valid_samples"' "$EVAL_OUT" >/dev/null
}

@test "a decimal with no leading digit is accepted" {
	# ".5" is a plausible thing for a model to emit and is a valid 0..1 score.
	# Pinning it so the validating regex is not tightened into rejecting it.
	_evaluate .5 none
	jq -e '.confidence == 0.5' "$EVAL_OUT" >/dev/null
}
