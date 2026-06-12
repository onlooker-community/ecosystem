#!/usr/bin/env bash
# Secret redaction + size capping for lineage change snippets.
#
# Mirrors the conservative secret patterns in historian-sanitizer.sh (false
# positives acceptable; false negatives are the failure mode that matters).
# The heavy lifting runs in an inline python3 block — the same pattern
# historian uses — because portable case-insensitive regex across BSD/GNU sed
# is not worth the fragility on a path that handles user code.

# Redact secret-shaped substrings from stdin, then cap to <max_chars>.
# Usage: printf '%s' "$content" | lineage_redact <max_chars> <redact:true|false>
lineage_redact() {
	local max_chars="${1:-4000}"
	local do_redact="${2:-true}"
	# Pass the program via -c (not a heredoc on stdin): -c keeps stdin free for
	# the piped content, so sys.stdin.read() actually receives it.
	local _prog
	_prog=$(cat <<'PY'
import re
import sys

max_chars = int(sys.argv[1] or "4000")
do_redact = sys.argv[2] != "false"
text = sys.stdin.read()

if do_redact:
    patterns = [
        re.compile(r"\bAKIA[0-9A-Z]{16}\b"),            # AWS access key id
        re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),  # GitHub tokens
        re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b"),   # Anthropic API keys
        re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),         # OpenAI-style keys
        re.compile(r"(?i:Bearer)\s+[A-Za-z0-9._\-+/=]{20,}"),  # bearer tokens
    ]
    for pat in patterns:
        text = pat.sub("[REDACTED:secret]", text)
    # KEY=value or "key": "value" where the key name implies a secret;
    # preserve the key, redact the value.
    kv = re.compile(
        r'([A-Za-z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Za-z0-9_]*"?\s*[:=]\s*"?)\S+',
        re.IGNORECASE,
    )
    text = kv.sub(lambda m: m.group(1) + "[REDACTED:secret]", text)

if len(text) > max_chars:
    text = text[:max_chars] + "… [truncated %d chars]" % (len(text) - max_chars)

sys.stdout.write(text)
PY
)
	python3 -c "$_prog" "$max_chars" "$do_redact"
}
