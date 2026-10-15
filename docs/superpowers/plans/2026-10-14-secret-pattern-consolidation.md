# One Secret-Pattern Lib Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace lineage's and historian's two diverged copies of the secret-redaction
patterns with one vendored lib, closing the two shapes historian writes verbatim today.

**Architecture:** A new `scripts/lib/onlooker-secret-patterns.sh` exposes one function,
`onlooker_redact_secrets`, that takes a JSON array of strings and returns a JSON array of
`{redacted, count}` positionally aligned with its input. One python3 process per call, not
per string. Both plugins vendor the lib via `sync-shared-libs.sh` and keep their own
wrappers — lineage its truncation, historian its drop filtering and counts.

**Tech Stack:** bash (macOS system bash 3.2 compatible), python3 (inline heredoc), jq,
bats.

## Global Constraints

- Patterns are lineage's set verbatim, which is a verified superset of historian's. No
  union, no additions. New shapes are out of scope (see the spec's Out of scope).
- The function takes **no** enable/disable flag. A caller that does not want redaction
  does not call it.
- Fail closed: if python3 fails, output is empty and no raw input text reaches the caller.
- Pattern order is lineage's order, unchanged. `sk-ant-` precedes the bare `sk-`.
- `count` is substitutions made in that one string, matching historian's existing
  `redaction_count` semantics.
- Secret-shaped test literals must be split (`"AKIA""0123…"`) or the repository's secret
  scanner blocks the file. `test/bats/historian-session-end.bats` already does this.
- Non-final negative assertions in bats need `|| return 1`; a `!`-prefixed command is
  exempt from errexit (SC2314, ecosystem-o09).
- Run tests with `npm run test:bats`, never bare `bats`.
- `scripts/sync-shared-libs.sh` refreshes on-demand libs but never creates the first copy
  — each plugin's first vendored copy is a manual `cp`.
- On-demand libs do not carry the `_ONLOOKER_LIB_FINGERPRINT=` marker; none of the
  existing three do. Do not add one.

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib/onlooker-secret-patterns.sh` (create) | The patterns and `onlooker_redact_secrets`. Nothing caller-specific. |
| `test/bats/onlooker-secret-patterns.bats` (create) | The shape table, fail-closed, batch alignment, JSON round-trip. |
| `scripts/sync-shared-libs.sh` (modify) | Register the lib in `ON_DEMAND_LIBS`. |
| `plugins/lineage/scripts/lib/onlooker-secret-patterns.sh` (create) | Vendored copy, byte-identical. |
| `plugins/lineage/scripts/lib/lineage-redact.sh` (modify) | Call the shared fn; keep truncation and the `do_redact=false` bypass. |
| `plugins/historian/scripts/lib/onlooker-secret-patterns.sh` (create) | Vendored copy, byte-identical. |
| `plugins/historian/scripts/lib/historian-sanitizer.sh` (modify) | Call the shared fn; keep drop filtering, `{kept, dropped}`, per-chunk counts. |
| `test/bats/historian-session-end.bats` (modify) | Add the two gap shapes to the end-to-end fixture. |

---

### Task 1: The shared lib and its shape table

**Files:**
- Create: `scripts/lib/onlooker-secret-patterns.sh`
- Create: `test/bats/onlooker-secret-patterns.bats`
- Modify: `scripts/sync-shared-libs.sh:30` (the `ON_DEMAND_LIBS` array)

**Interfaces:**
- Consumes: nothing.
- Produces: `onlooker_redact_secrets <json_array_of_strings>` → stdout, a JSON array of
  objects `{"redacted": <string>, "count": <integer>}`, element *i* corresponding to input
  element *i*. Empty stdout on python3 failure. Tasks 2 and 3 call exactly this.

- [ ] **Step 1: Write the failing test**

Create `test/bats/onlooker-secret-patterns.bats`:

```bash
#!/usr/bin/env bats

# The shared secret-redaction lib (ONL-167).
#
# The shape table is the load-bearing part. The bug this lib exists to fix was
# invisible because historian's fixture enumerated the four shapes its code
# implemented rather than the shapes a transcript can contain, so a pattern
# that was never there looked exactly like a pattern that worked.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/scripts/lib/onlooker-secret-patterns.sh"
}

