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
  "customs":      "gate_blocks",
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

# The lookback cutoff as an ISO 8601 UTC string, or empty when `date` cannot
# produce one. ISO 8601 is lexicographically sortable, so callers compare it as
# a string. Empty means "no lower bound" to every caller, deliberately: a
# broken date subsystem should widen the window, not empty it.
#
# -v is BSD (macOS), -d is GNU. Order matters: BSD date accepts -d as an
# entirely different flag, so GNU must be the fallback.
_counsel_cutoff_ts() {
	local lookback_days="${1:-30}"
	if [[ "$(uname)" == "Darwin" ]]; then
		date -v "-${lookback_days}d" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf ''
	else
		date -d "-${lookback_days} days" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf ''
	fi
}

# The shape of the WHOLE window, in a few KB regardless of its size.
#
# This exists because a per-event dump cannot describe a month. Measured on a
# real log: 92,822 events over 30 days is 12.1 MB once payloads are dropped -
# 202x the 60,000-char budget - so any per-event view is a sample, and before
# ONL-165 it was a 0.132% sample of the OLDEST events. This summary is bounded
# by the number of distinct types and days instead, which made the same window
# 2,859 bytes.
#
# Slurped (-s) rather than streamed so group_by does the aggregation. Measured
# at ~1.3 s against a 259k-line log, the same as a streaming projection, so the
# clearer form costs nothing. Both passes together run inside counsel's
# background refresh, behind a synthesis call with a 90 s timeout.
counsel_window_summary() {
	local lookback_days="${1:-30}"
	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	local empty='{"window":{"from":"","to":"","events":0,"sessions":0},"by_type":{},"by_day":{}}'

	[[ -f "$log_path" ]] || { printf '%s' "$empty"; return 0; }

	local cutoff_ts summary
	cutoff_ts=$(_counsel_cutoff_ts "$lookback_days")

	# `add` on an empty array yields null, hence the `// {}` on both maps.
	summary=$(jq -sc --arg cutoff "$cutoff_ts" '
		[ .[]
		  | select(.timestamp != null)
		  | select($cutoff == "" or .timestamp >= $cutoff)
		] as $ev
		| { window: {
		      from:     $cutoff,
		      to:       (if ($ev | length) > 0
		                 then ($ev | max_by(.timestamp) | .timestamp) else "" end),
		      events:   ($ev | length),
		      sessions: ([ $ev[].session_id ] | map(select(. != null)) | unique | length)
		    },
		    by_type: ($ev | group_by(.event_type)
		                  | map({ (.[0].event_type // "unknown"): length }) | add // {}),
		    by_day:  ($ev | group_by(.timestamp[0:10])
		                  | map({ (.[0].timestamp[0:10]): length }) | add // {})
		  }
	' "$log_path" 2>/dev/null) || summary=""

	[[ -z "$summary" || "$summary" == "null" ]] && summary="$empty"
	printf '%s' "$summary"
}

# Sources for the WHOLE window, derived from the summary's type census.
#
# Deliberately not computed from the event sample: a bounded sample can miss a
# whole plugin the window contains, and the brief would then under-report what
# it drew on. by_type sees every type in the period.
counsel_sources_from_summary() {
	local summary="${1:-}"
	local sources

	sources=$(printf '%s' "$summary" | jq -c --argjson map "$_COUNSEL_SOURCE_MAP" '
		[ (.by_type // {}) | keys[] | split(".")[0] | $map[.] // "onlooker_events" ]
		| unique
	' 2>/dev/null) || sources=""

	[[ -z "$sources" || "$sources" == "[]" ]] && sources='["onlooker_events"]'
	printf '%s' "$sources"
}

counsel_read_events() {
	local lookback_days="${1:-30}"
	local chars_max="${2:-60000}"

	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	[[ -f "$log_path" ]] || { printf ''; return 0; }

	local cutoff_ts
	cutoff_ts=$(_counsel_cutoff_ts "$lookback_days")

	# The RECENT end of the window, not the oldest. `tail -c` where this used
	# `head -c`, which is the whole of ONL-165: a weekly coaching brief that
	# structurally cannot see the last few days is describing the wrong period.
	#
	# `payload` is gone from the projection. It averaged ~480 bytes an event,
	# which is why 60,000 chars held only 124 of them - dropping it fits
	# hundreds of envelopes in the same budget. It also keeps payloads out of
	# an LLM prompt, which is the posture the hosted summarizer takes
	# deliberately (see apps/cli/src/sessions.ts: "payload is absent from
	# EventEnvelope deliberately, and that absence is the feature's entire
	# safety story"). Counsel is local, so this is not the same guarantee, but
	# there is no reason to send more than the brief reasons over.
	#
	# The cost: `tail` cannot emit until jq finishes, so jq no longer exits
	# early on SIGPIPE and the pass is ~1533 ms against ~760 ms before, on a
	# 259k-line log. That is paid in counsel's background refresh, behind a
	# synthesis call with a 90 s timeout.
	#
	# pipefail stays disabled for the same reason it was before: a failure
	# anywhere in the pipeline must degrade to truncated output rather than
	# discard every event. The hook and the /counsel skill both set pipefail.
	#
	# The trailing jq re-reads the bytes as raw lines and drops whatever does
	# not parse, which removes the partial first line `tail -c` leaves behind
	# and guarantees the result is valid JSONL for counsel_count_events.
	local summary
	summary=$(set +o pipefail
		jq -rc --arg cutoff "$cutoff_ts" '
			select(.timestamp != null) |
			select($cutoff == "" or .timestamp >= $cutoff) |
			{
				type:    .event_type,
				plugin:  (.plugin // "unknown"),
				ts:      .timestamp,
				session: (.session_id // "")
			}
		' "$log_path" 2>/dev/null \
			| tail -c "$chars_max" \
			| jq -Rc 'fromjson? // empty' 2>/dev/null
	) || summary=""

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
