#!/usr/bin/env bash
# Memory store reader for Curator.
#
# Parses ~/.claude/projects/<encoded-project>/memory/MEMORY.md and the
# referenced *.md files. Returns a JSON array of memory records:
#
#   [
#     {
#       "filename": "feedback_no_trailing_summaries.md",
#       "title": "...",                       # from frontmatter `name` or MEMORY.md link
#       "type": "feedback",                   # from frontmatter `type`
#       "body": "...",                        # everything after the frontmatter
#       "exists": true,                       # false when MEMORY.md points at a missing file
#       "frontmatter_parsed": true|false
#     },
#     ...
#   ]
#
# Orphans (files present in the memory dir but not referenced from MEMORY.md)
# get their own record with `referenced: false`. Broken index entries
# (referenced by MEMORY.md but missing on disk) get `exists: false`.

# Returns 0 iff the given filename contains a path separator, parent-dir
# escape, leading dot, null byte, or other shape that should never get
# joined onto the memory dir. Used to defang MEMORY.md entries before we
# interpolate them into a filesystem path.
_curator_memory_unsafe_filename() {
	local fname="$1"
	[[ -z "$fname" ]] && return 0
	case "$fname" in
		# Absolute paths, traversal, separators, dotfiles, control chars.
		/*|*/*|*\\*|*..*|.*|*$'\n'*|*$'\r'*) return 0 ;;
	esac
	# Must end in .md and look like a plain filename.
	[[ "$fname" == *.md ]] || return 0
	[[ "$fname" =~ ^[A-Za-z0-9._-]+\.md$ ]] || return 0
	return 1
}

# Resolve the memory store path. The runtime resolves
# $CLAUDE_PROJECT_ENCODED — when unset, the caller provides it explicitly.
#
# Usage: curator_memory_resolve_path <memory_store_path_template> [encoded]
# Returns the resolved absolute path, or empty if it can't be resolved.
#
# ${CLAUDE_CONFIG_DIR} is the placeholder that matters. Claude Code exports
# CLAUDE_CONFIG_DIR to hook processes and it is not always $HOME/.claude — this
# machine uses ~/.claude-personal. The template used to hardcode that segment,
# so curator audited a directory that could not exist and reported nothing
# (ecosystem-449.18). The fallback matches validate-path.sh:19 exactly, so the
# default install is unaffected.
#
# Interpolation is parameter expansion, never eval: the template reaches here
# from <repo>/.claude/settings.json, so a repo could otherwise supply
# $(...) and have it run (ecosystem-18f).
curator_memory_resolve_path() {
	local template="$1"
	[[ -z "$template" ]] && return 0
	local encoded="${2:-${CLAUDE_PROJECT_ENCODED:-}}"
	local config_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"

	# Bail before substituting, not after. The old guard tested for the
	# placeholder in the ALREADY-SUBSTITUTED string, where an empty encoding
	# has replaced it with nothing — so it never fired, and an unresolvable
	# template silently produced ".../projects//memory": a real-looking path
	# pointing at the wrong place, which a caller would happily mkdir.
	if [[ -z "$encoded" && "$template" == *'${CLAUDE_PROJECT_ENCODED}'* ]]; then
		return 0
	fi

	# Best-effort interpolation. The template may contain ${CLAUDE_CONFIG_DIR},
	# ${HOME} and ${CLAUDE_PROJECT_ENCODED}.
	local resolved
	resolved="${template//\$\{CLAUDE_CONFIG_DIR\}/${config_dir}}"
	resolved="${resolved//\$\{HOME\}/${HOME:-}}"
	resolved="${resolved//\$\{CLAUDE_PROJECT_ENCODED\}/${encoded}}"
	printf '%s' "$resolved"
}

