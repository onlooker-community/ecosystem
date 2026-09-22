#!/usr/bin/env bash
# Hook execution timing for Onlooker hooks — ecosystem substrate and plugins.
#
# This file is VENDORED into every plugin's scripts/lib/. Edit this canonical
# copy and run scripts/sync-shared-libs.sh to propagate it; drift is caught by
# test/bats/shared-lib-vendoring.bats.
#
# It is deliberately self-contained. A plugin publishes rooted at
# plugins/<name> and ships no ecosystem tree, so this file may not source
# validate-path.sh or anything else (ecosystem-ber).
#
# Usage, at the top of a hook:
#   source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
#   hook_health_register "my-plugin-post-tool-use"
#   INPUT=$(cat)
#   hook_health_context "$INPUT"
#
# Fail-soft throughout: every function returns 0. A hook must never break
# because its instrument broke.
#
# What duration_ms actually measures, since consumers cannot infer it:
# from the clock read inside hook_health_register to the clock read at the top
# of _hook_health_write. Treat small values as a floor, not a measurement.
# duration_ms is null when it could not be computed at all.
#
# How much of the instrument lands inside that window depends on the shell, and
# the difference is not small (ecosystem-449.66):
#
#   bash 4.2+   Nothing. EPOCHREALTIME and printf %()T are builtins, so both
#               stamps are free, and the start is re-read after the breadcrumb
#               so its append is excluded too. Measured floor: ~1ms, the same
#               as before this lib wrote two records per fire.
#   bash 3.2    One jq fork for the end stamp, whose startup lands in the
#               window, plus the breadcrumb's append — buying that exclusion
#               would cost another jq fork, more than the append itself. On a
#               loaded host this reads as tens of milliseconds and is mostly
#               the instrument, not the hook.
#
# `#!/usr/bin/env bash` resolves to 3.2 on macOS and 5.x on Linux, so the
# development machine gets the expensive path and CI the cheap one.

# Content fingerprint of this file, stamped by scripts/sync-shared-libs.sh and
# verified by test/bats/shared-lib-fingerprint.bats.
#
# ecosystem-449.31. This lib is vendored into every plugin and plugins install
# independently, so one session can run the substrate on one copy and its
# plugins on another. Records from that window mixed two attribution schemes
# with nothing in the record to separate them. Carrying the fingerprint lets a
# rollup partition rows by which copy wrote them instead of assuming uniformity.
#
# Derived from the bytes rather than declared: a version directory's name, its
# package.json and its mtime have each been caught disagreeing with the contents
# they label. A hand-maintained constant would be a fourth such label.
_ONLOOKER_LIB_FINGERPRINT="18c8543e9cff"

# What the record actually reports, and the reason it is a second variable.
#
# ecosystem-5ddlyv / ONL-98. The constant above is re-assigned by every
# re-source, so reading it at write time made lib_schema last-source-wins
# while plugin_name/plugin_version stayed first-source-wins behind the
# _ONLOOKER_PLUGIN_ORIGIN_DERIVED sentinel below. The fourteen hooks that
# source their vendored copy and then reach the substrate through
# validate-path.sh:71 therefore stamped the plugin's identity beside the
# substrate's fingerprint — and because the start breadcrumb is written
# before that re-source and the terminal record after it, one run_id emitted
# two rows disagreeing about which copy wrote it. Measured 2026-09-21: 22
# such run_ids across librarian, tribunal, echo, assayer and archivist.
#
# This has to be a separate variable rather than a guard on the line above.
# lib_fingerprint(), lib_fingerprint_stamped() and lib_fingerprint_stamp() in
# scripts/lib-fingerprint.sh, and check-shared-lib-skew.mjs, all anchor on
# `_ONLOOKER_LIB_FINGERPRINT=` at column 0 — sed's `^` and JS's startsWith.
# Indenting the assignment into an `if` block, or renaming it, stops every one
# of them matching, and they fail by silently finding no stamp rather than by
# erroring.
#
# ${var=} rather than ${var:=}, matching the origin fields: it preserves an
# existing empty value instead of refilling it. Not exported, so a subshell
# re-deriving from its own copy is the safe direction.
: "${_ONLOOKER_LIB_SCHEMA=$_ONLOOKER_LIB_FINGERPRINT}"

