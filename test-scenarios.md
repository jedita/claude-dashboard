# Claude Code Terminal Dashboard — Test Scenarios

All scenarios described in plain English. Organized by feature area matching the PRD.

---

## A. Hook Script (`tab-state.sh`)

### A1. Session Initialization (SessionStart → `init`)

- **A1.1** When a new Claude Code session starts, a state file is created at `~/.claude/tab-state/<session_id>.json` with status `starting`.
- **A1.2** When `CLAUDE_SESSION_NAME` env var is set, the state file uses that value as the session `name`.
- **A1.3** When `CLAUDE_SESSION_NAME` is not set, the name falls back to `<last_cwd_segment>-<first_4_chars_of_session_id>` (e.g. `ankorstore-a08f`).
- **A1.4** The state file contains all required fields: `session_id`, `name`, `status`, `cwd`, `pid`, `last_activity`, `created_at`.
- **A1.5** The `created_at` timestamp is set to the current time in ISO 8601 format.
- **A1.6** The terminal tab title is updated via OSC 0 to show `🔄 <session_name>`.
- **A1.7** If the API server is not running, the hook starts it in the background via `nohup`.
- **A1.8** If the API server is already running, the hook does not start a second instance.
- **A1.9** The state file is written atomically (write to `.tmp` then `mv`).
- **A1.10** The hook completes in under 200ms.

### A2. Working State (UserPromptSubmit → `working`)

- **A2.1** When the user submits a prompt, the state file is updated with status `working`.
- **A2.2** The `last_activity` timestamp is updated to the current time.
- **A2.3** The terminal tab title changes to `🟢 <session_name>`.
- **A2.4** The existing state file fields (`name`, `cwd`, `pid`, `created_at`) are preserved — only `status` and `last_activity` change.

### A3. Done State (Stop → `stop`)

- **A3.1** When Claude finishes responding, the state file is updated with status `done`.
- **A3.2** The `last_message_preview` is populated with the first ~80 characters of the last assistant message.
- **A3.3** Markdown formatting is stripped from the preview (code fences, headers, bold/italic, links removed).
- **A3.4** Newlines in the preview are collapsed to spaces.
- **A3.5** The terminal tab title changes to `✅ <session_name>`.
- **A3.6** The `last_activity` timestamp is updated.

### A4. Error State (StopFailure → `error`)

- **A4.1** When Claude encounters an API error, the state file is updated with status `error`.
- **A4.2** The terminal tab title changes to `❌ <session_name>`.
- **A4.3** The `last_activity` timestamp is updated.

### A5. Attention State (Notification → `attention`)

- **A5.1** When Claude needs user input, the state file is updated with status `attention`.
- **A5.2** The terminal tab title changes to `⚠️ <session_name>`.
- **A5.3** The `last_activity` timestamp is updated.

### A6. Cleanup (SessionEnd → `cleanup`)

- **A6.1** When a session ends, the state file for that session is deleted from `~/.claude/tab-state/`.
- **A6.2** If the state file doesn't exist (e.g. already cleaned up), the script does not error.

### A7. Edge Cases

- **A7.1** When two hooks fire in rapid succession for the same session, the last write wins and the file is not corrupted.
- **A7.2** When the `~/.claude/tab-state/` directory does not exist, the hook creates it.
- **A7.3** When `jq` is not installed, the hook fails gracefully (or reports an error).
- **A7.4** When stdin JSON is malformed, the hook does not crash or write a corrupted state file.
- **A7.5** When the `session_id` contains special characters, the file is still created safely.

---

## B. Local API Server

### B1. Health Endpoint

- **B1.1** `GET /api/health` returns `{ "ok": true }` with status 200.
- **B1.2** The health endpoint responds even when there are no session state files.

### B2. Sessions Endpoint

- **B2.1** `GET /api/sessions` returns an array of all session state objects.
- **B2.2** Each session object includes an `alive` boolean indicating whether the PID is still running.
- **B2.3** When no state files exist, `/api/sessions` returns an empty array.
- **B2.4** When a new state file is added to the directory, it appears in the next `/api/sessions` response.
- **B2.5** When a state file is deleted, it no longer appears in `/api/sessions`.
- **B2.6** When a state file contains invalid JSON, it is skipped (not returned) and does not crash the server.

### B3. SSE Events Endpoint

