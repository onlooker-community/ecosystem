# Author Key Derivation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Derive a per-visibility-scope `author_key` from a machine-local secret, so a lesson can be attributed without linking a user's org and public identities.

**Architecture:** One new librarian lib. A `0600` secret file outside any project key, created once and never regenerated, plus an HMAC derivation with a versioned domain tag. Nothing consumes it yet — `ecosystem-4z8.4` will.

**Tech Stack:** bash (macOS bash 3.2 compatible), `openssl` (LibreSSL 3.3.6 on macOS, OpenSSL 3.x on Linux CI), bats.

## Pre-flight — RESOLVED

The `author_key` width was recorded as an assumption. **It is confirmed.**
`ZAuthorKey` in `onlooker/packages/lesson-contract/src/primitives.ts:35-41`
is `z.string().regex(/^[0-9a-f]{32}$/)` — 32 lowercase hex characters. The
derivation truncates HMAC-SHA256 to its first 16 bytes, and the golden vectors
below are correct as written.

The contract does not pin the HMAC's `scope` input, so the
`onlooker.author.v1:` domain tag is ours to choose and is compatible.

## Global Constraints

- **The secret is NOT project-keyed.** It lives at `${ONLOOKER_DIR:-$HOME/.onlooker}/author/user_secret`, outside any project directory. Every *other* librarian artifact is project-keyed via `librarian_project_dir`, so the local pattern is the wrong one to copy here — a per-project secret would silently give one user a different identity in every repo.
- **Never use `$RANDOM` for the secret.** `plugins/archivist/scripts/lib/archivist-ulid.sh:41-44` uses it for ULIDs, which is correct there and disqualifying here. Copy `plugins/assayer/scripts/lib/assayer-ulid.sh:29`'s `openssl rand -hex` instead.
- **`openssl rand -hex 32` means 32 BYTES, printed as 64 hex characters.** Do not "correct" it to `-hex 16`; that halves the entropy and nothing fails.
- **Never regenerate an existing secret.** A missing file means first use; an existing file is authoritative. Regenerating orphans every lesson the user has written, including their ability to retract them.
- Use `${ONLOOKER_DIR:-$HOME/.onlooker}` — the idiom at `plugins/librarian/scripts/lib/librarian-storage.sh:19`. Never a bare hardcoded `~/.onlooker`.
- On failure, return non-zero and write **nothing to stdout**, with a reason on stderr. Silence is the actual danger in this file.
- Bash 3.2 compatible: no associative arrays, no `${var^^}`, no `mapfile`.
- **bats runs under macOS system bash 3.2, where a failing NON-FINAL `[[ ]]` does NOT fail the test.** Every non-final `[[ ]]` needs `|| return 1`; single-bracket `[ ]` gates on its own.
- Assert on messages, not just exit codes, wherever a test asserts a refusal. This codebase has shipped six vacuous tests across three branches.
- No event emission. American English.
- Commit via the `/commit` contract: `<type>(<scope>): <subject> :emoji:`, subject ≤72 chars including the emoji, why-focused body.

## File Structure

| File | Responsibility |
|---|---|
| `plugins/librarian/scripts/lib/librarian-author-key.sh` | **Create.** Secret path, secret creation/validation, and the HMAC derivation. |
| `test/bats/librarian-author-key.bats` | **Create.** Secret-handling tests (Task 1), derivation tests including the golden vector (Task 2). |
| `docs/lesson-promotion-pipeline.md` | **Modify** (Task 2). Its "Open questions" section still lists `author_key` derivation as unanswered. |

---