# Every shape the lib claims to redact, as `name<TAB>sample`.
#
# Literals are split ("AKIA" "0123…") because the repository's secret scanner
# blocks a file containing a complete one - the same reason
# historian-session-end.bats builds its fixtures by concatenation.
_shape_samples() {
	printf '%s\n' \
		"aws	AKIA""0123456789ABCDEF" \
		"github_pat	ghp""_aaaaaaaaaaaaaaaaaaaaaaaa" \
		"github_oauth	gho""_bbbbbbbbbbbbbbbbbbbbbbbb" \
		"github_server	ghs""_cccccccccccccccccccccccc" \
		"github_user	ghu""_dddddddddddddddddddddddd" \
		"github_refresh	ghr""_eeeeeeeeeeeeeeeeeeeeeeee" \
		"anthropic	sk-""ant-ffffffffffffffffffffff" \
		"openai	sk-""gggggggggggggggggggggggg" \
		"bearer	Bearer ""hhhhhhhhhhhhhhhhhhhhhhhh" \
		"kv_equals	API_KEY=""iiiiiiiiiiiiiiii" \
		"kv_json	\"api_key\": \"""jjjjjjjjjjjjjjjj\""
}

# Redact one string; print the redacted text.
_redact_one() {
	onlooker_redact_secrets "$(jq -cn --arg s "$1" '[$s]')" | jq -r '.[0].redacted'
}

@test "every shape in the table is redacted" {
	local line name sample out failed=""
	while IFS=$'\t' read -r name sample; do
		[ -n "$name" ] || continue
		out=$(_redact_one "$sample")
		# The secret value must be gone and the placeholder present. Both
		# halves matter: an empty result would satisfy the first alone.
		if printf '%s' "$out" | grep -qF "$sample"; then
			failed="${failed}${name}:not-redacted "
		fi
		if ! printf '%s' "$out" | grep -qF '[REDACTED:secret]'; then
			failed="${failed}${name}:no-placeholder "
		fi
	done < <(_shape_samples)
	[ -z "$failed" ] || { echo "shapes failing: $failed"; return 1; }
}

@test "the table covers every shape, so a dropped pattern cannot pass silently" {
	# A floor on the table itself. Without this, deleting a row would make the
	# loop above pass by iterating less.
	[ "$(_shape_samples | grep -c .)" -eq 11 ]
}

@test "a KV pair keeps its key and separator, losing only the value" {
	local out
	out=$(_redact_one "API_KEY=""iiiiiiiiiiiiiiii")
	[ "$out" = "API_KEY=[REDACTED:secret]" ]
}

@test "a JSON-style pair keeps its key and colon" {
	# The shape historian writes verbatim today. The separator and opening
	# quote survive because they are inside the pattern's capture group.
	local out
	out=$(_redact_one "\"api_key\": \"""jjjjjjjjjjjjjjjj\"")
	[[ "$out" == '"api_key": "[REDACTED:secret]'* ]] || return 1
	[[ "$out" != *jjjjjjjjjjjjjjjj* ]] || return 1
}

@test "ordinary text passes through untouched with a zero count" {
	local result
	result=$(onlooker_redact_secrets "$(jq -cn '["just some prose about keys"]')")
	[ "$(printf '%s' "$result" | jq -r '.[0].redacted')" = "just some prose about keys" ]
	[ "$(printf '%s' "$result" | jq -r '.[0].count')" = "0" ]
}

@test "count reports the number of substitutions" {
	local sample result
	sample="AKIA""0123456789ABCDEF and ghp""_aaaaaaaaaaaaaaaaaaaaaaaa"
	result=$(onlooker_redact_secrets "$(jq -cn --arg s "$sample" '[$s]')")
	[ "$(printf '%s' "$result" | jq -r '.[0].count')" = "2" ]
}

