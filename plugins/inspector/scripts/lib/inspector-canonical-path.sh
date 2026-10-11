#!/usr/bin/env bash
# Path normalization for inspector.
#
# Split out of onlooker-project-key.sh when that file was replaced by the
# vendored canonical onlooker-project-key.sh: this is a path helper, not
# project-key derivation.

inspector_canonical_path() {
	local p="${1:-}"
	[[ -z "$p" ]] && return 0

	local out
	if out=$(realpath "$p" 2>/dev/null) && [[ -n "$out" ]]; then
		printf '%s' "$out"
		return 0
	fi
	# BSD readlink has no -f, so this silently no-ops there and falls through.
	if out=$(readlink -f "$p" 2>/dev/null) && [[ -n "$out" ]]; then
		printf '%s' "$out"
		return 0
	fi

	if [[ -d "$p" ]]; then
		out=$(cd "$p" 2>/dev/null && pwd -P) && [[ -n "$out" ]] && {
			printf '%s' "$out"
			return 0
		}
	else
		local dir base
		dir=$(dirname "$p")
		base=$(basename "$p")
		out=$(cd "$dir" 2>/dev/null && pwd -P) && [[ -n "$out" ]] && {
			printf '%s/%s' "$out" "$base"
			return 0
		}
	fi

	# Nothing resolved it — hand back the input rather than an empty string,
	# so a caller comparing two of these still compares like with like.
	printf '%s' "$p"
}
