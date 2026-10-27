#!/usr/bin/env bash
# Similarity-search retriever for Historian.
#
# Given a query embedding and a project key, walks every JSONL chunk
# record under ~/.onlooker/historian/<key>/sessions/, computes cosine
# similarity between the query vector and each chunk's `embedding`
# field, and returns the top-K candidates above a similarity floor.
#
# A chunk has no `embedding` when its embed failed at indexing time: a
# cold or unreachable ollama, a timeout, an oversized input. Nothing
# re-embeds it on a later SessionEnd pass (`/historian backfill` does, but
# only when someone runs it), so skipping it would make it invisible for
# good. Instead such a chunk is scored by term overlap with the prompt
# text (ONL-124): the fraction of the prompt's distinct terms that appear
# in its body. Those matches carry `match: "lexical"` and rank strictly
# below every vector match, so the fallback fills empty slots and can
# never displace a real similarity hit. Their score is not a cosine and
# is not compared against min_similarity.
#
# When the query itself has no vector (the embedder was down, or the embed
# call failed), every chunk is scored that way, embedded or not (ONL-213).
# Restricting it to unembedded chunks would find almost nothing once a
# backfill has run. The cost is the same as a vector pass: reading the store
# dominates both, about 2.5s for 12.7k chunks / 219MB, and the overlap
# scoring adds about 0.06s of that.

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
#                                   [<query_text>] [<lexical_min_overlap>]
#
# Without query_text, unembedded chunks are skipped as before. An empty
# query embedding ("[]") with query_text searches by term overlap alone.
#
# Output: JSON array, vector matches first by similarity descending, then
# lexical matches by overlap descending, length <= top_k.
# Each entry: {
#   chunk_id, session_id, similarity, age_days, body_redacted,
#   chunk_index, start_turn_index, end_turn_index, source, match
# }
historian_retriever_search() {
	local sessions_dir="${1:-}"
	local query="${2:-[]}"
	local top_k="${3:-5}"
	local min_sim="${4:-0.55}"
	local max_age_days="${5:-180}"
	local current_session="${6:-}"
	local query_text="${7:-}"
	local lexical_min="${8:-0.5}"

	if [[ -z "$sessions_dir" || ! -d "$sessions_dir" ]]; then
		echo '[]'
		return 0
	fi

	python3 - "$sessions_dir" "$top_k" "$min_sim" "$max_age_days" "$current_session" "$query" \
		"$query_text" "$lexical_min" <<'PY'
import datetime, json, math, os, re, sys

sessions_dir = sys.argv[1]
top_k = int(sys.argv[2])
min_sim = float(sys.argv[3])
max_age_days = int(sys.argv[4])
current_session = sys.argv[5]
query = json.loads(sys.argv[6] or "null")
query_text = sys.argv[7]
try:
    lexical_min = float(sys.argv[8])
except ValueError:
    lexical_min = 0.5

# Words too common to say anything about what a prompt is about. Without
# them, any two English paragraphs would clear the overlap floor.
STOPWORDS = frozenset(
    """
    about above after again against all also and any are because been before
    being below between both but can could did does doing down during each
    few for from further had has have having her here hers him his how into
    its itself just let more most much must not now off once only other our
    ours out over own same she should some such than that the their theirs
    them then there these they this those through too under until upon very
    was were what when where which while who whom why will with would you
    your yours yourself
    """.split()
)


def terms(text):
    return {
        t
        for t in re.findall(r"[a-z0-9][a-z0-9_]*", (text or "").lower())
        if len(t) >= 3 and t not in STOPWORDS
    }


query_terms = terms(query_text)


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


query_vector = query if isinstance(query, list) and query else None
if query_vector is None and not query_terms:
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
    if query_vector is not None and isinstance(embedding, list) and embedding:
        match = "vector"
        sim = cosine(query_vector, embedding)
        if sim is None or sim < min_sim:
            return
    else:
        # Two shared terms at minimum, so a one-word prompt cannot match on
        # a single coincidence.
        if not query_terms:
            return
        shared = len(query_terms & terms(chunk.get("body_redacted", "")))
        if shared < 2:
            return
        sim = shared / len(query_terms)
        if sim < lexical_min:
            return
        match = "lexical"
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
            "match": match,
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

# Every vector match ahead of every lexical one, whatever their scores: an
# overlap fraction and a cosine are not on the same scale.
scored.sort(key=lambda c: (c["match"] != "vector", -c["similarity"]))
print(json.dumps(scored[:top_k]))
PY
}
