#!/usr/bin/env bash
# Chunker for Historian.
#
# Given a JSON array of normalized turns (from historian-transcript.sh),
# produces a JSON array of chunk records. Each chunk:
#   - Prefers turn boundaries, splitting mid-turn only when a single turn
#     is larger than `target_chars` (see the oversized-turn branch below)
#   - Targets `target_chars` characters with `overlap_chars` overlap
#     (carrying the last N chars of one chunk's content as the start of
#     the next)
#   - Records start_turn_index, end_turn_index, body_chars
#
# Character-based chunking instead of token-based: tokenizers vary by
# embedder, and the chunker shouldn't have to know which embedder will
# run downstream. Char counts approximate token counts at ~4 chars / token
# for English-ish prose; configs are tunable.

# Usage: historian_chunker_split <turns_json> <target_chars> <overlap_chars>
# Output: JSON array of chunks.
historian_chunker_split() {
	local turns="${1:-[]}"
	local target_chars="${2:-2400}"
	local overlap_chars="${3:-400}"

	python3 - "$target_chars" "$overlap_chars" "$turns" <<'PY'
import json, sys

target = int(sys.argv[1])
overlap = max(0, int(sys.argv[2]))
turns = json.loads(sys.argv[3] or "[]")

# Overlap has to stay meaningfully below the target. A chunk is seeded with the
# previous chunk's trailing `overlap` chars, so an overlap at or above the
# target starts every chunk already over budget, and the oversized-turn window
# below would advance by nothing. Half the target is the most that still leaves
# room to make progress.
if target > 0:
    overlap = min(overlap, target // 2)

chunks = []
chunk_index = 0
buf_parts = []
buf_chars = 0
buf_start = None
buf_end = None

# Pending overlap text carried from the previous chunk. It seeds the next
# chunk's body but doesn't get attributed a turn (the overlap is purely
# textual continuity for the embedder).
pending_overlap = ""


def flush(force_text=None):
    """Emit the current buffer as a chunk. force_text overrides the
    accumulated body and is used when a single turn exceeds the target."""
    global chunk_index, buf_parts, buf_chars, buf_start, buf_end
    if force_text is None:
        if not buf_parts:
            return
        body = "\n\n".join(buf_parts)
    else:
        body = force_text
    if not body.strip():
        # Reset and skip empty bodies (can happen with overlap-only carry).
        buf_parts = []
        buf_chars = 0
        buf_start = None
        buf_end = None
        return
    chunks.append({
        "chunk_index": chunk_index,
        "start_turn_index": buf_start,
        "end_turn_index": buf_end,
        "body": body,
        "body_chars": len(body),
    })
    chunk_index += 1
    buf_parts = []
    buf_chars = 0
    buf_start = None
    buf_end = None


for turn in turns:
    role = turn.get("role", "")
    content = turn.get("content", "")
    if not content:
        continue
    rendered = f"{role}: {content}"
    rendered_len = len(rendered)

    # If this single turn exceeds the target, flush whatever's pending and
    # window the turn into target-sized pieces.
    if rendered_len > target:
        # Flush pending buffer first.
        if buf_parts:
            flush()
        # A turn bigger than the target used to become one oversized chunk, on
        # the theory that turn boundaries were worth preserving whole. They are
        # not worth it at this price: nomic-embed-text answers HTTP 500 above
        # roughly 7k chars, so those chunks were stored without a vector and the
        # embedding-only retriever could never return them. The longest turns in
        # a session are the substantial ones, so the index was losing exactly
        # the material worth recalling (ONL-123).
        #
        # Slide a target-sized window over the turn instead, carrying `overlap`
        # chars between windows so a match landing on a seam still reads in
        # context. Every window is attributed to the turn it came from.
        full = (pending_overlap + ("\n\n" if pending_overlap else "")) + rendered
        stride = max(1, target - overlap)
        pos = 0
        while pos < len(full):
            buf_start = turn["turn_index"]
            buf_end = turn["turn_index"]
            flush(force_text=full[pos:pos + target])
            if pos + target >= len(full):
                break
            pos += stride
        pending_overlap = full[-overlap:] if overlap > 0 else ""
        continue

    candidate_len = buf_chars + rendered_len + (2 if buf_parts else 0)  # 2 for "\n\n"
    if buf_parts and candidate_len > target:
        # Flush the buffer; start a new chunk seeded with overlap from the
        # body we just emitted.
        last_body = ""
        if chunks:
            last_body = chunks[-1]["body"]
        flush()
        if overlap > 0 and last_body:
            pending_overlap = last_body[-overlap:]
        else:
            pending_overlap = ""

    if not buf_parts and pending_overlap:
        buf_parts.append(pending_overlap)
        buf_chars += len(pending_overlap)
        pending_overlap = ""

    buf_parts.append(rendered)
    buf_chars += rendered_len + (2 if len(buf_parts) > 1 else 0)
    if buf_start is None:
        buf_start = turn["turn_index"]
    buf_end = turn["turn_index"]

# Final flush.
if buf_parts:
    flush()

print(json.dumps(chunks))
PY
}
