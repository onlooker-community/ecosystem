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
            role = rec.get("role") or rec.get("type")
            if role not in ("user", "assistant"):
                continue
            raw = rec.get("content", "")
            if isinstance(raw, list):
                # Anthropic content-blocks form. Concatenate the text-typed
                # blocks; drop tool_use / tool_result entries here.
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
