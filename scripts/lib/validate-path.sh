#!/usr/bin/env bash
# Shared path validation utilities for Onlooker scripts
#
# Source this file to get consistent path handling and error reporting.
# source "$CLAUDE_PLUGIN_ROOT/scripts/lib/validate-path.sh"
#
# All validation functions return 0 (success) or 1 (failure), never exit.
# All ensure functions create resources if needed and return 0 (success) or 1 (failure).

# ==============================================================================
# Path Constants (exported for use by scripts that source this file)
# ==============================================================================

export CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
export ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}"
export ONLOOKER_SESSION_TRACKERS_DIR="$ONLOOKER_DIR/session-trackers"
export ONLOOKER_SESSION_HISTORY_DIR="$ONLOOKER_DIR/session-history"
export ONLOOKER_SESSION_SUMMARIES_DIR="$ONLOOKER_DIR/session-summaries"
export ONLOOKER_COMPACT_TRACKERS_DIR="$ONLOOKER_DIR/compact-trackers"
export ONLOOKER_METRICS_DIR="$ONLOOKER_DIR/metrics"
export ONLOOKER_EVENTS_LOG="$ONLOOKER_DIR/logs/onlooker-events.jsonl"
export ONLOOKER_HOOK_HEALTH_LOG="$ONLOOKER_DIR/logs/hook-health.jsonl"
_VALIDATE_PATH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ONLOOKER_EMIT="$_VALIDATE_PATH_DIR/onlooker-emit.sh"
unset _VALIDATE_PATH_DIR

# ==============================================================================
# Plugin Identity
# Derive the calling plugin's name from its config.json .plugin_name field.
# Exported as ONLOOKER_PLUGIN_NAME so onlooker-emit.sh can stamp every event.
# If the sourcing plugin has no config.json or no plugin_name key, falls back
# to the directory name of CLAUDE_PLUGIN_ROOT.
# ==============================================================================
if [[ -z "${ONLOOKER_PLUGIN_NAME:-}" ]]; then
  _config_file="${CLAUDE_PLUGIN_ROOT:-}/config.json"
  if [[ -f "$_config_file" ]]; then
    ONLOOKER_PLUGIN_NAME=$(jq -r '.plugin_name // empty' "$_config_file" 2>/dev/null) || ONLOOKER_PLUGIN_NAME=""
  fi
  if [[ -z "${ONLOOKER_PLUGIN_NAME:-}" ]]; then
    ONLOOKER_PLUGIN_NAME=$(basename "${CLAUDE_PLUGIN_ROOT:-unknown}")
  fi
  unset _config_file
fi
export ONLOOKER_PLUGIN_NAME

# ==============================================================================
# Hook Health Monitoring
# Track hook success/failure rates to identify flaky hooks.
# ==============================================================================

# These functions provide observability into hook execution health.
# Usage:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/validate-path.sh"
#   hook_register "my-hook" "My Hook" "My hook description" # Call at start of hook
#   # ... hook logic ...
#   hook_success    # Call on successful completion (or let trap handle failure)

# Current hook content (set by hook_register)
_HOOK_NAME=""
_HOOK_START_TIME=""

# Extended content (set by hook_set_context)
_HOOK_SESSION_ID=""
_HOOK_EVENT=""
_HOOK_TOOL_NAME=""

