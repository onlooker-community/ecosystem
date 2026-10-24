# Judging the claim — 2026-10-23

ONL-187. The [2026-10-22 record](../2026-10-22-false-refusals/README.md) found
that every false refusal had the same shape. The claim was general, the
rationale cited this repo's plugins, and the model refused because of the
rationale. `librarian_lesson_auto_justify` said "refuse unless the claim is
true" but gave the model the whole candidate, without saying which part was
being judged.

This run measures two rewrites of the prompt that both say so. The second one
shipped.

| | |
| --- | --- |
| design | **paired**: only the justification step, re-run on the 14 parked candidates recorded in 2026-10-22's `samples.json`, 3 runs each |
| model | `claude-haiku-4-5-20251001` |
| labels | 2026-10-22's `labels.json`, R1–R10, unchanged |
| baseline | 2026-10-22's single run with the old prompt. It was **not** re-run, so its run-to-run spread is unknown |

Pairing on the same candidates removes transform noise, which a full harness
re-run brings with it: each re-run produces different candidates. The cost is
that only the justification step is measured. There are no gate figures here.

## The two arms

**v1** added: *Judge the claim line. The rationale, resolution and stack are
evidence about the claim, not what is being judged. A rationale that cites a
specific project, plugin or helper records where the lesson was learned, and
that is not by itself a reason to refuse. Refuse on the evidence only when it
shows the claim itself depends on a version.*

**v2** (shipped) prefixes v1 with: *Judge the claim line, as written. Do not
restate it as a more general principle and judge that instead. A claim that
names a project's own plugin, helper or internal mechanism is project-specific:
refuse it.*

## Results

Each cell shows one outcome per run, refused (`R`) or accepted (`A`). There
were no empty responses in either arm.

| | label | old (1 run) | v1 | v2 |
| --- | --- | --- | --- | --- |
| R1 ollama embedding pipeline | right | R | RRR | ARA |
| R2 historian chunking | **wrong** | R | AAA | RAA |
| R3 lineage baseline sha | right | R | AAA | RRR |
| R4 `librarian_lesson_write_atomic` | right | R | RRA | RRR |
| R5 warn after an irreversible step | **wrong** | R | AAA | RAA |
| R6 tribunal skill instructions | right | R | AAA | AAR |
| R7 ZLesson dedup comment | right | R | RRR | RRR |
| R8 tests named for a user story | **wrong** | R | AAA | AAA |
| R9 isolate bats from git config | right | R | AAA | AAA |
| R10 GITHUB_TOKEN vs git config | right | R | AAR | RAR |
| `jq -r` pretty-prints | — | A | AAA | ARR |
| watch-unmatched scanner | — | A | AAA | RAA |
| concurrent agents, run ids | — | A | AAA | ARA |
| concurrent hooks, file locking | — | A | AAA | AAA |

The four unlabeled rows were accepted under the old prompt and went to the
jury. Two of v2's refusals there are right. The `jq -r` claim is false, since
jq pretty-prints by default and `-r` plays no part, and the jury had already
failed it on grounding. "watch-unmatched scanner" is this project's term, and
the jury failed it on scope. The refusal of the run-id claim is wrong: those
are generic mechanisms, and that candidate passed the gate.

| errors per 14-candidate run | old | v1 | v2 |
| --- | --- | --- | --- |
| false refusals (R2, R5, R8, run ids) | 3 | 0 | 1.0 |
| missed refusals (R1, R3, R4, R6, R7, R9, R10, `jq -r`) | 1 | 5 | 3.0 |
| **total** | **4** | **5** | **4.0** |

## What this shows

**v1 overcorrected.** It removed every false refusal and lost R3 and R6
outright. Both of those claims name this repo's own mechanism, and the model
restated each as a general principle and judged that instead. For example,
"explicit instructions to an LLM are interpreted more reliably than vague
shorthand". v2's added sentences target exactly that, and R3 and R4 came back
in every run.

**v2 ties the old prompt on total errors and shifts the mix.** Its errors
lean toward accepting when they should refuse, where the old prompt's leaned
the other way. A missed refusal still faces the adversarial jury. A false
refusal leaves a good lesson `pending` for a human and, while ONL-112 is
open, is billed again on every scan. So on this sample v2 does not have fewer
errors. It has errors that a later stage can catch, and it has a stated rule,
which is what made every contested label in 2026-10-22 contestable.

**R9 is a blind spot in every arm.** `GIT_CONFIG_GLOBAL` needs git ≥ 2.32, and
no prompt noticed. The old prompt refused R9 for a weaker reason (the
one-remedy rule).

## Limits

- n=14 candidates, 10 of them labeled. At this size the totals cannot be told
  apart. Read the direction of the change, not its size.
- v2 was written after seeing v1's misses on these same candidates, so it is
  tuned to this set. A fresh corpus is the real test.
- The baseline is one run. The old prompt was not re-run three times, so its
  spread is unknown, and every "old" figure above is a single observation.
- The model is not deterministic. v2 disagreed with itself on 8 of 14
  candidates across three runs.

## Re-measuring

`v1.json` and `v2.json` hold every response. The runner sources
`librarian-config.sh` and `librarian-lesson-auto.sh` from the plugin under test,
sets `ONLOOKER_DIR` to a throwaway directory and `LIBRARIAN_NESTED=1`, then
calls the function on each parked candidate:

```bash
jq -c '.candidates[] | select(.confirm_outcome != null) | {artifact_id, candidate}' \
  ../2026-10-22-false-refusals/samples.json |
while IFS= read -r row; do
  librarian_lesson_auto_justify "$(jq -c .candidate <<<"$row")" claude-haiku-4-5-20251001
done
```

Run it three times per arm. To get a proper baseline, run the pre-ONL-187
prompt (`git show 20b3958:plugins/librarian/scripts/lib/librarian-lesson-auto.sh`)
the same way.
