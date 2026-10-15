#!/usr/bin/env bats

# `run -127` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

# The shared secret-redaction lib (ONL-167).
#
# The shape table is the load-bearing part. The bug this lib exists to fix was
# invisible because historian's fixture enumerated the four shapes its code
# implemented rather than the shapes a transcript can contain, so a pattern
# that was never there looked exactly like a pattern that worked.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/scripts/lib/onlooker-secret-patterns.sh"
}

# Every shape the lib claims to redact, as `name<TAB>sample`.
#
# Literals are split ("AKIA" "0123…") because the repository's secret scanner
# blocks a file containing a complete one - the same reason
# historian-session-end.bats builds its fixtures by concatenation.
_shape_samples() {
	printf '%s\n' \
		"aws	AKIA""0123456789ABCDEF" \
		"github_pat	ghp""_aaaaaaaaaaaaaaaaaaaaaaaa" \
		"github_oauth	gho""_bbbbbbbbbbbbbbbbbbbbbbbb" \
		"github_server	ghs""_cccccccccccccccccccccccc" \
		"github_user	ghu""_dddddddddddddddddddddddd" \
		"github_refresh	ghr""_eeeeeeeeeeeeeeeeeeeeeeee" \
		"anthropic	sk-""ant-ffffffffffffffffffffff" \
		"openai	sk-""gggggggggggggggggggggggg" \
		"bearer	Bearer ""hhhhhhhhhhhhhhhhhhhhhhhh" \
		"kv_equals	API_KEY=""iiiiiiiiiiiiiiii" \
		"kv_json	\"api_key\": \"""jjjjjjjjjjjjjjjj\""
}

# Redact one string; print the redacted text.
_redact_one() {
	onlooker_redact_secrets "$(jq -cn --arg s "$1" '[$s]')" | jq -r '.[0].redacted'
}

@test "every shape in the table is redacted" {
	local name sample out failed=""
	while IFS=$'\t' read -r name sample; do
		[ -n "$name" ] || continue
		out=$(_redact_one "$sample")
		# The secret value must be gone and the placeholder present. Both
		# halves matter: an empty result would satisfy the first alone.
		if printf '%s' "$out" | grep -qF "$sample"; then
			failed="${failed}${name}:not-redacted "
		fi
		if ! printf '%s' "$out" | grep -qF '[REDACTED:secret]'; then
			failed="${failed}${name}:no-placeholder "
		fi
	done < <(_shape_samples)
	[ -z "$failed" ] || { echo "shapes failing: $failed"; return 1; }
}

@test "the table covers every shape, so a dropped pattern cannot pass silently" {
	# A floor on the table itself. Without this, deleting a row would make the
	# loop above pass by iterating less.
	[ "$(_shape_samples | grep -c .)" -eq 11 ]
}

@test "a KV pair keeps its key and separator, losing only the value" {
	local out
	out=$(_redact_one "API_KEY=""iiiiiiiiiiiiiiii")
	[ "$out" = "API_KEY=[REDACTED:secret]" ]
}

@test "a JSON-style pair keeps its key and colon" {
	# The shape historian writes verbatim today. The separator and opening
	# quote survive because they are inside the pattern's capture group.
	local out
	out=$(_redact_one "\"api_key\": \"""jjjjjjjjjjjjjjjj\"")
	[[ "$out" == '"api_key": "[REDACTED:secret]'* ]] || return 1
	[[ "$out" != *jjjjjjjjjjjjjjjj* ]] || return 1
}

@test "ordinary text passes through untouched with a zero count" {
	local result
	result=$(onlooker_redact_secrets "$(jq -cn '["just some prose about keys"]')")
	[ "$(printf '%s' "$result" | jq -r '.[0].redacted')" = "just some prose about keys" ]
	[ "$(printf '%s' "$result" | jq -r '.[0].count')" = "0" ]
}

@test "count reports the number of substitutions" {
	local sample result
	sample="AKIA""0123456789ABCDEF and ghp""_aaaaaaaaaaaaaaaaaaaaaaaa"
	result=$(onlooker_redact_secrets "$(jq -cn --arg s "$sample" '[$s]')")
	[ "$(printf '%s' "$result" | jq -r '.[0].count')" = "2" ]
}

@test "the batch result is positionally aligned with its input" {
	# Task 3 zips counts back onto chunk records by index, so alignment is a
	# contract rather than a convenience.
	local result
	result=$(onlooker_redact_secrets "$(jq -cn --arg a "AKIA""0123456789ABCDEF" '["clean one", $a, "clean two"]')")
	[ "$(printf '%s' "$result" | jq -r 'length')" = "3" ]
	[ "$(printf '%s' "$result" | jq -r '.[0].redacted')" = "clean one" ]
	[ "$(printf '%s' "$result" | jq -r '.[1].count')" = "1" ]
	[ "$(printf '%s' "$result" | jq -r '.[2].redacted')" = "clean two" ]
}

@test "quotes and newlines survive the JSON round trip" {
	# The round trip is new surface this lib introduces; a body carrying a
	# quote or a newline must come back intact.
	local sample result
	sample=$(printf 'line one "quoted"\nline two')
	result=$(onlooker_redact_secrets "$(jq -cn --arg s "$sample" '[$s]')")
	[ "$(printf '%s' "$result" | jq -r '.[0].redacted')" = "$sample" ]
}

@test "an empty array returns an empty array" {
	[ "$(onlooker_redact_secrets '[]' | jq -r 'length')" = "0" ]
}

@test "a missing argument is treated as an empty array" {
	[ "$(onlooker_redact_secrets | jq -r 'length')" = "0" ]
}

@test "fails closed when python3 is unavailable" {
	# A redactor that fails OPEN is the leak it exists to prevent. Both
	# existing callers already behave this way; nothing asserted it.
	local stub="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$stub"
	printf '#!/bin/sh\nexit 127\n' > "${stub}/python3"
	chmod +x "${stub}/python3"

	local sample payload
	sample="AKIA""0123456789ABCDEF"
	payload=$(jq -cn --arg s "$sample" '[$s]')

	# `run`, not a `$( )` capture. The function propagates python3's exit
	# status, so a command substitution here aborts the test body under errexit
	# before any assertion runs - which is a test bug that looks exactly like
	# the code failing. Fail-closed is a claim about OUTPUT; a nonzero status
	# is correct and is what lets a caller tell failure from an empty batch.
	# `run -127` rather than a bare `run`: bats treats an unexpected 127 as a
	# likely typo and errors out with advice to pin it, and 127 is exactly what
	# an absent interpreter produces. Pinning it states the expectation.
	run -127 bash -c "PATH='${stub}:${PATH}'
		source '${REPO_ROOT}/scripts/lib/onlooker-secret-patterns.sh'
		onlooker_redact_secrets '${payload}' 2>/dev/null"

	[ -z "$output" ] || return 1
	printf '%s' "$output" | grep -qF "$sample" && return 1
	true
}
