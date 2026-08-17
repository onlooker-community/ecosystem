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
	printf '# Root\nThe alpha plugin does things.\n' > "${FIXTURE_REPO}/CLAUDE.md"
	printf '# Sub\n' > "${FIXTURE_REPO}/sub/CLAUDE.md"

	export CARTOGRAPHER_DIR="${BATS_TEST_TMPDIR}/cartographer"
	mkdir -p "$CARTOGRAPHER_DIR"
	AUDIT_LOG="${CARTOGRAPHER_DIR}/audit.log"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '[]'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
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

@test "the run record captures the trigger" {
	CARTOGRAPHER_TRIGGER="session_start_first_run" _run_audit
	run bash -c "cat '${CARTOGRAPHER_DIR}/runs/'*.json | jq -r '.trigger'"
	[ "$output" = "session_start_first_run" ]
}
