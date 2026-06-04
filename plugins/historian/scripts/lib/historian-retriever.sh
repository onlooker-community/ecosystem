#!/usr/bin/env bash
# Similarity-search retriever for Historian.
#
# Given a query embedding and a project key, walks every JSONL chunk
# record under ~/.onlooker/historian/<key>/sessions/, computes cosine
# similarity between the query vector and each chunk's `embedding`
# field, and returns the top-K candidates above a similarity floor.
#
# Chunks indexed before the embedder shipped don't have an `embedding`
# field; the retriever silently skips them rather than treating them as
# zero-similarity. They'll join the index after the next SessionEnd
# indexing pass.

# Aggregate every chunk record for the project. Returns a JSON array.
historian_retriever_load_all_chunks() {
	local key="$1"
	[[ -z "$key" ]] && { echo '[]'; return 0; }

	local dir
	dir=$(historian_sessions_dir "$key")
	[[ -d "$dir" ]] || { echo '[]'; return 0; }

	# Walk every *.jsonl, emit one JSON array. Use python3 to avoid the
	# `jq -s` quirks around very large inputs and to control the chunk
	# shape (drop the embedding from filtering candidates but keep it
	# for the math).
	python3 - "$dir" <<'PY'
import json, os, sys
dir_path = sys.argv[1]
out = []
try:
    for name in sorted(os.listdir(dir_path)):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(dir_path, name)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    out.append(rec)
        except OSError:
            continue
except FileNotFoundError:
    pass
print(json.dumps(out))
PY
}

# Compute top-K cosine-similarity matches against the query embedding.
#
# The chunks are streamed from disk one line at a time so memory and
# argv stay bounded as the per-project store grows. Earlier versions
# passed the full chunks array as an argv string, which would trip the
# OS ARG_MAX limit somewhere around tens of thousands of chunks; this
# form never holds more than one chunk in memory at a time.
#
# Usage: historian_retriever_search <sessions_dir>
#                                   <query_embedding_json>
#                                   <top_k> <min_similarity>
#                                   <max_age_days> <current_session_id>
#
# Output: JSON array sorted by similarity descending, length <= top_k.
# Each entry: {
#   chunk_id, session_id, similarity, age_days, body_redacted,
#   chunk_index, start_turn_index, end_turn_index, source
# }
historian_retriever_search() {
	local sessions_dir="${1:-}"
	local query="${2:-[]}"
	local top_k="${3:-5}"
	local min_sim="${4:-0.55}"
	local max_age_days="${5:-180}"
	local current_session="${6:-}"

	if [[ -z "$sessions_dir" || ! -d "$sessions_dir" ]]; then
		echo '[]'
		return 0
	fi

	python3 - "$sessions_dir" "$top_k" "$min_sim" "$max_age_days" "$current_session" "$query" <<'PY'
import datetime, json, math, os, sys

sessions_dir = sys.argv[1]
top_k = int(sys.argv[2])
min_sim = float(sys.argv[3])
max_age_days = int(sys.argv[4])
current_session = sys.argv[5]
query = json.loads(sys.argv[6] or "null")


def cosine(a, b):
    if not a or not b or len(a) != len(b):
        return None
    dot = 0.0
    na = 0.0
    nb = 0.0
    for x, y in zip(a, b):
        dot += x * y
        na += x * x
        nb += y * y
    if na <= 0.0 or nb <= 0.0:
        return None
    return dot / (math.sqrt(na) * math.sqrt(nb))


def parse_iso(s):
    if not s:
        return None
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except ValueError:
        return None


if not isinstance(query, list) or not query:
    print("[]")
    sys.exit(0)

now = datetime.datetime.now(datetime.timezone.utc)
scored = []


def consider(chunk):
    sid = chunk.get("session_id", "")
    # Exclude chunks from the session that is currently asking for
    # context; a session retrieving its own chunks is a degenerate case.
    if current_session and sid == current_session:
        return
    embedding = chunk.get("embedding")
    if not isinstance(embedding, list) or not embedding:
        return
    sim = cosine(query, embedding)
    if sim is None or sim < min_sim:
        return
    created = parse_iso(chunk.get("created_at"))
    if created is None:
        age_days = -1
    else:
        age_days = (now - created).days
        if max_age_days > 0 and age_days > max_age_days:
            return
    scored.append(
        {
            "chunk_id": chunk.get("chunk_id"),
            "session_id": sid,
            "similarity": round(sim, 4),
            "age_days": age_days,
            "body_redacted": chunk.get("body_redacted", ""),
            "chunk_index": chunk.get("chunk_index"),
            "start_turn_index": chunk.get("start_turn_index"),
            "end_turn_index": chunk.get("end_turn_index"),
            "source": chunk.get("source", "local"),
        }
    )


try:
    names = sorted(os.listdir(sessions_dir))
except OSError:
    names = []

for name in names:
    if not name.endswith(".jsonl"):
        continue
    path = os.path.join(sessions_dir, name)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue
                consider(chunk)
    except OSError:
        continue

scored.sort(key=lambda c: c["similarity"], reverse=True)
print(json.dumps(scored[:top_k]))
PY
}
