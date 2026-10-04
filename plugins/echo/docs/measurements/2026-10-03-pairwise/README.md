# Pairwise discrimination measurement — 2026-10-03

Raw artifacts from the ONL-103 run. 72 judge calls, `claude-haiku-4-5-20251001`,
`echo-judge-prompt.sh` at sha256
`6b583b00080f77d5b2a44eb7d6d59412f6f97863ddea7a0cf366b8c801918779`.

The analysis and the `stop` verdict are in
`docs/superpowers/specs/2026-10-03-echo-pairwise-discrimination-design.md`.

These are committed rather than left in scratch for one reason: the spec's
`cross_antisymmetry` counts a tie-against-a-preference as a failure, and says so. That
is a pre-registered choice, not a fact — counting only self-contradictory verdicts gives
96.7% instead of 56.7% and flips the verdict. Anyone who wants the number under a
different definition needs the per-pair verdicts, and re-deriving them costs 72 calls.

ADR-004 opens by complaining about a figure that "carried no methodology — no sample
count, no files, no date, no model — so it could neither be defended nor re-derived."
Keeping these closes that gap for this measurement.

| file | contents |
|---|---|
| `verdicts.json` | every verdict, per pair and per presentation order, plus `attempted` counts |
| `stats.json` | the computed rates and the kill verdict |

To re-measure on a different model or prompt:

```bash
plugins/echo/scripts/measure-pairwise-discrimination.sh --repeats 2 --out <dir> \
  .claude/skills/writing-tests/SKILL.md \
  plugins/lineage/skills/lineage/SKILL.md \
  plugins/tribunal/agents/tribunal-actor.md \
  plugins/tribunal/agents/tribunal-judge-adversarial.md \
  plugins/tribunal/agents/tribunal-judge-standard.md \
  plugins/tribunal/agents/tribunal-meta-judge.md
```

The corpus must stay these six files for the result to be comparable — the 0.61
signal-to-noise figure this was measured against comes from the same set (ONL-102).
