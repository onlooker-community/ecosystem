#!/usr/bin/env bash
# The evaluation prompt echo's judge is given.
#
# Originally extracted from echo-stop-gate.sh so the spread harness could send
# the judge exactly what the hook sent it. ONL-103 retired that hook, and the
# lib stays here because both runners now share it
# (scripts/measure-judge-spread.sh and scripts/measure-pairwise-discrimination.sh):
# two copies of a prompt drift apart silently, and this repo already learned
# that the expensive way, with fourteen hooks hand-rolling one substrate lookup
# and all fourteen wrong the same two ways (ecosystem-449.36, ecosystem-449.35).
#
# Changing anything below invalidates comparison against every committed
# measurement, because each result is a property of THIS prompt scored by a
# particular model. Both runners stamp a prompt fingerprint into their output
# so a changed prompt is detectable rather than merely suspected. See
# plugins/echo/docs/adr/004-drift-threshold-from-measured-spread.md and
# docs/adr/005-retire-the-stop-gate.md.
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

# The pairwise comparison prompt (ONL-103).
#
# The absolute rubric above has a measured signal-to-noise of 0.61 -- it cannot
# reliably separate two different documents, and separating two versions of one
# document is harder. A pairwise verdict needs no stable absolute scale, which
# is exactly what that measurement says is missing.
#
# "better" always refers to DOCUMENT B. Stating the direction in the prompt
# rather than inferring it from argument order is what makes the antisymmetry
# check meaningful: a judge that prefers slot two produces discrimination that
# looks excellent and means nothing, and the only way to see that is to run
# both orders and compare.
#
# The tie permission is load-bearing. A model asked to compare is reluctant to
# call two things equal, and the self-comparison arm measures nothing else. A
# self_tie_rate that fails because the prompt never invited a tie is a prompt
# defect masquerading as a finding about pairwise comparison.
#
# Exposes:
#   echo_build_pairwise_prompt <rel_a> <content_a> <rel_b> <content_b>
echo_build_pairwise_prompt() {
	local rel_a="$1" content_a="$2" rel_b="$3" content_b="$4"
	printf '%s\n' 'You are comparing two agent prompt files. Return JSON only — no prose, no markdown fences.'
	printf '\n'
	printf '%s\n' 'Output schema (exactly these keys):'
	printf '%s\n' '{'
	printf '%s\n' '  "verdict": "better" | "worse" | "same",'
	printf '%s\n' '  "confidence": 0.0..1.0,'
	printf '%s\n' '  "reason": "1-2 sentences naming the deciding difference."'
	printf '%s\n' '}'
	printf '\n'
	printf '%s\n' 'The verdict is about DOCUMENT B, relative to DOCUMENT A:'
	printf '%s\n' '  "better" — DOCUMENT B is the better prompt file'
	printf '%s\n' '  "worse"  — DOCUMENT B is the worse prompt file'
	printf '%s\n' '  "same"   — neither is meaningfully better'
	printf '\n'
	printf '%s\n' 'Judge on: role clarity, unambiguous output format, criterion coverage, and internal consistency.'
	printf '\n'
	printf '%s\n' 'The two documents may be identical. That is expected and common — answer "same" when they are, and whenever the difference between them does not favor either one.'
	printf '\n'
	printf '%s\n' "---DOCUMENT A: ${rel_a}---"
	printf '%s\n' "$content_a"
	printf '%s\n' '---END DOCUMENT A---'
	printf '\n'
	printf '%s\n' "---DOCUMENT B: ${rel_b}---"
	printf '%s\n' "$content_b"
	printf '%s\n' '---END DOCUMENT B---'
}
