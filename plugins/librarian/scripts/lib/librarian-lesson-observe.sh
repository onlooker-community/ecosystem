#!/usr/bin/env bash
# librarian-lesson-observe.sh: the versions a lesson's stack entries were
# observed on, read from the project rather than claimed by a model.
#
# The work is in librarian-lesson-observe.mjs, beside this file. Manifest
# parsing is JSON, YAML and TOML, which is node's job, not jq's. The path is
# resolved from this file, never from a caller's $PLUGIN_ROOT, so a sub-shell
# that loses PLUGIN_ROOT still finds it.
#
# Fail-soft: on a missing argument, no node, or any error, it prints nothing
# and the caller treats every entry as unresolved.

_LIBRARIAN_LESSON_OBSERVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Usage: librarian_lesson_observe <project_key> <observed_at> <stack_json>
librarian_lesson_observe() {
	local key="${1:-}" observed_at="${2:-}" stack="${3:-}"
	[[ -z "$key" || -z "$observed_at" || -z "$stack" ]] && return 0
	command -v node >/dev/null 2>&1 || return 0
	node "${_LIBRARIAN_LESSON_OBSERVE_DIR}/librarian-lesson-observe.mjs" \
		"${ONLOOKER_DIR:-$HOME/.onlooker}" "$key" "$observed_at" "$stack" 2>/dev/null || true
}
