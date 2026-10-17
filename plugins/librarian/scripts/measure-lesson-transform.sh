#!/usr/bin/env bash
# Measure the lesson transform's jury pass rate on a batch (ONL-110).
#
# WHY THIS EXISTS. The evidence that transform claims fail adversarial review
# was n=2: two candidates, each passing the standard judge and failing the
# adversary. Two is enough to notice a pattern and not enough to measure one,
# and ONL-110's Done-when requires any fix be "measured against a batch rather
# than a single lucky candidate". So the batch has to exist before the fix
# does, and the baseline has to be recorded before anything changes.
#
# WHAT IT DOES. Transforms N archivist artifacts into lesson candidates with
# the real transform, scores each with the real two-judge panel, and reports
# per-criterion pass rates against a rubric READ FROM CONFIG — including
# `disclosure`, which carries the strictest floor (0.9) and which the issue
# body never mentioned.
#
# NOTHING TERMINAL TOUCHES THE REAL STORE. A decline is permanent
# (librarian_lesson_seen reads declined.jsonl), so measuring in place would
# burn every artifact it scored and the second run would have nothing left to
# measure. The whole run happens inside a throwaway ONLOOKER_DIR seeded with
# copies. That also empties declined.jsonl, which is why artifacts already
# declined in real life are measurable again here.
#
# IT SCORES WITHOUT CONFIRMING. librarian_lesson_judge requires a `confirmed`
# proposal and then writes; this calls librarian_lesson_aggregate and
# librarian_lesson_gate directly instead. Those are pure, and they are the same
# two functions the real verdict is computed from, so the number means what it
# says. The judge PROMPT comes from librarian_lesson_auto_judge_prompt — the
# one production dispatches — rather than a copy that would keep reporting old
# rates after the prompt changed.
#
# IT JUDGES THE SHAPE PRODUCTION CONFIRMS INTO. librarian_lesson_auto_stage runs
# auto_confirm_one BEFORE auto_judge_one, and that step rewrites a parked
# candidate's scope from {"kind":"unscoped"} to {"kind":"version_independent"}.
# The judge prompt then asserts "a MODEL asserted that this lesson holds
# regardless of version" — true of the confirmed shape, false of the raw one.
# Judging the raw candidate asserts a claim it does not make, and it costs real
# score: measured on three candidates, scope_accuracy fell ~0.11 and grounding
# ~0.05, in the same direction every time. So a parked candidate's scope is
# rewritten here the way auto_confirm_one would write it. `--raw-scope` turns
# that off to reproduce the pre-fix measurement. The justification model call
# auto_confirm_one makes is NOT reproduced: it gates whether confirmation
# happens, and does not change the candidate the panel sees.
#
# THE UNSCOPED COST CAP IS BYPASSED, deliberately: unscoped_per_scan (3) is
# cost control on a live scan, not a quality mechanism, and leaving it on would
# silently truncate the batch to three parked candidates. Every call passes
# unscoped_so_far=0.
#
# NOT WIRED INTO npm test. A full N=12 run costs 12 transform calls plus 24
# judge calls. test/bats/librarian-measure-lesson-transform.bats covers the
# plumbing with a stubbed `claude`, and test/node/lesson-transform-stats.test.mjs
# covers the arithmetic exhaustively.
#
# Usage:
#   measure-lesson-transform.sh [--samples N] [--out DIR] [--dry-run]
#                               [--rubric ID] [--project-key KEY]
#                               [--sample-mode spread|richest] [--artifacts-from DIR]
#                               [--raw-scope]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_ROOT}/../.." && pwd)"

SAMPLES=12
DRY_RUN=0
OUT_DIR=""
RUBRIC_ID="lesson-promotion-public"
PROJECT_KEY=""
SAMPLE_MODE="spread"
ARTIFACTS_FROM=""
CONFIRM_SHAPE=1

