#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  source "${PLUGIN_ROOT}/scripts/lib/lineage-record.sh"
  source "${PLUGIN_ROOT}/scripts/lib/lineage-baseline.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  printf 'one\n' > "${PROJECT_REPO}/tracked.txt"
  git -C "$PROJECT_REPO" add tracked.txt
  git -C "$PROJECT_REPO" commit -qm "seed"
}

@test "baseline path lands under lineage-baselines, never under lineage" {
  run lineage_baseline_path "abc123" "sess-1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"/lineage-baselines/abc123/sess-1.json" ]] || return 1
  [[ "$output" != *"/lineage/abc123"* ]]
}

@test "candidate_paths reports a modified tracked file" {
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$output" = "tracked.txt" ]
}

# The gap a `git diff --name-only HEAD` enumeration would miss entirely.
@test "candidate_paths reports an untracked new file" {
  printf 'brand new\n' > "${PROJECT_REPO}/created.txt"
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$output" = "created.txt" ]
}

@test "candidate_paths handles a path with a space" {
  printf 'x\n' > "${PROJECT_REPO}/two words.txt"
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$output" = "two words.txt" ]
}

# `git status --porcelain=v1 -z` emits a rename as the status-prefixed new
# path followed by a SECOND, bare record holding only the old path. Slicing
# that bare record like a normal one chops into the path text itself.
@test "candidate_paths reports the new path for a rename" {
  git -C "$PROJECT_REPO" mv tracked.txt renamed.txt
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "renamed.txt" ]
}

@test "candidate_paths does not yield a mangled old path for a rename" {
  git -C "$PROJECT_REPO" mv tracked.txt renamed.txt
  run lineage_candidate_paths "$PROJECT_REPO"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"cked.txt"* ]] || return 1
  [[ "$output" != *"tracked.txt"* ]]
}

@test "baseline_build writes no key for a path that does not exist on disk" {
  git -C "$PROJECT_REPO" mv tracked.txt renamed.txt
  base=$(lineage_baseline_build "$PROJECT_REPO")
  missing=""
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    [ -f "${PROJECT_REPO}/${k}" ] || missing="${missing}${k},"
  done < <(printf '%s' "$base" | jq -r '.files | keys[]')
  [ -z "$missing" ]
}

@test "changed_files reports a newly created untracked file" {
  base=$(lineage_baseline_build "$PROJECT_REPO")
  printf 'brand new\n' > "${PROJECT_REPO}/created.txt"
  run lineage_changed_files "$PROJECT_REPO" "$base"
  [ "$output" = "created.txt" ]
}

@test "added_content returns the whole file for an untracked file" {
  printf 'brand new\n' > "${PROJECT_REPO}/created.txt"
  run lineage_added_content "$PROJECT_REPO" "created.txt"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"brand new"* ]]
}

@test "changed_files reports a file modified after the baseline" {
  base=$(lineage_baseline_build "$PROJECT_REPO")
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  run lineage_changed_files "$PROJECT_REPO" "$base"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "tracked.txt" ]
}

@test "changed_files reports nothing when nothing changed" {
  base=$(lineage_baseline_build "$PROJECT_REPO")
  run lineage_changed_files "$PROJECT_REPO" "$base"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ]
}

# The case a hash of `git status` output alone would miss: the file was ALREADY
# dirty at baseline, so its status line is byte-identical after the second edit
# and only a per-path content sha can tell them apart.
@test "changed_files catches a second edit to an already-dirty file" {
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  base=$(lineage_baseline_build "$PROJECT_REPO")
  before=$(lineage_candidate_paths "$PROJECT_REPO")
  printf 'three\n' >> "${PROJECT_REPO}/tracked.txt"
  after=$(lineage_candidate_paths "$PROJECT_REPO")
  [ "$before" = "$after" ] || return 1   # the status listing really is identical
  run lineage_changed_files "$PROJECT_REPO" "$base"
  [ "$output" = "tracked.txt" ]
}

@test "content_scope is delta for a file clean at baseline" {
  base=$(lineage_baseline_build "$PROJECT_REPO")
  run lineage_content_scope "$base" "tracked.txt"
  [ "$output" = "delta" ]
}

@test "content_scope is cumulative for a file already dirty at baseline" {
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  base=$(lineage_baseline_build "$PROJECT_REPO")
  run lineage_content_scope "$base" "tracked.txt"
  [ "$output" = "cumulative" ]
}

@test "added_content returns the added lines only" {
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  run lineage_added_content "$PROJECT_REPO" "tracked.txt"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"two"* ]] || return 1
  [[ "$output" != *"one"* ]]
}

@test "classify marks git switch as tool_generated" {
  run lineage_classify_command "git switch -c feat/x"
  [ "$output" = "tool_generated" ]
}

@test "classify marks npm ci as tool_generated" {
  run lineage_classify_command "npm ci --silent"
  [ "$output" = "tool_generated" ]
}

@test "classify marks a formatter as tool_generated" {
  run lineage_classify_command "./node_modules/.bin/biome format --write src"
  [ "$output" = "tool_generated" ]
}

# The default that keeps this bug from recurring one layer up.
@test "classify defaults an unrecognized command to authored" {
  run lineage_classify_command "frobnicate --rewrite everything"
  [ "$output" = "authored" ]
}

@test "classify treats a heredoc write as authored" {
  run lineage_classify_command "cat > file.txt <<EOF"
  [ "$output" = "authored" ]
}

@test "candidate_paths is empty for a non-git directory" {
  run lineage_candidate_paths "${BATS_TEST_TMPDIR}"
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ]
}
