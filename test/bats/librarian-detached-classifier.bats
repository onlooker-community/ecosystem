#!/usr/bin/env bats
#
# ecosystem-449.72. librarian's SessionEnd must not call an LLM.
#
# WHY. A hook resolves /opt/homebrew/bin/claude, and against that binary a
# single classifier call put its answer on stdout at +39,065ms and exited at
# +46,484ms. A trivial prompt cost ~29,000ms, so most of that is nested CLI
# session startup, not model work (ecosystem-449.73). SessionEnd's ceiling is
# 1500ms and is not raisable from a plugin, so one call is ~26x the entire
# budget.
#
# The shipped per-call timeout was 20s -- BELOW the ~39s the call needs -- so
# every call was killed before its answer arrived, returned empty, and the loop
# recorded classified_null. That is why librarian.candidate.proposed is 0
# all-time (ecosystem-449.67), and why raising the timeout and moving the work
# off SessionEnd have to land together: at 20s nothing ever returns, and a
# longer timeout inside SessionEnd would block it for minutes.
#
# So SessionEnd queues the window and spawns a detached worker, following
# plugin-currency-surfacer's _spawn_refresh. These tests pin the split: the hook
# makes no model calls and leaves a durable queue, and the worker does the
# classifying with no ceiling.

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
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/librarian-detached.git

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]

	ARCHIVIST_DIR="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
	LIBRARIAN_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}"
	ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	QUEUE_DIR="${LIBRARIAN_DIR}/classify-queue"
	mkdir -p "${PROJECT_REPO}/.claude"

	# Records every model call so a test can assert the hook made none. The
	# stub answers any classifier prompt, so a hook that still classified
	# inline would look successful -- which is exactly what must fail.
	export CLAUDE_CALL_LOG="${BATS_TEST_TMPDIR}/claude-calls"
	: > "$CLAUDE_CALL_LOG"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
[[ -n "${CLAUDE_CALL_LOG:-}" ]] && echo call >> "$CLAUDE_CALL_LOG"
if [[ "$prompt" == *"marker-baddesc"* ]]; then
  printf '%s' '{"type":"feedback","title":"Bad description","body":"Body survives a malformed description.","description":42,"confidence":0.88}'
elif [[ "$prompt" == *"marker-stub"* ]]; then
  printf '%s' '{"type":"feedback","title":"Prefer explicit config","body":"Prefer explicit configuration over inference.\n\n**Why:** Stated in review.\n**How to apply:** Require a config key rather than guessing.","description":"require a config key instead of inferring a setting","confidence":0.88}'
else
  printf '%s' '{"type":null,"title":"","body":"","confidence":0.2}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-end.sh"
	WORKER="${PLUGIN_ROOT}/scripts/lib/librarian-classify-worker.sh"
	FIXTURE_CREATED_AT=$(relative_iso_days_ago 1)

	# The spawn needs a durable, non-racing trace. Pointing the hook at a
	# sentinel worker records that it spawned without letting a real worker run
	# concurrently and pollute CLAUDE_CALL_LOG.
	SPAWN_SENTINEL="${BATS_TEST_TMPDIR}/spawned"
	SENTINEL_WORKER="${BATS_TEST_TMPDIR}/sentinel-worker.sh"
	cat > "$SENTINEL_WORKER" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$1" > "${SPAWN_SENTINEL}"
STUBEOF
	chmod +x "$SENTINEL_WORKER"
}

_seed_artifact() {
	local kind="$1" id="$2" summary="$3" detail="$4" created_at="${5:-$FIXTURE_CREATED_AT}"
	local dir="${ARCHIVIST_DIR}/${kind}"
	mkdir -p "$dir"
	jq -n \
		--arg id "$id" --arg kind "${kind%s}" \
		--arg project_key "$PROJECT_KEY" \
		--arg summary "$summary" --arg detail "$detail" \
		--arg created_at "$created_at" --arg session_id "sess-1" \
		'{ id: $id, kind: $kind, project_key: $project_key, source: "local",
		   created_at: $created_at, updated_at: $created_at,
		   summary: $summary, detail: $detail, files: [], session_id: $session_id }' \
		> "${dir}/${id}.json"
}

