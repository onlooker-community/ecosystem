# Author Key Derivation — Design

**Status:** Shipped.
**Tracked by:** `ecosystem-4z8.5`, under epic `ecosystem-4z8`.
**Blocks:** `ecosystem-4z8.4` (approved pool and declined ledger).
**Contract:** `docs/lesson-promotion-pipeline.md:92`.

---

## What this is

The last thing standing between a judged lesson and the pool. A lesson cannot be
written without an `author_key`, and nothing derives one today — `grep
author_key` across this repo returns documentation and nothing else.

The contract pins the format. The derivation lives on the producing side, which
is us.

## The property that matters

`author_key` is derived **per visibility scope**, so a user's `org` identity and
their `public` identity cannot be linked by anyone who does not hold their
secret.

The failure mode is what makes this its own stage rather than a decision made
inline: **getting the derivation wrong breaks unlinkability silently.** Nothing
throws. No test goes red on its own. The pool fills with keys that look
perfectly well-formed and quietly leak the association they exist to prevent.
Every decision below is shaped by that.

## The secret

`$ONLOOKER_DIR/author/user_secret` — a plain file created `0600` on first
derivation, holding the output of `openssl rand -hex 32`.

Be precise about the width, because this is the same unit confusion that makes
the `author_key` field ambiguous: `-hex 32` requests **32 bytes** and prints
them as **64 hex characters**. The file therefore holds a 64-character string.
Do not "correct" it to `-hex 16` on the assumption that the count refers to
characters — that would halve the secret's entropy, and nothing would fail.

### Not `$RANDOM`

Archivist's ULID helper builds randomness from `$RANDOM`
(`plugins/archivist/scripts/lib/archivist-ulid.sh:41-44`). That is correct for a
sortable identifier and disqualifying for a secret — `$RANDOM` is a 15-bit
PRNG seeded predictably.

Assayer already uses `openssl rand -hex`
(`plugins/assayer/scripts/lib/assayer-ulid.sh:29`), which is the pattern to
copy. This is called out because **the wrong example is the closer one**: an
implementer looking for "how does this repo generate randomness" is more likely
to land on the ULID helpers.

### Never regenerated when it exists

A missing file means first use. An existing file is authoritative.

This is load-bearing. Regenerating silently changes the user's identity, which
orphans every lesson they have written — including their ability to retract
any of them, since retraction is authorized by holding the key that produced
them. A regeneration bug would not surface as an error; it would surface as a
person's history quietly ceasing to be theirs.

### Portable by construction

It is a plain file so that copying it works. The documented instruction is to
copy it to the second machine **before first use there**, because a machine
that has already generated a secret will not overwrite it.

The cost of portability is stated rather than hidden: the user now holds a
secret they can lose or leak. Losing it means a new identity. Leaking it means
someone can forge lessons as them and link their scoped identities.

### Permissions

Created `0600`. On read, if the mode is wider, tighten it to `0600` and warn on
stderr — do not refuse.

Refusing would block the promotion path over a condition the user cannot fix
without guidance, and tightening silently would hide a real exposure. Note that
tightening does not undo whatever exposure already occurred; it stops the next
one. The warning is the part that matters.

## The derivation

```
author_key(visibility) =
    HMAC-SHA256(key = user_secret, message = "onlooker.author.v1:" + visibility)
    truncated to its first 16 bytes
    rendered as 32 lowercase hex
```

Verified shape on LibreSSL 3.3.6, and the algorithm it verifies is unchanged
by the implementation note below:

```bash
printf '%s' "onlooker.author.v1:${visibility}" \
  | openssl dgst -sha256 -hmac "$secret" -r \
  | cut -d' ' -f1 \
  | cut -c1-32
```

### Implementation: node, not openssl, for the HMAC call

The shape above is `openssl`, because that's what proves the algorithm on the
command line. The shipped implementation calls `node` instead, for one reason:
`openssl dgst -sha256 -hmac` takes the key as a CLI argument, and there is no
flag to take it any other way. On Linux, `/proc/<pid>/cmdline` is
world-readable, so for the life of every derivation call, any local user could
read `$secret` straight out of the process table. `node`'s `crypto.createHmac`
takes the key from a variable, so the secret goes over the **environment**
instead (`/proc/<pid>/environ` is owner-only) and never appears on argv;
`visibility` still does, because it isn't secret.

The algorithm did not change: node's `crypto.createHmac("sha256", secret)`
computes the identical HMAC-SHA256 as `openssl dgst -sha256 -hmac`, verified
against all three golden vectors byte-for-byte before the switch shipped. The
node call still emits the full 64 hex characters; truncation to 32 stays a
separate step in the shell, gated by the digest-width sanity check described
below — that check, not the command substitution's own exit status, is what
makes a misbehaving subprocess fail closed, since there is no `pipefail` on a
pipeline that no longer exists once `cut` is gone.

