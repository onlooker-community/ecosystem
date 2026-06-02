#!/usr/bin/env bash
# Input sanitization for Warden evaluator-bound content.
#
# Applied before any ingested content is interpolated into the escalation
# evaluator prompt. The content warden scans is, by definition, untrusted —
# so before it is shown to the evaluator it must be neutralized against a
# second-order injection (content that tries to talk the evaluator out of
# flagging it).
#
# Exposes:
#   warden_sanitize <string> <max_chars>   # echoes sanitized, truncated string
#
# Sanitization steps (applied in order):
#   1. Null-byte removal
#   2. Control-character removal (0x00–0x1F and 0x7F, except \t and \n)
#   3. Prompt-delimiter stripping (evaluator prompt tag sequences → [STRIPPED])
#   4. Truncation to max_chars

# Tags that, if present in scanned content, would inject into the evaluator prompt.
_WARDEN_STRIP_SEQUENCES=(
	"<source_content>"
	"</source_content>"
	"<instructions>"
	"</instructions>"
	"<|"
	"[INST]"
	"[/INST]"
	"<<SYS>>"
	"<</SYS>>"
)

# Remove null bytes and ASCII control characters except \t (0x09) and \n (0x0A).
_warden_strip_control_chars() {
	local input="$1"
	printf '%s' "$input" \
		| tr -d '\000-\010\013-\037\177' \
		2>/dev/null
}

# Replace all occurrences of a literal string with [STRIPPED].
#
# Uses bash native substring replacement rather than sed: the strip sequences
# contain '/', '[', and '|', any of which would collide with sed's delimiter
# or regex syntax. Quoting the needle in ${var//"needle"/repl} forces a literal
# (non-glob) match that is safe for arbitrary bytes.
_warden_strip_literal() {
	local input="$1"
	local needle="$2"
	printf '%s' "${input//"$needle"/[STRIPPED]}"
}

# Truncate a string to at most max_chars characters.
_warden_truncate() {
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
warden_sanitize() {
	local input="$1"
	local max_chars="${2:-0}"

	local s
	s=$(_warden_strip_control_chars "$input")

	local seq
	for seq in "${_WARDEN_STRIP_SEQUENCES[@]}"; do
		s=$(_warden_strip_literal "$s" "$seq")
	done

	s=$(_warden_truncate "$s" "$max_chars")
	printf '%s' "$s"
}
