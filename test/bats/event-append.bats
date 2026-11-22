#!/usr/bin/env bats

# onlooker_append_line: one line, one write(), however many hooks emit at once
# (ONL-301). The race is reproduced, not reasoned about: concurrent writers
# append to one file and every line must come back whole.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	LIB="${REPO_ROOT}/scripts/lib/event-append.sh"
	source "$LIB"
	OUT="${BATS_TEST_TMPDIR}/out.jsonl"

	# Each writer appends 200 lines of one letter, so a torn line is any line
	# that is not a single run of one letter, the right length.
	WRITER="${BATS_TEST_TMPDIR}/writer.sh"
	cat >"$WRITER" <<'EOF'
#!/usr/bin/env bash
# $1 = mode (helper|printf), $2 = letter, $3 = line length, $4 = file, $5 = lib
source "$5"
line=$(head -c "$3" </dev/zero | tr '\0' "$2")
for _ in $(seq 200); do
	if [[ "$1" == helper ]]; then onlooker_append_line "$4" "$line"
	else printf '%s\n' "$line" >>"$4"; fi
done
EOF
	chmod +x "$WRITER"

	SHELLS=("$BASH")
	local candidate
	for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
		if [[ -x "$candidate" && "$candidate" != "$BASH" ]]; then SHELLS+=("$candidate"); fi
	done
}

# Runs 4 concurrent writers and prints "<torn> <total>".
_race() {
	local mode="$1" len="$2" shell="$3" w
	: >"$OUT"
	for w in a b c d; do "$shell" "$WRITER" "$mode" "$w" "$len" "$OUT" "$LIB" & done
	wait
	# awk, not a grep repetition count: BSD grep caps those at 255.
	LC_ALL=C awk -v n="$len" '
		{ c = substr($0, 1, 1); if (length($0) != n || $0 !~ ("^" c "+$")) torn++ }
		END { printf "%d %d\n", torn, NR }' "$OUT"
}

@test "the race is real: concurrent printf appends of long lines tear" {
	# The sibling of the test below. Without it, a platform where printf stopped
	# tearing would leave that test passing for a reason it does not check.
	local torn total
	read -r torn total < <(_race printf 8000 "$BASH")
	[ "$total" -ge 800 ] || return 1
	[ "$torn" -gt 0 ]
}

@test "concurrent appends through the helper never tear, on every bash here" {
	local shell len torn total
	for shell in "${SHELLS[@]}"; do
		# 1023 is the longest line the builtin keeps; 1024 is the first through cat.
		for len in 1023 1024 8000 60000; do
			read -r torn total < <(_race helper "$len" "$shell")
			[ "$total" -eq 800 ] || { echo "$shell len=$len: $total lines"; return 1; }
			[ "$torn" -eq 0 ] || { echo "$shell len=$len: $torn torn"; return 1; }
		done
	done
}

# A cat that records each call shows which path a line took.
_shim_cat() {
	local shim="${BATS_TEST_TMPDIR}/catshim" real_cat
	real_cat=$(command -v cat)
	mkdir -p "$shim"
	printf '#!/usr/bin/env bash\nprintf x >>"%s/cat-calls"\nexec "%s" "$@"\n' \
		"$BATS_TEST_TMPDIR" "$real_cat" >"${shim}/cat"
	chmod +x "${shim}/cat"
	PATH="${shim}:${PATH}"
}

_cat_calls() { [[ -f "${BATS_TEST_TMPDIR}/cat-calls" ]] && wc -c <"${BATS_TEST_TMPDIR}/cat-calls" | tr -d ' ' || echo 0; }

@test "a line that fits the buffer starts no process" {
	_shim_cat
	onlooker_append_line "$OUT" "$(head -c 1023 </dev/zero | tr '\0' a)" || return 1
	[ "$(_cat_calls)" -eq 0 ] || return 1
	[ "$(wc -c <"$OUT" | tr -d ' ')" -eq 1024 ]
}

@test "a line one byte past the buffer goes through cat, whole" {
	_shim_cat
	onlooker_append_line "$OUT" "$(head -c 1024 </dev/zero | tr '\0' a)" || return 1
	[ "$(_cat_calls)" -eq 1 ] || return 1
	[ "$(wc -c <"$OUT" | tr -d ' ')" -eq 1025 ]
}

@test "the threshold counts bytes, not characters" {
	_shim_cat
	local line
	# 600 two-byte characters: 600 by a UTF-8 count, 1,200 bytes on the wire.
	line=$(LC_ALL=C; for _ in $(seq 600); do printf '\303\251'; done)
	LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 onlooker_append_line "$OUT" "$line" || return 1
	[ "$(_cat_calls)" -eq 1 ] || return 1
	[ "$(wc -c <"$OUT" | tr -d ' ')" -eq 1201 ]
}

@test "a failed append returns non-zero on both paths" {
	run onlooker_append_line "${BATS_TEST_TMPDIR}/no/such/dir/log" "short"
	[ "$status" -ne 0 ] || return 1
	run onlooker_append_line "${BATS_TEST_TMPDIR}/no/such/dir/log" "$(head -c 2000 </dev/zero | tr '\0' a)"
	[ "$status" -ne 0 ]
}

@test "no emitter appends to the event log with printf" {
	run grep -rnE "printf '%s\\\\n' \"\\\$[a-z_]+\" >> ?\"\\\$(log_path|ONLOOKER_EVENTS_LOG)\"" \
		"${REPO_ROOT}/scripts" "${REPO_ROOT}"/plugins/*/scripts
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "every file that calls the helper defines it once sourced" {
	# Sourced, not grepped: the guard around each source line names the file
	# too, so a grep still matches with the source itself deleted.
	local f missing=()
	while IFS= read -r f; do
		[[ "$f" == */event-append.sh ]] && continue
		env -i PATH="$PATH" HOME="$HOME" bash -c \
			'source "$1" >/dev/null 2>&1; declare -F onlooker_append_line >/dev/null' _ "$f" \
			|| missing+=("$f")
	done < <(grep -rl 'onlooker_append_line' "${REPO_ROOT}/scripts" "${REPO_ROOT}"/plugins/*/scripts)
	[ "${#missing[@]}" -eq 0 ] || { printf '%s\n' "${missing[@]}"; return 1; }
}

@test "a real emitter's long events land whole under concurrency" {
	export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/archivist-events.sh"
	local title payload w
	title="Archivist Extract · $(head -c 4000 </dev/zero | tr '\0' t)"
	payload=$(jq -cn --arg t "$title" \
		'{plugin: "archivist", artifact_kind: "extract", artifact_path: "/tmp/x.json", artifact_title: $t}')
	for w in 1 2 3 4; do
		( for _ in 1 2 3 4 5 6; do archivist_emit_event "onlooker.artifact.ready" "$payload"; done ) &
	done
	wait
	[ "$(wc -l <"$ONLOOKER_EVENTS_LOG" | tr -d ' ')" -eq 24 ] || return 1
	# jq stops at the first line it cannot parse, so 24 means all 24 parsed.
	[ "$(jq -c . "$ONLOOKER_EVENTS_LOG" | wc -l | tr -d ' ')" -eq 24 ]
}
