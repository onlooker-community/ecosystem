#!/usr/bin/env bash
# cartographer-omission.sh — disk → doc detection.
#
# Every other analysis phase starts from the text of the instruction files and
# tests what it finds against the filesystem. This one runs the other way: it
# enumerates entities on disk and checks each is mentioned somewhere in the
# corpus. An entity nothing names produces no token for stale_ref to extract
# and no rule for contradiction to compare, which is why omissions were
# previously invisible to every phase.
#
# Detection is a grep — no model call. A model would only help judge whether an
# omission MATTERS, which is a sharper question than the drift that motivated
# this. See docs/superpowers/specs/2026-08-16-cartographer-undocumented-entity-design.md
#
# Usage:
#   cartographer_analyze_undocumented_entity <files_json> <repo_root> \
#       <globs_json> <exclude_json> <max_findings>
#
# Prints a JSON array of findings on stdout in the same shape the analyzers in
# cartographer-analyze.sh return, so run_synthesize merges it without special
# handling. Diagnostics go to stderr, which run-audit.sh appends to audit.log.

# Word-boundary mention test.
#
# Boundaries are hand-rolled rather than \b because entity names contain
# hyphens, and \b treats '-' as a non-word character: \blist-prompt-rules\b
# would also match inside "my-list-prompt-rules-thing". Bounding on
# [^A-Za-z0-9_-] instead means a hyphenated name matches only when genuinely
# standalone, while a name inside a path ("plugins/beta/") still counts.
_cartographer_name_mentioned() {
	local name="$1"
	local files_json="$2"

	local escaped
	escaped=$(printf '%s' "$name" | sed 's/[][\.*^$(){}?+|\\]/\\&/g')

	local fpath
	while IFS= read -r fpath; do
		[[ -z "$fpath" || ! -f "$fpath" ]] && continue
		if grep -qE "(^|[^A-Za-z0-9_-])${escaped}([^A-Za-z0-9_-]|\$)" "$fpath" 2>/dev/null; then
			return 0
		fi
	done < <(printf '%s' "$files_json" | jq -r '.[]' 2>/dev/null)
	return 1
}

cartographer_analyze_undocumented_entity() {
	local files_json="${1:-[]}"
	local repo_root="${2:?repo_root required}"
	local globs_json="${3:-[]}"
	local exclude_json="${4:-[]}"
	local max_findings="${5:-20}"

	# An empty corpus cannot document anything, so every entity would look
	# undocumented. Refuse rather than emit a burst of false findings that the
	# emit phase would dedup-sentinel and never re-evaluate.
	local corpus_count
	corpus_count=$(printf '%s' "$files_json" | jq 'length' 2>/dev/null || printf '0')
	[[ "${corpus_count:-0}" -eq 0 ]] && { printf '[]'; return 0; }

	local findings="[]"
	local emitted=0 dropped=0
	local root="${repo_root%/}"

	# nullglob so an unmatched pattern expands to nothing rather than to itself.
	# Restore the prior setting — this library is sourced, not run.
	local had_nullglob=0
	shopt -q nullglob && had_nullglob=1
	shopt -s nullglob

	local glob match
	while IFS= read -r glob; do
		[[ -z "$glob" ]] && continue
		# shellcheck disable=SC2086 # $glob unquoted on purpose: this is the glob
		# expansion. ${root} IS quoted — a repo path containing a space must not
		# word-split before the glob expands, or the match silently finds nothing.
		for match in "${root}"/$glob; do
			[[ -e "$match" ]] || continue

			local trimmed="${match%/}"
			local name relpath
			name=$(basename "$trimmed")
			relpath="${trimmed#"${root}"/}"

			local excluded=0 excl
			while IFS= read -r excl; do
				[[ -z "$excl" ]] && continue
				[[ "$relpath" == *"$excl"* ]] && { excluded=1; break; }
			done < <(printf '%s' "$exclude_json" | jq -r '.[]' 2>/dev/null)
			[[ "$excluded" -eq 1 ]] && continue

			_cartographer_name_mentioned "$name" "$files_json" && continue

			if [[ "$emitted" -ge "$max_findings" ]]; then
				dropped=$(( dropped + 1 ))
				continue
			fi

			local finding
			finding=$(jq -n \
				--arg fa "$trimmed" \
				--arg n "$name" \
				--arg rp "$relpath" \
				'{
					type: "undocumented_entity",
					severity: "warning",
					file_a: $fa,
					excerpt_a: $n,
					file_b: null,
					excerpt_b: null,
					description: ($n + " exists at " + $rp
						+ " but is not mentioned in any instruction file."),
					suggested_fix: ("Document " + $n
						+ " in CLAUDE.md, or exclude its path from cartographer.undocumented_entity.")
				}')
			findings=$(printf '%s' "$findings" | jq --argjson f "$finding" '. + [$f]')
			emitted=$(( emitted + 1 ))
		done
	done < <(printf '%s' "$globs_json" | jq -r '.[]' 2>/dev/null)

	[[ "$had_nullglob" -eq 0 ]] && shopt -u nullglob

	# Say what was dropped. A silent truncation reads as "this is everything".
	if [[ "$dropped" -gt 0 ]]; then
		printf 'undocumented_entity: capped at %s findings, %s candidate(s) dropped\n' \
			"$max_findings" "$dropped" >&2
	fi

	printf '%s' "$findings"
}
