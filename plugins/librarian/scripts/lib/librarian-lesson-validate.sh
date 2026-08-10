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

	# The integer-part alternative is [0-9]*[1-9][0-9]*, not [1-9][0-9]*: the
	# vendored pattern's equivalent is \d*[1-9]\d*, which allows a leading
	# zero digit (05, 007) as long as some digit is nonzero. [1-9][0-9]* only
	# permits a nonzero *leading* digit, so it rejects >=05 while the vendored
	# schema accepts it — a real jq/schema disagreement, not a style choice.
	local nonzero='([0-9]*[1-9][0-9]*(\.[0-9]+)?(\.[0-9]+)?|0+\.[0-9]*[1-9][0-9]*(\.[0-9]+)?|0+\.0+\.[0-9]*[1-9][0-9]*)'
	local any='[0-9]+(\.[0-9]+)?(\.[0-9]+)?'
	local pattern="^((<|<=|=)${any}|(>|>=)${nonzero}|(>|>=)${any} (<|<=)${any})$"

	# Use bash's own regex engine rather than grep: grep's ^/$ anchor to line
	# boundaries, not string boundaries, so a value with an embedded newline
	# could smuggle a valid line past an otherwise-rejected string. [[ =~ ]]
	# anchors to the whole string. The pattern must stay unquoted here —
	# quoting the right-hand side of =~ forces literal string matching.
	[[ "$r" =~ $pattern ]]
}

# Everything both validators check, excluding the scope branch. Kept in one
# place because it mirrors the vendored sub-schemas line for line; a second
# copy is how the jq rules and the schema drifted apart once already.
#
# Composed into a jq program by each validator, which appends its own scope
# clause. See librarian_lesson_validate_candidate for why the
# additionalProperties and minLength mirrors are not decorative.
_LIBRARIAN_LESSON_STRUCTURAL='
	(.claim | type) == "string" and (.claim | length) > 0
	and (.rationale | type) == "string" and (.rationale | length) > 0
	and (.evidence | type) == "object"
	and ((.evidence | keys) - ["artifact_ids", "session_ids", "project_key", "observed_at", "resolution"] | length) == 0
	and (.evidence.artifact_ids | type) == "array" and (.evidence.artifact_ids | length) > 0
	and (.evidence.artifact_ids | all(type == "string" and test("^[0-9A-HJKMNP-TV-Z]{26}$")))
	and (.evidence.session_ids | type) == "array" and (.evidence.session_ids | length) > 0
	and (.evidence.session_ids | all(type == "string" and length > 0))
	and (.evidence.project_key | type) == "string"
	and (.evidence.project_key | test("^[0-9a-f]{12}$"))
	and (.evidence.observed_at | type) == "string"
	and (.evidence.observed_at | test("^(?:(?:\\d\\d[2468][048]|\\d\\d[13579][26]|\\d\\d0[48]|[02468][048]00|[13579][26]00)-02-29|\\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\\d|30)|(?:02)-(?:0[1-9]|1\\d|2[0-8])))T(?:(?:[01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d(?:\\.\\d+)?)?(?:Z))$"))
	and (.evidence.resolution | type) == "string" and (.evidence.resolution | length) > 0
	and (.applies_to | type) == "object"
	and ((.applies_to | keys) - ["stack", "scope", "file_patterns", "task_kinds"] | length) == 0
	and (.applies_to.stack | type) == "array" and (.applies_to.stack | length) > 0
	and (.applies_to.stack | all(type == "string" and length > 0))
	and (.applies_to.file_patterns | type) == "array"
	and (.applies_to.file_patterns | all(type == "string" and length > 0))
	and (.applies_to.task_kinds | type) == "array"
	and (.applies_to.task_kinds | all(type == "string" and length > 0))
'