# Detect hook event from script path
# Looks for known event directory names in the call stack
_detect_hook_event() {
  local script_path="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-}}"

  # Known Claude Code hook events
  local events="PreToolUse|PostToolUse|PostToolUseFailure|PermissionRequest|PermissionDenied|SessionStart|SessionEnd|Notification|SubagentStart|PreCompact|PostCompact|SubagentStop|ConfigChange|CwdChanged|FileChanged|StopFailure|InstructionsLoaded|Elicitation|ElicitationResult|UserPromptSubmit|Stop|TeammateIdle|TaskCreated|TaskCompleted|WorktreeCreate|WorktreeRemove"

  if [[ "$script_path" =~ /($events)/ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Set extended context from hook input JSON
# Call this after reading stdin to capture session/tool context
# Usage: hook_set_context "$INPUT"
#    OR: hook_set_context "$INPUT" "PostToolUse"  # explicit event override
hook_set_context() {
  local input="${1:-}"
  local event_override="${2:-}"

  [[ -z "$input" ]] && return 0

  # Extract context from JSON input
  _HOOK_SESSION_ID=$(echo "$input" | jq -r '.session_id // ""' 2>/dev/null) || _HOOK_SESSION_ID=""
  _HOOK_TOOL_NAME=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null) || _HOOK_TOOL_NAME=""

  # Use explicit event or auto-detect from script path
  if [[ -n "$event_override" ]]; then
    _HOOK_EVENT="$event_override"
  else
    _HOOK_EVENT=$(_detect_hook_event)
  fi

  # Export for onlooker-emit.sh envelope enrichment
  export ONLOOKER_HOOK_TYPE="${_HOOK_EVENT}"
  export ONLOOKER_TOOL_NAME="${_HOOK_TOOL_NAME}"
}


# Register hook execution start
# Usage: hook_register "hook-name"
hook_register() {
  _HOOK_NAME="${1:-unknown}"
  # Get time in milliseconds (macOS compatible)
  if [[ "$(uname)" == "Darwin" ]]; then
    _HOOK_START_TIME=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s)
  else
    _HOOK_START_TIME=$(date +%s%3N 2>/dev/null || date +%s)
  fi

  # Set up trap to catch failures
  trap '_hook_on_exit $?' EXIT
}

# Log hook success (call explicitly or let trap determine)
hook_success() {
  _hook_log "success" ""
  trap - EXIT  # Clear trap since we're handling it
}

# Log hook failure with optional error message
# Usage: hook_failure "error message"
hook_failure() {
  local error_msg="${1:-}"
  _hook_log "failure" "$error_msg"
  trap - EXIT
}

# Internal: called by EXIT trap
_hook_on_exit() {
  local exit_code="$1"
  if [[ $exit_code -eq 0 ]]; then
    _hook_log "success" ""
  else
    _hook_log "failure" "exit_code=$exit_code"
  fi
  trap - EXIT
}

# Internal: write to health log
_hook_log() {
  local hook_status="$1"
  local error_msg="$2"

  [[ -z "$_HOOK_NAME" ]] && return 0

  local end_time duration_ms timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Get end time in milliseconds (macOS compatible)
  if [[ "$(uname)" == "Darwin" ]]; then
    end_time=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s)
  else
    end_time=$(date +%s%3N 2>/dev/null || date +%s)
  fi

  # Calculate duration (handle both ms and s timestamps)
  if [[ ${#_HOOK_START_TIME} -gt 10 && ${#end_time} -gt 10 ]]; then
    duration_ms=$((end_time - _HOOK_START_TIME))
  else
    # Fallback to seconds-based calculation
    duration_ms=0
  fi

  ensure_file_exists "$ONLOOKER_HOOK_HEALTH_LOG" || return 0

  jq -cn \
    --arg ts "$timestamp" \
    --arg hook "$_HOOK_NAME" \
    --arg hook_status "$hook_status" \
    --arg error "$error_msg" \
    --argjson duration "$duration_ms" \
    --arg session_id "$_HOOK_SESSION_ID" \
    --arg hook_event "$_HOOK_EVENT" \
    --arg tool_name "$_HOOK_TOOL_NAME" \
    '{
      timestamp: $ts,
      hook: $hook,
      status: $hook_status,
      duration_ms: $duration,
      error: (if $error == "" then null else $error end),
      session_id: (if $session_id == "" then null else $session_id end),
      hook_event: (if $hook_event == "" then null else $hook_event end),
      tool_name: (if $tool_name == "" then null else $tool_name end)
    }' \
    >> "$ONLOOKER_HOOK_HEALTH_LOG" 2>/dev/null

  # Reset context
  _HOOK_NAME=""
  _HOOK_START_TIME=""
  _HOOK_SESSION_ID=""
  _HOOK_EVENT=""
  _HOOK_TOOL_NAME=""
}

# Get hook health summary for last N hours
# Usage: health=$(hook_health_summary 24)
# Returns JSON with success/failure counts per hook
hook_health_summary() {
  local hours="${1:-24}"
  local cutoff_time

  if ! validate_file_readable "$ONLOOKER_HOOK_HEALTH_LOG"; then
    echo '{}'
    return 0
  fi

  # Calculate cutoff timestamp
  if [[ "$(uname)" == "Darwin" ]]; then
    cutoff_time=$(date -u -v-"${hours}"H +"%Y-%m-%dT%H:%M:%SZ")
  else
    cutoff_time=$(date -u -d "$hours hours ago" +"%Y-%m-%dT%H:%M:%SZ")
  fi

  jq -s --arg cutoff "$cutoff_time" '
    map(select(.timestamp >= $cutoff))
    | group_by(.hook)
    | map({
        hook: .[0].hook,
        total: length,
        success: map(select(.status == "success")) | length,
        failure: map(select(.status == "failure")) | length,
        avg_duration_ms: (map(.duration_ms) | add / length | floor),
        last_error: (map(select(.error != null)) | last | .error // null)
      })
    | sort_by(-.failure)
  ' "$ONLOOKER_HOOK_HEALTH_LOG" 2>/dev/null || echo '[]'
}

# ==============================================================================
# Hook Composition Bus
# ==============================================================================

# Lightweight mechanism for hooks within the same event invocation to share
# structured JSON findings. Each tool call gets a unique bus directory;
# hooks write named JSON files that later hooks can read.
#
# IMPORTANT: Hooks within the same `hooks` array run in PARALLEL.
# For reliable producer->consumer flow, place them in separate matcher entries in
# hooks.json (matcher entries run sequentially).
#
# Usage (producer):
#   hook_bus_init "$INPUT"
#   hook_bus_put "secret-scanner" '{"found": true, "patterns": ["AWS key"]}'
#
# Usage (consumer):
#   hook_bus_init "$INPUT"
#   if hook_bus_has "secret-scanner"; then
#     result=$(hook_bus_get "secret-scanner")
#   fi

# Current bus directory (set by hook_bus_init)
_HOOK_BUS_DIR=""

# Portable short hash (macOS md5 vs Linux md5sum)
_short_hash() {
  local input="$1"
  if command -v md5sum &>/dev/null; then
    printf '%s' "$input" | md5sum 2>/dev/null | cut -c1-8
  elif command -v md5 &>/dev/null; then
    printf '%s' "$input" | md5 2>/dev/null | cut -c1-8
  else
    # Fallback: use cksum (always available)
    printf '%s' "$input" | cksum | cut -d' ' -f1
  fi
}

# Initialize the hook bus for this invocation
# Derives a unique directory from session + tool + input content
# Usage: hook_bus_init "$INPUT"
hook_bus_init() {
  local input_json="${1:-}"

  local session_id="${_HOOK_SESSION_ID:-unknown}"
  local tool_name="${_HOOK_TOOL_NAME:-unknown}"

  # Hash the tool_input portion for uniqueness within session+tool
  local input_hash
  local tool_input
  tool_input=$(printf '%s' "$input_json" | jq -r '.tool_input // ""' 2>/dev/null) || tool_input=""
  input_hash=$(_short_hash "${tool_input}")

  _HOOK_BUS_DIR="/tmp/.onlooker-hook-bus-${session_id}-${tool_name}-${input_hash}"
  ensure_dir_exists "$_HOOK_BUS_DIR" || {
    _HOOK_BUS_DIR=""  # Signal bus unavailable so hook_bus_put noops
    return 1
  }
}

# Write a named finding to the bus
# Usage: hook_bus_put "secret-scanner" '{"found": true}'
hook_bus_put() {
  local name="$1"
  local json_payload="$2"
  [[ -z "$_HOOK_BUS_DIR" || ! -d "$_HOOK_BUS_DIR" ]] && return 1
  printf '%s\n' "$json_payload" > "${_HOOK_BUS_DIR}/${name}.json" 2>/dev/null
}

# Read a named finding from the bus
# Returns JSON payload, or empty string if not found
# Usage: result=$(hook_bus_get "secret-scanner")
hook_bus_get() {
  local name="$1"
  local path="${_HOOK_BUS_DIR}/${name}.json"
  if [[ -f "$path" ]]; then
    cat "$path" 2>/dev/null
  fi
}

# Check if a named finding exists on the bus
# Usage: if hook_bus_has "secret-scanner"; then ...
hook_bus_has() {
  local name="$1"
  [[ -n "$_HOOK_BUS_DIR" && -f "${_HOOK_BUS_DIR}/${name}.json" ]]
}

# List all finding names on the bus
# Returns newline-separated names (without .json extension)
hook_bus_list() {
  [[ -z "$_HOOK_BUS_DIR" || ! -d "$_HOOK_BUS_DIR" ]] && return 0
  local f
  for f in "$_HOOK_BUS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    basename "$f" .json
  done
}

# Clean up expired bus directories (older than 5 minutes)
# Call from SessionEnd or periodically
hook_bus_cleanup() {
  # Resolve /tmp symlink (macOS: /tmp -> /private/tmp) so find works
  local tmp_dir
  tmp_dir="$(cd /tmp && pwd -P)"
  find "$tmp_dir" -maxdepth 1 -name ".onlooker-hook-bus-*" -type d -mmin +5 -exec rm -rf {} + 2>/dev/null || true
}

# ==============================================================================
# Validation Functions (return 0/1, never exit)
# ==============================================================================

# Check if file exists
# Usage: validate_file_exists "/path/to/file" && echo "exists"
validate_file_exists() {
	local path="$1"
	[[ -n "$path" && -f "$path" ]]
}

# Check if file exists and is readable
# Usage: validate_file_readable "/path/to/file" && cat "$file"
validate_file_readable() {
  local path="$1"
  [[ -n "$path" && -f "$path" && -r "$path" ]]
}

# Check if parent directory is writable (for creating/appending to file)
# Usage: validate_file_writable "/path/to/new/file" && echo "data" >> "$file"
validate_file_writable() {
  local path="$1"
  [[ -z "$path" ]] && return 1
  local parent
  parent=$(dirname "$path")
  [[ -d "$parent" && -w "$parent" ]]
}

# Check if directory exists
# Usage: validate_dir_exists "/path/to/dir" && ls "$dir"
validate_dir_exists() {
  local path="$1"
  [[ -n "$path" && -d "$path" ]]
}

# ==============================================================================
# Ensure Functions (create if needed, return 0/1)
# ==============================================================================

# Create directory if it doesn't exist (mkdir -p wrapper)
# Usage: ensure_dir_exists "/path/to/dir" && echo "ready"
ensure_dir_exists() {
  local path="$1"
  [[ -z "$path" ]] && return 1
  [[ -d "$path" ]] && return 0
  mkdir -p "$path" 2>/dev/null
}

# Create file if it doesn't exist (creates parent dirs too)
# Usage: ensure_file_exists "/path/to/file" && echo "data" >> "$file"
ensure_file_exists() {
  local path="$1"
  [[ -z "$path" ]] && return 1
  [[ -f "$path" ]] && return 0
  local parent
  parent=$(dirname "$path")
  ensure_dir_exists "$parent" || return 1
  touch "$path" 2>/dev/null
}

# ==============================================================================
# Convenience Functions (shortcuts for common operations)
# ==============================================================================

# Safely read last N lines from file (returns empty if file missing)
# Usage: recent=$(safe_tail "/path/to/file" 5)
safe_tail() {
  local path="$1"
  local lines="${2:-10}"
  if validate_file_readable "$path"; then
    tail -n "$lines" "$path" 2>/dev/null
  fi
}


# Safely append to file (creates file if needed)
# Usage: echo "data" | safe_append "/path/to/file"
# Or:    safe_append "/path/to/file" "data to append"
safe_append() {
  local path="$1"
  local data="$2"
  ensure_file_exists "$path" || return 1
  if [[ -n "$data" ]]; then
    printf '%s\n' "$data" >> "$path" 2>/dev/null
  else
    cat >> "$path" 2>/dev/null
  fi
}

# ==============================================================================
# Turn State Tracking
# Track turn-level state for each session (lineage, turn number, etc.)
# ==============================================================================

# Read/write turn state from the per-session tracker file. The tracker stores
# JSON with turn_number and turn_tool_seq alongside existing fields (start_time,
# tool_calls, etc.). These values are exported as env vars so onlooker-emit.sh
# can include them in every event envelope.

# Read turn state from session tracker and export as env vars.
# Sets ONLOOKER_TURN_NUMBER and ONLOOKER_TURN_TOOL_SEQ.
# Usage: turn_state_export "$SESSION_ID"
turn_state_export() {
	local session_id="${1:-}"
	 [[ -z "$session_id" || "$session_id" == "null" ]] && return 0

  	local tracker_file="$ONLOOKER_SESSION_TRACKERS_DIR/$session_id"
  	if [[ -f "$tracker_file" ]] && jq -e '.turn_number' "$tracker_file" >/dev/null 2>&1; then
  	  export ONLOOKER_TURN_NUMBER=$(jq -r '.turn_number // 0' "$tracker_file" 2>/dev/null)
  	  export ONLOOKER_TURN_TOOL_SEQ=$(jq -r '.turn_tool_seq // 0' "$tracker_file" 2>/dev/null)
  	else
  	  export ONLOOKER_TURN_NUMBER=""
  	  export ONLOOKER_TURN_TOOL_SEQ=""
	fi
}

# Ensure session tracker exists with turn_number and turn_tool_seq fields.
# Usage: turn_state_ensure_session "$SESSION_ID"
turn_state_ensure_session() {
  local session_id="${1:-}"
  [[ -z "$session_id" || "$session_id" == "null" ]] && return 0

  local tracker_file="$ONLOOKER_SESSION_TRACKERS_DIR/$session_id"
  ensure_dir_exists "$ONLOOKER_SESSION_TRACKERS_DIR" || return 1

  if [[ ! -f "$tracker_file" ]]; then
    echo '{"turn_number":1,"turn_tool_seq":0}' >"$tracker_file"
    return 0
  fi

  if ! jq -e '.turn_number' "$tracker_file" >/dev/null 2>&1; then
    local temp_file
    temp_file=$(mktemp)
    if jq '.turn_number = (.turn_number // 1) | .turn_tool_seq = (.turn_tool_seq // 0)' \
      "$tracker_file" >"$temp_file" 2>/dev/null; then
      mv "$temp_file" "$tracker_file"
    else
      rm -f "$temp_file"
      echo '{"turn_number":1,"turn_tool_seq":0}' >"$tracker_file"
    fi
  fi
}

# Increment turn_number and reset turn_tool_seq in session tracker.
# Usage: turn_state_next_turn "$SESSION_ID"
turn_state_next_turn() {
  local session_id="${1:-}"
  [[ -z "$session_id" || "$session_id" == "null" ]] && return 0

  turn_state_ensure_session "$session_id" || return 1

  local tracker_file="$ONLOOKER_SESSION_TRACKERS_DIR/$session_id"
  [[ ! -f "$tracker_file" ]] && return 0

  local temp_file
  temp_file=$(mktemp)
  if jq '.turn_number = ((.turn_number // 0) + 1) | .turn_tool_seq = 0' \
      "$tracker_file" > "$temp_file" 2>/dev/null; then
    mv "$temp_file" "$tracker_file"
  else
    rm -f "$temp_file"
  fi
}

# Increment turn_tool_seq in session tracker.
# Usage: turn_state_next_tool "$SESSION_ID"
turn_state_next_tool() {
  local session_id="${1:-}"
  [[ -z "$session_id" || "$session_id" == "null" ]] && return 0

  turn_state_ensure_session "$session_id" || return 1

  local tracker_file="$ONLOOKER_SESSION_TRACKERS_DIR/$session_id"
  [[ ! -f "$tracker_file" ]] && return 0

  local temp_file
  temp_file=$(mktemp)
  if jq '.turn_tool_seq = ((.turn_tool_seq // 0) + 1)' \
      "$tracker_file" > "$temp_file" 2>/dev/null; then
    mv "$temp_file" "$tracker_file"
  else
    rm -f "$temp_file"
  fi
}

# Safely emit dev-os event (validates emit script exists)
# Automatically exports turn state if not already set, so every emission
# gets hook_type/turn/tool_call_seq in the envelope without callers needing
# to call turn_state_export() explicitly.
# Usage: echo "$INPUT" | safe_emit "event_type" '{"key":"value"}'
safe_emit() {
  local event_type="$1"
  local payload="$2"

  # Auto-export turn state if not already set
  if [[ -z "${ONLOOKER_TURN_NUMBER:-}" && -n "${_HOOK_SESSION_ID:-}" ]]; then
    turn_state_export "$_HOOK_SESSION_ID"
  fi

  if validate_file_exists "$ONLOOKER_EMIT"; then
    "$ONLOOKER_EMIT" "$event_type" "$payload"
  else
    # Fallback: write directly to events log with envelope enrichment.
    # Uses env vars set by hook_set_context() — NOT stdin (already consumed).
    ensure_file_exists "$ONLOOKER_EVENTS_LOG" || return 1
    local timestamp session_id plugin_name hook_type tool_name turn tool_seq
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    session_id="${_HOOK_SESSION_ID:-}"
    if [[ -z "$session_id" ]]; then
      session_id=$(echo "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null) || session_id="unknown"
    fi
    plugin_name="${ONLOOKER_PLUGIN_NAME:-unknown}"
    hook_type="${ONLOOKER_HOOK_TYPE:-}"
    tool_name="${ONLOOKER_TOOL_NAME:-}"
    turn="${ONLOOKER_TURN_NUMBER:-}"
    tool_seq="${ONLOOKER_TURN_TOOL_SEQ:-}"
    jq -cn \
      --arg ts "$timestamp" \
      --arg sid "$session_id" \
      --arg plugin "$plugin_name" \
      --arg type "$event_type" \
      --arg hook_type "$hook_type" \
      --arg tool_name "$tool_name" \
      --arg turn "$turn" \
      --arg tool_seq "$tool_seq" \
      --argjson payload "$payload" \
      '{timestamp: $ts, session_id: $sid, plugin: $plugin, event_type: $type, payload: $payload}
      + (if $hook_type != "" then {hook_type: $hook_type} else {} end)
      + (if $tool_name != "" then {tool_name: $tool_name} else {} end)
      + (if $turn != "" then {turn: ($turn | tonumber)} else {} end)
      + (if $tool_seq != "" then {tool_call_seq: ($tool_seq | tonumber)} else {} end)
      ' >> "$ONLOOKER_EVENTS_LOG"
  fi
}