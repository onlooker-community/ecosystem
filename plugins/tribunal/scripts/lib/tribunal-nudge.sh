#!/usr/bin/env bash
# The Stop-time nudge toward /tribunal: everything it decides, with no I/O
# beyond the state file it is handed. The hook (tribunal-stop-nudge.sh) wires
# this to config, the transcript and the bus.
# Spec: docs/superpowers/specs/2026-11-15-tribunal-nudge-design.md

# Usage: tribunal_nudge_glob_to_regex <glob>
# An anchored ERE for a glob over a worktree-relative path. `**/` is zero or
# more leading directories, `**` elsewhere is anything, `*` and `?` stay inside
# one segment. Matched with [[ =~ ]] rather than globstar, which bash 3.2 lacks.
tribunal_nudge_glob_to_regex() {
	local g="$1" out="" c i=0 n=${#1}
	while [[ $i -lt $n ]]; do
		c="${g:i:1}"
		if [[ "$c" == "*" && "${g:i+1:1}" == "*" ]]; then
			if [[ "${g:i+2:1}" == "/" ]]; then
				out+="(.*/)?"
				i=$((i + 3))
			else
				out+=".*"
				i=$((i + 2))
			fi
			continue
		fi
		case "$c" in
			"*") out+="[^/]*" ;;
			"?") out+="[^/]" ;;
			"." | "+" | "^" | "$" | "(" | ")" | "[" | "]" | "{" | "}" | "|" | "\\") out+="\\${c}" ;;
			*) out+="$c" ;;
		esac
		i=$((i + 1))
	done
	printf '^%s$' "$out"
}

# Usage: tribunal_nudge_matches_any <path> [glob...]
# Case-insensitive: on macOS's filesystem Secrets.md and .ENV are the same
# risk as their lowercase spellings. nocasematch is restored, as assayer does.
tribunal_nudge_matches_any() {
	local path="$1" glob re hit=1 restore
	shift
	# shopt -p exits 1 when the option is off; under errexit that would abort before any match.
	restore=$(shopt -p nocasematch || true)
	shopt -s nocasematch
	for glob in "$@"; do
		re=$(tribunal_nudge_glob_to_regex "$glob")
		if [[ "$path" =~ $re ]]; then
			hit=0
			break
		fi
	done
	eval "$restore"
	return "$hit"
}

# Usage: tribunal_nudge_scan <transcript>
# One pass over the transcript for both things the nudge needs: `E<TAB><path>`
# per write-class edit, and `T` per /tribunal run. A long session's transcript
# runs to megabytes, so the grep keeps jq to the lines that can matter.
#
# /tribunal counts as ran for a Skill tool_use whose input.skill is tribunal
# or tribunal:tribunal, or a user turn carrying <command-name>/tribunal</...>
# (or /tribunal:tribunal). Text that merely mentions /tribunal does not count.
tribunal_nudge_scan() {
	local transcript="$1"
	[[ -n "$transcript" && -f "$transcript" ]] || return 0
	{ grep -E '"tool_use"|<command-name>' "$transcript" 2>/dev/null || true; } \
		| jq -rR '
			fromjson? |
			if .type == "assistant" then
				.message.content[]? | select(type == "object" and .type == "tool_use")
				| if (.name | IN("Edit", "Write", "MultiEdit", "NotebookEdit")) then
					(.input.file_path // .input.notebook_path // empty) | strings
					| select(startswith("/")) | "E\t" + .
				elif .name == "Skill" and ((.input.skill // "") | IN("tribunal", "tribunal:tribunal")) then
					"T"
				else empty end
			elif .type == "user" then
				(.message.content
					| if type == "string" then .
					  else ([.[]? | select(type == "object" and .type == "text") | .text] | join("\n")) end)
				| select(test("<command-name>/tribunal(:tribunal)?</command-name>")) | "T"
			else empty end
		' 2>/dev/null
}

# Usage: tribunal_nudge_decide <count> <sensitive_json> <min_files> <state_json>
# The frequency rule. A first nudge names its trigger, sensitive winning over
# size. After that, only growth speaks again: a sensitive path not seen at the
# last nudge, or at least twice the files. skips_reported is not a nudge.
tribunal_nudge_decide() {
	jq -cn --argjson n "$1" --argjson sens "$2" --argjson min "$3" --argjson st "$4" '
		($min > 0 and $n >= $min) as $size
		| (($sens | length) > 0) as $s
		| if ($size or $s) | not then {action: "skip", reason: "below_threshold"}
		  elif ($st | has("files")) | not then
			{action: "nudge", trigger: (if $s then "sensitive" else "size" end)}
		  elif (($sens - ($st.sensitive // [])) | length) > 0 or $n >= 2 * $st.files then
			{action: "nudge", trigger: "grew"}
		  else {action: "skip", reason: "unchanged"} end'
}

# Usage: tribunal_nudge_message <count> <sensitive_json>
# The cost hint is there because /tribunal runs several judge models per
# iteration (tribunal ADR-001), far more than the gate's one judge.
tribunal_nudge_message() {
	jq -rn --argjson n "$1" --argjson s "$2" '
		"tribunal: this session changed \($n) file\(if $n == 1 then "" else "s" end)"
		+ (if ($s | length) > 0 then
			", \($s | length) sensitive (" + ($s[0:3] | join(", "))
			+ (if ($s | length) > 3 then " and \(($s | length) - 3) more" else "" end) + ")"
		  else "" end)
		+ ". Worth a jury? /tribunal runs several judge models; type it to start."'
}

# Usage: tribunal_nudge_state_read <path>
# Reads as {} for a missing or unparseable file. The jq call is guarded because
# a failed assignment as the last step of an && list would abort a set -e caller.
tribunal_nudge_state_read() {
	local path="$1" v=""
	if [[ -n "$path" && -f "$path" ]]; then
		v=$(jq -ce 'select(type == "object")' "$path" 2>/dev/null) || v=""
	fi
	printf '%s' "${v:-"{}"}"
}

# Usage: tribunal_nudge_state_write <path> <json>
# Through a temp file and mv, so a killed hook leaves the old state, not half
# of a new one. No path (no session id) means no state, never a shared file.
tribunal_nudge_state_write() {
	local path="$1" json="$2"
	[[ -n "$path" ]] || return 0
	mkdir -p "${path%/*}" 2>/dev/null || return 0
	printf '%s\n' "$json" > "${path}.tmp" 2>/dev/null && mv -f "${path}.tmp" "$path" 2>/dev/null
	return 0
}
