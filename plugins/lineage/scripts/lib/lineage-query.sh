#!/usr/bin/env bash
# Query side of lineage: read the change ledger and resolve prompts.
#
# The /lineage skill is a thin wrapper over these functions; the logic lives
# here so it is unit-testable in bats without driving the skill runtime.
#
# Requires lineage-record.sh (for lineage_record_path) and lineage-redact.sh
# (for capping/scrubbing resolved prompts) sourced beforehand.

# All change records for a file, newest first (one compact JSON per line).
# Usage: lineage_changes_for_file <project_key> <file_path>
lineage_changes_for_file() {
	local key="$1" file="$2"
	local path
	path=$(lineage_record_path "$key")
	[[ -f "$path" ]] || return 0
	jq -s -c --arg f "$file" \
		'[ .[] | select(.file_path == $f) ] | reverse | .[]' \
		"$path" 2>/dev/null
}

# How much of the change the captured content actually covers.
#
# Only the Bash path writes content_scope, because only it derives a record
# from a git diff — and git diffs against the last commit, not the last edit,
# so a tree that was already dirty makes the captured content wider than the
# change that prompted it. Edit/Write/MultiEdit carry no scope and need none:
# the tool said what it changed, so the content is that change. A Bash record
# without one predates the field, and nothing about it says either way.
#
# Echoes one of: delta | cumulative | exact | unknown
# Usage: lineage_scope_kind <content_scope> <tool>
lineage_scope_kind() {
	local scope="${1:-}" tool="${2:-}"
	# jq renders a missing field as the string "null" unless the caller
	# defaulted it, and printing that at a user is worse than saying nothing.
	[[ "$scope" == "null" ]] && scope=""
	if [[ -n "$scope" ]]; then
		printf '%s' "$scope"
		return 0
	fi
	case "$tool" in
	Edit | Write | MultiEdit) printf 'exact' ;;
	*) printf 'unknown' ;;
	esac
}

# The caveat that belongs with a scope kind.
#
# Every kind gets a sentence, including the confident ones. An answer that
# renders nothing here reads as certain, and a cumulative answer looking as
# confident as an exact one is the failure this whole field exists to prevent.
# Usage: lineage_scope_note <content_scope> <tool>
lineage_scope_note() {
	local kind
	kind=$(lineage_scope_kind "${1:-}" "${2:-}")
	case "$kind" in
	delta)
		printf 'Scope: delta — the file was clean beforehand, so the captured content is exactly this change.'
		;;
	cumulative)
		printf 'Scope: cumulative — the captured content may also include earlier uncommitted work, since the record was built by diffing against the last commit rather than the last edit. A weaker claim than an exact match.'
		;;
	exact)
		printf 'Scope: exact — the tool reported what it changed, so the captured content is this change and nothing else.'
		;;
	*)
		printf 'Scope: unknown — this record carries no scope, so how much of the change it covers cannot be told.'
		;;
	esac
}

# Name the tool as something that reads inside a sentence.
#
# "by a Bash" was the old rendering, wrong twice over: Bash is not a thing a
# change is made by, and an article chosen without looking at the word also
# gets "a Edit" wrong. Known tools are named deliberately; anything else falls
# back to articling on the first letter so a tool lineage has never seen still
# reads as English.
# Usage: lineage_tool_phrase <tool>
lineage_tool_phrase() {
	local tool="${1:-}"
	if [[ -z "$tool" || "$tool" == "null" ]]; then
		printf 'an unknown tool'
		return 0
	fi
	if [[ "$tool" == "Bash" ]]; then
		printf 'a shell command'
		return 0
	fi
	case "$tool" in
	[AEIOUaeiou]*) printf 'an %s' "$tool" ;;
	*) printf 'a %s' "$tool" ;;
	esac
}

