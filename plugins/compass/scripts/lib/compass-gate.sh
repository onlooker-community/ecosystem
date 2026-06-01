#!/usr/bin/env bash
# Shared evaluation pipeline for Compass.
#
# Called by compass-pre-tool-use.sh (Write/Edit/MultiEdit) and
# compass-bash-gate.sh (Bash write commands). Contains all gate logic:
#   1. Skip-glob filter
#   2. Dir+stem cooldown check
#   3. Turn budget check
#   4. Context minimum check
#   5. Skip sentinel check
#   6. Symbolic skip layer (reply-to-question pattern)
#   7. Input sanitization
#   8. Prior-turn transcript read
#   9. N=5 parallel evaluator
#  10. Intervention UX on block
#
# Exposes:
#   compass_run_gate <tool_name> <file_path> <operation> \
#                   <context_or_command> <session_id> <cwd>
#
# Hook contract (Claude Code PreToolUse protocol):
#   - Always exits 0.
#   - To block: write {"decision":"block","reason":"..."} to stdout before returning.
#   - To allow: write nothing to stdout.

# -----------------------------------------------------------------------
# Helper: update session state (turn_check_count, circuit_breaker).
# -----------------------------------------------------------------------

_compass_state_file() {
	local session_id="$1"
	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	printf '%s' "${onlooker_dir}/compass/sessions/${session_id}.json"
}

_compass_state_get() {
	local session_id="$1"
	local jq_path="$2"
	local state_file
	state_file=$(_compass_state_file "$session_id")
	[[ -f "$state_file" ]] || { printf ''; return 1; }
	jq -r "${jq_path} // empty" "$state_file" 2>/dev/null
}

_compass_state_update() {
	local session_id="$1"
	local jq_expr="$2"
	local state_file
	state_file=$(_compass_state_file "$session_id")
	[[ -f "$state_file" ]] || return 1
	local updated
	updated=$(jq "$jq_expr" "$state_file" 2>/dev/null) || return 1
	[[ -n "$updated" ]] && printf '%s' "$updated" > "$state_file"
}

_compass_increment_turn_count() {
	local session_id="$1"
	_compass_state_update "$session_id" '.turn_check_count += 1'
}

_compass_record_failure() {
	local session_id="$1"
	_compass_state_update "$session_id" '
		.circuit_breaker.consecutive_failures += 1
	'
}

_compass_reset_failures() {
	local session_id="$1"
	_compass_state_update "$session_id" '
		.circuit_breaker.consecutive_failures = 0
	'
}

_compass_open_circuit() {
	local session_id="$1"
	local now
	now=$(date +%s 2>/dev/null) || now=0
	_compass_state_update "$session_id" \
		--argjson now "$now" \
		'.circuit_breaker.state = "open" | .circuit_breaker.opened_at = $now' \
		2>/dev/null || \
	_compass_state_update "$session_id" \
		".circuit_breaker.state = \"open\" | .circuit_breaker.opened_at = ${now}"
}

# -----------------------------------------------------------------------
# Helper: glob matching for skip_globs.
# -----------------------------------------------------------------------
_compass_matches_skip_glob() {
	local file_path="$1"
	local globs_json="$2"
	[[ -z "$file_path" || -z "$globs_json" ]] && return 1

	# Convert JSON array to bash array and check each pattern.
	local globs
	mapfile -t globs < <(printf '%s' "$globs_json" | jq -r '.[]' 2>/dev/null) || return 1

	local glob
	for glob in "${globs[@]}"; do
		# Use bash glob matching (extglob not needed for ** — use case).
		# Convert ** to a catch-all for simple prefix/suffix matching.
		local pattern="${glob//\*\*/DOUBLE_STAR}"
		pattern="${pattern//\*/[^/]*}"
		pattern="${pattern//DOUBLE_STAR/.*}"
		if [[ "$file_path" =~ $pattern ]]; then
			return 0
		fi
	done
	return 1
}

