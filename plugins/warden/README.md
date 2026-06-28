# Warden

Untrusted-content gate enforcing the Agents Rule of Two.

Warden scans content flowing into the agent through `WebFetch` and `Read` for prompt-injection patterns. When it finds a threat, it closes a session-scoped **content gate** that blocks `Write`, `Edit`, `MultiEdit`, and `Bash` until the user explicitly clears it.

Grounded in Meta's *Agents Rule of Two*: an agent should hold no more than two of {access to private data, ability to take external actions, processing of untrusted content} at once. A coding agent in a real repository already holds the first two — your source and secrets, plus the ability to write files and run commands. The moment it ingests untrusted content (a fetched page, a file of unknown provenance) it holds all three: the dangerous configuration in which untrusted content can steer private data into external actions. Warden cannot un-read content, so it removes the *external-actions* property instead — closing the gate keeps the agent reading and reasoning while a human reviews the situation. Three-of-three collapses back to two-of-three, with the user as the release valve.

Warden is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

Detection and enforcement are split across two hook surfaces, mediated only by the on-disk gate lock — the surfaces never call each other. See [ADR-001](docs/adr/001-detect-after-ingest-gate-before-action.md).

| Surface | What Warden does |
|---------|------------------|
| `PostToolUse` (`WebFetch`, `Read`) | Extracts ingested content from `tool_response`, applies the source and skip-glob filters and length cap, and runs the hybrid scanner. A strong pattern hit closes the gate immediately; a weak hit escalates to the evaluator. On a positive verdict it closes the session-scoped gate and emits `warden.threat.detected`. PostToolUse cannot block the read — and deliberately does not, because reading is how the threat is discovered. |
| `PreToolUse` (`Write`, `Edit`, `MultiEdit`, `Bash`) | Pure lock check: if the gate is closed it returns `{"decision":"block", …}` and emits `warden.gate.blocked`; otherwise it allows silently. No model call, no command parsing. |
| `SessionStart` | Initializes Warden for the session. A new session always starts with the gate open, even if a prior session saw a threat. |
| `/warden` skill | The user-facing control surface — reports gate status and is the only sanctioned way to clear a closed gate. |

### Hybrid detection

Detection is a two-stage funnel, balancing coverage against cost and data egress:

1. **Pattern floor** (`warden-patterns.sh`) — a curated regex set mapped to five threat types: `prompt_injection`, `instruction_override`, `credential_exfiltration`, `command_injection`, and `social_engineering`. **Strong** signatures (explicit override/exfil/command-injection phrasing) score `detection.strong_pattern_confidence` (default `0.9`) and close the gate with no model call. **Weak** signatures (social-engineering pressure, soft instruction-shaped imperatives) score `detection.weak_pattern_confidence` (default `0.5`) — below `close_threshold` — and are treated as borderline.
2. **LLM escalation** (`warden-evaluator.sh`) — borderline content is sanitized and sent to N parallel Haiku judges (majority vote). The gate closes only if the panel judges it an injection with confidence `≥ close_threshold`.

Clean content (no signature) never reaches the model. Set `escalation.enabled: false` for a zero-egress, pattern-only posture.

### Fail-soft posture

- Detection never blocks the read — `PostToolUse` cannot. If escalation errors, Warden falls back to the deterministic pattern verdict.
- Enforcement is a pure lock check, trivially fail-closed: a present lock always blocks.
- Event emission is best-effort; a schema-validation or emit failure is logged to stderr and never blocks a session.

## Activation

Install the plugin in Claude from the marketplace with:

```
/plugin install warden@onlooker-community
```
## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "warden": {
    "scan": {
      "sources": ["web_fetch", "file_read"],
      "max_content_chars": 20000,
      "skip_globs": ["**/*.lock", "**/*.sum", "**/node_modules/**", "**/.git/**", "**/dist/**", "**/build/**"],
      "store_snippet": true,
      "snippet_max_chars": 240
    },
    "detection": {
      "close_threshold": 0.65,
      "strong_pattern_confidence": 0.9,
      "weak_pattern_confidence": 0.5
    },
    "escalation": {
      "enabled": true,
      "borderline_only": true,
      "model": "claude-haiku-4-5-20251001",
      "n": 3,
      "temperature": 0.0,
      "max_output_tokens": 192,
      "sample_timeout_seconds": 12,
      "min_valid_samples": 2
    },
    "gate": {
      "blocked_tools": ["Write", "Edit", "MultiEdit", "Bash"],
      "clear_policy": "user_override_only"
    }
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `scan.sources` | `["web_fetch", "file_read"]` | Which ingestion sources to scan. Matches the schema's `source_type` enum. |
| `scan.max_content_chars` | `20000` | Length cap on the content fed into detection. |
| `scan.skip_globs` | lockfiles, `node_modules`, `.git`, `dist`, `build`, … | Globs whose reads are not scanned. |
| `scan.store_snippet` | `true` | Whether to keep a flagged excerpt in the gate record and event payload. |
| `scan.snippet_max_chars` | `240` | Maximum length of a stored snippet. |
| `detection.close_threshold` | `0.65` | Confidence at or above which a verdict closes the gate. |
| `detection.strong_pattern_confidence` | `0.9` | Score assigned to strong pattern hits — above threshold, closes without a model call. |
| `detection.weak_pattern_confidence` | `0.5` | Score assigned to weak pattern hits — below threshold, escalates to the evaluator. |
| `escalation.enabled` | `true` | Whether borderline content escalates to the LLM evaluator. `false` is a zero-egress, pattern-only posture. |
| `escalation.borderline_only` | `true` | Escalate only weak/borderline hits, never clean content. |
| `escalation.model` | `claude-haiku-4-5-20251001` | Model used for the evaluator panel. |
| `escalation.n` | `3` | Number of parallel evaluator samples (majority vote). |
| `escalation.temperature` | `0.0` | Sampling temperature for the evaluator. |
| `escalation.max_output_tokens` | `192` | Token ceiling per evaluator sample. |
| `escalation.sample_timeout_seconds` | `12` | Per-sample wall-clock timeout. |
| `escalation.min_valid_samples` | `2` | Minimum valid samples required to form a verdict. |
| `gate.blocked_tools` | `["Write", "Edit", "MultiEdit", "Bash"]` | Tools blocked while the gate is closed. |
| `gate.clear_policy` | `user_override_only` | How a closed gate may be cleared. Only explicit user override is supported. |

