#!/usr/bin/env bash
# Secret-shaped redaction, shared by every plugin that stores agent text.
#
# One copy, because two copies diverged: lineage carried a bare `sk-` pattern
# and a KV pattern accepting `:` and quotes, historian carried neither, and
# historian is the plugin that stores whole session transcripts. Two shapes
# reached disk verbatim for as long as both copies existed (ONL-167).
#
# Conservative by design: false positives are acceptable, false negatives are
# the failure mode that matters. Bearer matches case-insensitively on the
# scheme name because RFC 6750 defines it that way and both cases occur.
#
# BATCH INTERFACE, deliberately. A per-string helper would cost one python3
# start per call, and historian's largest session on the machine this was
# measured on holds 243 chunks against a ~21ms python3 start - about 5.1s
# inside a SessionEnd hook whose default abort window is 1.5s. One call
# handles the whole batch whatever its size.
#
# Usage: onlooker_redact_secrets '<json array of strings>'
#   stdout: JSON array of {"redacted": string, "count": integer}, element i
#           corresponding to input element i.
#
# Takes no enable/disable flag: a caller that does not want redaction does not
# call it, which keeps that branch in the caller rather than in here.
#
# FAILS CLOSED. If python3 is missing or errors, stdout is empty and no raw
# input text escapes. A redactor that failed open would be the leak it exists
# to prevent.
onlooker_redact_secrets() {
	local inputs="${1:-[]}"

	python3 - "$inputs" <<'PY'
import json, re, sys

inputs = json.loads(sys.argv[1] or "[]")

PLACEHOLDER = "[REDACTED:secret]"

# Order is load-bearing: sk-ant- precedes the bare sk- so an Anthropic key is
# labeled by the more specific pattern.
TOKEN_PATTERNS = [
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),            # AWS access key id
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),  # GitHub tokens, all five kinds
    re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b"),   # Anthropic API keys
    re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),         # OpenAI-style keys
    re.compile(r"(?i:Bearer)\s+[A-Za-z0-9._\-+/=]{20,}"),  # bearer tokens
]

# KEY=value or "key": "value" where the key name implies a secret. Group 1
# captures the key, the separator and any opening quote, so the replacement
# preserves the original form instead of normalizing every pair to `key=`.
KV_PATTERN = re.compile(
    r'([A-Za-z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Za-z0-9_]*"?\s*[:=]\s*"?)\S+',
    re.IGNORECASE,
)


def redact(text):
    count = 0
    out = text
    for pat in TOKEN_PATTERNS:
        found = pat.findall(out)
        if found:
            count += len(found)
            out = pat.sub(PLACEHOLDER, out)
    kv = list(KV_PATTERN.finditer(out))
    if kv:
        count += len(kv)
        out = KV_PATTERN.sub(lambda m: m.group(1) + PLACEHOLDER, out)
    return {"redacted": out, "count": count}


# Non-strings are coerced rather than raising: one malformed element must not
# cost the whole batch, which for historian is a whole session's transcript.
print(json.dumps([redact(t) if isinstance(t, str) else {"redacted": "", "count": 0}
                  for t in inputs]))
PY
}
