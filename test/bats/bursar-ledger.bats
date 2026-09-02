#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/bursar-ledger.sh"

	KEY="proj0123abcd"
}

_record() {
	# _record <session_id> <cost-or-empty> <tokens-or-empty> <ts_epoch>
	local sid="$1" cost="$2" tokens="$3" ts="$4"
	local rec
	rec=$(jq -n --arg sid "$sid" --arg pk "$KEY" --argjson te "$ts" \
		'{ts:"x", ts_epoch:$te, session_id:$sid, project_key:$pk, governor_present:true}')
	[ -n "$cost" ] && rec=$(printf '%s' "$rec" | jq --argjson v "$cost" '. + {cost_usd:$v}')
	[ -n "$tokens" ] && rec=$(printf '%s' "$rec" | jq --argjson v "$tokens" '. + {tokens:$v}')
	printf '%s' "$rec"
}

@test "recording a session creates a single ledger line" {
	local now
	now=$(date +%s)
	bursar_ledger_record "$KEY" "$(_record s1 1.0 100 "$now")"
	local path
	path=$(bursar_ledger_path "$KEY")
	[ -f "$path" ]
	[ "$(wc -l < "$path")" -eq 1 ]
}

@test "re-recording the same session upserts in place (idempotent)" {
	local now
	now=$(date +%s)
	bursar_ledger_record "$KEY" "$(_record s1 1.0 100 "$now")"
	bursar_ledger_record "$KEY" "$(_record s1 2.5 200 "$now")"
	local path
	path=$(bursar_ledger_path "$KEY")
	[ "$(wc -l < "$path")" -eq 1 ]
	[ "$(jq -r '.cost_usd' "$path")" = "2.5" ]
}

@test "different sessions append distinct lines" {
	local now
	now=$(date +%s)
	bursar_ledger_record "$KEY" "$(_record s1 1.0 100 "$now")"
	bursar_ledger_record "$KEY" "$(_record s2 2.0 200 "$now")"
	[ "$(wc -l < "$(bursar_ledger_path "$KEY")")" -eq 2 ]
}

@test "rolling_7d cutoff is roughly now minus seven days" {
	local now cutoff diff
	now=$(date +%s)
	cutoff=$(bursar_window_cutoff_epoch "rolling_7d" "monday")
	diff=$(( now - cutoff ))
	# 7 days = 604800s; allow a couple of seconds of clock drift across calls.
	[ "$diff" -ge 604798 ]
	[ "$diff" -le 604803 ]
}

@test "calendar_week cutoff is at or before now and not in the future" {
	local now cutoff
	now=$(date +%s)
	cutoff=$(bursar_window_cutoff_epoch "calendar_week" "monday")
	[ "$cutoff" -le "$now" ]
	# Never more than a full week back.
	[ "$(( now - cutoff ))" -le 604800 ]
}

@test "window totals sum cost and tokens, count sessions, and track cost coverage" {
	local now in1 in2 out
	now=$(date +%s)
	in1=$(( now - 100 ))
	in2=$(( now - 200 ))
	out=$(( now - 700000 ))   # older than 7 days

	local dir
	dir=$(bursar_ledger_dir "$KEY")
	mkdir -p "$dir"
	{
		_record withcost 1.0 100 "$in1"
		printf '\n'
		# governor absent: no cost_usd, no tokens
		jq -nc --arg pk "$KEY" --argjson te "$in2" \
			'{ts:"x", ts_epoch:$te, session_id:"nocost", project_key:$pk, governor_present:false}'
		_record stale 50.0 9999 "$out"
		printf '\n'
	} > "${dir}/sessions.jsonl"

	local cutoff totals
	cutoff=$(bursar_window_cutoff_epoch "rolling_7d" "monday")
	totals=$(bursar_window_totals "$KEY" "$cutoff")

	[ "$(printf '%s' "$totals" | jq -r '.total_cost_usd')" = "1" ]
	[ "$(printf '%s' "$totals" | jq -r '.total_tokens')" = "100" ]
	[ "$(printf '%s' "$totals" | jq -r '.session_count')" = "2" ]
	[ "$(printf '%s' "$totals" | jq -r '.sessions_with_cost')" = "1" ]
}

@test "window totals are zero when no ledger exists" {
	local totals
	totals=$(bursar_window_totals "nonexistent000" "0")
	[ "$(printf '%s' "$totals" | jq -r '.session_count')" = "0" ]
	[ "$(printf '%s' "$totals" | jq -r '.total_cost_usd')" = "0" ]
}

@test "token formatting is human-friendly" {
	[ "$(bursar_fmt_tokens 800)" = "800" ]
	[ "$(bursar_fmt_tokens 42000)" = "42k" ]
	[ "$(bursar_fmt_tokens 3100000)" = "3.1M" ]
}

