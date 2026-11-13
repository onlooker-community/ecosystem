#!/usr/bin/env bash
# Warms the SessionStart injection cache, detached from the hook that wrote.
#
# Usage: archivist-inject-warm.sh <project_key> <cwd>
#
# archivist-extract launches this after its PreCompact writes, so the compact
# SessionStart that follows answers from the cache instead of rebuilding it
# (ONL-260). It runs apart from the hook because a warm first waits out the
# second of the last write, which PreCompact should not sit through.

set -uo pipefail

PROJECT_KEY="${1:-}"
CWD="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./hook-health.sh
source "${SCRIPT_DIR}/hook-health.sh"
hook_health_register "archivist-inject-warm"

[[ -z "$PROJECT_KEY" ]] && hook_health_exit 0

# shellcheck source=./archivist-inject-cache.sh
source "${SCRIPT_DIR}/archivist-inject-cache.sh"
archivist_inject_cache_warm "$PROJECT_KEY" "$CWD"

hook_health_exit 0