The repo already depends on `node` (see `librarian-emit.sh` and its
`curator`/`historian` counterparts), so this adds no new dependency. `node`
absence is handled the same way `openssl` absence was: refuse, with a reason
on stderr, before attempting the call.

### Why a domain tag and a version

Once lessons exist in a shared pool, **the derivation is permanent**. Changing
it gives every user a new `author_key` and orphans everything they wrote.

`onlooker.author.v1:` buys two things for the cost of one string constant. The
domain tag stops this secret's output from colliding with any other use of the
same secret. The version lets a future `v2` add an org identity — so a user in
two orgs gets two keys — without ambiguity: `v1` lessons keep validating under
`v1`, new ones move to `v2`, and the two are distinguishable rather than
silently conflated.

**An org identity is deliberately not in `v1`.** No org id exists anywhere in
this system. Feeding one in now would invent structure for an unwritten
consumer, which is the mistake `ecosystem-si6` avoided by refusing to add a
`judging` status for a jury that did not exist.

### Truncation

**Verified against the contract.** `ZAuthorKey` in
`onlooker/packages/lesson-contract/src/primitives.ts:35-41` is
`z.string().regex(/^[0-9a-f]{32}$/)` — 32 characters, confirming the literal
reading. Its own comment reasons the same way we did: "128 bits makes that
negligible; truncating further buys nothing."

HMAC-SHA256 natively produces 64 hex characters, so the derivation truncates
to the first 16 bytes.

The contract documents the field as `HMAC(user_secret, scope)` but **does not
pin what `scope` is**, so the producing side owns that choice and the
`onlooker.author.v1:` domain tag below is compatible with it.

That comment also states what `author_key` is *for*, which sharpens why
stability matters: it "is what org revocation and public blocking act on." A
regenerated secret does not merely orphan a user's lessons — it walks them out
from under a block.

### The empty-secret trap

An empty or truncated secret file HMACs perfectly happily. `HMAC("", scope)` is
**identical for every user in that state** — a corrupt secret does not fail, it
silently collapses everyone onto one shared identity, which is the precise
opposite of what this stage exists to guarantee.

