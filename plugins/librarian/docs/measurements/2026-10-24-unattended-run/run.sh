#!/usr/bin/env bash
# ONL-115 items 1 and 2: one real unattended stage run, sandboxed.
#
# Runs the INSTALLED librarian stage against copies of real parked candidates
# in a throwaway ONLOOKER_DIR, so nothing in the real lesson store changes. A
# pass-through `claude` shim adds --output-format json, keeps each call's full
# JSON (modelUsage, cost, turns), and prints only .result, so the stage sees
# exactly what it sees in production.
#
# Usage: run.sh <plugin_root> <out_dir> <lesson_id>...
set -uo pipefail

PLUGIN_ROOT="${1:?plugin root}"
OUT="${2:?out dir}"
shift 2
IDS=("$@")
[[ ${#IDS[@]} -gt 0 ]] || { echo "no lesson ids"; exit 1; }

REAL_CLAUDE=$(bash -c 'command -v claude')
ECOSYSTEM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
REAL_LESSONS="${REAL_ONLOOKER_DIR:-$HOME/.onlooker}/librarian/ee2cfbe428c7/lessons"

SANDBOX=$(mktemp -d -t onl115)
rm -rf "$OUT/calls"
mkdir -p "$SANDBOX/bin" "$OUT/calls"
export ONLOOKER_DIR="$SANDBOX/onlooker"
export ONLOOKER_EVENTS_LOG="$ONLOOKER_DIR/logs/onlooker-events.jsonl"
export ONLOOKER_ECOSYSTEM_ROOT="$ECOSYSTEM_REPO"
export ONLOOKER_VALIDATE=1
# Production hooks run with CLAUDE_PLUGIN_ROOT set, and the config loader reads
# shipped defaults from it. Without it every default reads empty: no --model is
# passed and the call runs on the session's default model.
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CALL_LOG="$OUT/calls"
export ONL115_DEPTH=0
export REAL_CLAUDE

cat > "$SANDBOX/bin/claude" <<'SHIM'
#!/usr/bin/env bash
n=$(find "$CALL_LOG" -name '*.json' | wc -l | tr -d ' ')
f="$CALL_LOG/$(printf '%02d' "$n").json"
# depth 0 is librarian's own call; deeper ones come from hooks that fire inside
# the nested session it starts.
printf 'depth=%s %s\n' "$ONL115_DEPTH" "$*" > "${f%.json}.args"
ONL115_DEPTH=$((ONL115_DEPTH + 1)) "$REAL_CLAUDE" "$@" --output-format json > "$f"
jq -r '.result // ""' "$f"
SHIM
chmod +x "$SANDBOX/bin/claude"
export PATH="$SANDBOX/bin:$PATH"

# A repo whose origin matches ecosystem's, so the project key is the real one
# and the copied proposals resolve. Its settings enable the stage here only.
REPO="$SANDBOX/repo"
mkdir -p "$REPO/.claude"
git -C "$REPO" init -q
git -C "$REPO" remote add origin "$(git -C "$ECOSYSTEM_REPO" remote get-url origin)"
printf '%s\n' '{"librarian":{"lesson_auto":{"enabled":true,"max_juries_per_scan":2}}}' \
	> "$REPO/.claude/settings.json"

for lib in librarian-config onlooker-project-key librarian-ulid librarian-storage \
	librarian-emit librarian-lesson-storage librarian-lesson-validate \
	librarian-author-key librarian-lesson-review librarian-lesson-rubric \
	librarian-lesson-judge librarian-lesson-promote librarian-lesson-transform \
	librarian-lesson-auto; do
	# shellcheck disable=SC1090
	source "$PLUGIN_ROOT/scripts/lib/$lib.sh"
done
librarian_config_load "$REPO"
KEY=$(onlooker_project_key "$REPO")
[[ "$KEY" == "ee2cfbe428c7" ]] || { echo "unexpected key $KEY"; exit 1; }
librarian_lesson_storage_init "$KEY"
for id in "${IDS[@]}"; do
	cp "$REAL_LESSONS/proposals/$id.json" "$(librarian_lessons_dir "$KEY")/proposals/"
done

{
	echo "plugin_root=$PLUGIN_ROOT"
	echo "judge_model=$(librarian_config_get '.librarian.lesson_auto.judge_model')"
	echo "transform_model=$(librarian_config_get '.librarian.lesson_transform.model')"
} > "$OUT/config.txt"

start=$(date +%s)
if [[ "${MODE:-stage}" == "judge" ]]; then
	# The jury path alone. Every candidate in the stage run was refused at the
	# justification step, so no judge was ever dispatched. Confirm each as a
	# model assertion (what an accepted justification produces), then run the
	# exact function the stage calls for a jury.
	export LIBRARIAN_SESSION_ID="onl115-measure"
	for id in "${IDS[@]}"; do
		librarian_lesson_confirm "$KEY" "$id" org \
			"The behavior follows from the language's documented semantics, not from any release." model
		printf '%s %s\n' "$id" "$(librarian_lesson_auto_judge_one "$KEY" "$id")" >> "$OUT/config.txt"
	done
else
	librarian_lesson_auto_stage "$KEY" "onl115-measure"
fi
echo "stage_seconds=$(( $(date +%s) - start ))" >> "$OUT/config.txt"

cp "$ONLOOKER_EVENTS_LOG" "$OUT/events.jsonl" 2>/dev/null || : > "$OUT/events.jsonl"
for id in "${IDS[@]}"; do
	jq -c '{id, status, asserted_by, auto_refusal, verdict: (.verdict // null | if . then {passed, reason, aggregate_score, failed_criterion, judges: [.judges[] | {judge_type, score, passed, criterion_scores}]} else null end)}' \
		"$(librarian_lessons_dir "$KEY")/proposals/$id.json"
done > "$OUT/outcomes.jsonl"
rm -rf "$SANDBOX"
