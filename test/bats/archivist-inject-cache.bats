#!/usr/bin/env bats

# The inject cache's own contract, called directly rather than through
# archivist-inject (ONL-260, ONL-114).
#
# archivist-inject.bats and archivist-inject-cache-warm.bats drive these through
# the hook and the writers. What they cannot see is the part of the contract the
# hook never exercises on its own: the key moving when a kind directory appears,
# a build on a store it cannot write to, and a warm with nothing to warm.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-config.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-inject-cache.sh"
	archivist_config_load ""

	KEY="abcdef123456"
	PROJECT_DIR=$(archivist_project_dir "$KEY")
	mkdir -p "$PROJECT_DIR"
}

teardown() {
	# A test that removes write permission must give it back, or bats cannot
	# clean the tree up.
	chmod -R u+w "$PROJECT_DIR" 2>/dev/null || true
}

_write_decision() {
	local id="$1" summary="$2" ts
	ts=$(relative_iso_days_ago 1)
	archivist_storage_write_artifact "$KEY" "decisions" "$id" "$(jq -n \
		--arg id "$id" --arg key "$KEY" --arg ts "$ts" --arg summary "$summary" \
		'{id: $id, kind: "decision", project_key: $key, source: "local",
		  created_at: $ts, updated_at: $ts, summary: $summary, detail: "why", files: []}')" >/dev/null
}

@test "prepare keys the cache on which kind directories exist" {
	archivist_inject_cache_prepare "$KEY"
	local before="$_AIC_CACHE_KEY"
	[[ "$before" == *"|0000" ]] || return 1

	mkdir -p "${PROJECT_DIR}/decisions"
	archivist_inject_cache_prepare "$KEY"
	# An old-mtime directory appearing must change the key, or a cache built
	# before it existed would pass as fresh.
	[[ "$_AIC_CACHE_KEY" == *"|1000" ]] || return 1
	[ "$_AIC_CACHE_KEY" != "$before" ]
}

@test "prepare keys the cache on the injection budgets" {
	archivist_inject_cache_prepare "$KEY"
	[[ "$_AIC_CACHE_KEY" == *"|8|2400|"* ]] || return 1
	[ "$_AIC_CACHE_FILE" = "${PROJECT_DIR}/.inject-cache" ]
}

@test "read misses when there is no cache yet" {
	archivist_inject_cache_prepare "$KEY"
	run archivist_inject_cache_read
	[ "$status" -eq 1 ]
}

# A build stamps its cache with the moment its read began, and bash 3.2's -nt
# compares whole seconds, so there only a build in a later second than the last
# write can hit. bash 4+ compares sub-seconds and would hit sooner; waiting out
# the second gives the same answer on both.
_next_second() {
	local started
	started=$(date +%s)
	while [[ "$(date +%s)" == "$started" ]]; do sleep 0.1; done
}

@test "a build answers and leaves a cache that read gives back unchanged" {
	_write_decision "01JTEST0000000000000000001" "keep the watermark per commit"
	_write_decision "01JTEST0000000000000000002" "detach the miner from SessionEnd"
	_next_second
	archivist_inject_cache_prepare "$KEY"

	archivist_inject_cache_build "$KEY" || return 1
	local n="$ARCHIVIST_INJECT_N" total="$ARCHIVIST_INJECT_TOTAL" body="$ARCHIVIST_INJECT_BODY"
	[ "$n" = "2" ] || return 1
	[ "$total" = "2" ] || return 1
	[[ "$body" == *"keep the watermark per commit"* ]] || return 1
	[ -f "${PROJECT_DIR}/.inject-cache" ] || return 1

	ARCHIVIST_INJECT_N="" ARCHIVIST_INJECT_TOTAL="" ARCHIVIST_INJECT_BODY=""
	archivist_inject_cache_read || return 1
	[ "$ARCHIVIST_INJECT_N" = "$n" ] || return 1
	[ "$ARCHIVIST_INJECT_TOTAL" = "$total" ] || return 1
	[ "$ARCHIVIST_INJECT_BODY" = "$body" ]
}

