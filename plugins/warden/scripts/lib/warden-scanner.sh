#!/usr/bin/env bash
# Hybrid scanner orchestration for Warden.
#
# Combines the deterministic pattern floor (warden-patterns.sh) with optional
# LLM escalation (warden-evaluator.sh):
#
#   strong pattern hit  → detected immediately (no model call)
#   weak pattern hit     → escalate to the evaluator when enabled; otherwise
#                          fall back to the weak-pattern confidence
#   no hit               → clean (no model call)
#
# On evaluator error the scanner falls back to the pattern verdict, so a model
# outage degrades coverage but never silently closes the gate on every read.
#
# Depends on (sourced by the caller):
#   warden-config.sh · warden-patterns.sh · warden-sanitizer.sh · warden-evaluator.sh
#
# Exposes:
#   warden_scan <source_type> <content>
#     → JSON {"detected":bool, "threat_type":"<t>", "confidence":<f>,
#             "matched_pattern":"<p>", "method":"<m>", "rationale":"<str>"}

# awk-based float >= comparison. Returns 0 (true) if $1 >= $2.
#
# Values are passed via `awk -v` (data), never interpolated into the program
# string: thresholds can originate from repo-level .claude/settings.json, which
# is untrusted under warden's threat model. -v also makes non-numeric input
# degrade to 0 rather than executing as awk code.
_warden_ge() {
	awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN {exit !(a >= b)}' 2>/dev/null
}

_warden_scan_result() {
	local detected="$1" threat="$2" confidence="$3" pattern="$4" method="$5" rationale="$6"
	jq -n \
		--argjson detected "$detected" \
		--arg t "$threat" \
		--argjson c "${confidence:-0}" \
		--arg p "$pattern" \
		--arg m "$method" \
		--arg r "$rationale" \
		'{detected:$detected, threat_type:$t, confidence:$c, matched_pattern:$p, method:$m, rationale:$r}' \
		2>/dev/null \
		|| printf '{"detected":%s,"threat_type":"%s","confidence":%s,"matched_pattern":"%s","method":"%s","rationale":"%s"}' \
			"$detected" "$threat" "${confidence:-0}" "$pattern" "$method" "$rationale"
}

warden_scan() {
	local source_type="$1"
	local content="$2"

	local close_threshold strong_conf weak_conf
	close_threshold=$(warden_config_get '.warden.detection.close_threshold')
	close_threshold="${close_threshold:-0.65}"
	strong_conf=$(warden_config_get '.warden.detection.strong_pattern_confidence')
	strong_conf="${strong_conf:-0.9}"
	weak_conf=$(warden_config_get '.warden.detection.weak_pattern_confidence')
	weak_conf="${weak_conf:-0.5}"

	local classify severity threat pattern
	classify=$(warden_pattern_classify "$content")
	severity=$(printf '%s' "$classify" | jq -r '.severity // "none"' 2>/dev/null) || severity="none"
	threat=$(printf '%s' "$classify" | jq -r '.threat_type // "none"' 2>/dev/null) || threat="none"
	pattern=$(printf '%s' "$classify" | jq -r '.matched_pattern // ""' 2>/dev/null) || pattern=""

	# ---- Clean: no signal at all. ------------------------------------
	if [[ "$severity" == "none" ]]; then
		_warden_scan_result false "none" 0 "" "none" "no injection pattern matched"
		return 0
	fi

	# ---- Strong: explicit, high-precision phrasing. ------------------
	if [[ "$severity" == "strong" ]]; then
		local detected="false"
		_warden_ge "$strong_conf" "$close_threshold" && detected="true"
		_warden_scan_result "$detected" "$threat" "$strong_conf" "$pattern" "pattern_strong" "matched a strong injection signature"
		return 0
	fi

	# ---- Weak: borderline. Escalate when enabled. --------------------
	local escalation_enabled
	escalation_enabled=$(warden_config_get '.warden.escalation.enabled')
	escalation_enabled="${escalation_enabled:-true}"

	if [[ "$escalation_enabled" == "true" ]]; then
		local max_chars excerpt
		max_chars=$(warden_config_get '.warden.scan.max_content_chars')
		max_chars="${max_chars:-20000}"
		excerpt=$(warden_sanitize "$content" "$max_chars")

		local eval_result decision eval_conf eval_threat eval_rationale
		eval_result=$(warden_evaluate "$source_type" "$excerpt" "$threat")
		decision=$(printf '%s' "$eval_result" | jq -r '.decision // "error"' 2>/dev/null) || decision="error"
		eval_conf=$(printf '%s' "$eval_result" | jq -r '.confidence // 0' 2>/dev/null) || eval_conf="0"
		eval_threat=$(printf '%s' "$eval_result" | jq -r '.threat_type // "none"' 2>/dev/null) || eval_threat="none"
		eval_rationale=$(printf '%s' "$eval_result" | jq -r '.rationale // ""' 2>/dev/null) || eval_rationale=""

		if [[ "$decision" == "injection" ]]; then
			[[ "$eval_threat" == "none" || -z "$eval_threat" ]] && eval_threat="$threat"
			local detected="false"
			_warden_ge "$eval_conf" "$close_threshold" && detected="true"
			_warden_scan_result "$detected" "$eval_threat" "$eval_conf" "$pattern" "escalation" "$eval_rationale"
			return 0
		fi

		if [[ "$decision" == "clean" ]]; then
			_warden_scan_result false "none" "$eval_conf" "$pattern" "escalation" "evaluator judged the borderline content clean"
			return 0
		fi

		# decision == error → fall back to the weak-pattern verdict below.
	fi

	# ---- Weak fallback: no escalation, or evaluator errored. ---------
	local detected="false"
	_warden_ge "$weak_conf" "$close_threshold" && detected="true"
	_warden_scan_result "$detected" "$threat" "$weak_conf" "$pattern" "pattern_weak" "weak injection signal; escalation unavailable"
	return 0
}
