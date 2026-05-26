#!/usr/bin/env bash
# Token estimation for the governor pre-call gate.
#
# Uses a tier-table approach: estimate from tool input JSON size with a
# per-content-type characters-per-token ratio, then multiply by a
# configurable safety margin.
#
# Tier table (characters per token):
#   ASCII prose      4.0
#   code / JSON      3.0
#   mixed            2.5
#   non-Latin        1.5
#
# Safety margin (config: governor.estimation.safety_margin, default 1.3)
# is applied before the gate check. Hard stop margin
# (governor.estimation.hard_stop_margin, default 1.5) is the threshold
# for a blocking decision regardless of enforcement mode.
#
# Estimation method tag emitted in governor.gate.checked: "tier_table"
#
# Exposes:
#   governor_estimate_tokens <json_input>   # echoes integer estimate
#   governor_estimate_cost <tokens> <model> # echoes float USD estimate
#   governor_estimate_method                # echoes "tier_table"

governor_estimate_method() {
	printf 'tier_table'
}

# Detect content tier from a sample of text.
# Returns one of: ascii_prose code_json mixed non_latin
_governor_detect_tier() {
	local sample="${1:-}"
	local len=${#sample}
	[[ $len -eq 0 ]] && { printf 'ascii_prose'; return 0; }

	# Check for structural characters that signal code/JSON
	local struct_count
	struct_count=$(printf '%s' "$sample" | tr -cd '{}[]():;=><' | wc -c 2>/dev/null) \
		|| struct_count=0
	struct_count=$(printf '%s' "$struct_count" | tr -d ' ')

	# >= 10% structural → code/JSON
	if (( struct_count * 10 >= len )); then
		printf 'code_json'
		return 0
	fi

	# Non-ASCII byte presence signals non-Latin
	local ascii_count
	ascii_count=$(printf '%s' "$sample" | tr -cd '[:print:][:space:]' | wc -c 2>/dev/null) \
		|| ascii_count=$len
	ascii_count=$(printf '%s' "$ascii_count" | tr -d ' ')

	if (( ascii_count * 10 < len * 7 )); then
		printf 'non_latin'
		return 0
	fi

	# 5–9% structural → mixed (prose with embedded code/JSON)
	if (( struct_count * 20 >= len )); then
		printf 'mixed'
		return 0
	fi

	printf 'ascii_prose'
}

# Estimate token count from a JSON input string.
# Usage: tokens=$(governor_estimate_tokens "$json_input")
governor_estimate_tokens() {
	local json_input="${1:-}"
	local safety_margin="${2:-}"

	[[ -z "$safety_margin" ]] && {
		safety_margin=$(governor_config_get '.governor.estimation.safety_margin' 2>/dev/null)
		safety_margin="${safety_margin:-1.3}"
	}

	local char_count=${#json_input}
	[[ $char_count -eq 0 ]] && { printf '100'; return 0; }

	local sample="${json_input:0:2000}"
	local tier
	tier=$(_governor_detect_tier "$sample")

	local chars_per_token
	case "$tier" in
		code_json)  chars_per_token="3.0" ;;
		mixed)      chars_per_token="2.5" ;;
		non_latin)  chars_per_token="1.5" ;;
		*)          chars_per_token="4.0" ;;
	esac

	# Single awk pass for fractional chars_per_token and safety margin
	local tokens
	tokens=$(awk "BEGIN { printf \"%d\", int($char_count / $chars_per_token * $safety_margin + 0.999) }" 2>/dev/null) \
		|| tokens=$(( char_count * 2 ))
	(( tokens < 1 )) && tokens=1

	printf '%s' "$tokens"
}

# Rough USD cost estimate from token count.
# Uses Sonnet-class pricing as a conservative default (~$3/M input, $15/M output).
# governor is not aware of the actual model being spawned, so this is a
# planning-time upper bound.
#
# Usage: cost=$(governor_estimate_cost 5000)
governor_estimate_cost() {
	local tokens="${1:-0}"

	# $3 per 1M input + $15 per 1M output; assume 50/50 split → ~$9/M blended
	awk "BEGIN { printf \"%.6f\", ($tokens / 1000000.0) * 9.0 }" 2>/dev/null \
		|| printf '0.0'
}
