#!/usr/bin/env bats
#
# Tests the librarian SessionStart surfacer. Verifies:
#   - Disabled config: empty additionalContext, exit 0.
#   - No git context: empty additionalContext, exit 0.
#   - Empty proposal queue + skip_inject_when_zero=true: empty context.
#   - Pending proposals: one-line pointer with the count and pluralization.
#   - Overflow: counts above max_pending_for_inject render as "<cap>+".

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/librarian-surfacer-test.git

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
  PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]
  LIBRARIAN_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}"

  mkdir -p "${PROJECT_REPO}/.claude"

  HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-start.sh"
}

_input() {
  jq -cn --arg cwd "$PROJECT_REPO" \
    '{cwd: $cwd, source: "startup", session_id: "sess-start-test"}'
}

# Helper: drop a proposal file with the given status into the queue.
_seed_proposal() {
  local id="$1" status="${2:-pending}"
  mkdir -p "${LIBRARIAN_DIR}/proposals"
  jq -n --arg id "$id" --arg status "$status" \
    '{
      id: $id,
      created_at: "2026-06-01T00:00:00Z",
      source_artifact_ids: [],
      source_session_ids: [],
      proposed: { type: "feedback", filename: ($id + ".md"),
                  title: "t", body: "b", classifier_confidence: 0.8 },
      conflict_state: "none",
      conflict_with: [],
      status: $status
    }' > "${LIBRARIAN_DIR}/proposals/${id}.json"
}


@test "surfacer emits empty context when there is no git context" {
  local non_git="${BATS_TEST_TMPDIR}/no-git"
  mkdir -p "$non_git"
  local input
  input=$(jq -cn --arg cwd "$non_git" '{cwd: $cwd, source: "startup", session_id: "s"}')

  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

@test "surfacer emits empty context when no proposals are pending" {
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

@test "surfacer surfaces one-line pointer when proposals exist (plural)" {
  _seed_proposal "01PROPOSAL11111111111111A"
  _seed_proposal "01PROPOSAL11111111111111B"
  _seed_proposal "01PROPOSAL11111111111111C"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Librarian has 3 pending memory promotion proposals"* ]] || return 1
  [[ "$ctx" == *"/librarian review"* ]]
}

@test "surfacer pluralizes singular vs plural correctly" {
  _seed_proposal "01PROPOSALSINGULAR0000000"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Librarian has 1 pending memory promotion proposal"* ]] || return 1
  [[ "$ctx" != *"proposals."* ]]
}

@test "surfacer ignores accepted/rejected proposals when counting pending" {
  _seed_proposal "01PROPOSALACCEPTED000000" "accepted"
  _seed_proposal "01PROPOSALREJECTED000000" "rejected"
  _seed_proposal "01PROPOSALPENDING0000000" "pending"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"1 pending memory promotion proposal"* ]]
}

@test "surfacer caps display at max_pending_for_inject + '+'" {
  # Override max to 3 via a project settings overlay.
  printf '%s\n' '{"librarian":{"surfacer":{"max_pending_for_inject":3}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
  for i in A B C D E; do
    _seed_proposal "01PROPOSALCAP$i$i$i$i$i$i$i$i$i$i$i$i"
  done

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Librarian has 3+ pending memory promotion proposals"* ]]
}

@test "session-start surfaces a pending lesson count as its own line" {
	# Reuse this file's existing project/hook setup, then seed one pending
	# lesson through the storage lib.
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	librarian_lesson_storage_init "$PROJECT_KEY"
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(jq -cn '{claim: "c", rationale: "r"}')" "01KZ45MKAM734ZS7JK24D2DK0R" >/dev/null

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"lesson"* ]] || return 1
}

@test "session-start surfaces lessons even with zero memory proposals" {
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	librarian_lesson_storage_init "$PROJECT_KEY"
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(jq -cn '{claim: "c", rationale: "r"}')" "01KZ45MKAM734ZS7JK24D2DK0R" >/dev/null

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"lesson"* ]] || return 1
}

# Helper: drop a held lesson pool entry plus its proposal envelope directly
# (skipping the promote pipeline, which this file doesn't otherwise pull in),
# with shippable_after far in the future so the hook's own sweep leaves it
# held rather than shipping it out from under the test.
_seed_held_lesson() {
	local id="$1"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	librarian_lesson_storage_init "$PROJECT_KEY"
	jq -n --arg id "$id" \
		'{id: $id, status: "approved", visibility: "public",
		  artifact_id: "01KZ45MKAM734ZS7JK24D2DK0R",
		  candidate: {claim: "c", rationale: "r"}}' \
		> "${LIBRARIAN_DIR}/lessons/approved_held/${id}.json"
	jq -n --arg id "$id" \
		'{id: $id, status: "approved", shippable_after: "2099-01-01T00:00:00Z"}' \
		> "${LIBRARIAN_DIR}/lessons/proposals/${id}.json"
}

@test "session-start surfaces the held count, with zero pending queues on either side" {
	# The skip-when-zero gate is the whole reason the held count needs its
	# own term in that condition: with zero pending memory proposals and
	# zero pending lesson candidates, the default skip_inject_when_zero=true
	# would otherwise exit before this line is ever built, and a held lesson
	# would ship with the user never having seen the veto window.
	_seed_held_lesson 01M3HELDSURFACE000000001

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	local ctx
	ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
	[[ "$ctx" == *"1 lesson(s) will leave this machine unless vetoed"* ]] || return 1
	[[ "$ctx" == *"/librarian lessons queue"* ]]
	# Confirms the held lesson is still there — the sweep ran but its
	# window (2099) hasn't elapsed, so this isn't accidentally passing
	# because the lesson shipped and count_held now reads 0 some other way.
	[ -f "${LIBRARIAN_DIR}/lessons/approved_held/01M3HELDSURFACE000000001.json" ]
}

