#!/usr/bin/env bash
# Deterministic injection-pattern floor for Warden.
#
# Classifies a block of ingested content against a curated set of
# prompt-injection signatures, mapped to the five schema threat_types:
#   prompt_injection · instruction_override · credential_exfiltration
#   command_injection · social_engineering
#
# Two severities:
#   strong — explicit, high-precision phrasing. Closes the gate on its own.
#   weak   — heuristic suspicion. Below the close threshold; escalates to the
#            evaluator (when escalation is enabled) rather than closing alone.
#
# Exposes:
#   warden_pattern_classify <content>
#     → JSON {"severity":"strong|weak|none","threat_type":"<t>",
#             "matched_pattern":"<regex>","hit_count":<n>}
#
# The matched_pattern is retained for the local gate record only — it is NOT
# emitted in warden.threat.detected (the schema forbids extra fields there).

# Each entry: "threat_type|regex" (extended regex, matched case-insensitively).

_WARDEN_STRONG_PATTERNS=(
	# instruction_override — explicit attempts to discard the standing prompt.
	'instruction_override|ignore (all (of )?)?(the )?(previous|prior|above|preceding|earlier) (instructions|prompts|directions|context)'
	'instruction_override|disregard (all |the |any )?(previous|prior|above|earlier|preceding) (instructions|directions|prompts|rules)'
	'instruction_override|forget (everything|all (of )?your|all (the )?previous|your (previous )?instructions)'
	'instruction_override|(override|overrule|bypass) (your|the|all) (instructions|system prompt|guardrails|safety)'
	'instruction_override|do not (follow|obey|comply with) (the|your|any) (previous|prior|system|earlier) (instructions|prompt)'
	# prompt_injection — role / system-prompt hijack and delimiter spoofing.
	'prompt_injection|you are now (a|an|the|in|no longer|free|developer mode)'
	'prompt_injection|new (instructions|system prompt|directives?)( for you)?:'
	'prompt_injection|(reveal|print|repeat|disclose|show) (me )?(your|the) (system prompt|initial instructions|hidden instructions)'
	'prompt_injection|<\/?(system|instructions?|assistant|im_start|im_end)>'
	'prompt_injection|\[/?INST\]|<<SYS>>|<\|im_(start|end)\|>'
	# credential_exfiltration — moving secrets out.
	'credential_exfiltration|(send|post|upload|transmit|exfiltrate|email|leak|forward) .{0,40}(api[ _-]?key|password|secret|token|credential|\.env|private key|ssh key)'
	'credential_exfiltration|(curl|wget|fetch|http) .{0,80}(api[ _-]?key|token|secret|password|\$\{?[A-Z_]*(KEY|TOKEN|SECRET|PASSWORD))'
	'credential_exfiltration|(AWS_SECRET_ACCESS_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN|OPENAI_API_KEY|cat .{0,30}\.env)'
	# command_injection — get the agent to run attacker-chosen commands.
	'command_injection|(curl|wget) .{0,120}\| ?(ba)?sh'
	'command_injection|base64 (--?d|--decode) .{0,80}\| ?(ba)?sh'
	'command_injection|rm -rf (/|~|\$HOME|\*)'
	'command_injection|(run|execute|eval) (the following|this) (command|code|script|payload)'
)

_WARDEN_WEAK_PATTERNS=(
	# social_engineering — pressure and false authority.
	'social_engineering|do not (tell|inform|notify|alert) (the )?(user|human|operator)'
	'social_engineering|without (asking|informing|telling|notifying) (the )?(user|anyone)'
	'social_engineering|i am (your|the) (developer|administrator|admin|owner|creator|operator)'
	'social_engineering|as an? (authorized|trusted|admin|administrator|privileged) (user|agent|developer)'
	'social_engineering|this is (urgent|critical|an emergency|time.?sensitive)'
	# prompt_injection — softer instruction-shaped imperatives in fetched text.
	'prompt_injection|(important|attention|note to|message for|hey) (ai|assistant|claude|chatbot|llm|model)'
	'prompt_injection|(please |kindly )?(now )?(follow|execute|carry out) (these|the following) (instructions|steps|commands)'
	# command_injection — pipe-to-shell shapes that did not hit the strong rule.
	'command_injection|(eval|exec|system)\(.{0,60}\)'
)

# Run one pattern list against the content. Echoes the first matching entry's
# "threat_type|matched_regex" and returns 0; returns 1 if nothing matches.
_warden_first_match() {
	local content="$1"
	shift
	local entry threat regex
	for entry in "$@"; do
		threat="${entry%%|*}"
		regex="${entry#*|}"
		if printf '%s' "$content" | grep -iqE -- "$regex" 2>/dev/null; then
			printf '%s|%s' "$threat" "$regex"
			return 0
		fi
	done
	return 1
}

# Count how many entries in a list match (signal strength for borderline calls).
_warden_count_matches() {
	local content="$1"
	shift
	local entry regex count=0
	for entry in "$@"; do
		regex="${entry#*|}"
		if printf '%s' "$content" | grep -iqE -- "$regex" 2>/dev/null; then
			count=$((count + 1))
		fi
	done
	printf '%d' "$count"
}

# Classify content. Echoes a JSON verdict object.
warden_pattern_classify() {
	local content="$1"

	local strong_hit weak_hit
	strong_hit=$(_warden_first_match "$content" "${_WARDEN_STRONG_PATTERNS[@]}") || strong_hit=""

	if [[ -n "$strong_hit" ]]; then
		local threat="${strong_hit%%|*}"
		local regex="${strong_hit#*|}"
		local n
		n=$(_warden_count_matches "$content" "${_WARDEN_STRONG_PATTERNS[@]}")
		jq -n \
			--arg sev "strong" \
			--arg t "$threat" \
			--arg p "$regex" \
			--argjson n "$n" \
			'{severity:$sev, threat_type:$t, matched_pattern:$p, hit_count:$n}' 2>/dev/null \
			|| printf '{"severity":"strong","threat_type":"%s","matched_pattern":"","hit_count":%s}' "$threat" "$n"
		return 0
	fi

	weak_hit=$(_warden_first_match "$content" "${_WARDEN_WEAK_PATTERNS[@]}") || weak_hit=""
	if [[ -n "$weak_hit" ]]; then
		local threat="${weak_hit%%|*}"
		local regex="${weak_hit#*|}"
		local n
		n=$(_warden_count_matches "$content" "${_WARDEN_WEAK_PATTERNS[@]}")
		jq -n \
			--arg sev "weak" \
			--arg t "$threat" \
			--arg p "$regex" \
			--argjson n "$n" \
			'{severity:$sev, threat_type:$t, matched_pattern:$p, hit_count:$n}' 2>/dev/null \
			|| printf '{"severity":"weak","threat_type":"%s","matched_pattern":"","hit_count":%s}' "$threat" "$n"
		return 0
	fi

	printf '{"severity":"none","threat_type":"none","matched_pattern":"","hit_count":0}'
}
