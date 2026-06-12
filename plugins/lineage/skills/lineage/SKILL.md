---
name: lineage
description: Answer "why does this line exist?" — trace a file, or a specific line, back to the change, prompt, agent, and session that produced it. Reads lineage's per-project change ledger and joins it to the transcripts historian preserves. Modes — /lineage <file> (change history), /lineage <file>:<line> or --line N (single-line provenance), /lineage <file> --grep <text> (content search), /lineage --status (ledger stats). Use when the user asks who/what/why introduced code in a file, or invokes /lineage.
---

# Lineage Skill

`/lineage` reads the per-project change ledger that the PostToolUse hook records
and resolves each change's originating prompt by joining to historian's durable
session transcripts (falling back to the live transcript). It answers
"why does this line exist?" without an LLM call — pure read, join, and render.

## Setup

Run once. Sources the plugin helpers, loads config, and resolves project context.

```bash
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

source "$PLUGIN_ROOT/scripts/lib/portable-lock.sh"
source "$PLUGIN_ROOT/scripts/lib/lineage-config.sh"
source "$PLUGIN_ROOT/scripts/lib/lineage-events.sh"
source "$PLUGIN_ROOT/scripts/lib/lineage-project-key.sh"
source "$PLUGIN_ROOT/scripts/lib/lineage-redact.sh"
source "$PLUGIN_ROOT/scripts/lib/lineage-record.sh"
source "$PLUGIN_ROOT/scripts/lib/lineage-query.sh"

REPO_ROOT=$(lineage_project_repo_root "$(pwd)")
lineage_config_load "$REPO_ROOT"
if ! lineage_config_enabled; then
  echo "Lineage is disabled. Set lineage.enabled=true in .claude/settings.json to enable."
  exit 0
fi
PROJECT_KEY=$(lineage_project_key "$(pwd)")
if [[ -z "$PROJECT_KEY" ]]; then
  echo "No project key — lineage needs a git repository (remote or root) to scope its ledger."
  exit 0
fi
PROMPT_SOURCE=$(lineage_config_prompt_source)
QSID="${CLAUDE_SESSION_ID:-lineage-query}"
```

## Invocation Modes

### `/lineage <file>` — change history (default)

Set `FILE` to the path the user named, then run. (Repo-relative paths are
resolved against the repo root.)

```bash
FILE="REPLACE_WITH_FILE"
[[ "$FILE" != /* && -n "$REPO_ROOT" ]] && FILE="$REPO_ROOT/$FILE"

echo "## Lineage — change history for \`$FILE\`"
count=0
while IFS= read -r rec; do
  [[ -z "$rec" ]] && continue
  count=$((count + 1))
  ts=$(jq -r '.ts' <<<"$rec"); sid=$(jq -r '.session_id' <<<"$rec")
  turn=$(jq -r '.turn // ""' <<<"$rec"); tool=$(jq -r '.tool' <<<"$rec")
  la=$(jq -r '.lines_added' <<<"$rec"); lr=$(jq -r '.lines_removed' <<<"$rec")
  tp=$(jq -r '.transcript_path // ""' <<<"$rec")
  resolved=$(lineage_resolve_prompt "$PROJECT_KEY" "$sid" "$turn" "$tp" "$PROMPT_SOURCE")
  prompt=$(jq -r '.prompt' <<<"$resolved"); via=$(jq -r '.resolved_via' <<<"$resolved")
  echo ""
  echo "### ${ts} · ${tool} (+${la}/-${lr}) · session ${sid}${turn:+ · turn ${turn}}"
  if [[ -n "$prompt" ]]; then
    echo "Prompt context (${via}):"; echo ""
    printf '%s\n' "$prompt" | head -c 600 | sed 's/^/> /'
  else
    echo "_Prompt unavailable (${via})._"
  fi
done < <(lineage_changes_for_file "$PROJECT_KEY" "$FILE")
[[ "$count" -eq 0 ]] && { echo ""; echo "No recorded changes for this file (it may predate lineage)."; }

lineage_emit_event "lineage.query.answered" \
  "$(jq -nc --arg pk "$PROJECT_KEY" --arg f "$FILE" --argjson m "$count" \
     '{project_key:$pk, file_path:$f, matches:$m}')" "$QSID" || true
```

