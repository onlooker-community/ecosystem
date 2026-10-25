# The unattended run with hooks off — 2026-10-24

ONL-195. The [unattended-run record](../2026-10-24-unattended-run/README.md)
found that every `claude -p` librarian starts also ran every other plugin's
hooks, and those nested sessions made 59–66% of the spend. Every plugin's
`claude -p` now passes `--settings '{"disableAllHooks":true}'`. This is the same
stage run repeated on this checkout to re-baseline the cost.

| | |
| --- | --- |
| plugin | this checkout's `plugins/librarian`, which includes ONL-194's extractor fix |
| candidates | the same three parked candidates as the unattended-run record |
| harness | that record's `run.sh` and `reduce.sh`, unchanged, with `max_juries_per_scan: 2` |

## Result

| | unattended run | hooks off |
| --- | ---: | ---: |
| librarian's calls | 7 | 7 |
| nested hook calls | 12 | **0** |
| librarian's spend | $0.443 | $0.384 |
| nested spend | $0.649 | **$0** |
| total | $1.092 | **$0.384** |
| juries returning a verdict | 1 of 2 | 2 of 2 |
| wall clock | 396 s | 302 s |

Nothing nested ran at all: the shim recorded no call below depth 0. The kept
`librarian.*` events are the stage's own eight; the unattended run kept 42, and
the other 34 came from librarian's own hooks firing inside nested sessions.

librarian's own calls also got cheaper. With no SessionStart hook injecting
context, each one carried about 3.4k fewer cache-creation tokens. A direct pair
of one-line calls measured 15,893 against 19,277.

## The verdicts

| candidate | unattended run | hooks off |
| --- | --- | --- |
| `01M5K7JM…` echo stats `stop` verdict | rejected, 0.862 | refused at justification |
| `01M5KD41…` `${v:-N}` under `set -u` | `unavailable` (extractor) | rejected, `jury_not_majority`, 0.864, failed `grounding` |
| `01M5KD7A…` validate at both boundaries | deferred by the cap | rejected, `jury_not_majority`, 0.848, failed `grounding` |

`01M5KD41…` is the candidate ONL-194's extractor kept losing. It now gets a
verdict in a real run, not just in a replay.

Across both records, all three juried model-asserted candidates failed on
`grounding`. Three verdicts is still not a pass rate, but it is the pattern
ADR-004's second criterion says to check before blaming the candidates
(ONL-168).

## Cost per shipped lesson, re-baselined

A juried candidate now costs about $0.17: one justification at $0.04–0.05 and
two judges at $0.04–0.08 each. A candidate refused at justification costs about
$0.04. At a 20% pass rate that is roughly $0.85 per shipped lesson, against
$2.40 before.
