# Author Key Derivation — Design

**Status:** Approved, not started.
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

Verified shape on LibreSSL 3.3.6:

```bash
printf '%s' "onlooker.author.v1:${visibility}" \
  | openssl dgst -sha256 -hmac "$secret" -r \
  | cut -d' ' -f1 \
  | cut -c1-32
```

`openssl dgst -sha256 -hmac` is present on macOS (LibreSSL 3.3.6) and accepts
the same form on OpenSSL 3.x. **Confirm that on Linux CI rather than assuming
it** — OpenSSL 3.x deprecated some `dgst` options and prefers `-macopt` for
certain algorithms, and a silent behavioral difference here produces wrong keys
rather than an error.

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

**Assumption, gated on verification.** The contract says "32 lowercase hex,"
read literally as 32 *characters* — 128 bits. HMAC-SHA256 natively produces 32
*bytes*, which is 64 hex characters.

128 bits is ample for a collision-resistant pseudonymous identifier, and
truncating an HMAC is standard practice. But only one of these validates at
ingest, and the enforcement boundary is the sync endpoint in `apps/api`, which
lives in the **onlooker** repo — not here. `packages/lesson-contract` does not
exist in this repository, and `@onlooker-community/schema` carries no
`author_key` at all.

**Confirm the width against the lesson contract before writing code.** Getting
it wrong means every key we mint fails at ingest, and we would discover that
only when a sync service that does not exist yet starts rejecting them.

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

## Interface

`librarian_author_key <visibility>`, in
`plugins/librarian/scripts/lib/librarian-author-key.sh`.

Echoes 32 lowercase hex and returns 0. On failure, returns non-zero and writes
**nothing to stdout**, with a reason on stderr.

All three visibilities get a key, `private` included. Private lessons never
leave the machine, but the contract requires the field on every lesson, and
deriving uniformly means `4z8.4` carries no special case.

It refuses, rather than improvising, when `openssl` is absent, the secret
cannot be created or read, the secret is empty or short, or the visibility is
not one of `private` / `org` / `public`. Every refusal writes a reason — this
is the one place in the pipeline where silence is the actual danger.

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
- **Format** — exactly 32 characters, all `[0-9a-f]`. Catches uppercase and
  width drift.
- **The key is not the secret** — catches a "derivation" that echoes its input.
- **No `$RANDOM` in the lib**, asserted by grep, because the wrong pattern is
  the nearer example in this repo.
- **Permissions** — created `0600`; a `0644` file is tightened and warned about.

## Out of scope

The approved pool and declined ledger (`4z8.4`), any sync, and key rotation or
revocation — there is no consumer for either, and inventing one now repeats the
mistake `si6` avoided. Also out of scope: an org identity in the HMAC input,
which is what `v2` exists for.
