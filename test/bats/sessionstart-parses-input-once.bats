#!/usr/bin/env bats

# Every SessionStart hook parses its stdin payload once: in hook_health_context,
# which hands cwd, session_id and source back. Every plugin's SessionStart hooks
# start at the same moment, so each process one spawns costs ~1.7x what it does
# alone, and a hook that parsed the payload again for its own fields paid one
# or two more jq starts for values it already had (ONL-292).
#
# Each hook runs for real, against a jq shim that counts the calls whose input
# is that hook's own payload.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git

	# No trailing newline: hooks read the payload with $(cat) and pass it on with
	# printf '%s', so that is the byte string a parse of it receives.
	PAYLOAD_FILE="${BATS_TEST_TMPDIR}/payload.json"
	printf '%s' "$(jq -cn --arg cwd "$PROJECT_REPO" \
		'{session_id: "sess-once", cwd: $cwd, hook_event_name: "SessionStart", source: "startup"}')" \
		>"$PAYLOAD_FILE"
	PARSE_LOG="${BATS_TEST_TMPDIR}/payload-parses"
	: >"$PARSE_LOG"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	local real_jq
	real_jq=$(command -v jq)
	# Reads stdin only when jq would: not under -n, not when a file is named,
	# and not from a terminal. A shim that read it anyway would eat the payload
	# before the hook's own $(cat), and count nothing for a hook that parses it
	# three times.
	cat >"${STUB_BIN}/jq" <<STUB
#!/usr/bin/env bash
no_stdin=0
for a in "\$@"; do
	[[ "\$a" == --null-input || "\$a" =~ ^-[a-zA-Z]*n[a-zA-Z]*\$ || -f "\$a" ]] && no_stdin=1
done
if (( no_stdin )) || [[ -t 0 ]]; then
	exec "$real_jq" "\$@"
fi
in=\$(mktemp "${BATS_TEST_TMPDIR}/jq-in.XXXXXX")
cat >"\$in"
cmp -s "\$in" "$PAYLOAD_FILE" && printf 'parse\n' >>"$PARSE_LOG"
"$real_jq" "\$@" <"\$in"
rc=\$?
rm -f "\$in"
exit \$rc
STUB
	chmod +x "${STUB_BIN}/jq"
	# Nothing here should reach a model.
	printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_BIN}/claude"
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

# The hook as hooks.json runs it: its plugin as CLAUDE_PLUGIN_ROOT, the payload
# on stdin.
_parses_of() {
	local root="$1" hook="$2"
	CLAUDE_PLUGIN_ROOT="$root" bash "${root}/${hook}" <"$PAYLOAD_FILE" >/dev/null 2>&1 || true
	grep -c . "$PARSE_LOG" || true
}

@test "the shim counts a parse of the payload" {
	jq -r '.cwd' <"$PAYLOAD_FILE" >/dev/null
	[ "$(grep -c . "$PARSE_LOG")" -eq 1 ]
}

@test "archivist-inject parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/archivist" scripts/hooks/archivist-inject.sh)" -eq 1 ]
}

@test "bursar-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/bursar" scripts/hooks/bursar-session-start.sh)" -eq 1 ]
}

@test "cartographer-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/cartographer" scripts/hooks/cartographer-session-start.sh)" -eq 1 ]
}

@test "compass-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/compass" scripts/hooks/compass-session-start.sh)" -eq 1 ]
}

@test "counsel-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/counsel" scripts/hooks/counsel-session-start.sh)" -eq 1 ]
}

@test "curator-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/curator" scripts/hooks/curator-session-start.sh)" -eq 1 ]
}

@test "governor-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/governor" scripts/hooks/governor-session-start.sh)" -eq 1 ]
}

@test "librarian-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/librarian" scripts/hooks/librarian-session-start.sh)" -eq 1 ]
}

@test "scribe-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/scribe" scripts/hooks/scribe-session-start.sh)" -eq 1 ]
}

@test "warden-session-start parses its payload once" {
	[ "$(_parses_of "${REPO_ROOT}/plugins/warden" scripts/hooks/warden-session-start.sh)" -eq 1 ]
}

@test "plugin-currency-surfacer parses its payload once" {
	[ "$(_parses_of "$REPO_ROOT" scripts/hooks/plugin-currency-surfacer.sh)" -eq 1 ]
}
