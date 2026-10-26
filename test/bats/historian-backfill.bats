#!/usr/bin/env bats
#
# backfill.sh embeds chunks that were stored without a vector (ONL-207).
#
# When the embedder is down, run-index.sh stores every chunk anyway and leaves
# `embedding` off. That is the right fail-soft call, but the retriever is
# embedding-only, so those chunks are unreachable until something embeds them.
# Measured on one machine: ollama stopped on 2026-10-21 and nothing restarted
# it, and four days later 15,019 chunks across 380 sessions had no vector.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/historian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/historian-test.git

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]

	ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	BACKFILL="${PLUGIN_ROOT}/scripts/backfill.sh"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	export PATH="${STUB_BIN}:${PATH}"
	CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
	: > "$CURL_LOG"

	mkdir -p "${PROJECT_REPO}/.claude"
	jq -n '{
		historian: {
			indexing: { min_transcript_chars_to_index: 50, chunk_target_chars: 400, chunk_overlap_chars: 50 },
			embedder: {
				backend: "ollama",
				ollama: { host: "http://127.0.0.1:11434", model: "nomic-embed-text" }
			}
		}
	}' > "${PROJECT_REPO}/.claude/settings.json"
	_install_curl_stub
}

# A curl stub standing in for ollama. tags_ok decides whether the probe passes,
# embed_rc is the exit status of every embed, and dims is the vector length
# the "model" returns. Every embed call is logged so a test can count them.
#
# ok_calls, when set, lets that many embeds succeed before embed_rc applies:
# an embedder that goes away partway through a run.
_install_curl_stub() {
	local tags_ok="${1:-1}" embed_rc="${2:-0}" dims="${3:-768}" ok_calls="${4:-0}"
	cat >"${STUB_BIN}/curl" <<STUB
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
	case "\$arg" in
		http*) url="\$arg" ;;
	esac
done
case "\$url" in
	*/api/tags)
		[[ "${tags_ok}" -eq 1 ]] || exit 7
		printf '%s' '{"models":[{"name":"nomic-embed-text:latest"}]}'
		exit 0
		;;
	*/api/embeddings)
		echo embed >> "${CURL_LOG}"
		if [[ "${embed_rc}" -ne 0 ]] && (( \$(grep -c embed "${CURL_LOG}") > ${ok_calls} )); then
			exit ${embed_rc}
		fi
		python3 -c 'import json; print(json.dumps({"embedding": [0.01] * ${dims}}))'
		exit 0
		;;
esac
exit 0
STUB
	chmod +x "${STUB_BIN}/curl"
}

_session_file() {
	local key="${1:-$PROJECT_KEY}" sid="${2:-sess-a}"
	printf '%s/historian/%s/sessions/%s.jsonl' "$ONLOOKER_DIR" "$key" "$sid"
}

# Append one stored chunk. vector_dims=0 stores it the way an outage does,
# with no embedding at all.
_seed_chunk() {
	local file="$1" idx="$2" body="$3" vector_dims="${4:-0}" model="${5:-}"
	mkdir -p "$(dirname "$file")"
	jq -cn --arg id "chunk-${idx}" --argjson i "$idx" --arg b "$body" \
		--argjson d "$vector_dims" --arg m "$model" '
		{ chunk_id: $id, session_id: "sess-a", chunk_index: $i,
		  body_redacted: $b, body_chars: ($b | length),
		  created_at: "2026-10-23T00:00:00Z", source: "local", redaction_count: 0 }
		+ (if $d > 0 then { embedding: [range($d) | 0.5] } else {} end)
		+ (if $m == "" then {} else { embedding_model: $m } end)' >> "$file"
}

_backfill() {
	(cd "$PROJECT_REPO" && bash "$BACKFILL" "$@")
}

_embed_calls() {
	grep -c embed "$CURL_LOG" || true
}