### Task 1: The secret

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-author-key.sh`
- Test: `test/bats/librarian-author-key.bats`

**Interfaces:**
- Consumes: nothing. This lib is self-contained by design — it must not depend on `librarian_project_dir`, because the secret is not project-scoped.
- Produces:
  - `librarian_author_secret_path` → echoes the absolute path. Never fails.
  - `librarian_author_secret_ensure` → creates the secret if absent, validates it if present. Echoes the secret on stdout, returns 0. Returns non-zero with empty stdout and a stderr reason if it cannot produce a valid secret.

- [ ] **Step 1: Write the failing tests**

Create `test/bats/librarian-author-key.bats`:

```bash
#!/usr/bin/env bats

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
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	: > "$path"

	run librarian_author_secret_ensure
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
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

@test "the lib never uses RANDOM for the secret" {
	# archivist-ulid.sh uses $RANDOM correctly for a sortable id; it is the
	# nearer example in this repo and the wrong one to copy for a secret.
	run grep -c 'RANDOM' "${PLUGIN_ROOT}/scripts/lib/librarian-author-key.sh"
	[ "$output" = "0" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/librarian-author-key.bats`
Expected: every test FAILS — the lib does not exist, so `source` in `setup()` errors.

- [ ] **Step 3: Write the secret half of the lib**

Create `plugins/librarian/scripts/lib/librarian-author-key.sh`:

```bash
#!/usr/bin/env bash
# Author identity for lesson promotion.
#
# author_key is derived PER VISIBILITY SCOPE so a user's org identity and their
# public identity cannot be linked by anyone who does not hold their secret.
#
# Breaking that unlinkability breaks it SILENTLY: nothing throws, and the pool
# fills with well-formed keys that leak the association they exist to prevent.
# The golden-vector test in test/bats/librarian-author-key.bats is what makes
# any change to this derivation go red.
#
# Exposes:
#   librarian_author_secret_path
#   librarian_author_secret_ensure
#   librarian_author_key <visibility>

# Where the secret lives.
#
# NOT project-keyed, deliberately. Every other librarian artifact sits under
# librarian_project_dir; this one must not, because one user is one author
# across all their repos. A per-project secret would hand the same person a
# different identity in every project, and nothing would report it.
librarian_author_secret_path() {
	printf '%s/author/user_secret' "${ONLOOKER_DIR:-$HOME/.onlooker}"
}

# Echo a valid secret, creating one on first use.
#
# Returns non-zero with empty stdout if it cannot produce a valid secret. An
# invalid secret is never "repaired" by regenerating: an existing file is
# authoritative, because replacing it silently changes the user's identity.
librarian_author_secret_ensure() {
	local path dir
	path="$(librarian_author_secret_path)"
	dir="$(dirname "$path")"

	if [[ ! -f "$path" ]]; then
		command -v openssl >/dev/null 2>&1 || {
			printf 'author-key: openssl is required to create a secret.\n' >&2
			return 1
		}
		mkdir -p "$dir" 2>/dev/null || {
			printf 'author-key: cannot create %s\n' "$dir" >&2
			return 1
		}
		# 32 BYTES, printed as 64 hex characters. Not $RANDOM: that is a
		# 15-bit PRNG, fine for a sortable id and disqualifying for a secret.
		local generated
		generated=$(openssl rand -hex 32 2>/dev/null) || {
			printf 'author-key: openssl rand failed.\n' >&2
			return 1
		}
		# Create restricted, then write — never write then chmod, which leaves
		# a window where the secret is world-readable on disk.
		( umask 077 && printf '%s\n' "$generated" > "$path" ) || {
			printf 'author-key: cannot write %s\n' "$path" >&2
			return 1
		}
	fi

	# Tighten loose permissions and say so. Refusing would block promotion over
	# something the user cannot fix without guidance; staying silent would hide
	# a real exposure. Tightening does not undo an exposure that already
	# happened — it stops the next one, and the warning is the part that counts.
	local mode
	mode=$(ls -l "$path" 2>/dev/null | cut -c1-10)
	if [[ "$mode" != "-rw-------" ]]; then
		chmod 0600 "$path" 2>/dev/null
		printf 'author-key: tightened permissions on %s (was %s)\n' "$path" "$mode" >&2
	fi

	local secret
	secret=$(cat "$path" 2>/dev/null | tr -d '\n')
	if [[ -z "$secret" ]]; then
		printf 'author-key: secret at %s is empty; refusing to derive.\n' "$path" >&2
		return 1
	fi
	# A short-but-nonempty secret still derives a plausible key with less
	# entropy than this design claims. 64 is the width openssl rand -hex 32
	# produces.
	if [[ "${#secret}" -lt 64 ]]; then
		printf 'author-key: secret at %s is too short (%d chars, expected 64).\n' \
			"$path" "${#secret}" >&2
		return 1
	fi

	printf '%s' "$secret"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/bats/librarian-author-key.bats`
Expected: PASS, 8/8.

- [ ] **Step 5: Prove the two security-critical tests discriminate**

In a throwaway `git worktree` only — never the shared working tree:

```bash
git worktree add /tmp/ak-verify HEAD
# In /tmp/ak-verify, two separate injections, run the suite after each:
#  (a) make librarian_author_secret_ensure regenerate unconditionally
#      (move the generation outside the `if [[ ! -f ... ]]`)
#      Expected: "an existing secret is never regenerated" FAILS
#  (b) delete the empty-secret guard
#      Expected: "an empty secret is refused, not used" FAILS
git worktree remove --force /tmp/ak-verify
```

Report each injection's result separately. If either leaves the suite green, that test is not pinning its guard — say so plainly rather than reporting it as proven.

- [ ] **Step 6: Lint and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-author-key.sh
git add plugins/librarian/scripts/lib/librarian-author-key.sh test/bats/librarian-author-key.bats
```

Commit subject: `feat(librarian): keep one author secret per user :closed_lock_with_key:`

---

### Task 2: The derivation

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-author-key.sh`
- Modify: `docs/lesson-promotion-pipeline.md`
- Test: `test/bats/librarian-author-key.bats` (append)

**Interfaces:**
- Consumes: `librarian_author_secret_ensure` from Task 1.
- Produces: `librarian_author_key <visibility>` → echoes 32 lowercase hex, returns 0. Non-zero with empty stdout on any failure.

**Confirm the BLOCKING PRE-FLIGHT above before starting.** If the contract says 64 hex rather than 32, change the truncation and regenerate the golden vector; nothing else moves.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-author-key.bats`:

```bash
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
	_fixed_secret
	run librarian_author_key "everyone"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
}

@test "a derivation on an empty secret refuses rather than sharing an identity" {
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	: > "$path"

	run librarian_author_key "public"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
}
```

- [ ] **Step 2: Verify the golden vectors independently**

The three expected values above were computed **before any implementation
existed**, directly from `openssl`, so they are not circular. Confirm them
yourself before trusting them — a golden vector copied from a buggy
implementation pins the bug:

```bash
Z=0000000000000000000000000000000000000000000000000000000000000000
for v in private org public; do
  printf '%s' "onlooker.author.v1:${v}" \
    | openssl dgst -sha256 -hmac "$Z" -r | cut -d' ' -f1 | cut -c1-32
done
```

Expected, in order: `e74674c25190cdf15099604441bb0d4b`,
`a8cf0203e178702412d37d5f796adbdc`, `11ff8ab7134c834e788ab4a5130f7853`.

If your platform's `openssl` disagrees with these, **stop and report it** —
that is a portability problem in the derivation itself, not a bad test, and it
means keys would differ between a contributor's machine and CI.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats test/bats/librarian-author-key.bats`
Expected: the nine new tests FAIL — `librarian_author_key` is not defined.

- [ ] **Step 4: Write the derivation**

Append to `plugins/librarian/scripts/lib/librarian-author-key.sh`:

```bash
# Derive this user's author_key for one visibility scope.
#
#   HMAC-SHA256(secret, "onlooker.author.v1:<visibility>")
#   truncated to 16 bytes, rendered as 32 lowercase hex
#
# The domain tag stops this secret's output colliding with any other use of the
# same secret. The version is what lets a future v2 add an org identity without
# silently rederiving every existing key: v1 lessons keep validating under v1.
#
# No org id in v1 — none exists in this system, and inventing one for an
# unwritten consumer is the mistake ecosystem-si6 avoided.
#
# Usage: librarian_author_key <private|org|public>
librarian_author_key() {
	local visibility="${1:-}"
	case "$visibility" in
		private|org|public) ;;
		*)
			printf 'author-key: unrecognized visibility: %s\n' "$visibility" >&2
			return 1
			;;
	esac

	command -v openssl >/dev/null 2>&1 || {
		printf 'author-key: openssl is required to derive a key.\n' >&2
		return 1
	}

	local secret
	secret=$(librarian_author_secret_ensure) || return 1

	local digest
	digest=$(printf '%s' "onlooker.author.v1:${visibility}" \
		| openssl dgst -sha256 -hmac "$secret" -r 2>/dev/null \
		| cut -d' ' -f1) || {
		printf 'author-key: HMAC failed.\n' >&2
		return 1
	}

	# 64 hex chars in, 32 out. Truncating an HMAC is standard; 128 bits is
	# ample for a collision-resistant pseudonymous identifier.
	[[ "${#digest}" -eq 64 ]] || {
		printf 'author-key: unexpected digest width %d; refusing.\n' "${#digest}" >&2
		return 1
	}
	printf '%s' "${digest:0:32}"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/bats/librarian-author-key.bats`
Expected: PASS, 17/17 (8 from Task 1, 9 new).

- [ ] **Step 6: Prove the golden vector discriminates**

In a throwaway `git worktree` only. Three separate injections, running the
suite after each and reverting between:

```bash
git worktree add /tmp/ak-verify2 HEAD
#  (a) change the domain tag to "onlooker.author.v2:"
#  (b) change the truncation from :0:32 to :0:64
#  (c) swap the HMAC arguments (hash the secret keyed by the message)
git worktree remove --force /tmp/ak-verify2
```

Expected: the golden-vector test FAILS under each. Report all three results
separately. If any injection leaves it green, the vector is not pinning the
derivation — say so rather than reporting it as proven.

- [ ] **Step 7: Close the doc's open question**

`docs/lesson-promotion-pipeline.md` has an "Open questions" section whose
second bullet still reads that `author_key` derivation is unsettled ("Where
does `user_secret` live, and how is it created on first use?"). Replace that
bullet with a one-line statement of the answer and a pointer to
`docs/superpowers/specs/2026-08-12-author-key-design.md`.

Leave the other open questions alone.

- [ ] **Step 8: Lint, full suite, and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-author-key.sh
npm run test:ci
git add plugins/librarian/scripts/lib/librarian-author-key.sh \
        test/bats/librarian-author-key.bats \
        docs/lesson-promotion-pipeline.md
```

Read each exit code from `$?` directly — never through a pipe, which reports
the pipe's last command.

Commit subject: `feat(librarian): derive an author key per visibility scope :closed_lock_with_key:`

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| Secret at `$ONLOOKER_DIR/author/user_secret`, not project-keyed | 1 |
| `openssl rand -hex 32`, never `$RANDOM` | 1 |
| Created `0600`; loose permissions tightened with a warning | 1 |
| Never regenerated when present | 1 |
| Empty or short secret refused | 1, 2 |
| `HMAC(secret, "onlooker.author.v1:<visibility>")`, truncated to 32 hex | 2 |
| All three visibilities derive a key | 2 |
| Failure returns non-zero with empty stdout and a stderr reason | 1, 2 |
| Golden vector, determinism, scope separation, secret separation | 2 |
| Format is exactly 32 lowercase hex | 2 |
| Key is not the secret | 2 |
| No `$RANDOM` in the lib | 1 |
