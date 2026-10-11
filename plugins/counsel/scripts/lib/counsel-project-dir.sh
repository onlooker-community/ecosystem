#!/usr/bin/env bash
# Where counsel keeps a project's briefs.
#
# Split out of counsel-project-key.sh when that file was replaced by the
# vendored canonical onlooker-project-key.sh: this embeds the plugin name and a
# subpath, so it is counsel's, not the substrate's.

counsel_project_dir() {
	local project_key="${1:-}"
	[[ -z "$project_key" ]] && return 1
	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	printf '%s' "${onlooker_dir}/counsel/${project_key}/briefs"
}