# Who made a change, as a phrase that reads inside a sentence.
#
# An unknown record names no session at all (ONL-26). It does keep the
# observer, in observed_by_session_id, but printing that here would put a
# session id exactly where a reader looks for the author, which is the misread
# this field exists to stop.
# Usage: lineage_author_phrase <record_json>
lineage_author_phrase() {
	printf '%s' "${1:-}" | jq -r '
		if .authorship == "unknown" then "an unknown session"
		else "session " + (.session_id // "unknown") end' 2>/dev/null
}

# The sentence that explains an unknown author, or nothing for an attributed
# record. Printed beside the answer for the same reason lineage_scope_note is:
# an answer with no caveat reads as certain.
# Usage: lineage_authorship_note <record_json>
lineage_authorship_note() {
	local reason
	reason=$(printf '%s' "${1:-}" | jq -r '
		if .authorship == "unknown" then (.authorship_reason // "unspecified") else "" end' 2>/dev/null)
	[[ -z "$reason" ]] && return 0
	case "$reason" in
	predates_call)
		printf 'Authorship: unknown — the file changed before the command that noticed it had started, so no session can be shown to have made this change. It may have come from an editor, a checkout, a script outside Claude, or a session without lineage.'
		;;
	*)
		printf 'Authorship: unknown — no session can be shown to have made this change.'
		;;
	esac
}

# Resolve the prompt behind a ledger record, or nothing for one whose author is
# unknown. An unknown record carries no session_id or transcript_path, but this
# refuses on authorship rather than relying on their absence, so a record that
# was hand-edited or written by a future field cannot lead it to the
# observer's history.
# Usage: lineage_resolve_record_prompt <project_key> <record_json> [prompt_source]
lineage_resolve_record_prompt() {
	local key="$1" rec="$2" source="${3:-historian_then_transcript}" sid turn tp
	if [[ "$(printf '%s' "$rec" | jq -r '.authorship // ""' 2>/dev/null)" == "unknown" ]]; then
		jq -nc '{prompt: "", resolved_via: "none"}'
		return 0
	fi
	sid=$(printf '%s' "$rec" | jq -r '.session_id // ""' 2>/dev/null)
	turn=$(printf '%s' "$rec" | jq -r '.turn // ""' 2>/dev/null)
	tp=$(printf '%s' "$rec" | jq -r '.transcript_path // ""' 2>/dev/null)
	lineage_resolve_prompt "$key" "$sid" "$turn" "$tp" "$source"
}

# The newest change whose added content contains <line_text> (substring),
# i.e. the change that introduced that content. Echoes one record or nothing.
# Usage: lineage_match_line <project_key> <file_path> <line_text>
lineage_match_line() {
	local key="$1" file="$2" needle="$3"
	local path
	path=$(lineage_record_path "$key")
	[[ -f "$path" ]] || return 0
	# An empty/whitespace needle has no meaningful introducing change.
	[[ -z "${needle//[[:space:]]/}" ]] && return 0
	jq -s -c --arg f "$file" --arg t "$needle" '
		[ .[] | select(.file_path == $f) ] | reverse
		| map(select(any(.added_snippets[]?; type == "string" and contains($t))))
		| (.[0] // empty)
	' "$path" 2>/dev/null
}

# Resolve the originating prompt for a change. Tries historian's durable
# per-session chunks first (tolerant turn-range match), then the live
# transcript, then gives up. Echoes {prompt, resolved_via} as JSON.
# Usage: lineage_resolve_prompt <project_key> <session_id> <turn> <transcript_path> [prompt_source]
lineage_resolve_prompt() {
	local key="$1" sid="$2" turn="$3" transcript_path="$4" source="${5:-historian_then_transcript}"
	local prompt="" via="none"
	local onlooker="${ONLOOKER_DIR:-$HOME/.onlooker}"

	# 1) historian: chunk whose [start_turn_index,end_turn_index] contains the
	#    turn, else nearest preceding, else the last chunk. body_redacted is the
	#    conversation context historian preserved for that span.
	if [[ "$source" != "transcript_only" && -n "$key" && -n "$sid" ]]; then
		local safe_sid hist_file
		safe_sid=$(printf '%s' "$sid" | tr -cd '[:alnum:]._-')
		[[ -z "$safe_sid" ]] && safe_sid="unknown"
		hist_file="${onlooker}/historian/${key}/sessions/${safe_sid}.jsonl"
		if [[ -f "$hist_file" ]]; then
			prompt=$(jq -rs --argjson t "${turn:-0}" '
				( [ .[] | select((.start_turn_index // 0) <= $t and (.end_turn_index // 0) >= $t) ] | .[0] )
				// ( [ .[] | select((.end_turn_index // 0) <= $t) ] | sort_by(.end_turn_index) | last )
				// (.[-1] // empty)
				| (.body_redacted // "")
			' "$hist_file" 2>/dev/null) || prompt=""
			[[ -n "$prompt" ]] && via="historian"
		fi
	fi

	# 2) transcript fallback: the turn-th user message (1-based), else the last.
	#    Tolerant of both transcript shapes (.role/.content and .type/.message.content).
	if [[ -z "$prompt" && "$source" != "historian_only" && -n "$transcript_path" && -f "$transcript_path" ]]; then
		prompt=$(jq -rs --argjson t "${turn:-0}" '
			[ .[]
			  | select((.role // .type) == "user")
			  | ((.content // .message.content) as $c
			     | if ($c | type) == "array"
			       then [ $c[]? | select(.type == "text") | .text ] | join("\n")
			       else ($c // "") end)
			] as $u
			| ($u[($t - 1)] // ($u[-1] // ""))
		' "$transcript_path" 2>/dev/null) || prompt=""
		[[ -n "$prompt" ]] && via="transcript"
	fi

	# Cap + scrub for display (historian bodies are already redacted; this also
	# scrubs the transcript path and keeps the excerpt short).
	prompt=$(printf '%s' "$prompt" | lineage_redact 1000 true)

	jq -nc --arg p "$prompt" --arg v "$via" '{prompt: $p, resolved_via: $v}'
}
