#!/usr/bin/env bash
# Watch-unmatched signal (ecosystem-449.21).
#
# GOVERNING RULE
#   Each mode mirrors its plugin's real matcher.
#
# A plugin that exits 0 and emits nothing looks exactly like a plugin with
# nothing to report. This lib answers the one question that separates them:
# do these configured patterns match zero paths in this repository at all?
# That is a property of repo plus config, not of the turn -- which is why it
# is marker-gated rather than emitted on every fire.
#
# The check must agree with the matcher it describes. Echo matches git-tracked
# paths plus untracked-but-not-ignored paths; cartographer expands globs
# against the filesystem and so sees untracked AND gitignored paths too. One
# scanner would disagree with one of them and invent misconfigurations that
# are not there.
#
# This lib will be VENDORED via scripts/sync-shared-libs.sh's ON_DEMAND_LIBS
# (only echo and cartographer source it, not every plugin -- SHARED_LIBS would
# mint copies nothing reads): an installed plugin publishes rooted at
# ./plugins/<name> and has no ecosystem checkout above it, so a repo-root path
# resolves in this checkout and nowhere else (ecosystem-ber).

# Default re-arm window. A deliberate constant, not config: pure edge-triggering
# makes a misconfiguration emitted once on day 1 invisible to a query over the
# last two days, which is the exact ambiguity this signal exists to remove.
_ONLOOKER_WATCH_TTL_HOURS_DEFAULT=168

