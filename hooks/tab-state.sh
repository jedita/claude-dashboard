#!/usr/bin/env bash
# tab-state.sh — Claude Code hook script for session state management
# Updates per-session state files in ~/.claude/tab-state/<session_id>.json
#
# Session discovery (creating tab-state files) is handled by the server
# watching ~/.claude/sessions/. This hook only enriches existing entries.
#
# The init event only launches the server and opens the browser — it does
# NOT require jq, making it robust in minimal shell environments (e.g.
# VS Code terminal profile shortcuts).
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

# --- Handle init early (no jq needed) ---
# Init only launches the server and opens the browser. Session state file
# creation is handled by the server via native session discovery.
if [ "$EVENT" = "init" ]; then
  # Consume stdin (Claude sends JSON but init doesn't need it)
  cat > /dev/null

  # Auto-launch server if not running
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
    local node_bin=""
    local candidate
    candidate="$(command -v node 2>/dev/null || true)"
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
      candidate="$(command -v node 2>/dev/null || true)"
      if [ -n "$candidate" ] && [ "${candidate:0:1}" = "/" ] && [ -x "$candidate" ]; then
        node_bin="$candidate"
      fi
    fi

    if [ -z "$node_bin" ]; then
      echo "tab-state.sh: cannot find node binary" >&2
      return 1
    fi

    # Start server in a NEW SESSION (detached: true calls setsid() on Unix).
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

  auto_launch_server
  open_dashboard_browser
  exit 0
fi

# --- All other events require jq ---
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

# Detect .code-workspace file that contains cwd as a folder root.
# Searches cwd and its parent directory for *.code-workspace files.
detect_workspace_file() {
  local cwd="$1"
  [ -z "$cwd" ] && return 1
  local parent
  parent="$(dirname "$cwd")"
  local dirs=("$cwd")
  [ "$parent" != "$cwd" ] && dirs+=("$parent")

  for dir in "${dirs[@]}"; do
    for ws_file in "$dir"/*.code-workspace; do
      [ -f "$ws_file" ] || continue
      local ws_dir
      ws_dir="$(dirname "$ws_file")"
      # Check if any folder in the workspace resolves to cwd
      local match
      # .code-workspace files use JSONC (trailing commas) — strip before jq
      match=$(sed 's/,[[:space:]]*\]/]/g; s/,[[:space:]]*}/}/g' "$ws_file" | jq -r --arg cwd "$cwd" --arg wsdir "$ws_dir" '
        .folders[]?.path // empty |
        if startswith("/") then . else ($wsdir + "/" + .) end |
        if . == $cwd then "yes" else empty end
      ' 2>/dev/null | head -1)
      if [ "$match" = "yes" ]; then
        echo "$ws_file"
        return 0
      fi
    done
  done
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

# Resolve the claude CLI binary path once, so background subshells can use it.
CLAUDE_BIN=""
_candidate="$(command -v claude 2>/dev/null || true)"
if [ -n "$_candidate" ] && [ "${_candidate:0:1}" = "/" ] && [ -x "$_candidate" ]; then
  CLAUDE_BIN="$_candidate"
fi
if [ -z "$CLAUDE_BIN" ]; then
  for _p in "$HOME/.local/bin/claude" /usr/local/bin/claude /opt/homebrew/bin/claude; do
    if [ -x "$_p" ]; then
      CLAUDE_BIN="$_p"
      break
    fi
  done
fi

# Generate an AI session name from the user's first prompt, then update the
# state file. Intended to be called in a background subshell so it does not
# block the hook's response.
generate_ai_name() {
  local user_prompt="$1"
  local state_file="$2"
  local log_file="$SERVER_LOG"

  log_ai_name() {
    local level="$1"; shift
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [ai-name] [$level] $*" >> "$log_file" 2>/dev/null || true
  }

  if [ -z "$CLAUDE_BIN" ]; then
    log_ai_name "ERROR" "claude CLI not found. Searched: command -v, ~/.local/bin, /usr/local/bin, /opt/homebrew/bin"
    return
  fi

  local title
  local claude_stderr
  claude_stderr=$(mktemp 2>/dev/null || echo "/tmp/claude-ai-name-$$")
  title=$(set +e +o pipefail; CLAUDE_TAB_TITLE_GENERATING=1 ANTHROPIC_API_KEY="" "$CLAUDE_BIN" --tools "" \
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

  # Reject CLI error messages that leaked to stdout
  if echo "$title" | grep -qiE '(API key|Not logged in|Please run|rate limit|error|timed out|ECONNREFUSED)'; then
    log_ai_name "ERROR" "CLI error leaked as title: $title"
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
}

case "$EVENT" in
  working)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    # If workspace_file not yet detected, detect and persist it
    STORED_WS="$(jq -r '.workspace_file // empty' "$STATE_FILE" 2>/dev/null)"
    if [ -z "$STORED_WS" ]; then
      CWD_VAL="$(jq -r '.cwd // empty' "$STATE_FILE" 2>/dev/null)"
      if [ -n "$CWD_VAL" ]; then
        STORED_WS="$(detect_workspace_file "$CWD_VAL")" || STORED_WS=""
        jq --arg ws "$STORED_WS" '.workspace_file = $ws' "$STATE_FILE" > "${STATE_FILE}.ws.tmp" \
          && mv "${STATE_FILE}.ws.tmp" "$STATE_FILE"
      fi
    fi

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

      # Launch AI name generation in background — updates state file when ready (~10s)
      if [ -n "$USER_PROMPT" ]; then
        generate_ai_name "$USER_PROMPT" "$STATE_FILE" &
        disown
      fi
    else
      STATE=$(jq \
        --arg status "working" \
        --arg last_activity "$NOW" \
        '.status = $status | .last_activity = $last_activity' \
        "$STATE_FILE")

      atomic_write "$STATE"
    fi
    ;;

  stop)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

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
    ;;

  error)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    NOW="$(now_iso)"

    STATE=$(jq \
      --arg status "error" \
      --arg last_activity "$NOW" \
      '.status = $status | .last_activity = $last_activity' \
      "$STATE_FILE")

    atomic_write "$STATE"
    ;;

  attention)
    if [ ! -f "$STATE_FILE" ]; then
      echo "tab-state.sh: no state file for session $SESSION_ID" >&2
      exit 1
    fi

    NOW="$(now_iso)"

    STATE=$(jq \
      --arg status "attention" \
      --arg last_activity "$NOW" \
      '.status = $status | .last_activity = $last_activity' \
      "$STATE_FILE")

    atomic_write "$STATE"
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
