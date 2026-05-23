#!/usr/bin/env bats
# Verifies the on-disk plugin manifests for archivist are wired up correctly.

setup_file() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
}

@test "archivist plugin.json is valid JSON with name and version" {
  run jq -e '.name == "archivist" and (.version | length > 0)' \
    "${REPO_ROOT}/plugins/archivist/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
}

@test "archivist config.json has plugin_name and archivist.enabled defaulting to false" {
  run jq -e '.plugin_name == "archivist" and .archivist.enabled == false' \
    "${REPO_ROOT}/plugins/archivist/config.json"
  [ "$status" -eq 0 ]
}

@test "marketplace.json lists ecosystem first and archivist second" {
  run jq -e '.plugins[0].name == "ecosystem" and .plugins[1].name == "archivist"' \
    "${REPO_ROOT}/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
}

@test "marketplace.json plugin entries omit version (claude reads version from plugin.json)" {
  # See https://code.claude.com/docs/en/plugins-reference.md#version-management:
  # plugin.json's version is the cache key. Setting it in both locations is a
  # documented drift hazard.
  run jq -e 'all(.plugins[]; has("version") | not)' "${REPO_ROOT}/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
}

@test "release-please-manifest.json tracks plugins/archivist" {
  run jq -e '.["plugins/archivist"]' "${REPO_ROOT}/.release-please-manifest.json"
  [ "$status" -eq 0 ]
}

@test "release-please-config.json declares plugins/archivist as a package" {
  run jq -e '.packages["plugins/archivist"] | type == "object"' \
    "${REPO_ROOT}/release-please-config.json"
  [ "$status" -eq 0 ]
}

@test "archivist hooks.json wires PreCompact manual+auto and SessionStart" {
  local f="${REPO_ROOT}/plugins/archivist/hooks/hooks.json"
  run jq -e '
    (.hooks.PreCompact | length) == 2 and
    .hooks.PreCompact[0].matcher == "manual" and
    .hooks.PreCompact[1].matcher == "auto" and
    .hooks.SessionStart[0].matcher == "*"
  ' "$f"
  [ "$status" -eq 0 ]
}

@test "archivist hook scripts are executable" {
  for script in archivist-extract.sh archivist-inject.sh; do
    test -x "${REPO_ROOT}/plugins/archivist/scripts/hooks/$script"
  done
}
