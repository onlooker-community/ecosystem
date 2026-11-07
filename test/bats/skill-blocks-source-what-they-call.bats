#!/usr/bin/env bats
#
# Guards that every plugin function a SKILL.md runs is defined by a lib the
# skill sources (ONL-151).
#
# In ONL-129 the counsel skill called counsel_project_dir from a block that
# never sourced counsel-project-dir.sh. The lib was vendored; it just wasn't
# loaded. Under `set -uo pipefail` the missing function left BRIEFS_DIR empty
# instead of failing, and the block survived shellcheck, the bats suite,
# lint:references and four reviews. Nothing runs these blocks in CI, so the
# check has to.
#
# What runs together decides what counts as sourced. The agent sends Setup
# (the first ```bash fence that sources a lib) together with one mode fence in
# a single `bash` call, so a mode fence may call anything Setup loads. A prose
# code span such as `librarian_cli accept <id>` runs the same way, with Setup.
# A ```! fence is executed alone when the skill loads, so it only gets what it
# sources itself.
#
# Which functions a set of source lines makes available is read from bash
# itself: the lines run and `declare -F` reports the result. That covers
# lib-to-lib chains and loaders that source through a variable
# (`source "$_COUNSEL_CONFIG_LOADER"`) without re-implementing either here.
# A name counts as a plugin function when a lib under the plugin's
# scripts/lib defines it at column 0, which is how every lib in the repo
# writes one.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
}

