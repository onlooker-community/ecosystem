#!/usr/bin/env bash
# A lesson's scope, derived from what Observe read rather than asked of the
# model. D4 and D5 of the evidenced-portability design. Pure jq, no I/O.

# The D4 rule as a jq function, shared by both entry points. A leading ^ and
# a v are read as the version they start at: a caret range IS D4's range.
# Anything else, including a prerelease, a bare major or a date, gets none.
_LIBRARIAN_LESSON_D4='
	def d4:
		strings
		| (capture("^\\^?v?(?<x>[0-9]{1,9})\\.(?<y>[0-9]{1,9})(\\.(?<z>[0-9]{1,9}))?$") // null) as $m
		| if $m == null then empty
		  else
			($m.x | tonumber) as $x
			| (if $m.z then "\($m.x).\($m.y).\($m.z)" else "\($m.x).\($m.y)" end) as $low
			| if $x >= 1 then ">=\($low) <\($x + 1)"
			  else ">=\($low) <0.\(($m.y | tonumber) + 1)"
			  end
		  end;
'

# Usage: librarian_lesson_range_for_version <version>
librarian_lesson_range_for_version() {
	jq -rn --arg v "${1:-}" "${_LIBRARIAN_LESSON_D4}"' $v | d4' 2>/dev/null || true
}

# Usage: librarian_lesson_scope_from_observation <stack_json> <observation_json>
librarian_lesson_scope_from_observation() {
	local stack="${1:-[]}" observation="${2:-}"
	printf '%s' "$observation" | jq -e 'type == "object"' >/dev/null 2>&1 \
		|| observation='{}'
	jq -cn --argjson stack "$stack" --argjson obs "$observation" "${_LIBRARIAN_LESSON_D4}"'
		if ($stack | length) == 0 then {kind: "no_stack"}
		else
			([$stack[] | strings as $e
			  | ((($obs.observed_on? | objects | .[$e]? | objects | .version?)) // empty) as $v
			  | ([$v | d4] | first) as $r
			  | select($r != null)
			  | {key: $e, value: $r}] | from_entries) as $versions
			| if ($versions | length) > 0 then {kind: "versioned", versions: $versions}
			  else {kind: "unscoped"}
			  end
		end
	' 2>/dev/null || printf '{"kind":"unscoped"}'
}
