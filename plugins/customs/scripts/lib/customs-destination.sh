#!/usr/bin/env bash
# Where a Bash command or a WebFetch URL is headed, for customs.
#
# Customs guards egress, not storage, so a Bash command is only checked when it
# runs a known network tool. customs_has_network_tool is a bash [[ =~ ]] with
# no subprocess, because it runs on every Bash call and most of them match
# nothing: those exit before python3 starts.
#
# Host reading is heuristic and errs toward asking. A host built at runtime
# (`curl "$(cat url.txt)"`) prints nothing, and the hook treats "no host" as a
# reason to ask, never as a pass. A stray extra host can only add a prompt.
#
# A candidate that is found but cannot be read as a valid host (`ev_il.test`,
# `[::1]`, a name over 253 characters) is never dropped silently: the function
# exits 2. That is a reason to ask even when another host in the same command
# was readable, because the readable one says nothing about where the
# unreadable one goes. The same holds for a command in the line that runs a
# network tool but names no host customs can read (`nc evil.test 80`).
#
# Exposes:
#   customs_has_network_tool <command>          exit 0 when a network tool runs
#   customs_destination_hosts <tool> <text>     one host per line, sorted, unique;
#                                               exit 0 = every candidate was read
#                                               (no output = none found),
#                                               exit 2 = at least one candidate
#                                               could not be read as a host, or
#                                               a network command named none

# A tool starts after a separator, a subshell or backtick, a backslash (`\curl`
# skips an alias), or a quote, so `sh -c 'curl …'`, `bash -c "curl …"` and
# `"curl" …` are seen. The cost: a quoted mention (`git commit -m 'curl is
# great'`) runs detection too, and asks only if a secret is also present.
_CUSTOMS_LEAD="(^|[[:space:];|&(\`\\\"'])"
# A tool's name ends at whitespace, a closing quote, or the end of the text.
_CUSTOMS_TRAIL="([[:space:]\"']|$)"
# An optional directory prefix, so /usr/bin/curl and ./nc count as the tool.
_CUSTOMS_PATH='([^[:space:];|&(`]*/)?'
_CUSTOMS_NET_TOOL_RE="${_CUSTOMS_LEAD}${_CUSTOMS_PATH}(curl|wget|http|https|xh|nc|ncat|ssh|scp|sftp|rsync)${_CUSTOMS_TRAIL}"
_CUSTOMS_GH_API_RE="${_CUSTOMS_LEAD}${_CUSTOMS_PATH}gh[[:space:]]+api([[:space:]]|$)"
# git only counts when the remote is written in the command. `git push origin`
# names a remote whose URL lives in .git/config, which customs does not read.
_CUSTOMS_GIT_REMOTE_RE="${_CUSTOMS_LEAD}${_CUSTOMS_PATH}git[[:space:]].*([a-z]+://|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:)"
_CUSTOMS_SCP_RSYNC_RE="${_CUSTOMS_LEAD}${_CUSTOMS_PATH}(scp|rsync)[[:space:]]"
# The HTTP clients that take a destination with no scheme (`curl evil.test/x`,
# `wget api.github.com`), so a bare host-shaped word is read as one for them.
_CUSTOMS_BARE_HOST_TOOL_RE="${_CUSTOMS_LEAD}${_CUSTOMS_PATH}(curl|wget|http|https|xh)${_CUSTOMS_TRAIL}"
# One whitespace-split word shaped like name.tld, optionally quoted, after an
# optional --opt=, and ending at a quote, a port or path, or the word's end. It
# also catches file names (`-o out.json`), which only adds a prompt.
_CUSTOMS_BARE_HOST_WORD_RE="^(--[a-z-]+=)?[\"']?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}([\"'/:]|$)"

customs_has_network_tool() {
	local cmd="${1:-}"
	[[ "$cmd" =~ $_CUSTOMS_NET_TOOL_RE ]] && return 0
	[[ "$cmd" =~ $_CUSTOMS_GH_API_RE ]] && return 0
	[[ "$cmd" =~ $_CUSTOMS_GIT_REMOTE_RE ]] && return 0
	return 1
}

