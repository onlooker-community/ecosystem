#!/usr/bin/env bash
# Rubric selection for lesson judging.
#
# Two builtins live in config.json under librarian.lesson_judging.rubrics,
# mirroring tribunal's rubric.builtins shape so they stay legible to anyone who
# knows tribunal. Librarian loads them itself rather than sourcing tribunal's
# lib — see docs/adr/002-agent-definitions-are-shared-assets.md.
#
# The per-criterion weights and min_pass floors are LIVE as of ecosystem-pht:
# librarian_lesson_aggregate weights them and librarian_lesson_gate blocks on
# any criterion below its floor.
#
# `disclosure` at min_pass 0.9 is what makes the public tier stricter than org.
# It replaces gate_policy `unanimous`, which was intended as a stand-in for
# exactly this and turned out to be a no-op: at the configured two-judge panel,
# `unanimous` and `majority` agree on every possible pass count. See
# ecosystem-j74. Changing judge_types without re-reading that bead is how the
# hole reopens.
#
# Exposes:
#   librarian_lesson_rubric_id_for_visibility <visibility>
#   librarian_lesson_rubric_get <rubric_id>

# Map a confirmed lesson's visibility to the rubric that judges it.
#
# `private` maps to the empty string on purpose: that tier runs no jury at all,
# which is what makes cost scale with intent rather than artifact volume.
#
# Usage: librarian_lesson_rubric_id_for_visibility <visibility>
librarian_lesson_rubric_id_for_visibility() {
	case "${1:-}" in
		private) printf '' ;;
		org)     printf 'lesson-promotion' ;;
		public)  printf 'lesson-promotion-public' ;;
		*)       return 1 ;;
	esac
	return 0
}

# Echo one rubric as compact JSON. Returns 1 and echoes nothing if unknown.
#
# Usage: librarian_lesson_rubric_get <rubric_id>
librarian_lesson_rubric_get() {
	local rubric_id="${1:-}"
	[[ -z "$rubric_id" ]] && return 1

	local rubrics found
	rubrics=$(librarian_config_get '.librarian.lesson_judging.rubrics')
	[[ -z "$rubrics" || "$rubrics" == "null" ]] && return 1

	found=$(printf '%s' "$rubrics" | jq -c --arg id "$rubric_id" \
		'map(select(.id == $id)) | first // empty' 2>/dev/null) || return 1
	[[ -z "$found" || "$found" == "null" ]] && return 1

	printf '%s' "$found"
}