_hook_input() {
	jq -cn --arg cwd "$PROJECT_REPO" --arg sid "${1:-sess-detached}" \
		'{cwd: $cwd, session_id: $sid, hook_event_name: "SessionEnd"}'
}

# An artifact that survives the durability filter, so the run reaches the point
# where classification would happen.
_seed_survivor() {
	_seed_artifact decisions "01JBXQ2K3M4N5P6Q7R8S9T0V" \
		"marker-stub: prefer explicit config" \
		"We decided to prefer explicit configuration over inference. Because the inferred path was wrong in two projects, we now require a config key."
}

_run_hook() {
	LIBRARIAN_CLASSIFY_WORKER="$SENTINEL_WORKER" \
		bash -c "printf '%s' '$(_hook_input "${1:-sess-detached}")' | '$HOOK'"
}

# grep -c prints 0 AND exits 1 when it matches nothing, so a `|| printf 0`
# fallback emits "0\n0" and every numeric comparison against it fails to parse.
_events_of() {
	[ -f "$ONLOOKER_EVENTS_LOG" ] || { printf '0'; return 0; }
	local n
	n=$(grep -c "\"event_type\":\"$1\"" "$ONLOOKER_EVENTS_LOG" 2>/dev/null) || n=0
	printf '%s' "${n:-0}"
}

@test "SessionEnd makes no model calls of its own" {
	_seed_survivor
	run _run_hook
	[ "$status" -eq 0 ] || return 1
	# The whole point: 20s < ~39s meant every inline call failed anyway, and a
	# timeout long enough to succeed would blow a 1500ms ceiling.
	[ "$(wc -l < "$CLAUDE_CALL_LOG" | tr -d ' ')" -eq 0 ]
}

@test "SessionEnd leaves the surviving window in a durable queue" {
	_seed_survivor
	run _run_hook
	[ "$status" -eq 0 ] || return 1
	[ -d "$QUEUE_DIR" ] || return 1
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1
	# The queue is what makes advancing the watermark safe: the artifacts are
	# handed off, not dropped, so this does not need ecosystem-449.55.
	jq -e '(.artifacts | length) >= 1 and (.session_id | type) == "string"' "$queued" >/dev/null
}

@test "SessionEnd spawns the worker" {
	_seed_survivor
	run _run_hook
	[ "$status" -eq 0 ] || return 1
	# Positive half — without it the no-model-calls test above would pass on a
	# hook that simply never classifies at all.
	[ -f "$SPAWN_SENTINEL" ] || return 1
	# It must be handed the queue file it wrote.
	local handed
	handed=$(head -1 "$SPAWN_SENTINEL")
	[ -f "$handed" ]
}

@test "SessionEnd does not claim the scan completed when it only queued" {
	_seed_survivor
	run _run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(_events_of librarian.scan.started)" -eq 1 ] || return 1
	# The worker emits scan.complete with the real counts when it lands. The
	# outcome enum is ok|empty|skipped|budget_exceeded with
	# additionalProperties:false, so there is no value meaning "queued" -- and
	# claiming one of the others here would be a false report.
	[ "$(_events_of librarian.scan.complete)" -eq 0 ]
}

@test "an empty window still completes in the hook, without queueing" {
	# Nothing to hand off means nothing to defer: this path must keep reporting
	# for itself, or a quiet session would emit no outcome at all.
	run _run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(_events_of librarian.scan.complete)" -eq 1 ] || return 1
	[ ! -f "$SPAWN_SENTINEL" ]
}

