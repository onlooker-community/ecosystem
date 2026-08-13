#!/usr/bin/env bats

# `run --separate-stderr` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	source "${PLUGIN_ROOT}/scripts/lib/librarian-author-key.sh"
}

@test "the secret lives outside any project directory" {
	# Every other librarian artifact is project-keyed. This one must not be:
	# a per-project secret would give one user a different identity in every
	# repo, silently.
	run librarian_author_secret_path
	[ "$status" -eq 0 ]
	[ "$output" = "${ONLOOKER_DIR}/author/user_secret" ]
	[[ "$output" != *"/librarian/"* ]] || return 1
}

@test "first use creates a secret with 0600 permissions" {
	run librarian_author_secret_ensure
	[ "$status" -eq 0 ]

	local path
	path=$(librarian_author_secret_path)
	[ -f "$path" ]
	# stat's portable-enough form for mode; %A on GNU, %Sp on BSD — use ls.
	local mode
	mode=$(ls -l "$path" | cut -c1-10)
	[ "$mode" = "-rw-------" ]
}

@test "the generated secret is 64 hex characters" {
	# openssl rand -hex 32 requests 32 BYTES and prints 64 characters.
	# Halving this to -hex 16 would halve the entropy and nothing would fail.
	run librarian_author_secret_ensure
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 64 ]
	printf '%s' "$output" | grep -Eq '^[0-9a-f]{64}$' || return 1
}

@test "an existing secret is never regenerated" {
	# Load-bearing: regenerating silently changes the user's identity and
	# orphans every lesson they have written, including retraction.
	librarian_author_secret_ensure >/dev/null
	local path first second
	path=$(librarian_author_secret_path)
	first=$(cat "$path")

	librarian_author_secret_ensure >/dev/null
	second=$(cat "$path")
	[ "$first" = "$second" ]
}

@test "an empty secret is refused, not used" {
	# HMAC("", scope) is IDENTICAL for every user in this state — a corrupt
	# secret would silently collapse everyone onto one shared identity.
	#
	# --separate-stderr: bats' plain `run` merges stdout and stderr into
	# $output, but the interface contract is "empty stdout, reason on
	# stderr" — two distinct streams. Without separating them here, $output
	# could never be "" once the required stderr reason is written, no
	# matter how correct the implementation is.
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	: > "$path"

	run --separate-stderr librarian_author_secret_ensure
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	# Pins the empty-secret guard specifically: an empty secret also trips
	# the short-secret check (0 < 64), so "refused" alone doesn't prove this
	# guard exists — the message must name the case, not just reject it.
	[[ "$stderr" == *"empty"* ]] || return 1
}

@test "a short secret is refused, naming the problem" {
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	printf 'abc123' > "$path"

	run librarian_author_secret_ensure
	[ "$status" -ne 0 ]
	[[ "$output" == *"too short"* ]] || return 1
}

@test "a 64-char non-hex secret is refused, naming the format problem" {
	# Length alone is not content: 64 characters of the wrong shape (here,
	# 64 'z's — not a hex digit) clears the length check but would still
	# derive a garbage-but-deterministic identity from HMAC. This must be
	# distinguishable from both "empty" and "too short" — a user acts on
	# each differently.
	local path secret
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	secret=$(printf 'z%.0s' $(seq 1 64))
	printf '%s' "$secret" > "$path"
	[ "${#secret}" -eq 64 ]

	run librarian_author_secret_ensure
	[ "$status" -ne 0 ]
	[[ "$output" == *"malformed"* ]] || return 1
	[[ "$output" != *"too short"* ]] || return 1
}

@test "a world-readable secret is tightened and warned about" {
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	openssl rand -hex 32 > "$path"
	chmod 0644 "$path"

	run librarian_author_secret_ensure
	[ "$status" -eq 0 ]
	[ "$(ls -l "$path" | cut -c1-10)" = "-rw-------" ]
	[[ "$output" == *"permissions"* ]] || return 1
}

