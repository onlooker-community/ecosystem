---
name: cartographer
description: Audit CLAUDE.md, AGENTS.md, and .claude/rules/ instruction files for contradictions, stale references, dead rules, and scope collisions. Runs a full audit in the foreground (with lock). Use when the user explicitly invokes /cartographer, or when they want immediate feedback after editing an instruction file. Supports --scope, --phase, --verbose, --status, and --force flags.
---

# Cartographer Skill

Cartographer audits the persistent instruction layer of the current project and reports findings in the conversation. The automated SessionStart path handles periodic background audits; this skill is for on-demand use.

## Setup

```bash
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$PLUGIN_ROOT/scripts/lib/cartographer-config.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-project-key.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-lock.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-events.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-collect.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh"
```

Load config and resolve project context:

```bash
REPO_ROOT=$(cartographer_project_repo_root "$(pwd)")
cartographer_config_load "$REPO_ROOT"

if ! cartographer_config_enabled; then
  echo "Cartographer is disabled. Set cartographer.enabled=true in .claude/settings.json to enable."
  exit 0
fi

PROJECT_KEY=$(cartographer_project_key "$(pwd)")
CARTOGRAPHER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}/cartographer/$PROJECT_KEY"
mkdir -p "$CARTOGRAPHER_DIR"
```

## Invocation Modes

### `/cartographer` — full audit

Runs all phases in the foreground. Acquires the audit lock (non-blocking).

```bash
LOCK_FILE="$CARTOGRAPHER_DIR/audit.lock"

if ! cartographer_lock_acquire "$LOCK_FILE"; then
  echo "An audit is already in progress."
  echo "Run \`/cartographer --status\` to follow it, or \`/cartographer --force\` to restart."
  exit 0
fi

export CARTOGRAPHER_DIR CARTOGRAPHER_TRIGGER="manual" ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}"
bash "$PLUGIN_ROOT/scripts/run-audit.sh"
cartographer_lock_release "$LOCK_FILE"
```

After the audit completes, read findings and render them to the conversation grouped by severity (see Rendering section).

### `/cartographer --verbose` — all findings

Shows ALL known findings (new + previously seen) from `$CARTOGRAPHER_DIR/findings/`. Does NOT re-emit bus events — renders to in-conversation output only.

```bash
echo "## Known Cartographer Findings"
echo ""
for f in "$CARTOGRAPHER_DIR/findings/"*.json; do
  [[ -f "$f" ]] || continue
  jq -r '"**[\(.severity | ascii_upcase)]** \(.type) — \(.description)\n  Files: \(.file_a // "n/a") / \(.file_b // "n/a")\n  Fix: \(.suggested_fix // "n/a")\n"' "$f" 2>/dev/null
done
```

### `/cartographer --status` — audit status

Reports the running state and last completion time. No LLM calls.

```bash
echo "## Cartographer Status"
if cartographer_lock_is_held "$CARTOGRAPHER_DIR/audit.lock"; then
  pid=$(cat "$CARTOGRAPHER_DIR/audit.lock" 2>/dev/null)
  echo "Audit running (PID $pid)"
else
  echo "No audit in progress"
fi

if [[ -f "$CARTOGRAPHER_DIR/last_audit_at" ]]; then
  ts=$(cat "$CARTOGRAPHER_DIR/last_audit_at")
  echo "Last completed: $(date -r "$ts" 2>/dev/null || date -d "@$ts" 2>/dev/null || echo "$ts")"
fi

runs=$(ls "$CARTOGRAPHER_DIR/runs/" 2>/dev/null | wc -l | tr -d ' ')
total=$(ls "$CARTOGRAPHER_DIR/findings/" 2>/dev/null | wc -l | tr -d ' ')
echo "Total findings on disk: $total"
echo "Audit runs recorded: $runs"
```

### `/cartographer --force` — force restart

Kills the running audit (if any) and starts fresh.

```bash
LOCK_FILE="$CARTOGRAPHER_DIR/audit.lock"
if cartographer_lock_is_held "$LOCK_FILE"; then
  pid=$(cat "$LOCK_FILE" 2>/dev/null)
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$LOCK_FILE"
fi
# Then proceed as a normal full audit
```

### `/cartographer --phase=<phase>` — single phase

Runs only one analysis phase: `contradiction`, `stale_ref`, `dead_rule`, or `scope_collision`.
Pass `CARTOGRAPHER_PHASE_FILTER` to run-audit.sh (the script checks this env var and skips other phases).

### `/cartographer --scope=<path>` — scoped audit

Limits discovery to files under `<path>`. Set `CARTOGRAPHER_SCOPE_PATH` before running.

## Rendering Findings

After a manual audit completes, render findings grouped by severity:

```bash
echo "## Cartographer Findings"
echo ""

for severity in error warning informational; do
  count=0
  output=""
  for f in "$CARTOGRAPHER_DIR/findings/"*.json; do
    [[ -f "$f" ]] || continue
    fsev=$(jq -r '.severity // "warning"' "$f" 2>/dev/null)
    [[ "$fsev" != "$severity" ]] && continue
    (( count++ )) || true
    output+=$(jq -r '"- **\(.type)**: \(.description)\n  `\(.file_a // "n/a")`\n  Fix: \(.suggested_fix // "n/a")\n"' "$f" 2>/dev/null)
    output+=$'\n'
  done
  if [[ "$count" -gt 0 ]]; then
    echo "### ${severity^} ($count)"
    printf '%s\n' "$output"
  fi
done
```

## Event Contract

- `cartographer.issue.found` — emitted for NEW findings only (not in dedup store). Downstream consumers must deduplicate on `payload.finding_hash`.
- `cartographer.audit.complete` — emitted when all phases complete (or partial with `status: "partial"`).
- Manual `--verbose` renders known findings as in-conversation output only — no bus events.
