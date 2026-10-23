# False refusals — 2026-10-22

ONL-183. The [2026-10-19 record](../2026-10-19-justified-scope/README.md)
found that the justification step, not the jury, decides most of what gets
promoted unattended: it refused 10 of 14 and 9 of 12 parked candidates. A
refusal was a bare `REFUSE`, so nobody could tell right refusals from wrong
ones. #473 made the model give a reason. This run collects those reasons on
the same pinned corpus, and `labels.json` sorts each refusal into right or
wrong.

| | |
| --- | --- |
| corpus | **pinned**: the same 36 artifacts as 2026-10-17 and 2026-10-19, rebuilt from their recorded ids. All 36 were still in the live store |
| transform + judges | `claude-haiku-4-5-20251001`, rubric `lesson-promotion-public` |
| justification prompt | `librarian_lesson_auto_justify` as of #473: same rules as 2026-10-19, now asking for `REFUSE: <one sentence>` |
| transform prompt | sha256 `fee9c5d7249d…`. Moved since 2026-10-19's arm B (`e27a4e521506…`); #477's session-id handling is the one prompt-side change on main since then |
| judge prompt | sha256 `74abc6feaf5c…`. Also moved, so the gate figures below are **not** comparable with 2026-10-19 |

## Results

| | 2026-10-19 control | 2026-10-19 arm B | **2026-10-22** |
| --- | --- | --- | --- |
| proposed | 15 | 13 | 16 |
| parked | 14 | 12 | 14 |
| justification refused | 10 | 9 | **10** |
| juried | 5 | 4 | 5 |
| gate pass | 3/5 | 2/4 | 2/5 |

The refusal rate is still about 70%, the most stable figure across all three
runs. This time every refusal comes with a reason.

## Labels

Each refusal was labeled three ways: an agent draft, then a
`tribunal-judge-adversarial` pass that labeled blind from the raw candidates
before reading the draft and then attacked it, then a human ruling on the one
disagreement (R2). The draft and the judge agreed on the other 9.

**False refusals: 3 of 10.** At n=10 the 95% Wilson interval runs from about
11% to 60%, so this is a pilot. What it shows is the direction: most refusals are
right, and the false-refusal rate is not zero.

| | label | why |
| --- | --- | --- |
| R1 ollama embedding pipeline | right, *contested* | the latency figures cited are in the rationale; "acceptable overhead" is the only version-sensitive word in the claim |
| R2 historian chunking | **wrong**, *contested* | general claim; historian specifics only in the rationale |
| R3 lineage baseline sha | right | lineage's own mechanism |
| R4 `librarian_lesson_write_atomic` | right | one required remedy, named by an internal helper |
| R5 warn after an irreversible step | **wrong** | general practice; refused on the rationale |
| R6 tribunal skill instructions | right | tribunal-internal calls |
| R7 ZLesson dedup comment | right | an event, not a lesson |
| R8 tests named for a user story | **wrong** | general testing advice; refused on the rationale |
| R9 isolate bats from git config | right | `GIT_CONFIG_GLOBAL` needs git ≥ 2.32 |
| R10 GITHUB_TOKEN vs git config | right | the claim is false |

## What the labels show

**All three false refusals have the same shape.** The claim is general, the
rationale cites this repo's plugins, and the model refused on the rationale.
R1 is the same shape at the edge, which is why it is contested. Under a strict
reading where judging the rationale is fine, the rate is 2 of 10 (R2 flips back).
Under a loose one that also counts R1, it is 4 of 10.

**The prompt doesn't say which reading is right.** `librarian_lesson_auto_justify`
says "refuse unless the claim is true independent of any version", but it
hands the model the whole candidate: claim, rationale and evidence. Every
contested label in this record comes down to that ambiguity, so it is worth
more than any single rate here. Fixing it changes what gets refused, which is
out of ONL-183's scope. It is filed as ONL-187.

**The reasons are what made labeling possible.** Every one of the ten points at
a specific sentence of the candidate, so each label above could be checked
against the reason rather than re-derived from the claim. For the three false
refusals, the reason is also what exposes the mistake: each cites a detail
that appears only in the rationale. R4 and R9 cite the one-remedy rule, which
is a legitimate ground under the prompt, though for R9 the version dependency
was the stronger reason. R10's reason is a correctness objection, not a scope
one, and it is correct.

## Limits

- n=10 refusals from one run. The transform model is not deterministic, so a
  re-run produces different candidates and different refusals.
- Every refused candidate's stack includes at least one of this repo's own
  plugins, except R1, R9 and R10. The corpus is one project's artifacts, so
  "general claim, project-specific rationale" may be over-represented compared
  with a corpus mined from other repos.

## Re-measuring

As in [2026-10-19](../2026-10-19-justified-scope/README.md#re-measuring). The
corpus was rebuilt like this:

```bash
for id in $(jq -r '.candidates[].artifact_id' \
    ../2026-10-19-justified-scope/control/samples.json); do
  grep -rl --include='*.json' "\"id\": *\"$id\"" \
    "$ONLOOKER_DIR/archivist/ee2cfbe428c7" | head -1 | xargs -I{} cp {} <pinned dir>/
done
```

To pull out the refusals for labeling:

```bash
jq '.candidates[] | select(.confirm_outcome == "skipped:no_justification")
    | {artifact_id, claim: .candidate.claim, stack: .candidate.applies_to.stack,
       refusal_reason}' samples.json
```
