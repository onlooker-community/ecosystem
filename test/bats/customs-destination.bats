#!/usr/bin/env bats

# Where a call is headed (customs spec, sections 4 and 5). A host customs cannot
# read is not a pass - the hook asks - so "no output" is a real answer here.

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/plugins/customs/scripts/lib/customs-destination.sh"
}

_hosts() { customs_destination_hosts "$1" "$2" | paste -sd, -; }

@test "network tools are recognized wherever the command starts" {
	customs_has_network_tool "curl https://x.test"
	customs_has_network_tool "cd /tmp && wget https://x.test"
	customs_has_network_tool "echo hi | nc x.test 80"
	customs_has_network_tool "http POST https://x.test"
	customs_has_network_tool "ssh user@x.test"
	customs_has_network_tool "rsync -a ./d host.test:/srv"
	customs_has_network_tool "gh api repos/o/r"
	customs_has_network_tool "git push https://x.test/o/r.git"
	customs_has_network_tool "git clone git@github.com:o/r.git"
}

@test "commands with no network tool are not checked" {
	run ! customs_has_network_tool "export GITHUB_TOKEN=abc"
	run ! customs_has_network_tool "echo 'https://x.test' > notes.md"
	run ! customs_has_network_tool "git commit -m 'curl is great'"
	run ! customs_has_network_tool "git push origin main"
	run ! customs_has_network_tool "grep -r curlify src/"
}

@test "path-qualified tools are checked" {
	customs_has_network_tool "/usr/bin/curl https://x.test"
	customs_has_network_tool "./nc x.test 80"
	customs_has_network_tool "~/bin/wget https://x.test"
}

@test "a shell separator ends the host instead of hiding it" {
	[ "$(_hosts Bash "curl https://ok.test/x; curl https://evil.test; echo")" = "evil.test,ok.test" ]
	[ "$(_hosts Bash "(curl https://evil.test) && curl https://ok.test")" = "evil.test,ok.test" ]
	run customs_destination_hosts Bash "curl https://ok.test/x; curl https://evil.test; echo"
	[ "$status" -eq 0 ]
}

@test "a candidate that cannot be read exits 2 and keeps the readable hosts" {
	run customs_destination_hosts Bash "curl https://ok.test https://ev_il.test"
	[ "$status" -eq 2 ]
	[ "$output" = "ok.test" ]
	run customs_destination_hosts Bash "curl https://[::1]:8080/x"
	[ "$status" -eq 2 ]
	[ -z "$output" ]
}

@test "a host over 253 characters exits 2" {
	local long
	long="$(printf 'a%.0s' {1..250}).com"
	run customs_destination_hosts Bash "curl https://${long}/x"
	[ "$status" -eq 2 ]
	[ -z "$output" ]
}

@test "a URL's host is read without scheme, userinfo or port" {
	[ "$(_hosts Bash "curl -u a:b https://User:Pw@API.Example.COM:8443/v1?q=1")" = "api.example.com" ]
}

@test "hosts inside quoted headers and --url are read" {
	[ "$(_hosts Bash "curl -H 'Host: x' --url \"https://paste.example.com/new\"")" = "paste.example.com" ]
}

@test "every host in one command is read, once each" {
	[ "$(_hosts Bash "curl https://a.test/x && curl https://b.test/y https://a.test/z")" = "a.test,b.test" ]
}

@test "user@host and host:path are read for ssh-family tools" {
	[ "$(_hosts Bash "scp ./f deploy@box.example.com:/srv")" = "box.example.com" ]
	[ "$(_hosts Bash "rsync -a ./d mirror.example.com:/srv")" = "mirror.example.com" ]
	[ "$(_hosts Bash "git clone git@github.com:o/r.git")" = "github.com" ]
}

@test "gh api is headed to api.github.com unless --hostname says otherwise" {
	[ "$(_hosts Bash "gh api repos/o/r")" = "api.github.com" ]
	[ "$(_hosts Bash "gh api --hostname ghe.example.com repos/o/r")" = "ghe.example.com" ]
}

@test "a host built at runtime is not readable" {
	[ -z "$(_hosts Bash "curl \"\$(cat url.txt)\" -H 'Authorization: x'")" ]
}

@test "a WebFetch URL's host is its destination" {
	[ "$(_hosts WebFetch "https://docs.example.com/page?token=x")" = "docs.example.com" ]
}