- **B3.1** `GET /api/events` establishes a Server-Sent Events connection.
- **B3.2** When a state file is created, the SSE stream emits a `session-update` event.
- **B3.3** When a state file is modified, the SSE stream emits a `session-update` event.
- **B3.4** When a state file is deleted, the SSE stream emits a `session-update` event.
- **B3.5** Rapid file changes within 300ms are debounced into a single `session-update` event.
- **B3.6** Multiple browser clients can connect to `/api/events` simultaneously and each receives events.

### B4. PID Liveness Checking

- **B4.1** Every 60 seconds, the server checks if each session's PID is still alive.
- **B4.2** When a PID is dead and the session status is not `done`, the session's `alive` field is set to `false`.
- **B4.3** When a PID is alive, the session's `alive` field is `true`.
- **B4.4** When a session has status `done` and its PID is dead, `alive` is still reported (the session completed normally).
- **B4.5** The liveness check does not modify the state files on disk — it only annotates the API response.

### B5. Startup Behavior

- **B5.1** On startup, the server removes state files older than 24 hours.
- **B5.2** State files younger than 24 hours are preserved on startup.
- **B5.3** The server binds to `127.0.0.1` only (not exposed to the network).
- **B5.4** The server uses port `3847` by default.
- **B5.5** The server uses the `PORT` env var if set, overriding the default port.
- **B5.6** If the port is already in use, the server logs a clear error and exits.
- **B5.7** The server creates the `~/.claude/tab-state/` directory if it doesn't exist.

### B6. Static File Serving

- **B6.1** The server serves the built Vue.js dashboard at the root URL (`http://127.0.0.1:3847/`).
- **B6.2** All static assets from `dist/` are served correctly (JS, CSS, HTML).

### B7. Server Auto-Launch Race Condition

- **B7.1** When two hooks simultaneously try to start the server, only one instance starts (PID file check).
- **B7.2** The PID file (`~/.claude/dashboard/server.pid`) is created when the server starts.
- **B7.3** If the PID file points to a dead process, a new server can be started.

---

## C. Browser Dashboard

### C1. Session Cards Display

- **C1.1** Each active session is rendered as a card with status emoji, name, last activity, and preview text.
- **C1.2** The status emoji matches the session status: 🔄 starting, 🟢 working, ✅ done, ⚠️ attention, ❌ error.
- **C1.3** The left border color matches the status (green for working, blue for done, amber for attention, red for error, gray for starting).
- **C1.4** Session names longer than 15 characters are truncated with an ellipsis.
- **C1.5** The preview text shows the first ~80 characters of the last assistant message.
- **C1.6** When a session has `alive: false`, the card is grayed out (opacity 0.5) and shows "Session ended unexpectedly".
- **C1.7** Stale sessions have a light gray left border instead of their status color.

### C2. Grouping and Sorting

- **C2.1** Sessions are grouped by project name (last segment of `cwd`).
- **C2.2** Each project group has a visible heading with the project name.
- **C2.3** Projects with no sessions do not appear on the dashboard.
- **C2.4** Cards within a group are ordered by `created_at` timestamp (oldest first).
- **C2.5** Cards never reorder when their status changes — position is stable based on creation time.
- **C2.6** A new session appears at the end of its project group.
- **C2.7** When a session is removed, the remaining cards maintain their positions.

### C3. Live Updates via SSE

- **C3.1** When a session's status changes, the corresponding card updates without a full page reload.
- **C3.2** When a new session starts, a new card appears on the dashboard automatically.
- **C3.3** When a session ends (state file deleted), the card disappears from the dashboard.
- **C3.4** The dashboard reconnects automatically if the SSE connection drops.
- **C3.5** After reconnection, the dashboard fetches fresh data and updates all cards.

### C4. Relative Timestamps

- **C4.1** The "last activity" time shows as a relative string (e.g. "just now", "2m ago", "1h ago").
- **C4.2** The relative time updates every 30 seconds without needing a server event.
- **C4.3** A session that was active "just now" transitions to "1m ago" after one minute.

### C5. Connection Status Indicator

- **C5.1** When the SSE connection is active, the header shows "● Connected" with a green dot.
- **C5.2** When the SSE connection is lost, the indicator changes to "● Reconnecting…" with an amber dot.
- **C5.3** When the server is unreachable after retries, the indicator shows "● Disconnected" with a red dot.
- **C5.4** After reconnecting successfully, the indicator returns to "● Connected".

