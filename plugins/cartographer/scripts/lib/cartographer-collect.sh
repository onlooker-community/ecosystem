#!/usr/bin/env bash
# cartographer-collect.sh — discover all auditable instruction files under a repo root.
#
# Finds:
#   - CLAUDE.md files (all depths up to max_depth)
#   - AGENTS.md files (all depths up to max_depth)
#   - .claude/rules/*.md files (global and repo-level)
#
# Applies exclude_paths (substring filter) to the collected list.
#
# Usage:
#   cartographer_collect_files <repo_root> <exclude_paths_json> [max_depth]
#   # prints one absolute path per line

cartographer_collect_files() {
	local repo_root="${1:?repo_root required}"
	local exclude_json="${2:-[]}"
	local max_depth="${3:-5}"

	# Build find -not -path exclusions
	local find_excludes=()
	while IFS= read -r excl; do
		[[ -z "$excl" ]] && continue
		find_excludes+=(-not -path "*/${excl}/*")
	done < <(printf '%s' "$exclude_json" | jq -r '.[]' 2>/dev/null)

	# Discover CLAUDE.md and AGENTS.md
	find "$repo_root" -maxdepth "$max_depth" \
		\( -name "CLAUDE.md" -o -name "AGENTS.md" \) \
		"${find_excludes[@]}" \
		-type f 2>/dev/null

	# Discover .claude/rules/*.md at repo level
	if [[ -d "$repo_root/.claude/rules" ]]; then
		find "$repo_root/.claude/rules" -maxdepth 2 -type f -name "*.md" 2>/dev/null
	fi
}

cartographer_collect_global_files() {
	# Global ~/.claude/CLAUDE.md and ~/.claude/rules/*.md
	if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
		printf '%s\n' "$HOME/.claude/CLAUDE.md"
	fi
	if [[ -d "$HOME/.claude/rules" ]]; then
		find "$HOME/.claude/rules" -maxdepth 2 -type f -name "*.md" 2>/dev/null
	fi
}

cartographer_file_content_hash() {
	local path="$1"
	[[ ! -f "$path" ]] && return 1
	if command -v sha256sum &>/dev/null; then
		sha256sum "$path" | cut -c1-16
	elif command -v shasum &>/dev/null; then
		shasum -a 256 "$path" | cut -c1-16
	else
		python3 -c "import sys,hashlib; print(hashlib.sha256(open('$path','rb').read()).hexdigest()[:16])"
	fi
}
