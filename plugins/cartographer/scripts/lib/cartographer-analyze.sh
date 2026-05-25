#!/usr/bin/env bash
# cartographer-analyze.sh — LLM-assisted analysis of instruction files.
#
# Orchestrates four analysis phases:
#   1. contradiction  — rules that cannot both be satisfied simultaneously
#   2. stale_ref      — references to paths/tools that no longer exist
#   3. dead_rule      — rules subsumed elsewhere or referencing removed workflows
#   4. scope_collision — project rules duplicating or contradicting global rules
#
# Each phase calls `claude -p` and produces a JSON findings array.
# Findings are normalized and returned for deduplication + storage.
#
# Usage:
#   cartographer_analyze_contradiction  <files_json> <model> <max_tokens> <phase_timeout>
#   cartographer_analyze_stale_ref      <files_json> <repo_root> <model> <max_tokens> <phase_timeout>
#   cartographer_analyze_scope_collision <global_files_json> <project_files_json> <model> <max_tokens> <phase_timeout>
#
# Note: contradiction detection also flags dead_rule findings in a single LLM pass.
#
# Each function prints a JSON array of finding objects on stdout:
#   [{type, severity, file_a, excerpt_a, file_b, excerpt_b, description, suggested_fix}]

_CARTOGRAPHER_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || printf 'timeout')

_cartographer_read_files_for_prompt() {
	local files_json="$1"
	local output=""
	while IFS= read -r fpath; do
		[[ -z "$fpath" || ! -f "$fpath" ]] && continue
		output+=$'\n<FILE: '"$fpath"$'>\n'
		output+=$(cat "$fpath")
		output+=$'\n</FILE>\n'
	done < <(printf '%s' "$files_json" | jq -r '.[]' 2>/dev/null)
	printf '%s' "$output"
}

cartographer_analyze_contradiction() {
	local files_json="$1"
	local model="${2:-claude-haiku-4-5-20251001}"
	local max_tokens="${3:-2048}"
	local timeout_s="${4:-60}"

	local corpus
	corpus=$(_cartographer_read_files_for_prompt "$files_json")
	[[ -z "$corpus" ]] && printf '[]' && return 0

	local prompt
	prompt=$(cat <<'PROMPT'
You are an expert technical editor reviewing Claude Code instruction files for internal consistency.

Your task: identify any CONTRADICTIONS — pairs of rules that cannot both be satisfied at the same time. A contradiction exists only when following rule A makes it impossible or directly inconsistent to follow rule B. Do not flag rules that are merely different or address different contexts.

Also identify any DEAD RULES — rules that are fully redundant because a more specific rule elsewhere already covers exactly the same ground.

Output ONLY a JSON array. Each element:
{
  "type": "contradiction" | "dead_rule",
  "severity": "error" | "warning",
  "file_a": "<absolute path>",
  "excerpt_a": "<quoted text ≤150 chars>",
  "file_b": "<absolute path>",
  "excerpt_b": "<quoted text ≤150 chars>",
  "description": "<one sentence explaining the conflict or redundancy>",
  "suggested_fix": "<one sentence concrete action>"
}

Severity: "error" if following both rules would violate safety or produce incorrect output; "warning" otherwise.
If no issues found, output: []
PROMPT
)

	local full_prompt="${prompt}

${corpus}"

	local response
	response=$(printf '%s' "$full_prompt" \
		| $_CARTOGRAPHER_TIMEOUT_CMD "$timeout_s" claude -p \
			--model "$model" \
			--max-tokens "$max_tokens" \
			2>/dev/null) || { printf '[]'; return 1; }

	printf '%s' "$response" | python3 -c "
import sys, json
raw = sys.stdin.read()
start = raw.find('[')
end = raw.rfind(']') + 1
if start < 0 or end <= start:
    print('[]')
else:
    try:
        arr = json.loads(raw[start:end])
        print(json.dumps(arr))
    except Exception:
        print('[]')
" 2>/dev/null || printf '[]'
}

