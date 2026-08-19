#!/usr/bin/env bats

# End-to-end coverage of the audit orchestrator.
#
# Nothing drove run-audit.sh before this file, and that absence is why two
# separate defects lived in it undetected: a crash on macOS bash 3.2 whenever
# the exclude list was empty (ecosystem-3xf), and config never being loaded at
# all, so every top-level setting was silently ignored (ecosystem-88v). Both are
# invisible to the unit tests, which exercise the libraries the orchestrator
# calls rather than the orchestrator itself.
#
# The audit shells out to `claude` for its three analysis phases. The stub below
# returns an empty findings array, which is enough: what is under test here is
# whether the orchestrator resolves and propagates its own configuration, not
# what a model says about the corpus.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	AUDIT="${PLUGIN_ROOT}/scripts/run-audit.sh"

	FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${FIXTURE_REPO}/sub" "${FIXTURE_REPO}/.claude"
	# Path-like tokens and a global counterpart so all three LLM analyzers have
	# something to chew on. Without them stale_ref and scope_collision
	# short-circuit before calling the model, and the call counts below could
	# not tell "skipped by the filter" apart from "had nothing to do".
	printf '# Root\nAlways read scripts/lib/config-loader.sh first.\nNever use src/legacy/gone.ts.\n' \
		> "${FIXTURE_REPO}/CLAUDE.md"
	printf '# Sub\nSee plugins/tribunal/README.md for details.\n' > "${FIXTURE_REPO}/sub/CLAUDE.md"
	mkdir -p "${CLAUDE_HOME}"
	printf '# Global\nAlways prefer tabs.\n' > "${CLAUDE_HOME}/CLAUDE.md"

	export CARTOGRAPHER_DIR="${BATS_TEST_TMPDIR}/cartographer"
	mkdir -p "$CARTOGRAPHER_DIR"
	AUDIT_LOG="${CARTOGRAPHER_DIR}/audit.log"

	# The stub records each invocation so tests can assert on how many model calls
	# an audit actually made — the only honest evidence that a filter skipped an
	# analyzer rather than merely discarding its output.
	export CLAUDE_CALL_LOG="${BATS_TEST_TMPDIR}/claude-calls"
	: > "$CLAUDE_CALL_LOG"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo call >> "$CLAUDE_CALL_LOG"
printf '[]'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

EVENTS_LOG_PATH() { printf '%s' "${ONLOOKER_DIR}/logs/onlooker-events.jsonl"; }

# Seed a finding from an earlier run. last_seen_at sits far in the past, so the
# current audit — whose stub returns no findings — will not observe it.
_seed_stored_finding() {
	local hash="$1" last_seen="${2:-1000}"
	mkdir -p "${CARTOGRAPHER_DIR}/findings"
	jq -n --arg h "$hash" --argjson ls "$last_seen" \
		'{finding_hash:$h, type:"undocumented_entity", severity:"warning",
		  file_a:"CLAUDE.md", file_b:null, description:"d", suggested_fix:"f",
		  first_seen_at:500, last_seen_at:$ls, resolved:false}' \
		> "${CARTOGRAPHER_DIR}/findings/${hash}.json"
}

_resolved_event_count() {
	local n
	n=$(grep -c '"event_type":"cartographer.issue.resolved"' "$(EVENTS_LOG_PATH)" 2>/dev/null) || n=0
	printf '%s' "$n"
}

_last_audit_complete() {
	grep '"event_type":"cartographer.audit.complete"' "$(EVENTS_LOG_PATH)" 2>/dev/null | tail -n 1
}

_llm_calls() {
	wc -l < "$CLAUDE_CALL_LOG" | tr -d ' '
}

_settings() {
	printf '%s' "$1" > "${FIXTURE_REPO}/.claude/settings.json"
}

_run_audit() {
	CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT"
}

@test "a full audit completes and records the run" {
	run _run_audit
	[ "$status" -eq 0 ] || return 1
	grep -q 'completed successfully' "$AUDIT_LOG" || return 1
	[ -f "${CARTOGRAPHER_DIR}/last_audit_at" ]
}

# ── Config actually reaches the orchestrator ─────────────────────────────────

# exclude_paths is the setting that stings: run_discover hands it straight to
# cartographer_collect_files, so ignoring it means the discovery walk always
# used the shipped defaults no matter what the user configured, quietly breaking
# the replace-not-merge contract in the plugin's own ADR-004.
@test "repo exclude_paths narrows the discovery walk" {
	_settings '{"cartographer": {"exclude_paths": ["sub"]}}'
	_run_audit
	grep -q 'phase=discover files=1' "$AUDIT_LOG"
}

