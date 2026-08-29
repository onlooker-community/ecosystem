#!/usr/bin/env bash
# Propagate scripts/lib/config-loader.sh into every plugin's scripts/lib/.
#
# The loader is vendored rather than shared. Each plugin publishes rooted at
# ./plugins/<name>, so an installed plugin is its own tree with no ecosystem
# checkout above it and cannot reach a repo-root path — it would source
# nothing, define no accessors, and read shipped defaults in silence
# (ecosystem-ber). Edit the canonical copy, run this, commit the result.
#
# Forgetting to run it is caught by test/bats/config-lib-self-locating.bats,
# which fails on any copy that drifts.
#
# Usage:
#   scripts/sync-config-loader.sh           # write the copies
#   scripts/sync-config-loader.sh --check   # report drift, write nothing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="${REPO_ROOT}/scripts/lib/config-loader.sh"

[[ -f "$CANONICAL" ]] || {
	printf 'missing canonical loader: %s\n' "$CANONICAL" >&2
	exit 1
}

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

drift=0
while IFS= read -r lib; do
	dest="${lib%/*}/config-loader.sh"
	cmp -s "$CANONICAL" "$dest" && continue
	drift=$((drift + 1))
	if [[ "$check_only" -eq 1 ]]; then
		printf 'out of sync: %s\n' "${dest#"${REPO_ROOT}/"}" >&2
	else
		cp "$CANONICAL" "$dest"
		printf 'synced %s\n' "${dest#"${REPO_ROOT}/"}"
	fi
done < <(find "${REPO_ROOT}/plugins" -path '*/scripts/lib/*-config.sh' -type f | sort)

if [[ "$check_only" -eq 1 ]]; then
	[[ "$drift" -eq 0 ]] || {
		printf '%d copy/copies out of sync — run scripts/sync-config-loader.sh\n' "$drift" >&2
		exit 1
	}
	printf 'all vendored copies match scripts/lib/config-loader.sh\n'
	exit 0
fi

printf '%d copy/copies updated\n' "$drift"