@test "the batch result is positionally aligned with its input" {
	# Task 3 zips counts back onto chunk records by index, so alignment is a
	# contract rather than a convenience.
	local result
	result=$(onlooker_redact_secrets "$(jq -cn --arg a "AKIA""0123456789ABCDEF" '["clean one", $a, "clean two"]')")
	[ "$(printf '%s' "$result" | jq -r 'length')" = "3" ]
	[ "$(printf '%s' "$result" | jq -r '.[0].redacted')" = "clean one" ]
	[ "$(printf '%s' "$result" | jq -r '.[1].count')" = "1" ]
	[ "$(printf '%s' "$result" | jq -r '.[2].redacted')" = "clean two" ]
}

@test "quotes and newlines survive the JSON round trip" {
	# The round trip is new surface this lib introduces; a body carrying a
	# quote or a newline must come back intact.
	local sample result
	sample=$(printf 'line one "quoted"\nline two')
	result=$(onlooker_redact_secrets "$(jq -cn --arg s "$sample" '[$s]')")
	[ "$(printf '%s' "$result" | jq -r '.[0].redacted')" = "$sample" ]
}

@test "an empty array returns an empty array" {
	[ "$(onlooker_redact_secrets '[]' | jq -r 'length')" = "0" ]
}

@test "a missing argument is treated as an empty array" {
	[ "$(onlooker_redact_secrets | jq -r 'length')" = "0" ]
}

