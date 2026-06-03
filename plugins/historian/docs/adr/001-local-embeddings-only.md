# ADR-001: Historian Uses Local Embeddings by Default

- Status: Accepted
- Date: 2026-06-02
- Deciders: Meagan
- Tags: historian, embeddings, privacy, data-egress, local-first

## Context and Problem Statement

Historian's central operation is embedding session transcripts. Two timeframes consume embeddings: indexing (once per session, in bulk) and retrieval (potentially every user prompt). The model choice — local vs. remote — drives privacy posture, cost shape, latency profile, retrieval quality, and dependency surface, all at once.

Remote embedding APIs (Voyage, OpenAI, Cohere, Anthropic's voyage models) are easier to set up, produce higher-quality embeddings, and impose no local compute requirement. They also mean every session's transcript content — including paths, identifiers, code snippets, internal terminology, and anything the user said in conversation — is sent over the wire to a third party, in the moment-by-moment course of normal use. Even a well-intentioned user with a benign API key may not realize how much they are streaming out, because the operation is invisible.

Local embedding models (`nomic-embed-text` via ollama, `bge-small` via fastembed) sacrifice some retrieval quality and impose a one-time local setup cost in exchange for keeping all transcript content on the user's machine. Modern small embedding models are good enough for the precedent-retrieval task historian is designed for.

This ADR records why local embedding is the architectural baseline, and what the remote opt-in path requires.

## Decision Drivers

- **Transcript content is the most sensitive thing historian touches.** It contains code paths the user is actively working on, names of internal systems, mid-thought work product, mistakes, and side discussions. A user adopting historian for productivity gains should not, as a side effect, opt into per-prompt transcript egress.
- **Per-prompt latency matters.** Retrieval runs on `UserPromptSubmit` — a hot path. A remote round-trip introduces ~100–400ms of latency every time. A local embedding model adds ~20–60ms. Cumulatively across a working day this is material.
- **Per-prompt cost matters.** Even at $0.00002 per 1K tokens, retrieval that fires on every long-enough prompt is a non-trivial recurring cost. Local embedding has a one-time setup cost and is free thereafter.
- **Retrieval-quality budget.** Historian's surface ("here is one past chunk that looks similar") is informational, not load-bearing. The model can ignore a marginal match. Top-1 retrieval against `nomic-embed-text` is good enough for the "have we seen this before?" signal. The marginal quality gain from a frontier embedding model does not unlock new capabilities here.
- **Fail-soft requirement.** Plugins in the Onlooker ecosystem must not block sessions they were not invited to. A remote-by-default embedder means a failed network call is a failed retrieval — silently. A local embedder still works without a network.
- **Opt-in pattern for sensitive plugins.** Compass's `data_egress` block makes egress an explicit configuration decision. Historian inherits this pattern: the user must affirm both `embedder.backend: "remote"` AND `data_egress.allow_remote_embedding: true` to send transcript content off-machine. Two independent affirmations.

## Considered Options

1. **Remote-by-default, with a local fallback.** Easier first-run UX. The user gets best-in-class retrieval immediately. Local fallback covers offline scenarios but most users never see it.
2. **Local-by-default, with a remote opt-in.** Privacy-by-default. Higher first-run friction (the user must install or already have ollama). Remote opt-in is gated by an explicit egress affirmation.
3. **No embeddings at all — keyword search only.** Cheapest, simplest, no dependency. Retrieval quality is poor for paraphrased prompts ("the flaky test" vs. "tests timing out intermittently"). Misses the semantic-recall use case that motivated historian.
4. **Hybrid: local for embedding, remote for reranking.** Embed everything locally; for the top-N candidates, call a remote reranker to break ties. Reduces remote egress dramatically while keeping high retrieval quality. More complex; defers to a future iteration.

## Decision

We adopt **Option 2: local embedding (via ollama with `nomic-embed-text`) is the default backend. Remote embedding is opt-in and requires both `embedder.backend: "remote"` and `data_egress.allow_remote_embedding: true`.**

Backends, in preference order:

1. **ollama with `nomic-embed-text`.** Recommended default. 768-dim embeddings, ~110MB model, fully local, good cosine-similarity behavior on prose and code-mixed content. Historian's `/historian setup` skill walks the user through `ollama pull nomic-embed-text`.
2. **fastembed via Python sidecar.** Fallback for users without ollama. ONNX-based; slower startup but no separate runtime daemon.
3. **Remote.** Opt-in only. Requires two-key affirmation. When enabled, historian still stores all embeddings and chunk bodies locally — only the embedding *computation* leaves the machine.

The two-key affirmation pattern (`embedder.backend: "remote"` AND `data_egress.allow_remote_embedding: true`) means a user who copies a config snippet that flips one key still gets a hard fail at startup rather than silent egress. The mismatch logs `historian.config.warning` with the specific message "remote embedding configured but egress not allowed."

Option 1 is rejected because the user-experience benefit (no install step) is small relative to the privacy cost (silent transcript egress on every prompt). A user who genuinely wants remote-grade quality can flip the two-key opt-in.

Option 3 is rejected because keyword retrieval misses the use cases historian is designed for. The motivating examples (flaky-test deja-vu, "I tried this approach already and it didn't work") all involve paraphrase across sessions.

Option 4 (hybrid local + remote reranker) is deferred. It is appealing — most egress avoided, near-frontier retrieval quality — but it triples the configuration surface and requires both backends to be working. The simpler local-only default is the right starting point; hybrid is a natural future opt-in.

## Consequences

### Positive

- Transcript content stays on the user's machine by default. No silent egress.
- Per-prompt retrieval latency stays in the 30–100ms range with a warm ollama process. The hot path is not slowed by network.
- Retrieval cost is zero after model download.
- The plugin works offline.
- The two-key egress affirmation forces an explicit decision at configuration time, matching compass's pattern. A user who wants remote retrieval can opt in cleanly; a user who doesn't is never accidentally signed up.
- Embedding-storage is forward-compatible with future cross-project sharing (`source: "team:<id>"`) without inheriting "we already sent everything to a third party" as a starting condition.

### Negative

- First-run UX requires installing ollama (~150MB runtime) and pulling the model (~110MB). The `/historian setup` skill streamlines this but it is friction relative to "edit a config and go."
- Retrieval quality is lower than frontier embedding models on edge cases (e.g., highly idiosyncratic terminology, very short prompts, code-heavy chunks). For most prose-shaped recall the gap is small.
- Local embedding consumes ~200MB of resident memory while the ollama process runs. On constrained machines this is noticeable.
- A user who wants remote retrieval has to flip two keys, not one. This is intentional but adds documentation surface.

### Neutral

- Ollama as the default runtime ties historian to a specific local-LLM ecosystem. Fastembed as a fallback hedges this dependency. A pure-Rust backend (e.g., direct ONNX) is plausible if ollama proves to be the wrong bet.
- The decision to store chunk bodies locally alongside embeddings is independent of this ADR but mutually reinforcing — co-located chunk bodies mean retrieval results can render without any network round-trip.

## Implementation Notes

- `embedder.backend: "ollama"` is checked first. If ollama is not on PATH or the configured host is unreachable, historian falls through to fastembed automatically. If fastembed is also unavailable, historian emits `historian.embedder.unavailable` and disables both indexing and retrieval for the session — no partial behavior.
- `embedder.backend: "remote"` does NOT auto-fall-through if the remote endpoint is unreachable. A misconfigured or down remote backend produces `historian.embedder.unavailable` and stops; this prevents silent fallback that might violate the user's expectation of where embeddings happen.
- The two-key affirmation check runs at `SessionStart`. A configuration with `backend: "remote"` and `allow_remote_embedding: false` logs a warning and forces `backend: "ollama"` for the session. The user is told their config has a mismatch.
- The `nomic-embed-text` cosine-similarity distribution on this corpus puts unrelated chunks around 0.30–0.45 and related chunks around 0.55–0.85. `min_similarity: 0.55` is the default floor. The `/historian calibrate` skill (mentioned as an open question in the design doc) is the per-project tuning surface.
- Remote backends, if enabled, must respect the same chunk-body redaction pipeline as local backends. Redaction is applied before any network call. Verified by an emitted `historian.chunk.sanitized` event preceding the embed.
- Re-embedding after a backend change is not automatic. The vector store has no `embedding_model` column today; mixing vectors from two different models silently degrades retrieval. A future migration adds the column and forces a re-index on backend change. Until then, the docs warn against changing `embedder.backend` after data is stored.

## Validation

- A test session with a transcript of ~10K characters should index in ≤2 seconds end-to-end on ollama with `nomic-embed-text` running locally on a typical macOS dev laptop.
- A `UserPromptSubmit` retrieval against a vector store with 500 chunks should complete in under 100ms wall-clock.
- A misconfigured `backend: "remote"` with `allow_remote_embedding: false` must produce `historian.config.warning` at SessionStart and operate as if `backend: "ollama"` for the session. No network call may be made.
- A purge via `/historian purge all` must remove all chunks for the project key and leave no embeddings behind. Verified by `historian.purge.completed` followed by an empty `historian.stats` report.

## References

- Compass design — precedent for explicit `data_egress` configuration blocks (`plugins/compass/docs/design.md#data-egress`)
- Compass `data_egress` discussion in the design doc — the "near-zero egress" mode template historian inherits
- Memory architecture overview (`docs/memory-architecture.md`)
- Historian design (`../design.md`)