The derivation therefore refuses when the secret is missing, empty, or shorter
than expected, rather than proceeding with whatever it read. **"Shorter than
expected" means fewer than 64 hex characters** — the full width `openssl rand
-hex 32` produces. A short-but-nonempty secret is the harder case: it still
derives a plausible-looking key, just one with less entropy behind it than the
design claims.

**"Shorter than expected" has a mirror: longer than expected, and it is
refused too, not accepted.** The width check is exact — `^[0-9a-f]{64}$`,
anchored on both ends — not "64 or more." HMAC does not ignore extra key
width; a 65-character value is a *different* secret, not a wider version of
the same one. Only the raw **first line** of the file is read and validated,
before any newline stripping. That single choice closes both the
malformed-content case (64 characters of the wrong shape — uppercase, spaces,
punctuation — pass a length check but not the anchored hex check, and are
refused as malformed rather than deriving a garbage-but-deterministic
identity) and an embedded-newline case: the documented way to move the secret
to a second machine is a plain copy, but a user who instead appends (`>>`
instead of `>`, or a backup restored on top of an existing file) leaves a
second 64-hex line sitting after the first. Stripping newlines from the whole
file before validating would concatenate the two lines into a 128-character
string that reads as one long-but-"valid" secret — a *third* identity,
matching neither machine, accepted silently. Reading only the first line
means content past it is simply never read, so that case can't arise.

### Permissions guard: the secret path must be a regular file

`ln FILE DIR` succeeds — POSIX `ln` links `basename(FILE)` *inside* an
existing directory rather than failing — so a directory sitting at the secret
path used to make first-use creation look like it succeeded (`created=1`)
while stranding a fresh 0600 secret one level down, at
`$path/user_secret.XXXXXX`, that nothing ever reads again: one new stray
secret file per call. A pre-existing FIFO at the secret path is worse: `ln`
correctly refuses to overwrite it, but the subsequent plain `cat` used to
block forever with no writer, hanging the calling session — a hard violation
of this repo's "a plugin must never block a session" constraint.

Both are the same underlying condition: something other than a regular file
at the secret path. The derivation checks for it explicitly (`[[ -f "$path"
]]`) immediately after the creation step and before either the permission
tightening step or the read below can touch it, cleans up any stray secret
material the `ln`-into-directory case may have left, and refuses with a
reason naming the real cause.

## Interface

`librarian_author_key <visibility>`, in
`plugins/librarian/scripts/lib/librarian-author-key.sh`.

Echoes 32 lowercase hex and returns 0. On failure, returns non-zero and writes
**nothing to stdout**, with a reason on stderr.

All three visibilities get a key, `private` included. Private lessons never
leave the machine, but the contract requires the field on every lesson, and
deriving uniformly means `4z8.4` carries no special case.

It refuses, rather than improvising, when `openssl` (secret creation) or
`node` (HMAC derivation) is absent, the secret cannot be created or read, the
secret path is not a regular file, the secret is empty, short, too long, or
malformed, or the visibility is not one of `private` / `org` / `public`.
Every refusal writes a reason — this is the one place in the pipeline where
silence is the actual danger.

### What a caller does with a failure

The same shape the jury established: `4z8.4` leaves the lesson `approved`,
writes nothing to the pool, and reports it. **"Could not derive" is not
"declined"**, for the same reason "could not judge" is not "rejected."

The fail-soft convention still holds at the session boundary — nothing here
blocks a session. Within the promotion path, refusing to write is correct: a
pool entry carrying a wrong or shared `author_key` is worse than no entry.

## Testing

State the limit first: **no test proves unlinkability.** That rests on HMAC's
properties and on the secret staying secret. Tests catch derivation drift and
gross errors. The suite is therefore built around one idea — make any change to
the algorithm turn something red.

bats, isolated temp home, per the repo's `writing-tests` skill — single-bracket
assertions or `|| return 1` on non-final ones, and every new assertion broken
once to confirm it discriminates.

- **A golden vector.** A fixed secret and fixed visibility produce a hardcoded
  expected 32-hex string. This is the load-bearing test: change the domain tag,
  the truncation width, the hash, or the argument order and it goes red. It is
  what makes "the derivation is permanent" enforceable rather than aspirational.
- **Determinism** — same inputs twice, identical output. Retraction depends on it.
- **Scope separation** — `private`, `org`, and `public` from one secret produce
  three distinct keys.
- **Secret separation** — two different secrets at the same visibility produce
  different keys. Catches a constant that ignores the secret entirely, which
  scope separation alone would not.
- **Idempotent creation** — derive, snapshot the secret file, derive again,
  assert the file is byte-identical. Catches silent regeneration.
- **An empty secret is refused** — a zero-byte secret file yields non-zero and
  empty stdout. This is the guard against everyone collapsing onto one identity.
- **A short secret is refused**, naming the problem distinctly from empty.
- **A malformed secret is refused** — 64 characters of the wrong shape (not
  `[0-9a-f]`) clears the length check but is still rejected, distinguishably
  from both empty and short. Length is not content.
- **A too-long secret is refused, not accepted as a wider key** — 65
  characters of otherwise-valid hex. Pins the width check as exact
  (`{64}`, anchored), not "64 or more": the regression this guards against
  is a real one that shipped and was caught in review, not a hypothetical.
- **A second line in the secret file changes nothing** — two concatenated
  64-hex lines (the `>>`-instead-of-`>` shape) still derive the golden
  vector for the first line alone, proving the second line is never read
  rather than silently concatenated into a third identity.
- **Format** — exactly 32 characters, all `[0-9a-f]`. Catches uppercase and
  width drift.
- **The key is not the secret** — catches a "derivation" that echoes its input.
- **No `$RANDOM` in the lib**, asserted by grep, because the wrong pattern is
  the nearer example in this repo.
- **Permissions** — created `0600`; a `0644` file is tightened and warned about.
- **An ACL-only grant is warned about** — `chmod +a` on macOS produces a
  `-rw-------+` mode string that looks clean; the warning fires anyway
  because the ACL flag is checked separately from the mode bits. Darwin-only,
  skipped on Linux CI where the fixture can't be constructed the same way.
- **The secret never reaches the HMAC subprocess over argv** — a spy `node`
  on `PATH` records its own argv and delegates to the real `node`, so the
  derivation still has to produce the golden vector while proving the
  secret isn't sitting in the process table.
- **A directory at the secret path is refused**, not silently stranded with
  a fresh secret one level down that nothing reads again.
- **A FIFO at the secret path is refused rather than hanging** the calling
  session forever. Run under `timeout` as a safety net for the test itself.
- **The `created` guard is pinned directly** — a stub `mktemp` on `PATH`
  simulates a creation-path regression (a freshly created secret landing at
  `0644` instead of `0600`) and asserts the weak permissions survive
  un-repaired on that same call, which is what makes the regression
  observable to a human or to the permissions test above instead of being
  silently papered over.
- **The returned key carries no trailing newline** — `run`'s `$output` and
  `$()` both strip trailing newlines, so this needs a sentinel appended
  immediately after the call to make a stray one visible.

## Out of scope

The approved pool and declined ledger (`4z8.4`), any sync, and key rotation or
revocation — there is no consumer for either, and inventing one now repeats the
mistake `si6` avoided. Also out of scope: an org identity in the HMAC input,
which is what `v2` exists for.