# Helper: same shape as _seed_held_lesson, but with an already-elapsed window
# so this hook's own sweep ships it into approved/ during the run.
_seed_shippable_lesson() {
	local id="$1"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	librarian_lesson_storage_init "$PROJECT_KEY"
	jq -n --arg id "$id" \
		'{id: $id, status: "approved", visibility: "public",
		  artifact_id: "01KZ45MKAM734ZS7JK24D2DK0R",
		  candidate: {claim: "c", rationale: "r"}}' \
		> "${LIBRARIAN_DIR}/lessons/approved_held/${id}.json"
	jq -n --arg id "$id" \
		'{id: $id, status: "approved", shippable_after: "2020-01-01T00:00:00Z"}' \
		> "${LIBRARIAN_DIR}/lessons/proposals/${id}.json"
}

@test "session-start surfaces what the sweep just shipped, with zero pending queues on either side" {
	# Mirrors the held-count test above, but for the moment that count exists
	# to prevent going silent about: the window has already elapsed, so this
	# hook's own sweep ships the lesson during the run, and HELD reads 0
	# afterward same as an empty queue would. Without a separate swept-count
	# term in the skip-when-zero gate, this is exactly the scenario the
	# review flagged as producing no line at all.
	_seed_shippable_lesson 01M3SWEPTSURFACE00000001

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	local ctx
	ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
	[[ "$ctx" == *"1 lesson(s) left this machine this session"* ]] || return 1
	[[ "$ctx" == *"01M3SWEPTSURFACE00000001"* ]] || return 1
	# The held line must NOT also fire for the same lesson — it shipped, it
	# is no longer held.
	[[ "$ctx" != *"will leave this machine unless vetoed"* ]]
	[ -f "${LIBRARIAN_DIR}/lessons/approved/01M3SWEPTSURFACE00000001.json" ]
	[ ! -f "${LIBRARIAN_DIR}/lessons/approved_held/01M3SWEPTSURFACE00000001.json" ]
}

@test "session-start announces each lesson its sweep shipped, under this session" {
	# The sweep's emit is guarded on librarian_emit being defined, and this
	# hook did not source librarian-emit.sh before ONL-116, so a sweep driven
	# from here would have shipped the lesson without a word on the bus.
	# These fixtures carry no promoted_at, so held_ms is absent, not zero.
	_seed_shippable_lesson 01M3SWEPTSURFACE00000003

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ] || return 1
	grep '"event_type":"librarian.lesson.shipped"' "${ONLOOKER_DIR}/logs/onlooker-events.jsonl" \
		| jq -e '.payload == {lesson_id: "01M3SWEPTSURFACE00000003"}
		         and .session_id == "sess-start-test"' >/dev/null
}

@test "session-start surfaces the swept count alongside a pending held lesson" {
	_seed_shippable_lesson 01M3SWEPTSURFACE00000002
	_seed_held_lesson 01M3HELDSURFACE000000003

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	local ctx
	ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
	[[ "$ctx" == *"1 lesson(s) left this machine this session"* ]] || return 1
	[[ "$ctx" == *"1 lesson(s) will leave this machine unless vetoed"* ]] || return 1
}

# Helper: a lesson whose verdict landed but whose promote() never did — the
# envelope carries a terminal status and no promoted_at, and nothing sits in
# approved/ or approved_held/. That is what auto_judge_one leaves behind when
# promote refuses before the pool write and its stderr is discarded (ONL-117).
_seed_stranded_lesson() {
	local id="$1" status="${2:-approved}"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	librarian_lesson_storage_init "$PROJECT_KEY"
	jq -n --arg id "$id" --arg s "$status" \
		'{id: $id, status: $s, created_at: "2026-06-01T00:00:00Z"}' \
		> "${LIBRARIAN_DIR}/lessons/proposals/${id}.json"
}

@test "session-start surfaces a stranded promotion, with zero pending queues on either side" {
	# Same trap as the held and swept lines: with nothing else to say, the
	# skip-when-zero gate would exit before this line builds, and the only
	# place the stranded lesson shows up is `lessons status`, which nobody
	# runs without a reason to.
	_seed_stranded_lesson 01M3STRANDED00000000001

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	local ctx
	ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
	[[ "$ctx" == *"1 lesson(s) judged but not promoted"* ]] || return 1
	[[ "$ctx" == *"/librarian lessons promote <id>"* ]] || return 1
	[[ "$ctx" == *"01M3STRANDED00000000001"* ]]
}

@test "session-start counts a rejected lesson whose declined row never landed" {
	_seed_stranded_lesson 01M3STRANDED00000000002 rejected

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	echo "$output" | jq -r '.hookSpecificOutput.additionalContext' \
		| grep -q '1 lesson(s) judged but not promoted'
}

@test "session-start stays silent about a lesson promote already stamped" {
	_seed_stranded_lesson 01M3STRANDED00000000003
	local p="${LIBRARIAN_DIR}/lessons/proposals/01M3STRANDED00000000003.json"
	jq '.promoted_at = "2026-06-01T00:00:00Z"' "$p" > "${p}.tmp" && mv "${p}.tmp" "$p"

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

@test "session-start names only the count once the stranded list is long" {
	local i
	for i in 1 2 3 4 5 6; do
		_seed_stranded_lesson "01M3STRANDEDLONG0000000${i}"
	done

	run bash -c "printf '%s' '$(_input)' | '$HOOK'"
	[ "$status" -eq 0 ]
	local ctx
	ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
	[[ "$ctx" == *"6 lesson(s) judged but not promoted"* ]] || return 1
	[[ "$ctx" != *"01M3STRANDEDLONG00000001"* ]]
}
