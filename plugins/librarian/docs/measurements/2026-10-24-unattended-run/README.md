# One real unattended run — 2026-10-24

ONL-115 asks three questions before `lesson_auto` is enabled anywhere. This run
answers the first two by measuring them. The third is a decision, recorded in
[ADR-004's Validation section](../../adr/004-a-model-may-assert-version-independence.md#validation),
and it uses the numbers below.

| | |
| --- | --- |
| plugin | the **installed** librarian 0.26.1, sourced from the plugin cache, not this checkout |
| candidates | copies of three real parked `unscoped` candidates from this repo's queue |
| isolation | a throwaway `ONLOOKER_DIR`; the real lesson store is read, never written |
| model calls | real `claude -p`, through a pass-through shim that adds `--output-format json` and keeps each call's accounting |
| runs | **stage**: `librarian_lesson_auto_stage`, the whole stage-6 path, with `max_juries_per_scan: 2`. **judge**: `librarian_lesson_auto_judge_one` alone on two candidates confirmed as model assertions, because the stage's cap left one unjudged |

`run.sh` reproduces either run (`MODE=judge` for the second); `reduce.sh` turns
its raw output into what is committed here. Nested hooks' responses summarize
the operator's event log and instruction files, so only their accounting is
kept.

## 1. Does `--max-turns 1` starve a judge? No

All 8 judge dispatches across both runs ended in one turn with
`subtype: success` and a non-empty response of 525–3385 characters. None tried a
tool call. The judges have `Read, Grep, Glob`, and their instructions say to read
the changed files, but the lesson prompt is fully inline and there is nothing
for them to read. That is still a property of today's prompt, as ONL-115 said.
It held in every dispatch measured.

**What did go wrong was the parsing, not the turn limit.** 3 of the 8 verdicts
came back `unavailable`, all for the same candidate (`01M5KD41…`). Its claim
quotes `${v:-N}`, and when a judge restates the claim in prose before its
verdict, `_librarian_lesson_extract_json_object` returns the first balanced
brace pair in the response, `{v:-N}`, instead of the fenced JSON after it. The
verdict JSON is there and is well formed. Replaying the extractor on the stored
responses reproduces it exactly: 5 of 8 parse, and the 3 failures all return
`{v:-N}`.

The consequence is the one ONL-115 predicted for a starved judge: an
`unavailable` jury leaves the candidate `confirmed`, so it is judged again on
every scan, at full cost, with the same result. Any lesson about bash parameter
expansion triggers it, and this repo's lessons are mostly about bash. This
blocks enabling, and is ONL-194.

## 2. Does `--model` override the agent's pinned model? Yes

Both tribunal judges pin `model: claude-opus-4-7` in their frontmatter. Every
`--agent` dispatch passed `--model claude-haiku-4-5-20251001`, and every one
reports `claude-haiku-4-5-20251001` as the only model in `modelUsage`. Opus
never appears in either run, in librarian's calls or in the nested ones.

| call | n | cost per call |
| --- | ---: | --- |
| justification (`lesson_transform.model`) | 3 | $0.055–0.063 |
| judge (`lesson_auto.judge_model`) | 8 | $0.056–0.081 |

The flag only overrides the model when it is passed. The first attempt at this
run forgot `CLAUDE_PLUGIN_ROOT`, the loader read every shipped default as empty,
and the justification calls went out with no `--model`. They ran on the
session's default model (Opus 5.5, $0.29–0.30 per call, about 5× the Haiku
cost). Production hooks always set `CLAUDE_PLUGIN_ROOT`, so this is not a live
defect, but it means a blank `judge_model` costs more rather than failing.

## What the questions did not ask: every model call runs the whole hook suite

`claude -p` starts a full Claude Code session, and every installed plugin's
hooks fire inside it. Only librarian checks its own `LIBRARIAN_NESTED` guard.
So each of librarian's calls also runs cartographer, counsel and assayer, which
make model calls of their own, and their sessions run the hooks again, up to
three levels deep. This is ONL-195.

| run | librarian's calls | cost | nested hook calls | cost | nested share |
| --- | ---: | ---: | ---: | ---: | ---: |
| stage | 7 | $0.443 | 12 | $0.649 | 59% |
| judge | 4 | $0.273 | 10 | $0.542 | 66% |

The real event log shows this is not caused by the harness. Since 2026-10-17,
226 sessions opened with one of librarian's prompts. Each of them emitted
`session.start`, `session.end`, a curator scan, historian indexing and a bursar
record, and 117 of them ran an assayer audit of librarian's own output.

The per-call prompt is also mostly overhead: librarian's calls averaged 16–17k
cache-creation tokens each, which is the session preamble, not the lesson.

## The jury's verdicts

| candidate | stage run | judge run |
| --- | --- | --- |
| `01M5K7JM…` echo stats `stop` verdict | rejected, `jury_not_majority`, aggregate 0.862 | — |
| `01M5KD41…` `${v:-N}` under `set -u` | `unavailable` (extractor) | `unavailable` (extractor) |
| `01M5KD7A…` validate at both boundaries | deferred by the cap | rejected, `jury_not_majority`, aggregate 0.851, failed `grounding` (0.76 and 0.74) |

The justification step accepted all three candidates on Haiku. No model-asserted
candidate passed the `-auto` rubric. Two verdicts is not a pass rate, but both
rejections fail on `grounding`, the criterion a judge without the repo can least
check (ONL-168).

## Not measured

- The hold, the veto window and `sweep_held` did not run, because nothing passed
  the jury.
- Wall-clock: the stage took 396 s for three candidates. It runs in the detached
  worker (ADR-003), so this run does not show how that interacts with SessionEnd.
- Two `run.sh` processes started at once left the stage run with an empty queue.
  The runs here were made one at a time. The cause was not investigated: in production
  the classify worker takes a per-queue lock, so two scans never overlap.