@test "an artifact written while a build renders is not hidden behind its cache" {
	_write_decision "01JTEST0000000000000000001" "keep the watermark per commit"
	_next_second
	archivist_inject_cache_prepare "$KEY"

	# Lands a write after the render has read the store but before the cache is
	# written, each in a second of its own. The cache must carry the time the
	# read began, which is older than that write, so the next read misses and
	# renders it. Stamped when it is written instead, the cache would be newer
	# than the write and answer without it.
	eval "_orig_load_ranked() $(declare -f archivist_storage_load_ranked | tail -n +2)"
	archivist_storage_load_ranked() {
		local out rc=0
		out=$(_orig_load_ranked "$@") || rc=$?
		_next_second
		_write_decision "01JTEST0000000000000000009" "written mid-build"
		_next_second
		printf '%s' "$out"
		return "$rc"
	}

	archivist_inject_cache_build "$KEY" || return 1
	[ "$ARCHIVIST_INJECT_N" = "1" ] || return 1
	[ -f "${PROJECT_DIR}/.inject-cache" ] || return 1
	run archivist_inject_cache_read
	[ "$status" -eq 1 ]
}

@test "a build leaves no stamp or temp file beside the cache" {
	_write_decision "01JTEST0000000000000000001" "keep the watermark per commit"
	archivist_inject_cache_prepare "$KEY"
	archivist_inject_cache_build "$KEY" || return 1
	[ -z "$(find "$PROJECT_DIR" -maxdepth 1 -name '.inject-cache.*')" ]
}

@test "a build on a store it cannot write to still answers, and caches nothing" {
	_write_decision "01JTEST0000000000000000001" "keep the watermark per commit"
	archivist_inject_cache_prepare "$KEY"
	chmod u-w "$PROJECT_DIR"
	# Root writes to a read-only directory anyway, which would make this vacuous.
	if : >"${PROJECT_DIR}/.probe" 2>/dev/null; then
		rm -f "${PROJECT_DIR}/.probe"
		skip "running as a user who can write to a read-only directory"
	fi

	archivist_inject_cache_build "$KEY" || return 1
	[ "$ARCHIVIST_INJECT_N" = "1" ] || return 1
	[ ! -e "${PROJECT_DIR}/.inject-cache" ]
}

@test "a build reports failure, and clears the answer, when the render is unusable" {
	archivist_inject_cache_prepare "$KEY"
	ARCHIVIST_INJECT_N="stale" ARCHIVIST_INJECT_TOTAL="stale" ARCHIVIST_INJECT_BODY="stale"
	# A non-numeric budget is what --argjson rejects, so the render returns nothing.
	_AIC_MAX_ITEMS="not-a-number"

	run archivist_inject_cache_build "$KEY"
	[ "$status" -eq 1 ] || return 1
	archivist_inject_cache_build "$KEY" || true
	[ -z "$ARCHIVIST_INJECT_N" ] || return 1
	[ ! -e "${PROJECT_DIR}/.inject-cache" ] || return 1
	[ -z "$(find "$PROJECT_DIR" -maxdepth 1 -name '.inject-cache.*')" ]
}

@test "warm with no project key does nothing" {
	run archivist_inject_cache_warm ""
	[ "$status" -eq 0 ] || return 1
	[ ! -e "${PROJECT_DIR}/.inject-cache" ]
}

@test "warm for a project with no store does nothing, and does not wait out the second" {
	local absent="0123456789ab" shim="${BATS_TEST_TMPDIR}/sleepshim"
	# The wait is a loop of `sleep 0.1`, so a sleep that records its calls shows
	# whether warm reached it. A wall-clock bound could not: the wait is under a
	# second, and so is a slow runner's noise.
	mkdir -p "$shim"
	printf '#!/usr/bin/env bash\nprintf x >>"%s/slept"\n' "$BATS_TEST_TMPDIR" >"${shim}/sleep"
	chmod +x "${shim}/sleep"

	PATH="${shim}:${PATH}" run archivist_inject_cache_warm "$absent" ""
	[ "$status" -eq 0 ] || return 1
	[ ! -d "$(archivist_project_dir "$absent")" ] || return 1
	[ ! -e "${BATS_TEST_TMPDIR}/slept" ]
}

@test "warm leaves a cache strictly newer than the write it follows" {
	_write_decision "01JTEST0000000000000000001" "keep the watermark per commit"
	archivist_inject_cache_warm "$KEY" "" || return 1
	[ -f "${PROJECT_DIR}/.inject-cache" ] || return 1
	[ "${PROJECT_DIR}/.inject-cache" -nt "${PROJECT_DIR}/decisions" ] || return 1

	# Which is what lets the next SessionStart answer from it.
	archivist_inject_cache_prepare "$KEY"
	archivist_inject_cache_read || return 1
	[ "$ARCHIVIST_INJECT_N" = "1" ]
}
