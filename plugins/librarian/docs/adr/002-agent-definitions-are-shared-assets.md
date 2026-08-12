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
prompt. It has no runtime surface, cannot fail at call time in a way that
propagates, and is resolved by the harness rather than by librarian. Depending
on one is closer to depending on a published schema than to calling another
plugin's code.

Sourcing tribunal's bash would be the real coupling: a change to
`tribunal_gate_decide`'s signature would break librarian silently, and
tribunal's own tests would not catch it.

Keeping the lifecycle in librarian also keeps `ecosystem-4z8.4`'s pool and
ledger in one plugin instead of splitting them across two.

## Consequences

A judge agent renamed or removed in tribunal breaks lesson judging at dispatch
time. That is a visible, loud failure at the moment a human invokes the verb —
not a silent one — and the "could not judge" path already handles it: the
candidate stays `confirmed` and nothing is written.

Librarian's gate logic can drift from tribunal's. Accepted deliberately: they
answer different questions. Tribunal gates an Actor's output with retry;
librarian gates a fixed artifact with none.
