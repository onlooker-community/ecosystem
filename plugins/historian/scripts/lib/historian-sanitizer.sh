#!/usr/bin/env bash
# Sanitizer for Historian chunks.
#
# Three layers, in order:
#   1. Secret-shaped substrings are redacted to "[REDACTED:secret]". The
#      patterns come from onlooker-secret-patterns.sh, vendored beside this
#      file. They used to live here, in a copy that had drifted from
#      lineage's: this one was missing the bare `sk-` pattern and its KV
#      pattern accepted `=` only, so an OpenAI-style key and a JSON-style
#      `"api_key": "..."` pair were written to transcripts verbatim
#      (ONL-167).
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
#                                 <redact_secret_patterns> <drop_skip_marker>
#
# The two boolean args honor the corresponding config knobs:
#   redact_secret_patterns: false → skip the secret regex substitutions
#                                    (chunk bodies copy through unchanged)
#   drop_skip_marker: false → keep chunks even when they contain the
#                              [historian:skip] marker
#
# Output: { "kept": [...], "dropped": [...] }

# Resolved from this file's OWN location, never from a caller-supplied
# PLUGIN_ROOT and never by climbing to a repo root (CLAUDE.md step 8).
# shellcheck source=./onlooker-secret-patterns.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/onlooker-secret-patterns.sh"

historian_sanitizer_run() {
	local chunks="${1:-[]}"
	local never_index_paths="${2:-[]}"
	local redact_secrets="${3:-true}"
	local drop_skip="${4:-true}"

	# Pass 1: drop filtering. Decides which chunks survive, IN ORDER, so the
	# redaction batch below is positionally aligned with `kept`. Filtering must
	# come first: redacting every body and filtering afterward would misalign
	# the zip the moment a chunk is dropped, attaching one chunk's count to
	# another chunk's record.
	local split
	split=$(python3 - "$chunks" "$never_index_paths" "$drop_skip" <<'PY'
import json, sys

chunks = json.loads(sys.argv[1] or "[]")
deny_paths = json.loads(sys.argv[2] or "[]")
drop_skip = sys.argv[3] != "false"

SKIP_MARKER = "[historian:skip]"

kept, dropped = [], []
for chunk in chunks:
    body = chunk.get("body", "")
    if drop_skip and SKIP_MARKER in body:
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
    kept.append(chunk)

print(json.dumps({"kept": kept, "dropped": dropped}))
PY
	) || return 0
	[[ -z "$split" ]] && return 0

	# Pass 2: redaction, one shared call over every surviving body. One python3
	# process for the whole batch, not one per chunk - the largest session
	# measured here holds 243 chunks and a python3 start costs ~21ms.
	local redacted='[]'
	if [[ "$redact_secrets" != "false" ]]; then
		local bodies
		bodies=$(printf '%s' "$split" | jq -c '[.kept[] | (.body // "")]') || return 0
		redacted=$(onlooker_redact_secrets "$bodies" 2>/dev/null) || return 0
		# Fail closed: no raw body may be emitted because redaction failed.
		[[ -z "$redacted" ]] && return 0
	fi

	# Zip the results back on by index. With redaction off every body copies
	# through with count 0, the shape the previous implementation produced -
	# the redact_secret_patterns: false knob must still bypass, not redact.
	printf '%s' "$split" | jq -c \
		--argjson red "$redacted" \
		--arg on "$redact_secrets" '
		{
			kept: [ .kept | to_entries[] | .key as $i | .value
				| (if $on == "false"
				   then {body_redacted: (.body // ""), redaction_count: 0}
				   else {body_redacted: $red[$i].redacted, redaction_count: $red[$i].count}
				   end) as $add
				| del(.body) + $add ],
			dropped: .dropped
		}'
}
