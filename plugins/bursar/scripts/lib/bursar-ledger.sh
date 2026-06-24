#!/usr/bin/env bash
# Per-project, multi-session rollup ledger for bursar.
#
# Where governor keeps a per-session ledger under
# ~/.onlooker/governance/ledgers/<session-id>.jsonl, bursar keeps one ledger
# per project under:
#
#   $ONLOOKER_DIR/bursar/projects/<project_key>/sessions.jsonl
#
# Each line is one session's spend, recorded once on SessionEnd:
#
#   { ts, ts_epoch, session_id, project_key,
#     cost_usd?, tokens?, api_calls?, governor_present, model? }
#
# cost/tokens/api_calls are omitted when governor was not running for the
# session (governor_present:false) — bursar degrades to a session count.
#
# Records are keyed by session_id: re-recording a session replaces its line
# rather than appending, so a SessionEnd that fires more than once is
# idempotent.
#
# ts_epoch (seconds) is stored alongside the RFC3339 ts so window filtering is
# a portable numeric jq compare with no date parsing.
#
# Requires portable-lock.sh to be sourced beforehand.

BURSAR_LEDGER_LOCK_TIMEOUT=5

bursar_ledger_dir() {
	local project_key="${1:-unknown}"
	local safe_key
	safe_key=$(printf '%s' "$project_key" | tr -c 'a-zA-Z0-9-' '_')
	printf '%s/bursar/projects/%s' "${ONLOOKER_DIR:-${HOME}/.onlooker}" "$safe_key"
}

bursar_ledger_path() {
	printf '%s/sessions.jsonl' "$(bursar_ledger_dir "$1")"
}

# Current wall-clock helpers (portable across macOS/Linux).
bursar_now_epoch() { date +%s 2>/dev/null || printf '0'; }
bursar_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf ''; }

bursar_epoch_to_iso() {
	local e="${1:-0}"
	date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
		|| date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
		|| printf ''
}

# Upsert a session record into the project ledger, keyed by session_id.
# Usage: bursar_ledger_record "$project_key" "$record_json"
bursar_ledger_record() {
	local project_key="${1:-}"
	local record="${2:-}"
	[[ -z "$project_key" || -z "$record" ]] && return 1

	# Pull the session_id and the compacted record out in a single jq pass:
	# line 1 is the key, line 2 is the line we will write.
	local sid record_compact
	{ IFS= read -r sid; IFS= read -r record_compact; } < <(
		printf '%s' "$record" | jq -r '.session_id // empty, tojson' 2>/dev/null
	)
	[[ -z "$sid" || -z "$record_compact" ]] && return 1

	local dir ledger_path lock_path
	dir=$(bursar_ledger_dir "$project_key")
	ledger_path="${dir}/sessions.jsonl"
	lock_path="${ledger_path}.lock"
	mkdir -p "$dir" 2>/dev/null || return 1

	if ! lock_acquire "$lock_path" "$BURSAR_LEDGER_LOCK_TIMEOUT"; then
		return 1
	fi

	local tmp
	tmp=$(mktemp "${dir}/.sessions.XXXXXX" 2>/dev/null) || { lock_release "$lock_path"; return 1; }

	if [[ -f "$ledger_path" ]]; then
		# Keep every line whose session_id differs from the one being recorded.
		jq -c --arg sid "$sid" 'select(.session_id != $sid)' "$ledger_path" 2>/dev/null >>"$tmp"
	fi
	printf '%s\n' "$record_compact" >>"$tmp"

	mv "$tmp" "$ledger_path" 2>/dev/null || { rm -f "$tmp"; lock_release "$lock_path"; return 1; }
	lock_release "$lock_path"
	return 0
}

# Compute the inclusive lower-bound epoch for the active window.
# Usage: bursar_window_cutoff_epoch <rolling_7d|calendar_week> <monday|sunday>
bursar_window_cutoff_epoch() {
	local window="${1:-rolling_7d}"
	local week_start="${2:-monday}"
	local now
	now=$(bursar_now_epoch)

	if [[ "$window" == "calendar_week" ]]; then
		# Local midnight today, computed portably from H/M/S (no GNU/BSD-only flags).
		local h m s secs_today today_midnight dow days_since
		h=$(date +%H 2>/dev/null) || h=0
		m=$(date +%M 2>/dev/null) || m=0
		s=$(date +%S 2>/dev/null) || s=0
		secs_today=$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
		today_midnight=$(( now - secs_today ))

		dow=$(date +%u 2>/dev/null) || dow=1   # 1=Mon .. 7=Sun
		if [[ "$week_start" == "sunday" ]]; then
			days_since=$(( dow % 7 ))           # Sun(7)->0, Mon(1)->1 .. Sat(6)->6
		else
			days_since=$(( dow - 1 ))           # Mon(1)->0 .. Sun(7)->6
		fi
		printf '%d' "$(( today_midnight - days_since * 86400 ))"
	else
		printf '%d' "$(( now - 604800 ))"       # rolling trailing 7 days
	fi
}

# Aggregate spend over the window. Prints a JSON object:
#   {total_cost_usd, total_tokens, session_count, sessions_with_cost}
# Usage: bursar_window_totals "$project_key" "$cutoff_epoch"
bursar_window_totals() {
	local project_key="${1:-}"
	local cutoff="${2:-0}"
	local ledger_path
	ledger_path=$(bursar_ledger_path "$project_key")

	if [[ ! -f "$ledger_path" ]]; then
		printf '{"total_cost_usd":0,"total_tokens":0,"session_count":0,"sessions_with_cost":0}'
		return 0
	fi

	jq -s --argjson cutoff "$cutoff" '
		[ .[] | select((.ts_epoch // 0) >= $cutoff) ] as $w
		| {
			total_cost_usd: ([ $w[] | (.cost_usd // 0) ] | add // 0),
			total_tokens: ([ $w[] | (.tokens // 0) ] | add // 0),
			session_count: ($w | length),
			sessions_with_cost: ([ $w[] | select(.cost_usd != null) ] | length)
		}
	' "$ledger_path" 2>/dev/null \
		|| printf '{"total_cost_usd":0,"total_tokens":0,"session_count":0,"sessions_with_cost":0}'
}

# Human-friendly token count: 1234567 -> "1.2M", 42000 -> "42k", 800 -> "800".
bursar_fmt_tokens() {
	local n="${1:-0}"
	awk -v n="$n" 'BEGIN {
		if (n >= 1000000) printf "%.1fM", n/1000000;
		else if (n >= 1000) printf "%.0fk", n/1000;
		else printf "%d", n;
	}'
}
