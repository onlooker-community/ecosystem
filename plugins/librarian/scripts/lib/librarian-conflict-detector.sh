#!/usr/bin/env bash
# Conflict and duplicate detection for librarian proposals.
#
# Compares proposed memories against existing memories in the user's
# typed memory store (~/.claude/projects/<encoded>/memory/) and classifies
# each proposal into one of:
#   - none           (no similarity, safe to propose)
#   - duplicate      (similarity >= duplicate_threshold; drop silently)
#   - merge_candidate (merge_threshold <= similarity < duplicate_threshold)
#   - conflict_candidate (opposing sentiment on overlapping content)
#
# Uses deterministic token-set Jaccard similarity (no LLM call) with
# configurable thresholds.

# Extract and normalize tokens from text for similarity comparison.
# Lowercases, removes stopwords, splits on non-alphanumeric.
_librarian_conflict_normalize() {
	local text="$1"
	printf '%s' "$text" \
		| tr '[:upper:]' '[:lower:]' \
		| tr -cs '[:alnum:]' '\n' \
		| grep -v '^$' \
		| sort -u \
		| paste -sd ' ' -
}

# Compute Jaccard similarity (intersection / union) of two token sets.
# Input: two space-separated token strings.
# Output: float 0-1.
_librarian_conflict_jaccard() {
	local tokens1="$1"
	local tokens2="$2"

	[[ -z "$tokens1" || -z "$tokens2" ]] && { printf '0'; return; }

	TOKENS1="$tokens1" TOKENS2="$tokens2" python3 -c '
import os
tokens1 = set(os.environ.get("TOKENS1", "").split())
tokens2 = set(os.environ.get("TOKENS2", "").split())
if not tokens1 and not tokens2:
    print(0)
else:
    intersection = len(tokens1 & tokens2)
    union = len(tokens1 | tokens2)
    similarity = intersection / union if union > 0 else 0
    print(f"{similarity:.2f}")
'
}

# Check for opposing sentiment markers (do/don't, always/never, etc.).
# Returns 0 if opposing markers found, 1 otherwise.
_librarian_conflict_opposing_sentiment() {
	local text1="$1"
	local text2="$2"

	# Normalize to lowercase.
	text1=$(printf '%s' "$text1" | tr '[:upper:]' '[:lower:]')
	text2=$(printf '%s' "$text2" | tr '[:upper:]' '[:lower:]')

	# Define opposing pairs.
	local -a pairs=("always:never" "never:always" "do:don't" "don't:do" "prefer:avoid"
	                 "avoid:prefer" "enable:disable" "disable:enable" "keep:remove"
	                 "remove:keep" "use:avoid" "avoid:use")

	for pair in "${pairs[@]}"; do
		local a="${pair%%:*}"
		local b="${pair##*:}"

		# Check if text1 has 'a' and text2 has 'b', or vice versa.
		if [[ "$text1" == *"$a"* && "$text2" == *"$b"* ]]; then
			return 0  # opposing
		fi
		if [[ "$text1" == *"$b"* && "$text2" == *"$a"* ]]; then
			return 0  # opposing
		fi
	done

	return 1  # not opposing
}

