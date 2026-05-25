---
name: tribunal
description: Run a task under multi-agent quality gates. Spawns the tribunal-actor subagent, a jury of typed Judges, and a Meta-Judge; aggregates verdicts under a configurable gate policy; retries the Actor with critique on rejection until acceptance or max_iterations. Use when the user explicitly wraps a task with /tribunal, or wants stronger correctness/safety review than a single pass. Emits the full tribunal.* canonical event stream.
---

# Tribunal: Multi-Agent Execution with Quality Gates

You are orchestrating a **Tribunal** evaluation loop. A user task gets wrapped in: **Actor → Jury → Meta-Judge → Gate**, retrying the Actor with feedback until the gate passes or `max_iterations` is reached.

## Setup

Before the loop, source the plugin's bash helpers and load config. Run this once at the start:

```bash
set -uo pipefail
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-config.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-rubric.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-jury.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-aggregate.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-gate.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-events.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-verdict.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-project-key.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tribunal-ulid.sh"

tribunal_config_load "$(pwd)"
tribunal_rubric_load "$(pwd)"
```

Parse the task description from the user's prompt arguments. If the user passed `--rubric=<id>`, use that; otherwise use `tribunal_rubric_default_id`.

Resolve the active rubric with `tribunal_rubric_get "$rubric_id"`. Validate it with `tribunal_rubric_validate "$rubric"`. If validation fails, abort with `tribunal.session.complete` outcome `aborted` and tell the user why.

## Per-task initialization

Generate identifiers and persist task-level state:

```bash
task_id=$(tribunal_ulid)
project_key=$(tribunal_project_key "$(pwd)")
remote=$(tribunal_project_remote_url "$(pwd)")
repo_root=$(tribunal_project_repo_root "$(pwd)")
tribunal_write_project_manifest "$project_key" "$remote" "$repo_root"
tribunal_write_task_manifest "$project_key" "$task_id" "$task_summary" "$rubric_id" "$rubric"
```

Emit `tribunal.session.start` with the resolved config (`judge_types`, `gate_policy`, `score_threshold`, `max_iterations`, model IDs).

## The loop

For `iteration_number` from `0` while `iteration_number < max_iterations`:

1. **Iteration start.** Generate `iteration_id=$(tribunal_ulid)`. `trigger` is `"initial"` for n=0, `"gate_blocked"` for retries. Initialize the iteration directory (creates `verdicts/` subdirectory):
   ```bash
   tribunal_init_iteration "$project_key" "$task_id" "$iteration_id"
   ```
   Emit `tribunal.iteration.start`.

2. **Actor.** Emit `tribunal.actor.start`. Use the Task tool to spawn `tribunal-actor` with:
   - The task description.
   - The rubric criteria (just `name` + `weight` + `min_pass`).
   - On retries: a digest of the prior iteration's consensus, dissent (if any), and Meta-Judge override.

   Capture the Actor's final output. **`$actor_output` must be the verbatim, complete text returned by the Agent tool — never a summary, paraphrase, or placeholder string.** Persist it:
   ```bash
   tribunal_write_actor_output "$project_key" "$task_id" "$iteration_id" "$actor_output"
   ```
   Emit `tribunal.actor.complete` with `success: true` and the inferred `artifact_kind` (`file` / `patch` / `message` / `command`).

3. **Empanel the jury.** Resolve the panel from configured types:
   ```bash
   types=$(tribunal_config_get_json '.tribunal.session.judge_types')
   # Rubric may override:
   rubric_types=$(printf '%s' "$rubric" | jq -c '.judge_types // empty')
   [[ -n "$rubric_types" && "$rubric_types" != "null" ]] && types="$rubric_types"
   jury=$(tribunal_jury_empanel "$types")
   ```
   Persist the jury and emit `tribunal.jury.empaneled`:
   ```bash
   tribunal_write_iteration_artifact "$project_key" "$task_id" "$iteration_id" "jury" "$jury"
   tribunal_jury_to_schema_judges "$jury"  # pass result as judges[] in the event
   ```

