#!/usr/bin/env bats

# What the orchestrator records when an LLM analyzer fails.
#
# Nothing asserted on the run JSON before this file, which is why two reporting
# defects rode along with ecosystem-449.63: "relate" was appended to
# PHASES_FAILED twice (once by run_relate, once by its caller's `||` clause), and
# a failed stale_ref or scope_collision analyzer was downgraded to an empty
# result with no record anywhere — the phase still reported COMPLETED, so "the
# model found nothing" and "the call never happened" were indistinguishable.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	AUDIT="${PLUGIN_ROOT}/scripts/run-audit.sh"

	FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${FIXTURE_REPO}/sub" "${FIXTURE_REPO}/.claude"
	printf '# Root\nAlways read scripts/lib/config-loader.sh first.\nNever use src/legacy/gone.ts.\n' \
		> "${FIXTURE_REPO}/CLAUDE.md"
	printf '# Sub\nSee plugins/tribunal/README.md for details.\n' > "${FIXTURE_REPO}/sub/CLAUDE.md"
	mkdir -p "$CLAUDE_HOME"
	printf '# Global\nAlways prefer tabs.\n' > "${CLAUDE_HOME}/CLAUDE.md"

	export CARTOGRAPHER_DIR="${BATS_TEST_TMPDIR}/cartographer"
	mkdir -p "$CARTOGRAPHER_DIR"
	AUDIT_LOG="${CARTOGRAPHER_DIR}/audit.log"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	# Every model call fails, the way they all did under --max-tokens.
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf "error: unknown option '--max-tokens'\n" >&2
exit 1
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_run_audit() {
	CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT"
}

_run_json() {
	cat "${CARTOGRAPHER_DIR}"/runs/audit-*.json
}

@test "a failed relate phase is recorded once, not twice" {
	_run_audit
	run bash -c '_j() { cat "$1"/runs/audit-*.json; }; _j "$0" | jq -c "[.phases_failed[] | select(. == \"relate\")]"' "$CARTOGRAPHER_DIR"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = '["relate"]' ]
}

@test "a failed stale_ref analyzer is recorded in the audit log" {
	_run_audit
	grep -q 'stale_ref' "$AUDIT_LOG"
}

@test "a failed scope_collision analyzer is recorded in the audit log" {
	_run_audit
	grep -q 'scope_collision' "$AUDIT_LOG"
}

@test "the CLI's own error reaches the audit log" {
	_run_audit
	grep -q "unknown option" "$AUDIT_LOG"
}

@test "a partial audit does not advance last_audit_at" {
	_run_audit
	[ ! -f "${CARTOGRAPHER_DIR}/last_audit_at" ]
}

# The fixture above fails EVERY model call, so relate fails too and the
# watermark is held for a reason that has nothing to do with synthesize. These
# isolate a single analyzer failure -- the state the orchestrator used to report
# as a clean audit, stamping last_audit_at and closing the 24h gate behind it.
_stub_claude_failing() {
	local marker="$1"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
prompt=\$(cat)
if [[ "\$prompt" == *"${marker}"* ]]; then
	printf 'error: analyzer failed\n' >&2
	exit 1
fi
printf '[]'
STUB
	chmod +x "${STUB_BIN}/claude"
}

# Distinctive to the stale_ref prompt. relate and scope_collision do not carry
# it, so both succeed with an empty result and only stale_ref dies.
STALE_REF_MARKER="could not be resolved on the filesystem"

@test "a failed stale_ref analyzer is named in phases_failed" {
	_stub_claude_failing "$STALE_REF_MARKER"
	_run_audit
	# Empty-string entries are an artifact of "${PHASES_FAILED[@]:-}" rendering
	# an empty array; filtering them also asserts stale_ref is the ONLY failure.
	run bash -c '_j() { cat "$1"/runs/audit-*.json; }; _j "$0" | jq -c "[.phases_failed[] | select(. != \"\")]"' "$CARTOGRAPHER_DIR"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = '["stale_ref"]' ]
}

@test "a stale_ref-only failure holds last_audit_at" {
	_stub_claude_failing "$STALE_REF_MARKER"
	_run_audit
	[ ! -f "${CARTOGRAPHER_DIR}/last_audit_at" ]
}

# Control. Without this, the two tests above would also pass if the fixture
# could never write the watermark at all, and would prove nothing.
@test "an audit with every analyzer succeeding does advance last_audit_at" {
	_stub_claude_failing "a marker that appears in no prompt"
	_run_audit
	[ -f "${CARTOGRAPHER_DIR}/last_audit_at" ]
}
