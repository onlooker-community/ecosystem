#!/usr/bin/env bash
# SessionStart hook stub for Librarian.
#
# Counts pending proposals and injects a one-line "Librarian has N pending
# proposals" pointer if any exist. Full implementation lands in a follow-up
# commit; this stub is the entry point that exits 0 unconditionally so the
# plugin is safe to install during design phase.

set -uo pipefail

[[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]] && exit 0
[[ ! -d "${ONLOOKER_DIR:-$HOME/.onlooker}" ]] && exit 0

# shellcheck source=../lib/librarian-config.sh
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/librarian-config.sh"

librarian_config_load "$(pwd)"
librarian_config_enabled || exit 0

# Implementation lands in a follow-up commit.
exit 0