### C6. Theme / Dark Mode

- **C6.1** When the OS is in light mode, the dashboard uses light theme colors (white background, dark text).
- **C6.2** When the OS is in dark mode, the dashboard uses dark theme colors (dark background, light text).
- **C6.3** Switching the OS theme updates the dashboard without a page reload.
- **C6.4** Card backgrounds, text colors, and borders all respect the current theme.
- **C6.5** Status border colors remain consistent across both themes.

### C7. Empty State

- **C7.1** When there are no active sessions, the dashboard shows a meaningful empty state (not a blank page).
- **C7.2** When the server is unreachable on initial load, the dashboard shows a connection error state.

---

## D. Deep-Linking to VS Code

### D1. "Open" Button

- **D1.1** Clicking the "Open" button triggers `vscode://anthropic.claude-code/open?session=<session_id>`.
- **D1.2** The link opens (or resumes) the correct Claude Code session in VS Code.
- **D1.3** VS Code comes to the foreground when the link is triggered.
- **D1.4** When the Claude Code extension is not installed, the link either fails gracefully or shows a VS Code install/enable prompt.

### D2. "Copy ID" Button

- **D2.1** Clicking "Copy ID" copies the full `session_id` to the system clipboard.
- **D2.2** A brief visual confirmation is shown after copying (e.g. button text changes to "Copied!").
- **D2.3** The copied ID can be used with `claude --resume <session_id>` successfully.

---

## E. Installation (`install.sh`)

- **E1** The script creates `~/.claude/tab-state/` if it doesn't exist.
- **E2** The script copies `tab-state.sh` to `~/.claude/hooks/tab-state.sh`.
- **E3** The script builds the Vue.js dashboard and copies `dist/` to `~/.claude/dashboard/dist/`.
- **E4** The script copies server files to `~/.claude/dashboard/`.
- **E5** The script runs `npm install --production` in `~/.claude/dashboard/`.
- **E6** The script prints instructions for merging hook configuration into `~/.claude/settings.json`.
- **E7** Running the install script a second time (re-install) works without errors and overwrites old files.
- **E8** The script does not overwrite existing `~/.claude/settings.json` — it only prints merge instructions.

---

## F. Integration / End-to-End Scenarios

### F1. Full Lifecycle

- **F1.1** Start a Claude Code session → state file appears → dashboard shows a new card with 🔄 status.
- **F1.2** Submit a prompt → card updates to 🟢 working status.
- **F1.3** Claude finishes → card updates to ✅ done with a message preview.
- **F1.4** Claude encounters an error → card updates to ❌ error status.
- **F1.5** Claude requests input → card updates to ⚠️ attention status.
- **F1.6** Session ends → card disappears from the dashboard.

### F2. Multiple Sessions

- **F2.1** Running 3 sessions in different projects shows 3 cards grouped under their respective project names.
- **F2.2** Running 2 sessions in the same project shows them grouped together under one heading.
- **F2.3** Sessions in different projects update independently — changing one does not affect others.
- **F2.4** All sessions can transition through all statuses independently.

### F3. Server Restart

- **F3.1** If the server is restarted, existing state files are still served correctly.
- **F3.2** The dashboard reconnects via SSE after the server restarts.
- **F3.3** State files older than 24 hours are pruned on server restart.

### F4. Browser Refresh

- **F4.1** Refreshing the dashboard page loads all current sessions from `/api/sessions`.
- **F4.2** The SSE connection is re-established after a page refresh.
- **F4.3** Card positions are consistent before and after refresh (same creation-order sorting).

### F5. Crash Recovery

- **F5.1** If a Claude Code session crashes without firing `SessionEnd`, the PID liveness check detects it within 60 seconds.
- **F5.2** The crashed session's card shows as stale (grayed out, "Session ended unexpectedly").
- **F5.3** On next server startup, orphaned state files older than 24h are pruned.

### F6. Performance

- **F6.1** Hook execution does not noticeably slow down Claude Code interactions (< 200ms).
- **F6.2** Dashboard state changes are reflected in the browser within ~500ms of the hook firing.
- **F6.3** With 10 concurrent sessions, the dashboard remains responsive and readable.
