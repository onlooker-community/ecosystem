#!/usr/bin/env bash
# Sanitizer for Historian chunks.
#
# Three layers, in order:
#   1. Secret-shaped substrings are redacted to "[REDACTED:secret]".
#      Patterns cover AWS access keys, GitHub PATs, Anthropic API keys,
#      bearer tokens, and KEY=value-style env assignments containing
#      key/secret/token in the key name.
#   2. `[historian:skip]` markers cause the entire chunk to be dropped.
#   3. Path-deny: if the chunk references any path under
#      `never_index_paths` (substring match against each entry), the
#      chunk is dropped.
#
# Input: JSON array of chunk records from the chunker (each with `body`).
# Output: JSON array of surviving chunk records, each with `body_redacted`
#         (instead of `body`) and a `redaction_count`, plus a sibling
#         array of `dropped` records keyed by reason.

# Usage: historian_sanitizer_run <chunks_json> <never_index_paths_json>
# Output: { "kept": [...], "dropped": [...] }
historian_sanitizer_run() {
	local chunks="${1:-[]}"
	local never_index_paths="${2:-[]}"

	python3 - "$chunks" "$never_index_paths" <<'PY'
import json, re, sys

chunks = json.loads(sys.argv[1] or "[]")
deny_paths = json.loads(sys.argv[2] or "[]")

# Secret-shaped patterns. Conservative — false positives are acceptable;
# false negatives are the failure mode we care about.
SECRET_PATTERNS = [
    # AWS access keys (AKIA followed by 16 base32-ish chars).
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    # GitHub PATs.
    re.compile(r"\bghp_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgho_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bghs_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bghu_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bghr_[A-Za-z0-9]{20,}\b"),
    # Anthropic API keys.
    re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b"),
    # Bearer tokens in headers.
    re.compile(r"Bearer\s+[A-Za-z0-9._\-+/=]{20,}"),
    # KEY=value where KEY contains key/secret/token (case-insensitive).
    # We redact only the value (everything after the first =).
    re.compile(
        r"\b([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Z0-9_]*)\s*=\s*\S+",
        re.IGNORECASE,
    ),
]


def sanitize(body):
    count = 0
    out = body
    for pat in SECRET_PATTERNS[:-1]:
        new = pat.sub("[REDACTED:secret]", out)
        # Each match is one redaction event.
        matches = pat.findall(out)
        if matches:
            count += len(matches)
            out = new
    # KEY=value form: preserve the key, redact the value.
    last = SECRET_PATTERNS[-1]
    matches = list(last.finditer(out))
    if matches:
        count += len(matches)

        def repl(m):
            key = m.group(1)
            return f"{key}=[REDACTED:secret]"

        out = last.sub(repl, out)
    return out, count


SKIP_MARKER = "[historian:skip]"


kept = []
dropped = []
for chunk in chunks:
    body = chunk.get("body", "")
    if SKIP_MARKER in body:
        dropped.append({
            "chunk_index": chunk.get("chunk_index"),
            "reason": "skip_marker",
        })
        continue
    if deny_paths and any(p and p in body for p in deny_paths):
        dropped.append({
            "chunk_index": chunk.get("chunk_index"),
            "reason": "never_index_path",
        })
        continue
    redacted, count = sanitize(body)
    new_chunk = dict(chunk)
    new_chunk.pop("body", None)
    new_chunk["body_redacted"] = redacted
    new_chunk["redaction_count"] = count
    kept.append(new_chunk)

print(json.dumps({"kept": kept, "dropped": dropped}))
PY
}