while [[ $# -gt 0 ]]; do
	case "$1" in
		--samples) SAMPLES="${2:-}"; shift 2 ;;
		--out) OUT_DIR="${2:-}"; shift 2 ;;
		--rubric) RUBRIC_ID="${2:-}"; shift 2 ;;
		--project-key) PROJECT_KEY="${2:-}"; shift 2 ;;
		--sample-mode) SAMPLE_MODE="${2:-}"; shift 2 ;;
		--artifacts-from) ARTIFACTS_FROM="${2:-}"; shift 2 ;;
		--raw-scope) CONFIRM_SHAPE=0; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '2,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
	esac
done

# A bad count has to fail here, loudly. These runners use `set -uo pipefail`
# without `-e` on purpose, so reaching the arithmetic below with a bare word
# makes bash read it as a variable name, `set -u` calls it unbound, and the
# script stops with status 0 having written nothing — a caller reads success
# and finds no artifacts. Same reasoning as echo's measure-judge-spread.sh.
if [[ ! "$SAMPLES" =~ ^[1-9][0-9]*$ ]]; then
	printf -- '--samples must be a positive integer; got: %s\n' "$SAMPLES" >&2
	exit 1
fi
case "$SAMPLE_MODE" in
	spread|richest) ;;
	*) printf -- '--sample-mode must be spread or richest; got: %s\n' "$SAMPLE_MODE" >&2; exit 1 ;;
esac

for lib in onlooker-project-key librarian-ulid librarian-storage \
	librarian-lesson-storage librarian-lesson-validate librarian-config \
	librarian-author-key librarian-lesson-review librarian-lesson-rubric \
	librarian-lesson-judge librarian-lesson-promote librarian-lesson-transform \
	librarian-lesson-auto; do
	# shellcheck disable=SC1090
	source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh" || {
		printf 'cannot source %s\n' "$lib" >&2
		exit 1
	}
done

REAL_ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}"

# Resolve the corpus. Default: the archivist artifacts for THIS repo, which is
# the raw material a live scan would actually transform.
if [[ -z "$PROJECT_KEY" ]]; then
	onlooker_project_resolve "$REPO_ROOT"
	PROJECT_KEY="${ONLOOKER_PROJECT_KEY:-}"
fi
if [[ -z "$PROJECT_KEY" ]]; then
	printf 'cannot resolve a project key; pass --project-key\n' >&2
	exit 1
fi
[[ -z "$ARTIFACTS_FROM" ]] && ARTIFACTS_FROM="${REAL_ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
if [[ ! -d "$ARTIFACTS_FROM" ]]; then
	printf 'no artifact corpus at %s\n' "$ARTIFACTS_FROM" >&2
	exit 1
fi

# Rank the corpus by detail length, richest first.
#
# Requires the fields the transform prompt actually reads, so a
# differently-shaped store fails here rather than producing a batch of empty
# prompts that scores like a result. librarian's own artifacts/ carry
# title/body, not summary/detail, and are NOT this corpus.
#
# A function because bash 3.2 — which `#!/usr/bin/env bash` resolves to on
# macOS — cannot parse a comment inside a process substitution, and has no
# `mapfile` to read one into an array.
_rank_corpus() {
	find "$ARTIFACTS_FROM" -type f -name '*.json' 2>/dev/null \
		| while IFS= read -r f; do
			len=$(jq -r '((.detail // "") | length)' "$f" 2>/dev/null) || continue
			[[ -z "$len" || "$len" == "null" ]] && continue
			jq -e 'has("id") and has("summary") and has("detail")' "$f" >/dev/null 2>&1 || continue
			printf '%s\t%s\n' "$len" "$f"
		done | sort -rn | cut -f2
}

# The bead asks whether the raw material is part of the problem: the original
# n=2 were the richest artifacts, which are implementation write-ups, and their
# claims came out as descriptions of work rather than transferable lessons.
# `richest` reproduces that bias on purpose so the two arms are comparable;
# `spread` takes evenly spaced ranks across the whole corpus, which is the
# honest default. Both are deterministic, so a re-run after a prompt change
# measures the same artifacts.
RANKED=()
while IFS= read -r _line; do
	[[ -n "$_line" ]] && RANKED+=("$_line")
done < <(_rank_corpus)

