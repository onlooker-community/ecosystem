#!/usr/bin/env bats

# The injection cache is warmed by the writers (ONL-260).
#
# archivist-inject answers SessionStart from .inject-cache while it is strictly
# newer than every kind directory. But archivist writes at the two moments just
# before a SessionStart: the mine worker after SessionEnd, the extractor at
# PreCompact. Measured on 0.10.6, every startup and compact inject followed one
# of those writes and rebuilt, at ~540ms p50 against ~65ms for a hit. So each
# writer now leaves a cache built after its own writes, and the start that
# follows answers from it.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	INJECT="${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh"

	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name T
	git -C "$REPO" remote add origin git@github.com:org/archivist-warm-test.git
	printf 'x\n' >"$REPO/a.txt"
	git -C "$REPO" add .
	git -C "$REPO" commit -q -m "fix(thing): stop dropping events

Because the old path dropped them on every restart."
	KEY=$(onlooker_project_key "$REPO")
	PROJECT_DIR=$(archivist_project_dir "$KEY")
	CACHE="${PROJECT_DIR}/.inject-cache"
}

# Writers warm in the background. Left running, they race bats removing the
# tree underneath them.
teardown() {
	await_warmed 5 || true
	await_unlocked 5 || true
}

# A warm is over once the cache exists and no stamp of a build in flight is
# left beside it.
await_warmed() {
	local timeout_s="${1:-10}" i stamps
	for ((i = 0; i < timeout_s * 10; i++)); do
		stamps=$(find "$PROJECT_DIR" -maxdepth 1 -name '.inject-cache.*' 2>/dev/null)
		[[ -f "$CACHE" && -z "$stamps" ]] && return 0
		sleep 0.1
	done
	echo "await_warmed: no settled cache after ${timeout_s}s" >&2
	return 1
}

# The worker deletes its lock last, so its absence is the run being over.
await_unlocked() {
	local timeout_s="${1:-30}" i
	for ((i = 0; i < timeout_s * 10; i++)); do
		[[ ! -d "${PROJECT_DIR}/mine.lock" ]] && return 0
		sleep 0.1
	done
	return 1
}

# Runs inject, logging every jq argument list while still running the real jq.
_inject_logging_jq() {
	local shim="${BATS_TEST_TMPDIR}/argshim" real
	real=$(command -v jq)
	mkdir -p "$shim"
	cat >"${shim}/jq" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_TEST_TMPDIR}/jq-args"
exec "$real" "\$@"
SHIM
	chmod +x "${shim}/jq"
	: >"${BATS_TEST_TMPDIR}/jq-args"
	jq -n --arg cwd "$REPO" --arg src "$1" '{cwd: $cwd, source: $src, session_id: "s"}' \
		| PATH="${shim}:${PATH}" "$INJECT"
}

_inject() {
	jq -n --arg cwd "$REPO" --arg src "$1" '{cwd: $cwd, source: $src, session_id: "s"}' | "$INJECT"
}

_run_mine() {
	printf '{"cwd":"%s","session_id":"s1"}' "$REPO" | "${PLUGIN_ROOT}/scripts/hooks/archivist-mine.sh"
}

_run_extract() {
	local stub="${BATS_TEST_TMPDIR}/bin" transcript="${BATS_TEST_TMPDIR}/transcript.jsonl"
	mkdir -p "$stub"
	cat >"${stub}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"decisions":[{"summary":"a decision worth keeping","detail":"why","files":[]}],"dead_ends":[],"open_questions":[]}'
STUB
	chmod +x "${stub}/claude"
	printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the work"}}' >"$transcript"
	jq -n --arg cwd "$REPO" --arg tp "$transcript" \
		'{cwd: $cwd, session_id: "sess-warm", transcript_path: $tp, trigger: "auto"}' \
		| PATH="${stub}:${PATH}" "${PLUGIN_ROOT}/scripts/hooks/archivist-extract.sh"
}

@test "a start after a mine run answers without reading an artifact" {
	# The production call form: the SessionEnd hook launching its detached worker.
	_run_mine >/dev/null || return 1
	await_unlocked || return 1
	await_warmed || return 1

	run _inject_logging_jq startup
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"stop dropping events"* ]] || return 1
	! grep -q '/decisions/' "${BATS_TEST_TMPDIR}/jq-args"
}

@test "a start after an extract answers without reading an artifact" {
	_run_extract >/dev/null || return 1
	await_warmed || return 1

	run _inject_logging_jq compact
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"a decision worth keeping"* ]] || return 1
	! grep -q '/decisions/' "${BATS_TEST_TMPDIR}/jq-args"
}

@test "a warmed answer is the one a cold render gives" {
	_run_mine >/dev/null || return 1
	await_unlocked || return 1
	await_warmed || return 1

	local warmed cold
	warmed=$(_inject startup)
	rm -f "$CACHE"
	cold=$(_inject startup)
	[ -n "$warmed" ] || return 1
	[ "$warmed" = "$cold" ]
}

@test "a warm answers under the project's own settings" {
	mkdir -p "${REPO}/.claude"
	printf '%s\n' '{"archivist":{"injection":{"include_dead_ends":false}}}' >"${REPO}/.claude/settings.json"
	_run_mine >/dev/null || return 1
	await_unlocked || return 1
	await_warmed || return 1

	run _inject_logging_jq startup
	[[ "$output" == *"stop dropping events"* ]] || return 1
	! grep -q '/decisions/' "${BATS_TEST_TMPDIR}/jq-args"
}
