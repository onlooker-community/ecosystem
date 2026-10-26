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
# network tool but names no host customs can read (`nc "$HOST" 80`).
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
# A host label shaped like a secret (`https://<key>.evil.test/`), checked on
# the lowercased candidate. The host validator accepts these, so without this
# the key would be written into the event's hosts and the prompt's reason. It
# mirrors TOKEN_PATTERNS in onlooker-secret-patterns.sh; reusing that would
# start python3 a second time per call. gh*_ already fails the validator on
# its underscore and is listed for clarity.
_CUSTOMS_SECRET_LABEL_RE='(^|[.@-])(akia[0-9a-z]{16}|sk-[a-z0-9_-]{20,}|gh[pousr]_)'
# A WebFetch URL that a URL parser reads differently from grep. WHATWG treats
# `\` like `/`, so `https://evil.test\@api.github.com/` goes to evil.test, and
# it drops tabs and newlines, joining what grep splits. Customs does not parse
# URLs, so it declines to read one with any of these.
_CUSTOMS_URL_ODD_RE='[\[:space:][:cntrl:]]'

# Each tool's own arguments are read positionally (ONL-211). A word after the
# tool that is not an option, nor the value of one, is a destination candidate,
# whatever its shape: `evil.test.`, `1.2.3.4`, `localhost:9` and `[::1]` all
# reach the validator, which asks on anything it cannot read. An earlier
# reader took only `name.tld` words, so those shapes went unchecked beside a
# readable URL.
#
# Options listed under _VALUE take the next word as a value, which is skipped:
# that is what keeps `curl -o out.json` and `-H 'Authorization: …'` from
# reading as hosts. Only options known to take a value belong there, because a
# wrong entry hides the word after it. An option missing from the list costs
# a prompt at most. Options under _HOST take a host as their value
# (`--proxy evil.test`, `ssh -J jump.test`), which is read like a destination.
_CUSTOMS_CURL_VALUE=" -d -H -u -A -e -b -c -o -T -F -w -X -m -E -K -D -r -Y -y -z -U -Q -t -P -C
	--data --data-raw --data-binary --data-urlencode --data-ascii --json --header
	--user --user-agent --referer --cookie --cookie-jar --output --output-dir
	--upload-file --form --form-string --write-out --request --max-time
	--connect-timeout --retry --retry-delay --retry-max-time --limit-rate --cert
	--key --cacert --capath --config --dump-header --range --oauth2-bearer
	--url-query --variable --trace --trace-ascii --stderr --proxy-user
	--speed-limit --speed-time --time-cond --aws-sigv4 --pass --cert-type
	--key-type --ciphers --proto --proto-redir --max-filesize --expect100-timeout
	--keepalive-time --local-port --quote --telnet-option --ftp-port
	--continue-at "
_CUSTOMS_CURL_HOST=" -x --proxy --preproxy --url --socks4 --socks4a --socks5 --socks5-hostname
	--connect-to --resolve --interface --dns-servers --unix-socket "
_CUSTOMS_WGET_VALUE=" -O -o -a -P -U -T -t -w -i -Q -l -B -D -R -A -I -X
	--output-document --output-file --append-output --directory-prefix
	--user-agent --timeout --tries --wait --input-file --quota --level
	--base --domains --reject --accept --include-directories
	--exclude-directories --header --user --password --http-user --http-password
	--post-data --post-file --body-data --body-file --method --referer
	--load-cookies --save-cookies --limit-rate --bind-address "
# A wgetrc command can set a proxy (`-e https_proxy=evil.test`), so it is read
# as a destination. It never validates as a host, so it asks.
_CUSTOMS_WGET_HOST=" -e --execute "
# httpie (http, https) and xh share one shape: `[METHOD] URL [ITEM…]`. Request
# items (`Authorization:token`, `a=b`) follow the URL, so only the first
# positional that is not a method is a destination.
_CUSTOMS_HTTPIE_VALUE=" -a -A -o -p -P -s --auth --auth-type --output --print
	--history-print --style --session --session-read-only --verify --cert
	--cert-key --timeout --max-redirects --pretty --format-options --boundary
	--default-scheme --response-charset --response-mime --ssl --ciphers --raw
	--bearer "
_CUSTOMS_HTTPIE_HOST=" --proxy --resolve --interface --unix-socket "
# OpenBSD nc and ncat disagree on some letters: -c is a TLS flag in one and
# takes a command in the other. Only letters that take a value in both are here.
_CUSTOMS_NC_VALUE=" -p -s -w -i -q -I -O -T -V -X -e -m -M -o -P -g -G
	--proxy-type --proxy-auth --exec --sh-exec --lua-exec --output --wait
	--source --source-port "