@test "an ACL-only grant is warned about even though the mode string looks fine" {
	# `chmod +a` is macOS-specific; on Linux (CI) this scenario can't be
	# constructed the same way, so this test only runs on Darwin.
	[[ "$(uname)" == "Darwin" ]] || skip "chmod +a is macOS-only; CI runs on Linux"

	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	openssl rand -hex 32 > "$path"
	chmod 0600 "$path"
	chmod +a "$(id -un) allow read" "$path"
	# Confirm the fixture actually carries the ACL before asserting on it —
	# otherwise a chmod +a failure would make this test vacuously pass.
	[ "$(ls -l "$path" | cut -c11)" = "+" ]

	run librarian_author_secret_ensure
	[ "$status" -eq 0 ]
	[[ "$output" == *"ACL"* ]] || return 1
}

@test "the lib never uses RANDOM for the secret" {
	# archivist-ulid.sh uses $RANDOM correctly for a sortable id; it is the
	# nearer example in this repo and the wrong one to copy for a secret.
	#
	# Comment lines are excluded: this pins usage, not mention. The lib's own
	# comment names $RANDOM directly to explain why it is disqualified, and a
	# grep that can't tell code from commentary would force that comment to
	# stop naming the thing it warns against.
	#
	# grep -c returns 0 with exit status 1 when there is no match — assert on
	# $output, not $status.
	run bash -c "grep -v '^[[:space:]]*#' \"${PLUGIN_ROOT}/scripts/lib/librarian-author-key.sh\" | grep -c 'RANDOM'"
	[ "$output" = "0" ]
}

# A fixed secret, so the golden vector below is reproducible.
_fixed_secret() {
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$path"
	chmod 0600 "$path"
}

@test "GOLDEN VECTOR: a fixed secret and visibility produce a fixed key" {
	# THE load-bearing test. Change the domain tag, the truncation width, the
	# hash, or the argument order and this goes red. It is what makes "the
	# derivation is permanent" enforceable rather than aspirational.
	#
	# Regenerate ONLY if the contract's width changes, and say so in the
	# commit — a silent update here defeats the test's whole purpose.
	_fixed_secret
	run librarian_author_key "public"
	[ "$status" -eq 0 ]
	[ "$output" = "11ff8ab7134c834e788ab4a5130f7853" ]
}

@test "GOLDEN VECTOR: org and private are pinned too" {
	# All three, so a change that happens to preserve one scope's output
	# still goes red. Computed independently of the implementation.
	_fixed_secret
	[ "$(librarian_author_key "private")" = "e74674c25190cdf15099604441bb0d4b" ]
	[ "$(librarian_author_key "org")" = "a8cf0203e178702412d37d5f796adbdc" ]
}

@test "the same inputs always produce the same key" {
	# Retraction depends on this: a user must be able to re-derive the key
	# that authored a lesson.
	_fixed_secret
	local a b
	a=$(librarian_author_key "org")
	b=$(librarian_author_key "org")
	[ "$a" = "$b" ]
}

@test "the three visibilities produce three distinct keys" {
	_fixed_secret
	local p o u
	p=$(librarian_author_key "private")
	o=$(librarian_author_key "org")
	u=$(librarian_author_key "public")
	[ "$p" != "$o" ]
	[ "$o" != "$u" ]
	[ "$p" != "$u" ]
}

@test "different secrets produce different keys at the same visibility" {
	# Catches a constant that ignores the secret entirely — which the
	# scope-separation test above would NOT catch.
	_fixed_secret
	local first
	first=$(librarian_author_key "public")

	local path
	path=$(librarian_author_secret_path)
	printf '%s\n' "1111111111111111111111111111111111111111111111111111111111111111" > "$path"
	local second
	second=$(librarian_author_key "public")

	[ "$first" != "$second" ]
}

@test "the key is 32 lowercase hex" {
	_fixed_secret
	run librarian_author_key "public"
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 32 ]
	printf '%s' "$output" | grep -Eq '^[0-9a-f]{32}$' || return 1
}

