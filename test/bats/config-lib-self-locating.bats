#!/usr/bin/env bats
#
# Guards that every plugin config lib locates config-loader.sh from its OWN
# path, not from a caller-supplied $PLUGIN_ROOT.
#
# These libs used to open with:
#
#   source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"
#
# PLUGIN_ROOT is read at source time from whatever scope did the sourcing. From
# a scope that never set it, the path collapses to
# /../../scripts/lib/config-loader.sh, the source fails, and config_load_plugin
# and config_get never get defined. The caller then gets empty strings from
# every accessor while the script keeps going and exits 0 — the config silently
# falls back to defaults instead of failing loudly.
#
# Cartographer hit exactly this (ecosystem-88v): run-audit.sh and both hooks
# sourced the config lib inside `bash -c` sub-shells that inherited
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT. It went unnoticed for months because
# the analyzers take their settings as positional parameters and kept working.
#
# The sweep in ecosystem-7bj made every lib self-locating via BASH_SOURCE, which
# is correct regardless of caller scope, cwd, or sub-shell nesting. These tests
# cover all 16 at once so plugin 17 cannot quietly reintroduce the pattern.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
}

# Every plugins/<name>/scripts/lib/<name>-config.sh in the repo.
_config_libs() {
  find "${REPO_ROOT}/plugins" -path '*/scripts/lib/*-config.sh' -type f | sort
}

# Without this, a typo in _config_libs would make every test below pass over an
# empty list and report coverage that does not exist. Not pinned to 16, so
# adding or removing a plugin does not fail it.
@test "the config-lib glob matches at least one file" {
  local count
  count=$(_config_libs | wc -l | tr -d ' ')
  [ "$count" -gt 0 ]
}

@test "no config lib resolves config-loader.sh through \$PLUGIN_ROOT" {
  local offenders=""
  local lib
  while IFS= read -r lib; do
    if grep -q 'source "\${PLUGIN_ROOT}' "$lib"; then
      offenders+="${lib#"${REPO_ROOT}/"}"$'\n'
    fi
  done < <(_config_libs)

  [ -z "$offenders" ] || {
    printf 'config libs still sourcing through $PLUGIN_ROOT:\n%s' "$offenders" >&2
    return 1
  }
}

@test "every config lib derives its own directory from BASH_SOURCE" {
  local missing=""
  local lib
  while IFS= read -r lib; do
    grep -q 'BASH_SOURCE\[0\]' "$lib" || missing+="${lib#"${REPO_ROOT}/"}"$'\n'
  done < <(_config_libs)

  [ -z "$missing" ] || {
    printf 'config libs not self-locating via BASH_SOURCE:\n%s' "$missing" >&2
    return 1
  }
}

# The behavioral test the source-text guards above stand in for. Sources each
# lib in a sub-shell with PLUGIN_ROOT unset and asserts the shared accessors it
# depends on actually got defined.
@test "every config lib yields working accessors with PLUGIN_ROOT unset" {
  local failures=""
  local lib
  while IFS= read -r lib; do
    local plugin_dir plugin_name out
    plugin_dir="${lib%/scripts/lib/*}"
    plugin_name="$(basename "$plugin_dir")"

    # CLAUDE_PLUGIN_ROOT is set because config_load_plugin genuinely needs it to
    # find the plugin's own config.json; PLUGIN_ROOT is deliberately absent,
    # which is the exact shape of the sub-shell that broke cartographer.
    out=$(env -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$plugin_dir" HOME="$HOME" \
      bash -c '
        set -u
        source "$1" 2>&1 || exit 1
        type -t config_load_plugin >/dev/null 2>&1 || { echo "config_load_plugin undefined"; exit 1; }
        type -t config_get >/dev/null 2>&1 || { echo "config_get undefined"; exit 1; }
        config_load_plugin "$2" "" _PROBE || { echo "config_load_plugin failed"; exit 1; }
        # A plugin ships a config.json, so the merged config must be a non-empty
        # JSON object. "{}" here would mean the load degraded to defaults.
        printf "%s" "$_PROBE" | jq -e "type == \"object\" and (length > 0)" >/dev/null \
          || { echo "merged config empty: $_PROBE"; exit 1; }
      ' _ "$lib" "$plugin_name" 2>&1) \
      || failures+="${plugin_name}: ${out}"$'\n'
  done < <(_config_libs)

  [ -z "$failures" ] || {
    printf 'config libs broken when PLUGIN_ROOT is unset:\n%s' "$failures" >&2
    return 1
  }
}

# Regression guard for the specific reported failure, kept separate so a break
# names cartographer directly rather than appearing in a list of 16.
@test "cartographer config survives the sub-shell shape that broke it" {
  local plugin_dir="${REPO_ROOT}/plugins/cartographer"
  run env -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$plugin_dir" bash -c '
    source "'"${plugin_dir}"'/scripts/lib/cartographer-config.sh"
    cartographer_config_load ""
    cartographer_config_audit_interval_hours
  '
  [ "$status" -eq 0 ] || return 1
  # The shipped default. Under the old pattern this came back empty, because
  # the accessor was never defined and the failure was swallowed.
  [[ -n "$output" ]] || return 1
  [[ "$output" != *"No such file or directory"* ]] || return 1
  [[ "$output" != *"command not found"* ]] || return 1
  [ "$output" -eq "$output" ] 2>/dev/null
}
