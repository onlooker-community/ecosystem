#!/usr/bin/env bash
# SessionEnd hook stub for Librarian.
#
# Reads archivist artifacts created since the last scan, classifies each
# candidate into a memory type, and writes proposals to the queue. Full
# pipeline lands in a follow-up commit; this stub is the entry point that
# exits 0 unconditionally so the plugin is safe to install during design phase.

set -uo pipefail

# Bail immediately if disabled or if Onlooker substrate is absent.
[[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]] && exit 0
[[ ! -d "${ONLOOKER_DIR:-$HOME/.onlooker}" ]] && exit 0

# shellcheck source=../lib/librarian-config.sh
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/librarian-config.sh"

librarian_config_load "$(pwd)"
librarian_config_enabled || exit 0

# Implementation lands in a follow-up commit.
exit 0
