---
description: List all prompt rules (global + project) with their pattern, guidance, and per-session fire status. Use when asked which prompt rules are active, why a rule did or didn't fire, or to debug the prompt-rule-injector hook.
disable-model-invocation: true
allowed-tools: Bash(bash *)
---

# List prompt rules

```!
bash -c '
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/validate-path.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/prompt-rules.sh"
prompt_rules_list_table "${CLAUDE_SESSION_ID}" "$(pwd)"
'
```
