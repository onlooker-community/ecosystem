# Lesson self-check: catch a justification that defends the wrong claim

Linear: [ONL-311](https://linear.app/onlooker/issue/ONL-311). Bead: ecosystem-1z07vm.3.

## Problem

The unattended path (`librarian_lesson_auto_confirm_one`) asks a model to say
why an unscoped claim holds regardless of version, then confirms the candidate
with that sentence as its `version_independent` justification and sends it to
the jury. A person has vetoed six lessons that the jury approved:

| Lesson | Claim | Justification defends |
|---|---|---|
| 01M5KE1F | Report post-truncation length alongside original | "a fundamental observability principle" |
| 01M5KDV1 | Window oversized turns with clamped overlap | "a universal algorithmic principle" |
| 01M5K7HV | Test descriptions should match assertions | "a universal principle" |
| 01M6FJ2S | Export CLAUDE_SESSION_ID in skill Setup blocks | "exporting env vars… is independent of Claude Code versions" |
| 01M6D6NZ | Batch per-file jq/node calls into one emit-batch | "batching reduces per-invocation overhead regardless of versions" |
| 01M6FWN1 | Consolidate jq invocations into one read pass | "fundamental to how command-line tools work" |

In five of the six, the justification argues for a broader principle than the
claim states, and the jury scores the principle. 01M6FJ2S does the same and
also rests on two Claude Code behaviors that a release can change. Both judges
scored its `scope_accuracy` 0.82 and passed it (bead notes, 2026-11-05).

The justify prompt already says "Do not restate it as a more general principle
and judge that instead" (ONL-187). The model writes a principle anyway, inside
the same call that is told not to. A veto is the only thing that stops these
lessons, and a jury rejection is terminal.

## Goal

A second, separate model call checks the justification against the claim
before the confirm. A candidate that fails stays `pending`. It never reaches
the jury and nothing is declined, so its artifact survives.

## Non-goals

- **Turning it on.** It ships behind a flag that defaults to off. Turning it on
  in ecosystem before ONL-198's review would change ADR-004's criteria 2 (pass
  rate among juried candidates) and 3 (veto rate among held lessons) partway
  through the measurement. Whether to turn it on is a decision for that review.
- **Versioned candidates.** They carry no justification, so there is nothing to
  check.
- **Copying the adversarial judge.** Both judges passed 01M6FJ2S at 0.82, so a
  self-check that copies them would have passed it too.
- **Changing the justify prompt.** ONL-187 already tried that, and the
  instruction it added is the one being ignored.

## Design

### Where it runs

In `librarian_lesson_auto_confirm_one`, after `librarian_lesson_auto_justify`
returns a non-empty, non-`REFUSE` sentence and before `librarian_lesson_confirm`.
It runs only when `librarian.lesson_auto.self_check.enabled` is `true`.

### The call

`librarian_lesson_auto_self_check <candidate_json> <justification> [model]`,
in `librarian-lesson-auto.sh` beside the justify call, and built the same way:

- `claude -p --max-turns 1 --settings '{"disableAllHooks":true}'`
- the model from `.librarian.lesson_transform.model`
- the timeout from `.librarian.lesson_transform.timeout_seconds`
- no EXIT trap (ONL-118)

The instructions live in `_librarian_lesson_auto_self_check_preamble`, kept
apart from the data so the outcome can be fingerprinted.

The prompt gets the claim, the stack and the justification, and asks two
questions:

1. Does the justification argue that **this claim, as written** holds
   regardless of version, or does it argue for a more general principle that
   the claim is one instance of? Arguing for the principle fails.
2. Which behaviors of the tools in the stack, or of any other external tool,
   must stay true for the claim to hold? If any of them is something a release
   of that tool could change, the claim is not version-independent, and it
   fails.

Output: `PASS`, or `FAIL: <one sentence naming which question failed and why>`.

### Outcomes

| Response | Action | Prints |
|---|---|---|
| `PASS` | confirm, as today | `confirmed:<id>` |
| `FAIL…` | record `.auto_self_check`, leave `pending` | `skipped:self_check_failed` |
| (fingerprint matches a stored failure) | no call, nothing written | `skipped:self_check_held` |
| empty, or neither form | nothing written | `unavailable` |

A failure is never a decline, even under `on_refusal: decline`. A refusal is
the model's judgment about the claim. A self-check failure is about one
justification, and a later prompt or model may write a better one.

A response that is neither `PASS` nor `FAIL` is infrastructure, not a verdict.
Treating it as a pass would let a malformed answer send a candidate to the
jury, and treating it as a failure would hold one on noise.

### What a failure records

```json
"auto_self_check": {
  "reason": "<sentence after FAIL:, or null>",
  "justification": "<the sentence that failed>",
  "failed_at": "<ISO-8601>",
  "fingerprint": "<hash>"
}
```

The justification is kept because the reason refers to it. Without it, a
person reading `lessons show` would see an objection to a sentence they can't
see.

### Not paying twice

`librarian_lesson_auto_self_check_fingerprint [model]` hashes, with
`librarian_body_hash`:
- the self-check preamble
- the justify preamble
- the model

The check runs before the justify call, beside the existing refusal-fingerprint
check. If `.auto_self_check.fingerprint` matches, the function prints
`skipped:self_check_held` without calling the model. It is a separate outcome
from `skipped:self_check_failed`, so the stage counts a failure once, on the
scan that paid for it, and not again on every later scan. Rewriting either prompt
or changing the model re-asks each held candidate once, the same way a refusal
is held (ONL-112). A later `PASS` deletes `.auto_self_check`.

The skip applies only while the flag is on. With the flag off, the stored
record is ignored and the candidate goes through justify and confirm as it
does today.

### Event

`librarian.lesson.self_checked`:

```json
{"lesson_id": "...", "outcome": "passed|failed|unavailable", "reason_given": true}
```

`reason_given` appears only when `outcome` is `failed`. The reason itself
stays on the proposal, the same split `librarian.lesson.asserted` uses. A
fingerprint skip makes no call and emits nothing.

`librarian.autojury.complete` gains `self_check_failed` (an integer): fresh
failures this scan, not held skips. It is added as an optional property, not
a required one. The payload schema is `additionalProperties: false`, and a
librarian release that predates this change must still validate. A self-check
failure does not count toward `refused`. Both changes go to
`@onlooker-community/schema` first (event type, payload schema, role, TS
types), following schema#113. This repo then bumps the dependency. Registration
in `test/bus-coverage.json` is `expected`, because a bats test drives every
outcome.

### Review walk

`librarian_cli_lessons_show` (`librarian-cli.sh`, beside the `refused:` line)
prints:

```
self-check:  <reason or "(no reason given)">
             justification: <justification>
```

SKILL.md step 3 says what that line means: the unattended path wrote a
justification and its own check rejected it, so the candidate is waiting for a
person. The person can confirm it with a justification of their own.

### Config

`plugins/librarian/config.json`:

```json
"lesson_auto": { ..., "self_check": { "enabled": false } }
```

The value is read with `librarian_config_get`. Only the literal `true`
enables it.

## Testing

Bats tests in `test/bats/librarian-lesson-auto.bats`, with `claude` stubbed the
way the existing auto tests stub it:

- Flag off: one `claude` call (justify), confirmed, no `.auto_self_check`, no
  `self_checked` event.
- Flag on with `PASS`: two calls, confirmed, `self_checked` with outcome
  `passed`.
- Flag on with `FAIL: …`: stays `pending`; `.auto_self_check` holds the reason,
  the justification and the fingerprint. No row in `declined.jsonl` under
  `on_refusal: decline`. The event has outcome `failed` and `reason_given: true`.
- Next scan with the fingerprint unchanged: zero `claude` calls, prints
  `skipped:self_check_held`, no event, and the stage's `self_check_failed`
  count is 0.
- Fingerprint changed (a different model): asks again.
- Garbage or empty response: `unavailable`, nothing written.
- The dispatched stdin is diffed against `_librarian_lesson_auto_self_check_preamble`
  plus the data block, to pin the prompt the way the judge prompt is pinned.
- The stage counts a failure in `self_check_failed`, not `refused`.
- `lessons show` prints the `self-check:` line.

## Measurement

The acceptance criterion requires the cost of a self-check measured against a
judge dispatch. The measurement goes in
`plugins/librarian/docs/measurements/2026-11-24-self-check/`:

- A `run.sh` that feeds each lesson's claim, stack and stored justification
  through the production prompt builder, with `--output-format json` to read
  `total_cost_usd`.
- **Recall:** the six vetoed lessons. Each should `FAIL`.
- **False fails:** lessons the jury approved that nobody vetoed. The store
  holds only one model-asserted lesson like that (01M5KDAW), so the control set
  also takes the four version-independent lessons a person justified that the
  jury approved: five lessons in all. Each should `PASS`. Five is thin, and the
  README says so.
- **Held early (optional):** the 39 model-asserted lessons the jury rejected.
  These have no ground truth, so the run reports only how many the self-check
  would have held before paying for a jury.
- **Cost:** median `total_cost_usd` per self-check, against the judge cost in
  `2026-10-24-unattended-run/` ($0.056–0.081 per judge, and $0.063 for the
  justify call). Expect roughly half the cost of a two-judge jury, not a small
  fraction of it.
- The README records the counts, the cost ratio, and every false fail verbatim.

The recall and false-fail groups are 11 real Haiku calls, about $0.70. The
held-early group adds 39 calls, about $2.50, and runs only with a separate
go-ahead. Everything runs once the prompt is pinned and before the PR opens.
If recall is low or false fails are high, the prompt is revised and the run
repeated. The flag stays off either way.

## Risks

- **Pending growth.** Under `on_refusal: decline`, a refused candidate is
  retired, but one that fails the self-check stays pending and counts at
  SessionStart. The measurement's false-fail rate shows how much this matters.
  If it is high, declining a candidate after N failures across distinct
  fingerprints is a follow-up, not part of this change.
- **The same model may share the blind spot.** The self-check uses the model
  that wrote the justification. The questions are narrower than the justify
  prompt's, and the recall run is what shows whether that is enough. ONL-110's
  model-tier child (1z07vm.5) is the follow-up if it isn't.
- **Release resets.** A librarian release restarts librarian-session-start's
  session count for the SessionStart milestone. The hook is at 189ms on 0.29.0,
  well under its 300ms budget, so that is accepted.
