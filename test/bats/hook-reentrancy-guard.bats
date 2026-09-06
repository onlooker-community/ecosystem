#!/usr/bin/env bats
#
# Every hook that shells out to the claude CLI must guard against re-entry.
#
# ecosystem-449.23. A nested `claude -p` is a real session: it fires the same
# hook events as any other and inherits the same plugin config, so a hook that
# invokes claude re-triggers itself. Tribunal recorded this in its own verdict
# text on 2026-08-30 — "The turn appears to be a meta-evaluation (a judge
# scoring another judge's output)" — so the mechanism is observed, not assumed.
#
# Seven hooks already carried the guard and five did not, including four
# enabled in this repo's committed settings by wave 2 (cartographer, counsel,
# librarian, scribe). The clearest sign it was being applied case by case
# rather than as a rule: cartographer guarded its PostToolUse hook and not its
# SessionStart hook.
#
# This test is the rule. It is deliberately repo-wide rather than five
# per-plugin tests, so a NEW plugin that shells out to claude cannot ship
# without a guard — which is the failure mode that produced this bead.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

# Does this file invoke the claude CLI?
#
# Comments are stripped first: several hooks discuss `claude -p` in their header
# and would otherwise self-report. `claude` must then appear as a COMMAND — at
# the start of a command position and followed by whitespace — which excludes
# CLAUDE_PLUGIN_ROOT (uppercase, underscore) and .claude-plugin (hyphen).
#
# `command -v claude` is excluded deliberately: it is an availability probe, not
# an invocation, and a hook that only probes needs no guard.
#
# Written permissively on purpose. An earlier version matched only `-p`/`--print`
# or an uppercase CLAUDE_ARGS array, and silently missed three real cases where
# the lib builds a lowercase `claude_args=(-p ...)` array — a false negative in
# a test whose whole job is catching omissions.
_invokes_claude() {
	sed 's/#.*$//' "$1" 2>/dev/null \
		| grep -vE 'command[[:space:]]+-v[[:space:]]+claude' \
		| grep -qE '(^|[|;&(]|[[:space:]])claude[[:space:]]'
}

# Does FILE name SCRIPT_BASENAME outside a comment? Covers both ways one
# script hands off to another -- `source lib.sh` and `exec .../run-audit.sh`
# -- because for re-entrancy they are the same thing: whatever environment the
# hook sets up, the child inherits.
_references() {
	sed 's/#.*$//' "$1" 2>/dev/null | grep -qF "$2"
}

