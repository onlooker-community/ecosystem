#!/usr/bin/env bash
# The evaluation prompt echo's judge is given.
#
# Extracted from echo-stop-gate.sh so the spread harness
# (scripts/measure-judge-spread.sh) can send the judge exactly what the hook
# sends it. A measurement taken against a different prompt does not transfer,
# and two copies of a prompt drift apart silently -- this repo already learned
# that the expensive way, with fourteen hooks hand-rolling one substrate lookup
# and all fourteen wrong the same two ways (ecosystem-449.36, ecosystem-449.35).
#
# Changing anything below invalidates the measured drift_threshold, because the
# threshold is a property of THIS prompt scored by a particular model. See
# plugins/echo/docs/adr/004-drift-threshold-from-measured-spread.md.
#
# Exposes:
#   echo_build_judge_prompt <rel_path> <content>   # writes the prompt to stdout

echo_build_judge_prompt() {
	local rel_path="$1" content="$2"
	printf '%s\n' 'You are evaluating an agent prompt file for quality. Return JSON only — no prose, no markdown fences.'
	printf '\n'
	printf '%s\n' 'Output schema (exactly these keys):'
	printf '%s\n' '{'
	printf '%s\n' '  "score": 0.0..1.0,'
	printf '%s\n' '  "passed": true|false,'
	printf '%s\n' '  "confidence": 0.0..1.0,'
	printf '%s\n' '  "feedback": "1-2 sentences on the highest-leverage issue, if any."'
	printf '%s\n' '}'
	printf '\n'
	printf '%s\n' 'Score on these criteria (equal weight):'
	printf '%s\n' '  - Role clarity: does the file clearly define what the agent is and what it must do?'
	printf '%s\n' '  - Output format: are output format and schema requirements unambiguous?'
	printf '%s\n' '  - Criterion coverage: are all evaluation dimensions specified with enough detail to apply consistently?'
	printf '%s\n' '  - Internal consistency: no contradictory instructions, no undefined terms.'
	printf '\n'
	printf '%s\n' "A score >= 0.7 is \"passed\". Be concise."
	printf '\n'
	printf '%s\n' "---FILE: ${rel_path}---"
	printf '%s\n' "$content"
	printf '%s\n' '---END FILE---'
}
