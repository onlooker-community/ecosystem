#!/usr/bin/env bash
# Where scribe keeps a project's artifacts.
#
# Split out of scribe-project-key.sh when that file was replaced by the
# vendored canonical onlooker-project-key.sh: this embeds the plugin name, so it
# is scribe's, not the substrate's.

scribe_project_dir() {
	local project_key="${1:-}"
	[[ -z "$project_key" ]] && return 1
	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	printf '%s' "${onlooker_dir}/scribe/${project_key}"
}
