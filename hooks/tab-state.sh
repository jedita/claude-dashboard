#!/usr/bin/env bash
# tab-state.sh — Claude Code hook script for session state management
# Writes per-session state files to ~/.claude/tab-state/<session_id>.json
# and updates terminal tab titles via OSC 0 escape sequences.
#
# Usage: echo '<json>' | bash tab-state.sh <event>
# Events: init, working, stop, error, attention, cleanup

set -euo pipefail

EVENT="${1:-}"
STATE_DIR="$HOME/.claude/tab-state"
DASHBOARD_DIR="$HOME/.claude/dashboard"
SERVER_SCRIPT="$DASHBOARD_DIR/server.js"
SERVER_PID_FILE="$DASHBOARD_DIR/server.pid"
SERVER_LOG="$DASHBOARD_DIR/server.log"
HEALTH_URL="http://127.0.0.1:3847/api/health"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Check for jq
if ! command -v jq &>/dev/null; then
  echo "tab-state.sh: jq is required but not installed" >&2
  exit 1
fi

# Read stdin into variable
INPUT="$(cat)"

# Validate JSON
if ! echo "$INPUT" | jq empty 2>/dev/null; then
  echo "tab-state.sh: invalid JSON on stdin" >&2
  exit 1
fi

# Parse session_id (required for all events)
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty')"
if [ -z "$SESSION_ID" ]; then
  echo "tab-state.sh: missing session_id in input" >&2
  exit 1
fi

# Sanitize session_id for filename safety (allow alphanumeric, dash, underscore)
SAFE_ID="$(echo "$SESSION_ID" | sed 's/[^a-zA-Z0-9_-]/_/g')"
STATE_FILE="$STATE_DIR/${SAFE_ID}.json"
TMP_FILE="$STATE_DIR/.${SAFE_ID}.json.tmp"

# Generate ISO 8601 timestamp
now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Emit OSC 0 escape sequence for terminal tab title
set_tab_title() {
  local title="$1"
  printf '\033]0;%s\033\\' "$title"
}

# Atomic write: write to tmp then mv
atomic_write() {
  local content="$1"
  echo "$content" > "$TMP_FILE"
  mv "$TMP_FILE" "$STATE_FILE"
}

# Strip markdown formatting from text
strip_markdown() {
  local text="$1"
  # Use printf to interpret escape sequences (JSON \n becomes real newlines)
  printf '%s' "$text" | sed \
    -e '/^```/,/^```/d' \
    -e 's/`[^`]*`//g' \
    -e 's/^#\{1,6\} //g' \
    -e 's/\*\*\([^*]*\)\*\*/\1/g' \
    -e 's/\*\([^*]*\)\*/\1/g' \
    -e 's/__\([^_]*\)__/\1/g' \
    -e 's/_\([^_]*\)_/\1/g' \
    -e 's/\[\([^]]*\)\]([^)]*)/ \1/g' \
    -e 's/!\[\([^]]*\)\]([^)]*)/ \1/g' \
    -e 's/^> //g' \
    -e 's/^- //g' \
    -e '/^$/d' | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ //' | head -c 80
}

# Get session name from existing state file
get_session_name() {
  if [ -f "$STATE_FILE" ]; then
    jq -r '.name // empty' "$STATE_FILE" 2>/dev/null
  fi
}

# Auto-launch the dashboard server if not running (only called on init)
auto_launch_server() {
  # Quick check: is server already responding?
  if curl -s --max-time 1 "$HEALTH_URL" >/dev/null 2>&1; then
    return 0
  fi

  # Check PID file — if a live process exists, server may still be starting
  if [ -f "$SERVER_PID_FILE" ]; then
    local existing_pid
    existing_pid="$(cat "$SERVER_PID_FILE" 2>/dev/null)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      return 0
    fi
    # PID file points to dead process — remove it
    rm -f "$SERVER_PID_FILE"
  fi

  # Ensure server script exists
  if [ ! -f "$SERVER_SCRIPT" ]; then
    echo "tab-state.sh: server script not found at $SERVER_SCRIPT" >&2
    return 1
  fi

  # Ensure dashboard directory exists
  mkdir -p "$DASHBOARD_DIR"

  # Start server in background
  nohup node "$SERVER_SCRIPT" >> "$SERVER_LOG" 2>&1 &
}

