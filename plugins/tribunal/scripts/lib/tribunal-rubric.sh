#!/usr/bin/env bash
# Rubric resolution for Tribunal.
#
# Layered lookup (latest wins, by rubric id):
#   1. Built-in rubrics from plugins/tribunal/config.json (.tribunal.rubric.builtins)
#   2. ~/.onlooker/tribunal.json (.rubrics)
#   3. <repo>/.claude/tribunal.json (.rubrics)
#
# Exposes:
#   tribunal_rubric_load <repo_root>         # populates _TRIBUNAL_RUBRICS (JSON array)
#   tribunal_rubric_get <id>                 # echoes a single rubric as JSON, or empty
#   tribunal_rubric_default_id               # default rubric id from config
#   tribunal_rubric_validate <rubric_json>   # exits 0 if valid, 1 otherwise; prints reasons to stderr
#
# Schema:
#   {
#     "id": "default",
#     "criteria": [ { "name": str, "weight": [0,1], "min_pass": [0,1] }, ... ],
#     "score_threshold": [0,1],
#     "max_iterations": int >= 1,
#     "judge_types": ["standard" | "security" | ...],
#     "gate_policy": "strict" | "majority" | "unanimous" | "meta_override",
#     "aggregation_method": "mean" | "median" | "min" | "weighted_mean"
#   }
#
# Requires tribunal-config.sh to be sourced and tribunal_config_load to have run.

_TRIBUNAL_RUBRICS="[]"

_tribunal_rubric_overlay_file() {
	local file="$1"
	local base="$2"
	[[ -f "$file" ]] || { printf '%s' "$base"; return 0; }
	local overlay
	overlay=$(jq -c '.rubrics // []' "$file" 2>/dev/null) || { printf '%s' "$base"; return 0; }
	[[ "$overlay" == "[]" || -z "$overlay" ]] && { printf '%s' "$base"; return 0; }

	jq -c -n --argjson base "$base" --argjson overlay "$overlay" '
		($base + $overlay)
		| reduce .[] as $r ({}; .[$r.id] = $r)
		| [.[]]
	'
}

tribunal_rubric_load() {
	local repo_root="${1:-}"
	local home_dir="${HOME:-}"

	local builtins
	builtins=$(printf '%s' "$_TRIBUNAL_CONFIG" | jq -c '.tribunal.rubric.builtins // []' 2>/dev/null)
	[[ -z "$builtins" ]] && builtins="[]"

	local merged="$builtins"
	merged=$(_tribunal_rubric_overlay_file "${home_dir}/.onlooker/tribunal.json" "$merged")
	merged=$(_tribunal_rubric_overlay_file "${repo_root}/.claude/tribunal.json" "$merged")

	_TRIBUNAL_RUBRICS="$merged"
}

tribunal_rubric_default_id() {
	local id
	id=$(tribunal_config_get '.tribunal.rubric.default_id')
	[[ -z "$id" ]] && id="default"
	printf '%s' "$id"
}

tribunal_rubric_get() {
	local id="$1"
	[[ -z "$id" ]] && return 0
	printf '%s' "$_TRIBUNAL_RUBRICS" | jq -c --arg id "$id" \
		'map(select(.id == $id)) | first // empty' 2>/dev/null
}

# Validate a single rubric JSON blob. Prints reasons to stderr; exits 1 on first
# problem so callers can pipe to a single failure path.
tribunal_rubric_validate() {
	local rubric="${1:-}"
	[[ -z "$rubric" || "$rubric" == "null" ]] && {
		printf 'rubric is empty\n' >&2
		return 1
	}

	local id
	id=$(printf '%s' "$rubric" | jq -r '.id // empty' 2>/dev/null)
	[[ -z "$id" ]] && { printf 'rubric missing .id\n' >&2; return 1; }

	local criteria_count
	criteria_count=$(printf '%s' "$rubric" | jq -r '(.criteria // []) | length' 2>/dev/null)
	[[ "$criteria_count" -ge 1 ]] || {
		printf 'rubric %s: criteria must be non-empty\n' "$id" >&2
		return 1
	}

	# Each criterion: name non-empty, weight in [0,1], min_pass in [0,1].
	local bad_crit
	bad_crit=$(printf '%s' "$rubric" | jq -r '
		[.criteria[]
		 | select(
			 (.name | type) != "string"
			 or (.name | length) == 0
			 or (.weight | type) != "number" or .weight < 0 or .weight > 1
			 or (.min_pass | type) != "number" or .min_pass < 0 or .min_pass > 1
		   )
		 | .name // "(unnamed)"]
		| join(",")
	' 2>/dev/null)
	[[ -n "$bad_crit" ]] && {
		printf 'rubric %s: invalid criteria: %s\n' "$id" "$bad_crit" >&2
		return 1
	}

	# Weights must sum to ~1.0.
	local weight_sum
	weight_sum=$(printf '%s' "$rubric" | jq -r '[.criteria[].weight] | add' 2>/dev/null)
	awk -v s="$weight_sum" 'BEGIN { exit !(s > 0.99 && s < 1.01) }' || {
		printf 'rubric %s: criterion weights sum to %s (expected ~1.0)\n' "$id" "$weight_sum" >&2
		return 1
	}

	# score_threshold in [0,1].
	local thr
	thr=$(printf '%s' "$rubric" | jq -r '.score_threshold // 0.75' 2>/dev/null)
	awk -v t="$thr" 'BEGIN { exit !(t >= 0 && t <= 1) }' || {
		printf 'rubric %s: score_threshold %s out of [0,1]\n' "$id" "$thr" >&2
		return 1
	}

	# gate_policy enum.
	local gp
	gp=$(printf '%s' "$rubric" | jq -r '.gate_policy // "majority"' 2>/dev/null)
	case "$gp" in
		strict|majority|unanimous|meta_override) : ;;
		*) printf 'rubric %s: invalid gate_policy %s\n' "$id" "$gp" >&2; return 1 ;;
	esac

	# aggregation_method enum.
	local am
	am=$(printf '%s' "$rubric" | jq -r '.aggregation_method // "weighted_mean"' 2>/dev/null)
	case "$am" in
		mean|median|min|weighted_mean) : ;;
		*) printf 'rubric %s: invalid aggregation_method %s\n' "$id" "$am" >&2; return 1 ;;
	esac

	# max_iterations integer >= 1.
	local mi
	mi=$(printf '%s' "$rubric" | jq -r '.max_iterations // 3' 2>/dev/null)
	[[ "$mi" =~ ^[0-9]+$ && "$mi" -ge 1 ]] || {
		printf 'rubric %s: max_iterations must be integer >= 1 (got %s)\n' "$id" "$mi" >&2
		return 1
	}

	return 0
}
