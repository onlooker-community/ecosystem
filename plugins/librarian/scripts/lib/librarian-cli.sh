#!/usr/bin/env bash
# Interactive control surface for the /librarian review skill.
#
# Exposes:
#   librarian_cli list                         # one-line summary + table of pending proposals
#   librarian_cli show <proposal_id>           # full proposal body + provenance + conflict state
#   librarian_cli accept <proposal_id>         # write to typed memory store, mark accepted
#   librarian_cli reject <proposal_id> [reason]  # tombstone + mark rejected
#   librarian_cli defer  <proposal_id>         # mark as deferred=true while keeping status pending
#   librarian_cli status                       # one-line counts (pending / accepted / rejected)
#
# Memory store writes go to:
#   ${HOME}/.claude/projects/${CLAUDE_PROJECT_ENCODED}/memory/<filename>
#
# When CLAUDE_PROJECT_ENCODED is unset, the CLI derives the encoded form
# from the current working directory (replace `/` with `-`). The MEMORY.md
# index is updated in-place — the accepted memory is appended as a new
# bullet line, and the file is created if it doesn't exist.
#
# Depends on (sourced by the caller): librarian-config.sh,
# librarian-project-key.sh, librarian-storage.sh, librarian-emit.sh

# ----------------------------------------------------------------------------
# Project key + memory store path resolution
# ----------------------------------------------------------------------------

_librarian_cli_project_key() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && cwd="$(pwd)"
	librarian_project_key "$cwd"
}

_librarian_cli_memory_dir() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && cwd="$(pwd)"

	local encoded="${CLAUDE_PROJECT_ENCODED:-}"
	if [[ -z "$encoded" ]]; then
		local abs
		abs=$(cd "$cwd" 2>/dev/null && pwd -P) || abs=""
		[[ -n "$abs" ]] && encoded=$(printf '%s' "$abs" | sed -E 's#/#-#g')
	fi
	[[ -z "$encoded" ]] && return 0

	printf '%s/.claude/projects/%s/memory' "${HOME:-}" "$encoded"
}

# ----------------------------------------------------------------------------
# Helpers for the typed memory store
# ----------------------------------------------------------------------------