case "$EVENT" in
  init)
    # Parse fields from stdin
    CWD="$(echo "$INPUT" | jq -r '.cwd // empty')"
    if [ -z "$CWD" ]; then
      CWD="${PWD}"
    fi

    # Session name: env var or fallback
    if [ -n "${CLAUDE_SESSION_NAME:-}" ]; then
      SESSION_NAME="$CLAUDE_SESSION_NAME"
    else
      DIR_NAME="$(basename "$CWD")"
      SHORT_ID="${SESSION_ID:0:4}"
      SESSION_NAME="${DIR_NAME}-${SHORT_ID}"
    fi

    NOW="$(now_iso)"
    PID="${PPID:-0}"

    STATE=$(jq -n \
      --arg sid "$SESSION_ID" \
      --arg name "$SESSION_NAME" \
      --arg status "starting" \
      --arg cwd "$CWD" \
      --argjson pid "$PID" \
      --arg last_activity "$NOW" \
      --arg created_at "$NOW" \
      '{
        version: 1,
        session_id: $sid,
        name: $name,
        status: $status,
        cwd: $cwd,
        pid: $pid,
        last_activity: $last_activity,
        last_message_preview: "",
        created_at: $created_at
      }')

    atomic_write "$STATE"
    set_tab_title "🔄 $SESSION_NAME"

    # Auto-launch server if not running (A1.7, A1.8)
    auto_launch_server
    ;;

  working)
    # Read existing state, update status and last_activity
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    SESSION_NAME="$(get_session_name)"
    NOW="$(now_iso)"

    STATE=$(jq \
      --arg status "working" \
      --arg last_activity "$NOW" \
      '.status = $status | .last_activity = $last_activity' \
      "$STATE_FILE")

    atomic_write "$STATE"
    set_tab_title "🟢 $SESSION_NAME"
    ;;

  stop)
    # Parse last_assistant_message, update status
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    SESSION_NAME="$(get_session_name)"
    NOW="$(now_iso)"
    RAW_MESSAGE="$(echo "$INPUT" | jq -r '.last_assistant_message // empty')"
    PREVIEW="$(strip_markdown "$RAW_MESSAGE")"

    STATE=$(jq \
      --arg status "done" \
      --arg last_activity "$NOW" \
      --arg preview "$PREVIEW" \
      '.status = $status | .last_activity = $last_activity | .last_message_preview = $preview' \
      "$STATE_FILE")

    atomic_write "$STATE"
    set_tab_title "✅ $SESSION_NAME"
    ;;

  error)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    SESSION_NAME="$(get_session_name)"
    NOW="$(now_iso)"

    STATE=$(jq \
      --arg status "error" \
      --arg last_activity "$NOW" \
      '.status = $status | .last_activity = $last_activity' \
      "$STATE_FILE")

    atomic_write "$STATE"
    set_tab_title "❌ $SESSION_NAME"
    ;;

  attention)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    SESSION_NAME="$(get_session_name)"
    NOW="$(now_iso)"

    STATE=$(jq \
      --arg status "attention" \
      --arg last_activity "$NOW" \
      '.status = $status | .last_activity = $last_activity' \
      "$STATE_FILE")

    atomic_write "$STATE"
    set_tab_title "⚠️ $SESSION_NAME"
    ;;

  cleanup)
    # Remove state file
    rm -f "$STATE_FILE"
    ;;

  *)
    echo "tab-state.sh: unknown event '$EVENT'" >&2
    exit 1
    ;;
esac
