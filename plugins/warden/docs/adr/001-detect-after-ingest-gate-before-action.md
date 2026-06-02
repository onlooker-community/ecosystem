# ADR-001: Warden Detects After Ingestion and Gates Before Action

- Status: Accepted
- Date: 2026-06-02
- Deciders: Meagan
- Tags: warden, rule-of-two, hook-architecture, prompt-injection, content-gate

## Context and Problem Statement

Warden defends against prompt injection arriving through untrusted content — content the agent ingests via `WebFetch` and `Read`. The naive instinct for a "scan content before the agent processes it" plugin is to scan at `PreToolUse`: inspect the thing before it enters the context, and block it if it's hostile.

That instinct does not fit the actual data flow:

1. **The content does not exist before the tool runs.** A `WebFetch` result is only known *after* the fetch. A `Read` result is the file's contents, surfaced in the `tool_response`. At `PreToolUse` there is nothing to scan but a URL or a path — far too little signal to classify an injection, and scanning the URL/path alone would miss the entire payload.
2. **Blocking the read is the wrong lever.** Reading a hostile page is not itself harmful; reading is how the agent and the user *discover* that the page is hostile. The harm is what the agent does *next* with that content — writing a file, editing code, running a command, exfiltrating a secret. The threat is downstream of ingestion.

So the question is not "how do we stop the agent from reading bad content" (we can't, and shouldn't), but "once bad content is in the context, how do we prevent it from driving an external action." This is precisely the framing of Meta's **Agents Rule of Two**: untrusted content (property C) is now present alongside private-data access (A) and external-action capability (B); we must drop one of the other two. Dropping B — external actions — is the safe, reversible choice.

## Decision Drivers

- **Signal availability**: the injection payload only exists in `tool_response`, which is a `PostToolUse` field. Detection must run where the content is.
- **No timing skew**: `PostToolUse` fires after the content is committed to the transcript, so the scan sees exactly what the agent sees — no race.
- **Reversibility**: the response to a detected threat should be a *pause a human can lift*, not a destructive or silent action. Revoking external actions is reversible; un-reading is not.
- **Rule-of-Two alignment**: the mitigation should map cleanly onto removing exactly one of the three properties. Gating B (Write/Edit/Bash) is that mapping.
- **Fail-soft**: a detector that runs on every read must not block reads when it errors, and the enforcement check must be cheap enough to run before every write without latency cost.

## Considered Options

1. **Scan at `PreToolUse` on WebFetch/Read and block the read.** Inspect before ingestion.
2. **Detect at `PostToolUse` on WebFetch/Read; gate at `PreToolUse` on Write/Edit/MultiEdit/Bash.** Split detection from enforcement across two hook surfaces, mediated by a session-scoped lock.
3. **Single `PreToolUse` hook on the write-class tools that re-scans the whole transcript each time.** No PostToolUse; scan lazily at write time.

## Decision

We adopt **Option 2: detect after ingestion, gate before action.**

- **Detection** runs on `PostToolUse` for `WebFetch` and `Read`. It extracts the ingested content from `tool_response`, runs the hybrid scanner, and on a positive verdict **closes a session-scoped content gate** (`gate.json`) and emits `warden.threat.detected`. PostToolUse cannot block the tool — and deliberately does not need to, because blocking the read is not the goal.
- **Enforcement** runs on `PreToolUse` for `Write`, `Edit`, `MultiEdit`, and `Bash`. It is a pure lock check: if the gate is closed, it returns `{"decision":"block", …}` and emits `warden.gate.blocked`; otherwise it allows silently. No model call, no command parsing.
- The two surfaces communicate **only** through the gate lock on disk — never by calling each other — consistent with the ecosystem's event-bus discipline.

Option 1 is rejected: there is nothing meaningful to scan at `PreToolUse` for these tools, and blocking the read is both ineffective (the threat is downstream) and user-hostile (it prevents discovery). Option 3 is rejected: re-scanning the full transcript on every write is expensive, repeats work, and loses the clean "this specific source was hostile" provenance that the PostToolUse scan captures at ingestion time.

## Consequences

### Positive

- Detection sees the real payload (`tool_response`), so classification is meaningful.
- The response is reversible and human-gated: external actions pause; the user clears the gate with `/warden clear`.
- Enforcement is O(1) and fail-closed (a present lock always blocks), so gating every write is cheap.
- The design maps one-to-one onto the Rule of Two: detection observes property C arriving; enforcement removes property B until a human restores it.
- Clean separation: detection cost (possibly a model call) is paid once per ingested source; enforcement cost is a file stat.

### Negative / trade-offs

- The hostile content **is** in the context by the time the gate closes — warden mitigates the consequence (external action), not the ingestion. This is inherent to the threat model and is exactly why the mitigation targets property B.
- A gate closed late in a turn can block writes the agent already intended as benign; the user must clear it. This is the intended friction, not a bug.
- Session-scoped state means a brand-new session starts open even if a prior session saw a threat. Acceptable: the untrusted content lives in a specific session's context, and warden gates that context.

## Related

- Plugin design: [`../design.md`](../design.md)
- Schema: `warden.threat.detected`, `warden.gate.blocked`, `warden.threat.cleared` in `@onlooker-community/schema` (plugins-safety payloads).
