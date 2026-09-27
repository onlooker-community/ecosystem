#!/usr/bin/env bash
# Librarian SessionStart surfacer.
#
# Counts pending proposals in the project's queue and injects a one-line
# `additionalContext` pointer if any exist. The full proposal bodies live
# in ~/.onlooker/librarian/<project-key>/proposals/ and are reviewed via
# the /librarian review skill rather than inlined here — SessionStart
# context is precious, and a queue of 20 distilled-but-unreviewed memories
# isn't where it should go.
#
# Hook contract:
#   - Always exits 0. Never blocks session start.
#   - Emits valid hookSpecificOutput JSON, even when nothing to say.
#   - No-ops when there is no project key (no git context).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "librarian-session-start"

# Ecosystem substrate (validate-path.sh) lives in the sibling ecosystem plugin.
# Resolution is shared rather than repeated: fourteen hooks each carried a
# byte-identical copy of this lookup, and it was wrong the same two ways in all
# fourteen (ecosystem-449.36, ecosystem-449.35). Fixing it fourteen times is how
# it stayed broken. See scripts/lib/substrate-resolve.sh.
# shellcheck source=../lib/substrate-resolve.sh
source "${PLUGIN_ROOT}/scripts/lib/substrate-resolve.sh"
_ECOSYSTEM_ROOT=$(onlooker_resolve_substrate "$PLUGIN_ROOT")

if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
fi

# shellcheck source=../lib/librarian-config.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
# shellcheck source=../lib/librarian-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
# shellcheck source=../lib/librarian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
# shellcheck source=../lib/librarian-lesson-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
# shellcheck source=../lib/librarian-lesson-validate.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
# shellcheck source=../lib/librarian-lesson-review.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-review.sh"

# Emit hookSpecificOutput with the given additionalContext string. An
# empty string is fine — the harness sees "nothing to say".
_emit() {
	local context="${1:-}"
	jq -cn --arg ctx "$context" '
		{
			hookSpecificOutput: {
				hookEventName: "SessionStart",
				additionalContext: $ctx
			}
		}
	'
}

INPUT=$(cat 2>/dev/null || true)
hook_health_context "$INPUT"
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
[[ -z "$CWD" ]] && CWD="$(pwd)"

librarian_config_load "$CWD"

PROJECT_KEY=$(librarian_project_key "$CWD")
if [[ -z "$PROJECT_KEY" ]]; then
	_emit ""
	hook_health_exit 0
fi

# Unconditional: NOT gated on lesson_auto.enabled. Gating it would strand every
# held lesson the moment the flag was turned off — written, judged, approved,
# and invisible forever. Deterministic file movement, no LLM call, so ADR-003
# is satisfied.
#
# The sweep's stdout is the ids it just moved into approved/ — the one moment
# a lesson leaves this machine unattended. Captured here (rather than
# discarded, as before) so that moment gets a line below instead of vanishing
# the instant the veto window elapses between sessions.
SWEPT_OUTPUT=$(librarian_lesson_sweep_held "$PROJECT_KEY" 2>/dev/null) || SWEPT_OUTPUT=""

HELD=$(librarian_lesson_count_held "$PROJECT_KEY" 2>/dev/null) || HELD=0

# bash 3.2 has no mapfile/readarray, so split the sweep's one-id-per-line
# stdout by hand.
SWEPT_IDS=()
if [[ -n "$SWEPT_OUTPUT" ]]; then
	while IFS= read -r _swept_id; do
		[[ -n "$_swept_id" ]] && SWEPT_IDS+=("$_swept_id")
	done <<< "$SWEPT_OUTPUT"
