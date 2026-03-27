# Claude Code Terminal Dashboard

A browser-based dashboard for monitoring active [Claude Code](https://claude.ai/code) sessions running in VS Code terminals. See all your sessions at a glance, check their status, and jump to the right terminal — without clicking through tabs.

![Status](https://img.shields.io/badge/status-working-green)

## The Problem

When running 3–5 concurrent Claude Code sessions in VS Code, there's no way to:

- See all sessions at a glance without clicking into each tab
- Know if a background session has finished, errored, or needs input
- Jump directly to the right terminal from outside VS Code

## How It Works

```
Claude Code sessions (Terminal 1, 2, 3…)
        │
        ▼  (lifecycle hooks)
~/.claude/tab-state/<session_id>.json
        │
        ▼  (fs.watch + SSE)
Express server (localhost:3847)
        │
        ▼  (real-time updates)
Browser dashboard (Vue.js)
        │
        ▼  (vscode:// deep-links)
Back to VS Code
```

Three components work together:

1. **Hook script** (`hooks/tab-state.sh`) — Triggered by Claude Code lifecycle events. Writes session state as JSON files and sets terminal tab titles via OSC 0 escape sequences.
2. **Backend server** (`server/server.js`) — Express.js server that watches the state directory, serves a REST API, and broadcasts changes over SSE.
3. **Frontend dashboard** (`dashboard/`) — Vue 3 SPA that renders session cards grouped by project with real-time updates.

## Features

- **Live session monitoring** — Cards update in real-time via Server-Sent Events
- **Status at a glance** — 🟢 Working, ✅ Done, ⚠️ Attention, ❌ Error, 🔄 Starting
- **Grouped by project** — Sessions organized by working directory
- **Deep-links to VS Code** — Click "Open" to jump to the session via `vscode://` URI
- **Terminal tab titles** — OSC 0 escape sequences show status emoji + session name in VS Code tabs
- **Light/dark mode** — Automatically matches your OS theme
- **PID liveness checks** — Detects and grays out sessions that ended unexpectedly
- **Auto-launch** — Server starts automatically on first session

## Prerequisites

- **Node.js** 18+
- **jq** — `brew install jq`
- **VS Code** with the [Claude Code extension](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code)

### VS Code Settings

Add these to your VS Code settings so terminal tabs display the hook-set titles:

```json
{
  "terminal.integrated.tabs.title": "${sequence}",
  "terminal.integrated.tabs.description": "${task}${separator}${local}"
}
```

## Installation

```bash
git clone <repo-url> ~/Projects/claude-dashboard
cd ~/Projects/claude-dashboard
bash install.sh
```

The install script:
1. Creates `~/.claude/tab-state/` directory
2. Copies the hook script to `~/.claude/hooks/tab-state.sh`
3. Builds the Vue.js dashboard and copies it to `~/.claude/dashboard/`
4. Installs server dependencies
5. Prints instructions for adding hook configuration to `~/.claude/settings.json`

### Hook Configuration

Add this to your `~/.claude/settings.json` (the install script will guide you):

```json
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
```

## Development

### Frontend

```bash
cd dashboard && npm install
npm run dev      # Vite dev server on http://localhost:5173 (proxies /api to :3847)
npm run build    # Production build to dist/
npm run preview  # Preview production build
```

### Backend

```bash
cd server && npm install
npm start        # Runs on http://127.0.0.1:3847
```

Run the server and the Vite dev server in separate terminals. The Vite config proxies `/api` requests to the backend.

### Testing Hooks Manually

```bash
echo '{"session_id":"test-123","cwd":"/tmp/test"}' | bash hooks/tab-state.sh init
```

Manual test scenarios are documented in `test-scenarios.md`.

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/api/health` | GET | `{ "ok": true }` — used by hook script to check if server is running |
| `/api/sessions` | GET | Array of all session state objects with computed `alive` field |
| `/api/events` | SSE | Server-Sent Events stream; emits `session-update` on state changes (300ms debounce) |

## Project Structure

```
claude-dashboard/
├── dashboard/              # Vue 3 + Vite frontend
│   └── src/
│       ├── App.vue
│       ├── components/
│       │   ├── SessionCard.vue
│       │   ├── ProjectGroup.vue
│       │   └── ConnectionStatus.vue
│       └── composables/
│           ├── useSessions.js
│           └── useRelativeTime.js
├── server/
│   └── server.js           # Express API server
├── hooks/
│   └── tab-state.sh        # Claude Code lifecycle hook script
├── install.sh              # Installation script
├── test-scenarios.md       # Manual test scenarios
└── CLAUDE.md               # AI assistant instructions
```

## Session State

State files are written to `~/.claude/tab-state/<session_id>.json`:

```json
{
  "session_id": "00893aaf-19fa-41d2-8238-13269b9b3ca0",
  "name": "auth-refactor",
  "status": "done",
  "cwd": "/Users/tomas/projects/ankorstore",
  "pid": 48291,
  "last_activity": "2026-03-24T14:32:01Z",
  "last_message_preview": "Completed the refactoring of the auth module...",
  "created_at": "2026-03-24T14:00:00Z"
}
```

Session names default to `<directory>-<short_id>` (e.g. `ankorstore-a08f`) and can be overridden with the `CLAUDE_SESSION_NAME` environment variable.

## Debugging

### Log file

All server output and hook diagnostics are written to:

```
~/.claude/dashboard/server.log
```

### Useful commands

```bash
# Tail the server log in real-time
tail -f ~/.claude/dashboard/server.log

# Show only AI title generation events
grep '\[ai-name\]' ~/.claude/dashboard/server.log

# Show AI title generation failures only
grep '\[ai-name\] \[ERROR\]' ~/.claude/dashboard/server.log

# Inspect a specific session's state file
cat ~/.claude/tab-state/<session_id>.json | jq .

# Check if the server is running
curl -s http://127.0.0.1:3847/api/health | jq .

# Check server PID
cat ~/.claude/dashboard/server.pid

# List all active session state files
ls -la ~/.claude/tab-state/
```

### Common issues

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| Dashboard shows default name (`project-abcd`) instead of AI title | `grep '\[ai-name\]' ~/.claude/dashboard/server.log` — look for ERROR/WARN entries | Ensure `claude` CLI is on PATH in the hook's environment |
| No sessions appear on dashboard | Check if server is running: `curl http://127.0.0.1:3847/api/health` | Restart: `node ~/.claude/dashboard/server.js` |
| Tab titles not updating in VS Code | Verify VS Code settings: `terminal.integrated.tabs.title` must be `${sequence}` | See [VS Code Settings](#vs-code-settings) |
| Stale sessions persist | Check PID liveness: `jq '.pid' ~/.claude/tab-state/*.json` and compare with `ps` | Dismiss from dashboard or delete state files |

## Known Limitations

- The `vscode://` deep-link may open a **new** terminal tab rather than focusing the existing one. Use "Copy ID" and `claude --resume <id>` as a workaround.
- The backend port (default 3847) is configurable via the `PORT` env var.
- State files from crashed sessions are pruned after 24 hours on server startup.

## Tech Stack

- **Frontend:** Vue.js 3 (Composition API), Vite, CSS with scoped styles
- **Backend:** Express.js, fs.watch, Server-Sent Events
- **Hooks:** Bash, jq, curl
- **No TypeScript, no test framework, no linter** — kept intentionally minimal
