#!/usr/bin/env bash
# Jury resolution for Tribunal.
#
# Maps a list of judge_types (from a rubric or config) into a panel of judges
# the orchestrator can spawn. Each panel entry carries:
#   - judge_id: ULID, unique per panel member
#   - judge_type: schema enum (standard, security, maintainability, adversarial,
#                 domain, meta)
#   - subagent: name of the subagent MD to invoke
#   - model: resolved per-judge-type model from config
#
# Two judge_types are recognized by schema but not yet shipped as subagents:
# `maintainability` and `domain`. The jury degrades them to `standard` and emits
# a warning on stderr so the orchestrator can log it.
#
# Requires tribunal-config.sh and tribunal-ulid.sh to be sourced.

# Map a judge_type to the shipped subagent name. Echoes empty if there is no
# shipped subagent.
_tribunal_jury_subagent_for_type() {
	case "$1" in
		standard)    printf 'tribunal-judge-standard' ;;
		security)    printf 'tribunal-judge-security' ;;
		adversarial) printf 'tribunal-judge-adversarial' ;;
		meta)        printf 'tribunal-meta-judge' ;;
		*) return 0 ;;
	esac
}

# Build a jury from a JSON array of judge_types.
# Echoes a JSON array of { judge_id, judge_type, subagent, model } objects.
# Unsupported types (maintainability, domain) are remapped to standard with a
# warning on stderr.
#
# Usage: jury=$(tribunal_jury_empanel '["standard","adversarial"]')
tribunal_jury_empanel() {
	local types_json="${1:-[]}"
	[[ -z "$types_json" ]] && types_json="[]"

	local panel='[]'
	local count
	count=$(printf '%s' "$types_json" | jq 'length' 2>/dev/null) || count=0

	local i raw_type judge_type subagent model judge_id
	for ((i = 0; i < count; i++)); do
		raw_type=$(printf '%s' "$types_json" | jq -r ".[$i]" 2>/dev/null) || continue
		[[ -z "$raw_type" || "$raw_type" == "null" ]] && continue

		# Schema-known types we don't ship yet degrade to standard.
		case "$raw_type" in
			maintainability|domain)
				printf 'tribunal-jury: judge_type "%s" not shipped in v0.1, degrading to standard\n' \
					"$raw_type" >&2
				judge_type="standard"
				;;
			meta)
				# Meta is the Meta-Judge — never goes in the jury panel.
				printf 'tribunal-jury: refusing to add judge_type "meta" to the jury (meta is the Meta-Judge)\n' >&2
				continue
				;;
			standard|security|adversarial)
				judge_type="$raw_type"
				;;
			*)
				printf 'tribunal-jury: unknown judge_type "%s", degrading to standard\n' \
					"$raw_type" >&2
				judge_type="standard"
				;;
		esac

		subagent=$(_tribunal_jury_subagent_for_type "$judge_type")
		[[ -z "$subagent" ]] && continue

		model=$(tribunal_config_judge_model "$judge_type")
		judge_id=$(tribunal_ulid)

		panel=$(printf '%s' "$panel" | jq -c \
			--arg id "$judge_id" \
			--arg type "$judge_type" \
			--arg sub "$subagent" \
			--arg model "$model" \
			'. + [{
				judge_id: $id,
				judge_type: $type,
				subagent: $sub,
				model: (if $model == "" then null else $model end)
			}]')
	done

	printf '%s' "$panel"
}

# Render a jury into the schema's TribunalJuryEmpaneledPayload.judges shape:
# [{ judge_id, judge_type, model_id }, ...]
tribunal_jury_to_schema_judges() {
	local panel="${1:-[]}"
	printf '%s' "$panel" | jq -c '[.[] | {
		judge_id: .judge_id,
		judge_type: .judge_type,
		model_id: .model
	} | with_entries(select(.value != null))]'
}
