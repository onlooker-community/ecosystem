#!/usr/bin/env bash
# Transcript reading for Historian.
#
# Claude Code records each session's transcript as JSONL where each line
# is an entry like { "role": "user"|"assistant"|"system", "content": "...",
# ... }. Historian only embeds user + assistant turns — tool calls and tool
# results are dropped at this stage so the chunked content stays
# semantically focused on the conversation.

# Load the transcript and emit a JSON array of normalized turn records:
#   [
#     { "turn_index": 0, "role": "user", "content": "..." },
#     { "turn_index": 1, "role": "assistant", "content": "..." },
#     ...
#   ]
#
# Returns an empty array when the transcript is absent or unreadable.
#
# Usage: historian_transcript_load <transcript_path>
historian_transcript_load() {
	local path="${1:-}"
	[[ -z "$path" || ! -f "$path" ]] && { echo '[]'; return 0; }

	# Filter to user/assistant role entries with non-empty content, keep
	# their original order (the JSONL is recorded chronologically), and
	# attach a turn_index. Content may be a string OR an array of content
	# blocks (Anthropic SDK shape); flatten array forms to text.
	python3 - "$path" <<'PY'
import json, sys

path = sys.argv[1]
out = []
turn_index = 0
try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            # Claude Code writes {"type":"user","message":{"role":...,
            # "content":...}} — the role is on `type`, the content is NESTED
            # under `message`. Reading a top-level `content` (which is what
            # this did) found nothing on every real transcript: 0 turns, 0
            # chars, and so every session tripped the min_chars gate and
            # reported too_short. 1730 of them (ONL-121).
            #
            # The flat {"role":..., "content":...} form is still accepted so a
            # non-Claude-Code adapter emitting it keeps working; `message`
            # simply wins when present.
            msg = rec.get("message")
            msg = msg if isinstance(msg, dict) else None

            role = (msg or {}).get("role") or rec.get("type") or rec.get("role")
            if role not in ("user", "assistant"):
                continue
            raw = msg.get("content", "") if msg is not None else rec.get("content", "")
            if isinstance(raw, list):
                # Anthropic content-blocks form. Concatenate the text-typed
                # blocks only; tool_use, tool_result and thinking are dropped
                # here. thinking matters as much as the tool blocks: it is
                # internal reasoning, often the largest part of an assistant
                # turn, and indexing it would both bloat the store and surface
                # working-out that was never addressed to anyone.
                parts = []
                for block in raw:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") in (None, "text"):
                        t = block.get("text") or ""
                        if t:
                            parts.append(t)
                content = "\n\n".join(parts)
            else:
                content = str(raw)
            content = content.strip()
            if not content:
                continue
            out.append({
                "turn_index": turn_index,
                "role": role,
                "content": content,
            })
            turn_index += 1
except OSError:
    pass

print(json.dumps(out))
PY
}

# Return the total content character count across normalized turns.
# Usage: historian_transcript_char_count <turns_json>
historian_transcript_char_count() {
	local turns="${1:-[]}"
	printf '%s' "$turns" | jq '[.[] | (.content | length)] | add // 0' 2>/dev/null
}
