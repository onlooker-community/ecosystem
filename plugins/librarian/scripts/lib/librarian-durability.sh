#!/usr/bin/env bash
# Cheap pre-LLM durability filter for librarian candidates.
#
# Drops obvious session-only items before paying for classification:
#   - Drop if detail.length < min_detail_chars
#   - Drop if matches a drop-list phrase
#   - Keep if matches a marker phrase ("always", "never", "remember", ...)
#   - Keep if files[] contains a path that still exists in the repo
#     (caller-supplied flag — we don't shell out to git here)
#
# Output: JSON array of surviving candidates plus a drop-reason record for
# each rejected item so the scan-complete event can report counts.

# Default drop-list patterns: terse meta-conversation that almost never
# promotes well. Matched case-insensitively against summary+detail.
_LIBRARIAN_DURABILITY_DROP_PATTERNS=(
	"the test is failing"
	"let me check"
	"i'll come back to this"
	"i will come back to this"
	"working on it"
	"investigating"
)

# Apply the durability filter to a JSON array of candidates.
#
# Usage: librarian_durability_filter <candidates_json> <markers_json> \
#                                    <min_detail_chars>
#
# Args:
#   candidates_json    Array of archivist artifacts (from
#                      librarian_archivist_load_since).
#   markers_json       JSON array of marker phrases (from config).
#   min_detail_chars   Minimum detail length to keep an artifact.
#
# Output: JSON object with two keys:
#   { "kept":    [<artifact>, ...],
#     "dropped": [{ "artifact_id": "...", "reason": "..." }, ...] }
librarian_durability_filter() {
	local candidates="${1:-[]}"
	local markers_json="${2:-[]}"
	local min_detail="${3:-40}"

	local drops
	drops=$(printf '%s\n' "${_LIBRARIAN_DURABILITY_DROP_PATTERNS[@]}" \
		| jq -R . | jq -s .)

	# All filtering happens in one jq expression to avoid bash-side iteration
	# for what's a pure data transform.
	printf '%s' "$candidates" | jq \
		--argjson markers "$markers_json" \
		--argjson drops "$drops" \
		--argjson min_detail "$min_detail" \
		'
		def normalized: ((.summary // "") + " " + (.detail // "")) | ascii_downcase;
		def matches_any($patterns): . as $text | $patterns | any(. as $p | ($text | contains($p)));

		def classify(c):
			c | normalized as $text |
			(c.detail // "") as $detail |
			if ($detail | length) < $min_detail then
				{ kept: false, reason: "detail_too_short" }
			elif ($text | matches_any($drops)) then
				{ kept: false, reason: "filter_drop_pattern" }
			elif ($text | matches_any($markers)) then
				{ kept: true, reason: "marker_phrase_match" }
			else
				{ kept: false, reason: "filter_marker_missing" }
			end;

		map(. as $c | classify($c) as $r | $c + { _filter: $r })
		| {
			kept: [.[] | select(._filter.kept) | del(._filter)],
			dropped: [.[] | select(._filter.kept | not) | { artifact_id: .id, reason: ._filter.reason }]
		}
		'
}
