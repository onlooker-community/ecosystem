#!/usr/bin/env bats
#
# The project dimension on the event envelope (ONL-129, schema 2.28.0).
#
# The emitter never derives the key itself — it reads ONLOOKER_PROJECT_KEY and
# ONLOOKER_PROJECT_BASIS, which onlooker_project_resolve exports. That split is
# the point of the design: a JavaScript copy of the derivation that drifted from
# the bash one would stop matching the on-disk directory names under
# $ONLOOKER_DIR/<plugin>/<key>/, which is the join the field exists to enable.
# So the last test here pins emitted-key == lib-derived-key rather than trusting
# either side alone.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	load_validate_path
	# shellcheck source=../../scripts/lib/onlooker-schema.sh
	source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
	# shellcheck source=../../scripts/lib/onlooker-project-key.sh
	source "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git

	: >"$ONLOOKER_EVENTS_LOG"
}

# Emit one session.start through the canonical emitter with the two project env
# vars set to $1 and $2. Prints the emitted envelope.
_emit_with() {
	local key="$1" basis="$2" params
	params=$(jq -cn --arg sid "proj-session" --arg cwd "$PROJECT_REPO" \
		'{session_id: $sid, event_type: "session.start",
		  payload: {working_directory: $cwd}}')
	printf '%s' "$params" | env \
		ONLOOKER_DIR="$ONLOOKER_DIR" \
		ONLOOKER_PLUGIN_NAME="onlooker" \
		ONLOOKER_PROJECT_KEY="$key" \
		ONLOOKER_PROJECT_BASIS="$basis" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" emit
}

@test "both project fields ride the envelope when the resolver exported both" {
	local event
	event=$(_emit_with "ee2cfbe428c7" "remote")

	printf '%s' "$event" | jq -e '.project == "ee2cfbe428c7"' >/dev/null || return 1
	printf '%s' "$event" | jq -e '.project_basis == "remote"' >/dev/null || return 1
	# Optional envelope fields must not have moved the envelope version: an
	# existing consumer pinned to "1.0" has to keep accepting new events.
	printf '%s' "$event" | jq -e '.schema_version == "1.0"' >/dev/null || return 1
	printf '%s' "$event" | onlooker_validate_event
}

@test "a root-derived basis rides the envelope verbatim" {
	local event
	event=$(_emit_with "bc046590dad9" "root")

	printf '%s' "$event" | jq -e '.project_basis == "root"' >/dev/null || return 1
	printf '%s' "$event" | onlooker_validate_event
}

@test "both fields are omitted when the resolver derived no key" {
	# What a non-git directory produces: onlooker_project_resolve exports two
	# empty strings. Emitting project:"" would fail the ^[0-9a-f]{12}$ pattern,
	# and absence is the documented value for "not attributable".
	local event
	event=$(_emit_with "" "")

	printf '%s' "$event" | jq -e 'has("project") == false' >/dev/null || return 1
	printf '%s' "$event" | jq -e 'has("project_basis") == false' >/dev/null || return 1
	printf '%s' "$event" | onlooker_validate_event
}

@test "a key with no basis emits neither field" {
	# Both or neither, enforced in the emitter rather than trusted from the
	# caller. A key on the wire without its discriminator is the failure mode
	# the design rejected in its own section 2: the hosted view cannot tell a
	# portable remote-derived key from a machine-local one, so it silently
	# splits one repo into two rows with nothing on the wire revealing it.
	local event
	event=$(_emit_with "ee2cfbe428c7" "")

	printf '%s' "$event" | jq -e 'has("project") == false' >/dev/null || return 1
	printf '%s' "$event" | jq -e 'has("project_basis") == false' >/dev/null || return 1
	printf '%s' "$event" | onlooker_validate_event
}

@test "a basis with no key emits neither field" {
	local event
	event=$(_emit_with "" "remote")

	printf '%s' "$event" | jq -e 'has("project") == false' >/dev/null || return 1
	printf '%s' "$event" | jq -e 'has("project_basis") == false' >/dev/null || return 1
	printf '%s' "$event" | onlooker_validate_event
}

@test "the emitted key is byte-identical to the on-disk directory name" {
	# The whole point of the field. onlooker_project_resolve is what a hook
	# calls, and the key it exports is what plugins already use as their
	# artifact directory name — so emit through exactly that path and compare
	# against a directory built from the lib, not against a literal.
	onlooker_project_resolve "$PROJECT_REPO"
	[ -n "$ONLOOKER_PROJECT_KEY" ] || return 1

	local artifact_dir
	artifact_dir="${ONLOOKER_DIR}/librarian/${ONLOOKER_PROJECT_KEY}"
	mkdir -p "$artifact_dir"

	local event emitted
	event=$(_emit_with "$ONLOOKER_PROJECT_KEY" "$ONLOOKER_PROJECT_BASIS")
	emitted=$(printf '%s' "$event" | jq -r '.project')

	[ "$emitted" = "$(basename "$artifact_dir")" ] || return 1
	[ "$ONLOOKER_PROJECT_BASIS" = "remote" ] || return 1
	printf '%s' "$event" | onlooker_validate_event
}

@test "a non-repo cwd resolves to no key, so the envelope carries no project" {
	# The cartographer/inspector regression this consolidation deleted: two
	# implementations invented 715b9b271e0a for a directory that is not a repo,
	# which under this design would seed a phantom project into the per-repo
	# view. The canonical lib returns empty, and the emitter omits both fields.
	local not_a_repo="${BATS_TEST_TMPDIR}/plain"
	mkdir -p "$not_a_repo"

	onlooker_project_resolve "$not_a_repo"
	[ -z "$ONLOOKER_PROJECT_KEY" ] || return 1
	[ -z "$ONLOOKER_PROJECT_BASIS" ] || return 1

	local event
	event=$(_emit_with "$ONLOOKER_PROJECT_KEY" "$ONLOOKER_PROJECT_BASIS")
	printf '%s' "$event" | jq -e 'has("project") == false' >/dev/null || return 1
	printf '%s' "$event" | onlooker_validate_event
}

@test "emit-from-hook carries the project dimension too" {
	# tool.* and session.* events reach the log through emit-from-hook, which
	# is 79% of events by volume — the namespaces that carried no project key
	# at all before this change. A fix that only covered `emit` would miss them.
	onlooker_project_resolve "$PROJECT_REPO"

	local hook_input event
	hook_input=$(jq -cn --arg cwd "$PROJECT_REPO" --arg sid "hook-session" \
		'{cwd: $cwd, session_id: $sid, hook_event_name: "PostToolUse",
		  tool_name: "Read", tool_input: {file_path: "/tmp/x"}}')

	event=$(printf '%s' "$hook_input" | env \
		ONLOOKER_DIR="$ONLOOKER_DIR" \
		ONLOOKER_PLUGIN_NAME="onlooker" \
		ONLOOKER_PROJECT_KEY="$ONLOOKER_PROJECT_KEY" \
		ONLOOKER_PROJECT_BASIS="$ONLOOKER_PROJECT_BASIS" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" emit-from-hook)

	printf '%s' "$event" | jq -e --arg k "$ONLOOKER_PROJECT_KEY" '.project == $k' >/dev/null || return 1
	printf '%s' "$event" | jq -e '.project_basis == "remote"' >/dev/null || return 1
	printf '%s' "$event" | onlooker_validate_event
}