# Do not clobber values a caller already set — several plugins set
# _HOOK_SESSION_ID before sourcing, and their *-events.sh libs read it.
# Note this seeds from the ENVIRONMENT, so an exported _HOOK_SESSION_ID crosses
# into child processes; hook_health_context lets a payload session_id override
# it for exactly that reason.
_HOOK_NAME="${_HOOK_NAME:-}"
_HOOK_START_MS="${_HOOK_START_MS:-}"
_HOOK_SESSION_ID="${_HOOK_SESSION_ID:-}"
_HOOK_EVENT="${_HOOK_EVENT:-}"
_HOOK_TOOL_NAME="${_HOOK_TOOL_NAME:-}"
_HOOK_PRIOR_EXIT_CMD="${_HOOK_PRIOR_EXIT_CMD:-}"
# The start stamp in ISO form, and the key that joins a breadcrumb to the
# terminal record that closes it (ecosystem-449.66).
_HOOK_START_ISO="${_HOOK_START_ISO:-}"
_HOOK_RUN_ID="${_HOOK_RUN_ID:-}"
# Set by hook_health_complete, read by the EXIT trap. Unset means the trap
# cannot prove the hook reached a termination point it chose, so the record says
# terminated rather than success.
#
# Deliberately NOT exported: a subshell that marks completion must not speak for
# its parent, and losing the flag is the safe direction (a run reads as
# terminated, never as a false success).
_HOOK_COMPLETED="${_HOOK_COMPLETED:-}"
# Separates two fires that land in the same millisecond in one process, which
# is what re-registering inside a fast hook looks like.
_HOOK_RUN_SEQ="${_HOOK_RUN_SEQ:-0}"

# Which plugin copy is this, and which host process is running it.
#
# ecosystem-9eg. /clear mints a new session_id inside the SAME process, and
# plugin code is pinned at PROCESS start rather than session start. A cleared
# session therefore looks post-release by every timestamp available while still
# running the pre-release plugin, so comparing a session's first event to the
# install time gives a false pass. Recording the version directly retires that
# whole inference.
#
# Derived from this file's own path, which is version-pinned in the installed
# layout (.../cache/<marketplace>/<plugin>/<version>/scripts/lib/hook-health.sh).
# Self-locating via BASH_SOURCE for the same reason config-loader.sh is:
# $PLUGIN_ROOT is read from whatever scope did the sourcing and is simply gone
# in a sub-shell that inherited only CLAUDE_PLUGIN_ROOT.
# Assigned only when unset, never blanked (ecosystem-449.50). The substrate's
# validate-path.sh re-sources this file from its own directory, so a plugin
# hook that registered with its vendored copy runs these lines a second time
# with BASH_SOURCE pointing into the ecosystem tree. A plain reset here would
# discard the plugin's identity before the guard below could protect it.
# ${var=} preserves an existing empty value; ${var:=} would not.
: "${_ONLOOKER_PLUGIN_NAME=}"
: "${_ONLOOKER_PLUGIN_VERSION=}"

# $PPID is the process that invoked the hook — the claude process itself,
# confirmed by capturing live hook processes during an edit. A builtin, so it
# costs nothing. Two session_ids sharing one host_pid IS a /clear; one
# plugin_name carrying two plugin_versions is a mixed-version window.
_HOOK_HOST_PID="$PPID"

