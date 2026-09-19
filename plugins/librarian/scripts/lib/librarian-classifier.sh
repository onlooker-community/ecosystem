#!/usr/bin/env bash
# Type classifier for librarian candidates.
#
# Calls `claude -p` with a structured prompt that maps a single archivist
# artifact to one of the four memory types (user, feedback, project,
# reference) or null when the artifact is interesting but session-only.
#
# Returns the model's JSON response on stdout, or empty string on any
# error (timeout, missing CLI, invalid JSON, low confidence). Callers
# treat empty as "drop this candidate".
#
# Config inputs (read via librarian_config_get from the caller):
#   librarian.classifier.model              Anthropic model id
#   librarian.classifier.temperature        Sampling temperature
#   librarian.classifier.max_output_tokens  Output cap
#   librarian.classifier.min_classifier_confidence  Drop below this

# Hard wall-clock ceiling for a single classifier call.
#
# ecosystem-449.72: this was 20s, and it was BELOW the time a call takes. A
# hook resolves /opt/homebrew/bin/claude, and against that binary one call put
# its answer on stdout at +39,065ms and exited at +46,484ms; a trivial prompt
# cost ~29,000ms, so most of it is nested CLI session startup rather than model
# work (ecosystem-449.73). Every call was therefore killed before its answer
# arrived, returned empty, and was recorded as classified_null -- which is why
# librarian.candidate.proposed is 0 all-time (ecosystem-449.67).
#
# The old comment said this existed so "a hung LLM" could not delay SessionEnd.
# Nothing was hung. The call simply costs more than SessionEnd's entire 1500ms
# ceiling, which is why classification now runs in a detached worker with no
# ceiling, and why this bound can be generous. It is a backstop against a call
# that never returns, not a budget.
_LIBRARIAN_CLASSIFIER_TIMEOUT_SECONDS=120

# Let config override it, so the bound can be tuned without editing the lib.
# Read at call time rather than source time: the accessor needs
# librarian_config_load to have run, and this file is sourced before that.
_librarian_classifier_timeout() {
	local configured=""
	if declare -F librarian_config_get >/dev/null 2>&1; then
		configured=$(librarian_config_get '.librarian.classifier.timeout_seconds' 2>/dev/null)
	fi
	case "$configured" in
		'' | null | *[!0-9]*) printf '%s' "$_LIBRARIAN_CLASSIFIER_TIMEOUT_SECONDS" ;;
		*) printf '%s' "$configured" ;;
	esac
}

# Build the classifier prompt for a single artifact.
# Usage: librarian_classifier_build_prompt <artifact_json>
librarian_classifier_build_prompt() {
	local artifact="$1"
	local kind summary detail files_list session_id created_at

	kind=$(printf '%s' "$artifact" | jq -r '.kind // ""')
	summary=$(printf '%s' "$artifact" | jq -r '.summary // ""')
	detail=$(printf '%s' "$artifact" | jq -r '.detail // ""')
	files_list=$(printf '%s' "$artifact" | jq -r '(.files // []) | join(", ")')
	session_id=$(printf '%s' "$artifact" | jq -r '.session_id // ""')
	created_at=$(printf '%s' "$artifact" | jq -r '.created_at // ""')

	cat <<EOF
You are classifying a session artifact for promotion into a long-term memory store.

The store has four types:
- user: durable facts about the user's role, expertise, or working style
- feedback: corrections or validated preferences ("don't do X", "yes, keep doing Y")
- project: ongoing work facts, decisions, constraints not derivable from the code
- reference: pointers to external systems (issue trackers, dashboards, channels)

RULES:
- Output ONLY a single JSON object on one line, no markdown fences, no prose.
- Schema: { "type": "<user|feedback|project|reference|null>",
            "title": "<<=60 chars>",
            "body": "<the memory content; structure per type>",
            "confidence": <float 0-1> }
- Use "type": null when the artifact is interesting but session-only (a
  specific bug fix, a one-off question that got answered, an exploration
  that didn't change anything).
- For feedback and project types, include **Why:** and **How to apply:**
  lines inside the body.

<artifact>
kind: ${kind}
summary: ${summary}
detail: ${detail}
files: ${files_list}
session_id: ${session_id}
created_at: ${created_at}
</artifact>
EOF
}

# Call the classifier for one artifact. Prints the model's JSON output or
# empty string on error.
#
# Usage: librarian_classifier_call <artifact_json> <model> <temperature>
#                                  <max_output_tokens>
librarian_classifier_call() {
	local artifact="$1"
	local model="${2:-}"
	local temperature="${3:-0.2}"
	local max_tokens="${4:-256}"

	command -v claude >/dev/null 2>&1 || return 0
	[[ -z "$artifact" ]] && return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-classify.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-classify.$$"
	# shellcheck disable=SC2064
	trap "rm -f '$prompt_file'" EXIT

	librarian_classifier_build_prompt "$artifact" > "$prompt_file" || return 0

	local args=(-p --max-turns 1)
	[[ -n "$model" ]] && args+=(--model "$model")

	local bound
	bound=$(_librarian_classifier_timeout)

	# The bare-claude branch is last for a reason beyond preference. In any
	# shell where an account-picker function named `claude` is defined, calling
	# it as a command runs the FUNCTION -- which on this machine prints "pick an
	# account" and returns 1, so the classifier fails silently on every call.
	# `timeout claude ...` executes a PROGRAM and bypasses the function, which
	# is the only reason the first two branches work at all.
	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$bound" claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$bound" claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(command claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi

	rm -f "$prompt_file"
	trap - EXIT

	[[ -z "$response" ]] && return 0

	# Strip accidental markdown fences before parsing.
	local clean
	clean=$(printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')

	# Validate the response shape before passing it back.
	if ! printf '%s' "$clean" | jq -e '
		(.type == null or (.type | IN("user", "feedback", "project", "reference")))
		and (.title | type) == "string"
		and (.body | type) == "string"
		and (.confidence | type) == "number"
	' >/dev/null 2>&1; then
		return 0
	fi

	printf '%s' "$clean"
}

# Synthesize a deterministic filename from a classifier result.
# Used when writing accepted promotions into the typed memory store.
# Format: <type>_<slugified-title>.md
#
# Usage: librarian_classifier_filename <type> <title>
librarian_classifier_filename() {
	local type="$1"
	local title="$2"
	local slug
	slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
		| sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g' \
		| cut -c1-60)
	[[ -z "$slug" ]] && slug="memory"
	printf '%s_%s.md' "$type" "$slug"
}
