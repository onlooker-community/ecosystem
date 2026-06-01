#!/usr/bin/env bash
# Event log reader for Counsel.
#
# Reads $ONLOOKER_EVENTS_LOG and returns a filtered, summarized view of
# the last N days suitable for passing to the synthesis prompt.
#
# Exposes:
#   counsel_read_events <lookback_days> <chars_max>
#     Echoes a structured text summary of events, or empty string on failure.
#
#   counsel_sources_from_events <events_json>
#     Echoes a JSON array of CounselSource strings present in the event batch.

# Maps event_type prefixes to CounselSource values.
_counsel_source_for_type() {
	local event_type="${1:-}"
	case "$event_type" in
		tribunal.*)     printf 'tribunal_verdicts' ;;
		echo.*)         printf 'echo_regressions' ;;
		sentinel.*)     printf 'sentinel_audit' ;;
		warden.*)       printf 'warden_audit' ;;
		oracle.*)       printf 'oracle_calibrations' ;;
		meridian.*)     printf 'meridian_reliance' ;;
		*)              printf 'onlooker_events' ;;
	esac
}

counsel_read_events() {
	local lookback_days="${1:-30}"
	local chars_max="${2:-60000}"

	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	[[ -f "$log_path" ]] || { printf ''; return 0; }

	# Compute cutoff as an ISO 8601 date string. ISO 8601 strings are
	# lexicographically sortable, so string comparison is safe for filtering.
	local cutoff_ts
	if [[ "$(uname)" == "Darwin" ]]; then
		cutoff_ts=$(date -v "-${lookback_days}d" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
			|| cutoff_ts=""
	else
		cutoff_ts=$(date -d "-${lookback_days} days" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
			|| cutoff_ts=""
	fi

	# Filter to events within the lookback window. If cutoff_ts is empty (date
	# command unavailable) fall through and include all events.
	local summary
	summary=$(jq -r --arg cutoff "$cutoff_ts" '
		select(.timestamp != null) |
		select($cutoff == "" or .timestamp >= $cutoff) |
		{
			type:      .event_type,
			plugin:    (.plugin // "unknown"),
			ts:        .timestamp,
			session:   (.session_id // ""),
			payload:   (.payload // {})
		}
	' "$log_path" 2>/dev/null | head -c "$chars_max") || summary=""

	printf '%s' "$summary"
}

counsel_sources_from_events() {
	local events_text="${1:-}"
	[[ -z "$events_text" ]] && { printf '["onlooker_events"]'; return 0; }

	local sources=()
	local seen_tribunal=0 seen_echo=0 seen_sentinel=0 seen_warden=0 seen_oracle=0 seen_meridian=0 seen_other=0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local etype
		etype=$(printf '%s' "$line" | jq -r '.type // ""' 2>/dev/null) || continue
		case "$etype" in
			tribunal.*)  seen_tribunal=1 ;;
			echo.*)      seen_echo=1 ;;
			sentinel.*)  seen_sentinel=1 ;;
			warden.*)    seen_warden=1 ;;
			oracle.*)    seen_oracle=1 ;;
			meridian.*)  seen_meridian=1 ;;
			*)           seen_other=1 ;;
		esac
	done <<< "$events_text"

	[[ "$seen_other" -eq 1 ]]    && sources+=("\"onlooker_events\"")
	[[ "$seen_tribunal" -eq 1 ]] && sources+=("\"tribunal_verdicts\"")
	[[ "$seen_echo" -eq 1 ]]     && sources+=("\"echo_regressions\"")
	[[ "$seen_sentinel" -eq 1 ]] && sources+=("\"sentinel_audit\"")
	[[ "$seen_warden" -eq 1 ]]   && sources+=("\"warden_audit\"")
	[[ "$seen_oracle" -eq 1 ]]   && sources+=("\"oracle_calibrations\"")
	[[ "$seen_meridian" -eq 1 ]] && sources+=("\"meridian_reliance\"")

	if [[ "${#sources[@]}" -eq 0 ]]; then
		printf '["onlooker_events"]'
		return 0
	fi

	local joined
	joined=$(IFS=,; printf '%s' "${sources[*]}")
	printf '[%s]' "$joined"
}

counsel_count_events() {
	local events_text="${1:-}"
	[[ -z "$events_text" ]] && { printf '0'; return 0; }
	local count=0
	while IFS= read -r line; do
		[[ -n "$line" ]] && count=$((count + 1))
	done <<< "$events_text"
	printf '%s' "$count"
}
