---
name: tribunal
description: Run a task under multi-agent quality gates. Spawns the tribunal-actor subagent, a jury of typed Judges, and a Meta-Judge; aggregates verdicts under a configurable gate policy; retries the Actor with critique on rejection until acceptance or max_iterations. Use when the user explicitly wraps a task with /tribunal, or wants stronger correctness/safety review than a single pass. Emits the full tribunal.* canonical event stream.
---

# Tribunal: Multi-Agent Execution with Quality Gates

You are orchestrating a **Tribunal** evaluation loop. A user task gets wrapped in: **Actor → Jury → Meta-Judge → Gate**, retrying the Actor with feedback until the gate passes or `max_iterations` is reached.

## Setup

Every block below needs the plugin's bash helpers and config. The Bash tool may be zsh and keeps no functions between calls, so send this block inside `bash`, in one call:

```text
bash <<'ONLOOKER_SKILL'
<this Setup block>
<the block you are running>
ONLOOKER_SKILL
```

```bash
set -uo pipefail
export CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID}"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-config.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-rubric.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-jury.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-aggregate.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-gate.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-events.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-verdict.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-resolve.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/tribunal-ulid.sh"

tribunal_config_load "$(pwd)"
tribunal_rubric_load "$(pwd)"
```

Parse the task description from the user's prompt arguments. If the user passed `--rubric=<id>`, use that; otherwise use `tribunal_rubric_default_id`.

Resolve the active rubric with `tribunal_rubric_get "$rubric_id"`. Validate it with `tribunal_rubric_validate "$rubric"`. If validation fails, abort with `tribunal.session.complete` outcome `aborted` and tell the user why.

## Per-task initialization

Generate identifiers and persist task-level state:

```bash
task_id=$(tribunal_ulid)
project_key=$(onlooker_project_key "$(pwd)")
remote=$(onlooker_project_remote_url "$(pwd)")
repo_root=$(onlooker_project_repo_root "$(pwd)")
tribunal_write_project_manifest "$project_key" "$remote" "$repo_root"
tribunal_write_task_manifest "$project_key" "$task_id" "$task_summary" "$rubric_id" "$rubric"
```

Emit `tribunal.session.start` with the resolved config (`judge_types`, `gate_policy`, `score_threshold`, `max_iterations`, model IDs).

Then record what is already dirty in the worktree, so that a discard at the end of the run can leave it alone:

```bash
task_dir=$(tribunal_task_dir "$project_key" "$task_id")
tribunal_baseline_write "$task_dir" "$(pwd)"
```

Remember whether it succeeded. It fails outside a git worktree or before the first commit, and then the end-of-run question doesn't offer Discard.