### `/lineage <file>:<line>` (or `--line N`) — single-line provenance

Set `FILE` and `LINE`, then run. Reads the current line's text and content-anchors
it to the change that introduced it.

```bash
FILE="REPLACE_WITH_FILE"; LINE="REPLACE_WITH_LINE_NUMBER"
[[ "$FILE" != /* && -n "$REPO_ROOT" ]] && FILE="$REPO_ROOT/$FILE"

line_text=$(sed -n "${LINE}p" "$FILE" 2>/dev/null)
needle=$(printf '%s' "$line_text" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

echo "## Lineage — why does \`$FILE\`:${LINE} exist?"
echo ""
echo "Line ${LINE}: \`${line_text}\`"

rec=$(lineage_match_line "$PROJECT_KEY" "$FILE" "$needle")
via="none"; matches=0
if [[ -z "$rec" ]]; then
  echo ""
  echo "No recorded change introduced this content (it may predate lineage, or the line moved since it was written)."
else
  matches=1
  ts=$(jq -r '.ts' <<<"$rec"); sid=$(jq -r '.session_id' <<<"$rec")
  turn=$(jq -r '.turn // ""' <<<"$rec"); tool=$(jq -r '.tool' <<<"$rec")
  tp=$(jq -r '.transcript_path // ""' <<<"$rec")
  resolved=$(lineage_resolve_prompt "$PROJECT_KEY" "$sid" "$turn" "$tp" "$PROMPT_SOURCE")
  prompt=$(jq -r '.prompt' <<<"$resolved"); via=$(jq -r '.resolved_via' <<<"$resolved")
  echo ""
  echo "Introduced ${ts} by a ${tool} in session ${sid}${turn:+ (turn ${turn})}."
  if [[ -n "$prompt" ]]; then
    echo ""; echo "Prompt context (${via}):"; echo ""
    printf '%s\n' "$prompt" | sed 's/^/> /'
  else
    echo "_Prompt unavailable (${via})._"
  fi
fi

lineage_emit_event "lineage.query.answered" \
  "$(jq -nc --arg pk "$PROJECT_KEY" --arg f "$FILE" --argjson m "$matches" \
     --argjson ln "${LINE:-0}" --arg via "$via" \
     '{project_key:$pk, file_path:$f, matches:$m, line:$ln, resolved_via:$via}')" "$QSID" || true
```

### `/lineage <file> --grep <text>` — content search

Same as the line mode, but set `needle` to the user's search text instead of
reading a line from the file:

```bash
FILE="REPLACE_WITH_FILE"; needle="REPLACE_WITH_TEXT"
[[ "$FILE" != /* && -n "$REPO_ROOT" ]] && FILE="$REPO_ROOT/$FILE"
rec=$(lineage_match_line "$PROJECT_KEY" "$FILE" "$needle")
# …render as in the line mode…
```

### `/lineage --status` — ledger stats

```bash
LEDGER=$(lineage_record_path "$PROJECT_KEY")
echo "## Lineage status"
echo "- Project key: ${PROJECT_KEY}"
echo "- Ledger: ${LEDGER}"
if [[ -f "$LEDGER" ]]; then
  total=$(wc -l < "$LEDGER" | tr -d ' ')
  files=$(jq -r '.file_path' "$LEDGER" 2>/dev/null | sort -u | grep -c '')
  echo "- Changes recorded: ${total} across ${files} file(s)"
else
  echo "- No changes recorded yet. Make some Edit/Write changes with lineage enabled."
fi
```

## Notes

- Provenance is **content-anchored**: a line is matched to the change whose added
  content contains it. If later edits moved or rewrote the line, the match is the
  most recent change that introduced the matching text — not a git-blame-exact
  mapping.
- The prompt is resolved lazily: historian's preserved per-session chunks first
  (durable across transcript cleanup), then the live `transcript_path`, then
  "unavailable." Install and enable historian for the most reliable prompts.
- Storage, project keying, and event emission match the other ecosystem plugins;
  everything is scoped by project key and honors `$ONLOOKER_DIR`.
