#!/usr/bin/env bash
# Approved lessons that have not reached the pool, and the opt-in background
# `onlooker sync` that sends them.
#
# approved/ is where a lesson waits for `onlooker sync`, and since lesson_auto
# fills it with nobody present, nothing told anyone a lesson was waiting. The
# CLI records what the pool confirmed it holds in $ONLOOKER_DIR/pushed.json,
# keyed by lesson id; an approved id missing there is one the pool does not
# hold. The CLI's own digest is over the parsed lesson, which bash cannot
# reproduce, so an edited lesson reads as synced until the next sync rewrites
# the record. `onlooker status` accepts the same limit (ONL-202).
#
# Nothing here calls the network or a model. The sync itself runs detached, so
# SessionStart pays for a glob, one jq, and a fork.
#
# Requires librarian-config.sh.

_librarian_lesson_sync_root() {
	printf '%s' "${ONLOOKER_DIR:-$HOME/.onlooker}"
}

# Count approved lessons, across every project, that pushed.json does not
# list. A missing or unreadable pushed.json counts them all: a record nobody
# can read says nothing was confirmed.
#
# Usage: librarian_lesson_unsynced_count
librarian_lesson_unsynced_count() {
	local root f ids=()
	root=$(_librarian_lesson_sync_root)
	for f in "$root"/librarian/*/lessons/approved/*.json; do
		[[ -f "$f" ]] || continue
		ids+=("$(basename "$f" .json)")
	done
	if [[ ${#ids[@]} -eq 0 ]]; then
		printf '0'
		return 0
	fi

	local pushed="$root/pushed.json" count=""
	if [[ -f "$pushed" ]]; then
		count=$(jq -rn --slurpfile p "$pushed" \
			'($p[0].lessons // {}) as $held
			 | [$ARGS.positional[] | select($held[.] == null)] | length' \
			--args "${ids[@]}" 2>/dev/null) || count=""
	fi
	[[ "$count" =~ ^[0-9]+$ ]] || count=${#ids[@]}
	printf '%s' "$count"
}

# The CLI name to run, from lesson_sync.cli.
_librarian_lesson_sync_cli() {
	local cli
	cli=$(librarian_config_get '.librarian.lesson_sync.cli' 2>/dev/null)
	case "$cli" in '' | null) cli="onlooker" ;; esac
	printf '%s' "$cli"
}

# 0 when the CLI holds a machine token. Reads only whether one is there; the
# token itself never leaves jq.
_librarian_lesson_sync_linked() {
	jq -e '(.machineToken | type) == "string" and (.machineToken | length) > 0' \
		"$(_librarian_lesson_sync_root)/cli.json" >/dev/null 2>&1
}

# The SessionStart line for <count> unsynced lessons, and the background sync
# when lesson_sync.auto allows one. Prints the line, or nothing when there is
# nothing to say or lesson_sync.remind is false.
#
# The background sync starts only on a linked machine with the CLI installed,
# and at most once per lesson_sync.min_interval_minutes across every session,
# stamped before it starts so two sessions opening together do not both run
# it. Its output goes to lesson-sync.log beside the stamp, because no session
# is left to read it. A sync that ran and did not clear the count is said so
# on the next session, so a failing sync is never mistaken for one in flight.
#
# Usage: librarian_lesson_sync_surface <count>
librarian_lesson_sync_surface() {
	local count="${1:-0}"
	[[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || return 0

	local cli remind auto line
	cli=$(_librarian_lesson_sync_cli)
	remind=$(librarian_config_get '.librarian.lesson_sync.remind' 2>/dev/null)
	auto=$(librarian_config_get '.librarian.lesson_sync.auto' 2>/dev/null)

	if ! command -v "$cli" >/dev/null 2>&1; then
		line="install the onlooker CLI, then run \`${cli} link\` and \`${cli} sync\`"
	elif ! _librarian_lesson_sync_linked; then
		line="run \`${cli} link\`, then \`${cli} sync\`"
	elif [[ "$auto" != "true" ]]; then
		line="run \`${cli} sync\`"
	elif _librarian_lesson_sync_start "$cli"; then
		line="syncing in the background"
	else
		line="still not synced after a background sync — run \`${cli} sync\` to see why"
	fi

	[[ "$remind" == "false" ]] && return 0
	if [[ "$line" == still* ]]; then
		printf '%s approved lesson(s) %s' "$count" "$line"
	else
		printf '%s approved lesson(s) not synced — %s' "$count" "$line"
	fi
}

# Start `<cli> sync` detached unless one started inside the interval. Returns
# 0 when it started one.
#
# Usage: _librarian_lesson_sync_start <cli>
_librarian_lesson_sync_start() {
	local cli="$1" dir stamp now last interval
	dir="$(_librarian_lesson_sync_root)/librarian"
	stamp="$dir/lesson-sync.last"
	interval=$(librarian_config_int '.librarian.lesson_sync.min_interval_minutes' 60 2>/dev/null)
	[[ "$interval" =~ ^[0-9]+$ ]] || interval=60
	now=$(date +%s)
	last=$(cat "$stamp" 2>/dev/null)
	if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < interval * 60 )); then
		return 1
	fi

	mkdir -p "$dir" 2>/dev/null || return 1
	printf '%s\n' "$now" > "$stamp" 2>/dev/null || return 1
	(
		printf '\n--- %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
		nohup "$cli" sync </dev/null 2>&1
	) </dev/null >>"$dir/lesson-sync.log" 2>&1 &
	disown 2>/dev/null || true
	return 0
}
