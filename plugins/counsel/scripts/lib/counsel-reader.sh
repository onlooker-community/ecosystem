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

# Event-type prefix -> CounselSource, as DATA rather than control flow.
#
# One definition, read by both counsel_sources_from_events and the test that
# asserts no shipped plugin falls through to the generic bucket. The previous
# version had the same mapping written twice - once in a `case` nobody called
# and once inline in the loop below - so correcting the dead one changed
# nothing while the tests stayed green (ONL-157).
#
# A jq object, not a bash associative array: this repo runs on macOS system
# bash 3.2, which has no `declare -A`.
#
# Buckets name what the brief CONSULTED, not who emitted - see the
# CounselSource docstring in @onlooker-community/schema. The six values are
# published and closed, so a prefix absent from this map is a prefix the brief
# reports generically.
_COUNSEL_SOURCE_MAP='{
  "compass":      "gate_blocks",
  "warden":       "gate_blocks",
  "tribunal":     "gate_blocks",
  "inspector":    "verification",
  "assayer":      "verification",
  "echo":         "verification",
  "librarian":    "memory",
  "curator":      "memory",
  "historian":    "memory",
  "scribe":       "memory",
  "archivist":    "memory",
  "governor":     "cost",
  "bursar":       "cost",
  "lineage":      "provenance",
  "cartographer": "provenance"
}'

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
	# Run inside a subshell with pipefail disabled. head -c closes the pipe once
	# chars_max bytes have arrived, which sends jq SIGPIPE; under the caller's
	# `set -o pipefail` (the SessionStart hook and the /counsel skill both set it)
	# that marks the whole pipeline failed, and the `|| summary=""` fallback would
	# then discard *every* event on any log large enough to exceed chars_max.
	# Disabling pipefail locally keeps the truncated output.
	# -rc: compact output keeps each object on one line (JSONL-shaped), which
	# downstream counsel_count_events and counsel_sources_from_events require.
	summary=$(set +o pipefail; jq -rc --arg cutoff "$cutoff_ts" '
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

	# ONE jq pass over the whole batch. The previous version forked a jq PER
	# LINE to read `.type`, against a batch bounded at chars_max (60,000 by
	# default) - hundreds of processes to produce a handful of strings.
	#
	# `fromjson?` rather than plain fromjson: counsel_read_events can truncate
	# its summary at chars_max mid-line, so the last line is routinely partial,
	# and one unparsable line must not empty the whole array.
	local sources
	sources=$(printf '%s' "$events_text" | jq -sRc --argjson map "$_COUNSEL_SOURCE_MAP" '
		[ split("\n")[]
		  | select(length > 0)
		  | (fromjson? // empty)
		  | (.type // "")
		  | split(".")[0]
		  | $map[.] // "onlooker_events"
		]
		| unique
	' 2>/dev/null) || sources=""

	# Empty batch, all-unparsable batch, or a jq that failed: the field is
	# optional in the schema but counsel has always sent something, and
	# "onlooker_events" is the honest answer for "read the log generically".
	[[ -z "$sources" || "$sources" == "[]" ]] && sources='["onlooker_events"]'
	printf '%s' "$sources"
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