_CUSTOMS_NC_HOST=" -x --proxy "
# ssh, scp and sftp share a list, so a letter that is a flag in any of them
# (ssh -X, ssh -s) is left out: listing it would hide the host after it.
_CUSTOMS_SSH_VALUE=" -b -B -c -D -E -e -F -I -i -L -l -m -O -o -p -P -Q -R -S -w "
_CUSTOMS_SSH_HOST=" -J -W "
_CUSTOMS_RSYNC_VALUE=" -e -f -T -B -M --rsh --port --exclude --include --filter
	--password-file --temp-dir --log-file --chmod --chown --block-size --timeout
	--contimeout --bwlimit --compare-dest --copy-dest --link-dest --backup-dir
	--suffix --files-from --exclude-from --include-from --remote-option
	--rsync-path --address --sockopts --out-format --log-file-format --max-size
	--min-size --max-delete --modify-window --partial-dir --usermap --groupmap
	--iconv --checksum-choice --compress-choice --compress-level "

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

	# gh api talks to api.github.com unless told otherwise.
	if [[ "$text" =~ $_CUSTOMS_GH_API_RE ]]; then
		local gh_host="api.github.com"
		if [[ "$text" =~ --hostname[=[:space:]]+([^[:space:]]+) ]]; then
			gh_host="${BASH_REMATCH[1]}"
		fi
		printf '%s\n' "$gh_host"
	fi
}

_CUSTOMS_WS_RUN_RE='^[[:space:]]+'
_CUSTOMS_SQ_RUN_RE="^'([^']*)'?"
_CUSTOMS_DQ_RUN_RE='^"([^"]*)"?'
_CUSTOMS_ESC_RUN_RE='^[\\](.?)'
_CUSTOMS_PLAIN_RUN_RE="^[^'\"\\[:space:]]+"

# Split <text> into words near enough to how a shell would: whitespace outside
# quotes separates, quotes group and are dropped, a backslash takes the next
# character. An unclosed quote runs to the end, which is what text cut out of
# `sh -c '…'` looks like. Expansions are left as written, so a `$URL` stays a
# word the validator cannot read.
_customs_words() {
	local text="$1" word="" have=0 run
	# Byte semantics: in a UTF-8 locale bash walks a string from the start to
	# reach an offset, which made this quadratic in the command's length.
	local LC_ALL=C
	# Each pass consumes one whole run, so a 20 KB quoted body is one match
	# rather than 20,000 iterations.
	while [[ -n "$text" ]]; do
		run=""
		if [[ "$text" =~ $_CUSTOMS_WS_RUN_RE ]]; then
			run="${BASH_REMATCH[0]}"
			if ((have)); then printf '%s\n' "$word"; fi
			word=""
			have=0
		elif [[ "$text" =~ $_CUSTOMS_SQ_RUN_RE || "$text" =~ $_CUSTOMS_DQ_RUN_RE || "$text" =~ $_CUSTOMS_ESC_RUN_RE ]]; then
			run="${BASH_REMATCH[0]}"
			word+="${BASH_REMATCH[1]}"
			have=1
		elif [[ "$text" =~ $_CUSTOMS_PLAIN_RUN_RE ]]; then
			run="${BASH_REMATCH[0]}"
			word+="$run"
			have=1
		fi
		# Every branch above matches at least one character. If none did,
		# stop rather than spin.
		[[ -n "$run" ]] || break
		text="${text:${#run}}"
	done
	if ((have)); then printf '%s\n' "$word"; fi
}

