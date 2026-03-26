#!/usr/bin/env bash
set -euo pipefail

# Claude Code Terminal Dashboard — Installer
# Copies hook script, server files, and built dashboard to ~/.claude/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
TAB_STATE_DIR="$CLAUDE_DIR/tab-state"
HOOKS_DIR="$CLAUDE_DIR/hooks"
DASHBOARD_DIR="$CLAUDE_DIR/dashboard"

echo "=== Claude Code Terminal Dashboard — Install ==="
echo ""

# 1. Create directories (E1)
echo "Creating directories..."
mkdir -p "$TAB_STATE_DIR"
mkdir -p "$HOOKS_DIR"
mkdir -p "$DASHBOARD_DIR"

# 2. Copy hook script (E2)
echo "Copying hook script..."
cp "$SCRIPT_DIR/hooks/tab-state.sh" "$HOOKS_DIR/tab-state.sh"
chmod +x "$HOOKS_DIR/tab-state.sh"

# 3. Build the Vue.js dashboard (E3)
echo "Building dashboard..."
(cd "$SCRIPT_DIR/dashboard" && npm install && npm run build)

echo "Copying dashboard dist..."
rm -rf "$DASHBOARD_DIR/dist"
cp -r "$SCRIPT_DIR/dashboard/dist" "$DASHBOARD_DIR/dist"

# 4. Copy server files (E4)
echo "Copying server files..."
cp "$SCRIPT_DIR/server/server.js" "$DASHBOARD_DIR/server.js"
cp "$SCRIPT_DIR/server/package.json" "$DASHBOARD_DIR/package.json"

# 5. Install server dependencies (E5)
echo "Installing server dependencies..."
(cd "$DASHBOARD_DIR" && npm install --production)

echo ""
echo "=== Installation complete ==="
echo ""

# 6. Print hook configuration instructions (E6, E8)
echo "To enable the dashboard, merge the following into $CLAUDE_DIR/settings.json"
echo "(do NOT overwrite the file — merge with any existing hooks configuration):"
echo ""
cat <<'HOOKSJSON'
{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh init" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh working", "async": true }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh stop", "async": true }] }],
    "StopFailure": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh error", "async": true }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh attention", "async": true }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh cleanup", "async": true }] }]
  }
}
HOOKSJSON

echo ""
echo "Also add the following to your VS Code settings (settings.json):"
echo ""
cat <<'VSCODEJSON'
{
  "terminal.integrated.tabs.title": "${sequence}",
  "terminal.integrated.tabs.description": "${task}${separator}${local}"
}
VSCODEJSON

echo ""
echo "Done! The server will auto-start on the next Claude Code session."
