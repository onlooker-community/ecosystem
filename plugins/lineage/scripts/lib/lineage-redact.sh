#!/usr/bin/env bash
# Secret redaction + size capping for lineage change snippets.
#
# The patterns live in onlooker-secret-patterns.sh, vendored beside this file.
# They used to live here, in a copy that drifted from historian's - this one
# was the better of the two, and historian was missing two shapes because of
# it (ONL-167).
#
# What stays here is lineage's own concern: the size cap, and the bypass.

# Resolved from this file's OWN location, never from a caller-supplied
# PLUGIN_ROOT and never by climbing to a repo root - both resolve in one
# checkout and nowhere else, and both fail by leaving the function undefined
# while the script still exits 0 (CLAUDE.md step 8).
# shellcheck source=./onlooker-secret-patterns.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/onlooker-secret-patterns.sh"

# Redact secret-shaped substrings from stdin, then cap to <max_chars>.
# Usage: printf '%s' "$content" | lineage_redact <max_chars> <redact:true|false>
lineage_redact() {
	local max_chars="${1:-4000}"
	local do_redact="${2:-true}"

	local text
	text=$(cat)

	if [[ "$do_redact" != "false" ]]; then
		local payload result
		payload=$(jq -cn --arg s "$text" '[$s]' 2>/dev/null) || return 0
		result=$(onlooker_redact_secrets "$payload" 2>/dev/null) || result=""
		# Fail closed, matching the shared lib: an unredacted snippet must
		# never reach the ledger because the redactor failed.
		[[ -z "$result" ]] && return 0
		text=$(printf '%s' "$result" | jq -r '.[0].redacted' 2>/dev/null) || return 0
	fi

	# Truncation stays here: it is lineage's budget, not a property of
	# redaction, and historian does not want it. The marker is byte-for-byte
	# what the previous inline python produced, so a consumer reading these
	# snippets sees no change.
	if [[ "${#text}" -gt "$max_chars" ]]; then
		printf '%s… [truncated %d chars]' "${text:0:max_chars}" "$(( ${#text} - max_chars ))"
	else
		printf '%s' "$text"
	fi
}