On escalation, only a sanitized, length-capped excerpt of the ingested content is sent to the evaluator model. Setting `escalation.enabled: false` disables all egress — Warden then relies on the deterministic pattern floor alone.

## The gate model

The gate is a single session-scoped lock with two states:

- **Open** (default — file absent, or `{"state":"open"}`) — `Write`, `Edit`, `MultiEdit`, and `Bash` are allowed.
- **Closed** (`{"state":"closed", …}`) — those operations are blocked at `PreToolUse`.

The detection hook **closes** the gate on a positive scan. Once closed, it can be **cleared only by the user** via the `/warden` skill (`clear_policy: user_override_only`) — Warden does not auto-clear in this release. The gate is session-scoped: a brand-new session starts open even if a prior session saw a threat, because the untrusted content lives in a specific session's context.

Clearing the gate re-enables write-class tools but does not remove the flagged content from the conversation — it is still in context. The skill reminds the user of this.

## Storage layout

```text
~/.onlooker/warden/sessions/<session_id>/
└── gate.json
```

`gate.json` when the gate is closed:

```json
{
  "state": "closed",
  "closed_at": 1717000000,
  "threat": {
    "threat_id": "01J…",
    "source_type": "web_fetch",
    "threat_type": "credential_exfiltration",
    "confidence": 0.9,
    "source_url": "https://…",
    "source_path": null,
    "snippet": "…sanitized excerpt…",
    "matched_pattern": "…",
    "detection_method": "pattern_strong"
  }
}
```

The local record keeps forensic fields (`threat_id`, `matched_pattern`, `detection_method`). The emitted `warden.threat.detected` event carries only the schema-permitted fields — warden payloads use `additionalProperties: false`. State is keyed by `session_id`, not by repository: the gate guards a single session's context.

## Events emitted

Warden emits the canonical `warden.*` event surface from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema) (v2.4.0+). All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

| Event | When | Payload |
|-------|------|---------|
| `warden.threat.detected` | A scan closes the gate. | `source_type`, `threat_type`, `confidence` (plus optional `source_url` / `source_path` / `snippet`) |
| `warden.gate.blocked` | A write/edit/bash operation is blocked by a closed gate. | `blocked_operation`, `threat_source_type` |
| `warden.threat.cleared` | The user clears the gate via `/warden`. | `source_type`, `cleared_by: user_override` |

## The `/warden` skill

`/warden` is the user-facing control surface for the gate that the hooks open and close automatically.

- `/warden` or `/warden status` — prints whether the gate is OPEN or CLOSED. When closed, prints the recorded threat: `threat_type`, `source_type`, source URL/path, confidence, detection method, matched pattern, and the flagged snippet (when storage is enabled).
- `/warden clear` (also `reopen`, `override`, `unblock`) — verifies the gate is closed, removes the lock, re-enables `Write`/`Edit`/`Bash`, and emits `warden.threat.cleared` with `cleared_by: user_override`.

The skill resolves the active session automatically: it prefers `$CLAUDE_SESSION_ID`, falls back to the single closed gate when exactly one exists, and reports ambiguity if several sessions have closed gates (re-run with an explicit session id in that case). Closing is automatic; clearing is always a deliberate user decision.

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- `claude` CLI on `PATH` (the evaluator shells out to `claude -p` when escalation is enabled).
- `jq` for JSON manipulation.
- `node` for canonical-event emission.

## Architecture decisions

Key decisions made during initial design are recorded in [`docs/adr/`](docs/adr/):

- [ADR-001](docs/adr/001-detect-after-ingest-gate-before-action.md) — Detect after ingestion, gate before action (the detection/enforcement split and its Rule-of-Two mapping)

See also the full plugin design in [`docs/design.md`](docs/design.md).
