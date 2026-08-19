#!/usr/bin/env bash
# cartographer-resolve.sh — retire findings whose drift is gone.
#
# A finding is written once to findings/<hash>.json and re-observed on every
# later audit, which refreshes last_seen_at. Nothing ever marked one absent, so
# fixing the drift a finding reported did not retire the finding — it rendered
# forever. The record already carried resolved:false from birth; the field
# existed, the loop that flips it did not.
#
# Absence is the evidence: the audit knows every finding it observed this run,
# so anything in the store whose last_seen_at predates this run's start was not
# observed and its drift is gone.
#
# That inference is only sound when the run actually looked everywhere, which is
# what the two guards below protect.

# Refresh a finding that was observed again this run.
#
# Usage: cartographer_refresh_finding <finding_file> <now>
#
# Reopening matters as much as the timestamp. The dedup sentinel outlives
# resolution, so drift that is fixed and then reintroduced arrives here rather
# than down the new-finding path. Leaving resolved:true would keep a live
# finding hidden from the renderer forever — a silent false negative, and a
# worse failure than the stale findings this module exists to retire.
cartographer_refresh_finding() {
	local finding_file="${1:-}" now="${2:-}"
	[[ -z "$finding_file" || -z "$now" ]] && return 1
	[[ -f "$finding_file" ]] || return 1

	local updated
	updated=$(jq --argjson ts "$now" \
		'.last_seen_at = $ts | .resolved = false | del(.resolved_at)' \
		"$finding_file" 2>/dev/null) || return 1
	[[ -z "$updated" ]] && return 1

	printf '%s\n' "$updated" >"${finding_file}.tmp" || return 1
	mv -f "${finding_file}.tmp" "$finding_file"
}

# Whether this run looked at enough for absence to mean anything.
#
# Two ways it does not. A targeted post-write audit evaluates a single file, so
# almost every stored finding is "unobserved" for reasons that have nothing to
# do with being fixed — letting it resolve would wipe the store on every edit.
# And a phase that timed out or errored contributes no findings, which is
# indistinguishable from its findings being gone.
#
# Named rather than inlined because run_emit needs the same answer to decide
# whether cartographer.audit.complete may report a resolved count at all. Two
# copies of this condition is precisely the kind of divergence that has bitten
# this plugin before.
#
# Usage: cartographer_resolution_is_sound <target_file> <phases_failed>
cartographer_resolution_is_sound() {
	local target_file="${1:-}" phases_failed="${2:-0}"
	[[ -z "$target_file" && "$phases_failed" -eq 0 ]]
}

# Mark findings not observed by this audit as resolved.
#
# Usage:
#   cartographer_resolve_absent_findings <findings_dir> <cutoff_ts> \
#                                        <target_file> <phases_failed_count> \
#                                        [now] [on_resolved]
#
# on_resolved, when given, is the name of a function called once per retired
# finding with its hash. Its stdout is discarded; see the call site below.
#
# cutoff_ts is the audit's start time: a finding observed this run had its
# last_seen_at refreshed to at-or-after it, so a record older than it was not
# observed. The comparison is strict (<), which errs toward leaving a finding
# open when the timestamps collide — a stale finding is visible and correctable,
# an incorrectly retired one is silent.
#
# Prints the number of findings newly resolved.
cartographer_resolve_absent_findings() {
	local findings_dir="${1:-}" cutoff_ts="${2:-}"
	local target_file="${3:-}" phases_failed="${4:-0}"
	local now="${5:-}"
	local on_resolved="${6:-}"
	[[ -z "$now" ]] && now=$(date +%s)

	[[ -z "$findings_dir" || -z "$cutoff_ts" ]] && return 1
	if [[ ! -d "$findings_dir" ]]; then
		printf '0'
		return 0
	fi

	# Both guards live in the predicate. A run that fails either one retires
	# nothing and announces nothing — announcing a resolution the run did not
	# establish tells every consumer to close a finding that is still live.
	if ! cartographer_resolution_is_sound "$target_file" "$phases_failed"; then
		printf '0'
		return 0
	fi

	local resolved=0 f updated
	for f in "$findings_dir"/*.json; do
		[[ -f "$f" ]] || continue
		# Emits nothing when the record is already resolved or was seen this
		# run, so an unchanged record is never rewritten and never counted.
		updated=$(jq --argjson cutoff "$cutoff_ts" --argjson now "$now" '
			if .resolved == true then empty
			elif ((.last_seen_at // 0) < $cutoff) then . + {resolved: true, resolved_at: $now}
			else empty end
		' "$f" 2>/dev/null) || continue
		[[ -z "$updated" ]] && continue
		printf '%s\n' "$updated" >"${f}.tmp" || continue
		mv -f "${f}.tmp" "$f" || continue
		resolved=$(( resolved + 1 ))

		# Announce inside the guarded loop, so a run that must not resolve also
		# cannot announce. The emitter is injected rather than sourced: this
		# module stays pure data, and a test can pass a stub without dragging
		# the event bus in behind it.
		#
		# stdout is the count channel — the caller reads it through a command
		# substitution — so the emitter is redirected away from it. That is also
		# why announcing works at all here despite the subshell: appending to
		# the event log is a filesystem effect, and unlike a variable it
		# survives.
		if [[ -n "$on_resolved" ]]; then
			local fhash
			fhash=$(printf '%s' "$updated" | jq -r '.finding_hash // ""')
			[[ -z "$fhash" ]] && fhash=$(basename "$f" .json)
			"$on_resolved" "$fhash" >/dev/null || true
		fi
	done

	printf '%d' "$resolved"
}
