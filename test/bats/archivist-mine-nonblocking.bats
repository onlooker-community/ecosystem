#!/usr/bin/env bats
#
# archivist's SessionEnd miner must not hold session shutdown.
#
# ONL-293. The hook ran its commit loop inline, inside the 1500ms the CLI gives
# the whole SessionEnd batch. After a session that spanned 18 merged pull
# requests it was killed at 1786ms, and the CLI printed "Hook cancelled" as the
# user exited. The loop now lives in archivist-mine-worker.sh and the hook only
# launches it. These pin that the launch stays a launch, that an up-to-date
# watermark launches nothing, and that two workers cannot overlap.

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_DIR="${BATS_TEST_TMPDIR}/onlooker"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/archivist-mine.sh"
	WORKER="${PLUGIN_ROOT}/scripts/lib/archivist-mine-worker.sh"

	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name T
	printf 'x\n' > "$REPO/a.txt"
	git -C "$REPO" add .
	git -C "$REPO" commit -q -m "fix(thing): stop dropping events

Because the old path dropped them on every restart."
	KEY=$(onlooker_project_key "$REPO")

	STARTED_MARKER="${BATS_TEST_TMPDIR}/worker_started"
	FINISHED_MARKER="${BATS_TEST_TMPDIR}/worker_finished"
}

# A detached worker outlives the hook, and so the test. Left alone its writes
# race bats removing the tree underneath it.
teardown() {
	local waited=0
	while [[ "$waited" -lt 15 ]]; do
		[[ -f "$FINISHED_MARKER" ]] && break
		[[ ! -f "$STARTED_MARKER" ]] && break
		sleep 1
		waited=$((waited + 1))
	done
	await_unlocked 10 || true
}

run_hook() {
	printf '{"cwd":"%s","session_id":"s1"}' "$REPO" | "$HOOK"
}

mined_path() {
	printf '%s/mined.json' "$(archivist_project_dir "$KEY")"
}

# The real worker deletes its lock last, so its absence after the watermark
# appears is the run being over.
await_unlocked() {
	local timeout_s="${1:-30}" i
	for ((i = 0; i < timeout_s * 10; i++)); do
		[[ ! -d "$(archivist_project_dir "$KEY")/mine.lock" ]] && return 0
		sleep 0.1
	done
	return 1
}

await_watermark() {
	local timeout_s="${1:-30}" i
	for ((i = 0; i < timeout_s * 10; i++)); do
		[[ -f "$(mined_path)" ]] && return 0
		sleep 0.1
	done
	echo "await_watermark: no mined.json after ${timeout_s}s" >&2
	return 1
}

install_slow_worker() {
	local sleep_s="${1:-5}"
	export ARCHIVIST_MINE_WORKER="${BATS_TEST_TMPDIR}/slow-worker.sh"
	cat > "$ARCHIVIST_MINE_WORKER" <<STUB
#!/usr/bin/env bash
printf 'x' > "${STARTED_MARKER}"
sleep ${sleep_s}
printf 'x' > "${FINISHED_MARKER}"
STUB
}

@test "the hook returns without waiting on the worker" {
	install_slow_worker 5

	local start end
	start=$(date +%s)
	run run_hook
	end=$(date +%s)

	[ "$status" -eq 0 ] || return 1
	# Well under the stub's 5s: anything that waits on the child is back to
	# racing the 1500ms ceiling.
	[ $(( end - start )) -lt 3 ] || return 1
	local i
	for ((i = 0; i < 50; i++)); do
		[[ -f "$STARTED_MARKER" ]] && break
		sleep 0.1
	done
	[ -f "$STARTED_MARKER" ] || return 1
	[ ! -f "$FINISHED_MARKER" ]
}

@test "the detached worker mines what the hook launched it for" {
	# The production call form, end to end: no foreground seam.
	run run_hook
	[ "$status" -eq 0 ] || return 1

	await_watermark || return 1
	await_unlocked || return 1
	[ "$(jq -r '.last_sha' "$(mined_path)")" = "$(git -C "$REPO" rev-parse HEAD)" ] || return 1
	run grep -l "stop dropping events" "$(archivist_project_dir "$KEY")/decisions"/*.json
	[ "$status" -eq 0 ]
}

@test "an up-to-date watermark launches no worker" {
	# Every session after the first takes this path; it must not spawn.
	mkdir -p "$(archivist_project_dir "$KEY")"
	printf '{"last_sha":"%s","at":"x"}\n' "$(git -C "$REPO" rev-parse HEAD)" > "$(mined_path)"
	install_slow_worker 0

	run run_hook

	[ "$status" -eq 0 ] || return 1
	sleep 0.5
	[ ! -f "$STARTED_MARKER" ]
}

@test "a worker declines while another live worker holds the lock" {
	local lock
	lock="$(archivist_project_dir "$KEY")/mine.lock"
	mkdir -p "$lock"
	# This test's own shell: alive for as long as the assertion needs it.
	printf '%s\n' "$$" > "${lock}/pid"

	run bash "$WORKER" "$KEY" "$REPO" "$REPO"

	[ "$status" -eq 0 ] || return 1
	[ ! -f "$(mined_path)" ] || return 1
	# Declining leaves the owner's lock alone.
	[ "$(cat "${lock}/pid")" = "$$" ] || return 1
	rm -rf "$lock"
}

@test "a lock whose owner is gone is reclaimed" {
	local lock dead
	lock="$(archivist_project_dir "$KEY")/mine.lock"
	mkdir -p "$lock"
	bash -c 'exit 0' &
	dead=$!
	wait "$dead"
	printf '%s\n' "$dead" > "${lock}/pid"

	run bash "$WORKER" "$KEY" "$REPO" "$REPO"

	[ "$status" -eq 0 ] || return 1
	[ "$(jq -r '.last_sha' "$(mined_path)")" = "$(git -C "$REPO" rev-parse HEAD)" ] || return 1
	[ ! -d "$lock" ]
}

@test "the hook's health record carries the session id" {
	# The miner's records were all session_id null: the hook never called
	# hook_health_context, so a cancelled run could only be matched by pid.
	install_slow_worker 0

	run run_hook
	[ "$status" -eq 0 ] || return 1

	run jq -rs '[.[] | select(.hook == "archivist-mine" and .status == "success")] | last | .session_id' \
		"${ONLOOKER_DIR}/logs/hook-health.jsonl"
	[ "$output" = "s1" ]
}