@test "the worker classifies a queued window and reports the real outcome" {
	_seed_survivor
	run _run_hook
	[ "$status" -eq 0 ] || return 1
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1

	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1
	# Now the model is called, and now a proposal exists.
	[ "$(wc -l < "$CLAUDE_CALL_LOG" | tr -d ' ')" -ge 1 ] || return 1
	[ "$(_events_of librarian.candidate.proposed)" -ge 1 ] || return 1
	[ "$(_events_of librarian.scan.complete)" -eq 1 ]
}

@test "the worker removes its queue file only after succeeding" {
	_seed_survivor
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1
	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$queued" ]
}

# ONL-226. accept turns the proposal's description into the memory's recall
# hook, so the classifier has to be asked for one and the worker has to keep it.
@test "the classifier prompt asks for a one-line description" {
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-classifier.sh"
	run librarian_classifier_build_prompt '{"kind":"decision","summary":"s","detail":"d"}'
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *'"description": "<'* ]]
}

@test "the worker carries the classifier's description onto the proposal" {
	_seed_survivor
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1
	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1

	local proposal
	proposal=$(find "${LIBRARIAN_DIR}/proposals" -name '*.json' -type f | head -1)
	[ -n "$proposal" ] || return 1
	jq -e '.proposed.description == "require a config key instead of inferring a setting"' "$proposal" >/dev/null
}

@test "a malformed description is dropped, not the proposal" {
	_seed_artifact decisions "01JBXQ2K3M4N5P6Q7R8S9T0W" \
		"marker-baddesc: prefer explicit config" \
		"We decided to prefer explicit configuration over inference. Because the inferred path was wrong in two projects, we now require a config key."
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1
	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1

	local proposal
	proposal=$(find "${LIBRARIAN_DIR}/proposals" -name '*.json' -type f | head -1)
	[ -n "$proposal" ] || return 1
	# accept falls back to the body for a proposal with no description, so a
	# missing field is recoverable where a number would be written verbatim.
	jq -e '.proposed.body == "Body survives a malformed description."
	       and (.proposed | has("description") | not)' "$proposal" >/dev/null
}

@test "a queue file survives a worker that cannot classify" {
	_seed_survivor
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1

	# A claude that fails rather than a PATH without one. The first version of
	# this test used PATH=/usr/bin:/bin, which on macOS also hides jq (it is in
	# /opt/homebrew/bin) -- so the worker bailed at an early guard and the test
	# passed without ever reaching the classifier. On Linux jq is in /usr/bin,
	# the worker ran on, dropped every candidate and deleted the queue. CI found
	# the bug the local pass had hidden.
	#
	# Failing in place is also the realistic shape: the account-picker stub that
	# shadows `claude` in an interactive shell returns 1 exactly like this.
	cat > "${STUB_BIN}/claude" <<'BROKEN'
#!/usr/bin/env bash
cat >/dev/null
exit 1
BROKEN
	chmod +x "${STUB_BIN}/claude"

	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1
	# The input must stay on disk. The watermark has already advanced, so this
	# file is the only remaining record of the window.
	[ -f "$queued" ] || return 1
	# And nothing may claim the scan finished, nor that the model judged these
	# artifacts unworthy — no call was answered.
	[ "$(_events_of librarian.scan.complete)" -eq 0 ] || return 1
	[ "$(_events_of librarian.candidate.dropped)" -eq 0 ]
}

