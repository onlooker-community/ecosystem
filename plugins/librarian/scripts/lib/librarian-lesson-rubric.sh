#!/usr/bin/env bash
# Rubric selection for lesson judging.
#
# Two builtins live in config.json under librarian.lesson_judging.rubrics,
# mirroring tribunal's rubric.builtins shape so they stay legible to anyone who
# knows tribunal. Librarian loads them itself rather than sourcing tribunal's
# lib — see docs/adr/002-agent-definitions-are-shared-assets.md.
#
# The per-criterion weights and min_pass floors are DECLARED BUT INERT today:
# tribunal_aggregate discards the rubric it is handed, and no per-criterion
# score reaches any gate. They are the honest statement of intent and go live
# unchanged when ecosystem-pht lands. Nothing here may depend on them.
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
