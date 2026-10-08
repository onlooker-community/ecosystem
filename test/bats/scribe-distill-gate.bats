#!/usr/bin/env bats
#
# scribe must not re-distill a transcript it has already covered, and must say
# so when it declines.
#
# ONL-41, second half. #391 moved the Haiku pass off the blocking Stop path but
# left it firing once per TURN, because scribe_distill had nothing in front of
# it asking whether the work was already done. Measured on the live event log:
# 62 scribe.distill.complete across 20 distinct sessions, one of them
# distilling 8 times in 56 minutes. Every pass writes the same
# <date>-<session>.md, so 42 of those 62 Haiku passes produced an artifact the
# next pass immediately overwrote.
#
# Echo had the identical defect and the identical fix (ecosystem-449.40): key
# the work on whether the input is new, not on whether the hook fired. The key
# differs, though — echo hashes watched files, but a transcript is APPEND-ONLY
# and differs on every turn, so a hash would gate nothing here. The unit of
# "new enough to redo the pass" is turns.
#
# The other half is ecosystem-449.21: a hook that decides not to act has to be
# visible in the event stream. Before this, every one of scribe's four bail
# paths exited silently, so the only signal was the ABSENCE of
# scribe.distill.complete — which cannot tell "too short" from "already
# covered" from "the hook never fired".

setup() {
	# load_validate_path, not setup_test_env: every assertion below reads
	# $ONLOOKER_EVENTS_LOG, and setup_test_env deliberately UNSETS that (so a
	# value from the developer's shell cannot outlive the temp home). Without
	# it the greps run against an empty path, silently match nothing, and the
	# "no events were emitted" tests pass whether or not the code works.
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	load_validate_path

	PLUGIN_ROOT="${REPO_ROOT}/plugins/scribe"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/scribe-stop.sh"

	# scribe_count_turns counts only user entries whose message.content is a
	# STRING — tool results carry an array and are excluded. A fixture that got
	# that wrong would never clear min_turns and would pass the skip tests below
	# for entirely the wrong reason.
	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	_append_user_turn "why is the gate failing"
	_append_user_turn "try it on the other branch"
	_append_user_turn "now write that up"

	CLAUDE_CALLED="${BATS_TEST_TMPDIR}/claude_called"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	_install_claude_stub
	export PATH="${STUB_BIN}:${PATH}"

	SESSIONS_DIR="${ONLOOKER_DIR}/scribe/sessions"
}