# Skills with a block that sources a lib: the plugins', and the ecosystem's
# own under skills/, whose plugin root is the repo root.
_skills_that_source() {
  grep -lE '^[[:space:]]*source ' \
    "${REPO_ROOT}"/plugins/*/skills/*/SKILL.md "${REPO_ROOT}"/skills/*/SKILL.md 2>/dev/null | sort
}

# Writes each ```bash and ```! fence of a skill to <dir>/<n>.sh, unindented,
# with <dir>/<n>.meta holding "<bash|bang> <line of the fence's first line>".
_split_fences() {
  awk -v dir="$2" '
    !inb && ($0 ~ /^[[:space:]]*```bash[[:space:]]*$/ || $0 ~ /^[[:space:]]*```![[:space:]]*$/) {
      n++
      inb = 1
      ind = match($0, /[^ \t]/) - 1
      f = dir "/" n ".sh"
      printf "" > f
      meta = dir "/" n ".meta"
      print (($0 ~ /```!/) ? "bang" : "bash"), NR + 1 > meta
      close(meta)
      next
    }
    inb && /^[[:space:]]*```[[:space:]]*$/ { inb = 0; close(f); next }
    inb { print substr($0, ind + 1) > f }
  ' "$1"
}

# Every function a lib under <root>/scripts/lib defines.
_plugin_functions() {
  grep -hoE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$1"/scripts/lib/*.sh | tr -d '()' | sort -u
}

# The functions defined once the source lines of the given fences have run,
# plus any a fence defines for itself.
_available_functions() {
  local root="$1"
  shift
  {
    bash -c "set -uo pipefail
PLUGIN_ROOT='${root}'
export CLAUDE_PLUGIN_ROOT='${root}'
$(grep -hE '^[[:space:]]*source ' "$@" | sed "s|\${CLAUDE_PLUGIN_ROOT}|${root}|g")
declare -F" 2>/dev/null | awk '{print $3}'
    grep -hoE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)' "$@" | tr -d '() \t'
  } | sort -u
}

# "<name> <line>" for each plugin function a fence names, first use only.
# Comment lines are skipped; anything else that spells the name counts.
_fence_calls() {
  awk 'NR == FNR { fn[$1] = 1; next }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      gsub(/[^A-Za-z0-9_]/, " ", line)
      n = split(line, w, " ")
      for (i = 1; i <= n; i++)
        if ((w[i] in fn) && !(w[i] in seen)) { seen[w[i]] = 1; print w[i], FNR }
    }' "$1" "$2"
}

# "<name> <line>" for each prose code span outside the fences whose first word
# is a plugin function: a command the skill tells the agent to run.
_prose_calls() {
  awk 'NR == FNR { fn[$1] = 1; next }
    /^[[:space:]]*```/ { infence = !infence; next }
    infence { next }
    {
      rest = $0
      while (match(rest, /`[^`]+`/)) {
        span = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        split(span, w, " ")
        if (w[1] in fn) print w[1], FNR
      }
    }' "$1" "$2"
}

# "<skill>:<line> <name>" for every plugin function a skill runs that what it
# sources does not define. Empty when the skill is sound. With --count, prints
# how many calls were checked instead, so a caller can tell a sound skill from
# one the parse found nothing in.
_unreachable_calls() {
  local skill="$1" mode="${2:-}" root dir setup="" n kind start name line checked=0
  root="${skill%/skills/*}"
  dir=$(mktemp -d "${BATS_TEST_TMPDIR}/fences.XXXXXX")
  _split_fences "$skill" "$dir"
  _plugin_functions "$root" >"${dir}/universe"

  n=1
  while [[ -f "${dir}/${n}.meta" ]]; do
    read -r kind start <"${dir}/${n}.meta"
    if [[ "$kind" == bash ]] && grep -qE '^[[:space:]]*source ' "${dir}/${n}.sh"; then
      setup="${dir}/${n}.sh"
      break
    fi
    n=$((n + 1))
  done

  n=1
  while [[ -f "${dir}/${n}.meta" ]]; do
    read -r kind start <"${dir}/${n}.meta"
    if [[ "$kind" == bang || -z "$setup" || "$setup" == "${dir}/${n}.sh" ]]; then
      _available_functions "$root" "${dir}/${n}.sh" >"${dir}/${n}.avail"
    else
      _available_functions "$root" "$setup" "${dir}/${n}.sh" >"${dir}/${n}.avail"
    fi
    while read -r name line; do
      checked=$((checked + 1))
      grep -qxF "$name" "${dir}/${n}.avail" ||
        printf '%s:%s %s\n' "${skill#"${REPO_ROOT}/"}" "$((start + line - 1))" "$name"
    done < <(_fence_calls "${dir}/universe" "${dir}/${n}.sh")
    n=$((n + 1))
  done

  if [[ -n "$setup" ]]; then
    _available_functions "$root" "$setup" >"${dir}/setup.avail"
    while read -r name line; do
      checked=$((checked + 1))
      grep -qxF "$name" "${dir}/setup.avail" ||
        printf '%s:%s %s\n' "${skill#"${REPO_ROOT}/"}" "$line" "$name"
    done < <(_prose_calls "${dir}/universe" "$skill")
  fi

  [[ "$mode" != --count ]] || printf '%s\n' "$checked"
}

# A copy of a plugin's skill under a scratch plugin root whose scripts/ is the
# real one, so a test can break the copy without touching the repo.
_scratch_skill() {
  local plugin="$1" root="${BATS_TEST_TMPDIR}/plugins/$1"
  mkdir -p "${root}/skills/${plugin}"
  ln -s "${REPO_ROOT}/plugins/${plugin}/scripts" "${root}/scripts"
  cp "${REPO_ROOT}/plugins/${plugin}/skills/${plugin}/SKILL.md" "${root}/skills/${plugin}/SKILL.md"
  printf '%s' "${root}/skills/${plugin}/SKILL.md"
}

@test "the skill glob finds the skills that source libs, plugin and repo-root" {
  local skills
  skills=$(_skills_that_source)
  [ "$(printf '%s\n' "$skills" | wc -l | tr -d ' ')" -ge 7 ] || return 1
  [[ "$skills" == *"/skills/list-prompt-rules/SKILL.md"* ]]
}

@test "every plugin function a skill runs is defined by a lib it sources" {
  cd "$REPO_ROOT"

  local skill unreachable=""
  while IFS= read -r skill; do
    unreachable+="$(_unreachable_calls "$skill")"
  done < <(_skills_that_source)

  [ -z "$unreachable" ] || {
    printf 'calls to functions no sourced lib defines:\n%s\n' "$unreachable" >&2
    return 1
  }
}

# Without this the check above passes on a parse that found nothing.
@test "the check reaches calls in every skill that sources libs" {
  cd "$REPO_ROOT"

  local skill count empty=""
  while IFS= read -r skill; do
    count=$(_unreachable_calls "$skill" --count | tail -n 1)
    [[ "$count" -gt 0 ]] || empty+="${skill#"${REPO_ROOT}/"}"$'\n'
  done < <(_skills_that_source)

  [ -z "$empty" ] || {
    printf 'skills where the check found no calls to check:\n%s' "$empty" >&2
    return 1
  }
}

# The ONL-129 bug, reproduced: the lib exists and is vendored, it just isn't
# sourced.
@test "a Setup block that drops the lib its own call needs is reported" {
  local skill
  skill=$(_scratch_skill counsel)
  grep -q 'counsel-project-dir.sh' "$skill" || return 1
  sed -i.bak '/counsel-project-dir\.sh/d' "$skill"

  run _unreachable_calls "$skill"
  [[ "$output" == *" counsel_project_dir"* ]]
}

# A mode fence and a prose command both run with Setup, so both depend on it.
@test "a mode fence and a prose command lose a function when Setup stops loading it" {
  local skill
  skill=$(_scratch_skill librarian)
  sed -i.bak '/librarian-cli\.sh/d' "$skill"

  local fence_line prose_line
  fence_line=$(grep -nF 'librarian_cli "<action>"' "$skill" | cut -d: -f1)
  prose_line=$(grep -nF 'Call `librarian_cli list`' "$skill" | cut -d: -f1)
  [[ -n "$fence_line" && -n "$prose_line" ]] || return 1

  run _unreachable_calls "$skill"
  # The Setup fence's own `librarian_cli "<action>"` line, and a prose command.
  [[ "$output" == *"SKILL.md:${fence_line} librarian_cli"* ]] || return 1
  [[ "$output" == *"SKILL.md:${prose_line} librarian_cli"* ]]
}

@test "a sound skill copy reports nothing" {
  local skill
  skill=$(_scratch_skill counsel)

  run _unreachable_calls "$skill"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ]
}