# Every raw candidate in <text>, one per line, with scheme, userinfo and port
# off but not yet lowercased or classified.
_customs_candidates() {
	local tool="$1" text="$2"

	# scheme://[userinfo@]host[:port], stopping at the path, query, fragment,
	# whitespace, a quote, or a shell separator.
	printf '%s\n' "$text" \
		| grep -oiE "[a-z][a-z0-9+.-]*://[^/[:space:]\"'?#;)|&,\`<>]+" \
		| sed -E 's#^[^:]+://##; s#^.*@##; s#:[0-9]*$##'

	[[ "$tool" == "Bash" ]] || return 0

	# user@host and user@host:path. Preceded by a space or a quote only, so
	# "email=me@x.test" in a form body is not read as a destination.
	printf '%s\n' "$text" \
		| grep -oE "(^|[[:space:]\"'])[A-Za-z0-9._-]+@[^[:space:]\"'/:;|&,)<>\`]+" \
		| sed -E 's#^.*@##'

	# host:path with no user, which only scp and rsync accept.
	if [[ "$text" =~ $_CUSTOMS_SCP_RSYNC_RE ]]; then
		printf '%s\n' "$text" \
			| grep -oE '(^|[[:space:]])[A-Za-z0-9._-]+\.[A-Za-z]{2,}:' \
			| sed -E 's#^[[:space:]]*##; s#:$##'
	fi

	# gh api talks to api.github.com unless told otherwise.
	if [[ "$text" =~ $_CUSTOMS_GH_API_RE ]]; then
		local gh_host="api.github.com"
		if [[ "$text" =~ --hostname[=[:space:]]+([^[:space:]]+) ]]; then
			gh_host="${BASH_REMATCH[1]}"
		fi
		printf '%s\n' "$gh_host"
	fi
}

# Bare host-shaped words in one segment, for the HTTP clients that accept them.
_customs_bare_hosts() {
	printf '%s\n' "$1" | tr '[:space:]' '\n' \
		| grep -oE "$_CUSTOMS_BARE_HOST_WORD_RE" \
		| sed -E "s#^--[a-z-]+=##; s#[\"']##g; s#[/:]\$##"
}

customs_destination_hosts() {
	local tool="${1:-}"
	local text="${2:-}"
	local candidates seg bare host valid="" bad=0

	candidates="$(_customs_candidates "$tool" "$text")"

	if [[ "$tool" == "Bash" ]]; then
		# Each command in the line must name its own destination. Without this,
		# `echo https://api.github.com; nc evil.test 80` was decided on
		# api.github.com alone, because nc's host has no shape customs reads. The
		# split ignores quotes, so `sh -c 'curl a.test; nc b.test 80'` is split
		# too. Splitting more can only find more segments that need a host.
		while IFS= read -r seg; do
			customs_has_network_tool "$seg" || continue
			bare=""
			if [[ "$seg" =~ $_CUSTOMS_BARE_HOST_TOOL_RE ]]; then
				bare="$(_customs_bare_hosts "$seg")"
				candidates+=$'\n'"$bare"
			fi
			if [[ -z "$bare" && -z "$(_customs_candidates Bash "$seg")" ]]; then
				bad=1
			fi
		done < <(printf '%s\n' "$text" | tr ';|&()`' '\n\n\n\n\n\n')
	fi

	# Normalize (lowercase, one trailing dot off), then classify each below.
	candidates="$(printf '%s\n' "$candidates" | tr '[:upper:]' '[:lower:]' | sed -E 's#\.$##')"

	while IFS= read -r host; do
		[[ -n "$host" ]] || continue
		if [[ ${#host} -le 253 && "$host" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
			valid+="${host}"$'\n'
		else
			bad=1
		fi
	done <<<"$candidates"

	if [[ -n "$valid" ]]; then
		printf '%s' "$valid" | sort -u
	fi

	[[ "$bad" -eq 0 ]] || return 2
	return 0
}