# -----------------------------------------------------------------------
# Helper: dir+stem identity (same as compass-record-write.sh).
# -----------------------------------------------------------------------
_compass_gate_dir_plus_stem() {
	local path="$1"
	[[ -z "$path" ]] && return 1
	local dir base stem
	dir=$(dirname "$path" 2>/dev/null) || dir="."
	base=$(basename "$path" 2>/dev/null) || base="$path"
	stem="${base%%.*}"
	[[ -z "$stem" ]] && stem="$base"
	printf '%s/%s' "$dir" "$stem"
}

# -----------------------------------------------------------------------
# Helper: cooldown check.
# -----------------------------------------------------------------------
_compass_in_cooldown() {
	local file_path="$1"
	local session_id="$2"
	local cooldown_seconds="$3"

	[[ -z "$file_path" ]] && return 1

	local identity
	identity=$(_compass_gate_dir_plus_stem "$file_path") || return 1

	local state_file
	state_file=$(_compass_state_file "$session_id")
	[[ -f "$state_file" ]] || return 1

	local now
	now=$(date +%s 2>/dev/null) || now=0

	local entry_ts
	entry_ts=$(jq -r \
		--arg identity "$identity" \
		'.cooldown[] | select(.identity == $identity) | .ts' \
		"$state_file" 2>/dev/null | tail -1) || entry_ts=""

	[[ -z "$entry_ts" ]] && return 1

	local age=$(( now - entry_ts ))
	[[ "$age" -le "$cooldown_seconds" ]] && return 0
	return 1
}

# -----------------------------------------------------------------------
# Helper: symbolic skip layer (reply-to-question pattern).
# -----------------------------------------------------------------------
_compass_symbolic_skip() {
	local prior_turn="$1"
	local context_excerpt="$2"

	[[ -z "$prior_turn" ]] && return 1

	# Condition 1: prior turn contains a numbered list and a question mark.
	local has_numbered_list has_question
	has_numbered_list=$(printf '%s' "$prior_turn" \
		| grep -cE '^\s*[0-9]+[.)]\s+' 2>/dev/null) || has_numbered_list=0
	has_question=$(printf '%s' "$prior_turn" | grep -c '?' 2>/dev/null) || has_question=0

	[[ "$has_numbered_list" -eq 0 || "$has_question" -eq 0 ]] && return 1

	# Condition 2: context excerpt looks like an option reference or affirmation.
	local trimmed_context
	trimmed_context=$(printf '%s' "$context_excerpt" | tr -s ' \t\n' ' ' | sed 's/^ *//;s/ *$//' 2>/dev/null) \
		|| trimmed_context="$context_excerpt"

	if printf '%s' "$trimmed_context" | grep -qiE \
		'^(yes|no|both|all|none|either|ok|okay|sure|the (first|second|third|fourth|fifth)|option [0-9]|[0-9]+[.)]?$)' \
		2>/dev/null; then
		return 0
	fi

	return 1
}

