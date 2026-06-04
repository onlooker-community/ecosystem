#!/usr/bin/env bash
# Cheap-tier checks for Curator.
#
# Pure data transforms over the memory record array produced by
# curator-memory-reader.sh. Each function returns a JSON array of findings
# of a single kind. Callers attach the project key and persist via
# curator-storage.sh.
#
# All checks are intentionally cheap — string scans and file-exists
# probes only. The LLM contradiction sweep lives in its own module.

# Date check. Scans memory bodies for ISO-8601 dates (YYYY-MM-DD) and
# flags any that are more than <grace_period_days> in the past, on the
# theory that those are most likely decayed deadlines or stale "by date"
# references the body never updated.
#
# Usage: curator_check_dates <memories_json> <grace_period_days>
# Output: JSON array of date_decayed finding payload candidates.
#         (Caller assigns finding_id and deduped_hash.)
curator_check_dates() {
	local memories="${1:-[]}"
	local grace="${2:-14}"

	local today
	today=$(date -u +"%Y-%m-%d")

	# Extract every YYYY-MM-DD substring per memory body via jq, then hand
	# the candidate list to python for precise date math and grace-period
	# filtering. Python gets the JSON as an argv (not stdin) because the
	# heredoc-on-stdin pattern collides with piped input — see SC2259.
	local candidates
	candidates=$(printf '%s' "$memories" | jq -c '
		[ .[] | select(.exists and .body != null and .body != "")
			| .filename as $fname
			| (.body | [scan("[0-9]{4}-[0-9]{2}-[0-9]{2}")])
			| .[]
			| { memory_file: $fname, matched_phrase: . }
		]
	')

	python3 - "$today" "$grace" "$candidates" <<'PY'
import json, sys, datetime

today_str = sys.argv[1]
grace = int(sys.argv[2])
data = json.loads(sys.argv[3] or "[]")
today = datetime.datetime.strptime(today_str, "%Y-%m-%d").date()
out = []
for entry in data:
    try:
        d = datetime.datetime.strptime(entry["matched_phrase"], "%Y-%m-%d").date()
    except (ValueError, KeyError):
        continue
    days_past = (today - d).days
    if days_past > grace:
        out.append({
            "memory_file": entry["memory_file"],
            "matched_phrase": entry["matched_phrase"],
            "days_past": days_past,
        })
print(json.dumps(out))
PY
}

# Path reference check. For each memory, scans the body for path-shaped
# strings ("scripts/foo.py", "src/lib/bar.ts", etc.) and emits a finding
# when the path doesn't resolve under the given repo root.
#
# Path heuristic: at least one `/`, contains an extension (`.ext`), and
# only matches the conservative character class `[A-Za-z0-9._/-]+`. The
# goal is to avoid both runaway false positives ("foo/bar baz" — has a
# space, skipped) and to be sensitive to renames (`scripts/old_name.py`
# really getting flagged when renamed to `scripts/new_name.py`).
#
# Usage: curator_check_paths <memories_json> <repo_root>
curator_check_paths() {
	local memories="${1:-[]}"
	local repo_root="${2:-}"

	[[ -z "$repo_root" || ! -d "$repo_root" ]] && { echo '[]'; return 0; }

	local abs_root
	abs_root=$(cd "$repo_root" 2>/dev/null && pwd -P) || { echo '[]'; return 0; }

	# Extract candidate paths per memory body. The jq scan regex returns
	# every match in the body; deduping happens after.
	local candidates
	candidates=$(printf '%s' "$memories" | jq -c '
		[ .[] | select(.exists and .body != null and .body != "")
			| .filename as $fname
			| (.body | [scan("[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+\\.[A-Za-z0-9]+")])
			| unique
			| .[]
			| { memory_file: $fname, candidate: . }
		]
	')

	# Walk each candidate, drop ones that resolve. JSON goes via argv to
	# avoid the SC2259 stdin clobber pattern that the date check tripped.
	local candidates_compact
	candidates_compact=$(printf '%s' "$candidates" | jq -c '.')
	python3 - "$abs_root" "$candidates_compact" <<'PY'
import json, os, sys

repo_root = sys.argv[1]
data = json.loads(sys.argv[2] or "[]")
out = []
for entry in data:
    candidate = entry["candidate"]
    abs_candidate = candidate if candidate.startswith("/") else os.path.join(repo_root, candidate)
    if os.path.exists(abs_candidate):
        continue
    # Strip the repo root prefix when reporting absolute matches.
    reported = candidate
    if candidate.startswith(repo_root + os.sep):
        reported = candidate[len(repo_root) + 1:]
    out.append({
        "memory_file": entry["memory_file"],
        "broken_path": reported,
    })
print(json.dumps(out))
PY
}

# Broken-index check: MEMORY.md references a file that doesn't exist on
# disk. The memory reader already encodes this via the `exists: false`
# record; this check just shapes it into a finding payload.
#
# Usage: curator_check_broken_index <memories_json>
curator_check_broken_index() {
	local memories="${1:-[]}"
	printf '%s' "$memories" | jq -c '
		[ .[] | select(.referenced == true and .exists == false)
			| { referenced_file: .filename }
		]
	'
}

# Orphaned memory: file in the dir but not referenced from MEMORY.md.
#
# Usage: curator_check_orphaned <memories_json>
curator_check_orphaned() {
	local memories="${1:-[]}"
	printf '%s' "$memories" | jq -c '
		[ .[] | select(.referenced == false and .exists == true)
			| { memory_file: .filename }
		]
	'
}
