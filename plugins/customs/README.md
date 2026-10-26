# Customs

Outbound secret gate.

Customs fires on `PreToolUse` for `Bash` and `WebFetch`. When a call carries a secret-shaped literal, it checks where the call is headed and asks (or denies) if that host is not where that kind of secret goes. A GitHub token to `api.github.com` passes; the same token to a paste site asks. It is the counterpart to warden, which guards what comes in: customs guards what goes out. Customs does nothing until you enable it.

Customs is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present. The full design and reasoning live in the [design spec](../../docs/superpowers/specs/2026-10-25-customs-outbound-gate-design.md).

## How it works

| Hook | Surface | What Customs does |
|------|---------|-------------------|
| `PreToolUse` | `Bash` | Checks the command for a network tool first. With none, exits before any detection runs. With one, scans the command for secret-shaped literals and decides on the hosts it finds. |
| `PreToolUse` | `WebFetch` | Scans the URL, and treats its host as the destination. The prompt is not scanned, because WebFetch never sends it to that host. |

Network tools are `curl`, `wget`, `http`, `https`, `xh`, `nc`, `ncat`, `ssh`, `scp`, `sftp`, `rsync`, `gh api`, and `git` when the command writes out an `http(s)://`, `ssh://` or `user@host:` remote. A tool named by path, such as `/usr/bin/curl`, counts too, and so does one opened by a quote or a backslash (`sh -c 'curl …'`, `"curl"`, `\curl`). A quoted mention such as `git commit -m 'curl is great'` therefore runs detection as well; it asks only if a secret is also present. A secret in a command with no network tool passes: that covers `export`, an `echo` into `.env`, and `op` writes. Customs guards egress, not storage.

### Decision flow

1. A Bash call with no network tool exits silently. No event.
2. The call is scanned for secret-shaped literals. Customs gates on specific token shapes only, never on a generic `KEY=value` assignment. None found: exit silently. No event.
3. Destination hosts are read from URLs, `user@host` and `host:path` arguments, and written-out git remotes. For `curl`, `wget`, `http`, `https` and `xh`, a bare word shaped like a host (`evil.test/x`, `api.github.com`) counts too. Hosts are lowercased and ports dropped.
4. The whole call asks, as if no host were readable, when any of these holds. An allowed host elsewhere in the call cannot carry it through. This is the safe direction: it costs a prompt.
   - A candidate cannot be read as a host (`ev_il.test`, `[::1]`, over 253 characters).
   - A candidate is shaped like a secret (`https://<key>.evil.test/`). It is left out of the event and the reason.
   - One of the commands in the line runs a network tool but names no host customs can read (`nc evil.test 80`, `ssh evil.test`). The line is split on `;`, `|`, `&`, parentheses, backticks and newlines, quotes or not, so `sh -c 'curl …; nc …'` is split too.
   - A WebFetch URL holds a backslash, whitespace or a control character, which a URL parser reads differently from customs.
5. Each kind of secret is checked against each host. A call passes only when every gated kind is headed solely to hosts paired with that kind.
6. A pass emits `customs.egress.allowed` and writes nothing. A miss emits `customs.egress.flagged` and returns `ask`, or `deny` under `mode: "deny"`. The reason names the kind of secret and the host, never the value.

Customs never writes `allow`. It can add a prompt to a call another gate allowed, but it cannot loosen another gate's decision. When hooks disagree, Claude Code applies `deny` over `ask`, so a closed warden gate still wins.

### Built-in pairs

A host is trusted for its own kinds of secret only.

| Kind | Built-in hosts |
|------|----------------|
| `github_token` | `github.com`, `api.github.com`, `uploads.github.com` |
| `anthropic_key` | `api.anthropic.com` |
| `openai_key` | `api.openai.com` |
| `aws_access_key_id` | `*.amazonaws.com` |

A pattern matches a host exactly. A leading `*.` matches any subdomain and the bare domain too, so `*.amazonaws.com` accepts `amazonaws.com`.

`*.amazonaws.com` is broad on purpose. Any S3 bucket is a host under it, including one someone else owns, so an AWS access key id can reach any bucket without a prompt. That is accepted because the key id alone is low value: without its secret key it cannot sign a request.

`bearer_token` has no issuer and so no built-in pair. A bare bearer token is recorded, not gated: it emits `customs.egress.flagged` with `decision: "none"` and the call proceeds. A bearer whose value matches a specific kind, such as a GitHub token after the word `Bearer`, is checked as that kind.

## Activation

Install Customs from the marketplace:

