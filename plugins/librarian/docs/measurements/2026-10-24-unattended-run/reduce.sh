#!/usr/bin/env bash
# Reduce one run.sh output directory to what is safe and useful to commit.
#
# Keeps per-call accounting (model, turns, tokens, cost, duration) for every
# call, and the response text only for librarian's own calls (depth 0). Nested
# hooks' responses summarize the operator's event log and instruction files, so
# they are dropped. Events are kept only for librarian.*.
#
# Usage: reduce.sh <out_dir>
set -euo pipefail
OUT="${1:?out dir}"
for f in "$OUT"/calls/*.json; do
	args=$(cat "${f%.json}.args")
	depth=${args%% *}
	depth=${depth#depth=}
	agent=""
	[[ "$args" == *--agent* ]] && agent=$(printf '%s\n' "$args" | tr ' ' '\n' | grep -A1 -e '--agent' | tail -1)
	requested=""
	[[ "$args" == *--model* ]] && requested=$(printf '%s\n' "$args" | tr ' ' '\n' | grep -A1 -e '--model' | tail -1)
	jq -c --arg call "$(basename "$f" .json)" --argjson depth "$depth" \
		--arg agent "$agent" --arg requested "$requested" '{
		call: $call, depth: $depth,
		agent: (if $agent == "" then null else $agent end),
		requested_model: (if $requested == "" then null else $requested end),
		models_used: (.modelUsage // {} | keys),
		num_turns, subtype, is_error, duration_ms,
		cost_usd: .total_cost_usd,
		usage: (.usage | {input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens}),
		result: (if $depth == 0 then .result else null end)
	}' "$f"
done > "$OUT/calls.jsonl"
jq -c 'select(.event_type | startswith("librarian."))' "$OUT/events.jsonl" > "$OUT/events.jsonl.tmp"
mv "$OUT/events.jsonl.tmp" "$OUT/events.jsonl"
rm -rf "$OUT/calls"