# -----------------------------------------------------------------------
# Intervention output — block with structured message.
# -----------------------------------------------------------------------
_compass_intervention() {
	local tool_name="$1"
	local file_path="$2"
	local confidence="$3"
	local stddev="$4"
	local primary_concern="$5"
	local rationale="$6"
	local session_id="$7"
	local confidence_threshold="$8"
	local stddev_threshold="$9"

	local block_reason=""
	local passed_conf passed_std
	passed_conf=$(awk "BEGIN {exit !(${confidence:-0} >= ${confidence_threshold:-0.65})}" 2>/dev/null && echo true || echo false)
	passed_std=$(awk "BEGIN {exit !(${stddev:-1} <= ${stddev_threshold:-0.20})}" 2>/dev/null && echo true || echo false)

	if [[ "$passed_conf" != "true" && "$passed_std" != "true" ]]; then
		block_reason="low confidence and high evaluator disagreement"
	elif [[ "$passed_conf" != "true" ]]; then
		block_reason="low confidence (${confidence} < ${confidence_threshold})"
	else
		block_reason="high evaluator disagreement (stddev ${stddev} > ${stddev_threshold})"
	fi

	local message
	message=$(printf \
'Compass blocked this write — %s.

  File: %s
  Tool: %s
  Confidence: %s  Stddev: %s  Concern: %s
  Evaluator rationale: %s

Choose a path:
  • Type compass: proceed  — override and allow this write
  • Provide more context   — compass will re-evaluate once with your clarification
  • Type compass: cancel   — abandon this write' \
		"$block_reason" "$file_path" "$tool_name" \
		"${confidence:-n/a}" "${stddev:-n/a}" "${primary_concern:-none}" \
		"${rationale:-(none)}")

	jq -n \
		--arg message "$message" \
		--arg decision "block" \
		'{"decision": $decision, "reason": $message}' 2>/dev/null \
		|| printf '{"decision":"block","reason":"Compass blocked this write — intent unclear."}'
}

# -----------------------------------------------------------------------
# Main gate function.
# $1 — tool_name   (Write | Edit | MultiEdit | Bash)
# $2 — file_path   (may be empty for Bash)
# $3 — operation   (write | edit | multi_edit | bash_write)
# $4 — context     (context excerpt or bash command string)
# $5 — session_id
# $6 — cwd
# -----------------------------------------------------------------------
compass_run_gate() {
	local tool_name="$1"
	local file_path="$2"
	local operation="$3"
	local context="$4"
	local session_id="${5:-unknown}"
	local cwd="${6:-}"

	local _allow_exit=0
	local _block_exit=0

	# ---- Rule 1: skip sentinel ----------------------------------------
	if printf '%s' "${context}${file_path}" | grep -qF '[compass:skip]' 2>/dev/null; then
		compass_emit_event "compass.check.skipped" \
			"$(jq -n --arg r "skip_sentinel" --arg f "$file_path" \
			'{reason:$r,file_path:$f}' 2>/dev/null || echo '{}')" 2>/dev/null || true
		return $_allow_exit
	fi

	# ---- Rule 2: skip_globs -------------------------------------------
	local skip_globs_json
	skip_globs_json=$(compass_config_get_json '.compass.skip_globs') || skip_globs_json="[]"
	if [[ -n "$file_path" ]] && _compass_matches_skip_glob "$file_path" "$skip_globs_json"; then
		compass_emit_event "compass.check.skipped" \
			"$(jq -n --arg r "skip_glob" --arg f "$file_path" \
			'{reason:$r,file_path:$f}' 2>/dev/null || echo '{}')" 2>/dev/null || true
		return $_allow_exit
	fi

	# ---- Rule 3: dir+stem cooldown ------------------------------------
	local cooldown_seconds
	cooldown_seconds=$(compass_config_get '.compass.cooldown.seconds')
	cooldown_seconds="${cooldown_seconds:-120}"
	if [[ -n "$file_path" ]] && _compass_in_cooldown "$file_path" "$session_id" "$cooldown_seconds"; then
		compass_emit_event "compass.check.skipped" \
			"$(jq -n --arg r "dir_plus_stem_cooldown" --arg f "$file_path" \
			'{reason:$r,file_path:$f}' 2>/dev/null || echo '{}')" 2>/dev/null || true
		return $_allow_exit
	fi

	# ---- Rule 4: turn budget ------------------------------------------
	local max_checks
	max_checks=$(compass_config_get '.compass.max_checks_per_turn')
	max_checks="${max_checks:-3}"
	local current_count
	current_count=$(_compass_state_get "$session_id" '.turn_check_count') || current_count=0
	current_count="${current_count:-0}"
	if (( current_count >= max_checks )); then
		compass_emit_event "compass.check.skipped" \
			"$(jq -n --arg r "turn_budget_exhausted" --arg f "$file_path" \
			'{reason:$r,file_path:$f}' 2>/dev/null || echo '{}')" 2>/dev/null || true
		return $_allow_exit
	fi

	# ---- Rule 5: context minimum -------------------------------------
	local min_context_chars
	min_context_chars=$(compass_config_get '.compass.min_context_chars')
	min_context_chars="${min_context_chars:-80}"
	local context_len="${#context}"
	if (( context_len < min_context_chars )); then
		compass_emit_event "compass.check.skipped" \
			"$(jq -n --arg r "insufficient_context" --arg f "$file_path" \
			'{reason:$r,file_path:$f}' 2>/dev/null || echo '{}')" 2>/dev/null || true
		return $_allow_exit
	fi

	# ---- Rule 6: circuit breaker -------------------------------------
	local cb_enabled cb_state cb_failures cb_threshold cb_open_duration
	cb_enabled=$(compass_config_get '.compass.circuit_breaker.enabled')
	cb_enabled="${cb_enabled:-true}"
	if [[ "$cb_enabled" == "true" ]]; then
		cb_state=$(_compass_state_get "$session_id" '.circuit_breaker.state') || cb_state="closed"
		cb_state="${cb_state:-closed}"
		if [[ "$cb_state" == "open" ]]; then
			cb_open_duration=$(compass_config_get '.compass.circuit_breaker.open_duration_seconds')
			cb_open_duration="${cb_open_duration:-300}"
			local opened_at
			opened_at=$(_compass_state_get "$session_id" '.circuit_breaker.opened_at') || opened_at=0
			opened_at="${opened_at:-0}"
			local now
			now=$(date +%s 2>/dev/null) || now=0
			local open_age=$(( now - opened_at ))
			if (( open_age < cb_open_duration )); then
				compass_emit_event "compass.check.skipped" \
					"$(jq -n --arg r "circuit_open" --arg f "$file_path" \
					'{reason:$r,file_path:$f}' 2>/dev/null || echo '{}')" 2>/dev/null || true
				return $_allow_exit
			else
				# TTL expired — close the circuit and proceed.
				_compass_state_update "$session_id" \
					'.circuit_breaker.state = "closed" | .circuit_breaker.opened_at = null' \
					2>/dev/null || true
			fi
		fi
	fi

	# ---- Increment turn check count ----------------------------------
	_compass_increment_turn_count "$session_id" 2>/dev/null || true

	# ---- Read prior assistant turn -----------------------------------
	local prior_turn_chars_max transcript_max_age
	prior_turn_chars_max=$(compass_config_get '.compass.transcript.prior_turn_chars_max')
	prior_turn_chars_max="${prior_turn_chars_max:-800}"
	transcript_max_age=$(compass_config_get '.compass.transcript.transcript_max_age_seconds')
	transcript_max_age="${transcript_max_age:-300}"

	local prior_turn=""
	prior_turn=$(compass_read_prior_turn "$session_id" "$prior_turn_chars_max" "$transcript_max_age") \
		|| prior_turn=""

	# ---- Symbolic skip layer -----------------------------------------
	local skip_reply_enabled
	skip_reply_enabled=$(compass_config_get '.compass.skip_patterns.reply_to_question.enabled')
	skip_reply_enabled="${skip_reply_enabled:-true}"
	if [[ "$skip_reply_enabled" == "true" ]] && _compass_symbolic_skip "$prior_turn" "$context"; then
		compass_emit_event "compass.check.skipped" \
			"$(jq -n --arg r "reply_to_question_pattern" --arg f "$file_path" \
			'{reason:$r,file_path:$f}' 2>/dev/null || echo '{}')" 2>/dev/null || true
		return $_allow_exit
	fi

	# ---- Sanitize context excerpt ------------------------------------
	local context_chars_max
	context_chars_max=$(compass_config_get '.compass.context_chars_max')
	context_chars_max="${context_chars_max:-600}"
	local sanitized_context
	sanitized_context=$(compass_sanitize "$context" "$context_chars_max")

	local sanitized_path
	sanitized_path=$(compass_sanitize "$file_path" 0)

	# ---- Run evaluator -----------------------------------------------
	local eval_result eval_exit
	eval_result=$(compass_evaluate \
		"$tool_name" "$sanitized_path" "$operation" \
		"$prior_turn" "$sanitized_context" "$session_id")
	eval_exit=$?

	local decision confidence stddev primary_concern rationale
	decision=$(printf '%s' "$eval_result" | jq -r '.decision // "error"' 2>/dev/null) || decision="error"
	confidence=$(printf '%s' "$eval_result" | jq -r '.confidence // ""' 2>/dev/null) || confidence=""
	stddev=$(printf '%s' "$eval_result" | jq -r '.stddev // ""' 2>/dev/null) || stddev=""
	primary_concern=$(printf '%s' "$eval_result" | jq -r '.primary_concern // "none"' 2>/dev/null) || primary_concern="none"
	rationale=$(printf '%s' "$eval_result" | jq -r '.rationale // ""' 2>/dev/null) || rationale=""

	local had_prior_turn="false"
	[[ -n "$prior_turn" ]] && had_prior_turn="true"

	local confidence_threshold stddev_threshold
	confidence_threshold=$(compass_config_get '.compass.confidence_threshold')
	confidence_threshold="${confidence_threshold:-0.65}"
	stddev_threshold=$(compass_config_get '.compass.stddev_threshold')
	stddev_threshold="${stddev_threshold:-0.20}"

	if [[ "$decision" == "error" ]]; then
		local error_policy
		error_policy=$(compass_config_get '.compass.error_policy')
		error_policy="${error_policy:-closed}"

		_compass_record_failure "$session_id" 2>/dev/null || true

		cb_failures=$(_compass_state_get "$session_id" '.circuit_breaker.consecutive_failures') \
			|| cb_failures=0
		cb_failures="${cb_failures:-0}"
		cb_threshold=$(compass_config_get '.compass.circuit_breaker.consecutive_failures_to_open')
		cb_threshold="${cb_threshold:-3}"
		if [[ "$cb_enabled" == "true" ]] && (( cb_failures >= cb_threshold )); then
			_compass_open_circuit "$session_id" 2>/dev/null || true
		fi

		compass_emit_event "compass.check.skipped" \
			"$(jq -n --arg r "sampler_error" --arg f "$file_path" \
			'{reason:$r,file_path:$f}' 2>/dev/null || echo '{}')" 2>/dev/null || true

		[[ "$error_policy" == "open" ]] && return $_allow_exit
		# fail-closed: block
		_compass_intervention \
			"$tool_name" "$file_path" "" "" "none" \
			"Evaluator failed — cannot verify intent clarity." \
			"$session_id" "$confidence_threshold" "$stddev_threshold"
		return $_block_exit
	fi

	# ---- Emit result event -------------------------------------------
	if [[ "$decision" == "pass" ]]; then
		_compass_reset_failures "$session_id" 2>/dev/null || true
		compass_emit_event "compass.check.passed" \
			"$(jq -n \
				--arg f "$file_path" \
				--arg t "$tool_name" \
				--arg hpt "$had_prior_turn" \
				--argjson conf "${confidence:-0}" \
				--argjson std "${stddev:-0}" \
				'{confidence:$conf,stddev:$std,file_path:$f,tool_name:$t,had_prior_turn:($hpt=="true")}' \
				2>/dev/null || echo '{}')" 2>/dev/null || true
		return $_allow_exit
	fi

	# decision == fail
	compass_emit_event "compass.check.failed" \
		"$(jq -n \
			--arg f "$file_path" \
			--arg concern "$primary_concern" \
			--argjson conf "${confidence:-0}" \
			--argjson std "${stddev:-0}" \
			'{confidence:$conf,stddev:$std,primary_concern:$concern,file_path:$f}' \
			2>/dev/null || echo '{}')" 2>/dev/null || true

	_compass_intervention \
		"$tool_name" "$file_path" \
		"${confidence:-0}" "${stddev:-0}" \
		"$primary_concern" "$rationale" \
		"$session_id" "$confidence_threshold" "$stddev_threshold"
	return $_block_exit
}
