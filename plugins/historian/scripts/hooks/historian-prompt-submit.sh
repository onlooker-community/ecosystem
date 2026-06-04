#!/usr/bin/env bash
# Historian UserPromptSubmit hook — STUB.
#
# The full retrieval pipeline (rate gate → query embedder → ANN lookup →
# additionalContext surfacer) is deferred to a follow-up landing that ships
# the first embedder backend. Today the hook is intentionally a no-op so
# the plugin can be installed and indexing can run without retrieval.
#
# Hook contract:
#   - Always exits 0.
#   - Never produces additionalContext while the retrieval pipeline is
#     unimplemented.

set -uo pipefail
exit 0