# Write a single memory file with provenance frontmatter and update
# MEMORY.md to reference it. Returns 0 on success.
#
# Usage: _librarian_cli_write_memory <memory_dir> <proposal_json>
_librarian_cli_write_memory() {
	local mem_dir="$1"
	local proposal="$2"
	[[ -z "$mem_dir" || -z "$proposal" ]] && return 1
	mkdir -p "$mem_dir" 2>/dev/null || return 1

	local id type title body filename confidence src_session_ids src_artifact_ids now
	id=$(printf '%s' "$proposal" | jq -r '.id // ""')
	type=$(printf '%s' "$proposal" | jq -r '.proposed.type // ""')
	title=$(printf '%s' "$proposal" | jq -r '.proposed.title // ""')
	body=$(printf '%s' "$proposal" | jq -r '.proposed.body // ""')
	filename=$(printf '%s' "$proposal" | jq -r '.proposed.filename // ""')
	confidence=$(printf '%s' "$proposal" | jq -r '.proposed.classifier_confidence // 0')
	src_session_ids=$(printf '%s' "$proposal" | jq -c '.source_session_ids // []')
	src_artifact_ids=$(printf '%s' "$proposal" | jq -c '.source_artifact_ids // []')
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	[[ -z "$type" || -z "$title" || -z "$body" || -z "$filename" ]] && return 1

	# Strip any `/` or `..` from the filename — proposals come from a
	# trusted source, but the safety check costs nothing.
	case "$filename" in
		*/*|*..*|.*) return 1 ;;
	esac
	[[ "$filename" == *.md ]] || return 1

	local out_path="${mem_dir}/${filename}"

	# Build the provenance YAML frontmatter. Single-line description and
	# title come from the classifier; the source* arrays carry traceability.
	{
		printf -- '---\n'
		printf 'name: %s\n' "$title"
		printf 'description: librarian-promoted from proposal %s\n' "$id"
		printf 'type: %s\n' "$type"
		printf 'source: librarian\n'
		printf 'classifier_confidence: %s\n' "$confidence"
		printf 'promoted_at: %s\n' "$now"
		printf 'source_session_ids: %s\n' "$src_session_ids"
		printf 'source_artifact_ids: %s\n' "$src_artifact_ids"
		printf -- '---\n\n'
		printf '%s\n' "$body"
	} > "$out_path" || return 1

	# Update MEMORY.md: append a one-line entry referencing the new file.
	local index_path="${mem_dir}/MEMORY.md"
	if [[ ! -f "$index_path" ]]; then
		printf '# Memory index\n\n' > "$index_path" || return 1
	fi
	# Avoid duplicate entries on repeated accepts of the same id (shouldn't
	# happen but is cheap to guard against).
	if ! grep -F -q "(${filename})" "$index_path"; then
		printf -- '- [%s](%s) — %s\n' "$title" "$filename" "$type" >> "$index_path"
	fi

	printf '%s' "$out_path"
}

# Update a proposal's status field (pending → accepted | rejected | deferred).
# Returns 0 on success.
_librarian_cli_set_proposal_status() {
	local key="$1"
	local proposal_id="$2"
	local new_status="$3"
	local extra_json="${4:-{\}}"
	[[ -z "$key" || -z "$proposal_id" || -z "$new_status" ]] && return 1

	local path
	path="$(librarian_proposals_dir "$key")/${proposal_id}.json"
	[[ -f "$path" ]] || return 1

	local now updated
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(jq --arg status "$new_status" --arg t "$now" --argjson extra "$extra_json" \
		'. * { status: $status, updated_at: $t } * $extra' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	printf '%s\n' "$updated" > "$path"
}

# ----------------------------------------------------------------------------
# Public surface
# ----------------------------------------------------------------------------

librarian_cli_list() {
	local cwd="${1:-}"
	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 0; }

	local pending
	pending=$(librarian_storage_load_proposals "$key" \
		| jq '[.[] | select((.status // "pending") == "pending")]')
	local count
	count=$(printf '%s' "$pending" | jq 'length' 2>/dev/null) || count=0

	if [[ "$count" -eq 0 ]]; then
		printf 'No pending proposals.\n'
		return 0
	fi

	printf '%s pending proposal%s:\n\n' "$count" "$([ "$count" -eq 1 ] && echo "" || echo "s")"
	# Print header + rows together so `column -t` (BSD-portable) aligns both.
	# We can't use util-linux's `column -N` here — macOS ships BSD column,
	# which only supports `-t` and `-s`.
	{
		printf 'ID\tTYPE\tCONFIDENCE\tCONFLICT\tTITLE\n'
		printf '%s' "$pending" | jq -r '
			.[] | [
				(.id // ""),
				(.proposed.type // "?"),
				((.proposed.classifier_confidence // 0) | tostring),
				(.conflict_state // "none"),
				(.proposed.title // "")
			] | @tsv
		'
	} | column -t -s $'\t'
}

librarian_cli_show() {
	local proposal_id="${1:-}"
	local cwd="${2:-}"
	[[ -z "$proposal_id" ]] && { printf 'usage: librarian_cli show <proposal_id>\n'; return 1; }

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	local path
	path="$(librarian_proposals_dir "$key")/${proposal_id}.json"
	if [[ ! -f "$path" ]]; then
		printf 'Proposal %s not found.\n' "$proposal_id"
		return 1
	fi

	jq -r '
		"--- proposal " + .id + " (" + (.status // "pending") + ") ---",
		"created_at:           " + (.created_at // ""),
		"type:                 " + (.proposed.type // ""),
		"title:                " + (.proposed.title // ""),
		"filename:             " + (.proposed.filename // ""),
		"classifier_confidence: " + ((.proposed.classifier_confidence // 0) | tostring),
		"conflict_state:       " + (.conflict_state // "none"),
		"source_session_ids:   " + ((.source_session_ids // []) | join(", ")),
		"source_artifact_ids:  " + ((.source_artifact_ids // []) | join(", ")),
		"",
		"body:",
		(.proposed.body // "")
	' "$path"
}

librarian_cli_accept() {
	local proposal_id="${1:-}"
	local cwd="${2:-}"
	[[ -z "$proposal_id" ]] && { printf 'usage: librarian_cli accept <proposal_id>\n'; return 1; }

	local key session_id
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }
	session_id="${CLAUDE_SESSION_ID:-cli}"

	local path proposal
	path="$(librarian_proposals_dir "$key")/${proposal_id}.json"
	[[ -f "$path" ]] || { printf 'Proposal %s not found.\n' "$proposal_id"; return 1; }
	proposal=$(jq '.' "$path") || { printf 'Could not parse proposal.\n'; return 1; }

	local mem_dir
	mem_dir=$(_librarian_cli_memory_dir "$cwd")
	[[ -z "$mem_dir" ]] && { printf 'Could not resolve typed memory store path. Set CLAUDE_PROJECT_ENCODED or run from inside the project.\n'; return 1; }

	local out_path
	out_path=$(_librarian_cli_write_memory "$mem_dir" "$proposal") || {
		printf 'Failed to write memory file.\n'
		return 1
	}

	local filename
	filename=$(printf '%s' "$proposal" | jq -r '.proposed.filename')
	_librarian_cli_set_proposal_status "$key" "$proposal_id" "accepted" \
		"$(jq -cn --arg final_filename "$filename" '{accepted_via: "manual", final_filename: $final_filename}')" \
		|| { printf 'Wrote memory file at %s but failed to update proposal status.\n' "$out_path"; return 1; }

	librarian_emit "librarian.proposal.accepted" "$session_id" "$(jq -cn \
		--arg proposal_id "$proposal_id" \
		--arg final_filename "$filename" \
		--arg accepted_via "manual" \
		'{proposal_id: $proposal_id, final_filename: $final_filename, accepted_via: $accepted_via}')"

	printf 'Accepted. Wrote %s\n' "$out_path"
}

librarian_cli_reject() {
	local proposal_id="${1:-}"
	local reason="${2:-}"
	local cwd="${3:-}"
	[[ -z "$proposal_id" ]] && { printf 'usage: librarian_cli reject <proposal_id> [reason]\n'; return 1; }

	local key session_id
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }
	session_id="${CLAUDE_SESSION_ID:-cli}"

	local path proposal body original_filename body_hash
	path="$(librarian_proposals_dir "$key")/${proposal_id}.json"
	[[ -f "$path" ]] || { printf 'Proposal %s not found.\n' "$proposal_id"; return 1; }
	proposal=$(jq '.' "$path") || { printf 'Could not parse proposal.\n'; return 1; }
	body=$(printf '%s' "$proposal" | jq -r '.proposed.body // ""')
	original_filename=$(printf '%s' "$proposal" | jq -r '.proposed.filename // ""')

	# Tombstone keyed on body hash so the same content does not re-propose.
	body_hash=$(librarian_body_hash "$body")
	if [[ -n "$body_hash" ]]; then
		if librarian_storage_write_tombstone "$key" "$body_hash" "$original_filename"; then
			librarian_emit "librarian.tombstone.created" "$session_id" "$(jq -cn \
				--arg body_hash "$body_hash" \
				--arg original_filename "$original_filename" \
				'{body_hash: $body_hash, original_filename: (if $original_filename == "" then null else $original_filename end)}
				 | with_entries(select(.value != null))')"
		else
			printf 'Failed to write tombstone for proposal %s.\n' "$proposal_id"
			return 1
		fi
	fi

	_librarian_cli_set_proposal_status "$key" "$proposal_id" "rejected" \
		"$(jq -cn --arg reason "$reason" '{reason: (if $reason == "" then null else $reason end)}')" \
		|| return 1

	librarian_emit "librarian.proposal.rejected" "$session_id" "$(jq -cn \
		--arg proposal_id "$proposal_id" \
		--arg reason "$reason" \
		'{proposal_id: $proposal_id, reason: (if $reason == "" then null else $reason end)}
		 | with_entries(select(.value != null))')"

	printf 'Rejected proposal %s%s\n' "$proposal_id" "$([ -n "$reason" ] && echo " (reason: $reason)" || echo "")"
}

librarian_cli_defer() {
	local proposal_id="${1:-}"
	local cwd="${2:-}"
	[[ -z "$proposal_id" ]] && { printf 'usage: librarian_cli defer <proposal_id>\n'; return 1; }

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	local path
	path="$(librarian_proposals_dir "$key")/${proposal_id}.json"
	[[ -f "$path" ]] || { printf 'Proposal %s not found.\n' "$proposal_id"; return 1; }

	# Deferred proposals remain pending — we just stamp the proposal with
	# an updated_at so a reviewer can tell it was visited.
	_librarian_cli_set_proposal_status "$key" "$proposal_id" "pending" \
		'{"deferred": true}' || return 1
	printf 'Deferred proposal %s — still in the queue for next session.\n' "$proposal_id"
}

librarian_cli_status() {
	local cwd="${1:-}"
	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 0; }

	local all
	all=$(librarian_storage_load_proposals "$key")
	local pending accepted rejected
	pending=$(printf '%s' "$all" | jq '[.[] | select((.status // "pending") == "pending")] | length')
	accepted=$(printf '%s' "$all" | jq '[.[] | select(.status == "accepted")] | length')
	rejected=$(printf '%s' "$all" | jq '[.[] | select(.status == "rejected")] | length')
	printf 'pending: %s, accepted: %s, rejected: %s\n' "$pending" "$accepted" "$rejected"
}

librarian_cli() {
	local action="${1:-list}"
	shift || true
	case "$action" in
		list) librarian_cli_list "$@" ;;
		show) librarian_cli_show "$@" ;;
		accept) librarian_cli_accept "$@" ;;
		reject) librarian_cli_reject "$@" ;;
		defer) librarian_cli_defer "$@" ;;
		status) librarian_cli_status "$@" ;;
		*) printf 'unknown action: %s\n' "$action"; return 2 ;;
	esac
}
