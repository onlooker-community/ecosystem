#!/usr/bin/env bash
# Run a mise-managed tool without depending on the caller's PATH.
#
# ecosystem-7jl. inspector's checks are spawned from a hook, and a hook's
# environment is whatever the session was launched with. `mise activate` builds
# its PATH from the shell profile, so a session that did not come from an
# interactive shell has no entry for shellcheck or biome. The check exits 127,
# inspector reports tool_missing, and the repo's primary gate is silently
# absent -- measured at 68 skipped against 23 run, a per-session split with
# three sessions never finding the tool and one always finding it.
#
# Only markdownlint escaped, because it alone was configured with an explicit
# path rather than a bare name. This generalizes that fix instead of adding a
# second special case.
#
# exec throughout, so this costs one bash startup and leaves no extra process
# on a path whose per-edit budget is tracked.
#
# Resolution order, cheapest first:
#   1. already on PATH        — the activated-shell case, no work to do
#   2. mise shims directory   — present whenever mise is installed, and stable
#                               across tool version bumps
#   3. mise itself            — authoritative, but costs a subprocess
#   4. bare exec              — fails 127 on purpose, so inspector still reports
#                               tool_missing rather than this wrapper inventing
#                               a different failure
#
# Usage: run-tool.sh <tool> [args...]

set -uo pipefail

TOOL="${1:-}"
if [[ -z "$TOOL" ]]; then
	printf 'run-tool.sh: a tool name is required\n' >&2
	exit 2
fi
shift

if command -v "$TOOL" >/dev/null 2>&1; then
	exec "$TOOL" "$@"
fi

MISE_SHIMS="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
if [[ -x "${MISE_SHIMS}/${TOOL}" ]]; then
	exec "${MISE_SHIMS}/${TOOL}" "$@"
fi

if command -v mise >/dev/null 2>&1; then
	resolved=$(mise which "$TOOL" 2>/dev/null) || resolved=""
	if [[ -n "$resolved" && -x "$resolved" ]]; then
		exec "$resolved" "$@"
	fi
fi

# Deliberate: 127 is what inspector reads as tool_missing. A tool that genuinely
# is not installed should still be reported that way rather than as a crash.
exec "$TOOL" "$@"
