# ADR-002: Agent definitions are shared assets; hooks are not

## Status

Accepted.

## Context

CLAUDE.md states: "Plugins communicate by emitting events to the JSONL log —
they do not call each other directly. All plugins depend on the ecosystem
substrate; no plugin depends on another plugin directly."

Lesson judging (`ecosystem-4z8.3`) needs a jury. Tribunal ships three judge
agent definitions and the rubric vocabulary. The stage couples librarian and
tribunal in some direction no matter how it is arranged: either librarian
reaches for tribunal's judges, or tribunal reaches into librarian's
project-keyed proposal files and writes verdicts back into them.

## Decision

The invariant forbids **runtime** coupling — one plugin's hook or library
calling another's, which makes one plugin's failure another's. It does not
forbid reusing a **published agent definition** by name.

Librarian therefore owns the `judge` verb, both rubrics, the aggregate, and the
gate decision, and dispatches `tribunal-judge-standard` and
`tribunal-judge-adversarial` by name.

Librarian does **not** source any file under `plugins/tribunal/`. It implements
its own aggregate and gate — roughly twenty lines — rather than calling
`tribunal_aggregate` or `tribunal_gate_decide`.

## Rationale

An agent definition is declarative: a markdown file with frontmatter and a
prompt. It has no runtime surface and cannot fail at call time in a way that
propagates — the harness resolves it, librarian never invokes tribunal's code
directly. That is a real difference from sourcing tribunal's bash, where a
signature change to `tribunal_gate_decide` breaks librarian mid-call and
neither plugin's tests would catch it.

It is a weaker guarantee than depending on a published schema, though.
`@onlooker-community/schema` is registered and drift-checked in CI (see
[ADR-005](../../../../docs/adr/005-runtime-emitter-fails-open.md)): a breaking
change to it fails a build before it ships. A judge agent's prompt carries no
such contract — nothing in either plugin's test suite stops a maintainer from
narrowing or repurposing what `tribunal-judge-standard` returns without
touching the agent's name. Calling that "closer to a published schema than to
calling another plugin's code" overstated the guarantee; only the *loud*
failure modes — the judge being renamed or removed — actually behave like a
schema break. See Consequences for what happens when the drift is quiet
instead.

Keeping the lifecycle in librarian also keeps `ecosystem-4z8.4`'s pool and
ledger in one plugin instead of splitting them across two.

## Consequences

A judge agent renamed or removed in tribunal breaks lesson judging at dispatch
time. That is a visible, loud failure at the moment a human invokes the verb —
not a silent one — and the "could not judge" path already handles it: the
candidate stays `confirmed` and nothing is written.

A judge agent silently edited in place is a different, unmitigated risk. If a
maintainer changes what a judge returns without renaming it — dropping
`judge_type`, redefining what `feedback_summary` means, rescaling `score` —
nothing in this pipeline notices at edit time, because the agent definition
carries no drift check the way `@onlooker-community/schema` does. The
`usable` panel check in `librarian-lesson-judge.sh` only catches the subset of
that risk that changes the verdict's *shape*: it requires `judge_type` to be a
string, `score` a number, and `passed` a boolean, and returns UNJUDGED rather
than a false rejection if any is missing or mistyped. A *semantic* change —
same shape, different meaning, such as a score scale moving from 0–1 to
0–100 — passes that check and is judged normally, with no signal to librarian
or its maintainers that the verdict no longer means what the aggregate and
gate assume it means. This ADR accepts that risk rather than closing it;
closing it would require either a real schema contract for judge output or
librarian validating semantics it does not own.

Librarian's gate logic can drift from tribunal's. Accepted deliberately: they
answer different questions. Tribunal gates an Actor's output with retry;
librarian gates a fixed artifact with none.