On a retry (see "Resolving a run the jury did not accept"), copy the previous run's baseline instead of writing a new one: `cp "$previous_task_dir/baseline.json" "$task_dir/"`. The previous run's edits are on disk by then. A fresh baseline would count them as work from before the run, and a later discard would never remove them.

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

   Capture the Actor's final output. **`$actor_output` must be the verbatim, complete text returned by the Task tool — never a summary, paraphrase, or placeholder string.** Persist it:
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
   schema_judges=$(tribunal_jury_to_schema_judges "$jury")  # pass $schema_judges as judges[] in the event
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

   **Before moving to step 5, verify all artifacts written so far are on disk:**
   - `iteration-<id>/actor.md` — verbatim actor output (written in step 2)
   - `iteration-<id>/jury.json` — jury panel (written in step 3)
   - `iteration-<id>/verdicts/<judge_id>.json` — one file per judge (written in step 4)

   (`iteration-<id>/gate.json` is written in step 7 — verify it there.)

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
   gate=$(tribunal_gate_decide "$policy" "$verdicts" "$aggregated" "$threshold" "$meta" "$dissent" "$dissent_threshold" "$rubric")
   ```
   If `gate.passed == true`, emit `tribunal.gate.passed` with `final_score: aggregated` and break the loop with outcome `accepted`. Otherwise emit `tribunal.gate.blocked` with the `reason`, `will_retry: (iteration_number + 1 < max_iterations)`, and `retry_iteration_number` if retrying. **Whenever `gate.failed_criterion` is present, copy it onto the event payload as `failed_criterion` — whatever the `reason` is.** The gate names the criterion on **every** blocking arm, not only when `criterion_floor` won the precedence contest: a criterion scored far below its floor also drags the aggregate under `score_threshold`, so the *worst* failures surface as `low_score`. Copying it only on `criterion_floor` drops the diagnostic precisely where it matters most. That now holds for the Meta-Judge's short-circuit returns too (`bias_detected`, and the early `meta_override` / `dissent_unresolved` arms), so an absent `failed_criterion` means no floor was violated — one reason string never reports two different ways depending on which return produced it. Persist `gate.json` either way.

   A `criterion_floor` block means the aggregate *cleared* its threshold and one criterion still failed its floor. Say so when you report it: "blocked on `safety` (0.30 < 0.80) despite an overall 0.82" is actionable, "blocked" is not.

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

## Resolving a run the jury did not accept

When the outcome is `rejected` or `exhausted_iterations`, the actor's changes are still on disk. After the summary, ask the person what to do with them, in one `AskUserQuestion`:

- **Question:** "The jury didn't accept this. What should happen to the changes?"
- **Keep the changes:** "Leave everything as it is."
- **Discard them:** "Restore the files this run changed. Files that already had changes before it started are left alone." Offer this only when the baseline was written.
- **Retry:** "Run the task again with the same settings, for up to `<max_iterations>` more iterations."

Then act on the answer:

- **Keep:** emit `decision: kept`. This is the override a calibrator reads.
- **Discard:** run `tribunal_discard "$task_dir"`.
  - **Exit 0:** the first line is `<restored> <left>`. Each remaining line is a file that had changes before the run and that the actor changed again. Tell the person how many files were restored, and name each file that was left alone so they can sort it out by hand. Emit `decision: discarded` with both counts.
  - **Exit 2:** `HEAD` moved during the run, so the actor committed. Tell the person nothing was restored, and that the commit has to be undone by hand. Emit nothing: the discard they chose didn't happen.
  - **Exit 1:** the baseline is missing or unreadable. Tell the person nothing was restored, and emit nothing.
  - **Exit 3:** some files couldn't be restored. They're named on stderr as `tribunal: could not restore <path>`. Stdout is as for exit 0. Tell the person what was restored, which files are left alone, and which couldn't be restored, so they can fix those by hand. Emit `decision: discarded` with the stdout counts, since a discard did happen.
- **Retry:** emit `decision: retried`. Then start again from "Per-task initialization", with the same task description, rubric and config, carrying the baseline forward as described there. The new run has its own `task_id`.
- **No answer** (dismissed, or a reply that is none of the three): emit nothing. A rejection without `tribunal.session.resolved` reads as unanswered. Never record a guess.

Emit a keep or a retry with three arguments, and a discard with its two counts:

```bash
payload=$(tribunal_resolved_payload "$task_id" "$outcome" kept)
payload=$(tribunal_resolved_payload "$task_id" "$outcome" discarded "$restored" "$left")
tribunal_emit_event "tribunal.session.resolved" "$payload"
```

The Setup block runs under `set -u`, so don't pass `"$restored" "$left"` when they were never set. Each block runs in a new shell, so set `project_key`, `task_id` and `task_dir` again from the values you noted.

Never ask after `accepted` or `aborted`.

## Error handling

- If a judge subagent fails to return parseable JSON, treat that judge as `score: 0, passed: false, confidence: 0` **and give it a `criterion_scores` object assigning `0` to every criterion in the active rubric.** Surface the parse error in `feedback_summary`. Do not abort the iteration — let the gate decide. A crashed judge was dispatched and produced nothing — that is the "assessed and failed" case, not the "did not assess" case. Omitting `criterion_scores` (or sending `{}`) would make the crash invisible to `weighted_mean`, which never reads `.score`, and the panel would score as though the judge had never been empaneled.
- If the Meta-Judge fails, default to `verdict_quality: "questionable", bias_detected: false` so the gate falls back to score-based logic.
- If event emission fails (schema validation), keep going and write a warning to stderr. The persisted artifacts on disk are still trustworthy.