# Detect conflict state for a single proposal against a single existing memory.
# Returns conflict classification and (optionally) the conflicting memory filename.
#
# Usage: librarian_conflict_check <proposal_body> <existing_memory_path> \
#                                 <duplicate_threshold> <merge_threshold>
#
# Output: JSON object { conflict_state, conflicting_file (optional) }
librarian_conflict_check() {
	local proposal_body="$1"
	local memory_path="$2"
	local dup_threshold="${3:-0.7}"
	local merge_threshold="${4:-0.45}"

	[[ -z "$proposal_body" || -z "$memory_path" ]] && {
		printf '%s' '{"conflict_state":"none"}'
		return 0
	}
	[[ ! -f "$memory_path" ]] && {
		printf '%s' '{"conflict_state":"none"}'
		return 0
	}

	# Extract the body of the existing memory (skip frontmatter).
	local existing_body
	existing_body=$(awk '/^---$/{ if (++count == 2) { in_body = 1; next } }
	                        in_body { print }' "$memory_path")

	[[ -z "$existing_body" ]] && {
		printf '%s' '{"conflict_state":"none"}'
		return 0
	}

	# Normalize both bodies to token sets.
	local prop_tokens existing_tokens
	prop_tokens=$(_librarian_conflict_normalize "$proposal_body")
	existing_tokens=$(_librarian_conflict_normalize "$existing_body")

	# Compute Jaccard similarity.
	local similarity
	similarity=$(_librarian_conflict_jaccard "$prop_tokens" "$existing_tokens")

	# Classify based on similarity + optional sentiment check.
	if awk "BEGIN { exit !($similarity >= $dup_threshold) }"; then
		# Definitely a duplicate.
		jq -cn --arg file "$(basename "$memory_path")" \
			'{ conflict_state: "duplicate", conflicting_file: $file }'
	elif awk "BEGIN { exit !($similarity >= $merge_threshold) }"; then
		# Merge candidate — significant overlap but not identical.
		jq -cn --arg file "$(basename "$memory_path")" \
			'{ conflict_state: "merge_candidate", conflicting_file: $file }'
	elif awk "BEGIN { exit !($similarity >= $merge_threshold * 0.8) }"; then
		# Check for opposing sentiment in the overlap zone.
		if _librarian_conflict_opposing_sentiment "$proposal_body" "$existing_body"; then
			jq -cn --arg file "$(basename "$memory_path")" \
				'{ conflict_state: "conflict_candidate", conflicting_file: $file }'
		else
			printf '%s' '{"conflict_state":"none"}'
		fi
	else
		# No meaningful overlap.
		printf '%s' '{"conflict_state":"none"}'
	fi
}

# Scan a proposal against all existing memories in the project.
# Returns the highest-priority conflict found (duplicate > conflict > merge).
#
# Usage: librarian_conflict_scan <proposal_json> <memory_dir> \
#                                <duplicate_threshold> <merge_threshold>
#
# Output: JSON object { conflict_state, conflict_with: [...] }
librarian_conflict_scan() {
	local proposal="$1"
	local memory_dir="$2"
	local dup_threshold="${3:-0.7}"
	local merge_threshold="${4:-0.45}"

	[[ -z "$proposal" || -z "$memory_dir" ]] && {
		printf '%s' '{"conflict_state":"none","conflict_with":[]}'
		return 0
	}
	[[ ! -d "$memory_dir" ]] && {
		printf '%s' '{"conflict_state":"none","conflict_with":[]}'
		return 0
	}

	local proposal_body
	proposal_body=$(printf '%s' "$proposal" | jq -r '.proposed.body // ""')
	[[ -z "$proposal_body" ]] && {
		printf '%s' '{"conflict_state":"none","conflict_with":[]}'
		return 0
	}

	local worst_state=""
	local conflicts='[]'

	# Scan all memory files in the project.
	for memory_file in "$memory_dir"/*.md; do
		[[ ! -f "$memory_file" ]] && continue

		local check
		check=$(librarian_conflict_check "$proposal_body" "$memory_file" \
		                                  "$dup_threshold" "$merge_threshold")
		[[ -z "$check" ]] && continue

		local state
		state=$(printf '%s' "$check" | jq -r '.conflict_state // "none"')
		local filename
		filename=$(printf '%s' "$check" | jq -r '.conflicting_file // ""')

		# Track conflicts; prioritize by severity: duplicate > conflict > merge.
		case "$state" in
			duplicate)
				worst_state="duplicate"
				conflicts=$(printf '%s' "$conflicts" | jq --arg f "$filename" '. + [$f]')
				;;
			conflict_candidate)
				if [[ "$worst_state" != "duplicate" ]]; then
					worst_state="conflict_candidate"
					conflicts=$(printf '%s' "$conflicts" | jq --arg f "$filename" '. + [$f]')
				fi
				;;
			merge_candidate)
				if [[ -z "$worst_state" ]]; then
					worst_state="merge_candidate"
					conflicts=$(printf '%s' "$conflicts" | jq --arg f "$filename" '. + [$f]')
				fi
				;;
		esac
	done

	[[ -z "$worst_state" ]] && worst_state="none"
	printf '%s' "$(jq -cn --arg state "$worst_state" --argjson files "$conflicts" \
		'{ conflict_state: $state, conflict_with: $files }')"
}