# Load every memory file referenced by MEMORY.md plus every file in the dir.
# Output: JSON array of memory records (as defined at the top of this file).
#
# One jq reads every file, whatever the store size. Parsing each file in its own
# processes cost 2.5s at 51 memories, which spent the scan budget before any
# check could run (ONL-235). --rawfile rather than `jq -R` over the files,
# because -R runs a last line with no newline into the next file.
#
# Usage: curator_memory_load_all <memory_dir_abs>
curator_memory_load_all() {
	local mem_dir="$1"
	[[ -z "$mem_dir" || ! -d "$mem_dir" ]] && { echo '[]'; return 0; }

	# 1. Parse MEMORY.md for referenced filenames.
	local index_path="${mem_dir}/MEMORY.md"
	local referenced_list=()
	if [[ -f "$index_path" ]]; then
		# Match the standard line format: `- [Title](file.md) — hook`
		while IFS= read -r line; do
			referenced_list+=("$line")
		done < <(grep -oE '\[[^]]+\]\([^)]+\)' "$index_path" 2>/dev/null \
			| sed -E 's/.*\(([^)]+)\)/\1/' | awk '{ print }')
	fi

	# 2. Plan one `<kind>\t<file index>\t<filename>` row per record, and bind
	#    each file that exists to $ARGS.named.
	local plan="" seen=$'\n' fname file slot
	local tab=$'\t' nl=$'\n'
	local rawfiles=() file_count=0

	_curator_memory_plan() {
		local kind="$1" path="$2"
		slot=""
		if [[ -f "$path" ]]; then
			slot="f${file_count}"
			file_count=$((file_count + 1))
			rawfiles+=(--rawfile "$slot" "$path")
		fi
		plan+="${kind}${tab}${slot}${tab}${fname}${nl}"
	}

	# Referenced first — preserves MEMORY.md ordering for downstream display.
	# Filename sanitization: anything with a path separator, parent-dir
	# escape, leading dot, or non-printable bytes is recorded as a broken
	# index entry and NEVER passed to the parser. Without this guard a
	# MEMORY.md entry like `[X](../../etc/passwd)` would read outside the
	# memory dir.
	if [[ ${#referenced_list[@]} -gt 0 ]]; then
		for fname in "${referenced_list[@]}"; do
			[[ -z "$fname" || "$fname" == "null" ]] && continue
			# Skip MEMORY.md itself if it self-references.
			[[ "$fname" == "MEMORY.md" ]] && continue

			if _curator_memory_unsafe_filename "$fname"; then
				plan+="unsafe${tab}${tab}${fname}${nl}"
			else
				_curator_memory_plan referenced "${mem_dir}/${fname}"
			fi
			seen+="${fname}${nl}"
		done
	fi

	# Then any orphans (files on disk not referenced from MEMORY.md).
	for file in "$mem_dir"/*.md; do
		[[ -f "$file" ]] || continue
		fname="${file##*/}"
		[[ "$fname" == "MEMORY.md" ]] && continue
		case "$seen" in *"${nl}${fname}${nl}"*) continue ;; esac
		_curator_memory_plan orphan "$file"
	done
	unset -f _curator_memory_plan

	# 3. Build the records. Extract simple `key: value` lines until the closing
	#    `---`. Fancier YAML (nested, lists) isn't expected in the auto-memory
	#    format.
	jq -cn --arg plan "$plan" "${rawfiles[@]+"${rawfiles[@]}"}" '
		def field($lines; $key):
			first(
				($lines[] | select(startswith($key + ":"))
					| sub("^" + $key + ":[[:space:]]*"; "")),
				""
			)
			| if . == "" then null else . end;

		def drop_trailing_blanks:
			until(length == 0 or .[-1] != ""; .[:-1]);

		def parsed($filename; $referenced; $raw):
			($raw | split("\n") | drop_trailing_blanks) as $lines
			| if ($lines | length) > 0 and ($lines[0] | startswith("---")) then
				($lines[1:] | map(startswith("---")) | index(true)) as $close
				| (if $close == null then $lines[1:] else $lines[1:$close + 1] end) as $fm
				| {
					filename: $filename,
					title: field($fm; "name"),
					description: field($fm; "description"),
					type: field($fm; "type"),
					body: (if $close == null then "" else $lines[$close + 2:] | join("\n") end),
					exists: true,
					referenced: $referenced,
					frontmatter_parsed: true
				}
			else
				{
					filename: $filename,
					title: null, description: null, type: null,
					body: ($lines | join("\n")),
					exists: true,
					referenced: $referenced,
					frontmatter_parsed: false
				}
			end;

		[
			$plan | split("\n")[] | select(. != "") | split("\t")
			| .[0] as $kind | .[1] as $slot | (.[2:] | join("\t")) as $filename
			| if $kind == "unsafe" then
				{
					filename: $filename,
					title: null, description: null, type: null, body: "",
					exists: false, referenced: true,
					frontmatter_parsed: false, unsafe: true
				}
			elif $slot == "" then
				{
					filename: $filename,
					title: null, type: null, body: "",
					exists: false, referenced: ($kind == "referenced"),
					frontmatter_parsed: false
				}
			else
				parsed($filename; $kind == "referenced"; $ARGS.named[$slot])
			end
		]
	'
}
