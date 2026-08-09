#!/usr/bin/env bash
# Pure validation rules for lesson candidates. No I/O, no network, no CLI.
#
# These rules mirror the vendored sub-schemas in plugins/librarian/schema/.
# ajv cannot run at runtime (installed plugins ship no node_modules, ADR-005),
# so enforcement here is jq. The two mechanisms have been proven able to
# disagree, so tests assert them separately.

# Version-shaped token check. Returns 0 when the artifact could plausibly
# yield a versioned scope, 1 when it definitionally cannot.
#
# This rejects only what is impossible, never what is merely low quality:
# the transform can emit `versioned` scope alone, so an artifact with no
# version token anywhere cannot produce a valid scope.versions.
#
# Usage: librarian_lesson_pregate <artifact_json>
librarian_lesson_pregate() {
	local artifact="${1:-}"
	[[ -z "$artifact" ]] && return 1

	local text
	text=$(printf '%s' "$artifact" | jq -r '((.summary // "") + " " + (.detail // ""))' 2>/dev/null) || return 1
	[[ -z "$text" ]] && return 1

	# Dotted (5.4.21), v-prefixed (v5), or x-range (5.x).
	printf '%s' "$text" | grep -qE '([0-9]+\.[0-9]+)|(\bv[0-9]+)|([0-9]+\.x\b)'
}

# Version range check, mirroring the vendored pattern.
#
# Accepts: <6  <=6  =6  >4  >=4  ">=4 <6"
# Rejects: ^5.4.21  ~5  5.x  5.4.21  >=0  >=0.0.0
#
# The >= and > forms require a non-zero lower bound. An unbounded lower bound
# matches every session and would never expire — version independence in
# disguise, which this stage is not allowed to mint.
#
# Usage: librarian_lesson_valid_range <string>
librarian_lesson_valid_range() {
	local r="${1:-}"
	[[ -z "$r" ]] && return 1

	local nonzero='([1-9][0-9]*(\.[0-9]+)?(\.[0-9]+)?|0+\.[0-9]*[1-9][0-9]*(\.[0-9]+)?|0+\.0+\.[0-9]*[1-9][0-9]*)'
	local any='[0-9]+(\.[0-9]+)?(\.[0-9]+)?'

	printf '%s' "$r" | grep -qE "^((<|<=|=)${any}|(>|>=)${nonzero}|(>|>=)${any} (<|<=)${any})$"
}

# Validate a full candidate. Prints nothing on success; prints a reason slug
# to stderr on failure.
#
# Usage: librarian_lesson_validate_candidate <candidate_json>
librarian_lesson_validate_candidate() {
	local candidate="${1:-}"
	[[ -z "$candidate" ]] && { printf 'schema_invalid\n' >&2; return 1; }

	# Structural shape, including the versioned-only rule and a non-empty
	# resolution. `versions` must be a non-empty object.
	if ! printf '%s' "$candidate" | jq -e '
		(.claim | type) == "string" and (.claim | length) > 0
		and (.rationale | type) == "string" and (.rationale | length) > 0
		and (.evidence.artifact_ids | type) == "array" and (.evidence.artifact_ids | length) > 0
		and (.evidence.session_ids | type) == "array" and (.evidence.session_ids | length) > 0
		and (.evidence.project_key | type) == "string"
		and (.evidence.project_key | test("^[0-9a-f]{12}$"))
		and (.evidence.observed_at | type) == "string"
		and (.evidence.resolution | type) == "string" and (.evidence.resolution | length) > 0
		and (.applies_to.stack | type) == "array" and (.applies_to.stack | length) > 0
		and (.applies_to.file_patterns | type) == "array"
		and (.applies_to.task_kinds | type) == "array"
		and .applies_to.scope.kind == "versioned"
		and (.applies_to.scope.versions | type) == "object"
		and (.applies_to.scope.versions | length) > 0
	' >/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	# Cross-field rule JSON Schema cannot express: every versions key must
	# name an entry in stack.
	if ! printf '%s' "$candidate" | jq -e '
		(.applies_to.scope.versions | keys) - .applies_to.stack | length == 0
	' >/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	# Every range must satisfy the vendored pattern.
	local range
	while IFS= read -r range; do
		[[ -z "$range" ]] && continue
		librarian_lesson_valid_range "$range" || { printf 'schema_invalid\n' >&2; return 1; }
	done < <(printf '%s' "$candidate" | jq -r '.applies_to.scope.versions[]' 2>/dev/null)

	return 0
}
