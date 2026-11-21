#!/usr/bin/env bash
# Append one line to a JSONL log in a single write(), so concurrent writers
# never interleave inside it (ONL-301).
#
# Every emitter used to append with `printf '%s\n' "$event" >> "$log"`. bash's
# printf goes through stdio, and stdio flushes a full buffer at a time, so a
# line longer than the buffer reaches the file as several write() calls.
# O_APPEND makes each write() land whole, not each line: two hooks emitting at
# once interleave between the pieces, and the log gets a line no JSON parser
# reads. With 4 concurrent writers, measured on macOS 2026-11-21:
#
#   line + newline   bash 3.2.57      bash 5.3.15
#   1,024 bytes      0 / 1200 torn    0 / 1200 torn
#   1,025 bytes      617 / 1200       744 / 1200
#   4,000 bytes      603 / 1600       1,322 / 1600
#
# `cat` reads the line from a here-string and writes what it read in one call,
# and tore none of 800 lines at any size up to 200KB on either bash. It costs a
# process start (~3ms), so lines that already fit the buffer keep the builtin:
# p50 of a real event is ~500 bytes, and ~4% run past 1KB (max seen 61KB).
#
# This lib is VENDORED into every plugin by scripts/sync-shared-libs.sh. Edit
# the canonical copy at scripts/lib/, run the sync script, commit both. It
# depends on nothing but bash and coreutils.

# The largest line, newline included, that stdio writes in one call. 1,024 is
# macOS's BUFSIZ and the smallest buffer measured; glibc's is larger.
_ONLOOKER_APPEND_ONE_WRITE_MAX=1024

# Usage: onlooker_append_line <path> <line>
# Returns the append's own status; the caller owns creating the directory.
onlooker_append_line() {
	local path="$1" line="$2"
	# ${#line} counts characters in a UTF-8 locale, and the buffer is in bytes.
	local LC_ALL=C
	if (( ${#line} < _ONLOOKER_APPEND_ONE_WRITE_MAX )); then
		printf '%s\n' "$line" >>"$path"
	else
		cat <<<"$line" >>"$path"
	fi
}