@test "the key is not the secret" {
	# Catches a "derivation" that echoes its input.
	_fixed_secret
	local secret key
	secret=$(librarian_author_secret_ensure)
	key=$(librarian_author_key "public")
	[ "$key" != "$secret" ]
	[[ "$secret" != *"$key"* ]] || return 1
}

@test "an unknown visibility is refused, naming it" {
	# --separate-stderr: plain `run` merges stdout and stderr into $output, so
	# the required stderr reason would make $output non-empty even though
	# stdout itself is clean. See the identical rationale on the Task 1 test
	# "an empty secret is refused, not used" above.
	_fixed_secret
	run --separate-stderr librarian_author_key "everyone"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	[[ "$stderr" == *"everyone"* ]] || return 1
}

@test "a derivation on an empty secret refuses rather than sharing an identity" {
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	: > "$path"

	run --separate-stderr librarian_author_key "public"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	[[ "$stderr" == *"empty"* ]] || return 1
}

@test "a 65-character secret is refused, not accepted as a wider key" {
	# The charset check used to be unbounded above (^[0-9a-f]{64,}$), so a
	# longer-but-still-hex first line quietly derived a DIFFERENT identity
	# instead of being refused. HMAC does not ignore extra key width — a
	# longer key is a different key, not a wider version of the same one.
	local path secret
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	secret=$(printf '0%.0s' $(seq 1 65))
	[ "${#secret}" -eq 65 ]
	printf '%s\n' "$secret" > "$path"

	run librarian_author_key "public"
	[ "$status" -ne 0 ]
	[[ "$output" == *"malformed"* ]] || return 1
}

@test "a second line in the secret file is never concatenated into a third identity" {
	# Regression for the embedded-newline bug: the charset check used to run
	# AFTER a `tr -d '\n'` that stripped every newline in the file, so two
	# concatenated 64-char lines (exactly the shape you get from `>>`
	# instead of `>`, or restoring a backup on top of an existing secret)
	# read as one 128-char "valid" secret — a THIRD identity matching
	# neither line. Reading only the first line sidesteps that: content
	# past line one is simply never read, so the key must match the golden
	# vector for the all-zero secret used on its own.
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$path"
	printf '%s\n' "1111111111111111111111111111111111111111111111111111111111111111" >> "$path"
	chmod 0600 "$path"

	run librarian_author_key "public"
	[ "$status" -eq 0 ]
	[ "$output" = "11ff8ab7134c834e788ab4a5130f7853" ]
}

@test "the secret reaches the HMAC subprocess over the environment, never argv" {
	# On Linux /proc/<pid>/cmdline is world-readable, so a secret on argv
	# would be visible to any local user for the life of the call. A spy
	# `node` on PATH records its own argv, then delegates to the real node
	# so the derivation still runs for real — this isn't just checking that
	# SOME node ran, the golden vector still has to come out right.
	_fixed_secret
	local stub_bin argv_capture real_node
	stub_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_bin"
	real_node=$(command -v node)
	argv_capture="${BATS_TEST_TMPDIR}/node-argv.bin"
	rm -f "$argv_capture"
	cat > "${stub_bin}/node" <<STUB
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$argv_capture"
exec "$real_node" "\$@"
STUB
	chmod +x "${stub_bin}/node"

	local old_path="$PATH"
	export PATH="${stub_bin}:${PATH}"
	run librarian_author_key "public"
	export PATH="$old_path"

	[ "$status" -eq 0 ]
	[ "$output" = "11ff8ab7134c834e788ab4a5130f7853" ]
	[ -f "$argv_capture" ]

	# grep -c returns 0 with exit status 1 when there is no match — assert
	# on $output, not $status, per the $RANDOM check above.
	run grep -ac "0000000000000000000000000000000000000000000000000000000000000000" "$argv_capture"
	[ "$output" = "0" ]
}