# ONL-192. When some calls answer and others come back empty, the run goes on,
# and the empty ones used to be recorded as candidate.dropped with
# classified_null -- a verdict nobody made, under a type a consumer reads as a
# deliberate skip. They are librarian.classifier.errored now.
@test "a call that does not come back is errored, not dropped as classified_null" {
	_seed_survivor
	_seed_artifact decisions "01JBXQ2K3M4N5P6Q7R8S9T0W" \
		"silent-stub: pin the runtime version" \
		"We decided to pin the runtime version in the repo. Because two machines drifted apart, we now require the pinned version everywhere."

	cat > "${STUB_BIN}/claude" <<'PARTIAL'
#!/usr/bin/env bash
prompt=$(cat)
[[ "$prompt" == *"silent-stub"* ]] && exit 0
if [[ "$prompt" == *"marker-stub"* ]]; then
  printf '%s' '{"type":"feedback","title":"Prefer explicit config","body":"Prefer explicit configuration over inference.\n\n**Why:** Stated in review.\n**How to apply:** Require a config key rather than guessing.","confidence":0.88}'
else
  printf '%s' '{"type":null,"title":"","body":"","confidence":0.2}'
fi
PARTIAL
	chmod +x "${STUB_BIN}/claude"

	run _run_hook
	[ "$status" -eq 0 ] || return 1
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1
	[ "$(jq '.artifacts | length' "$queued")" -eq 2 ] || return 1

	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1

	[ "$(_events_of librarian.classifier.errored)" -eq 1 ] || return 1
	grep '"event_type":"librarian.classifier.errored"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.reason == "no_response"
			and .payload.source_artifact_id == "01JBXQ2K3M4N5P6Q7R8S9T0W"' >/dev/null || return 1
	! grep '"event_type":"librarian.candidate.dropped"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null \
		| jq -e 'select(.payload.reason == "classified_null")' >/dev/null || return 1
	[ "$(_events_of librarian.candidate.proposed)" -eq 1 ]
}

@test "a second worker will not run against a queue already in flight" {
	_seed_survivor
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1

	# mkdir is the atomic test-and-set, same as _spawn_refresh uses.
	mkdir "${queued}.lock"
	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1
	# It declined, so it neither classified nor consumed the queue.
	[ "$(wc -l < "$CLAUDE_CALL_LOG" | tr -d ' ')" -eq 0 ] || return 1
	[ -f "$queued" ]
}

# The watermark advance in SessionEnd is only safe if a stranded window is
# actually retried. It deletes its queue file on success alone, so a worker that
# dies leaves its input behind -- but this hook is the only writer, and a later
# session writes a NEW file. Without a drain those artifacts sit forever behind
# an advanced watermark, and the queue would be a place data goes to be lost
# rather than the durable handoff this design claims.
@test "a later session spawns a worker for a window left behind" {
	# A queue file from a previous session whose worker never finished. Shaped
	# by the real writer, so the worker's restore block accepts it.
	mkdir -p "$QUEUE_DIR"
	local orphan="${QUEUE_DIR}/01ORPHANEDWINDOW000000000.json"
	jq -n --arg cwd "$PROJECT_REPO" --arg pk "$PROJECT_KEY" \
		'{ cwd: $cwd, session_id: "sess-previous", project_key: $pk,
		   artifacts: [], artifact_count_in_window: 1,
		   candidates_dropped: 0, queued_at_ms: 1789000000000 }' > "$orphan"

	# A session with nothing of its own to queue must still pick it up.
	local seen="${BATS_TEST_TMPDIR}/seen-queues"
	: > "$seen"
	cat > "$SENTINEL_WORKER" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "${seen}"
STUBEOF
	chmod +x "$SENTINEL_WORKER"

	_seed_survivor
	run _run_hook
	[ "$status" -eq 0 ] || return 1
	grep -q "01ORPHANEDWINDOW000000000" "$seen"
}

@test "the classifier timeout is configurable and clears real call latency" {
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-classifier.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	librarian_config_load "$PROJECT_REPO"
	local configured
	configured=$(librarian_config_get '.librarian.classifier.timeout_seconds')
	[ -n "$configured" ] || return 1
	[ "$configured" != "null" ] || return 1
	# Measured: the answer landed at +39s and the process exited at +46s. A
	# ceiling at or below that is the bug -- it killed every call before its
	# answer arrived and made the classifier look like it returned nothing.
	[ "$configured" -gt 46 ]
}

