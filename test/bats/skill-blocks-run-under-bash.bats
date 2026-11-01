#!/usr/bin/env bats
#
# Guards that the shell blocks in SKILL.md files run from the tool shell.
#
# Claude Code's Bash tool runs the user's shell, which is zsh on macOS, and
# keeps no functions between calls. The blocks source libs that need bash, so
# each skill tells the agent to run Setup and its mode block together in one
# `bash <<'ONLOOKER_SKILL'` call. The quoted delimiter keeps zsh from expanding
# anything inside it.
#
# CLAUDE_PLUGIN_ROOT is not exported to the Bash tool. Claude Code substitutes
# only the exact `${CLAUDE_PLUGIN_ROOT}` spelling into skill text, so
# `$CLAUDE_PLUGIN_ROOT` and `${CLAUDE_PLUGIN_ROOT:-...}` both arrive empty, and
# a BASH_SOURCE fallback has no file to locate from a pasted block (ONL-230).

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
}

# Skipping in CI would pass these over nothing, so a missing zsh only skips on
# a developer machine.
_require_zsh() {
  command -v zsh >/dev/null 2>&1 && return 0
  [[ -z "${CI:-}" ]] || {
    echo "zsh is required in CI" >&2
    return 1
  }
  skip "zsh not installed"
}

_skills_with_setup() {
  grep -lE '^[[:space:]]*source ' "${REPO_ROOT}"/plugins/*/skills/*/SKILL.md | sort
}

_config_libs() {
  find "${REPO_ROOT}/plugins" -path '*/scripts/lib/*-config.sh' -type f | sort
}

# The first ```bash fence that sources a lib, as Claude Code renders it: the
# plugin root substituted in, and the sample CLI call that needs real arguments
# dropped.
_render_setup_block() {
  local skill="$1" plugin_root
  plugin_root="${skill%/skills/*}"
  awk '
    /^```bash$/ && !done { in_block = 1; buf = ""; next }
    /^```$/ && in_block {
      in_block = 0
      if (buf ~ /source /) { printf "%s", buf; done = 1 }
      next
    }
    in_block { buf = buf $0 "\n" }
  ' "$skill" |
    grep -v '_cli "<action>"' |
    sed "s|\${CLAUDE_PLUGIN_ROOT}|${plugin_root}|g"
}

@test "the skill glob matches the skills that source libs" {
  local count
  count=$(_skills_with_setup | wc -l | tr -d ' ')
  [ "$count" -ge 6 ]
}

@test "no skill spells the plugin root in a form Claude Code will not substitute" {
  local offenders
  offenders=$(grep -nE 'BASH_SOURCE|\$CLAUDE_PLUGIN_ROOT|\$\{CLAUDE_PLUGIN_ROOT:' \
    "${REPO_ROOT}"/plugins/*/skills/*/SKILL.md || true)
  [ -z "$offenders" ] || {
    printf 'unsubstituted plugin root:\n%s\n' "$offenders" >&2
    return 1
  }
}

@test "every skill that sources libs documents the bash wrapper" {
  local missing="" skill
  while IFS= read -r skill; do
    grep -qF "bash <<'ONLOOKER_SKILL'" "$skill" || missing+="${skill#"${REPO_ROOT}/"}"$'\n'
  done < <(_skills_with_setup)
  [ -z "$missing" ] || {
    printf 'skills without the bash wrapper:\n%s' "$missing" >&2
    return 1
  }
}

@test "every skill setup block loads when launched from zsh" {
  _require_zsh
  cd "$REPO_ROOT"

  local skill script failures=""
  while IFS= read -r skill; do
    script="${BATS_TEST_TMPDIR}/run.zsh"
    {
      printf "set -uo pipefail\nbash <<'ONLOOKER_SKILL'\n"
      _render_setup_block "$skill"
      printf 'echo SETUP_BLOCK_FINISHED\nONLOOKER_SKILL\n'
    } >"$script"

    run zsh "$script"
    if [[ "$status" -ne 0 || "$output" != *SETUP_BLOCK_FINISHED* || "$output" == *"not found"* ]]; then
      failures+="${skill#"${REPO_ROOT}/"} (status ${status}): ${output}"$'\n'
    fi
  done < <(_skills_with_setup)

  [ -z "$failures" ] || {
    printf 'setup blocks that failed from zsh:\n%s' "$failures" >&2
    return 1
  }
}

@test "a config lib sourced from zsh names the shell, not the package" {
  _require_zsh

  local lib failures=""
  while IFS= read -r lib; do
    run zsh -c "set -uo pipefail; source '${lib}'"
    if [[ "$status" -ne 1 || "$output" != *"needs bash"* || "$output" == *"incomplete"* ]]; then
      failures+="${lib#"${REPO_ROOT}/"} (status ${status}): ${output}"$'\n'
    fi
  done < <(_config_libs)

  [ -z "$failures" ] || {
    printf 'config libs with the wrong failure under zsh:\n%s' "$failures" >&2
    return 1
  }
}

@test "a config lib still loads under bash" {
  local lib failures=""
  while IFS= read -r lib; do
    run bash -c "set -uo pipefail; source '${lib}'"
    [[ "$status" -eq 0 ]] || failures+="${lib#"${REPO_ROOT}/"}: ${output}"$'\n'
  done < <(_config_libs)

  [ -z "$failures" ] || {
    printf 'config libs that broke under bash:\n%s' "$failures" >&2
    return 1
  }
}