# Every script in this plugin that leads to claude, directly or through another
# script it sources or executes.
#
# Computed to a fixpoint rather than one level deep, because the path can be
# indirect: cartographer's hooks exec run-audit.sh, which sources
# cartographer-analyze.sh, and only that last file actually runs `claude -p`.
# A one-level walk sees run-audit.sh invoke nothing and reports the hook clean
# -- which is how cartographer-session-start.sh was dismissed as needing no
# guard, on the strength of its own "NEVER calls claude -p" header comment.
# That invariant is true of the script and irrelevant to the recursion.
#
# Walks scripts/*.sh as well as scripts/lib/*.sh: run-audit.sh is a sibling of
# lib/, not inside it.
#
# Bounded to the plugin's own scripts/ tree. That holds only because no script
# under the ecosystem substrate's scripts/ invokes claude — checked, not
# assumed. If one ever does, a hook could reach claude through it and this walk
# would not see it.
_claude_reaching_scripts() {
	local plugin_dir="$1"
	local all=() reaching=() s dep changed=1 known

	for s in "${plugin_dir}"/scripts/*.sh "${plugin_dir}"/scripts/lib/*.sh \
		"${plugin_dir}"/scripts/hooks/*.sh; do
		[[ -f "$s" ]] && all+=("$s")
	done
	[[ ${#all[@]} -eq 0 ]] && return 0

	for s in "${all[@]}"; do
		_invokes_claude "$s" && reaching+=("$s")
	done

	while ((changed)); do
		changed=0
		for s in "${all[@]}"; do
			known=0
			for dep in "${reaching[@]+"${reaching[@]}"}"; do
				[[ "$s" == "$dep" ]] && { known=1; break; }
			done
			((known)) && continue
			for dep in "${reaching[@]+"${reaching[@]}"}"; do
				if _references "$s" "$(basename "$dep")"; then
					reaching+=("$s")
					changed=1
					break
				fi
			done
		done
	done

	printf '%s\n' "${reaching[@]+"${reaching[@]}"}"
}

# A hook reaches claude if it is anywhere in that set.
_reaches_claude() {
	local hook="$1" plugin_dir="$2" s
	while IFS= read -r s; do
		[[ "$s" == "$hook" ]] && return 0
	done < <(_claude_reaching_scripts "$plugin_dir")
	return 1
}

@test "every hook that invokes claude guards against re-entering itself" {
	local unguarded=() hook plugin_dir plugin
	for hook in "${REPO_ROOT}"/plugins/*/scripts/hooks/*.sh; do
		[[ -f "$hook" ]] || continue
		plugin_dir=$(cd "$(dirname "$hook")/../.." && pwd)
		plugin=$(basename "$plugin_dir")
		_reaches_claude "$hook" "$plugin_dir" || continue
		grep -qE '\[\[ "\$\{[A-Z_]+_NESTED:-0?\}" == "1" \]\] && exit 0' "$hook" \
			|| unguarded+=("${plugin}/$(basename "$hook")")
	done

	if [[ ${#unguarded[@]} -gt 0 ]]; then
		printf 'hooks invoking claude with no re-entrancy guard:\n'
		printf '  %s\n' "${unguarded[@]}"
		return 1
	fi
	true
}

# The guard must short-circuit before hook_health_register, or a nested
# invocation is recorded as a real hook run and inflates the very latency
# numbers the rollout is judged on.
@test "the guard sits above hook_health_register in every hook that has one" {
	local bad=() hook guard_line register_line
	for hook in "${REPO_ROOT}"/plugins/*/scripts/hooks/*.sh; do
		[[ -f "$hook" ]] || continue
		guard_line=$(grep -nE '^[[:space:]]*\[\[ "\$\{[A-Z_]+_NESTED:-0?\}" == "1" \]\] && exit 0' "$hook" 2>/dev/null | head -1 | cut -d: -f1)
		[[ -n "$guard_line" ]] || continue
		# The CALL, not a comment about it — tribunal's header discusses
		# hook_health_register 18 lines above where it actually calls it.
		register_line=$(grep -nE '^[[:space:]]*hook_health_register[[:space:]]' "$hook" 2>/dev/null | head -1 | cut -d: -f1)
		[[ -n "$register_line" ]] || continue
		[[ "$guard_line" -lt "$register_line" ]] \
			|| bad+=("$(basename "$hook") (guard line $guard_line, register line $register_line)")
	done

	if [[ ${#bad[@]} -gt 0 ]]; then
		printf 'guard placed after hook_health_register:\n'
		printf '  %s\n' "${bad[@]}"
		return 1
	fi
	true
}

# Setting the guard variable must also be paired with exporting it, or the
# nested claude process never inherits it and the guard does nothing.
@test "every guard exports its variable so the nested process inherits it" {
	local bad=() hook var
	for hook in "${REPO_ROOT}"/plugins/*/scripts/hooks/*.sh; do
		[[ -f "$hook" ]] || continue
		var=$(grep -oE '[A-Z][A-Z_]*_NESTED' "$hook" 2>/dev/null | head -1)
		[[ -n "$var" ]] || continue
		grep -qE "^export ${var}=1" "$hook" || bad+=("$(basename "$hook") ($var never exported)")
	done

	if [[ ${#bad[@]} -gt 0 ]]; then
		printf '%s\n' "${bad[@]}"
		return 1
	fi
	true
}