@test "embeds every stored chunk that has no vector, in place" {
	local f
	f=$(_session_file)
	_seed_chunk "$f" 0 "first chunk without a vector"
	_seed_chunk "$f" 1 "second chunk without a vector"

	run _backfill
	[ "$status" -eq 0 ] || return 1

	[ "$(jq -s 'map(select(.embedding | length == 768)) | length' "$f")" -eq 2 ] || return 1
	[ "$(jq -sc 'map(.chunk_id)' "$f")" = '["chunk-0","chunk-1"]' ] || return 1
	[ "$(jq -s 'map(select(.embedding_model == "nomic-embed-text")) | length' "$f")" -eq 2 ]
}

@test "reads the shipped defaults when nothing exports CLAUDE_PLUGIN_ROOT" {
	# Run by path, the script is the only thing that knows where the plugin
	# is. With no project override to mask it, a lost plugin root reads the
	# backend as unset and refuses as if ollama were off.
	local f
	f=$(_session_file)
	_seed_chunk "$f" 0 "needs a vector"
	echo '{}' > "${PROJECT_REPO}/.claude/settings.json"

	run env -u CLAUDE_PLUGIN_ROOT bash -c 'cd "$1" && bash "$2"' _ "$PROJECT_REPO" "$BACKFILL"
	[ "$status" -eq 0 ] || return 1
	[ "$(jq -s 'map(select(.embedding_model == "nomic-embed-text")) | length' "$f")" -eq 1 ]
}

@test "leaves a chunk that already has a vector exactly as it was" {
	local f before
	f=$(_session_file)
	_seed_chunk "$f" 0 "already embedded" 768
	_seed_chunk "$f" 1 "needs a vector"
	before=$(head -1 "$f")

	run _backfill
	[ "$status" -eq 0 ] || return 1
	[ "$(head -1 "$f")" = "$before" ] || return 1
	[ "$(_embed_calls)" -eq 2 ]   # one probe, one chunk
}

@test "skips a chunk with an empty body rather than embedding nothing" {
	local f
	f=$(_session_file)
	_seed_chunk "$f" 0 ""

	run _backfill
	[ "$status" -eq 0 ] || return 1
	[ "$(jq -s 'map(select(has("embedding"))) | length' "$f")" -eq 0 ]
}

@test "--dry-run counts what it would embed and changes nothing" {
	local f g before
	f=$(_session_file)
	g=$(_session_file "$PROJECT_KEY" "sess-b")
	_seed_chunk "$f" 0 "one"
	_seed_chunk "$f" 1 "two"
	_seed_chunk "$g" 0 "three"
	before=$(cat "$f" "$g")

	run _backfill --dry-run
	[ "$status" -eq 0 ] || return 1
	# Two sessions in one project is one project, not two.
	[[ "$output" == *"3 chunks across 2 sessions in 1 project."* ]] || return 1
	[ "$(cat "$f" "$g")" = "$before" ] || return 1
	[ "$(_embed_calls)" -eq 0 ]
}

@test "refuses to start when the embedder is unreachable, and says so" {
	local f before
	f=$(_session_file)
	_seed_chunk "$f" 0 "needs a vector"
	before=$(cat "$f")
	_install_curl_stub 0

	run _backfill
	[ "$status" -ne 0 ] || return 1
	[ "$(cat "$f")" = "$before" ] || return 1
	grep -q '"event_type":"historian.embedder.unavailable"' "$ONLOOKER_EVENTS_LOG"
}

@test "stops after repeated embed failures instead of burning through the store" {
	local f before i
	f=$(_session_file)
	for i in 0 1 2 3 4 5 6 7 8 9; do _seed_chunk "$f" "$i" "chunk number $i"; done
	before=$(cat "$f")
	# The probe passes but every embed times out: a daemon that is up with its
	# model cold, or one that stopped mid-run.
	_install_curl_stub 1 28

	run _backfill
	[ "$status" -ne 0 ] || return 1
	[ "$(cat "$f")" = "$before" ] || return 1
	[ "$(_embed_calls)" -lt 10 ] || return 1
	grep '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.reason == "timeout"' >/dev/null
}

