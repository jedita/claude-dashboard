# Claude Code Dashboard — Features & Functions

A browser-based real-time dashboard for monitoring active Claude Code sessions running in VS Code terminals. It shows session status, supports deep-linking back to the originating terminal tab, and updates in real-time via Server-Sent Events (SSE).

---

## Table of Contents

1. [System Architecture](#system-architecture)
2. [Hook Script (tab-state.sh)](#hook-script-tab-statesh)
3. [Backend Server (server.js)](#backend-server-serverjs)
4. [Frontend Dashboard (Vue 3 SPA)](#frontend-dashboard-vue-3-spa)
5. [Installation & Deployment](#installation--deployment)
6. [Configuration Reference](#configuration-reference)
7. [API Reference](#api-reference)
8. [Event Flow](#event-flow)
9. [Known Limitations](#known-limitations)

---

## System Architecture

```
Claude Code Sessions (Terminal 1, 2, 3…)
    ↓ (lifecycle hooks)
~/.claude/tab-state/<session_id>.json
    ↓ (fs.watch + SSE)
Express Server (localhost:3847)
    ↓ (real-time updates)
Browser Dashboard (Vue 3 SPA)
    ↓ (vscode:// deep-links)
Back to VS Code
```

Three components work together:

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Hook script | Bash, jq, curl | Captures session lifecycle events, writes state files, manages terminal tab titles, auto-launches server |
| Backend server | Express.js (Node) | REST API, SSE broadcast, PID liveness tracking, file watching |
| Frontend dashboard | Vue 3 + Vite | Real-time UI, session cards, project grouping, deep-linking |

---

## Hook Script (tab-state.sh)

The hook script (`hooks/tab-state.sh`, ~490 lines) is a Bash script triggered by Claude Code lifecycle events. It writes session state as JSON files to `~/.claude/tab-state/` and manages terminal tab titles.

### Lifecycle Event Handlers

#### `init` — SessionStart
- Creates a new session state file with initial metadata (session ID, working directory, PID, timestamps).
- Discovers the TTY path by walking the process tree.
- Sets the terminal tab title to `🔄 SessionName`.
- Cleans up stale sessions from dead processes.
- Auto-launches the Express server if not already running.
- Opens the dashboard in the default browser (once per server instance).

#### `working` — UserPromptSubmit
- Updates session status to `working`.
- Sets the terminal tab title to `🟢 SessionName`.
- On the first prompt: triggers AI-powered title generation in the background using the Claude API.
- The AI generates a short 3–5 word descriptive title from the user's prompt text.

#### `stop` — Stop (successful completion)
- Updates session status to `done`.
- Sets the terminal tab title to `✅ SessionName`.
- Extracts the last assistant message, strips markdown formatting, and stores a preview (up to 80 characters).

#### `error` — StopFailure
- Updates session status to `error`.
- Sets the terminal tab title to `❌ SessionName`.

#### `attention` — Notification
- Updates session status to `attention`.
- Sets the terminal tab title to `⚠️ SessionName`.

#### `cleanup` — SessionEnd
- Removes the session state file.
- Clears the terminal tab title.

### Internal Functions

| Function | Purpose |
|----------|---------|
| `now_iso()` | Generates an ISO 8601 UTC timestamp |
| `discover_tty()` | Finds the controlling TTY by walking up to 10 process ancestors. Fast path via `/dev/tty`; fallback via process tree walking. Required because hooks run as subprocesses without a controlling terminal. |
| `set_tab_title(title, tty_path)` | Writes an OSC 0 escape sequence (`\033]0;title\033\\`) to the discovered TTY to set the VS Code terminal tab title. Silently fails if TTY is no longer accessible. |
| `atomic_write(content)` | Writes JSON to a temporary file then renames it into place (atomic operation), preventing partial reads. |
| `strip_markdown(text)` | Removes code blocks, inline code, headers, bold/italic, links, blockquotes, and list markers. Collapses to a single line and truncates at 80 characters. Used for message preview text. |
| `cleanup_stale_sessions()` | Iterates state files and removes any whose PID no longer exists. Prevents stale session accumulation from crashes. |
| `get_session_name()` | Reads the current session name from the state file via `jq`. |
| `generate_ai_name(prompt, file, tty)` | Runs in the background. Calls the Claude API to generate a 3–5 word title from the user's prompt. Validates the result (rejects if >7 words or looks conversational). Updates the state file and terminal tab title atomically. Guarded by an `ai_name_generated` flag to run only once per session. Logs all failures, rejections, and successes to `~/.claude/dashboard/server.log` with `[ai-name]` tag and severity level (`ERROR`, `WARN`, `INFO`). |
| `auto_launch_server()` | Health-checks the server via `curl /api/health`. If not running, locates the Node binary (tries `command -v node`, `/opt/homebrew/bin/node`, `/usr/local/bin/node`, `/usr/bin/node`, then loads nvm). Spawns the server in a new detached session so it survives terminal closure. Waits up to 3 seconds (6 retries) for the server to respond. |
| `open_dashboard_browser()` | Opens the dashboard URL in the default browser once per server instance. Checks a flag file (`~/.claude/dashboard/.browser-opened`) to prevent repeated opens. Respects the `CLAUDE_DASHBOARD_NO_BROWSER` environment variable. |

### Recursion Guard

The `CLAUDE_TAB_TITLE_GENERATING` environment variable prevents the AI title generation (which calls Claude) from triggering hooks recursively.

### Session Naming

Default session name: `<dirname>-<short_id>`. Can be overridden via the `CLAUDE_SESSION_NAME` environment variable.

### State File Structure

Written to `~/.claude/tab-state/<session_id>.json`:

```json
{
  "version": 1,
  "session_id": "00893aaf-19fa-41d2-8238-13269b9b3ca0",
  "name": "auth-refactor",
  "status": "starting",
  "cwd": "/Users/tomas/projects/ankorstore",
  "pid": 48291,
  "last_activity": "2026-03-24T14:32:01Z",
  "last_message_preview": "Completed the refactoring of...",
  "created_at": "2026-03-24T14:00:00Z",
  "ai_name_generated": false,
  "tty_path": "/dev/ttys000"
}
```

### External Dependencies

- `jq` — JSON processing (required)
- `curl` — HTTP requests to server and Claude API (required)
- `node` — Required for auto-launching the server

---

## Backend Server (server.js)

The backend (`server/server.js`, ~265 lines) is an Express.js server that watches the state directory, serves a REST API, and broadcasts changes over SSE.

### Features

#### File Watching & SSE Broadcasting
- Uses `fs.watch()` on `~/.claude/tab-state/` to detect state file changes.
- Debounces changes (300ms) before broadcasting a `session-update` event to all connected SSE clients.
- SSE clients receive events via `EventSource` with automatic browser-side reconnection.

#### PID Liveness Tracking
- Maintains a `pidLivenessCache` (Map) that maps PIDs to alive/dead boolean status.
- Refreshes the cache every 60 seconds using `process.kill(pid, 0)` signal checks.
- Each session returned by the API includes a computed `alive` boolean field.

#### Dead Session Auto-Pruning
- `pruneDeadSessions()` runs every 60 seconds.
- If a session's PID is dead AND its `last_activity` is older than 5 minutes: the state file is automatically removed.
- On startup, `pruneOldStateFiles()` removes any state files older than 24 hours.

#### Graceful Shutdown
- Handles `SIGINT` and `SIGTERM` signals.
- If active sessions exist: the signal is ignored (server stays alive to serve the dashboard).
- If no active sessions: exits cleanly and removes the PID file.

#### Static File Serving
- Serves the built Vue dashboard from `~/.claude/dashboard/dist/`.
- SPA fallback: all non-API routes return `index.html` for client-side routing.

### Server Functions

| Function | Purpose |
|----------|---------|
| `pruneOldStateFiles()` | Startup cleanup — removes state files older than 24 hours |
| `checkPidAlive(pid)` | Tests if a process is still running via `process.kill(pid, 0)`. Handles EPERM (process exists, different owner). |
| `refreshPidLiveness()` | Updates the PID cache for all known sessions (runs every 60s) |
| `readAllSessions()` | Reads all `.json` files from the state directory, parses them, skips invalid JSON silently |
| `getSessionsWithLiveness()` | Reads sessions and enriches each with an `alive` boolean from the cache |
| `broadcastSSE(eventName, data)` | Sends a formatted SSE event to all connected clients |
| `scheduleSSEBroadcast()` | Debounced wrapper — waits 300ms after the last file change before broadcasting |
| `pruneDeadSessions()` | Removes state files for dead sessions past the 5-minute grace period |

### Configuration Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `PORT` | 3847 | Server listening port (configurable via `PORT` env var) |
| `BIND_ADDRESS` | `127.0.0.1` | Localhost only — not exposed to network |
| `SSE_DEBOUNCE_MS` | 300 | Debounce window for state file changes |
| `PID_LIVENESS_INTERVAL_MS` | 60,000 | PID check interval |
| `PRUNE_AGE_MS` | 86,400,000 | Maximum state file age (24 hours) |
| `DEAD_SESSION_GRACE_MS` | 300,000 | Grace period before auto-pruning dead sessions (5 minutes) |

### Dependencies

- `express` (^4.21.0) — the only npm dependency
- Node.js built-in modules: `fs`, `path`, `os`

---

## Frontend Dashboard (Vue 3 SPA)

The frontend (`dashboard/`, ~300 lines of source) is a Vue 3 + Vite single-page application using the Composition API.

### Components

#### `App.vue` — Root Component
- Renders the dashboard header with the title and connection status indicator.
- Displays three states:
  - **Loading**: "Loading sessions…" text while fetching.
  - **Error**: Red-bordered error message when the server is unreachable.
  - **Empty**: Dashed-border message when no sessions exist.
  - **Active**: Renders `ProjectGroup` components for each group of sessions.
- Controls the overall layout (max-width 1080px centered container).
- Defines all CSS custom properties (variables) for theming.
- Applies an `opacity: 0.4` and `pointer-events: none` overlay when connection is lost (`conn-impaired` class).

#### `ProjectGroup.vue` — Session Grouping
- Groups sessions by their project directory (last path component of `cwd`).
- Displays a section heading with the project name (uppercase, letter-spaced).
- Renders session cards in a responsive CSS Grid:
  - `grid-template-columns: repeat(auto-fill, minmax(300px, 1fr))`
  - Automatically adapts from 1 column on mobile to 2–3+ columns on desktop.

#### `SessionCard.vue` — Individual Session Display
- Displays a card for each session with:
  - **Status indicator**: Animated spinner (working), gray dot (starting), or emoji (✅ done, ⚠️ attention, ❌ error).
  - **Session name**: Truncated to 30 characters with ellipsis.
  - **Relative time**: "just now", "3m ago", "2h ago", "1d ago" — auto-updates every 30 seconds.
  - **Message preview**: Collapsed by default; click to expand (up to 140px with scroll).
  - **Stale indicator**: "Session ended unexpectedly" warning for dead processes.
  - **Left border**: Color-coded by status (gray=starting, orange=working, blue=done, yellow=attention, red=error, muted gray=dead).
  - **Stale sessions**: Reduced to 45% opacity.

- **Actions**:
  - **Open in VS Code**: Generates a `vscode://file/{cwd}` deep-link (or `vscode://anthropic.claude-code/open?session={id}` if no cwd).
  - **Copy ID**: Copies `session_id` to clipboard with visual feedback ("Copy ID" → "Copied!" → "Copy ID" after 2s).
  - **Dismiss**: Only shown for dead sessions. Calls `DELETE /api/sessions/:id` to remove the state file.

#### `ConnectionStatus.vue` — Connection Indicator
- Displays a pill-shaped badge in the header with:
  - **Connected**: Green dot with glow shadow, "Connected" label.
  - **Reconnecting**: Orange dot with glow shadow, "Reconnecting…" label.
  - **Disconnected**: Red dot with glow shadow, "Disconnected" label.

### Composables

#### `useSessions.js` — Session State & API Logic
- **`sessions`**: Reactive array of all session objects.
- **`loading`**: Boolean for initial fetch state.
- **`error`**: Error message string (null when healthy).
- **`connectionStatus`**: `'connected'` | `'reconnecting'` | `'disconnected'`.
- **`groupedSessions`**: Computed property that groups sessions by project name (last path component of `cwd`), sorts sessions within each group by `created_at` (oldest first), and sorts groups alphabetically by project name.
- **`fetchSessions()`**: Calls `GET /api/sessions` and updates reactive state.
- **`connectSSE()`**: Opens an `EventSource` to `/api/events`. On `session-update` events, refetches all sessions. Handles reconnection with a 10-second timeout before marking as disconnected.
- **`disconnectSSE()`**: Closes the EventSource and clears timers.
- **`dismissSession(sessionId)`**: Calls `DELETE /api/sessions/:id` and refetches.

#### `useRelativeTime.js` — Time Formatting
- **`formatRelativeTime(isoString)`**: Converts ISO 8601 timestamps to relative format:
  - `< 60s` → "just now"
  - `< 60m` → "Xm ago"
  - `< 24h` → "Xh ago"
  - `≥ 1d` → "Xd ago"
  - Handles null/empty input and future timestamps gracefully.
- **`tick`**: A reactive counter incremented every 30 seconds, forcing Vue to recompute all relative times across the dashboard.

### Theme System

The dashboard supports automatic light and dark modes via CSS custom properties and `@media (prefers-color-scheme: dark)`.

**Light Mode (default):**

| Variable | Value | Usage |
|----------|-------|-------|
| `--bg` | `#FAFBFC` | Page background |
| `--surface` | `#FFFFFF` | Container surfaces |
| `--card-bg` | `#FFFFFF` | Card backgrounds |
| `--text-primary` | `#1a1a2e` | Main text |
| `--text-secondary` | `#6b7280` | Secondary/muted text |
| `--border-color` | `#e5e7eb` | Borders |
| `--border-subtle` | `#f0f1f3` | Subtle dividers |

**Dark Mode:**

| Variable | Value | Usage |
|----------|-------|-------|
| `--bg` | `#111119` | Page background |
| `--surface` | `#1a1a2e` | Container surfaces |
| `--card-bg` | `#1e1e36` | Card backgrounds |
| `--text-primary` | `#ECF0F1` | Main text |
| `--text-secondary` | `#8b95a5` | Secondary/muted text |
| `--border-color` | `#2a2a44` | Borders |
| `--border-subtle` | `#222238` | Subtle dividers |

**Spacing Scale:** `--space-xs` (4px), `--space-sm` (8px), `--space-md` (16px), `--space-lg` (24px), `--space-xl` (40px), `--space-2xl` (64px).

### Animations

- **Working spinner**: `@keyframes spin` — 360° rotation, 0.7s linear infinite. Orange (#E67E22) border styling.
- **Button hover transitions**: Background and color transitions at 0.15s.
- **Card hover**: Opacity and box-shadow transitions at 0.2s.
- **Connection impaired overlay**: Opacity transition at 0.3s.

### Responsive Design

- Max-width 1080px centered container.
- CSS Grid with `auto-fill` and `minmax(300px, 1fr)` for automatic column adaptation.
- System font stack with em-based sizing.
- Flexible spacing scale via CSS custom properties.

### Frontend Dependencies

- `vue` (^3.5.30)
- `@vitejs/plugin-vue` (^6.0.5) — dev
- `vite` (^8.0.1) — dev

No router, state management library, or UI framework.

---

## Installation & Deployment

### Install Script (`install.sh`, ~85 lines)

1. **Creates directories**: `~/.claude/tab-state/`, `~/.claude/hooks/`, `~/.claude/dashboard/`.
2. **Copies hook script**: `hooks/tab-state.sh` → `~/.claude/hooks/tab-state.sh` (made executable).
3. **Builds dashboard**: Runs `npm install && npm run build` in `dashboard/`.
4. **Copies built dashboard**: `dashboard/dist/` → `~/.claude/dashboard/dist/`.
5. **Copies server files**: `server/server.js` and `server/package.json` → `~/.claude/dashboard/`.
6. **Installs server dependencies**: `npm install --production` in `~/.claude/dashboard/`.
7. **Prints configuration instructions**: Outputs the hook configuration JSON and VS Code settings.

### Required Hook Configuration

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tab-state.sh init" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tab-state.sh working", "async": true }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tab-state.sh stop", "async": true }] }],
    "StopFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tab-state.sh error", "async": true }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tab-state.sh attention", "async": true }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tab-state.sh cleanup", "async": true }] }]
  }
}
```

### Required VS Code Settings

```json
{
  "terminal.integrated.tabs.title": "${sequence}",
  "terminal.integrated.tabs.description": "${task}${separator}${local}"
}
```

This enables VS Code to display the hook-set terminal tab titles.

### Development Commands

| Command | Location | Purpose |
|---------|----------|---------|
| `npm run dev` | `dashboard/` | Vite dev server on port 5173 (proxies `/api` to :3847) |
| `npm run build` | `dashboard/` | Production build to `dist/` |
| `npm run preview` | `dashboard/` | Preview production build |
| `npm start` / `node server.js` | `server/` | Start Express server on port 3847 |

### Manual Hook Testing

```bash
echo '{"session_id":"test-123","cwd":"/tmp/test"}' | bash hooks/tab-state.sh init
```

---

## Configuration Reference

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `3847` | Server listening port |
| `CLAUDE_SESSION_NAME` | `<dirname>-<short_id>` | Override the session display name |
| `CLAUDE_DASHBOARD_NO_BROWSER` | unset | Set to any value to disable auto-opening the browser |
| `CLAUDE_TAB_TITLE_GENERATING` | unset | Internal recursion guard for AI title generation |
| `NVM_DIR` | `~/.nvm` | Node version manager directory (used by server auto-launch) |

### File Paths

| Path | Purpose |
|------|---------|
| `~/.claude/tab-state/` | Session state JSON files |
| `~/.claude/tab-state/<session_id>.json` | Individual session state |
| `~/.claude/hooks/tab-state.sh` | Installed hook script |
| `~/.claude/dashboard/` | Server and dashboard distribution |
| `~/.claude/dashboard/dist/` | Built Vue dashboard static files |
| `~/.claude/dashboard/server.js` | Express server |
| `~/.claude/dashboard/server.pid` | Server process ID file |
| `~/.claude/dashboard/server.log` | Server stdout/stderr log |
| `~/.claude/dashboard/.browser-opened` | Flag file to prevent repeated browser opens |
| `~/.claude/settings.json` | Claude Code hook configuration |

### Timeouts & Intervals

| Name | Value | Purpose |
|------|-------|---------|
| SSE debounce | 300ms | Debounce window for state file changes before broadcasting |
| PID liveness check | 60s | How often the server verifies session PIDs are alive |
| State file max age | 24h | Startup pruning threshold for old state files |
| Dead session grace period | 5min | Wait time before auto-removing dead session state files |
| Relative time tick | 30s | How often the dashboard recalculates relative timestamps |
| SSE disconnect timeout | 10s | Time without SSE response before marking as disconnected |
| Server startup wait | 3s | Maximum wait for server to respond after auto-launch (6 retries × 500ms) |

---

## API Reference

### `GET /api/health`

Health check endpoint.

**Response:** `{ "ok": true }`

### `GET /api/sessions`

Returns all active sessions with computed liveness.

**Response:**
```json
[
  {
    "version": 1,
    "session_id": "uuid",
    "name": "session-name",
    "status": "starting|working|done|error|attention",
    "cwd": "/path/to/project",
    "pid": 12345,
    "last_activity": "2026-03-24T14:32:01Z",
    "last_message_preview": "Completed the refactoring...",
    "created_at": "2026-03-24T14:00:00Z",
    "alive": true
  }
]
```

### `DELETE /api/sessions/:id`

Dismisses a session by removing its state file.

**Response:** `{ "ok": true }` or `404` if not found.

The session ID is sanitized (non-alphanumeric characters replaced with underscores).

### `GET /api/events`

Server-Sent Events stream for real-time updates.

**Headers:**
- `Content-Type: text/event-stream`
- `Cache-Control: no-cache`
- `Connection: keep-alive`

**Events:**
```
event: session-update
data: {"type":"reload"}
```

Sends `retry: 3000\n\n` on initial connection. The browser `EventSource` handles automatic reconnection.

---

## Event Flow

### Full Session Lifecycle

```
1. Claude Code starts a session
   → SessionStart hook fires
   → tab-state.sh init
   → State file created (status: "starting")
   → Tab title: "🔄 SessionName"
   → Server auto-launched if needed
   → Browser opened (once per server instance)

2. fs.watch detects new state file
   → Server broadcasts "session-update" SSE event (debounced 300ms)
   → Dashboard receives event, fetches /api/sessions
   → New session card appears in the dashboard

3. User submits a prompt
   → UserPromptSubmit hook fires
   → tab-state.sh working
   → State file updated (status: "working")
   → Tab title: "🟢 SessionName"
   → AI title generation starts in background (first prompt only)
   → Dashboard updates: spinner shown, status changes

4. AI title generated (background, ~1-2s)
   → State file updated with AI-generated name
   → Tab title: "🟢 AI Generated Title"
   → Dashboard updates: session name changes

5. Claude finishes responding
   → Stop hook fires
   → tab-state.sh stop
   → State file updated (status: "done", last_message_preview populated)
   → Tab title: "✅ SessionName"
   → Dashboard updates: checkmark shown, preview available

6. User ends the session
   → SessionEnd hook fires
   → tab-state.sh cleanup
   → State file deleted
   → Tab title cleared
   → Dashboard updates: session card disappears

Alternative paths:
- StopFailure → status: "error", tab: "❌"
- Notification → status: "attention", tab: "⚠️"
- Process crash → PID check detects dead process after 60s;
  state file auto-pruned after 5-minute grace period
```

---

## Debugging

### Log File

All server output and hook-script diagnostics are written to `~/.claude/dashboard/server.log`. The hook script's `generate_ai_name` function tags its log entries with `[ai-name]` and a severity level (`ERROR`, `WARN`, `INFO`).

### Diagnostic Commands

| Command | Purpose |
|---------|---------|
| `tail -f ~/.claude/dashboard/server.log` | Stream server and hook logs in real-time |
| `grep '\[ai-name\]' ~/.claude/dashboard/server.log` | Show all AI title generation events |
| `grep '\[ai-name\] \[ERROR\]' ~/.claude/dashboard/server.log` | Show AI title generation failures only |
| `grep '\[ai-name\] \[WARN\]' ~/.claude/dashboard/server.log` | Show rejected AI titles (too long or conversational) |
| `cat ~/.claude/tab-state/<session_id>.json \| jq .` | Inspect a session's current state |
| `cat ~/.claude/tab-state/<session_id>.json \| jq '.name, .ai_name_generated'` | Check if AI name was applied |
| `curl -s http://127.0.0.1:3847/api/health \| jq .` | Verify server is running |
| `cat ~/.claude/dashboard/server.pid` | Check server PID |
| `ls -la ~/.claude/tab-state/` | List all active session state files |

### Common Issues

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| Dashboard shows default name (`project-abcd`) instead of AI-generated title | Run `grep '\[ai-name\]' ~/.claude/dashboard/server.log` — look for `ERROR` (CLI not found, API failure) or `WARN` (title rejected) | Ensure `claude` CLI is on PATH in the hook's shell environment. Check `~/.claude/dashboard/server.log` for stderr output from the CLI. |
| `ai_name_generated` is `false` after session completes | The `stop` event resets this flag to `false`. Check if any `[ai-name] [INFO]` entry exists for that session — if not, the `working` event may not have fired or the CLI call failed. | Verify the `UserPromptSubmit` hook is configured in `~/.claude/settings.json`. |
| No sessions appear on dashboard | Server may not be running. Run `curl http://127.0.0.1:3847/api/health`. | Start manually: `node ~/.claude/dashboard/server.js`, or restart a Claude Code session (auto-launches server on `init`). |
| Tab titles not showing in VS Code | VS Code needs `terminal.integrated.tabs.title` set to `${sequence}` to display OSC 0 titles. | Add the required VS Code settings (see [Installation & Deployment](#installation--deployment)). |
| Stale/dead sessions persist on dashboard | PID liveness check runs every 60s; dead sessions have a 5-minute grace period before auto-pruning. | Dismiss manually from the dashboard, or delete the state file: `rm ~/.claude/tab-state/<session_id>.json`. |

---

## Known Limitations

1. **VS Code deep-link behavior**: The `vscode://file/` URI may open a new terminal tab instead of focusing the existing one. Workaround: use "Copy ID" and `claude --resume <id>`.
2. **No browser focus management**: The dashboard opens in the default browser but does not steal focus.
3. **AI title generation depends on Claude API**: Requires network connectivity and API availability. Failures are logged to `~/.claude/dashboard/server.log` with the `[ai-name]` tag.
4. **Platform support**: TTY discovery tested on macOS/Linux. Untested on Windows/WSL.
5. **No TypeScript**: Plain JavaScript throughout the entire project.
6. **No automated tests**: Test scenarios are documented in `test-scenarios.md` for manual verification.
7. **No linter**: No ESLint, Prettier, or other code quality tooling configured.
8. **Single server instance**: All sessions share one Express server; no clustering or load balancing.
9. **No authentication**: The dashboard is exposed on `localhost:3847` without any auth. Bound to `127.0.0.1` only.
10. **Ephemeral session data**: Sessions are only visible while state files exist. Clearing `~/.claude/tab-state/` removes all history.
11. **No session persistence/history**: Once a session's state file is deleted (cleanup or dismissal), it cannot be recovered.