# bursar-session-end.sh calls `bursar_ledger_record "$KEY" "$RECORD" 1` and
# documents why: "a short lock timeout (1s) to ensure the hook completes within
# the CLI's 1.5s SessionEnd budget". The function took two parameters, so that
# 1 went nowhere and the hardcoded BURSAR_LEDGER_LOCK_TIMEOUT=5 applied — the
# hook then waited 5s inside a 1.5s budget and was cancelled. Combined with an
# abandoned holder-less lock, that stalled ten project ledgers between Jun 20
# and Aug 7 (ecosystem-2vo).
#
# Asserted by capturing the argument rather than by timing: a wall-clock
# assertion here would be both slow and flaky, and the contract under test is
# "the caller's timeout reaches lock_acquire", not "it took N seconds".
@test "bursar_ledger_record passes the caller's lock timeout through" {
	_CAPTURED_TIMEOUT=""
	lock_acquire() { _CAPTURED_TIMEOUT="$2"; return 0; }
	lock_release() { return 0; }

	bursar_ledger_record "$KEY" "$(_record s1 1.5 100 1000)" 1

	[ "$_CAPTURED_TIMEOUT" = "1" ]
}

@test "bursar_ledger_record falls back to its default timeout when none is given" {
	_CAPTURED_TIMEOUT=""
	lock_acquire() { _CAPTURED_TIMEOUT="$2"; return 0; }
	lock_release() { return 0; }

	bursar_ledger_record "$KEY" "$(_record s1 1.5 100 1000)"

	[ "$_CAPTURED_TIMEOUT" = "$BURSAR_LEDGER_LOCK_TIMEOUT" ]
}

# The acceptance case for ecosystem-2vo, end to end: a ledger that has been
# stalled behind an abandoned lock must start writing again, AND must do it
# fast enough to matter.
#
# The lock shape is the one found on real machines — an empty <ledger>.lock.d
# with no holder file, left by code that predates holder files.
#
# The elapsed-time bound is the load-bearing part. Without it this test passes
# on the clamp alone, because bats imposes no deadline and a 5s break still
# eventually writes the record — but production does impose one: the CLI gives
# SessionEnd 1.5s, and 110 of 119 real runs died at ~1500ms having written
# nothing. So "it resumes" is only true if the break fits the budget, which
# needs the caller's 1s to actually reach lock_acquire as well.
#
# 3s is deliberately loose: the fixed path takes ~0.85s and the broken one
# ~5s, so the bound sits well clear of both and does not turn CI load into a
# false failure.
@test "a ledger stalled behind an abandoned lock resumes writing, within budget" {
	local dir ledger lock
	dir=$(bursar_ledger_dir "$KEY")
	mkdir -p "$dir"
	ledger="${dir}/sessions.jsonl"
	lock="${ledger}.lock"

	# Exactly what is on disk in the wild: the directory, and nothing in it.
	mkdir "${lock}.d"
	[ ! -e "${lock}.d/holder" ] || return 1

	local start end elapsed
	start=$(date +%s)
	bursar_ledger_record "$KEY" "$(_record s-resume 2.5 200 1000)" 1
	end=$(date +%s)
	elapsed=$((end - start))

	[ -f "$ledger" ] || return 1
	[ "$(jq -rs '.[0].session_id' "$ledger")" = "s-resume" ] || return 1
	[ "$elapsed" -lt 3 ]
}

# The other half of ecosystem-2vo's remediation. A writer killed between mktemp
# and mv leaves its temp file behind forever — that is exactly how each of the
# ten ledgers died, and two of those temps are still on the real machine
# (.sessions.Vuu1nb, 0 bytes, Aug 2; .sessions.VqjmCn, 20480 bytes, Aug 7).
# Nothing has ever swept them, so the litter is one file per abandonment and
# only grows.
#
# The clamp in portable-lock.sh un-stalls the ledger but leaves the litter, so
# the next successful write is the place to clear it: inside the lock this
# process owns the directory exclusively, which makes any .sessions.* that is
# not the one we just created abandoned by definition. No mtime heuristic
# needed, and no risk of deleting a live writer's temp.
@test "a successful write sweeps temp files abandoned by a killed writer" {
	local dir
	dir=$(bursar_ledger_dir "$KEY")
	mkdir -p "$dir"
	printf 'half a ledger\n' >"${dir}/.sessions.Vuu1nb"
	: >"${dir}/.sessions.VqjmCn"

	bursar_ledger_record "$KEY" "$(_record s1 1.0 100 "$(date +%s)")" || return 1

	[ ! -e "${dir}/.sessions.Vuu1nb" ] || return 1
	[ ! -e "${dir}/.sessions.VqjmCn" ] || return 1
	# The sweep must not take the ledger with it.
	[ "$(jq -rs '.[0].session_id' "$(bursar_ledger_path "$KEY")")" = "s1" ]
}