CORPUS_SIZE="${#RANKED[@]}"
if [[ "$CORPUS_SIZE" -eq 0 ]]; then
	printf 'no usable artifacts in %s (need id, summary, detail)\n' "$ARTIFACTS_FROM" >&2
	exit 1
fi
if [[ "$SAMPLES" -gt "$CORPUS_SIZE" ]]; then
	printf 'only %d usable artifacts; lowering --samples from %d\n' "$CORPUS_SIZE" "$SAMPLES" >&2
	SAMPLES="$CORPUS_SIZE"
fi

SELECTED=()
if [[ "$SAMPLE_MODE" == "richest" ]]; then
	for ((i = 0; i < SAMPLES; i++)); do SELECTED+=("${RANKED[$i]}"); done
else
	# Evenly spaced ranks, first and last included.
	if [[ "$SAMPLES" -eq 1 ]]; then
		SELECTED+=("${RANKED[0]}")
	else
		for ((i = 0; i < SAMPLES; i++)); do
			idx=$(( i * (CORPUS_SIZE - 1) / (SAMPLES - 1) ))
			SELECTED+=("${RANKED[$idx]}")
		done
	fi
fi

CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" librarian_config_load "$REPO_ROOT"
TRANSFORM_MODEL=$(librarian_config_get '.librarian.lesson_transform.model' 2>/dev/null)
JUDGE_MODEL=$(librarian_config_get '.librarian.lesson_auto.judge_model' 2>/dev/null)
case "$JUDGE_MODEL" in ''|null) JUDGE_MODEL="claude-haiku-4-5-20251001" ;; esac

RUBRIC=$(librarian_lesson_rubric_get "$RUBRIC_ID") || {
	printf 'rubric %s is not defined in config\n' "$RUBRIC_ID" >&2
	exit 1
}
THRESHOLD=$(printf '%s' "$RUBRIC" | jq -r '.score_threshold')
POLICY=$(printf '%s' "$RUBRIC" | jq -r '.gate_policy')

if [[ "$DRY_RUN" -eq 1 ]]; then
	printf 'would run %d transform calls + %d judge calls (%d total)\n' \
		"$SAMPLES" "$(( SAMPLES * 2 ))" "$(( SAMPLES * 3 ))"
	printf 'transform model: %s\njudge model:     %s\n' "${TRANSFORM_MODEL:-default}" "$JUDGE_MODEL"
	printf 'rubric:          %s (threshold %s, gate %s)\n' "$RUBRIC_ID" "$THRESHOLD" "$POLICY"
	printf 'corpus:          %s (%d usable, mode %s)\n' "$ARTIFACTS_FROM" "$CORPUS_SIZE" "$SAMPLE_MODE"
	for f in "${SELECTED[@]}"; do printf '  %s\n' "${f##*/}"; done
	exit 0
fi

command -v claude >/dev/null 2>&1 || {
	printf 'claude is not on PATH; nothing to measure\n' >&2
	exit 1
}

[[ -z "$OUT_DIR" ]] && OUT_DIR="${REAL_ONLOOKER_DIR}/librarian/measure/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR" || { printf 'cannot create %s\n' "$OUT_DIR" >&2; exit 1; }

_sha256() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
	else sha256sum "$1" | cut -d' ' -f1; fi
}
# Both prompts are stamped. A pass rate is a property of ONE transform prompt
# scored by ONE judge prompt under ONE model pair; without all four a later
# reader cannot tell whether the baseline still applies. ONL-110's own notes
# exist because an earlier figure could not say.
TRANSFORM_SHA=$(_sha256 "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-transform.sh")
JUDGE_SHA=$(_sha256 "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-auto.sh")