@test "a directory at the secret path is refused, not silently stranding a secret" {
	# `ln FILE DIR` succeeds by linking basename(FILE) inside DIR rather
	# than failing, so a directory at the secret path used to make creation
	# look like it succeeded while stranding a fresh 0600 secret one level
	# down that nothing ever reads again — one new stray file per call.
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$path"

	run --separate-stderr librarian_author_secret_ensure
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	[[ "$stderr" == *"not a regular file"* ]] || return 1

	# No stray secret left behind inside the directory.
	[ -z "$(ls -A "$path")" ]
}

@test "a FIFO at the secret path is refused rather than hanging forever" {
	# A plain `cat` on a FIFO with no writer blocks indefinitely, and this
	# repo's constraint is that a plugin must never hang a session. Wrapped
	# in `timeout` as a safety net for the test itself in case of a
	# regression; a correct implementation returns well inside it.
	command -v timeout >/dev/null 2>&1 || skip "timeout not available"
	command -v mkfifo >/dev/null 2>&1 || skip "mkfifo not available"
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	mkfifo "$path"

	run timeout 5 bash -c "source '${PLUGIN_ROOT}/scripts/lib/librarian-author-key.sh'; librarian_author_secret_ensure"
	[ "$status" -ne 124 ] || return 1
	[ "$status" -ne 0 ]
}

@test "a weak-permission secret from a compromised creation path is not silently repaired" {
	# Pins the `created` guard directly: without it, the tighten step below
	# would run unconditionally and silently repair a permissions
	# regression in the creation path on the very call that introduced it,
	# before anything — test or human — could observe it. The real
	# creation path always produces 0600 under a healthy umask, so a stub
	# `mktemp` on PATH stands in for a umask/creation regression: it
	# creates the temp file for real (so `ln` still has something to link)
	# and then weakens its permissions before this lib ever sees it.
	local stub_bin real_mktemp
	stub_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_bin"
	real_mktemp=$(command -v mktemp)
	cat > "${stub_bin}/mktemp" <<STUB
#!/usr/bin/env bash
tmp=\$("$real_mktemp" "\$@")
chmod 0644 "\$tmp"
printf '%s' "\$tmp"
STUB
	chmod +x "${stub_bin}/mktemp"

	local old_path="$PATH"
	export PATH="${stub_bin}:${PATH}"
	run librarian_author_secret_ensure
	export PATH="$old_path"
	[ "$status" -eq 0 ]

	local path
	path=$(librarian_author_secret_path)
	# The guard's job: leave the weak permissions from a bad creation path
	# visible rather than silently fixing them on the same call that
	# created the file.
	[ "$(ls -l "$path" | cut -c1-10)" = "-rw-r--r--" ]
}

@test "the returned key carries no trailing newline" {
	# `run`'s $output and $() both strip trailing newlines, so a stray
	# printf '%s\n' regression in librarian_author_key would stay invisible
	# to every other assertion in this file. Capture with a sentinel
	# appended immediately after the call: only newlines at the very end of
	# the whole captured stream get stripped, so a newline the function
	# itself emits ends up mid-stream, before the sentinel, and survives.
	_fixed_secret
	local captured
	captured=$(librarian_author_key "public"; printf 'END')
	[ "$captured" = "11ff8ab7134c834e788ab4a5130f7853END" ]
}

@test "a 64-character non-hex digest is refused, not truncated and returned" {
	# The width check alone cannot tell a digest from 64 arbitrary bytes.
	# Requires a misbehaving node, which is a serious precondition — but a
	# subprocess can misbehave for reasons other than compromise, and a
	# non-hex key fails the contract's own /^[0-9a-f]{32}$/ at ingest.
	_fixed_secret
	local stub_bin
	stub_bin="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub_bin"
	cat > "${stub_bin}/node" <<'STUB'
#!/usr/bin/env bash
printf 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
STUB
	chmod +x "${stub_bin}/node"

	local old_path="$PATH"
	export PATH="${stub_bin}:${PATH}"
	run --separate-stderr librarian_author_key "public"
	export PATH="$old_path"

	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	[[ "$stderr" == *"malformed"* ]] || return 1
}
