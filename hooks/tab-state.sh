#!/usr/bin/env bash
# tab-state.sh — Claude Code hook script for session state management
# Writes per-session state files to ~/.claude/tab-state/<session_id>.json
# and updates terminal tab titles via OSC 0 escape sequences.
#
# Usage: echo '<json>' | bash tab-state.sh <event>
# Events: init, working, stop, error, attention, cleanup

set -euo pipefail

# Guard: prevent recursive invocation from nested `claude -p` calls (e.g. generate_ai_name).
# The child claude process inherits this env var and its hooks exit immediately.
if [ -n "${CLAUDE_TAB_TITLE_GENERATING:-}" ]; then
  exit 0
fi

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

# Discover the TTY by walking up the process tree.
# Hooks run as subprocesses with no controlling terminal, so we walk
# ancestors to find the Claude Code node process that IS attached to
# the user's terminal.
# Returns the TTY path on stdout, or exit 1 if not found.
discover_tty() {
  # Fast path: /dev/tty refers to the controlling terminal and works even
  # when ps -o tty= shows "??" (common with piped stdin in hook subprocesses).
  if [ -w /dev/tty ] && (printf '' > /dev/tty) 2>/dev/null; then
    echo /dev/tty
    return 0
  fi

  # Fallback: walk the process tree looking for an ancestor with a real TTY.
  local pid="${BASHPID:-$$}"
  local i=0
  while [ $i -lt 10 ]; do
    local raw_tty
    raw_tty=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
    if [ -n "$raw_tty" ] && [ "$raw_tty" != "??" ]; then
      local tty_path="/dev/tty${raw_tty}"
      if [ -w "$tty_path" ]; then
        echo "$tty_path"
        return 0
      fi
    fi
    local ppid
    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$ppid" ] || [ "$ppid" = "0" ] && break
    pid="$ppid"
    i=$((i + 1))
  done
  return 1
}