```
/plugin install customs@onlooker-community
```

Then enable it in `.claude/settings.json`. Customs is opt-in and does nothing until you do.

```json
{
  "enabledPlugins": {
    "customs@onlooker-community": true
  }
}
```

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults, and a `customs` key in `.claude/settings.json` is merged over them.

```json
{
  "customs": {
    "mode": "ask",
    "pairs": {},
    "record_only_kinds": ["bearer_token"]
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `mode` | `"ask"` | `ask` prompts you to approve the call. `deny` blocks it outright. Any other value is treated as `ask` and emits `customs.check.failed` with `stage: "config"`. |
| `pairs` | `{}` | Extra hosts per kind of secret. These **add** to the built-in pairs. |
| `record_only_kinds` | `["bearer_token"]` | Kinds that are recorded with `decision: "none"` and never gated. |

To allow a self-hosted GitHub for GitHub tokens:

```json
{
  "customs": {
    "pairs": {
      "github_token": ["ghe.example.com"]
    }
  }
}
```

User pairs add to the built-ins rather than replacing them. The built-in pairs live in code (`scripts/lib/customs-allowlist.sh`), not in `config.json`, because the config loader's deep merge replaces arrays: with the built-ins in config, one user pair would silently drop `github.com`. Replacing the built-ins is deliberately not offered.

## What it does not catch

- **Secrets referenced through variables** (`$GITHUB_TOKEN`, `op run`). The command text never holds the value, and expanding variables would mean reading the environment.
- **Indirect egress.** A script the command runs that sends the secret later. Customs sees the call it is given, not what that call does next.
- **Request bodies read from files** (`curl -d @file`). Customs does not read files.
- **Package installs** (typosquat-shaped names, unpinned versions). Tracked as ONL-204.
- **Hosts hidden in variables or built at runtime.** These are not caught as such, but they ask, since an unreadable host is never a pass.
- **Clients outside the tool list.** `python`, `node`, `perl`, `ruby`, `socat`, `telnet`, `openssl s_client` and cloud CLIs such as `aws` or `gcloud` are not network tools to customs, so a secret they send passes unchecked.
- **Command text crafted to evade it.** Customs assumes the command was not written to fool it. Quote concatenation (`api.github.com"".evil.test`), curl's `--connect-to` and `--resolve`, and `GH_HOST=` all send a call somewhere other than the host customs reads.

## Unattended runs

When no one can answer an `ask`, Claude Code denies the call and the model reads the reason in the tool result. Measured 2026-10-25 with Claude Code 2.1.308: the live ask canary in `test/bats/gate-block-contract.bats` passes, so a `-p` run denies an `ask` that nobody answers. `ask` also holds in auto mode: the classifier can still deny the call, but it cannot approve it silently.

Run the canary with `ONLOOKER_GATE_E2E=1`. On a machine where `claude` is an account-picker shell function rather than a binary, put a shim first on `PATH` that sets `CLAUDE_CONFIG_DIR` and calls the real binary; the design plan has the exact shim.

## Failure behavior

Customs fails open, the reverse of the shared secret-pattern lib. A gate on every Bash call that failed closed would turn a missing `python3` into a session where no shell command runs, and the likely response is to disable customs. So any internal error exits 0 with no output, and emits `customs.check.failed` with the `stage` that failed: `input`, `detect`, `destination`, or `config`. A broken customs shows up as a failure on the Sessions page, never as quiet.

## Events emitted

Customs emits `customs.*` events from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema) to `~/.onlooker/logs/onlooker-events.jsonl`.

| Event | When | Key payload fields |
|-------|------|--------------------|
| `customs.egress.flagged` | A gated kind is headed somewhere unpaired, or a record-only kind is present. | `tool`, `kinds`, `hosts`, `decision` (`ask`, `deny`, or `none`) |
| `customs.egress.allowed` | Every gated kind is headed only to hosts paired with it. | `tool`, `kinds`, `hosts` |
| `customs.check.failed` | Customs could not complete the check and failed open. | `tool`, `stage` |

Payloads carry the kind of secret and the host, never the secret, the command, or a URL path. An event about a leak must not be the leak. The `hosts` list holds at most the first 16 hosts; every host is still decided. No event is emitted for a call with no network tool, or with one but no secret. Claude Code records no event for your answer to a prompt, so Customs cannot count approvals.

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- `jq` for JSON manipulation.
- `python3` for secret detection. Without it Customs fails open with `stage: "detect"`.
- `node` for canonical-event emission.
