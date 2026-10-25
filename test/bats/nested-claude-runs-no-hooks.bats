#!/usr/bin/env bats
#
# Every `claude -p` a plugin starts must run with hooks disabled (ONL-195).
#
# `claude -p` starts a full Claude Code session, and every installed plugin's
# hooks fire inside it. Each plugin's *_NESTED guard only stops that plugin
# re-entering itself, so a librarian call also ran cartographer, counsel and
# assayer, which made model calls of their own, up to three levels deep. In
# ONL-115's measured run those nested hook sessions were 59-66% of the spend,
# and 226 of them in one week showed up as sessions in their own right.
#
# `--settings '{"disableAllHooks":true}'` stops all of it: a measured session
# with the flag wrote no events and no hook-health records, against 46 and 22
# without it, and `--agent` dispatch still resolves plugin agents.
#
# This guard is textual on purpose. The flag has to be on the same line that
# starts the invocation or builds its `-p` argument array, so a new call site
# that forgets it fails here instead of in somebody's bill.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
}

# Prints file:line for every line under plugins/*/scripts that starts a
# `claude -p` invocation or a `-p` argument array. Comments, and messages that
# only mention `claude -p`, are excluded.
_nested_claude_sites() {
	grep -rnE --include='*.sh' \
		'(\bclaude -p\b|=\( *-p\b)' \
		"${REPO_ROOT}"/plugins/*/scripts \
		| grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|printf |echo )'
}

@test "the guard finds the call sites it is meant to cover" {
	# A guard that matches nothing passes vacuously. Every plugin that shells
	# out to claude today has to show up.
	sites=$(_nested_claude_sites)
	for plugin in archivist assayer cartographer compass counsel librarian scribe tribunal; do
		printf '%s\n' "$sites" | grep -q "/plugins/${plugin}/" || {
			printf 'no claude -p call site found in %s\n' "$plugin" >&2
			return 1
		}
	done
}

@test "every claude -p a plugin starts disables hooks" {
	missing=$(_nested_claude_sites | grep -v '"disableAllHooks":true' || true)
	if [[ -n "$missing" ]]; then
		printf 'claude -p without --settings {"disableAllHooks":true}:\n%s\n' "$missing" >&2
		return 1
	fi
}