fi
SWEPT_COUNT=${#SWEPT_IDS[@]}

SKIP_WHEN_ZERO=$(librarian_config_get '.librarian.surfacer.skip_inject_when_zero')
[[ -z "$SKIP_WHEN_ZERO" || "$SKIP_WHEN_ZERO" == "null" ]] && SKIP_WHEN_ZERO="true"

MAX_PENDING=$(librarian_config_get '.librarian.surfacer.max_pending_for_inject')
[[ -z "$MAX_PENDING" || "$MAX_PENDING" == "null" ]] && MAX_PENDING=20

PENDING=$(librarian_storage_count_pending "$PROJECT_KEY")
[[ -z "$PENDING" || "$PENDING" == "null" ]] && PENDING=0

LESSON_PENDING=$(librarian_lesson_list_pending "$PROJECT_KEY" | jq 'length' 2>/dev/null) || LESSON_PENDING=0
[[ -z "$LESSON_PENDING" || "$LESSON_PENDING" == "null" ]] && LESSON_PENDING=0

# HELD and SWEPT_COUNT must count toward this gate too, not just the other two
# queues: a lessons-only-held session (no pending memory proposals, no pending
# lesson candidates) would otherwise hit the default skip-when-zero exit before
# the HELD_LINE below ever builds, shipping the held lesson next sweep with the
# user never having seen the veto window at all. The same is true the other
# direction: a session whose sweep just shipped the last held lesson has
# HELD == 0 by the time it's counted (the sweep already ran), so without
# SWEPT_COUNT here that publication would be the one thing this hook has
# nothing to say about.
if [[ "$PENDING" -eq 0 && "$LESSON_PENDING" -eq 0 && "${HELD:-0}" -eq 0 && "${SWEPT_COUNT:-0}" -eq 0 && "$SKIP_WHEN_ZERO" == "true" ]]; then
	_emit ""
	hook_health_exit 0
fi

# The two queues fill independently, so a lessons-only session (the common
# case per the trap this hook guards against) must not resurrect the "0
# pending" memory noise skip_inject_when_zero exists to suppress — only
# build the memory line when there's something to say or the config opts
# out of skipping.
CONTEXT=""
if [[ "$PENDING" -gt 0 || "$SKIP_WHEN_ZERO" != "true" ]]; then
	# Cap the surfaced number so a runaway queue doesn't make the pointer
	# itself look alarming. Users still see the truthful count in
	# /librarian review.
	if [[ "$PENDING" -gt "$MAX_PENDING" ]]; then
		DISPLAY_COUNT="${MAX_PENDING}+"
	else
		DISPLAY_COUNT="$PENDING"
	fi

	NOUN="proposals"
	[[ "$PENDING" -eq 1 ]] && NOUN="proposal"

	CONTEXT=$(printf 'Librarian has %s pending memory promotion %s. Review with `/librarian review`.' \
		"$DISPLAY_COUNT" "$NOUN")
fi

LESSON_LINE=""
if [[ "$LESSON_PENDING" -gt 0 ]]; then
	LESSON_LINE=$(printf '%s lesson candidate(s) awaiting confirmation — run /librarian lessons' "$LESSON_PENDING")
fi

if [[ -n "$LESSON_LINE" ]]; then
	if [[ -n "$CONTEXT" ]]; then
		CONTEXT="${CONTEXT}"$'\n'"${LESSON_LINE}"
	else
		CONTEXT="$LESSON_LINE"
	fi
fi

HELD_LINE=""
if [[ "${HELD:-0}" -gt 0 ]]; then
	HELD_LINE=$(printf '%s lesson(s) will leave this machine unless vetoed — run /librarian lessons queue' "$HELD")
fi

if [[ -n "$HELD_LINE" ]]; then
	if [[ -n "$CONTEXT" ]]; then
		CONTEXT="${CONTEXT}"$'\n'"${HELD_LINE}"
	else
		CONTEXT="$HELD_LINE"
	fi
fi

# Composed the same way as HELD_LINE and LESSON_LINE above. Named ids when the
# list is short enough to read at a glance; just the count once it isn't —
# the count is what matters, the ids are a convenience for `lessons show <id>`.
SWEPT_LINE=""
if [[ "$SWEPT_COUNT" -gt 0 ]]; then
	if [[ "$SWEPT_COUNT" -le 5 ]]; then
		SWEPT_IDS_JOINED=$(IFS=', '; printf '%s' "${SWEPT_IDS[*]}")
		SWEPT_LINE=$(printf '%s lesson(s) left this machine this session: %s' \
			"$SWEPT_COUNT" "$SWEPT_IDS_JOINED")
	else
		SWEPT_LINE=$(printf '%s lesson(s) left this machine this session' "$SWEPT_COUNT")
	fi
fi

if [[ -n "$SWEPT_LINE" ]]; then
	if [[ -n "$CONTEXT" ]]; then
		CONTEXT="${CONTEXT}"$'\n'"${SWEPT_LINE}"
	else
		CONTEXT="$SWEPT_LINE"
	fi
fi

_emit "$CONTEXT"
hook_health_exit 0
