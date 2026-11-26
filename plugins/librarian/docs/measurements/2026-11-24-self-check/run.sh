#!/usr/bin/env bash
# ONL-311: the self-check's recall, false fails and cost, on real lessons.
#
# Sends each lesson's claim, stack and stored version_independent
# justification through the production prompt builder, one real `claude -p`
# each, with --output-format json for the cost. Reads the lesson store;
# writes nothing to it.
#
# Usage: run.sh <group>...   (vetoed kept human rejected)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO/plugins/librarian"
for lib in librarian-config librarian-storage librarian-lesson-storage librarian-lesson-auto; do
	# shellcheck disable=SC1090
	source "$CLAUDE_PLUGIN_ROOT/scripts/lib/${lib}.sh"
done
librarian_config_load "$REPO"
MODEL=$(librarian_config_get '.librarian.lesson_transform.model')

[[ $# -gt 0 ]] || { echo "usage: run.sh <group>..."; exit 1; }
OUT="$HERE/results.jsonl"
STORE="${ONLOOKER_DIR:-$HOME/.onlooker}/librarian"

for group in "$@"; do
	awk -F'\t' -v g="$group" '$1 == g {print $2}' "$HERE/ids.tsv" | while read -r id; do
		matches=("$STORE"/*/lessons/proposals/"$id".json)
		f="${matches[0]}"
		[[ -f "$f" ]] || { echo "missing $id" >&2; continue; }
		candidate=$(jq -c '.candidate' "$f")
		justification=$(jq -r '.candidate.applies_to.scope.justification' "$f")
		raw=$(librarian_lesson_auto_self_check_prompt "$candidate" "$justification" \
			| claude -p --max-turns 1 --settings '{"disableAllHooks":true}' \
				--model "$MODEL" --output-format json 2>/dev/null)
		jq -cn --arg g "$group" --arg id "$id" --argjson r "${raw:-null}" \
			'{group: $g, id: $id,
			  verdict: ($r.result // "" | gsub("\n"; " ")),
			  cost_usd: ($r.total_cost_usd // null)}' >> "$OUT"
	done
done