SANDBOX=$(mktemp -d 2>/dev/null) || { printf 'cannot create a sandbox\n' >&2; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
export ONLOOKER_DIR="$SANDBOX"
librarian_lesson_storage_init "$PROJECT_KEY"

printf 'measuring %d candidates (rubric %s)\n' "$SAMPLES" "$RUBRIC_ID" >&2

ACC="${OUT_DIR}/.acc.json"
printf '[]' > "$ACC"

for f in "${SELECTED[@]}"; do
	artifact=$(cat "$f" 2>/dev/null) || continue
	aid=$(printf '%s' "$artifact" | jq -r '.id // ""')
	detail_len=$(printf '%s' "$artifact" | jq -r '((.detail // "") | length)')

	# unscoped_so_far=0 every time: see the header on the cost cap.
	outcome=$(librarian_lesson_transform_one "$PROJECT_KEY" "$artifact" 0)

	lesson_id=""
	parked=0
	case "$outcome" in
		proposed:*:unscoped) lesson_id="${outcome#proposed:}"; lesson_id="${lesson_id%:unscoped}"; parked=1 ;;
		proposed:*) lesson_id="${outcome#proposed:}" ;;
	esac

	verdicts='[]'
	aggregate='null'
	gate='null'
	candidate='null'

	if [[ -n "$lesson_id" ]]; then
		path="$(librarian_lessons_dir "$PROJECT_KEY")/proposals/${lesson_id}.json"
		candidate=$(jq -c '.candidate' "$path" 2>/dev/null) || candidate='null'
	fi

	judged_scope_kind=""
	if [[ "$candidate" != "null" && -n "$candidate" ]]; then
		if [[ "$CONFIRM_SHAPE" -eq 1 && "$parked" -eq 1 ]]; then
			candidate=$(printf '%s' "$candidate" \
				| jq -c '.applies_to.scope = {"kind":"version_independent"}' 2>/dev/null) \
				|| candidate='null'
		fi
		judged_scope_kind=$(printf '%s' "$candidate" | jq -r '.applies_to.scope.kind // ""' 2>/dev/null)
	fi

	if [[ "$candidate" != "null" && -n "$candidate" ]]; then
		prompt=$(librarian_lesson_auto_judge_prompt "$candidate" "$RUBRIC")
		std=$(_librarian_lesson_auto_judge tribunal-judge-standard "$prompt" "$JUDGE_MODEL")
		adv=$(_librarian_lesson_auto_judge tribunal-judge-adversarial "$prompt" "$JUDGE_MODEL")

		# Stamp judge_type from the agent we dispatched, exactly as
		# librarian_lesson_auto_judge_one does — a model echoing the
		# "standard|adversarial" literal would otherwise corrupt the split
		# this whole measurement is about.
		if [[ -n "$std" && -n "$adv" ]]; then
			std=$(printf '%s' "$std" | jq -c '.judge_type = "standard"' 2>/dev/null) || std=""
			adv=$(printf '%s' "$adv" | jq -c '.judge_type = "adversarial"' 2>/dev/null) || adv=""
		fi
		if [[ -n "$std" && -n "$adv" ]]; then
			verdicts=$(jq -cn --argjson a "$std" --argjson b "$adv" '[$a, $b]' 2>/dev/null) || verdicts='[]'
			aggregate=$(librarian_lesson_aggregate "$verdicts" "$RUBRIC") || aggregate='null'
			if [[ "$aggregate" != "null" ]]; then
				gate=$(librarian_lesson_gate "$POLICY" "$verdicts" "$aggregate" "$THRESHOLD" "$RUBRIC") || gate='null'
			fi
			printf '.' >&2
		else
			# Empty is infrastructure, not a verdict — the distinction the
			# transform and the auto stage both draw. Recorded as a judge
			# failure so a short batch cannot masquerade as a low pass rate.
			printf 'x' >&2
		fi
	else
		printf '%s' "${outcome:0:1}" >&2
	fi

	jq --arg aid "$aid" --arg lid "$lesson_id" --arg out "$outcome" \
		--arg jsk "$judged_scope_kind" \
		--argjson parked "$parked" --argjson dl "$detail_len" \
		--argjson cand "$candidate" --argjson v "$verdicts" \
		--argjson agg "${aggregate:-null}" --argjson g "${gate:-null}" \
		'. + [{artifact_id: $aid, lesson_id: $lid, transform_outcome: $out,
		       parked: ($parked == 1), detail_length: $dl,
		       judged_scope_kind: (if $jsk == "" then null else $jsk end),
		       candidate: $cand, verdicts: $v, aggregate: $agg, gate: $g}]' \
		"$ACC" > "${ACC}.next" && mv "${ACC}.next" "$ACC"
