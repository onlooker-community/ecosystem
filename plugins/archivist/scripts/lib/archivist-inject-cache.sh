#!/usr/bin/env bash
# The SessionStart injection list, rendered and cached per project.
#
# Rendering reads every artifact the project has to show at most max_items of
# them: ~60ms of jq at 1,345 artifacts, about 2.4x that under SessionStart
# contention. So the rendered list is cached in .inject-cache, and answers
# while it is strictly newer than each kind directory, pinned.json and this
# file. Every writer creates a file per artifact, so a write moves its
# directory's mtime; a hand edit made in place does not, and is not seen until
# the next artifact is written or a pin changes.
#
# A cache only archivist-inject built was nearly always stale by the next
# start, because archivist writes at the two moments just before one: the mine
# worker after SessionEnd, the extractor at PreCompact. Each 0.10.6 startup and
# compact inject measured rebuilt, at ~540ms p50 against ~65ms for a hit
# (ONL-260). So those writers call archivist_inject_cache_warm after writing,
# off the SessionStart path, and the start that follows answers from it.
#
# Exposes:
#   archivist_inject_cache_prepare <project_key>  # after archivist_config_load
#   archivist_inject_cache_read                   # 0 on a fresh hit
#   archivist_inject_cache_build <project_key>    # render and cache
#   archivist_inject_cache_warm <project_key> <cwd>
#
# read and build leave the answer in ARCHIVIST_INJECT_N, ARCHIVIST_INJECT_TOTAL
# and ARCHIVIST_INJECT_BODY: the count injected, the total, and the list
# escaped for a JSON string.

_ARCHIVIST_INJECT_CACHE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ARCHIVIST_INJECT_CACHE_SELF="${_ARCHIVIST_INJECT_CACHE_DIR}/archivist-inject-cache.sh"

# Only when absent: sourcing archivist-config.sh again would reset a config the
# caller has already loaded.
# shellcheck source=./archivist-storage.sh
declare -F archivist_project_dir >/dev/null || source "${_ARCHIVIST_INJECT_CACHE_DIR}/archivist-storage.sh"
# shellcheck source=./archivist-config.sh
declare -F archivist_config_load >/dev/null || source "${_ARCHIVIST_INJECT_CACHE_DIR}/archivist-config.sh"

ARCHIVIST_INJECT_N="" ARCHIVIST_INJECT_TOTAL="" ARCHIVIST_INJECT_BODY=""

# Resolves the budgets, the cache path and the key the body is rendered under.
# Which paths exist is part of the key, since a kind directory that appears
# with an old mtime would otherwise pass as fresh. So is this file's own path:
# each release installs to its own directory.
archivist_inject_cache_prepare() {
	local key="$1" p
	_AIC_MAX_ITEMS=$(archivist_config_int '.archivist.injection.max_items' 8)
	_AIC_MAX_CHARS=$(archivist_config_int '.archivist.injection.max_chars' 2400)
	_AIC_INCLUDE_DEAD_ENDS=$(archivist_config_get '.archivist.injection.include_dead_ends')
	_AIC_INCLUDE_OPEN_QUESTIONS=$(archivist_config_get '.archivist.injection.include_open_questions')
	_AIC_PROJECT_DIR=$(archivist_project_dir "$key")
	_AIC_CACHE_FILE="${_AIC_PROJECT_DIR}/.inject-cache"
	_AIC_CACHE_KEY="v2|${_ARCHIVIST_INJECT_CACHE_SELF}|${_AIC_MAX_ITEMS}|${_AIC_MAX_CHARS}|${_AIC_INCLUDE_DEAD_ENDS}|${_AIC_INCLUDE_OPEN_QUESTIONS}|"
	for p in decisions dead_ends open_questions pinned.json; do
		if [[ -e "${_AIC_PROJECT_DIR}/${p}" ]]; then _AIC_CACHE_KEY+="1"; else _AIC_CACHE_KEY+="0"; fi
	done
}

# 0 when the cache may answer: strictly newer than everything its body was
# rendered from. A change in the same second is a miss, as bash 3.2 compares
# whole seconds.
_archivist_inject_cache_fresh() {
	local p
	[[ -f "$_AIC_CACHE_FILE" && "$_AIC_CACHE_FILE" -nt "$_ARCHIVIST_INJECT_CACHE_SELF" ]] || return 1
	for p in decisions dead_ends open_questions pinned.json; do
		[[ -e "${_AIC_PROJECT_DIR}/${p}" && ! "$_AIC_CACHE_FILE" -nt "${_AIC_PROJECT_DIR}/${p}" ]] && return 1
	done
	return 0
}