@test "without an exclude override both instruction files are discovered" {
	_run_audit
	grep -q 'phase=discover files=2' "$AUDIT_LOG"
}

# The orchestrator warns when total_timeout_seconds cannot cover three phases.
# The warning only fires if the CONFIGURED phase timeout was read: at the 60s
# default the shipped 600s total is comfortably sufficient and nothing is
# logged, so its presence is proof the accessor saw 999 rather than the default.
@test "phase_timeout_seconds is read from config, not the accessor default" {
	_settings '{"cartographer": {"phase_timeout_seconds": 999}}'
	_run_audit
	grep -q 'total_timeout_seconds=600 is less than 3× phase_timeout_seconds=999' "$AUDIT_LOG"
}

@test "no warning at the shipped defaults" {
	_run_audit
	run grep -c 'is less than 3×' "$AUDIT_LOG"
	[ "$output" = "0" ]
}

@test "user-level settings reach the orchestrator too" {
	mkdir -p "${CLAUDE_HOME}"
	printf '%s' '{"cartographer": {"exclude_paths": ["sub"]}}' \
		> "${CLAUDE_HOME}/settings.json"
	_run_audit
	grep -q 'phase=discover files=1' "$AUDIT_LOG"
}

# ── The log stays readable ───────────────────────────────────────────────────

# run-audit.sh never exported PLUGIN_ROOT, so every analysis sub-shell that
# sourced cartographer-config.sh resolved config-loader.sh against an empty
# prefix and died, appending three lines of noise per phase to audit.log on
# every audit. Nobody read it because the analyzers took their settings as
# parameters and kept working.
@test "the audit log carries no config-loader errors" {
	_run_audit
	run grep -cE 'No such file or directory|command not found' "$AUDIT_LOG"
	[ "$output" = "0" ]
}

@test "the audit log carries no unbound variable errors" {
	_settings '{"cartographer": {"exclude_paths": []}}'
	_run_audit
	run grep -c 'unbound variable' "$AUDIT_LOG"
	[ "$output" = "0" ]
}

# An empty exclude list is a legitimate configuration, and expanding a genuinely
# empty array under `set -u` is an unbound-variable error on bash 3.2 — the
# macOS system bash, and what #!/usr/bin/env bash resolves to there. This is the
# ecosystem-3xf crash, which Linux CI could never have seen.
@test "an empty exclude list does not abort the audit" {
	_settings '{"cartographer": {"exclude_paths": []}}'
	run _run_audit
	[ "$status" -eq 0 ] || return 1
	grep -q 'phase=discover files=2' "$AUDIT_LOG"
}

# ── Targeted audits ──────────────────────────────────────────────────────────

@test "a targeted audit examines only the named file" {
	CARTOGRAPHER_TARGET_FILE="${FIXTURE_REPO}/CLAUDE.md" \
		CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT"
	grep -q 'phase=discover files=1' "$AUDIT_LOG"
}

# last_audit_at gates the session-start interval check. A targeted run covers
# one file, so advancing it would let a single edit suppress the next full audit.
@test "a targeted audit does not advance last_audit_at" {
	CARTOGRAPHER_TARGET_FILE="${FIXTURE_REPO}/CLAUDE.md" \
		CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT"
	[ ! -f "${CARTOGRAPHER_DIR}/last_audit_at" ]
}

# ── --type and --scope ───────────────────────────────────────────────────────
#
# SKILL.md documented both flags while run-audit.sh read neither, so passing
# them silently ran a full audit (ecosystem-9og). These assert on the count of
# model calls, because that is what distinguishes a genuinely skipped analyzer
# from one that ran and had its findings thrown away.

@test "an unfiltered audit calls the model once per LLM analyzer" {
	_run_audit
	[ "$(_llm_calls)" = "3" ]
}

@test "a type filter skips the analyzers that cannot produce it" {
	CARTOGRAPHER_TYPE_FILTER=stale_ref _run_audit
	[ "$(_llm_calls)" = "1" ]
}

# undocumented_entity is a grep, not a model call, so narrowing to it should
# cost nothing at all.
@test "narrowing to undocumented_entity makes no model calls" {
	CARTOGRAPHER_TYPE_FILTER=undocumented_entity _run_audit
	[ "$(_llm_calls)" = "0" ]
}

# contradiction and dead_rule share one pass, so dead_rule must still run it —
# skipping would silently return nothing for a legitimate request.
@test "dead_rule still runs the contradiction analyzer" {
	CARTOGRAPHER_TYPE_FILTER=dead_rule _run_audit
	[ "$(_llm_calls)" = "1" ] || return 1
	grep -q 'phase=relate starting' "$AUDIT_LOG" || return 1
	run grep -c 'phase=relate skipped by type filter' "$AUDIT_LOG"
	[ "$output" = "0" ]
}