@test "keeps what it embedded when the embedder goes away partway through" {
	local f i
	f=$(_session_file)
	for i in 0 1 2 3 4 5 6 7 8 9; do _seed_chunk "$f" "$i" "chunk number $i"; done
	# The probe and the first two chunks embed, then every call times out.
	_install_curl_stub 1 28 768 3

	run _backfill
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"in a row"* ]] || return 1
	[ "$(jq -s 'map(select(has("embedding"))) | length' "$f")" -eq 2 ] || return 1
	[ "$(jq -s 'length' "$f")" -eq 10 ] || return 1
	# Two good calls and the probe, then five failures, then it stops.
	[ "$(_embed_calls)" -eq 8 ]
}

@test "skips a session another indexer holds the lock on" {
	local f before lockdir holder
	f=$(_session_file)
	_seed_chunk "$f" 0 "needs a vector"
	before=$(cat "$f")

	# The same lock run-index.sh takes for this session, held by a live pid.
	lockdir="${ONLOOKER_DIR}/historian/sessions/sess-a.index.lock.d"
	mkdir -p "$lockdir"
	sleep 30 &
	holder=$!
	printf '%s\n' "$holder" > "${lockdir}/holder"

	run _backfill
	kill "$holder" 2>/dev/null || true
	[ "$status" -eq 0 ] || return 1
	[ "$(cat "$f")" = "$before" ] || return 1
	[[ "$output" == *"locked"* ]]
}

@test "refuses when stored vectors are a different size than the model returns" {
	# A model change with no label to show it: mixing the two would quietly
	# break similarity for every stored chunk.
	local f before
	f=$(_session_file)
	_seed_chunk "$f" 0 "embedded by some other model" 384
	_seed_chunk "$f" 1 "needs a vector"
	before=$(cat "$f")

	run _backfill
	[ "$status" -ne 0 ] || return 1
	[ "$(cat "$f")" = "$before" ] || return 1
	[[ "$output" == *"384"* && "$output" == *"768"* ]]
}

@test "refuses when stored vectors are labeled with a different model" {
	local f before
	f=$(_session_file)
	_seed_chunk "$f" 0 "embedded by mxbai" 768 "mxbai-embed-large"
	_seed_chunk "$f" 1 "needs a vector"
	before=$(cat "$f")

	run _backfill
	[ "$status" -ne 0 ] || return 1
	[ "$(cat "$f")" = "$before" ] || return 1
	[[ "$output" == *"mxbai-embed-large"* ]]
}

@test "walks every project by default, and only one with --project" {
	local other="0123456789ab" f1 f2
	f1=$(_session_file "$PROJECT_KEY")
	f2=$(_session_file "$other")
	_seed_chunk "$f1" 0 "this project"
	_seed_chunk "$f2" 0 "another project"

	run _backfill --project "$other"
	[ "$status" -eq 0 ] || return 1
	[ "$(jq -s 'map(select(has("embedding"))) | length' "$f1")" -eq 0 ] || return 1
	[ "$(jq -s 'map(select(has("embedding"))) | length' "$f2")" -eq 1 ] || return 1

	run _backfill
	[ "$status" -eq 0 ] || return 1
	[ "$(jq -s 'map(select(has("embedding"))) | length' "$f1")" -eq 1 ]
}

@test "run-index labels new vectors with the model that made them" {
	# So the next backfill, or a model change, has something better than
	# vector length to go on.
	local transcript="${BATS_TEST_TMPDIR}/transcript.jsonl" text
	: > "$transcript"
	for text in \
		"Investigating a flaky test in the auth middleware path, which keeps failing on retry three of the CI job." \
		"The root cause is a race between session token cache invalidation and the redirect retry loop in the middleware."; do
		jq -cn --arg t "$text" '{type:"user", message:{content:[{type:"text", text:$t}]}}' >> "$transcript"
	done

	HISTORIAN_SESSION_ID="sess-label" HISTORIAN_CWD="$PROJECT_REPO" \
		HISTORIAN_TRANSCRIPT="$transcript" run bash "${PLUGIN_ROOT}/scripts/run-index.sh"
	[ "$status" -eq 0 ] || return 1
	local f
	f=$(_session_file "$PROJECT_KEY" "sess-label")
	[ -s "$f" ] || return 1
	[ "$(jq -s 'map(select(.embedding_model != "nomic-embed-text")) | length' "$f")" -eq 0 ]
}
