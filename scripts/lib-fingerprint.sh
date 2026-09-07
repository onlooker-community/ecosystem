#!/usr/bin/env bash
# Content fingerprint of a vendored shared lib.
#
# ecosystem-449.31. hook-health.sh is vendored into every plugin, and plugins
# install independently, so one session can have the substrate on one copy and
# every plugin on another. Records written in that window mixed two attribution
# schemes with nothing in the record to tell them apart.
#
# The fingerprint goes IN the record so a rollup can partition rows by which
# copy wrote them. It has to be derived from the file's own bytes: a directory
# name, a package.json version and a directory mtime have each been observed
# disagreeing with the contents they label (see 449.27 and 449.31). A
# hand-bumped constant would be a fourth such label, so this is computed and
# verified by test instead.
#
# The fingerprint line is neutralized before hashing, so the value does not
# depend on itself.
#
# Usage:
#   lib_fingerprint <file>          # print the 12-hex fingerprint of its content
#   lib_fingerprint_stamped <file>  # print the fingerprint currently written in it

LIB_FINGERPRINT_MARKER='_ONLOOKER_LIB_FINGERPRINT='

_lib_fingerprint_sha12() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

lib_fingerprint() {
	local file="${1:?file required}"
	[[ -f "$file" ]] || return 1
	sed "s/^${LIB_FINGERPRINT_MARKER}.*/${LIB_FINGERPRINT_MARKER}PLACEHOLDER/" "$file" \
		| _lib_fingerprint_sha12
}

lib_fingerprint_stamped() {
	local file="${1:?file required}"
	[[ -f "$file" ]] || return 1
	sed -n "s/^${LIB_FINGERPRINT_MARKER}[\"']\\{0,1\\}\\([0-9a-f]*\\).*/\\1/p" "$file" | head -1
}

# Rewrite FILE's fingerprint line to match its own content. Returns 0 if it
# changed, 1 if it was already correct.
lib_fingerprint_stamp() {
	local file="${1:?file required}" want have tmp
	want=$(lib_fingerprint "$file") || return 1
	have=$(lib_fingerprint_stamped "$file")
	[[ "$want" == "$have" ]] && return 1
	tmp="${file}.fp.$$"
	sed "s/^${LIB_FINGERPRINT_MARKER}.*/${LIB_FINGERPRINT_MARKER}\"${want}\"/" "$file" > "$tmp" \
		&& cat "$tmp" > "$file"
	rm -f "$tmp"
	return 0
}
