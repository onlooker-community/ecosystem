#!/usr/bin/env bash
# Input sanitization for Compass evaluator-bound fields.
#
# Applied before any user-supplied content is interpolated into the
# evaluator prompt. Prevents prompt injection via crafted file names,
# file contents, or conversation text.
#
# Exposes:
#   compass_sanitize <string> <max_chars>   # echoes sanitized, truncated string
#   compass_sanitize_field <field> <string> # echoes sanitized string for a named field
#
# Sanitization steps (applied in order):
#   1. Null-byte removal
#   2. Control-character removal (0x00–0x1F and 0x7F, except \t and \n)
#   3. XML delimiter stripping (evaluator prompt tag sequences → [STRIPPED])
#   4. Truncation to max_chars

# Tags that, if present in user-supplied data, would inject into the evaluator prompt.
_COMPASS_STRIP_SEQUENCES=(
	"<prior_assistant_turn>"
	"</prior_assistant_turn>"
	"<context_excerpt>"
	"</context_excerpt>"
	"<tool_input>"
	"</tool_input>"
	"<instructions>"
	"</instructions>"
	"<|"
	"[INST]"
	"[/INST]"
	"<<SYS>>"
	"<</SYS>>"
)

# Remove null bytes and ASCII control characters except \t (0x09) and \n (0x0A).
_compass_strip_control_chars() {
	local input="$1"
	# tr: delete bytes 0x00-0x08, 0x0B-0x1F, 0x7F
	printf '%s' "$input" \
		| tr -d '\000-\010\013-\037\177' \
		2>/dev/null
}

# Replace all occurrences of a literal string with [STRIPPED].
# Uses bash native parameter expansion to avoid the sed delimiter trap —
# needles like </prior_assistant_turn> contain '/' which breaks sed s///.
_compass_strip_literal() {
	local input="$1"
	local needle="$2"
	[[ -z "$needle" ]] && { printf '%s' "$input"; return; }
	printf '%s' "${input//"$needle"/[STRIPPED]}"
}

# Truncate a string to at most max_chars UTF-8 characters.
_compass_truncate() {
	local input="$1"
	local max_chars="${2:-0}"
	if [[ "$max_chars" -le 0 ]]; then
		printf '%s' "$input"
		return
	fi
	printf '%s' "$input" | cut -c "1-${max_chars}" 2>/dev/null
}

# Full sanitization pipeline. Echoes the sanitized string.
#   $1 — raw input string
#   $2 — max chars (0 = no truncation)
compass_sanitize() {
	local input="$1"
	local max_chars="${2:-0}"

	local s
	s=$(_compass_strip_control_chars "$input")

	local seq
	for seq in "${_COMPASS_STRIP_SEQUENCES[@]}"; do
		s=$(_compass_strip_literal "$s" "$seq")
	done

	s=$(_compass_truncate "$s" "$max_chars")
	printf '%s' "$s"
}