_onlooker_watch_sha256_first12() {
	local input="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

# Seconds since epoch for an ISO-8601 UTC stamp, or empty when unparseable.
# python3 rather than `date`: -d vs -v diverges between GNU and BSD/macOS.
_onlooker_watch_epoch() {
	python3 -c '
import datetime, sys
try:
    d = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
    print(int(d.replace(tzinfo=datetime.timezone.utc).timestamp()))
except Exception:
    sys.exit(1)
' "$1" 2>/dev/null
}

# The ":-$HOME/.onlooker" fallback is load-bearing, not decoration. This is
# called from echo-stop-gate.sh at a point ABOVE where that hook establishes its
# own ONLOOKER_BASE (line 173), so a bare "${ONLOOKER_DIR:-}" would resolve to
# "/watch-unmatched/..." and fail to write with no error anyone would see. Both
# call-site hooks already use exactly this fallback (echo-stop-gate.sh:173,
# cartographer-session-start.sh:49); the env var still wins where it is set,
# which is what CLAUDE.md item 3 requires.
onlooker_watch_marker_path() {
	printf '%s/watch-unmatched/%s/%s.json' \
		"${ONLOOKER_DIR:-$HOME/.onlooker}" "${1:-unknown}" "${2:-unknown}"
}

# Hash over the SORTED pattern list. Reordering watch_paths is not a change in
# meaning and must not re-arm the signal; editing one is and must.
onlooker_watch_patterns_hash() {
	local sorted
	sorted=$(printf '%s' "${1:-[]}" | jq -cS 'sort' 2>/dev/null) || return 1
	[[ -z "$sorted" || "$sorted" == "null" ]] && return 1
	_onlooker_watch_sha256_first12 "$sorted"
}

# Due when: no marker, hash differs, stamp missing/unparseable, or age > ttl.
# Every unknown resolves to "due" -- under-reporting a live misconfiguration is
# the failure this bead exists to fix, so ambiguity errs toward emitting.
onlooker_watch_marker_due() {
	local path="${1:-}" hash="${2:-}" ttl_hours="${3:-$_ONLOOKER_WATCH_TTL_HOURS_DEFAULT}"
	[[ -f "$path" ]] || return 0

	local stored_hash stored_at prev now
	stored_hash=$(jq -r '.patterns_hash // ""' "$path" 2>/dev/null) || return 0
	[[ "$stored_hash" != "$hash" ]] && return 0

	stored_at=$(jq -r '.last_emitted // ""' "$path" 2>/dev/null) || return 0
	[[ -z "$stored_at" ]] && return 0

	prev=$(_onlooker_watch_epoch "$stored_at") || return 0
	[[ -z "$prev" ]] && return 0
	now=$(date +%s)
	(( now - prev > ttl_hours * 3600 )) && return 0
	return 1
}

# Write-then-rename: concurrent sessions in one project race on this file, and
# a torn write that still parses would be worse than one that does not.
onlooker_watch_marker_write() {
	local path="${1:-}" hash="${2:-}"
	[[ -z "$path" ]] && return 1
	mkdir -p "$(dirname "$path")" 2>/dev/null || return 1

	local tmp="${path}.tmp.$$"
	if ! jq -n --arg h "$hash" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{patterns_hash: $h, last_emitted: $t}' >"$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

onlooker_watch_marker_clear() {
	[[ -n "${1:-}" ]] && rm -f "$1" 2>/dev/null
	return 0
}

# files mode -- mirrors echo-stop-gate.sh's real candidate set: ALL_CHANGED
# there is git-tracked paths PLUS untracked-but-not-ignored paths
# (`git ls-files --others --exclude-standard`, echo-stop-gate.sh:135), not
# tracked paths alone. A pattern matching only a gitignored path still reports
# unmatched -- `--exclude-standard` excludes it from both this scanner and
# echo's real matcher, so the two stay in agreement.
#
# Prints "<matched> <scanned>". matched is 0 or 1; the caller only needs the
# boolean, and returning on the first hit avoids walking the rest of the tree.
_onlooker_watch_scan_files() {
	local root="${1:-}" patterns_json="${2:-[]}"

	local patterns=() p
	while IFS= read -r p; do
		[[ -n "$p" ]] && patterns+=("$p")
	done < <(printf '%s' "$patterns_json" | jq -r '.[]' 2>/dev/null)

	if [[ "${#patterns[@]}" -eq 0 ]]; then
		printf '0 0'
		return 0
	fi

	local scanned=0 f pat
	while IFS= read -r f; do
		[[ -z "$f" ]] && continue
		scanned=$(( scanned + 1 ))
		for pat in "${patterns[@]}"; do
			# shellcheck disable=SC2053 # unquoted on purpose: this is the glob
			if [[ "$f" == $pat ]]; then
				printf '1 %s' "$scanned"
				return 0
			fi
		done
	done < <(
		{
			git -C "$root" ls-files 2>/dev/null
			git -C "$root" ls-files --others --exclude-standard 2>/dev/null
		}
	)

	printf '0 %s' "$scanned"
}

# dirs mode -- mirrors cartographer-omission.sh:77 exactly: shell glob expansion
# against the FILESYSTEM under nullglob, then an existence test. This sees
# untracked and gitignored paths, which is why it cannot be folded into the
# files scanner.
#
# nullglob is saved and restored: this lib is sourced, not run.
_onlooker_watch_scan_dirs() {
	local root="${1:-}" patterns_json="${2:-[]}"
	root="${root%/}"

	local had_nullglob=0
	shopt -q nullglob && had_nullglob=1
	shopt -s nullglob

	local scanned=0 matched=0 glob match
	while IFS= read -r glob; do
		[[ -z "$glob" ]] && continue
		# shellcheck disable=SC2086 # $glob unquoted on purpose: this is the glob
		# expansion. "${root}" IS quoted -- a repo path containing a space must
		# not word-split before the glob expands, or the match silently finds
		# nothing.
		for match in "${root}"/$glob; do
			scanned=$(( scanned + 1 ))
			[[ -e "$match" ]] || continue
			matched=1
		done
	done < <(printf '%s' "$patterns_json" | jq -r '.[]' 2>/dev/null)

	[[ "$had_nullglob" -eq 0 ]] && shopt -u nullglob
	printf '%s %s' "$matched" "$scanned"
}

# Public entry point. Returns 0 on every path, including every failure.
#
# An empty pattern list emits nothing: a plugin configured to watch nothing is
# a different condition from a plugin whose patterns cannot match, and this
# event type only speaks to the second.
onlooker_watch_unmatched_check() {
	local plugin="" config_key="" root="" project_key="" mode=""
	local patterns_json="" emit_fn="" ttl_hours="$_ONLOOKER_WATCH_TTL_HOURS_DEFAULT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--plugin)        plugin="${2:-}";        shift; shift ;;
			--config-key)    config_key="${2:-}";    shift; shift ;;
			--root)          root="${2:-}";          shift; shift ;;
			--project-key)   project_key="${2:-}";   shift; shift ;;
			--mode)          mode="${2:-}";          shift; shift ;;
			--patterns-json) patterns_json="${2:-}"; shift; shift ;;
			--emit-fn)       emit_fn="${2:-}";       shift; shift ;;
			--ttl-hours)     ttl_hours="${2:-$_ONLOOKER_WATCH_TTL_HOURS_DEFAULT}"; shift; shift ;;
			*) shift ;;
		esac
	done

	[[ -z "$plugin" || -z "$config_key" || -z "$root" ]] && return 0
	[[ -z "$project_key" || -z "$mode" || -z "$patterns_json" ]] && return 0
	[[ -z "$emit_fn" ]] && return 0
	command -v jq >/dev/null 2>&1 || return 0

	local count
	count=$(printf '%s' "$patterns_json" | jq -r 'length' 2>/dev/null) || return 0
	[[ -z "$count" || "$count" == "null" || "$count" -eq 0 ]] && return 0

	[[ "$mode" == "files" || "$mode" == "dirs" ]] || return 0

	# MARKER FIRST, THEN SCAN. This ordering is the cost contract: in steady
	# state the whole check is one stat, and the scan only runs when the answer
	# could change something. Scanning first would be simpler and would keep the
	# marker exact, but it would pay the scan on every Stop forever to tidy a
	# file no consumer reads.
	#
	# The price is that clearing lags by up to one TTL: a repository whose
	# patterns start matching again keeps its marker until the next due check
	# observes the match. That is harmless -- the marker only ever suppresses
	# emission, and a matching repository has nothing to emit.
	local marker hash
	marker=$(onlooker_watch_marker_path "$project_key" "$config_key")
	hash=$(onlooker_watch_patterns_hash "$patterns_json") || return 0
	onlooker_watch_marker_due "$marker" "$hash" "$ttl_hours" || return 0

	local scan
	case "$mode" in
		files) scan=$(_onlooker_watch_scan_files "$root" "$patterns_json") ;;
		dirs)  scan=$(_onlooker_watch_scan_dirs  "$root" "$patterns_json") ;;
	esac

	local matched="${scan%% *}" scanned="${scan##* }"

	# A match is the recovery edge: drop the marker so a later re-break speaks.
	if [[ "$matched" != "0" ]]; then
		onlooker_watch_marker_clear "$marker"
		return 0
	fi

	# candidates_scanned is omitted in dirs mode on purpose. Under nullglob an
	# unmatched glob produces zero loop iterations, so the counter is always 0
	# exactly when we emit -- a number that looks like a measurement and is not
	# one. The schema makes the field optional; absent beats a constant zero,
	# the same reasoning that made compass's confidence null rather than 0
	# (ecosystem-449.45). In files mode it counts real tracked and untracked
	# candidate files and stays.
	local payload
	if [[ "$mode" == "files" ]]; then
		payload=$(jq -cn \
			--arg p "$plugin" --arg k "$config_key" --arg pk "$project_key" \
			--argjson pat "$patterns_json" --argjson n "$scanned" \
			'{plugin: $p, config_key: $k, patterns: $pat,
			  candidates_scanned: $n, project_key: $pk}' 2>/dev/null) || return 0
	else
		payload=$(jq -cn \
			--arg p "$plugin" --arg k "$config_key" --arg pk "$project_key" \
			--argjson pat "$patterns_json" \
			'{plugin: $p, config_key: $k, patterns: $pat,
			  project_key: $pk}' 2>/dev/null) || return 0
	fi

	if command -v "$emit_fn" >/dev/null 2>&1 || declare -F "$emit_fn" >/dev/null 2>&1; then
		"$emit_fn" "onlooker.watch.unmatched" "$payload" || true
		onlooker_watch_marker_write "$marker" "$hash" || true
	fi

	return 0
}