done
printf '\n' >&2

# `corpus` is provenance, not a filesystem handle, and these artifacts get
# committed. Collapse the ONLOOKER_DIR and home prefixes to literals so a
# recorded measurement carries no operator username and reads the same on any
# machine. Order matters: ONLOOKER_DIR usually lives under HOME, so the more
# specific prefix has to win.
CORPUS_LABEL="$ARTIFACTS_FROM"
CORPUS_LABEL="${CORPUS_LABEL/#$REAL_ONLOOKER_DIR/\$ONLOOKER_DIR}"
CORPUS_LABEL="${CORPUS_LABEL/#$HOME/\~}"

SAMPLES_JSON="${OUT_DIR}/samples.json"
jq -n \
	--arg transform_model "${TRANSFORM_MODEL:-default}" \
	--arg judge_model "$JUDGE_MODEL" \
	--arg transform_sha256 "$TRANSFORM_SHA" \
	--arg judge_prompt_sha256 "$JUDGE_SHA" \
	--arg measured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg corpus "$CORPUS_LABEL" \
	--arg sample_mode "$SAMPLE_MODE" \
	--argjson confirm_shape "$([[ "$CONFIRM_SHAPE" -eq 1 ]] && printf true || printf false)" \
	--arg project_key "$PROJECT_KEY" \
	--argjson corpus_size "$CORPUS_SIZE" \
	--argjson rubric "$RUBRIC" \
	--slurpfile acc "$ACC" \
	'{transform_model: $transform_model, judge_model: $judge_model,
	  transform_sha256: $transform_sha256, judge_prompt_sha256: $judge_prompt_sha256,
	  measured_at: $measured_at, corpus: $corpus, corpus_size: $corpus_size,
	  sample_mode: $sample_mode, project_key: $project_key,
	  confirm_shape: $confirm_shape,
	  rubric: $rubric, candidates: $acc[0]}' > "$SAMPLES_JSON" || {
	printf 'cannot write %s\n' "$SAMPLES_JSON" >&2
	exit 1
}
rm -f "$ACC"

node "${SCRIPT_DIR}/lesson-transform-stats.mjs" "$SAMPLES_JSON" > "${OUT_DIR}/stats.json" || {
	printf 'statistics failed; raw samples kept at %s\n' "$SAMPLES_JSON" >&2
	exit 1
}

printf '\nsamples: %s\nstats:   %s\n\n' "$SAMPLES_JSON" "${OUT_DIR}/stats.json"
node -e '
const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const pct = (x) => (x === null ? "  n/a" : `${(x * 100).toFixed(1)}%`.padStart(6));
console.log(`n=${s.n} judged of ${s.transform.attempted} attempted  (proposed ${s.transform.proposed}, declined ${s.transform.declined}, skipped ${s.transform.skipped}, unavailable ${s.transform.unavailable})`);
console.log(`gate pass rate: ${pct(s.gate.pass_rate)}   reasons: ${JSON.stringify(s.gate.reasons)}`);
console.log("");
console.log("judge        pass rate   mean score");
for (const [t, d] of Object.entries(s.judges)) {
  console.log(`  ${t.padEnd(12)}${pct(d.pass_rate)}      ${d.mean_score ?? "n/a"}`);
}
console.log("");
console.log("criterion        floor  pass rate  min-mean  std    adv     unscored");
for (const [name, c] of Object.entries(s.criteria)) {
  const sj = c.by_judge.standard, aj = c.by_judge.adversarial;
  console.log(`  ${name.padEnd(15)}${String(c.min_pass).padEnd(7)}${pct(c.pass_rate)}    ${String(c.min_mean ?? "n/a").padEnd(10)}${pct(sj?.pass_rate ?? null)} ${pct(aj?.pass_rate ?? null)}  ${c.unscored}`);
}
' "${OUT_DIR}/stats.json"