# The versioned branch, shared by both validators.
_LIBRARIAN_LESSON_SCOPE_VERSIONED='
	.applies_to.scope.kind == "versioned"
	and ((.applies_to.scope | keys) - ["kind", "versions"] | length) == 0
	and (.applies_to.scope.versions | type) == "object"
	and (.applies_to.scope.versions | length) > 0
'

# Checks that only apply to a versioned candidate: the cross-field rule JSON
# Schema cannot express, and the range pattern on each value.
#
# NUL-delimited, not newline-delimited: a range value with an embedded newline
# would otherwise split into two lines that can each pass individually even
# though the single value they came from is not a valid range. Do not skip
# empty reads either — jq never emits one for a non-empty object of strings,
# so an empty read means the range itself is empty, which is invalid.
_librarian_lesson_check_versions() {
	local candidate="$1"

	printf '%s' "$candidate" | jq -e '
		(.applies_to.scope.versions | keys) - .applies_to.stack | length == 0
	' >/dev/null 2>&1 || return 1

	local range
	while IFS= read -r -d '' range; do
		librarian_lesson_valid_range "$range" || return 1
	done < <(printf '%s' "$candidate" | jq --raw-output0 '.applies_to.scope.versions[]' 2>/dev/null)

	return 0
}

# Validate a full candidate. Prints nothing on success; prints a reason slug
# to stderr on failure.
#
# Usage: librarian_lesson_validate_candidate <candidate_json>
librarian_lesson_validate_candidate() {
	local candidate="${1:-}"
	[[ -z "$candidate" ]] && { printf 'schema_invalid\n' >&2; return 1; }

	# versioned ONLY. This is the guarantee that stops the transform minting
	# lessons that never expire: private lessons run no jury, so nothing
	# downstream would catch a bad version_independent claim. A human may
	# assert that branch — see librarian_lesson_validate_confirmed — because
	# the constraint in the review path forces it to a judged visibility.
	if ! printf '%s' "$candidate" | jq -e \
		"${_LIBRARIAN_LESSON_STRUCTURAL} and ${_LIBRARIAN_LESSON_SCOPE_VERSIONED}" \
		>/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	_librarian_lesson_check_versions "$candidate" || {
		printf 'schema_invalid\n' >&2
		return 1
	}

	return 0
}

# Validate a candidate a human has confirmed.
#
# Identical to librarian_lesson_validate_candidate except that it also permits
# the version_independent branch, which requires a non-empty justification.
#
# The two are NOT redundant and the difference is not stylistic. They encode
# different trust: this one bounds what a human may assert AND a jury will then
# check, because the review path refuses version_independent at private
# visibility. The transform's validator bounds what a model may assert
# unsupervised, where nothing downstream would catch a bad claim. Deleting
# either collapses that distinction.
#
# Usage: librarian_lesson_validate_confirmed <candidate_json>
librarian_lesson_validate_confirmed() {
	local candidate="${1:-}"
	[[ -z "$candidate" ]] && { printf 'schema_invalid\n' >&2; return 1; }

	local scope_clause='
		(
			('"${_LIBRARIAN_LESSON_SCOPE_VERSIONED}"')
			or (
				.applies_to.scope.kind == "version_independent"
				and ((.applies_to.scope | keys) - ["kind", "justification"] | length) == 0
				and (.applies_to.scope.justification | type) == "string"
				and (.applies_to.scope.justification | length) > 0
			)
		)
	'

	if ! printf '%s' "$candidate" | jq -e \
		"${_LIBRARIAN_LESSON_STRUCTURAL} and ${scope_clause}" \
		>/dev/null 2>&1; then
		printf 'schema_invalid\n' >&2
		return 1
	fi

	# Range and subset rules apply only to the versioned branch.
	if printf '%s' "$candidate" | jq -e '.applies_to.scope.kind == "versioned"' >/dev/null 2>&1; then
		_librarian_lesson_check_versions "$candidate" || {
			printf 'schema_invalid\n' >&2
			return 1
		}
	fi

	return 0
}
