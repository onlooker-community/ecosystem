#!/usr/bin/env bats
#
# ONL-132 / ecosystem-ac8r8d.3 — compass, the last plugin in the migration.
#
# All seven values used the ${v:-N} idiom, which substitutes only when the
# value is EMPTY. Any other non-numeric value passed through to (( )) — and to
# [[ -le ]], which evaluates its operands arithmetically too — where bash reads
# a bare word as a VARIABLE NAME and set -u stops the shell.
#
# WHY THIS FILE EXISTS RATHER THAN TESTS IN compass-gate.bats.
#
# compass's libs carry no `set` line of their own; set -uo pipefail lives in its
# four HOOKS. Every existing compass bats file sources the libs directly, so the
# gate runs there WITHOUT set -u — which means the unbound-variable abort cannot
# happen and a test written that way passes against unguarded code no matter
# what fixture it uses. That trap cost two vacuous tests on counsel before it
# was understood (see the ecosystem-ac8r8d.3 notes).
#
# So every test here drives the gate through $DRIVER, a real script that sets
# the same strict mode the hooks do. The observable is the GATE_REACHED_END
# sentinel the driver prints after compass_run_gate returns: an aborted gate
# never gets there. Exit status is useless — the driver exits 0 either way,
# because set -u without -e leaves the last completed command's status behind.
#
# Fixtures use "unlimited", never a digit-leading value like "120s". Digit-
# leading hits the milder mode — bash reports "value too great for base", the
# comparison merely returns non-zero, and the gate SURVIVES with the comparison
# silently wrong — so such a fixture passes against unfixed code. That mode is
# covered at the accessor in config-get-int.bats.
#
# Each test also seeds whatever state its check needs. Several of these values
# sit behind a condition — the cooldown comparison only runs when a matching
# cooldown entry exists, and open_duration_seconds only when the circuit is
# already open — so without that seeding the test would execute none of the
# code it names. That is the second trap from the same notes.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/compass"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	export SESSION_ID="test-session-config-int"
	STATE_DIR="${ONLOOKER_DIR}/compass/sessions"
	STATE_FILE="${STATE_DIR}/${SESSION_ID}.json"
	mkdir -p "$STATE_DIR"
	cat > "$STATE_FILE" <<-EOF
		{
		  "session_id": "${SESSION_ID}",
		  "turn_check_count": 0,
		  "cooldown": [],
		  "circuit_breaker": {"state":"closed","consecutive_failures":0,"opened_at":null}
		}
	EOF

	SETTINGS_DIR="${BATS_TEST_TMPDIR}/repo/.claude"
	mkdir -p "$SETTINGS_DIR"
	GATE_CWD="${BATS_TEST_TMPDIR}/repo"

	LONG_CONTEXT="$(printf 'x%.0s' {1..200})"

	# The driver. set -uo pipefail here is the whole point of the file: it is
	# what the hooks do and what the libs do not.
	DRIVER="${BATS_TEST_TMPDIR}/drive-gate.sh"
	cat > "$DRIVER" <<'DRV'
#!/usr/bin/env bash
set -uo pipefail
for lib in compass-config compass-events compass-sanitizer \
           compass-transcript compass-evaluator compass-gate; do
	# shellcheck disable=SC1090
	source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/${lib}.sh"
done

compass_config_load "${GATE_CWD:-}"

# Re-stubbed AFTER sourcing, because compass-evaluator.sh defines the real one
# and it shells out to `claude -p`. Tests that need the evaluator's own config
# reads stub the claude CLI instead and leave this alone.
if [[ "${STUB_EVALUATE:-1}" == "1" ]]; then
	compass_evaluate() {
		printf '{"decision":"pass","confidence":0.95,"stddev":0.03,"primary_concern":"none","rationale":"stub","sample_count":5}'
		return 0
	}
fi

compass_run_gate "Write" "$GATE_PATH" "write" "$GATE_CTX" "$SESSION_ID" "" "" || true
printf 'GATE_REACHED_END\n'
DRV
	chmod +x "$DRIVER"
}

_drive() {
	run env \
		CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
		ONLOOKER_DIR="$ONLOOKER_DIR" \
		HOME="$HOME" \
		SESSION_ID="$SESSION_ID" \
		GATE_CWD="$GATE_CWD" \
		GATE_PATH="${1:-/tmp/subject.txt}" \
		GATE_CTX="${2:-$LONG_CONTEXT}" \
		STUB_EVALUATE="${3:-1}" \
		bash "$DRIVER"
}

