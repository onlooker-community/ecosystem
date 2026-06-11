---
name: counsel
description: Run the weekly observability synthesis on demand and render the coaching brief in the conversation. Reads the onlooker event log, runs a single synthesis pass, writes the brief, and prints it — bypassing the SessionStart staleness gate. Use when the user explicitly invokes /counsel, or wants a fresh improvement brief right now instead of waiting for the next stale-brief regeneration. Supports --show (print the latest brief, no LLM call) and --status.
---

# Counsel Skill

Counsel's SessionStart hook regenerates a weekly improvement brief only when the
last one has gone stale (`synthesis_interval_days`, default 7) and injects it
invisibly. This skill is the on-demand path: it forces a fresh synthesis right
now and renders the brief into the conversation.

## Setup

Run this once at the start. It sources the plugin helpers, loads config, and
resolves project context.

```bash
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

source "$PLUGIN_ROOT/scripts/lib/counsel-config.sh"
source "$PLUGIN_ROOT/scripts/lib/counsel-events.sh"
source "$PLUGIN_ROOT/scripts/lib/counsel-project-key.sh"
source "$PLUGIN_ROOT/scripts/lib/counsel-ulid.sh"
source "$PLUGIN_ROOT/scripts/lib/counsel-reader.sh"
source "$PLUGIN_ROOT/scripts/lib/counsel-synthesize.sh"
source "$PLUGIN_ROOT/scripts/lib/counsel-brief.sh"

REPO_ROOT=$(counsel_project_repo_root "$(pwd)")
counsel_config_load "$REPO_ROOT"

if ! counsel_config_enabled; then
  echo "Counsel is disabled. Set counsel.enabled=true in .claude/settings.json to enable."
  exit 0
fi

PROJECT_KEY=$(counsel_project_key "$(pwd)")
if [[ -z "$PROJECT_KEY" ]]; then
  echo "No project key — Counsel needs a git repository (remote or root) to scope briefs. Skipping."
  exit 0
fi
BRIEFS_DIR=$(counsel_project_dir "$PROJECT_KEY")
```

## Invocation Modes

### `/counsel` — run the weekly review now (default)

Forces a synthesis pass regardless of brief freshness, writes the brief to
`${ONLOOKER_DIR:-~/.onlooker}/counsel/<project-key>/briefs/<YYYY-WW>.md`, emits
`counsel.brief.generated`, and renders the result. Re-running in the same ISO
week overwrites that week's brief in place. (`$ONLOOKER_DIR` overrides the
storage root; the test suite and non-default installs rely on it.)

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-$(counsel_ulid)}"
export _HOOK_SESSION_ID="$SESSION_ID"

LOOKBACK=$(counsel_config_get '.counsel.lookback_days'); LOOKBACK="${LOOKBACK:-30}"
echo "Running Counsel synthesis over the last ${LOOKBACK} days of events…"

_rc=0
OUTPUT_PATH=$(counsel_generate_brief "$SESSION_ID" "$(pwd)" force) || _rc=$?

if [[ "$_rc" -eq 2 ]]; then
  min_events=$(counsel_config_get '.counsel.capture.min_events'); min_events="${min_events:-10}"
  echo "Not enough events to synthesize a brief (fewer than ${min_events} in the lookback window). Use the ecosystem long enough to accumulate telemetry, then try again."
  exit 0
elif [[ "$_rc" -ne 0 || -z "$OUTPUT_PATH" || ! -f "$OUTPUT_PATH" ]]; then
  echo "Counsel synthesis failed. Check that the \`claude\` CLI is on PATH and the onlooker log is readable."
  exit 1
fi
```

Then render the brief verbatim to the conversation:

```bash
echo "## Counsel weekly review (\`$(basename "$OUTPUT_PATH" .md)\`)"
echo ""
cat "$OUTPUT_PATH"
echo ""
echo "_Brief saved to ${OUTPUT_PATH}._"
```

### `/counsel --show` — print the latest brief (no LLM call)

Renders the most recent brief already on disk. No synthesis, no events emitted.

```bash
LATEST=$(ls -1 "$BRIEFS_DIR"/*.md 2>/dev/null | sort | tail -1)
if [[ -z "$LATEST" || ! -f "$LATEST" ]]; then
  echo "No brief on disk yet for this project. Run \`/counsel\` to generate one."
  exit 0
fi
echo "## Counsel brief (\`$(basename "$LATEST" .md)\`)"
echo ""
cat "$LATEST"
```

### `/counsel --status` — brief freshness

Reports the latest brief's age, last-generated time, and path. No LLM call.

```bash
INTERVAL=$(counsel_config_get '.counsel.synthesis_interval_days'); INTERVAL="${INTERVAL:-7}"
LATEST=$(ls -1 "$BRIEFS_DIR"/*.md 2>/dev/null | sort | tail -1)

echo "## Counsel status"
echo "- Project key: ${PROJECT_KEY}"
echo "- Briefs dir:  ${BRIEFS_DIR}"
echo "- Stale after: ${INTERVAL} days"

if [[ -z "$LATEST" || ! -f "$LATEST" ]]; then
  echo "- Latest brief: none yet (run \`/counsel\`)"
  exit 0
fi

if [[ "$(uname)" == "Darwin" ]]; then
  mtime=$(stat -f '%m' "$LATEST" 2>/dev/null || echo 0)
  human=$(date -r "$mtime" 2>/dev/null || echo "$mtime")
else
  mtime=$(stat -c '%Y' "$LATEST" 2>/dev/null || echo 0)
  human=$(date -d "@$mtime" 2>/dev/null || echo "$mtime")
fi
now=$(date +%s 2>/dev/null || echo "$mtime")
age_days=$(( (now - mtime) / 86400 ))

echo "- Latest brief: $(basename "$LATEST") (generated ${human}, ${age_days}d ago)"
if [[ "$age_days" -ge "$INTERVAL" ]]; then
  echo "- Status: stale — SessionStart will regenerate, or run \`/counsel\` now."
else
  echo "- Status: fresh — run \`/counsel\` to force a regeneration anyway."
fi
```

## Notes

- The synthesis pass shells out to `claude -p` with the configured
  `evaluator.model` (default Haiku) — see the plugin README for all config keys.
- The on-demand path honors the same `capture.min_events` floor as the hook: if
  too few events fall inside the lookback window, it reports that instead of
  emitting a thin brief.
- Output, events, storage layout, and project keying are identical to the
  SessionStart path — this skill only bypasses the staleness gate.