@test "a type filter the relate phase cannot serve says so in the log" {
	CARTOGRAPHER_TYPE_FILTER=scope_collision _run_audit
	grep -q 'phase=relate skipped by type filter' "$AUDIT_LOG"
}

# A typo must not read as a clean repo.
@test "an unknown type aborts instead of auditing nothing" {
	run env CARTOGRAPHER_TYPE_FILTER=stale_refs CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT"
	[ "$status" -ne 0 ] || return 1
	grep -q "unknown type filter 'stale_refs'" "$AUDIT_LOG" || return 1
	[ "$(_llm_calls)" = "0" ]
}

@test "the active filters are recorded in the log" {
	CARTOGRAPHER_TYPE_FILTER=stale_ref CARTOGRAPHER_SCOPE_PATH=sub _run_audit
	grep -q 'filter type=stale_ref' "$AUDIT_LOG" || return 1
	grep -q 'filter scope=sub' "$AUDIT_LOG"
}

@test "a scope narrows the corpus without skipping analyzers" {
	CARTOGRAPHER_SCOPE_PATH=sub _run_audit
	grep -q 'phase=discover files=1' "$AUDIT_LOG" || return 1
	[ "$(_llm_calls)" = "3" ]
}

@test "an absolute scope narrows the same way" {
	CARTOGRAPHER_SCOPE_PATH="${FIXTURE_REPO}/sub" _run_audit
	grep -q 'phase=discover files=1' "$AUDIT_LOG"
}

@test "the two filters compose" {
	CARTOGRAPHER_TYPE_FILTER=stale_ref CARTOGRAPHER_SCOPE_PATH=sub _run_audit
	grep -q 'phase=discover files=1' "$AUDIT_LOG" || return 1
	[ "$(_llm_calls)" = "1" ]
}

@test "a scope matching nothing still completes cleanly" {
	CARTOGRAPHER_SCOPE_PATH=does/not/exist run _run_audit
	grep -q 'phase=discover files=0' "$AUDIT_LOG"
}

@test "the run record captures the trigger" {
	CARTOGRAPHER_TRIGGER="session_start_first_run" _run_audit
	run bash -c "cat '${CARTOGRAPHER_DIR}/runs/'*.json | jq -r '.trigger'"
	[ "$output" = "session_start_first_run" ]
}

# A typeless finding must not vanish. The builder refuses it (ecosystem-ci0),
# but refusing is only half the fix: if the orchestrator discards that refusal
# the event is still silently absent, one layer further up. The audit log is
# where an operator would go looking for it.
@test "a finding with no type is reported in the audit log" {
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo call >> "$CLAUDE_CALL_LOG"
printf '[{"severity":"warning","file_a":"CLAUDE.md","excerpt_a":"Always prefer tabs.","description":"typeless"}]'
STUB
	chmod +x "${STUB_BIN}/claude"

	run _run_audit
	[ "$status" -eq 0 ] || return 1
	grep -q 'carries no type' "$AUDIT_LOG"
}


# ── Resolution reaching the bus (ecosystem-w2i) ──────────────────────────────
#
# The resolution loop retired findings on disk but nothing announced it, so a
# consumer reading only the log — counsel, by design — saw every finding ever
# opened and none ever closed.

@test "a full audit announces the findings it retired" {
	_seed_stored_finding gonehash
	_run_audit
	grep '"event_type":"cartographer.issue.resolved"' "$(EVENTS_LOG_PATH)" \
		| jq -e '.payload.finding_hash == "gonehash"' >/dev/null
}

@test "a completed full audit reports how many findings it retired" {
	_seed_stored_finding gonehash
	_run_audit
	_last_audit_complete | jq -e '.payload.resolved_finding_count == 1' >/dev/null
}

# A targeted run sees one file, so nearly every stored finding is "unobserved"
# for reasons unrelated to being fixed. It must neither retire nor announce.
@test "a targeted audit announces no resolutions" {
	_seed_stored_finding gonehash
	CARTOGRAPHER_TARGET_FILE="${FIXTURE_REPO}/CLAUDE.md" \
		CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT"
	[ "$(_resolved_event_count)" = "0" ]
}

# Reporting zero would read as "swept, retired nothing". The field is absent
# instead, because this run never swept.
@test "a targeted audit reports no resolved count at all" {
	_seed_stored_finding gonehash
	CARTOGRAPHER_TARGET_FILE="${FIXTURE_REPO}/CLAUDE.md" \
		CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT"
	_last_audit_complete | jq -e '.payload | has("resolved_finding_count") | not' >/dev/null
}