_hook_health_derive_origin() {
	local src="${BASH_SOURCE[0]}"
	local before after

	# A hook that sources this file relative to its own directory hands us a
	# path that still carries the traversal: "$SCRIPT_DIR/../lib/hook-health.sh"
	# arrives as <root>/scripts/hooks/../lib/hook-health.sh. The walk below
	# reads components by name, so an uncollapsed `..` sits exactly where
	# `scripts` is expected and a perfectly ordinary layout falls through to
	# the null case. plugin-currency-surfacer hit this and nothing else did:
	# it is the only substrate hook that sources hook-health first, so it is
	# the only one whose winning derivation ran against the `..` path. All
	# 1,315 of its rows were unattributed (measured 2026-09-20).
	#
	# Collapsed textually and in-process. No realpath, no `cd -P`, no fork:
	# this runs on every hook invocation and a subprocess here is billed to
	# every hook's reported duration_ms, which is the number the whole
	# hook-cost thread is trying to measure.
	#
	# The rewrite assumes the cancelled component is a real directory and not
	# a symlink pointing elsewhere. In the installed layout it is — a plain
	# extracted tree — and a symlinked scripts/hooks would fail the name check
	# below either way, which is the safe direction.
	while [[ "$src" == */*/../* ]]; do
		before="${src%%/../*}" # everything left of the first /..
		after="${src#*/../}"   # everything right of it
		before="${before%/*}"  # drop the component the .. cancels
		src="${before}/${after}"
	done

	# Walk up from <root>/scripts/lib/hook-health.sh to <root>, checking each
	# component by name. Pure parameter expansion: no dirname, no subprocess.
	# Verifying the names rather than blindly stripping three levels means a
	# path of an unexpected shape falls through to the null case instead of
	# quietly labeling rows with whatever happened to sit three levels up.
	local libdir="${src%/*}"
	[[ "${libdir##*/}" == "lib" ]] || return 0
	local scriptsdir="${libdir%/*}"
	[[ "${scriptsdir##*/}" == "scripts" ]] || return 0
	local root="${scriptsdir%/*}"
	# A relative path can run out of components before we run out of strips,
	# leaving root equal to what we tried to strip.
	[[ -n "$root" && "$root" != "$scriptsdir" ]] || return 0

	local base="${root##*/}"
	# Assigned to a variable first: bash 3.2 treats a quoted regex literal as a
	# string to match, not a pattern.
	local semver='^[0-9]+\.[0-9]+\.[0-9]+'
	if [[ "$base" =~ $semver ]]; then
		_ONLOOKER_PLUGIN_VERSION="$base"
		local parent="${root%/*}"
		[[ -n "$parent" && "$parent" != "$root" ]] && _ONLOOKER_PLUGIN_NAME="${parent##*/}"
	else
		# A working-tree checkout: <repo>/plugins/<name> or <repo> for the
		# substrate. Name it, but leave the version null — this copy is not a
		# release and must not be counted as one.
		_ONLOOKER_PLUGIN_NAME="$base"
	fi
	return 0
}

# First source wins. Every one of the fourteen affected hooks sources its own
# vendored copy and registers before it reaches the substrate's
# validate-path.sh, so the first derivation is the one that names the code
# actually running the hook; the substrate's re-source is incidental.
#
# The sentinel is set before deriving rather than after, and tested with
# ${var+set} rather than for emptiness, so a first copy at an unrecognizable
# path stays null instead of being backfilled by the substrate. Null says "a
# copy we cannot name wrote this"; adopting the substrate's identity would be
# the same wrong answer this guard exists to prevent.
if [[ -z "${_ONLOOKER_PLUGIN_ORIGIN_DERIVED+set}" ]]; then
	_ONLOOKER_PLUGIN_ORIGIN_DERIVED=1
	_hook_health_derive_origin
fi

# Resolve the log path into $_HH_LOG_PATH. One definition, no subprocess.
#
# Both writers sit inside the window duration_ms measures, so `$(hook_health_log_path)`
# billed a fork to every hook's reported latency — one that predates this change
# in _hook_health_write, and one the breadcrumb would have added. That is real
# against a ~3ms floor, and hook-health.bats asserts duration_ms < 50 on a hook
# that does no work. Setting a global instead of capturing stdout removes both.
_HH_LOG_PATH=""
_hook_health_resolve_log_path() {
	_HH_LOG_PATH="${ONLOOKER_HOOK_HEALTH_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/hook-health.jsonl}"
	return 0
}

# Public accessor, kept because callers and tests use it. Resolved fresh each
# call rather than cached: ONLOOKER_HOOK_HEALTH_LOG is redirected between
# register and write throughout the suite, and a cached value would quietly
# send those records to the previous path.
hook_health_log_path() {
	_hook_health_resolve_log_path
	printf '%s' "$_HH_LOG_PATH"
}

# Milliseconds since the epoch, cheapest source first.
#
# Cost measured on macOS: $EPOCHREALTIME 0.08ms, perl 6.9ms, python3 18.7ms.
# Hooks run under bash 3.2, where EPOCHREALTIME does not exist, so perl is the
# usual winner. The date rung gives second resolution rather than dropping the
# record entirely.
_hook_health_now_ms() {
	local er s us
	if [[ -n "${EPOCHREALTIME:-}" ]]; then
		er="${EPOCHREALTIME/,/.}"   # some locales render the separator as a comma
		s="${er%%.*}"
		us="${er#*.}000"
		printf '%s%s' "$s" "${us:0:3}"
		return 0
	fi
	if command -v jq >/dev/null 2>&1; then
		jq -n '(now * 1000 | floor)' 2>/dev/null && return 0
	fi
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time() * 1000' 2>/dev/null && return 0
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null && return 0
	fi
	printf '%s000' "$(date +%s 2>/dev/null || printf 0)"
}

# The same clock, returned through $_HH_NOW_MS instead of stdout. Returns 1 when
# the shell has no free clock, so callers fall back to the cascade above.
#
# Capturing _hook_health_now_ms with `$(...)` forks even on the EPOCHREALTIME
# path, where the read itself is free — and that fork lands inside the window
# duration_ms measures, on both ends. Under bash 5 this makes the whole measured
# window subprocess-free, which is how a no-work hook gets back under the
# `duration_ms < 50` budget in hook-health.bats after the start breadcrumb
# added a write to it.
_HH_NOW_MS=""
_hook_health_now_ms_var() {
	[[ -n "${EPOCHREALTIME:-}" ]] || return 1
	local er="${EPOCHREALTIME/,/.}"   # some locales render the separator as a comma
	local s="${er%%.*}"
	local us="${er#*.}000"
	_HH_NOW_MS="${s}${us:0:3}"
	return 0
}

# Set _HOOK_START_MS and _HOOK_START_ISO together, adding no subprocess to what
# the clock already cost (ecosystem-449.66 needs both: ms to measure duration,
# ISO because every existing consumer reads .timestamp off each line —
# check-plugin-liveness.mjs does Date.parse(rec.timestamp) and drops a line
# without one).
#
# bash 4.2+ has printf %()T, a builtin, so both stamps are free. It formats in
# LOCAL time, so the TZ=UTC prefix is load-bearing and not cosmetic: measured on
# bash 5.3 in a UTC-4 zone, the unprefixed form returned 00:29:50Z for a true
# 04:29:50Z — a Z stamped on local time, four hours wrong. The prefix does not
# leak TZ into the hook's environment (verified: TZ stays unset afterward).
#
# Under the #!/usr/bin/env bash that resolves to 3.2 on macOS there is no %()T,
# but _hook_health_now_ms already spends a jq subprocess there, so asking that
# same call for both values keeps the count at one.
_hook_health_start_stamps() {
	_HOOK_START_ISO=""

	# Both stamps from builtins, no subprocess at all: EPOCHREALTIME by
	# parameter expansion for the milliseconds, %()T for the ISO form. This
	# path is strictly cheaper than before this change, which always spent a
	# fork on $(_hook_health_now_ms).
	# shellcheck disable=SC2059
	if _hook_health_now_ms_var && printf -v _HOOK_START_ISO '%(%s)T' -1 2>/dev/null; then
		_HOOK_START_MS="$_HH_NOW_MS"
		TZ=UTC printf -v _HOOK_START_ISO '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null
		[[ -n "$_HOOK_START_ISO" ]] && return 0
	fi

	local pair
	if command -v jq >/dev/null 2>&1; then
		pair=$(jq -rn '[(now * 1000 | floor | tostring), (now | todate)] | join(" ")' 2>/dev/null)
		if [[ -n "$pair" && "$pair" == *" "* ]]; then
			_HOOK_START_MS="${pair%% *}"
			_HOOK_START_ISO="${pair#* }"
			return 0
		fi
	fi

	# Last resort: two calls, or none. A missing ISO suppresses the breadcrumb
	# rather than writing a line no consumer can date.
	_HOOK_START_MS=$(_hook_health_now_ms)
	_HOOK_START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
	return 0
}

# Escape a value for embedding in a printf-built JSON string. The breadcrumb
# cannot use jq — the whole point is that it costs no subprocess — so the two
# characters that can break a JSON string, plus the control characters, are
# handled here. One malformed line makes the log unparseable to a streaming
# consumer, so this is not optional.
#
# Returns through the global $_HH_ESC rather than stdout, deliberately. A
# `$(...)` capture is a fork, and the breadcrumb needs eight of these: written
# the obvious way it cost more than the jq record it was meant to be cheaper
# than, and blew the `duration_ms < 50` budget in hook-health.bats. Parameter
# expansion only, no subprocess.
# Make sure the log's directory exists, and do it OUTSIDE the timed window.
#
# This used to live in _hook_health_write, which runs after the end stamp, so
# its cost fell outside every reported duration. The breadcrumb needs the
# directory too, but it runs *before* the end stamp — so calling it there moved
# `dirname` + `mkdir` inside the window and billed them to the hook. Measured in
# a fresh bats fixture, where the directory never exists yet: duration_ms=55
# against a budget of 50, from a hook that does nothing at all.
#
# ${path%/*} instead of $(dirname "$path"): same answer for an absolute path,
# no fork. Only ever does real work once per machine.
_hook_health_ensure_log_dir() {
	_hook_health_resolve_log_path
	[[ -f "$_HH_LOG_PATH" ]] && return 0
	local dir="${_HH_LOG_PATH%/*}"
	[[ -n "$dir" && "$dir" != "$_HH_LOG_PATH" ]] || return 0
	[[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
	return 0
}

_HH_ESC=""
_hook_health_json_escape() {
	_HH_ESC="${1:-}"
	_HH_ESC="${_HH_ESC//\\/\\\\}"
	_HH_ESC="${_HH_ESC//\"/\\\"}"
	_HH_ESC="${_HH_ESC//$'\n'/ }"
	_HH_ESC="${_HH_ESC//$'\r'/ }"
	_HH_ESC="${_HH_ESC//$'\t'/ }"
	return 0
}

# The completion sentinel: written up front, closed by the terminal record.
#
# A breadcrumb with no matching run_id is a run that was terminated. That
# inference asks nothing of the dying shell, which is why it holds for SIGKILL
# as well as SIGTERM — see the note above hook_health_register.
_hook_health_breadcrumb() {
	[[ -n "$_HOOK_NAME" && -n "$_HOOK_START_ISO" ]] || return 0

	local path
	_hook_health_resolve_log_path; path="$_HH_LOG_PATH"
	# No mkdir here. hook_health_register already called
	# _hook_health_ensure_log_dir, before the clock started, precisely so this
	# cost is not billed to the hook. If that failed the append below is a no-op
	# under `|| true`, which is the fail-soft behavior this lib promises.

	local start="${_HOOK_START_MS:-0}"
	[[ "$start" =~ ^[0-9]+$ ]] || start=0

	# Each value escaped into a local first. No command substitution anywhere in
	# here — see the note on _hook_health_json_escape.
	local iso hook rid lib pname pver
	_hook_health_json_escape "$_HOOK_START_ISO"; iso="$_HH_ESC"
	_hook_health_json_escape "$_HOOK_NAME"; hook="$_HH_ESC"
	_hook_health_json_escape "$_HOOK_RUN_ID"; rid="$_HH_ESC"
	_hook_health_json_escape "$_ONLOOKER_LIB_SCHEMA"; lib="$_HH_ESC"

	# null, not "", for an unknown plugin — the terminal record makes the same
	# distinction, and a consumer joining the two must not see them disagree.
	if [[ -n "$_ONLOOKER_PLUGIN_NAME" ]]; then
		_hook_health_json_escape "$_ONLOOKER_PLUGIN_NAME"; pname="\"${_HH_ESC}\""
	else
		pname="null"
	fi
	if [[ -n "$_ONLOOKER_PLUGIN_VERSION" ]]; then
		_hook_health_json_escape "$_ONLOOKER_PLUGIN_VERSION"; pver="\"${_HH_ESC}\""
	else
		pver="null"
	fi

	printf '{"timestamp":"%s","hook":"%s","status":"started","run_id":"%s","start_ms":%s,"host_pid":%s,"lib_schema":"%s","plugin_name":%s,"plugin_version":%s}\n' \
		"$iso" "$hook" "$rid" "$start" "${_HOOK_HOST_PID:-0}" "$lib" "$pname" "$pver" \
		>> "$path" 2>/dev/null || true
	return 0
}

# Start timing, drop the completion sentinel, and arm the exit trap.
#
# Any EXIT trap already installed is preserved and run after we log. Six plugin
# hooks depend on this: four remove a prompt file, and cartographer's two
# release a lock, which a clobbered trap would strand.
#
# WHY A BREADCRUMB AND NOT A SIGNAL TRAP (ecosystem-449.66). The EXIT trap
# cannot tell a completed run from a killed one: when a signal kills the shell
# bash still runs the trap, but $? inside it is the status of the last COMPLETED
# command — typically a successful jq — so a killed hook recorded success.
# Measured: 624 librarian-session-end records, every one status=success, for a
# hook being killed at the 1500ms SessionEnd deadline on nearly every session.
#
# The obvious repair — trap TERM/INT/HUP as well — is worse. Bash defers a
# trapped signal while it waits on a foreground child. Measured with a TERM trap
# and `sleep` in the foreground: signalled pid-only, the handler ran at +9630ms;
# signalled process-group, +26ms. Untrapped, bash dies promptly in both. So a
# signal trap can make a hook outlive the deadline that killed it, and SIGKILL
# stays invisible regardless.
#
# So the discriminator is positional rather than reactive: record the start, and
# let the ABSENCE of the terminal record mean termination. Nothing is asked of
# the dying shell, so it holds for every way a hook can die.
hook_health_register() {
	_HOOK_NAME="${1:-unknown}"
	# A fresh fire has not completed yet, whatever a previous one in this shell
	# managed to do.
	_HOOK_COMPLETED=""
	# Before the clock starts, deliberately. Creating the directory is setup for
	# the instrument, not work the hook did, and it is the one thing here that
	# can cost a real syscall. Doing it after the start stamp put it inside every
	# reported duration.
	_hook_health_ensure_log_dir
	_hook_health_start_stamps
	_HOOK_RUN_SEQ=$((_HOOK_RUN_SEQ + 1))
	_HOOK_RUN_ID="${_HOOK_START_MS:-0}-$$-${_HOOK_RUN_SEQ}"
	_hook_health_breadcrumb
	# Re-stamp so the breadcrumb's own append is not billed to the hook. Writing
	# it is instrument overhead, and it is not cheap: measured in the bats
	# fixture on a loaded host, the append alone moved duration_ms from ~20ms to
	# ~42ms, because a file open/write/close under I/O contention is expensive
	# in a way the escaping and formatting around it are not (those are 0.27ms).
	#
	# Only when the clock is free. On bash 3.2 a second read means another jq
	# fork, which would cost several times the append it is trying to exclude —
	# so there the reported duration still includes it, as it always has. The
	# breadcrumb keeps its own earlier stamp either way; a start a millisecond
	# before the duration's origin is immaterial to pairing.
	if _hook_health_now_ms_var; then
		_HOOK_START_MS="$_HH_NOW_MS"
	fi

	local prior
	prior=$(trap -p EXIT 2>/dev/null)
	# Skip when the installed trap is already ours. A second register would
	# otherwise capture `_hook_health_on_exit` as "the prior trap" and
	# overwrite the caller's real handler, silently discarding the cleanup
	# chaining exists to preserve.
	if [[ -n "$prior" && "$prior" != *_hook_health_on_exit* ]]; then
		# Format is: trap -- 'cmd' EXIT
		prior="${prior#trap -- }"
		prior="${prior% EXIT}"
		# The assignment unquotes bash's own quoting, including the '\'' form
		# it emits for embedded single quotes.
		eval "_HOOK_PRIOR_EXIT_CMD=$prior" 2>/dev/null || _HOOK_PRIOR_EXIT_CMD=""
	fi

	trap '_hook_health_on_exit $?' EXIT
	return 0
}

# Log first, then hand control back to whatever trap we displaced. Logging
# first keeps the prior handler running even if the write fails, at the cost of
# excluding the hook's own cleanup from the recorded duration.
_hook_health_on_exit() {
	local exit_code="${1:-0}"
	if [[ -z "$_HOOK_COMPLETED" ]]; then
		# The trap ran without the hook ever marking completion, so the shell
		# did not reach a termination point it chose — it was killed. $exit_code
		# is kept for forensics but is NOT evidence of anything: measured, it is
		# the status of the last COMPLETED command, which for a killed hook is
		# typically a successful jq. Reporting it as success is ecosystem-449.66.
		_hook_health_write "terminated" "terminated_before_completion,last_exit_code=${exit_code}"
	elif [[ "$exit_code" -eq 0 ]]; then
		_hook_health_write "success" ""
	else
		_hook_health_write "failure" "exit_code=${exit_code}"
	fi
	trap - EXIT
	if [[ -n "$_HOOK_PRIOR_EXIT_CMD" ]]; then
		local prior_cmd="$_HOOK_PRIOR_EXIT_CMD"
		_HOOK_PRIOR_EXIT_CMD=""
		eval "$prior_cmd" || true
	fi
	return 0
}

# Fill session/event/tool from the hook's JSON payload. Optional — call it
# after reading stdin.
#
# session_id is the exception to caller-wins: the payload is authoritative when
# it carries one. _HOOK_SESSION_ID is the only one of these that plugins
# `export`, so it is the only one a child process inherits — and a hook that
# shells out to `claude` (assayer, and any other claude-invoking hook) leaks its
# own id into every hook that nested session fires. Preferring the inherited
# value files all of that under the parent, which is what made 93 separate
# sessions read as one session re-firing SessionStart 93 times. See
# ecosystem-449.27.
#
# Every in-process setter derives the value from the same payload it then hands
# us, so preferring the payload is a no-op for them and only corrects the
# inherited case. An absent or empty payload session_id still leaves a
# caller-set value alone — several plugins set it before sourcing and pass a
# payload that carries none.
#
# tool_name and hook_event keep caller-wins: neither is ever exported, so
# neither can be inherited across a process boundary.
hook_health_context() {
	local input="${1:-}"
	[[ -n "$input" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	local payload_session_id
	payload_session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
	if [[ -n "$payload_session_id" ]]; then
		_HOOK_SESSION_ID="$payload_session_id"
	fi
	[[ -z "$_HOOK_TOOL_NAME" ]] && _HOOK_TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
	[[ -z "$_HOOK_EVENT" ]] && _HOOK_EVENT=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)
	return 0
}

# Mark that the hook reached a termination point of its own choosing.
#
# This is the whole discriminator (ecosystem-449.66). The EXIT trap cannot infer
# it: on fall-off-the-end BASH_COMMAND is the last command, which is
# indistinguishable from a command interrupted by a signal, and $? is the last
# COMPLETED command's status either way. So the normal path has to say so.
#
# Cheap by construction — a variable assignment, no subprocess, no write. The
# record is still written once, by the EXIT trap.
hook_health_complete() {
	_HOOK_COMPLETED=1
	return 0
}

# Mark completion and exit, for hooks whose termination is a bare `exit`.
# `builtin exit` rather than `exit` so this is safe even if a caller has its own
# exit function, and so the hook's exit code passes through untouched.
hook_health_exit() {
	_HOOK_COMPLETED=1
	builtin exit "${1:-0}"
}

# An explicit terminal record is itself a statement that the hook reached a
# decision, so both of these imply completion. Marking before the write keeps
# the EXIT trap from re-reporting a run these already closed as terminated.
hook_health_success() {
	_HOOK_COMPLETED=1
	_hook_health_write "success" ""
}

hook_health_failure() {
	_HOOK_COMPLETED=1
	_hook_health_write "failure" "${1:-}"
}

# Write one record. The end timestamp comes from jq's `now` inside the call we
# already make, so it costs no extra process.
_hook_health_write() {
	local hook_status="$1"
	local error_msg="$2"

	[[ -n "$_HOOK_NAME" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	# Stamp the end BEFORE any other work. Everything below — the path lookup,
	# dirname, mkdir, and jq's own startup — used to run between the two clock
	# reads and land inside every reported duration. Measured cost of that:
	# dirname 1.4ms, mkdir 1.05ms, plus jq's pre-read startup.
	#
	# The capture itself was part of that cost: `$(...)` forks even when the
	# clock underneath is free, and the fork happens after the start stamp, so
	# it was billed to the hook. Preferring the variable form makes the whole
	# measured window subprocess-free under bash 5.
	local end
	if _hook_health_now_ms_var; then
		end="$_HH_NOW_MS"
	else
		end=$(_hook_health_now_ms)
	fi

	local path
	_hook_health_resolve_log_path; path="$_HH_LOG_PATH"
	# Still guarded here as well as in register, for the callers that reach a
	# terminal write without one — hook_health_success straight after a
	# register that could not create the directory, say. Costs a builtin test
	# once the log exists, which is after the first write on any machine.
	#
	# The trailing `|| return 0` is load-bearing, not decoration: without it a
	# failed mkdir makes this the function's exit status, and the whole lib
	# promises every function returns 0 so a hook never breaks because its
	# instrument did. Dropping it turned an unwritable log into a failing
	# hook_health_register.
	_hook_health_ensure_log_dir || return 0

	local start="${_HOOK_START_MS:-0}"
	[[ "$start" =~ ^[0-9]+$ ]] || start=0
	[[ "$end" =~ ^[0-9]+$ ]] || end=0

	jq -cn \
		--arg hook "$_HOOK_NAME" \
		--arg hook_status "$hook_status" \
		--arg error "$error_msg" \
		--arg session_id "$_HOOK_SESSION_ID" \
		--arg hook_event "$_HOOK_EVENT" \
		--arg tool_name "$_HOOK_TOOL_NAME" \
		--arg lib "$_ONLOOKER_LIB_SCHEMA" \
		--arg plugin_name "$_ONLOOKER_PLUGIN_NAME" \
		--arg plugin_version "$_ONLOOKER_PLUGIN_VERSION" \
		--arg run_id "$_HOOK_RUN_ID" \
		--argjson host_pid "${_HOOK_HOST_PID:-0}" \
		--argjson start "$start" \
		--argjson end "$end" \
		'{
			timestamp: (now | todate),
			hook: $hook,
			status: $hook_status,
			# Joins this record to the breadcrumb hook_health_register wrote.
			# A breadcrumb whose run_id never appears on a terminal record is a
			# run that was terminated (ecosystem-449.66).
			run_id: (if $run_id == "" then null else $run_id end),
			# null means "could not be measured" — a bad stamp or a backward
			# clock step. 0 means a genuinely sub-millisecond hook. Collapsing
			# both onto 0 silently deflated the average consumers read.
			duration_ms: (if $start > 0 and $end >= $start then $end - $start else null end),
			error: (if $error == "" then null else $error end),
			session_id: (if $session_id == "" then null else $session_id end),
			hook_event: (if $hook_event == "" then null else $hook_event end),
			tool_name: (if $tool_name == "" then null else $tool_name end),
			# Which vendored copy of hook-health.sh wrote this row. Rows with
			# differing values in one session are a skew window, not noise.
			lib_schema: (if $lib == "" then null else $lib end),
			# Which plugin code wrote this row (ecosystem-9eg). plugin_version
			# is null for a working-tree copy, which is not a release and must
			# not be counted as one.
			plugin_name: (if $plugin_name == "" then null else $plugin_name end),
			plugin_version: (if $plugin_version == "" then null else $plugin_version end),
			# The host claude process. Two session_ids sharing one host_pid is
			# a /clear, which no timestamp can distinguish from a fresh start.
			host_pid: (if $host_pid > 0 then $host_pid else null end)
		   }' >> "$path" 2>/dev/null || true

	# Reset so a second write in the same shell cannot double-count. The
	# completion flag resets too: a hook that registers a second time must earn
	# its own completion, or the first fire's mark would vouch for a second run
	# that was killed.
	_HOOK_NAME=""
	_HOOK_START_MS=""
	_HOOK_START_ISO=""
	_HOOK_RUN_ID=""
	_HOOK_COMPLETED=""
	return 0
}
