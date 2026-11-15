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