# The pass outlives the hook, so it also outlives the test. Left alone its
# writes race bats tearing the tree down underneath it.
teardown() {
	local waited=0
	while [[ "$waited" -lt 25 ]]; do
		if [[ "$waited" -ge 2 ]] &&
			! compgen -G "${ONLOOKER_DIR}"/scribe/sessions/*.distill.lock.d >/dev/null 2>&1; then
			break
		fi
		sleep 1
		waited=$((waited + 1))
	done
}

_install_claude_stub() {
	cat >"${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
printf 'x\n' >> "${CLAUDE_CALLED}"
printf '%s' '{"summary":"s","problem":"p","decisions":[],"tradeoffs":[],"constraints":[],"out_of_scope":[]}'
STUB
	chmod +x "${STUB_BIN}/claude"
}

_append_user_turn() {
	jq -cn --arg t "$1" '{type:"user", message:{content:$t}}' >>"$TRANSCRIPT"
}

_run_hook() {
	local sid="${1:-sess-gate}" tp="${2-$TRANSCRIPT}"
	jq -cn --arg cwd "$BATS_TEST_TMPDIR" --arg sid "$sid" --arg tp "$tp" \
		'{cwd:$cwd, session_id:$sid, transcript_path:$tp, hook_event_name:"Stop"}' \
		| "$HOOK" 2>/dev/null
}

# The hook returns before the detached pass finishes, so every assertion has to
# wait for the worker to reach its decision rather than reading straight after.
_wait_for_event() {
	local event_type="$1" want="${2:-1}" waited=0 seen=0
	while [[ "$waited" -lt 25 ]]; do
		if [[ -f "$ONLOOKER_EVENTS_LOG" ]]; then
			# NB: `|| printf '0'` would APPEND to grep's own output, not replace
			# it. grep -c prints "0" and exits 1 when there are no matches, so
			# that form yielded "0\n0" and the [[ -ge ]] below died with
			# "syntax error in expression" instead of waiting. It only showed up
			# when the count was zero -- i.e. exactly when a hook had died, the
			# case this helper exists to report.
			seen=$(grep -c "\"event_type\":\"${event_type}\"" "$ONLOOKER_EVENTS_LOG" 2>/dev/null) || seen=0
			[[ "$seen" -ge "$want" ]] && return 0
		fi
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

_skip_reasons() {
	grep '"event_type":"scribe.distill.skipped"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null \
		| jq -r '.payload.reason'
}

_count_events() {
	grep -c "\"event_type\":\"$1\"" "$ONLOOKER_EVENTS_LOG" 2>/dev/null || printf '0'
}

_marker() {
	printf '%s/%s.distill.state' "$SESSIONS_DIR" "${1:-sess-gate}"
}

# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------

# THE regression test. Two Stops on an unchanged transcript is exactly the shape
# that billed 42 wasted Haiku passes: the second one has nothing new to read.
@test "a second Stop on the same transcript does not re-run the pass" {
	_run_hook sess-twice >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || {
		echo "first pass never completed"
		return 1
	}

	_run_hook sess-twice >/dev/null
	_wait_for_event "scribe.distill.skipped" 1 || {
		echo "second Stop neither distilled nor reported a skip"
		return 1
	}

	local calls
	calls=$(wc -l <"$CLAUDE_CALLED" | tr -d '[:space:]')
	[ "$calls" -eq 1 ] || {
		echo "expected 1 Haiku pass across two Stops, got ${calls}"
		return 1
	}
}

@test "the declined second Stop reports no_new_turns with both compared counts" {
	_run_hook sess-reason >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || return 1
	_run_hook sess-reason >/dev/null
	_wait_for_event "scribe.distill.skipped" 1 || return 1

	grep '"event_type":"scribe.distill.skipped"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e 'select(.payload.reason == "no_new_turns")
		         | .payload.turn_count == 3
		           and .payload.last_distilled_turns == 3
		           and .payload.threshold == 8' >/dev/null || {
		echo "payload did not carry the comparison:"
		_skip_reasons
		return 1
	}
}

# Re-distilling is refinement, not waste — a later pass sees more of the session
# and writes a better document. The gate decides how much new material earns
# another call, so crossing it must actually re-run.
@test "enough new turns lets the pass run again" {
	_run_hook sess-grow >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || return 1

	# 3 -> 8 turns: exactly the default threshold of last + 5.
	_append_user_turn "four"
	_append_user_turn "five"
	_append_user_turn "six"
	_append_user_turn "seven"
	_append_user_turn "eight"

	_run_hook sess-grow >/dev/null
	_wait_for_event "scribe.distill.complete" 2 || {
		echo "a grown transcript was not re-distilled"
		return 1
	}

	local calls
	calls=$(wc -l <"$CLAUDE_CALLED" | tr -d '[:space:]')
	[ "$calls" -eq 2 ]
}

# One turn short of the threshold is the boundary the gate actually defends;
# off-by-one here means either every turn re-distills or none ever does.
@test "one turn short of the threshold still declines" {
	_run_hook sess-edge >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || return 1

	_append_user_turn "four"
	_append_user_turn "five"
	_append_user_turn "six"
	_append_user_turn "seven"

	_run_hook sess-edge >/dev/null
	_wait_for_event "scribe.distill.skipped" 1 || return 1

	local calls
	calls=$(wc -l <"$CLAUDE_CALLED" | tr -d '[:space:]')
	[ "$calls" -eq 1 ] || {
		echo "7 turns against a threshold of 8 re-distilled anyway"
		return 1
	}
}

# The marker is what the gate reads, and it must mean "a document exists", not
# "a pass was attempted" — otherwise a failed extraction suppresses its retry.
@test "the turn count is recorded only once a document is on disk" {
	_run_hook sess-mark >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || return 1

	[ -f "$(_marker sess-mark)" ] || {
		echo "no marker at $(_marker sess-mark)"
		return 1
	}
	[ "$(tr -dc '0-9' <"$(_marker sess-mark)")" = "3" ]
}

@test "a failed pass records nothing, so the next Stop retries" {
	cat >"${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
printf 'stub-claude: deliberate failure\n' >&2
exit 1
STUB
	chmod +x "${STUB_BIN}/claude"

	_run_hook sess-fail >/dev/null
	local waited=0
	while [[ ! -f "$(_marker sess-fail)" && "$waited" -lt 8 ]]; do
		sleep 1
		waited=$((waited + 1))
	done

	! [ -f "$(_marker sess-fail)" ] || {
		echo "a failed extraction recorded coverage it never produced"
		return 1
	}
}

# The escape hatch. Anyone who wants the old every-turn behavior sets 0, and a
# gate that ignored that would be a behavior change with no way out.
@test "redistill_min_new_turns of 0 disables the gate" {
	mkdir -p "${BATS_TEST_TMPDIR}/.claude"
	jq -n '{scribe: {capture: {redistill_min_new_turns: 0}}}' \
		>"${BATS_TEST_TMPDIR}/.claude/settings.json"

	_run_hook sess-off >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || return 1
	_run_hook sess-off >/dev/null
	_wait_for_event "scribe.distill.complete" 2 || {
		echo "gate still engaged with redistill_min_new_turns=0"
		return 1
	}

	[ "$(_count_events scribe.distill.complete)" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Reporting the bail (ecosystem-449.21)
# ---------------------------------------------------------------------------

@test "a session below min_turns reports below_min_turns, not silence" {
	local short="${BATS_TEST_TMPDIR}/short.jsonl"
	jq -cn '{type:"user", message:{content:"just the one"}}' >"$short"

	_run_hook sess-short "$short" >/dev/null
	_wait_for_event "scribe.distill.skipped" 1 || {
		echo "a too-short session bailed silently"
		return 1
	}

	grep '"event_type":"scribe.distill.skipped"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e 'select(.payload.reason == "below_min_turns")
		         | .payload.turn_count == 1 and .payload.threshold == 3' >/dev/null
}

@test "an unreadable transcript reports no_transcript" {
	_run_hook sess-missing "${BATS_TEST_TMPDIR}/not-a-file.jsonl" >/dev/null
	_wait_for_event "scribe.distill.skipped" 1 || {
		echo "a missing transcript bailed silently"
		return 1
	}

	_skip_reasons | grep -q '^no_transcript$'
}

# Deciding this in the hook would put the reporting on the Stop path, which is
# the one thing this bead is about keeping clear.
@test "the no_transcript decision is not made on the Stop path" {
	local start end
	start=$(date +%s)
	_run_hook sess-fast "${BATS_TEST_TMPDIR}/not-a-file.jsonl" >/dev/null
	end=$(date +%s)
	[ "$((end - start))" -lt 3 ]
}

# ---------------------------------------------------------------------------
# The hook's own contract still holds
# ---------------------------------------------------------------------------

@test "Stop stays silent on stdout whatever the worker decides" {
	local out
	out=$(_run_hook sess-quiet "${BATS_TEST_TMPDIR}/not-a-file.jsonl")
	[ -z "$out" ] || {
		echo "hook wrote to stdout: ${out}"
		return 1
	}

	out=$(_run_hook sess-quiet2)
	[ -z "$out" ]
}

@test "a session with no id is the one skip that stays silent" {
	jq -cn --arg cwd "$BATS_TEST_TMPDIR" --arg tp "$TRANSCRIPT" \
		'{cwd:$cwd, session_id:"", transcript_path:$tp, hook_event_name:"Stop"}' \
		| "$HOOK" 2>/dev/null
	sleep 2
	[ "$(_count_events scribe.distill.skipped)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The document keeps its content
# ---------------------------------------------------------------------------

# Every bullet in the intent document is written with a format string that
# STARTS WITH A DASH, which printf parses as options. So `printf '- %s\n'` has
# never emitted anything: the Tradeoffs, Constraints and Out of Scope sections
# came out empty however much the model found, Decisions kept only its indented
# "Considered" sub-lines (those start with spaces), and every pass wrote
# "printf: --: invalid option" to a stderr nobody read.
#
# Found by reading ~/.onlooker/scribe/distill.log, which is only worth reading
# because #391 started writing it. Confirmed against a real artifact: its JSON
# held 5 decisions, 3 tradeoffs and 5 constraints; its markdown rendered none of
# them. The JSON sibling was always fine, so nothing upstream noticed.
@test "the document renders the bullets its JSON carries" {
	cat >"${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
printf 'x\n' >> "CLAUDE_CALLED_PATH"
printf '%s' '{"summary":"s","problem":"p",
 "decisions":[{"decision":"detach the pass","reason":"Stop must not block","alternatives":["inline"]}],
 "tradeoffs":["freshness for cost"],
 "constraints":["no new SessionEnd hook"],
 "out_of_scope":["the historian join"]}'
STUB
	sed -i.bak "s|CLAUDE_CALLED_PATH|${CLAUDE_CALLED}|" "${STUB_BIN}/claude"
	chmod +x "${STUB_BIN}/claude"

	_run_hook sess-doc >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || {
		echo "no document was produced"
		return 1
	}

	local doc
	doc=$(find "${ONLOOKER_DIR}/scribe" -name '*-sess-doc.md' -o -name '*.md' \
		-path '*scribe*' 2>/dev/null | grep -v sessions | head -1)
	[ -n "$doc" ] || {
		echo "no markdown artifact on disk"
		return 1
	}

	grep -q 'detach the pass' "$doc" || {
		echo "the decision bullet is missing:"
		sed -n '/## Decisions/,/## Tradeoffs/p' "$doc"
		return 1
	}
	grep -q 'freshness for cost' "$doc" || {
		echo "the tradeoff bullet is missing"
		return 1
	}
	grep -q 'no new SessionEnd hook' "$doc" || {
		echo "the constraint bullet is missing"
		return 1
	}
	grep -q 'the historian join' "$doc"
}

# The same dash-as-option bug, one line further down. Cheap to assert and it is
# the separator a reader looks for between the body and the provenance footer.
@test "the document keeps its closing rule" {
	_run_hook sess-rule >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || return 1

	local doc
	doc=$(find "${ONLOOKER_DIR}/scribe" -name '*.md' 2>/dev/null | grep -v sessions | head -1)
	[ -n "$doc" ] || return 1
	grep -qx -- '---' "$doc"
}

# The pass must stop writing printf usage errors into the log that #391 made the
# only place its diagnostics survive. A successful run should leave it clean.
@test "a successful pass leaves no printf usage errors in the distill log" {
	_run_hook sess-clean >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || return 1

	local log="${ONLOOKER_DIR}/scribe/distill.log"
	if [[ -f "$log" ]]; then
		! grep -q 'invalid option' "$log" || {
			echo "printf usage errors still in the log:"
			grep 'invalid option' "$log" | head -3
			return 1
		}
	fi
}

# ---------------------------------------------------------------------------
# ONL-132 / ecosystem-ac8r8d.3
#
# Both gate thresholds reached arithmetic through the null/empty-fallback
# idiom, which catches "" and the literal "null" and nothing else:
#   min_turns      -> [[ "$turn_count" -lt "$min_turns" ]]       (:234)
#   redistill_min  -> threshold=$((last_turns + redistill_min))  (:266)
# [[ -lt ]] evaluates its operands arithmetically, so it dies exactly as (( ))
# does. A bare word there is read as a VARIABLE NAME, set -u stops the shell,
# and scribe-distill.sh runs set -uo pipefail deliberately without -e -- so the
# status is 0 and the gate vanishes without a word.
#
# These are hook-level rather than accessor-level because the gate publishes the
# threshold it used, which makes the fallback VALUE observable from outside.
# That matters: asserting mere survival would not bite here.
#
# Fixtures use "unlimited", never a digit-leading value like "3turns". Digit-
# leading hits the milder mode -- bash reports "value too great for base", the
# comparison returns non-zero, the script survives with the gate silently
# inverted -- and so passes against unfixed code. config-get-int.bats covers it.
# ---------------------------------------------------------------------------

@test "a non-numeric min_turns falls back to the shipped threshold, gate intact" {
	mkdir -p "${BATS_TEST_TMPDIR}/.claude"
	jq -n '{scribe: {capture: {min_turns: "unlimited"}}}' \
		>"${BATS_TEST_TMPDIR}/.claude/settings.json"

	local short="${BATS_TEST_TMPDIR}/short.jsonl"
	jq -cn '{type:"user", message:{content:"just the one"}}' >"$short"

	_run_hook sess-badmin "$short" >/dev/null
	_wait_for_event "scribe.distill.skipped" 1 || {
		echo "the gate died instead of falling back"
		return 1
	}

	# threshold == 3 is the shipped default, and is what proves the fallback
	# landed on it rather than on 0 -- a 0 threshold would admit every trivial
	# session, trading a silent death for a silently disabled gate.
	grep '"event_type":"scribe.distill.skipped"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e 'select(.payload.reason == "below_min_turns")
		         | .payload.threshold == 3' >/dev/null
}

@test "a non-numeric redistill_min_new_turns leaves the gate engaged" {
	mkdir -p "${BATS_TEST_TMPDIR}/.claude"
	jq -n '{scribe: {capture: {redistill_min_new_turns: "unlimited"}}}' \
		>"${BATS_TEST_TMPDIR}/.claude/settings.json"

	_run_hook sess-badredistill >/dev/null
	_wait_for_event "scribe.distill.complete" 1 || {
		echo "the first pass never completed"
		return 1
	}

	# Falls back to the shipped 5, so a second pass over the same transcript is
	# still gated. Unguarded, $((last_turns + redistill_min)) kills the shell
	# here and no second event of EITHER kind appears -- so asserting only
	# "complete did not happen twice" would pass against broken code. The skip
	# event is what distinguishes a working gate from a dead hook.
	_run_hook sess-badredistill >/dev/null
	_wait_for_event "scribe.distill.skipped" 1 || {
		echo "second pass neither distilled nor reported a skip: gate died"
		return 1
	}

	[ "$(_count_events scribe.distill.complete)" -eq 1 ]
}