archivist_inject_cache_read() {
	_archivist_inject_cache_fresh || return 1
	local k="" n="" total="" body=""
	{ IFS= read -r k; IFS= read -r n; IFS= read -r total; IFS= read -r body; } <"$_AIC_CACHE_FILE" 2>/dev/null
	[[ "$k" == "$_AIC_CACHE_KEY" && "$n" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || return 1
	ARCHIVIST_INJECT_N="$n" ARCHIVIST_INJECT_TOTAL="$total" ARCHIVIST_INJECT_BODY="$body"
	return 0
}

# Renders the list and caches it. 1 when the render produced nothing usable.
archivist_inject_cache_build() {
	local key="$1"
	ARCHIVIST_INJECT_N="" ARCHIVIST_INJECT_TOTAL="" ARCHIVIST_INJECT_BODY=""

	# Stamp the cache with the time this read began, not the time it ends: an
	# artifact written mid-read is then newer than the cache that missed it. No
	# stamp, as in a store this cannot write to, means no cache.
	local mark="${_AIC_CACHE_FILE}.$$"
	: >"$mark" 2>/dev/null || mark=""

	# The whole render is one jq over the ranked list. It used to run several jq
	# calls per rendered item, each re-parsing every artifact the project has:
	# ~780ms for 8 items at 1,221 artifacts (ONL-114). It runs inside the jq that
	# reads the artifacts, so the corpus is parsed once. The budgets count
	# characters, as ${#LINE} did under the UTF-8 locale sessions run in.
	#
	# It prints three lines: the count injected, the total, and the body escaped
	# for a JSON string, which is what the cache stores.
	local output
	output=$(archivist_storage_load_ranked "$key" "$(cat <<'JQ'
		def text: if . == null or . == false then "" elif type == "string" then . else tojson end;

		def kind_label:
			if . == "decisions" then "decision"
			elif . == "dead_ends" then "dead-end"
			elif . == "open_questions" then "open-question"
			else . end;
		# null when the item has no summary, which skips it without counting.
		def line:
			((.summary // "") | text) as $summary
			| if $summary == "" then null else
				((.detail // "") | text) as $detail
				| ((try ((.files // []) | join(", ")) catch "") // "") as $files
				| (if .pinned == true then "- [pinned \((.kind // "" | text) | kind_label)] " else "- [\((.kind // "" | text) | kind_label)] " end)
					+ $summary
					+ (if $detail != "" and $detail != "null" then "\n  " + $detail else "" end)
					+ (if $files != "" then "\n  files: " + $files else "" end)
			end;

		"Archivist — carried over from prior sessions in this repo (kind | summary):" as $header
		| length as $total
		| map(select(
			($include_dead_ends == "true" or .kind != "dead_ends")
			and ($include_open_questions == "true" or .kind != "open_questions")))
		| reduce .[] as $item ({text: $header, chars: ($header | length), n: 0, done: false};
			if .done then .
			elif .n >= $max_items then .done = true
			else ($item | line) as $line
				| if $line == null then .
				elif .chars + ($line | length) + 1 > $max_chars then .done = true
				else .text += "\n" + $line | .chars += ($line | length) + 1 | .n += 1
				end
			end)
		| "\(.n)\n\($total)\n" + (if .n == 0 then "" else .text | tojson | .[1:-1] end)
JQ
)" -r \
		--argjson max_items "$_AIC_MAX_ITEMS" \
		--argjson max_chars "$_AIC_MAX_CHARS" \
		--arg include_dead_ends "$_AIC_INCLUDE_DEAD_ENDS" \
		--arg include_open_questions "$_AIC_INCLUDE_OPEN_QUESTIONS" 2>/dev/null) || output=""

	local n="" total="" body=""
	{ IFS= read -r n; IFS= read -r total; IFS= read -r body; } <<<"$output"

	if [[ ! "$n" =~ ^[0-9]+$ || ! "$total" =~ ^[0-9]+$ ]]; then
		[[ -n "$mark" ]] && rm -f "$mark"
		return 1
	fi
	ARCHIVIST_INJECT_N="$n" ARCHIVIST_INJECT_TOTAL="$total" ARCHIVIST_INJECT_BODY="$body"

	# Written beside the stamp, given its mtime, then renamed into place, so a
	# reader never sees a partial cache or one stamped later than its read.
	if [[ -n "$mark" ]]; then
		if printf '%s\n%s\n%s\n%s\n' "$_AIC_CACHE_KEY" "$n" "$total" "$body" >"${mark}.tmp" 2>/dev/null \
			&& touch -r "$mark" "${mark}.tmp" 2>/dev/null; then
			mv -f "${mark}.tmp" "$_AIC_CACHE_FILE" 2>/dev/null || rm -f "${mark}.tmp"
		else
			rm -f "${mark}.tmp"
		fi
		rm -f "$mark"
	fi
	return 0
}

# Leaves a cache the next SessionStart can answer from. For a writer, after
# its writes: it waits out the current second first, since a cache stamped in
# the same second as the write it follows is not strictly newer, and misses.
# Config is loaded from cwd, as archivist-inject loads it, so both resolve the
# same key.
archivist_inject_cache_warm() {
	local key="$1" cwd="${2:-}" started
	[[ -n "$key" ]] || return 0
	archivist_config_load "$cwd"
	archivist_inject_cache_prepare "$key"
	[[ -d "$_AIC_PROJECT_DIR" ]] || return 0
	started=$(date +%s)
	while [[ "$(date +%s)" == "$started" ]]; do sleep 0.1; done
	archivist_inject_cache_build "$key" >/dev/null || true
	return 0
}