# Write OSC 0 to a specific TTY path, or discover the TTY if not provided.
set_tab_title() {
  local title="$1"
  local tty_path="${2:-}"
  if [ -z "$tty_path" ]; then
    tty_path="$(discover_tty)" || return 1
  fi
  # Re-check writability: the caller may pass an explicit path that has gone stale.
  if [ -n "$tty_path" ] && [ -w "$tty_path" ]; then
    (printf '\033]0;%s\033\\' "$title" > "$tty_path") 2>/dev/null
    return 0
  fi
  return 1
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

# Remove state files whose owning process is no longer running.
# Called during init so stale sessions from crashes or recursive spawns
# don't accumulate on the dashboard.
cleanup_stale_sessions() {
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    local pid
    pid=$(jq -r '.pid // 0' "$f" 2>/dev/null)
    [ "$pid" = "0" ] || [ -z "$pid" ] && { rm -f "$f"; continue; }
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f"
    fi
  done
}

# Get session name from existing state file
get_session_name() {
  if [ -f "$STATE_FILE" ]; then
    jq -r '.name // empty' "$STATE_FILE" 2>/dev/null
  fi
}

# Generate an AI tab title from the user's first prompt, then update the
# state file and terminal title. Intended to be called in a background
# subshell so it does not block the hook's response.
generate_ai_name() {
  local user_prompt="$1"
  local state_file="$2"
  local tty_path="${3:-}"
  local log_file="$SERVER_LOG"

  log_ai_name() {
    local level="$1"; shift
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [ai-name] [$level] $*" >> "$log_file" 2>/dev/null || true
  }

  # Disable errexit for the claude call — the CLI may exit non-zero even on
  # success, and pipefail would propagate that, killing this background subshell.
  local title
  local claude_stderr
  claude_stderr=$(mktemp 2>/dev/null || echo "/tmp/claude-ai-name-$$")
  title=$(set +e +o pipefail; CLAUDE_TAB_TITLE_GENERATING=1 claude --tools "" \
    -p "You are a tab-title generator. Given a user prompt, output ONLY a short tab title (3-5 words, no punctuation, no quotes). Do NOT answer the prompt. Do NOT explain. Output just and ONLY a tab title.

User prompt: $user_prompt" \
    < /dev/null 2>"$claude_stderr" | tr -d '\n' | sed 's/^ *//; s/ *$//' | head -c 50) || true

  if [ -z "$title" ]; then
    local stderr_content=""
    [ -f "$claude_stderr" ] && stderr_content=$(head -c 500 "$claude_stderr" 2>/dev/null)
    rm -f "$claude_stderr"
    log_ai_name "ERROR" "Claude CLI returned empty title. stderr: ${stderr_content:-<none>}"
    return
  fi
  rm -f "$claude_stderr"

  # Validate: reject if it looks like a conversational AI response
  local word_count
  word_count=$(echo "$title" | wc -w | tr -d ' ')
  if [ "$word_count" -gt 7 ]; then
    log_ai_name "WARN" "Rejected title (too many words: $word_count): $title"
    return
  fi

  # Reject common AI response openers (model answered the prompt instead of titling it)
  if echo "$title" | grep -qiE '^(Sure |Let me |Of course|Unfortunately|Certainly|Yes |No |Thank)'; then
    log_ai_name "WARN" "Rejected title (conversational opener): $title"
    return
  fi

  # Update state file with the validated title
  if [ -f "$state_file" ]; then
    local ai_tmp="${state_file}.aititle.tmp"
    if jq --arg name "$title" \
      '.name = $name' \
      "$state_file" > "$ai_tmp" 2>/dev/null && mv "$ai_tmp" "$state_file"; then
      log_ai_name "INFO" "Updated session name to: $title"
    else
      log_ai_name "ERROR" "Failed to update state file: $state_file"
    fi
  else
    log_ai_name "ERROR" "State file missing when trying to write title: $state_file"
  fi

  # Update terminal tab title (uses pre-discovered TTY from main process)
  set_tab_title "🟢 $title" "$tty_path" || true
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

  # Resolve the actual node binary path.
  # command -v may return a shell function name (e.g. nvm lazy-loader) instead
  # of a path, so we check that the result starts with '/'.
  local node_bin=""
  local candidate
  candidate="$(command -v node 2>/dev/null)"
  if [ -n "$candidate" ] && [ "${candidate:0:1}" = "/" ] && [ -x "$candidate" ]; then
    node_bin="$candidate"
  fi

  # Fallback: search well-known paths where node is typically installed
  if [ -z "$node_bin" ]; then
    for p in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
      if [ -x "$p" ]; then
        node_bin="$p"
        break
      fi
    done
  fi

  # Last resort: try loading nvm to put node on PATH
  if [ -z "$node_bin" ]; then
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    candidate="$(command -v node 2>/dev/null)"
    if [ -n "$candidate" ] && [ "${candidate:0:1}" = "/" ] && [ -x "$candidate" ]; then
      node_bin="$candidate"
    fi
  fi

  if [ -z "$node_bin" ]; then
    echo "tab-state.sh: cannot find node binary" >&2
    return 1
  fi

  # Start server in a NEW SESSION (detached: true calls setsid() on Unix).
  # nohup+disown is not enough on macOS — the server stays in the terminal's
  # process group and gets killed when the tab closes. spawn({detached:true})
  # creates an independent session that survives terminal closure.
  "$node_bin" -e "
    const{spawn}=require('child_process'),fs=require('fs'),
    log=fs.openSync('${SERVER_LOG}','a');
    spawn(process.execPath,['${SERVER_SCRIPT}'],
      {detached:true,stdio:['ignore',log,log]}).unref();
  "

  # Wait for server to become ready
  local retries=0
  while [ $retries -lt 6 ]; do
    if curl -s --max-time 1 "$HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    retries=$((retries + 1))
  done
}

# Open the dashboard in the default browser (only once per server lifetime)
open_dashboard_browser() {
  [ -n "${CLAUDE_DASHBOARD_NO_BROWSER:-}" ] && return 0

  local browser_flag="$DASHBOARD_DIR/.browser-opened"
  local server_pid_val=""

  # Read current server PID
  if [ -f "$SERVER_PID_FILE" ]; then
    server_pid_val="$(cat "$SERVER_PID_FILE" 2>/dev/null)"
  fi

  # Check if we already opened the browser for this server instance
  if [ -f "$browser_flag" ]; then
    local stored_pid
    stored_pid="$(cat "$browser_flag" 2>/dev/null)"
    if [ "$stored_pid" = "$server_pid_val" ]; then
      return 0
    fi
  fi

  # Only open if server is actually responding
  if curl -s --max-time 1 "$HEALTH_URL" >/dev/null 2>&1; then
    echo "$server_pid_val" > "$browser_flag"
    open "http://127.0.0.1:3847/"
  fi
}

case "$EVENT" in
  init)
    # Parse fields from stdin
    CWD="$(echo "$INPUT" | jq -r '.cwd // empty')"
    if [ -z "$CWD" ]; then
      CWD="${PWD}"
    fi

    # Session name: env var or fallback to dirname-shortid
    if [ -n "${CLAUDE_SESSION_NAME:-}" ]; then
      SESSION_NAME="$CLAUDE_SESSION_NAME"
    else
      DIR_NAME="$(basename "$CWD")"
      SHORT_ID="${SESSION_ID:0:4}"
      SESSION_NAME="${DIR_NAME}-${SHORT_ID}"
    fi

    NOW="$(now_iso)"
    PID="${PPID:-0}"

    # Discover TTY early (process tree is intact at init) and cache for later events
    CURRENT_TTY="$(discover_tty 2>/dev/null)" || CURRENT_TTY=""

    STATE=$(jq -n \
      --arg sid "$SESSION_ID" \
      --arg name "$SESSION_NAME" \
      --arg status "starting" \
      --arg cwd "$CWD" \
      --argjson pid "$PID" \
      --arg last_activity "$NOW" \
      --arg created_at "$NOW" \
      --arg tty "$CURRENT_TTY" \
      '{
        version: 1,
        session_id: $sid,
        name: $name,
        status: $status,
        cwd: $cwd,
        pid: $pid,
        last_activity: $last_activity,
        last_message_preview: "",
        created_at: $created_at,
        ai_name_generated: false,
        tty_path: $tty
      }')

    atomic_write "$STATE"
    set_tab_title "🔄 $SESSION_NAME" "$CURRENT_TTY" || true

    # Purge stale sessions from dead processes
    cleanup_stale_sessions

    # Auto-launch server if not running
    auto_launch_server

    # Open dashboard in browser (once per server instance)
    open_dashboard_browser
    ;;

  working)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    SESSION_NAME="$(get_session_name)"
    STORED_TTY="$(jq -r '.tty_path // empty' "$STATE_FILE" 2>/dev/null)"
    NOW="$(now_iso)"
    AI_GENERATED="$(jq -r '.ai_name_generated // false' "$STATE_FILE" 2>/dev/null)"

    if [ "$AI_GENERATED" = "false" ]; then
      # First prompt: mark ai_name_generated=true atomically to prevent
      # duplicate generation if messages arrive quickly
      USER_PROMPT="$(echo "$INPUT" | jq -r '.prompt // empty')"

      STATE=$(jq \
        --arg status "working" \
        --arg last_activity "$NOW" \
        '.status = $status | .last_activity = $last_activity | .ai_name_generated = true' \
        "$STATE_FILE")

      atomic_write "$STATE"
      set_tab_title "🟢 $SESSION_NAME" "$STORED_TTY" || true

      # Launch AI title generation in background — updates tab when ready (~10s)
      if [ -n "$USER_PROMPT" ]; then
        generate_ai_name "$USER_PROMPT" "$STATE_FILE" "$STORED_TTY" &
        disown
      fi
    else
      STATE=$(jq \
        --arg status "working" \
        --arg last_activity "$NOW" \
        '.status = $status | .last_activity = $last_activity' \
        "$STATE_FILE")

      atomic_write "$STATE"
      set_tab_title "🟢 $SESSION_NAME" "$STORED_TTY" || true
    fi
    ;;

  stop)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    SESSION_NAME="$(get_session_name)"
    STORED_TTY="$(jq -r '.tty_path // empty' "$STATE_FILE" 2>/dev/null)"
    NOW="$(now_iso)"
    RAW_MESSAGE="$(echo "$INPUT" | jq -r '.last_assistant_message // empty')"
    PREVIEW="$(strip_markdown "$RAW_MESSAGE")"

    STATE=$(jq \
      --arg status "done" \
      --arg last_activity "$NOW" \
      --arg preview "$PREVIEW" \
      '.status = $status | .last_activity = $last_activity | .last_message_preview = $preview | .ai_name_generated = false' \
      "$STATE_FILE")

    atomic_write "$STATE"
    set_tab_title "✅ $SESSION_NAME" "$STORED_TTY" || true
    ;;

  error)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    SESSION_NAME="$(get_session_name)"
    STORED_TTY="$(jq -r '.tty_path // empty' "$STATE_FILE" 2>/dev/null)"
    NOW="$(now_iso)"

    STATE=$(jq \
      --arg status "error" \
      --arg last_activity "$NOW" \
      '.status = $status | .last_activity = $last_activity' \
      "$STATE_FILE")

    atomic_write "$STATE"
    set_tab_title "❌ $SESSION_NAME" "$STORED_TTY" || true
    ;;

  attention)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    SESSION_NAME="$(get_session_name)"
    STORED_TTY="$(jq -r '.tty_path // empty' "$STATE_FILE" 2>/dev/null)"
    NOW="$(now_iso)"

    STATE=$(jq \
      --arg status "attention" \
      --arg last_activity "$NOW" \
      '.status = $status | .last_activity = $last_activity' \
      "$STATE_FILE")

    atomic_write "$STATE"
    set_tab_title "⚠️ $SESSION_NAME" "$STORED_TTY" || true
    ;;

  cleanup)
    # Reset terminal tab title before removing state
    if [ -f "$STATE_FILE" ]; then
      STORED_TTY="$(jq -r '.tty_path // empty' "$STATE_FILE" 2>/dev/null)"
      set_tab_title "" "$STORED_TTY" || true
    fi
    # Remove state file
    rm -f "$STATE_FILE"
    ;;

  *)
    echo "tab-state.sh: unknown event '$EVENT'" >&2
    exit 1
    ;;
esac
