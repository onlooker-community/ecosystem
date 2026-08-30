#!/usr/bin/env bash
# Build and append lineage change records.
#
# Storage: $ONLOOKER_DIR/lineage/<project-key>/changes.jsonl — append-only, one
# change per line. Each record:
#   { change_id, ts, ts_epoch, session_id, turn?, tool, operation, file_path,
#     lines_added, lines_removed, bytes, edit_count, content_sha256,
#     added_snippets[], transcript_path }
#
# The bus event (lineage.change.recorded) carries metadata + content_sha256
# only; the added content lives here in the per-project ledger, where the
# /lineage query content-anchors a line back to the change that introduced it.
#
# Requires lineage-redact.sh and portable-lock.sh sourced beforehand.

lineage_record_dir() {
	local key="${1:-unknown}"
	local safe
	safe=$(printf '%s' "$key" | tr -c 'a-zA-Z0-9-' '_')
	printf '%s/lineage/%s' "${ONLOOKER_DIR:-${HOME}/.onlooker}" "$safe"
}

lineage_record_path() { printf '%s/changes.jsonl' "$(lineage_record_dir "$1")"; }

lineage_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf ''; }
lineage_now_epoch() { date +%s 2>/dev/null || printf '0'; }

lineage_sha256() {
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1
	else
		printf ''
	fi
}

# Line count of a text blob (0 for empty). `grep -c ''` counts every line,
# including a final line with no trailing newline.
_lineage_count_lines() {
	[[ -z "$1" ]] && { printf '0'; return 0; }
	printf '%s' "$1" | grep -c '' 2>/dev/null || printf '0'
}

# Tool → operation enum (create|overwrite|edit|multi_edit). Write is recorded as
# a coarse "create"; the create/overwrite distinction is not reliably knowable
# at PostToolUse and does not affect the provenance answer.
_lineage_operation() {
	case "$1" in
		Edit) printf 'edit' ;;
		MultiEdit) printf 'multi_edit' ;;
		Write) printf 'create' ;;
		Bash) printf 'shell_edit' ;;
		*) printf 'edit' ;;
	esac
}

# Added / removed content extracted from the tool_input JSON, per tool.
_lineage_added() {
	local tool="$1" ti="$2"
	case "$tool" in
		Edit) printf '%s' "$ti" | jq -r '.new_string // ""' 2>/dev/null ;;
		Write) printf '%s' "$ti" | jq -r '.content // ""' 2>/dev/null ;;
		MultiEdit) printf '%s' "$ti" | jq -r '[.edits[]?.new_string // ""] | join("\n")' 2>/dev/null ;;
	esac
}

_lineage_removed() {
	local tool="$1" ti="$2"
	case "$tool" in
		Edit) printf '%s' "$ti" | jq -r '.old_string // ""' 2>/dev/null ;;
		Write) printf '' ;;
		MultiEdit) printf '%s' "$ti" | jq -r '[.edits[]?.old_string // ""] | join("\n")' 2>/dev/null ;;
	esac
}

# Build a change record JSON (pure — no I/O). Echoes the record.
# Usage: lineage_build_record <change_id> <ts> <ts_epoch> <session_id> <turn>
#          <tool> <file_path> <tool_input_json> <max_chars> <do_redact>
#          <transcript_path> [added_override] [provenance_kind] [content_scope]
#
# added_override carries content git found for a shell-shaped edit, where
# tool_input says nothing about what changed. provenance_kind and content_scope
# are emitted only when set, so Edit/Write/MultiEdit records are byte-identical
# to before this change.
lineage_build_record() {
	local change_id="$1" ts="$2" ts_epoch="$3" session_id="$4" turn="$5"
	local tool="$6" file_path="$7" ti="$8" max_chars="$9" do_redact="${10}" transcript_path="${11}"
	local added_override="${12:-}" prov_kind="${13:-}" content_scope="${14:-}"

	local added removed added_red lines_added lines_removed bytes digest op edit_count
	if [[ -n "$added_override" ]]; then
		added="$added_override"
		removed=""
	else
		added=$(_lineage_added "$tool" "$ti")
		removed=$(_lineage_removed "$tool" "$ti")
	fi
	lines_added=$(_lineage_count_lines "$added")
	lines_removed=$(_lineage_count_lines "$removed")
	bytes=$(printf '%s' "$added" | wc -c | tr -d ' ')
	digest=$(lineage_sha256 "$added")
	op=$(_lineage_operation "$tool")
	edit_count=$(printf '%s' "$ti" | jq -r 'if .edits then (.edits | length) else 1 end' 2>/dev/null) || edit_count=1
	added_red=$(printf '%s' "$added" | lineage_redact "$max_chars" "$do_redact")

	jq -n \
		--arg cid "$change_id" --arg ts "$ts" --argjson te "${ts_epoch:-0}" \
		--arg sid "$session_id" --arg tool "$tool" --arg op "$op" \
		--arg fp "$file_path" --arg snip "$added_red" --arg tp "$transcript_path" \
		--argjson la "${lines_added:-0}" --argjson lr "${lines_removed:-0}" \
		--argjson by "${bytes:-0}" --arg digest "$digest" \
		--argjson ec "${edit_count:-1}" --arg turn "$turn" \
		--arg pk "$prov_kind" --arg cs "$content_scope" \
		'{
			change_id: $cid, ts: $ts, ts_epoch: $te,
			session_id: $sid, tool: $tool, operation: $op, file_path: $fp,
			lines_added: $la, lines_removed: $lr, bytes: $by,
			edit_count: $ec, content_sha256: $digest,
			added_snippets: [$snip], transcript_path: $tp
		}
		+ (if $turn != "" then {turn: ($turn | tonumber)} else {} end)
		+ (if $pk != "" then {provenance_kind: $pk} else {} end)
		+ (if $cs != "" then {content_scope: $cs} else {} end)' 2>/dev/null
}

# Append a record to the project ledger under its write lock.
# Usage: lineage_append <project_key> <record_json>
lineage_append() {
	local key="$1" record="$2"
	[[ -z "$key" || -z "$record" ]] && return 1

	local dir path lock rec_compact
	dir=$(lineage_record_dir "$key")
	path="${dir}/changes.jsonl"
	lock="${path}.lock"
	mkdir -p "$dir" 2>/dev/null || return 1

	rec_compact=$(printf '%s' "$record" | jq -c . 2>/dev/null) || return 1

	if lock_acquire "$lock" 5; then
		printf '%s\n' "$rec_compact" >> "$path" 2>/dev/null
		local ok=$?
		lock_release "$lock"
		return "$ok"
	fi
	return 1
}