_settings() { printf '%s\n' "$1" > "${SETTINGS_DIR}/settings.json"; }

# --- sanity: the driver itself reaches the end on a clean config -------------
# Without this, a driver broken for any unrelated reason would make every test
# below fail for the wrong reason and look like the guard was missing.
@test "the strict-mode driver reaches the end with valid config" {
	_settings '{"compass":{}}'
	_drive
	[[ "$output" == *"GATE_REACHED_END"* ]] || return 1
}

# --- always-reached comparisons ---------------------------------------------

@test "a non-numeric max_checks_per_turn does not kill the gate" {
	_settings '{"compass":{"max_checks_per_turn":"unlimited"}}'
	_drive
	[[ "$output" == *"GATE_REACHED_END"* ]] || {
		echo "gate died at the turn-budget comparison"
		return 1
	}
}

@test "a non-numeric min_context_chars does not kill the gate" {
	_settings '{"compass":{"min_context_chars":"unlimited"}}'
	_drive
	[[ "$output" == *"GATE_REACHED_END"* ]] || {
		echo "gate died at the context-minimum comparison"
		return 1
	}
}

# --- comparisons behind seeded state ----------------------------------------

@test "a non-numeric cooldown.seconds does not kill the gate" {
	# The [[ "$age" -le "$cooldown_seconds" ]] comparison runs ONLY when a
	# cooldown entry matches this file's dir+stem identity. With the empty
	# cooldown[] the setup seeds, _compass_in_cooldown returns before comparing
	# anything and this test would execute none of the code it names.
	local identity
	identity=$(dirname /tmp/cooled/subject.txt)/$(basename /tmp/cooled/subject.txt .txt)
	jq --arg id "$identity" --argjson ts "$(date +%s)" \
		'.cooldown = [{identity:$id, ts:$ts}]' "$STATE_FILE" > "${STATE_FILE}.new"
	mv "${STATE_FILE}.new" "$STATE_FILE"

	_settings '{"compass":{"cooldown":{"seconds":"unlimited"}}}'
	_drive "/tmp/cooled/subject.txt"
	[[ "$output" == *"GATE_REACHED_END"* ]] || {
		echo "gate died at the cooldown comparison"
		return 1
	}
}

@test "a non-numeric circuit_breaker.open_duration_seconds does not kill the gate" {
	# open_duration_seconds is read inside the `cb_state == "open"` branch, so
	# the circuit has to actually be open or the read never happens.
	jq --argjson now "$(date +%s)" \
		'.circuit_breaker = {state:"open", consecutive_failures:3, opened_at:$now}' \
		"$STATE_FILE" > "${STATE_FILE}.new"
	mv "${STATE_FILE}.new" "$STATE_FILE"

	_settings '{"compass":{"circuit_breaker":{"enabled":true,"open_duration_seconds":"unlimited"}}}'
	_drive
	[[ "$output" == *"GATE_REACHED_END"* ]] || {
		echo "gate died at the circuit-breaker TTL comparison"
		return 1
	}
}

# --- the evaluator's two values ---------------------------------------------
#
# These need a SECOND driver, because the gate calls the evaluator as
# `eval_result=$(compass_evaluate ...)` — a command substitution. set -u kills
# only the subshell there, so the gate survives with an empty result and
# GATE_REACHED_END prints either way: the sentinel above is vacuous for these
# two. (Verified mechanism, same as historian's embedder.)
#
# So the evaluator driver calls compass_evaluate with its output REDIRECTED to a
# file rather than captured in $(...), which is what makes the abort reach the
# driver and the sentinel meaningful again. The containment in the real gate is
# a mitigation worth knowing about, not a reason to leave the read unguarded —
# unguarded, the evaluation silently returns nothing and the gate reads that as
# decision "error".
_write_eval_driver() {
	EVAL_DRIVER="${BATS_TEST_TMPDIR}/drive-eval.sh"
	cat > "$EVAL_DRIVER" <<'DRV'
#!/usr/bin/env bash
set -uo pipefail
for lib in compass-config compass-events compass-sanitizer \
           compass-transcript compass-evaluator; do
	# shellcheck disable=SC1090
	source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/${lib}.sh"
done
compass_config_load "${GATE_CWD:-}"
# NOT $(...) — see the comment in the bats file.
compass_evaluate "Write" "/tmp/subject.txt" "write" \
	"shall I refactor the parser?" "$GATE_CTX" "$SESSION_ID" > "$EVAL_OUT" || true
printf 'EVAL_REACHED_END\n'
DRV
	chmod +x "$EVAL_DRIVER"
}