# The host a destination word names: no path, query or fragment, no userinfo,
# no port. A word with a scheme is skipped, since _customs_candidates already
# read it. What cannot be reduced to a name is printed as written, so the
# validator rejects it rather than it vanishing: `[::1]`, `$HOST`, an empty
# authority.
_customs_word_host() {
	local w="$1" h
	[[ -n "$w" && "$w" != *://* ]] || return 0
	h="${w%%[/?#]*}"
	h="${h##*@}"
	if [[ "$h" != \[* && "$h" =~ ^(.*):[0-9]*$ ]]; then
		h="${BASH_REMATCH[1]}"
	fi
	# `:3000/x` is httpie and xh shorthand for localhost.
	if [[ -z "$h" && "$w" == :* ]]; then
		h="localhost"
	fi
	printf '%s\n' "${h:-$w}"
}

# The destinations one network tool names in the words after it.
_customs_tool_hosts() {
	local tool="$1" args="$2" w value_opts="" host_opts=""
	local skip=0 hostnext=0 opts_done=0 got=0
	case "$tool" in
		curl) value_opts="$_CUSTOMS_CURL_VALUE"; host_opts="$_CUSTOMS_CURL_HOST" ;;
		wget) value_opts="$_CUSTOMS_WGET_VALUE"; host_opts="$_CUSTOMS_WGET_HOST" ;;
		http | https | xh) value_opts="$_CUSTOMS_HTTPIE_VALUE"; host_opts="$_CUSTOMS_HTTPIE_HOST" ;;
		nc | ncat) value_opts="$_CUSTOMS_NC_VALUE"; host_opts="$_CUSTOMS_NC_HOST" ;;
		ssh | scp | sftp) value_opts="$_CUSTOMS_SSH_VALUE"; host_opts="$_CUSTOMS_SSH_HOST" ;;
		rsync) value_opts="$_CUSTOMS_RSYNC_VALUE" ;;
	esac
	value_opts="${value_opts//[[:space:]]/ } "
	host_opts="${host_opts//[[:space:]]/ } "

	while IFS= read -r w; do
		if ((skip)); then skip=0; continue; fi
		if ((hostnext)); then hostnext=0; _customs_word_host "$w"; continue; fi
		# A redirection's target is a file or a here-string, not a destination.
		case "$w" in
			'<' | '<<' | '<<<' | '>' | '>>' | [0-9]'>' | [0-9]'>>' | '&>') skip=1; continue ;;
			'<'* | '>'* | [0-9]'>'*) continue ;;
		esac
		if ((!opts_done)) && [[ "$w" == -?* ]]; then
			if [[ "$w" == "--" ]]; then
				opts_done=1
			elif [[ "$w" == --*=* ]]; then
				[[ "$host_opts" == *" ${w%%=*} "* ]] && _customs_word_host "${w#*=}"
			elif [[ "$host_opts" == *" $w "* ]]; then
				hostnext=1
			elif [[ "$value_opts" == *" $w "* ]]; then
				skip=1
			fi
			continue
		fi
		case "$tool" in
			curl | wget) _customs_word_host "$w" ;;
			http | https | xh)
				# A method comes first when given; items follow the URL.
				((got)) && continue
				[[ "$w" =~ ^[A-Z]+$ ]] && continue
				_customs_word_host "$w"
				got=1
				;;
			nc | ncat | ssh | sftp)
				# The first positional is the host. What follows is a port or
				# a remote command, which runs elsewhere.
				_customs_word_host "$w"
				return 0
				;;
			scp | rsync)
				# Only a host:path (or host::module) word is remote. A colon
				# after a slash is part of a local path.
				[[ "$w" =~ ^[^/]*: ]] || continue
				_customs_word_host "${w%%:*}"
				;;
		esac
	done < <(_customs_words "$args")
	return 0
}

# Every network tool in one segment, each reading its own arguments.
_customs_segment_tool_hosts() {
	local rest="$1" before tool
	while [[ "$rest" =~ $_CUSTOMS_NET_TOOL_RE ]]; do
		tool="${BASH_REMATCH[3]}"
		before="$rest"
		rest="${rest#*"${BASH_REMATCH[0]}"}"
		# Each pass must consume the tool it found, or this never ends.
		[[ "$rest" != "$before" ]] || break
		_customs_tool_hosts "$tool" "$rest"
	done
}

customs_destination_hosts() {
	local tool="${1:-}"
	local text="${2:-}"
	local candidates seg tool_hosts host valid="" bad=0

	# No host is printed: what grep would read is the wrong host.
	if [[ "$tool" == "WebFetch" && "$text" =~ $_CUSTOMS_URL_ODD_RE ]]; then
		return 2
	fi

	candidates="$(_customs_candidates "$tool" "$text")"

	if [[ "$tool" == "Bash" ]]; then
		# Each command in the line must name its own destination, read from the
		# tool's own arguments. Without this, a URL anywhere in the line could
		# stand in for a host the tool itself names: `nc evil.test 80 <<<
		# "https://api.github.com …"` was decided on api.github.com alone
		# (ONL-211). The split ignores quotes, so `sh -c 'curl a.test; nc b.test
		# 80'` is split too. Splitting more can only find more segments that
		# need a host.
		while IFS= read -r seg; do
			customs_has_network_tool "$seg" || continue
			tool_hosts="$(_customs_segment_tool_hosts "$seg")"
			candidates+=$'\n'"$tool_hosts"
			if [[ -z "$tool_hosts" && -z "$(_customs_candidates Bash "$seg")" ]]; then
				bad=1
			fi
		done < <(printf '%s\n' "$text" | tr ';|&()`' '\n\n\n\n\n\n')
	fi

	# Normalize (lowercase, one trailing dot off), then classify each below.
	candidates="$(printf '%s\n' "$candidates" | tr '[:upper:]' '[:lower:]' | sed -E 's#\.$##')"

	while IFS= read -r host; do
		[[ -n "$host" ]] || continue
		# Unreadable, so the call asks, and never printed.
		if [[ "$host" =~ $_CUSTOMS_SECRET_LABEL_RE ]]; then
			bad=1
		elif [[ ${#host} -le 253 && "$host" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
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
