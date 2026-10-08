#!/usr/bin/env bash
# Distillation pipeline for Scribe.
#
# Orchestrates the full Stop-time flow:
#   1. Load session state (captured initial prompt)
#   2. Count transcript turns — skip if below min_turns
#   3. Call scribe_extract_intent (Haiku pass)
#   4. Format output as a readable Markdown document
#   5. Write to ~/.onlooker/scribe/<project_key>/
#   6. Optionally mirror to <repo_root>/<project_dir>/
#   7. Emit scribe.distill.complete
#
# Exposes:
#   scribe_distill <session_id> <cwd> <transcript_path>
#   _scribe_emit_skip <reason> [turn_count] [last_distilled_turns] [threshold]
#
# Return codes from scribe_distill:
#   0  an intent document was written
#   1  a real failure (no transcript, extraction failed, write failed)
#   2  skipped: fewer turns than scribe.capture.min_turns
#   3  skipped: too few new turns since the last distillation
#
# 2 and 3 are deliberate skips, not errors, and each reports itself as
# scribe.distill.skipped before returning.

# shellcheck source=./scribe-extract.sh
# (caller must source scribe-extract.sh before scribe-distill.sh)

# Report a decision not to distill.
#
# Every way scribe can decline used to be silent, so the only signal was the
# ABSENCE of scribe.distill.complete — which cannot tell "too short" from
# "already covered" from "the hook never fired" (ecosystem-449.21). The numbers
# ride along because below_min_turns and no_new_turns are both "not enough
# turns" and reading them apart afterwards needs the pair that was compared.
#
# Never fails the caller: a skip that cannot be reported is still a skip.
_scribe_emit_skip() {
	local reason="${1:-}" turn_count="${2:-}" last="${3:-}" threshold="${4:-}"

	[[ -z "$reason" ]] && return 0
	declare -F scribe_emit_event >/dev/null 2>&1 || return 0

	local payload
	payload=$(jq -n \
		--arg reason "$reason" \
		--arg tc "$turn_count" \
		--arg last "$last" \
		--arg th "$threshold" \
		'{reason: $reason}
		 + (if $tc   == "" then {} else {turn_count:           ($tc   | tonumber)} end)
		 + (if $last == "" then {} else {last_distilled_turns: ($last | tonumber)} end)
		 + (if $th   == "" then {} else {threshold:            ($th   | tonumber)} end)' \
		2>/dev/null) || return 0

	[[ -n "$payload" ]] && scribe_emit_event "scribe.distill.skipped" "$payload" >/dev/null 2>&1
	return 0
}

# Where the turn count of the last successful distillation is recorded.
#
# Deliberately NOT <session>.json: scribe-capture.sh read-modify-writes that
# file on every UserPromptSubmit, and a detached distillation writing it at the
# same time could drop captured_prompt. A separate file shares no writer.
_scribe_distill_marker_path() {
	printf '%s/scribe/sessions/%s.distill.state' \
		"${ONLOOKER_DIR:-${HOME}/.onlooker}" "${1:-unknown}"
}

# Digits only, so a truncated or garbage read yields "" rather than something
# that makes the `-lt` below a syntax error. Absent marker and unreadable marker
# both mean "never distilled", which re-distills — failing toward doing the work.
_scribe_last_distilled_turns() {
	local marker="${1:-}"
	[[ -f "$marker" ]] || return 0
	local raw
	raw=$(tr -dc '0-9' <"$marker" 2>/dev/null | head -c 12) || raw=""
	printf '%s' "$raw"
}

# Written only after the document is on disk, so a failed pass does not suppress
# the next one. tmp+mv so a concurrent reader sees the old count or the new one,
# never a half-written line.
_scribe_record_distilled_turns() {
	local marker="${1:-}" turns="${2:-}"
	[[ -z "$marker" || -z "$turns" ]] && return 0
	mkdir -p "$(dirname "$marker")" 2>/dev/null || return 0
	local tmp="${marker}.tmp.$$"
	printf '%s\n' "$turns" >"$tmp" 2>/dev/null || return 0
	mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null
	return 0
}

_scribe_format_document() {
	local intent_json="${1:-}"
	local session_id="${2:-unknown}"
	local project_root="${3:-}"
	local captured_prompt="${4:-}"
	local date_str
	date_str=$(date '+%Y-%m-%d' 2>/dev/null) || date_str="unknown"
	local timestamp
	timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || timestamp="unknown"

	local summary problem decisions_json tradeoffs_json constraints_json out_of_scope_json
	summary=$(printf '%s' "$intent_json" | jq -r '.summary // ""' 2>/dev/null) || summary=""
	problem=$(printf '%s' "$intent_json" | jq -r '.problem // ""' 2>/dev/null) || problem=""
	decisions_json=$(printf '%s' "$intent_json" | jq -c '.decisions // []' 2>/dev/null) || decisions_json="[]"
	tradeoffs_json=$(printf '%s' "$intent_json" | jq -c '.tradeoffs // []' 2>/dev/null) || tradeoffs_json="[]"
	constraints_json=$(printf '%s' "$intent_json" | jq -c '.constraints // []' 2>/dev/null) || constraints_json="[]"
	out_of_scope_json=$(printf '%s' "$intent_json" | jq -c '.out_of_scope // []' 2>/dev/null) || out_of_scope_json="[]"

	local session_short="${session_id:0:8}"

	{
		printf '# Session Intent: %s\n\n' "$date_str"
		[[ -n "$summary" ]] && printf '> %s\n\n' "$summary"

		printf '## Problem\n\n'
		if [[ -n "$problem" ]]; then
			printf '%s\n\n' "$problem"
		else
			printf '*No problem statement extracted.*\n\n'
		fi

		printf '## Decisions\n\n'
		local decision_count
		decision_count=$(printf '%s' "$decisions_json" | jq 'length' 2>/dev/null) || decision_count=0
		if [[ "$decision_count" -gt 0 ]]; then
			local i
			for ((i = 0; i < decision_count; i++)); do
				local d r alts
				d=$(printf '%s' "$decisions_json" | jq -r ".[$i].decision // \"\"" 2>/dev/null) || d=""
				r=$(printf '%s' "$decisions_json" | jq -r ".[$i].reason // \"\"" 2>/dev/null) || r=""
				alts=$(printf '%s' "$decisions_json" | jq -r ".[$i].alternatives // [] | .[]" 2>/dev/null) || alts=""
				[[ -z "$d" ]] && continue
				printf -- '- **%s** — %s\n' "$d" "$r"
				if [[ -n "$alts" ]]; then
					printf '  - *Considered:* '
					local first=1
					while IFS= read -r alt; do
						[[ -z "$alt" ]] && continue
						[[ "$first" -eq 0 ]] && printf ', '
						printf '%s' "$alt"
						first=0
					done <<< "$alts"
					printf '\n'
				fi
			done
			printf '\n'
		else
			printf '*None noted.*\n\n'
		fi

		printf '## Tradeoffs\n\n'
		local tradeoff_count
		tradeoff_count=$(printf '%s' "$tradeoffs_json" | jq 'length' 2>/dev/null) || tradeoff_count=0
		if [[ "$tradeoff_count" -gt 0 ]]; then
			printf '%s' "$tradeoffs_json" | jq -r '.[]' 2>/dev/null | while IFS= read -r item; do
				[[ -n "$item" ]] && printf -- '- %s\n' "$item"
			done
			printf '\n'
		else
			printf '*None noted.*\n\n'
		fi

		printf '## Constraints\n\n'
		local constraint_count
		constraint_count=$(printf '%s' "$constraints_json" | jq 'length' 2>/dev/null) || constraint_count=0
		if [[ "$constraint_count" -gt 0 ]]; then
			printf '%s' "$constraints_json" | jq -r '.[]' 2>/dev/null | while IFS= read -r item; do
				[[ -n "$item" ]] && printf -- '- %s\n' "$item"
			done
			printf '\n'
		else
			printf '*None noted.*\n\n'
		fi

		printf '## Out of Scope\n\n'
		local oos_count
		oos_count=$(printf '%s' "$out_of_scope_json" | jq 'length' 2>/dev/null) || oos_count=0
		if [[ "$oos_count" -gt 0 ]]; then
			printf '%s' "$out_of_scope_json" | jq -r '.[]' 2>/dev/null | while IFS= read -r item; do
				[[ -n "$item" ]] && printf -- '- %s\n' "$item"
			done
			printf '\n'
		else
			printf '*None noted.*\n\n'
		fi

		if [[ -n "$captured_prompt" ]]; then
			printf '## Initial Prompt\n\n'
			printf '```\n%s\n```\n\n' "$captured_prompt"
		fi

		# '%s\n' rather than '---\n': a format string starting with a dash is
		# parsed as options, so this line has never printed — every intent
		# document is missing its rule and every pass wrote "printf: --:
		# invalid option" to a stderr nobody was reading (ONL-30).
		printf '%s\n' '---'
		printf '*Generated by scribe · session `%s` · %s*\n' "$session_short" "$timestamp"
		[[ -n "$project_root" ]] && printf '*Project: `%s`*\n' "$project_root"
	}
}

scribe_distill() {
	local session_id="${1:-}"
	local cwd="${2:-}"
	local transcript_path="${3:-}"

	[[ -z "$session_id" ]] && return 1

	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	local state_file="${onlooker_dir}/scribe/sessions/${session_id}.json"

	# Load captured prompt from session state (best-effort).
	local captured_prompt=""
	if [[ -f "$state_file" ]]; then
		captured_prompt=$(jq -r '.captured_prompt // ""' "$state_file" 2>/dev/null) || captured_prompt=""
	fi

	# Transcript is required for extraction.
	if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
		printf 'scribe_distill: no transcript available for session %s\n' "$session_id" >&2
		return 1
	fi

	# Count turns; skip trivial sessions.
	local min_turns
	min_turns=$(scribe_config_int '.scribe.capture.min_turns' 3)

	local turn_count
	turn_count=$(scribe_count_turns "$transcript_path")

	if [[ "$turn_count" -lt "$min_turns" ]]; then
		_scribe_emit_skip "below_min_turns" "$turn_count" "" "$min_turns"
		return 2
	fi

	# THE RE-DISTILLATION GATE. Stop fires once per TURN, and this function had
	# nothing in front of it that asked whether the work had already been done —
	# so a qualifying session re-ran the whole Haiku pass on every subsequent
	# turn and overwrote the same <date>-<session>.md each time. Measured on the
	# live event log for ONL-41: 62 scribe.distill.complete across 20 sessions,
	# one of them distilling 8 times in 56 minutes, 42 of the 62 passes
	# producing an artifact the next pass immediately discarded. Echo had the
	# same defect and the same fix (ecosystem-449.40): key the work on whether
	# the input is new, not on whether the hook fired.
	#
	# The key is the turn count rather than a content hash, because unlike
	# echo's watched files a transcript is APPEND-ONLY — it differs on every
	# single turn, so a hash would never match and would gate nothing. What
	# "new enough to redo the pass" means here is a number of turns.
	#
	# Re-distilling is refinement, not waste: a later pass sees more of the
	# session and writes a better document. The gate sets how much new material
	# is worth another Haiku call, and 0 disables it for anyone who wants the
	# old every-turn behavior back.
	local redistill_min last_turns
	redistill_min=$(scribe_config_int '.scribe.capture.redistill_min_new_turns' 5)

	local marker
	marker=$(_scribe_distill_marker_path "$session_id")
	last_turns=$(_scribe_last_distilled_turns "$marker")

	if [[ -n "$last_turns" && "$redistill_min" -gt 0 ]]; then
		local threshold=$((last_turns + redistill_min))
		if [[ "$turn_count" -lt "$threshold" ]]; then
			_scribe_emit_skip "no_new_turns" "$turn_count" "$last_turns" "$threshold"
			return 3
		fi
	fi

	# Resolve config.
	local model timeout_s max_tokens temperature transcript_chars_max
	model=$(scribe_config_get '.scribe.evaluator.model')
	[[ -z "$model" || "$model" == "null" ]] && model="claude-haiku-4-5-20251001"
	timeout_s=$(scribe_config_get '.scribe.evaluator.timeout')
	[[ -z "$timeout_s" || "$timeout_s" == "null" ]] && timeout_s="60"
	max_tokens=$(scribe_config_get '.scribe.evaluator.max_tokens')
	[[ -z "$max_tokens" || "$max_tokens" == "null" ]] && max_tokens="2048"
	temperature=$(scribe_config_get '.scribe.evaluator.temperature')
	[[ -z "$temperature" || "$temperature" == "null" ]] && temperature="0.3"
	transcript_chars_max=$(scribe_config_get '.scribe.capture.transcript_chars_max')
	[[ -z "$transcript_chars_max" || "$transcript_chars_max" == "null" ]] && transcript_chars_max="40000"

	# Run extraction.
	local intent_json
	intent_json=$(scribe_extract_intent \
		"$transcript_path" "$model" "$timeout_s" "$max_tokens" "$temperature" "$transcript_chars_max") || {
		printf 'scribe_distill: extraction failed for session %s\n' "$session_id" >&2
		return 1
	}

	# Resolve project key and output paths.
	# project_key partitions storage and is identity, so a worktree shares its
	# parent's. project_root is where this document gets written and what it
	# names, which for a worktree is the worktree itself — the parent is a tree
	# this session never touched (ecosystem-449.37).
	local project_key project_root output_dir
	project_key=$(scribe_project_key "$cwd")
	project_root=$(scribe_worktree_root "$cwd")
	[[ -z "$project_root" ]] && project_root=$(scribe_project_repo_root "$cwd")

	if [[ -n "$project_key" ]]; then
		output_dir=$(scribe_project_dir "$project_key")
	else
		output_dir="${onlooker_dir}/scribe/unknown"
	fi

	mkdir -p "$output_dir" 2>/dev/null || {
		printf 'scribe_distill: cannot create output dir %s\n' "$output_dir" >&2
		return 1
	}

	local date_str
	date_str=$(date '+%Y-%m-%d' 2>/dev/null) || date_str="unknown"
	local session_short="${session_id:0:8}"
	local filename="${date_str}-${session_short}.md"
	local output_path="${output_dir}/${filename}"

	# Format and write the document.
	local doc
	doc=$(_scribe_format_document \
		"$intent_json" "$session_id" "$project_root" "$captured_prompt")

	printf '%s\n' "$doc" > "$output_path" 2>/dev/null || {
		printf 'scribe_distill: failed to write %s\n' "$output_path" >&2
		return 1
	}

	# Mirror to project tree if configured.
	local mirror artifacts=1
	mirror=$(scribe_config_get '.scribe.output.mirror_to_project')
	if [[ "$mirror" == "true" && -n "$project_root" ]]; then
		local project_dir
		project_dir=$(scribe_config_get '.scribe.output.project_dir')
		[[ -z "$project_dir" || "$project_dir" == "null" ]] && project_dir="docs/decisions"
		local mirror_dir="${project_root}/${project_dir}"
		if mkdir -p "$mirror_dir" 2>/dev/null; then
			if cp "$output_path" "${mirror_dir}/${filename}" 2>/dev/null; then
				artifacts=2
			fi
		fi
	fi

	# Also persist the structured JSON alongside the markdown so the agent
	# can upload it without re-parsing markdown.
	local json_path="${output_dir}/${date_str}-${session_short}.json"
	printf '%s\n' "$intent_json" > "$json_path" 2>/dev/null || true

	# Only now, with the document actually on disk, does this count as covered.
	# Recording it earlier would let a failed extraction suppress the retry.
	_scribe_record_distilled_turns "$marker" "$turn_count"

	# Emit scribe.distill.complete.
	local payload
	payload=$(jq -n \
		--arg sid "$session_id" \
		--argjson cap 1 \
		--argjson art "$artifacts" \
		'{session_id: $sid, captures_processed: $cap, artifacts_produced: $art}') || payload=""

	[[ -n "$payload" ]] && scribe_emit_event "scribe.distill.complete" "$payload" || true

	# Emit onlooker.artifact.ready so the agent can upload the structured content.
	local artifact_payload
	artifact_payload=$(jq -n \
		--arg plugin "scribe" \
		--arg artifact_kind "intent" \
		--arg artifact_path "$json_path" \
		--arg artifact_title "Session Intent · $date_str" \
		'{plugin: $plugin, artifact_kind: $artifact_kind,
		  artifact_path: $artifact_path, artifact_title: $artifact_title}') || artifact_payload=""
	[[ -n "$artifact_payload" ]] && scribe_emit_event "onlooker.artifact.ready" "$artifact_payload" || true

	printf '%s' "$output_path"
}