# $1 = "valid" to return a scorable response, anything else for garbage.
_stub_claude() {
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	CLAUDE_TALLY="${BATS_TEST_TMPDIR}/claude-calls"
	: > "$CLAUDE_TALLY"
	mkdir -p "$STUB_BIN"
	if [[ "${1:-valid}" == "valid" ]]; then
		cat > "${STUB_BIN}/claude" <<-STUB
			#!/usr/bin/env bash
			cat >/dev/null
			printf 'x\n' >> "$CLAUDE_TALLY"
			printf '{"score":0.9,"primary_concern":"none","one_line_rationale":"stub"}'
		STUB
	else
		# No .score, so every sample is discarded and valid_count reaches 0 —
		# which is what drives execution INTO the min_valid comparison.
		cat > "${STUB_BIN}/claude" <<-STUB
			#!/usr/bin/env bash
			cat >/dev/null
			printf 'x\n' >> "$CLAUDE_TALLY"
			printf '{"not_a_score":true}'
		STUB
	fi
	chmod +x "${STUB_BIN}/claude"
}

@test "a non-numeric evaluator.n does not kill the evaluator" {
	_write_eval_driver
	_stub_claude valid
	_settings '{"compass":{"evaluator":{"n":"unlimited"}}}'
	EVAL_OUT="${BATS_TEST_TMPDIR}/eval.json"

	run env PATH="${STUB_BIN}:${PATH}" \
		CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ONLOOKER_DIR="$ONLOOKER_DIR" HOME="$HOME" \
		SESSION_ID="$SESSION_ID" GATE_CWD="$GATE_CWD" GATE_CTX="$LONG_CONTEXT" \
		EVAL_OUT="$EVAL_OUT" bash "$EVAL_DRIVER"

	[[ "$output" == *"EVAL_REACHED_END"* ]] || {
		echo "evaluator died at the sampling loop"
		return 1
	}

	# Falls back to the shipped 5 rather than to 0: a 0-sample fallback would
	# collect nothing and report every write as insufficient-samples, trading a
	# silent death for a gate that always errors. The stub tally is the only way
	# to see which happened.
	[ "$(wc -l < "$CLAUDE_TALLY" | tr -d ' ')" -eq 5 ]
}

@test "a non-numeric evaluator.min_valid_samples does not kill the evaluator" {
	_write_eval_driver
	_stub_claude garbage
	_settings '{"compass":{"evaluator":{"min_valid_samples":"unlimited"}}}'
	EVAL_OUT="${BATS_TEST_TMPDIR}/eval.json"

	run env PATH="${STUB_BIN}:${PATH}" \
		CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ONLOOKER_DIR="$ONLOOKER_DIR" HOME="$HOME" \
		SESSION_ID="$SESSION_ID" GATE_CWD="$GATE_CWD" GATE_CTX="$LONG_CONTEXT" \
		EVAL_OUT="$EVAL_OUT" bash "$EVAL_DRIVER"

	[[ "$output" == *"EVAL_REACHED_END"* ]] || {
		echo "evaluator died at the valid-sample comparison"
		return 1
	}

	# Every sample was unscorable, so the comparison is reached and the printed
	# payload carries the threshold it used. 3 is the shipped default.
	jq -e '.error == "insufficient_valid_samples" and .min_valid_samples == 3' \
		"$EVAL_OUT" >/dev/null
}

@test "a non-numeric circuit_breaker.consecutive_failures_to_open does not kill the gate" {
	# This one IS in the gate's main shell, so the gate sentinel works — but it
	# only runs on the post-evaluation error path. Reaching it needs a real
	# evaluation that fails, hence STUB_EVALUATE=0 plus a claude stub that
	# returns nothing scorable.
	_stub_claude garbage
	_settings '{"compass":{"circuit_breaker":{"enabled":true,"consecutive_failures_to_open":"unlimited"}}}'

	run env PATH="${STUB_BIN}:${PATH}" \
		CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ONLOOKER_DIR="$ONLOOKER_DIR" HOME="$HOME" \
		SESSION_ID="$SESSION_ID" GATE_CWD="$GATE_CWD" \
		GATE_PATH="/tmp/cb-subject.txt" GATE_CTX="$LONG_CONTEXT" \
		STUB_EVALUATE=0 bash "$DRIVER"

	[[ "$output" == *"GATE_REACHED_END"* ]] || {
		echo "gate died at the circuit-breaker threshold comparison"
		return 1
	}
}