@test "fails closed when python3 is unavailable" {
	# A redactor that fails OPEN is the leak it exists to prevent. Both
	# existing callers already behave this way; nothing asserted it.
	local stub="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$stub"
	printf '#!/bin/sh\nexit 127\n' > "${stub}/python3"
	chmod +x "${stub}/python3"

	local sample out
	sample="AKIA""0123456789ABCDEF"
	out=$(PATH="${stub}:${PATH}" bash -c "
		source '${REPO_ROOT}/scripts/lib/onlooker-secret-patterns.sh'
		onlooker_redact_secrets '$(jq -cn --arg s "$sample" '[$s]')'" 2>/dev/null)

	[ -z "$out" ] || return 1
	printf '%s' "$out" | grep -qF "$sample" && return 1
	true
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/onlooker-secret-patterns.bats`

Expected: every test fails with `onlooker_redact_secrets: command not found`, and `setup`
fails on the missing source path.

- [ ] **Step 3: Write the lib**

Create `scripts/lib/onlooker-secret-patterns.sh`:

```bash
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/onlooker-secret-patterns.bats`
Expected: 11 tests pass.

- [ ] **Step 5: Verify the shape table actually gates**

Delete the `sk-` line from `TOKEN_PATTERNS`, re-run, and confirm
`every shape in the table is redacted` fails naming `openai:not-redacted`. Restore it.
Then delete a row from `_shape_samples` and confirm the count test fails. Restore it.

This is the step that distinguishes a table that tests the code from a table that
describes it — the exact failure that hid this bug.

- [ ] **Step 6: Register the lib for vendoring**

In `scripts/sync-shared-libs.sh:30`, change:

```bash
ON_DEMAND_LIBS=(portable-lock.sh watch-unmatched.sh onlooker-project-key.sh)
```

to:

```bash
ON_DEMAND_LIBS=(portable-lock.sh watch-unmatched.sh onlooker-project-key.sh onlooker-secret-patterns.sh)
```

- [ ] **Step 7: Confirm the vendoring guards now cover the lib**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/shared-lib-vendoring.bats`
Expected: passes. The on-demand count assertion in that file reads the array from
`sync-shared-libs.sh`, so it adjusts automatically; no copy exists yet and on-demand libs
are never created, so nothing is out of sync.

Run: `scripts/sync-shared-libs.sh --check`
Expected: `all vendored copies match their canonical libs`.

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/onlooker-secret-patterns.sh test/bats/onlooker-secret-patterns.bats scripts/sync-shared-libs.sh
git commit -m "feat(secrets): one redaction lib, with a table of every shape :lock:"
```

---

### Task 2: Lineage adopts the lib

**Files:**
- Create: `plugins/lineage/scripts/lib/onlooker-secret-patterns.sh` (manual first copy)
- Modify: `plugins/lineage/scripts/lib/lineage-redact.sh:12-51`
- Test: `test/bats/lineage-redact.bats` (existing, 7 tests — must keep passing)

**Interfaces:**
- Consumes: `onlooker_redact_secrets <json_array_of_strings>` from Task 1.
- Produces: `lineage_redact <max_chars> <redact:true|false>`, stdin → stdout. Signature
  unchanged, so no caller of lineage_redact changes.

- [ ] **Step 1: Run the existing tests to record the baseline**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/lineage-redact.bats`
Expected: 7 tests pass. These are the regression net for this task — the point is that
behavior does not change.

- [ ] **Step 2: Vendor the lib**

```bash
cp scripts/lib/onlooker-secret-patterns.sh plugins/lineage/scripts/lib/onlooker-secret-patterns.sh
```

On-demand libs are refreshed but never created by the sync script, so this first copy is
manual by design.

- [ ] **Step 3: Rewrite lineage_redact to call the shared lib**

Replace the whole body of `plugins/lineage/scripts/lib/lineage-redact.sh` with:

```bash
#!/usr/bin/env bash
# Secret redaction + size capping for lineage change snippets.
#
# The patterns live in onlooker-secret-patterns.sh, vendored beside this file.
# They used to live here, in a copy that drifted from historian's - this one
# was the better of the two, and historian was missing two shapes because of
# it (ONL-167).
#
# What stays here is lineage's own concern: the size cap, and the bypass.

# Resolved from this file's OWN location, never from a caller-supplied
# PLUGIN_ROOT and never by climbing to a repo root - both resolve in one
# checkout and nowhere else, and both fail by leaving the function undefined
# while the script still exits 0 (CLAUDE.md step 8).
# shellcheck source=./onlooker-secret-patterns.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/onlooker-secret-patterns.sh"

# Redact secret-shaped substrings from stdin, then cap to <max_chars>.
# Usage: printf '%s' "$content" | lineage_redact <max_chars> <redact:true|false>
lineage_redact() {
	local max_chars="${1:-4000}"
	local do_redact="${2:-true}"

	local text
	text=$(cat)

	if [[ "$do_redact" != "false" ]]; then
		local result
		result=$(onlooker_redact_secrets "$(jq -cn --arg s "$text" '[$s]')" 2>/dev/null) \
			|| result=""
		# Fail closed, matching the shared lib: an unredacted snippet must
		# never reach the ledger because the redactor failed.
		[[ -z "$result" ]] && return 0
		text=$(printf '%s' "$result" | jq -r '.[0].redacted') || return 0
	fi

	# Truncation stays here: it is lineage's budget, not a property of
	# redaction, and historian does not want it.
	if [[ "${#text}" -gt "$max_chars" ]]; then
		printf '%s… [truncated %d chars]' "${text:0:max_chars}" "$(( ${#text} - max_chars ))"
	else
		printf '%s' "$text"
	fi
}
```

- [ ] **Step 4: Run the existing tests**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/lineage-redact.bats`
Expected: the same 7 tests pass. If the truncation test fails, compare the message format
against the original: `"… [truncated %d chars]"` with a leading ellipsis character and no
space before it.

- [ ] **Step 5: Verify fail-closed end to end**

```bash
D=$(mktemp -d); printf '#!/bin/sh\nexit 127\n' > "$D/python3"; chmod +x "$D/python3"
printf '%s' 'secret ghp'"_aaaaaaaaaaaaaaaaaaaaaaaa"' here' \
  | PATH="$D:$PATH" bash -c 'source plugins/lineage/scripts/lib/lineage-redact.sh; lineage_redact 4000 true'
```

Expected: empty output. The raw token must not appear.

- [ ] **Step 6: Confirm vendoring is clean**

Run: `scripts/sync-shared-libs.sh --check`
Expected: `all vendored copies match their canonical libs`.

Run: `ONLOOKER_VALIDATE=1 bats test/bats/shared-lib-vendoring.bats`
Expected: passes, now including lineage in the sources-it-and-vendors-it check.

- [ ] **Step 7: Commit**

```bash
git add plugins/lineage/scripts/lib/onlooker-secret-patterns.sh plugins/lineage/scripts/lib/lineage-redact.sh
git commit -m "refactor(lineage): take the patterns from the shared lib :recycle:"
```

---

### Task 3: Historian adopts the lib, closing the two gaps

**Files:**
- Create: `plugins/historian/scripts/lib/onlooker-secret-patterns.sh` (manual first copy)
- Modify: `plugins/historian/scripts/lib/historian-sanitizer.sh:29-123`
- Modify: `test/bats/historian-session-end.bats:155-180`

**Interfaces:**
- Consumes: `onlooker_redact_secrets <json_array_of_strings>` from Task 1.
- Produces: `historian_sanitizer_run <chunks_json> <never_index_paths_json>
  <redact_secret_patterns> <drop_skip_marker>` → `{"kept": [...], "dropped": [...]}`.
  Signature and output shape unchanged.

- [ ] **Step 1: Write the failing test**

In `test/bats/historian-session-end.bats`, find the fixture at line ~160 that builds
`turn_body` from `fake_aws`, `fake_gh` and `fake_anthropic`. Add the two shapes historian
writes verbatim today, and assert they are gone.

Replace the fixture block with:

```bash
  fake_anthropic="s""k-ant-veryverylongtokenvalue1234"
  # The two shapes historian wrote verbatim before ONL-167: a bare sk- key
  # (it had sk-ant- only) and a JSON-style pair (its KV pattern accepted `=`
  # only). lineage redacted both; historian did not.
  fake_openai="s""k-plainopenaistyletokenvalue99"
  fake_json_secret="j""sonsecretvalue1234567890"
  local turn_body
  turn_body=$(printf 'Here'"'"'s an AWS key: %s. And a GitHub PAT %s. And API_TOKEN=%s. And Bearer abcdefghijklmnopqrstuvwxyz. And %s. And "api_key": "%s".' \
    "$fake_aws" "$fake_gh" "$fake_anthropic" "$fake_openai" "$fake_json_secret")
  _append_text_turn "user" "$turn_body"
```

and add these assertions beside the three existing ones:

```bash
  ! grep -F -q "$fake_openai" "$jsonl" || return 1
  ! grep -F -q "$fake_json_secret" "$jsonl" || return 1
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/historian-session-end.bats --filter "redact"`
Expected: FAIL on one of the two new assertions — historian writes both shapes verbatim
today, which is the bug.

- [ ] **Step 3: Vendor the lib**

```bash
cp scripts/lib/onlooker-secret-patterns.sh plugins/historian/scripts/lib/onlooker-secret-patterns.sh
```

- [ ] **Step 4: Rewrite the sanitizer to call the shared lib**

In `plugins/historian/scripts/lib/historian-sanitizer.sh`, add the source line below the
header comment (above `historian_sanitizer_run`):

```bash
# shellcheck source=./onlooker-secret-patterns.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/onlooker-secret-patterns.sh"
```

Then replace the function body so the python block no longer carries patterns. The drop
filtering runs first and decides which bodies survive; only those are sent for redaction,
and the results are zipped back by position:

```bash
historian_sanitizer_run() {
	local chunks="${1:-[]}"
	local never_index_paths="${2:-[]}"
	local redact_secrets="${3:-true}"
	local drop_skip="${4:-true}"

	# Pass 1: drop filtering. Decides which chunks survive, in order, so the
	# redaction batch below is positionally aligned with `kept`.
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
        dropped.append({"chunk_index": chunk.get("chunk_index"), "reason": "skip_marker"})
        continue
    if deny_paths and any(p and p in body for p in deny_paths):
        dropped.append({"chunk_index": chunk.get("chunk_index"), "reason": "never_index_path"})
        continue
    kept.append(chunk)

print(json.dumps({"kept": kept, "dropped": dropped}))
PY
	) || return 0
	[[ -z "$split" ]] && return 0

	# Pass 2: redaction, one shared call over every surviving body.
	local redacted='[]'
	if [[ "$redact_secrets" != "false" ]]; then
		local bodies
		bodies=$(printf '%s' "$split" | jq -c '[.kept[] | (.body // "")]') || return 0
		redacted=$(onlooker_redact_secrets "$bodies" 2>/dev/null) || return 0
		# Fail closed: no raw body may be emitted because redaction failed.
		[[ -z "$redacted" ]] && return 0
	fi

	# Zip the results back on. With redaction off, every body copies through
	# with count 0 - the shape the previous implementation produced too.
	printf '%s' "$split" | jq -c \
		--argjson red "$redacted" \
		--arg on "$redact_secrets" '
		{
			kept: [ .kept | to_entries[] | .key as $i | .value
				| del(.body)
				+ (if $on == "false"
				   then {body_redacted: (.body // ""), redaction_count: 0}
				   else {body_redacted: $red[$i].redacted, redaction_count: $red[$i].count}
				   end) ],
			dropped: .dropped
		}'
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `ONLOOKER_VALIDATE=1 bats test/bats/historian-session-end.bats`
Expected: all tests pass, including the two new assertions.

- [ ] **Step 6: Verify the previously-leaking shapes directly**

```bash
source plugins/historian/scripts/lib/historian-sanitizer.sh
SAMPLE='s''k-cccccccccccccccccccccccc and "api_key": "ffffffffffffffff"'
historian_sanitizer_run "$(jq -cn --arg b "$SAMPLE" '[{body:$b}]')" '[]' true true \
  | jq -r '.kept[0].body_redacted'
```

Expected: both values replaced by `[REDACTED:secret]`. Before this task the same command
printed both verbatim.

- [ ] **Step 7: Verify the redaction-off path still copies bodies through**

```bash
historian_sanitizer_run "$(jq -cn '[{body:"API_KEY=plaintext"}]')" '[]' false true \
  | jq -r '.kept[0] | "\(.body_redacted) count=\(.redaction_count)"'
```

Expected: `API_KEY=plaintext count=0`. The `redact_secret_patterns: false` config knob
must still bypass redaction rather than silently redacting anyway.

- [ ] **Step 8: Run the full suite and the vendoring checks**

Run: `scripts/sync-shared-libs.sh --check` → `all vendored copies match their canonical libs`
Run: `npm run test:ci` → exit 0

- [ ] **Step 9: Commit**

```bash
git add plugins/historian/scripts/lib/onlooker-secret-patterns.sh plugins/historian/scripts/lib/historian-sanitizer.sh test/bats/historian-session-end.bats
git commit -m "fix(historian): redact the two shapes its own copy missed :lock:"
```

---

## Self-Review

**Spec coverage.** Each spec decision maps to a task: §1 one lib / batch interface →
Task 1 Steps 3, 6; §2 lineage's superset → Task 1 Step 3 (`TOKEN_PATTERNS` and
`KV_PATTERN` copied verbatim from lineage); §3 callers keep their contracts → Task 2
Step 3 (truncation and bypass stay) and Task 3 Step 4 (drop filtering, `{kept, dropped}`,
counts stay); §4 fail-closed as a tested property → Task 1 Step 1 (`fails closed when
python3 is unavailable`), Task 2 Step 5, Task 3 Step 4. The spec's Testing section maps to
Task 1's shape table, Task 1 Step 5 (break-it-on-purpose), and Task 3 Step 1 (the two gap
shapes against historian). The spec's JSON round-trip risk maps to Task 1's
`quotes and newlines survive the JSON round trip`.

**Placeholder scan.** No TBD/TODO, no "handle edge cases", no "similar to Task N". Every
code step carries the literal content.

**Type consistency.** `onlooker_redact_secrets` is called identically in Tasks 2 and 3 —
one positional JSON-array argument, output read as `.[i].redacted` and `.[i].count`.
`lineage_redact` and `historian_sanitizer_run` keep their existing signatures, so no
caller outside these files changes.

**One gap found and closed during review:** Task 3's original sketch sent every chunk body
for redaction and filtered afterward, which would have misaligned the zip whenever a chunk
was dropped. Step 4 now filters first and redacts only survivors, and Task 1's
`the batch result is positionally aligned with its input` test exists to make that
alignment a contract rather than an assumption.