4. **Run each Judge.** For each entry in the jury panel:
   - Emit `tribunal.judge.start` with `judge_id`, `judge_type`, `judge_model_id`.
   - Spawn the judge subagent (`.subagent` field) with the Actor output + rubric.
   - Parse the JSON object the judge returns. Augment it with `task_id`, `iteration_id`, `judge_id`, `judge_model_id` from the panel entry, and `judge_type` from the panel entry (canonical, overriding what the agent self-reported).
   - Emit `tribunal.verdict` with that payload.
   - **Persist the verdict. This call is required for every judge on every iteration — including retries:**
     ```bash
     tribunal_write_judge_verdict "$project_key" "$task_id" "$iteration_id" "$judge_id" "$verdict_json"
     ```

   Collect the verdicts into a JSON array `verdicts`.

   **Before moving to step 5, verify all per-iteration artifacts are on disk:**
   - `iteration-<id>/actor.md` — verbatim actor output (written in step 2)
   - `iteration-<id>/jury.json` — jury panel (written in step 3)
   - `iteration-<id>/verdicts/<judge_id>.json` — one file per judge (written in step 4)
   - `iteration-<id>/gate.json` — written by the gate step (step 7)

5. **Aggregate + dissent.**
   ```bash
   method=$(printf '%s' "$rubric" | jq -r '.aggregation_method // "weighted_mean"')
   threshold=$(printf '%s' "$rubric" | jq -r '.score_threshold // 0.75')
   dissent_threshold=$(tribunal_config_get '.tribunal.session.dissent_threshold')
   [[ -z "$dissent_threshold" ]] && dissent_threshold="0.25"

   aggregated=$(tribunal_aggregate "$method" "$verdicts" "$rubric")
   dissent=$(tribunal_disagreement "$verdicts")
   ```
   Build and emit `tribunal.consensus.reached`. If `dissent > dissent_threshold`, emit `tribunal.dissent.recorded` (set `resolution` to `null` for now — the Meta-Judge may set it on the next step via `override_recommendation`).

6. **Meta-Judge.** Emit `tribunal.meta.start`. Spawn `tribunal-meta-judge` with the verdicts and the Actor output. Parse its JSON; augment with `task_id`, `iteration_id`, `meta_model_id`. Emit `tribunal.meta.complete`. Persist.

7. **Gate.**
   ```bash
   policy=$(printf '%s' "$rubric" | jq -r '.gate_policy // "majority"')
   gate=$(tribunal_gate_decide "$policy" "$verdicts" "$aggregated" "$threshold" "$meta" "$dissent" "$dissent_threshold")
   ```
   If `gate.passed == true`, emit `tribunal.gate.passed` with `final_score: aggregated` and break the loop with outcome `accepted`. Otherwise emit `tribunal.gate.blocked` with the `reason`, `will_retry: (iteration_number + 1 < max_iterations)`, and `retry_iteration_number` if retrying. Persist `gate.json` either way.

   If blocking and retrying, build the retry digest (lowest-scoring criteria + meta override + dissent summary) and feed it into the next iteration's Actor prompt.

## Termination

When the loop exits:

- `accepted` — gate passed.
- `exhausted_iterations` — loop ran `max_iterations` without acceptance.
- `aborted` — orchestrator caught an unrecoverable error (rubric validation failed, Actor subagent crashed twice, etc.). Set this explicitly when you catch errors; do not silently swallow.

Emit `tribunal.session.complete` with `outcome`, `final_score`, `iterations_used`, `total_duration_ms`. Skip `total_cost_usd` in v0.1 — the runtime does not surface subagent costs to the orchestrator yet.

## Summary to the user

After emitting `session.complete`, render a compact markdown summary to the user:

- Verdict (✓ accepted / ✗ rejected / ⏱ exhausted / ⚠ aborted) with final score.
- Per-iteration table: iteration | per-judge scores | dissent | gate result.
- Meta-Judge bias notes if any.
- Path to the persisted artifacts (`~/.onlooker/tribunal/<key>/<task_id>/`).

Keep the summary terse. The artifacts on disk are the long form.

## Error handling

- If a judge subagent fails to return parseable JSON, treat that judge as `score: 0, passed: false, confidence: 0` and surface the parse error in `feedback_summary`. Do not abort the iteration — let the gate decide.
- If the Meta-Judge fails, default to `verdict_quality: "questionable", bias_detected: false` so the gate falls back to score-based logic.
- If event emission fails (schema validation), keep going and write a warning to stderr. The persisted artifacts on disk are still trustworthy.