cartographer_analyze_stale_ref() {
	local files_json="$1"
	local repo_root="$2"
	local model="${3:-claude-haiku-4-5-20251001}"
	local max_tokens="${4:-2048}"
	local timeout_s="${5:-60}"

	# bash pre-pass: extract path-like tokens and test on filesystem
	local candidates=""
	while IFS= read -r fpath; do
		[[ -z "$fpath" || ! -f "$fpath" ]] && continue
		local line_no=0
		while IFS= read -r line; do
			(( line_no++ ))
			# extract tokens that look like relative/absolute paths
			local tokens
			tokens=$(printf '%s' "$line" | grep -oE '[./][a-zA-Z0-9_/.-]{3,}' 2>/dev/null || true)
			while IFS= read -r tok; do
				[[ -z "$tok" ]] && continue
				# resolve relative to repo root
				local resolved="$repo_root/$tok"
				if [[ ! -e "$resolved" && ! -e "$tok" ]]; then
					candidates+="FILE=$fpath LINE=$line_no TOKEN=$tok CONTEXT=$(printf '%s' "$line" | cut -c1-120)"$'\n'
				fi
			done < <(printf '%s\n' "$tokens")
		done <"$fpath"
	done < <(printf '%s' "$files_json" | jq -r '.[]' 2>/dev/null)

	[[ -z "$candidates" ]] && printf '[]' && return 0

	local prompt
	prompt=$(cat <<'PROMPT'
You are reviewing references extracted from Claude Code instruction files. Each reference could not be resolved on the filesystem.

Classify each as:
- "stale": a genuine reference to something that should exist but does not
- "example": an illustrative or hypothetical path, not a real reference
- "ambiguous": cannot tell from context

Output ONLY a JSON array (only include items classified as "stale"):
{
  "type": "stale_ref",
  "severity": "warning",
  "file_a": "<path>",
  "excerpt_a": "<the unresolvable reference token>",
  "file_b": null,
  "excerpt_b": null,
  "description": "<one sentence>",
  "suggested_fix": "<one sentence, or null>"
}

If none are stale, output: []
PROMPT
)
	local full_prompt="${prompt}

<CANDIDATES>
${candidates}
</CANDIDATES>"

	local response
	response=$(printf '%s' "$full_prompt" \
		| $_CARTOGRAPHER_TIMEOUT_CMD "$timeout_s" claude -p \
			--model "$model" \
			--max-tokens "$max_tokens" \
			2>/dev/null) || { printf '[]'; return 1; }

	printf '%s' "$response" | python3 -c "
import sys, json
raw = sys.stdin.read()
start = raw.find('[')
end = raw.rfind(']') + 1
if start < 0 or end <= start:
    print('[]')
else:
    try:
        arr = json.loads(raw[start:end])
        print(json.dumps(arr))
    except Exception:
        print('[]')
" 2>/dev/null || printf '[]'
}

cartographer_analyze_scope_collision() {
	local global_json="$1"
	local project_json="$2"
	local model="${3:-claude-haiku-4-5-20251001}"
	local max_tokens="${4:-2048}"
	local timeout_s="${5:-60}"

	local global_files project_files
	global_files=$(_cartographer_read_files_for_prompt "$global_json")
	project_files=$(_cartographer_read_files_for_prompt "$project_json")

	[[ -z "$global_files" || -z "$project_files" ]] && printf '[]' && return 0

	local prompt
	prompt=$(cat <<'PROMPT'
You are auditing Claude Code instruction files for scope collisions between global and project-level files.

The GLOBAL file applies to all projects. The PROJECT files apply only to this project. Project rules override global rules when they conflict.

Identify SCOPE COLLISIONS:
1. Exact or near-exact duplications where the project rule adds nothing new
2. Contradictions where it is unclear from context that the project is intentionally overriding the global

Do NOT flag intentional, clearly-worded overrides like "For this project, use X instead of the global default Y".

Output ONLY a JSON array:
{
  "type": "scope_collision",
  "severity": "warning",
  "file_a": "<global file path>",
  "excerpt_a": "<global rule ≤150 chars>",
  "file_b": "<project file path>",
  "excerpt_b": "<project rule ≤150 chars>",
  "description": "<one sentence>",
  "suggested_fix": "<one sentence>"
}

If none found, output: []
PROMPT
)

	local full_prompt="${prompt}

<GLOBAL FILES>
${global_files}
</GLOBAL FILES>

<PROJECT FILES>
${project_files}
</PROJECT FILES>"

	local response
	response=$(printf '%s' "$full_prompt" \
		| $_CARTOGRAPHER_TIMEOUT_CMD "$timeout_s" claude -p \
			--model "$model" \
			--max-tokens "$max_tokens" \
			2>/dev/null) || { printf '[]'; return 1; }

	printf '%s' "$response" | python3 -c "
import sys, json
raw = sys.stdin.read()
start = raw.find('[')
end = raw.rfind(']') + 1
if start < 0 or end <= start:
    print('[]')
else:
    try:
        arr = json.loads(raw[start:end])
        print(json.dumps(arr))
    except Exception:
        print('[]')
" 2>/dev/null || printf '[]'
}

# Compute the canonical finding hash (commutative across file_a/file_b).
cartographer_finding_hash() {
	local type="$1"
	local file_a="$2"
	local excerpt_a="$3"
	local file_b="${4:-}"
	local excerpt_b="${5:-}"

	# Sort files so A→B and B→A produce the same hash
	local sorted_files
	if [[ "$file_a" < "$file_b" ]]; then
		sorted_files="${file_a}:::${file_b}"
	else
		sorted_files="${file_b}:::${file_a}"
	fi

	# Normalize excerpts: strip leading/trailing whitespace, collapse internal runs
	local norm_a norm_b
	norm_a=$(printf '%s' "$excerpt_a" | tr -s ' \t\n' ' ' | sed 's/^ //;s/ $//')
	norm_b=$(printf '%s' "$excerpt_b" | tr -s ' \t\n' ' ' | sed 's/^ //;s/ $//')

	local input="${type}:${sorted_files}:${norm_a}:${norm_b}"
	if command -v sha256sum &>/dev/null; then
		printf '%s' "$input" | sha256sum | cut -c1-16
	elif command -v shasum &>/dev/null; then
		printf '%s' "$input" | shasum -a 256 | cut -c1-16
	else
		printf '%s' "$input" | python3 -c \
			'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'
	fi
}
