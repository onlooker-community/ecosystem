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
# Exposes:
#   customs_has_network_tool <command>          exit 0 when a network tool runs
#   customs_destination_hosts <tool> <text>     one host per line, sorted, unique

_CUSTOMS_LEAD='(^|[[:space:];|&(`])'
_CUSTOMS_NET_TOOL_RE="${_CUSTOMS_LEAD}(curl|wget|http|https|xh|nc|ncat|ssh|scp|sftp|rsync)([[:space:]]|$)"
_CUSTOMS_GH_API_RE="${_CUSTOMS_LEAD}gh[[:space:]]+api([[:space:]]|$)"
# git only counts when the remote is written in the command. `git push origin`
# names a remote whose URL lives in .git/config, which customs does not read.
_CUSTOMS_GIT_REMOTE_RE="${_CUSTOMS_LEAD}git[[:space:]].*([a-z]+://|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:)"

customs_has_network_tool() {
	local cmd="${1:-}"
	[[ "$cmd" =~ $_CUSTOMS_NET_TOOL_RE ]] && return 0
	[[ "$cmd" =~ $_CUSTOMS_GH_API_RE ]] && return 0
	[[ "$cmd" =~ $_CUSTOMS_GIT_REMOTE_RE ]] && return 0
	return 1
}

customs_destination_hosts() {
	local tool="${1:-}"
	local text="${2:-}"

	{
		# scheme://[userinfo@]host[:port], stopping at the path, query, fragment,
		# whitespace or a closing quote.
		printf '%s\n' "$text" \
			| grep -oiE "[a-z][a-z0-9+.-]*://[^/[:space:]\"'?#]+" \
			| sed -E 's#^[^:]+://##; s#^.*@##; s#:[0-9]*$##'

		if [[ "$tool" == "Bash" ]]; then
			# user@host and user@host:path. Preceded by a space or a quote only, so
			# "email=me@x.test" in a form body is not read as a destination.
			printf '%s\n' "$text" \
				| grep -oE "(^|[[:space:]\"'])[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}" \
				| sed -E 's#^.*@##'

			# host:path with no user, which only scp and rsync accept.
			if [[ "$text" =~ ${_CUSTOMS_LEAD}(scp|rsync)[[:space:]] ]]; then
				printf '%s\n' "$text" \
					| grep -oE '(^|[[:space:]])[A-Za-z0-9.-]+\.[A-Za-z]{2,}:' \
					| sed -E 's#^[[:space:]]*##; s#:$##'
			fi

			# gh api talks to api.github.com unless told otherwise.
			if [[ "$text" =~ $_CUSTOMS_GH_API_RE ]]; then
				local gh_host="api.github.com"
				if [[ "$text" =~ --hostname[=[:space:]]+([A-Za-z0-9.-]+) ]]; then
					gh_host="${BASH_REMATCH[1]}"
				fi
				printf '%s\n' "$gh_host"
			fi
		fi
	} | tr '[:upper:]' '[:lower:]' \
		| sed -E 's#\.$##' \
		| grep -E '^[a-z0-9][a-z0-9.-]*$' \
		| sort -u

	return 0
}
