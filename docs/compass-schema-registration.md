# Compass Event Schema Registration

## Issue

Compass plugin emits three event types that are **not registered** in the `@onlooker-community/schema` package:

- `compass.check.passed` — alignment check passed; write proceeds
- `compass.check.failed` — alignment check failed; write blocked
- `compass.check.skipped` — check gate matched; write proceeds unverified

These events are documented in `plugins/compass/README.md` and implemented in `plugins/compass/scripts/lib/compass-gate.sh`, but they are missing from the schema's event_type enum at <https://schema.onlooker.dev/schemas/event.v1.json>.

## Current Behavior

The onlooker daemon logs validation warnings whenever compass events are emitted:

```
level=WARN msg="skipping event that fails schema validation"
  path=/Users/meaganwaller/.onlooker/logs/onlooker-events.jsonl
  err="schema: jsonschema validation failed with 'https://schema.onlooker.dev/schemas/event.v1.json#'
  - at '/event_type': value must be one of [... valid types ...]"
```

Valid compass events are silently dropped from the event log, breaking observability of alignment checks.

## Required Changes

These changes must be made in the `@onlooker-community/schema` repository:

### 1. Update event.v1.json

Add three entries to the `event_type` enum:
- `compass.check.passed`
- `compass.check.failed`
- `compass.check.skipped`

### 2. Define payload schemas

For each event type, define the payload schema with fields documented in `plugins/compass/README.md`:

**`compass.check.passed`**
- `confidence` (number 0-1) — mean confidence score from evaluators
- `stddev` (number) — standard deviation of evaluator scores
- `file_path` (string) — path to the file being written
- `tool_name` (string) — name of the tool (Write, Edit, MultiEdit, Bash)
- `had_prior_turn` (boolean) — whether prior assistant turn was available

**`compass.check.failed`**
- `confidence` (number 0-1) — mean confidence score (below threshold)
- `stddev` (number) — standard deviation (above threshold)
- `primary_concern` (string) — most common concern from evaluators
- `file_path` (string) — path to the file being written

**`compass.check.skipped`**
- `reason` (string enum) — one of: `skip_sentinel`, `skip_glob`, `dir_plus_stem_cooldown`, `turn_budget_exhausted`, `insufficient_context`, `circuit_open`, `reply_to_question_pattern`, `sampler_error`
- `file_path` (string, optional) — path to the file (may be empty for non-write gates)

## References

- **Event emission:** `plugins/compass/scripts/lib/compass-gate.sh`
- **Documentation:** `plugins/compass/README.md`
- **Design doc:** `plugins/compass/docs/design.md`
- **Architecture:** `CLAUDE.md` ADR-005 (schema registration requirement)

## Impact

Once registered, compass alignment events will be visible in the Onlooker event log, enabling:
- Measurement of how often intent clarity gates trigger
- Analysis of evaluator agreement patterns
- Auditing of circuit breaker behavior
- Observability of the pre-write alignment layer