# ONL-118. The worker's EXIT trap is the only thing that releases its queue
# lock, and three libs it calls used to replace that trap with their own
# prompt-file cleanup and then clear it with `trap - EXIT`. The worker happens
# to call each of them through $(...), whose subshell keeps the change to
# itself, so the release survived -- but only by accident of call form. Called
# directly, any of them left the caller with no EXIT trap at all.
@test "no model-calling lib disarms its caller's EXIT trap" {
	local fn
	for fn in librarian_classifier_call librarian_lesson_call librarian_lesson_auto_justify; do
		run bash -c '
			source "$1/scripts/lib/librarian-config.sh"
			source "$1/scripts/lib/librarian-classifier.sh"
			source "$1/scripts/lib/librarian-lesson-transform.sh"
			source "$1/scripts/lib/librarian-lesson-auto.sh"
			librarian_config_load "$2" >/dev/null 2>&1
			trap "echo caller-cleanup" EXIT
			"$3" "{\"claim\":\"x\",\"evidence\":{},\"applies_to\":{\"stack\":[]}}" >/dev/null 2>&1
			trap -p EXIT
		' _ "$PLUGIN_ROOT" "$PROJECT_REPO" "$fn"
		[[ "$output" == *"caller-cleanup"* ]] || { echo "$fn disarmed the trap: $output"; return 1; }
	done
}

@test "the worker releases its queue lock when killed during a model call" {
	_seed_survivor
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1

	# A call still in flight when the worker dies, which is when a lib's own
	# cleanup would be installed if it could reach the worker's trap. The stub
	# says when it started.
	local started="${BATS_TEST_TMPDIR}/call-started"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null
touch "${started}"
sleep 5
STUB
	chmod +x "${STUB_BIN}/claude"

	bash "$WORKER" "$queued" >/dev/null 2>&1 3>&- &
	local pid=$! i
	for i in $(seq 1 100); do
		[ -f "$started" ] && break
		sleep 0.1
	done
	[ -f "$started" ] || return 1
	kill -TERM "$pid"
	wait "$pid" 2>/dev/null || true

	[ ! -d "${queued}.lock" ] || return 1
	# The input stays for the retry the lock release makes possible.
	[ -f "$queued" ]
}

# SIGKILL runs no trap, so no amount of trap hygiene releases the lock then.
# The lock records its owner, and a lock whose owner is gone is reclaimed.
@test "a lock left by a worker that no longer exists is reclaimed" {
	_seed_survivor
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1

	bash -c 'exit 0' &
	local dead=$!
	wait "$dead"
	mkdir "${queued}.lock"
	printf '%s\n' "$dead" > "${queued}.lock/pid"

	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1
	[ "$(wc -l < "$CLAUDE_CALL_LOG" | tr -d ' ')" -ge 1 ] || return 1
	[ ! -f "$queued" ] || return 1
	[ ! -d "${queued}.lock" ]
}

@test "a lock whose recorded owner is still running is honored" {
	_seed_survivor
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1

	mkdir "${queued}.lock"
	printf '%s\n' "$$" > "${queued}.lock/pid"

	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1
	[ "$(wc -l < "$CLAUDE_CALL_LOG" | tr -d ' ')" -eq 0 ] || return 1
	[ -f "$queued" ]
}

# A lock with no owner recorded is either one being created this instant or one
# stranded before locks recorded owners. Age tells them apart: no worker holds
# a lock for a day.
@test "an ownerless lock older than a day is reclaimed" {
	_seed_survivor
	run _run_hook
	local queued
	queued=$(find "$QUEUE_DIR" -name '*.json' -type f | head -1)
	[ -n "$queued" ] || return 1

	mkdir "${queued}.lock"
	touch -t 202001010000 "${queued}.lock"

	run bash "$WORKER" "$queued"
	[ "$status" -eq 0 ] || return 1
	[ "$(wc -l < "$CLAUDE_CALL_LOG" | tr -d ' ')" -ge 1 ] || return 1
	[ ! -f "$queued" ]
}
