#!/usr/bin/env bash
# Propagate the shared libs into every plugin's scripts/lib/.
#
# These libs are vendored rather than shared. Each plugin publishes rooted at
# ./plugins/<name>, so an installed plugin is its own tree with no ecosystem
# checkout above it and cannot reach a repo-root path — it would source
# nothing, define no functions, and fail in silence (ecosystem-ber).
# Edit the canonical copy, run this, commit the result.
#
# Drift is caught by test/bats/shared-lib-vendoring.bats and
# test/bats/config-lib-self-locating.bats.
#
# Usage:
#   scripts/sync-shared-libs.sh           # write the copies
#   scripts/sync-shared-libs.sh --check   # report drift, write nothing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_LIBS=(config-loader.sh hook-health.sh)

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

drift=0

for lib in "${SHARED_LIBS[@]}"; do
	canonical="${REPO_ROOT}/scripts/lib/${lib}"
	[[ -f "$canonical" ]] || {
		printf 'missing canonical lib: %s\n' "$canonical" >&2
		exit 1
	}

	while IFS= read -r plugin_dir; do
		dest="${plugin_dir}/scripts/lib/${lib}"
		[[ -d "${plugin_dir}/scripts/lib" ]] || continue
		cmp -s "$canonical" "$dest" 2>/dev/null && continue
		drift=$((drift + 1))
		if [[ "$check_only" -eq 1 ]]; then
			printf 'out of sync: %s\n' "${dest#"${REPO_ROOT}/"}" >&2
		else
			cp "$canonical" "$dest"
			printf 'synced %s\n' "${dest#"${REPO_ROOT}/"}"
		fi
	done < <(find "${REPO_ROOT}/plugins" -maxdepth 1 -mindepth 1 -type d | sort)
done

if [[ "$check_only" -eq 1 ]]; then
	[[ "$drift" -eq 0 ]] || {
		printf '%d copy/copies out of sync — run scripts/sync-shared-libs.sh\n' "$drift" >&2
		exit 1
	}
	printf 'all vendored copies match their canonical libs\n'
	exit 0
fi

printf '%d copy/copies updated\n' "$drift"
