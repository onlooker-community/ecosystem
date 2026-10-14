# One Secret-Pattern Lib — Design

**Status:** Approved, not implemented.
**Tracked by:** [ONL-167](https://linear.app/onlooker/issue/ONL-167).
**Unblocks:** [ONL-161](https://linear.app/onlooker/issue/ONL-161) (customs), whose
constraint is "reuse the redaction patterns, not a third copy".
**Scope:** `scripts/lib/`, lineage's and historian's redactors, and the test fixture
that should have caught the divergence. Customs itself is **not** in scope — see
[Out of scope](#out-of-scope).

Secret-shaped literals in this document are written with placeholder tails
(`AKIA<16>`, `sk-<24>`) rather than full example values. The repository's secret scanner
blocks a write containing a complete one, which is also why
`test/bats/historian-session-end.bats` builds its fixtures by string concatenation.

---

## Why

Two plugins redact secrets before writing to `~/.onlooker`, with two separate copies of
the pattern set, and they have already diverged. Measured by running one sample through
both:

```text
input:  AKIA<16> / ghp_<24> / sk-ant-<22> / sk-<24> /
        Bearer <24> / API_KEY=<16> / "api_key": "<16>"

lineage:   7 of 7 redacted
historian: 5 of 7 — the bare sk- key and the JSON-style pair written verbatim
```

Two shapes reach disk unredacted through historian:

1. **OpenAI-style keys.** `lineage-redact.sh:31` carries `\bsk-[A-Za-z0-9]{20,}\b`.
   historian has `sk-ant-` only, so any `sk-` key that is not Anthropic's passes through.
2. **JSON-style secrets.** lineage's KV pattern accepts `[:=]` and optional quotes;
   historian's (`historian-sanitizer.sh:64-67`) accepts `=` only, so `"api_key": "…"` is
   untouched. JSON is the ordinary shape for a config file or an API response quoted into
   a transcript.

This is the wrong way round. historian indexes **whole session transcripts** into
`$ONLOOKER_DIR/historian/<project-key>/sessions/` — the largest and most sensitive store
the ecosystem keeps — while lineage stores short, size-capped change snippets. The weaker
pattern set guards the more exposed data, and `redact_secret_patterns` defaults to `true`
(`plugins/historian/config.json:13`), so this is the shipped path.

### Why no test caught it

`test/bats/historian-session-end.bats:155-180` builds its fixture from four shapes — AWS,
a GitHub PAT, `API_TOKEN=…`, Bearer — which are four historian *does* handle. The fixture
enumerates what the code implements rather than what a transcript can contain, so the gaps
are invisible to it.

That file has been a weak spot before: ecosystem-o09 found all three of its credential
assertions were non-final `!` commands, exempt from errexit, so it would have passed with
every credential written verbatim. That was gating; this is coverage. Same fixture, second
hole.

## What this spec decides

### 1. One lib, shaped as a shell function over a JSON batch

New canonical `scripts/lib/onlooker-secret-patterns.sh`, registered in `ON_DEMAND_LIBS`
and vendored into lineage and historian by `sync-shared-libs.sh`.

```text
onlooker_redact_secrets <json_array_of_strings>     # positional arg, not stdin
  → stdout: JSON array of {redacted: string, count: integer}
```

`count` is the number of substitutions made in that one string, which is what historian's
`redaction_count` already reports. Output is positionally aligned with input: element *i*
of the result corresponds to element *i* of the argument, so a caller can zip the two
without matching on content. The function takes **no** enable/disable flag — a caller that
does not want redaction does not call it, which is how lineage's `do_redact=false` bypass
stays a branch in lineage rather than a parameter in the shared lib.

**One python3 process per call, not per string.** That is the constraint that chose this
shape. Measured: a typical historian session is 3 chunks, the largest on this machine is
243, and a python3 start costs ~21 ms. A shared helper called per chunk would cost 243 ×
21 ms ≈ **5.1 s** in a SessionEnd hook with a 1.5 s default abort window. A batch
interface costs one process whatever the input size.

**Why `.sh` and not a vendored `.py` module.** A `.py` would be more natural for two
python callers and would skip the JSON marshalling, and `sync-shared-libs.sh` would copy
it happily — it is filename-agnostic, and the `_ONLOOKER_LIB_FINGERPRINT=` marker is valid
in both languages. But the catch-all vendoring guard in `shared-lib-vendoring.bats`
(`_libs_sourced_from_own_tree`) hard-codes `\.sh"` in its regex and keys on a `source`
line, which a `.py` file never has. Adoption would be unguarded. Fixing a drift bug by
first widening the drift guard is the wrong direction, so the lib stays `.sh` and both
existing guards — byte-identity and sources-but-does-not-vendor — cover it with no change.

Rejected third option: holding the patterns as a python source string in a shell variable
for each caller to interpolate into its heredoc. One source of truth and the smallest
change to both callers, but it is executable code smuggled through a shell string: no
linting, no syntax checking, and nobody can safely edit it later.

### 2. Lineage's pattern set wins, because it is a verified superset

Not a union. Checked pattern by pattern:

| | lineage | historian | |
|---|---|---|---|
| AWS `AKIA…` | yes | yes | identical |
| GitHub | `gh[pousr]_` | five separate `ghp_`/`gho_`/`ghs_`/`ghu_`/`ghr_` | same coverage |
| Anthropic `sk-ant-` | yes | yes | identical |
| OpenAI-style `sk-` | yes | **no** | lineage only |
| Bearer | yes | yes | identical |
| KV | `[:=]`, optional quotes | `=` only | lineage broader |

So historian gains two shapes and loses nothing. A union would have been the lazy default
and is not needed here; stating it as a superset is what makes "nothing is lost" checkable
rather than hoped for.

### 3. Each caller keeps its own contract

The shared lib owns the patterns and the substitution. Nothing else moves.

- **`lineage_redact`** keeps its `stdin → stdout` signature, its `max_chars` truncation and
  its `do_redact=false` bypass. Internally it wraps stdin as a one-element array, calls the
  shared function, and unwraps.
- **`historian_sanitizer_run`** keeps path-denial, `[historian:skip]` dropping, its
  `{kept, dropped}` output and its `redaction_count` per record. It replaces its inline
  `SECRET_PATTERNS` and `sanitize()` with one shared call over all chunk bodies, then zips
  the returned counts back onto the records.

Keeping the wrappers is deliberate. The two callers genuinely differ — one truncates, one
drops records and counts — and pulling those into the shared lib would make it know about
historian's chunk shape, which is how a shared lib becomes a second home for one caller's
concerns.

### 4. Fail-closed is a property, not an accident

Both redactors today produce **empty output** when python3 fails, verified by shadowing
`python3` with a stub that exits 127: no raw text reaches the caller. The shared lib
preserves that and gets a test for it, because a redactor that fails open is precisely the
leak it exists to prevent, and nothing currently asserts the behavior.

## Code shape

1. `scripts/lib/onlooker-secret-patterns.sh` — the patterns and `onlooker_redact_secrets`.
2. `scripts/sync-shared-libs.sh` — add the lib to `ON_DEMAND_LIBS`; the first copy into
   each plugin is manual, since on-demand libs are refreshed and never created.
3. `plugins/lineage/scripts/lib/lineage-redact.sh` — call the shared function; keep
   truncation and the bypass.
4. `plugins/historian/scripts/lib/historian-sanitizer.sh` — call the shared function; keep
   path-denial, skip-dropping and counts.
5. Vendored copies into both plugins, byte-identical via the sync script.

## Testing

- **A table-driven fixture enumerating every supported shape**, shared by both plugins'
  tests, so dropping a pattern fails instead of silently downgrading. The absence of this
  is what hid the bug, so it is the load-bearing part of the fix rather than a nicety.
- **The two gap shapes asserted against historian specifically** — a bare `sk-` key and a
  JSON-style pair — since that is the regression being closed. Break each on purpose
  before trusting it.
- **Fail-closed**, by shadowing `python3` with a failing stub and asserting the output is
  empty and the input secret absent.
- **Equivalence**, asserting both callers redact the same shapes, which is the property
  consolidation is supposed to buy.
- Negative assertions need `|| return 1` when non-final: a `!`-prefixed command is exempt
  from errexit, which is exactly how this file's three credential checks were once vacuous
  (ecosystem-o09). That hazard is live in any test whose assertions are "the secret is
  absent".
- Fixture literals must be split (`"s""k-…"`) or the repository's secret scanner blocks
  the file, the convention `historian-session-end.bats` already follows.

Run with `npm run test:bats`, never bare `bats`.

## Out of scope

- **Customs itself** ([ONL-161](https://linear.app/onlooker/issue/ONL-161)). It consumes
  this lib as its third caller, and sequencing it after keeps a live credential leak from
  waiting on a new opt-in plugin that ships last in a dogfood wave. Customs is also
  scoped to secrets only for now; its package-install slice is deferred.
- **Extending the vendoring guard to non-`.sh` libs.** Only needed if a future lib is not
  a shell file; related to [ONL-151](https://linear.app/onlooker/issue/ONL-151), which is
  about the guards keying on location rather than behavior.
- **Widening the pattern set beyond lineage's.** Slack tokens, GCP keys, private-key PEM
  blocks and the rest are all plausible additions, and every one is a false-positive
  decision of its own. This spec consolidates what exists; adding shapes is a separate
  change against a fixture that will then exist to measure it.

## Risks

- **A shared redactor is a single point of failure.** Today a bug in one copy leaks one
  store; afterwards it leaks both. That is the trade consolidation always makes, and it is
  the right one here only because the fixture arrives with it — without the shape table,
  this spec would be replacing two partly-wrong implementations with one uniformly-wrong
  one.
- **The JSON round-trip is new surface.** Strings carrying control characters, invalid
  UTF-8 or embedded quotes have to survive `jq` on the way in and out. The shape table
  should include a chunk with a quote and a newline in it for that reason.
- **No backfill.** Transcripts already written keep whatever they captured. Any bare `sk-`
  key or JSON-style secret already on disk stays there, and a sweep of the existing store
  is a separate decision with its own blast radius.
