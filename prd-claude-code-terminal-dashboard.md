# PRD: Claude Code Terminal Dashboard

**Author:** Tomas · **Date:** March 24, 2026 · **Status:** Spec Complete

---

## Executive summary

When running multiple Claude Code sessions in VS Code's integrated terminal, there is no centralized way to see all sessions at a glance, understand their status, or jump to a specific one. This PRD specifies a **browser-based dashboard** that reads hook-generated state files to display a live overview of all active Claude Code sessions, their status (working, done, needs attention, error) — with a deep-link mechanism to focus the originating terminal tab in VS Code.

The solution is built entirely on user-side hooks and a lightweight local web server. No upstream changes to Claude Code or VS Code are required.

---

## Problem statement

### Current pain points

1. **No bird's-eye view.** With 3–5 concurrent Claude Code terminals, the only way to check what's happening is to click into each tab individually. There's no external surface showing all sessions.
2. **No status visibility for background tabs.** A session may have finished, errored, or be waiting for input — but unless you're looking at that specific tab, you don't know.
3. **No deep-linking back into VS Code.** Even if you had a list of sessions, there's no way to click and jump to the right terminal tab without cycling through them.

### User story

> As a developer running multiple Claude Code sessions in VS Code, I want a persistent dashboard (browser tab or menu bar widget) that shows all my active sessions with their status, so I can see at a glance which sessions need my attention and jump directly to the right terminal.

---

## Scope

**In scope (Phases 1–4):**
- Hook scripts writing session state files + OSC tab titles (Phase 1)
- Local API server with SSE live updates (Phase 2)
- Browser dashboard with Vue.js (Phase 3)
- `vscode://` deep-links from dashboard cards (Phase 4)

**Out of scope (future):**
- OSC 9 notifier integration for in-VS Code notifications (Phase 5)
- Custom VS Code extension for terminal focus-by-name (Phase 6)
- macOS menu bar widget
- AI-generated session names via Anthropic API
- Agent/subagent hierarchy display

---

## Solution overview

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Claude Code (Terminal 1)    Claude Code (Terminal 2)    ...    │
│         │                           │                           │
│    Stop/Notification/           Stop/Notification/              │
│    UserPromptSubmit hooks       UserPromptSubmit hooks          │
│         │                           │                           │
│         ▼                           ▼                           │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  ~/.claude/tab-state/<session_id>.json                   │   │
│  │  { status, cwd, pid, name, last_activity, preview }      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                          │                                      │
│              ┌───────────┼───────────────┐                      │
│              ▼                           ▼                      │
│   ┌─────────────────┐       ┌───────────────────────┐          │
│   │ Express server   │       │  OSC 0 title updater  │          │
│   │ localhost:3847   │       │  (in hook script)     │          │
│   │ JSON API + SSE   │       └───────────────────────┘          │
│   └────────┬────────┘                                           │
│            │                                                    │
│            ▼                                                    │
│   ┌─────────────────────────────┐                               │
│   │ Browser Dashboard (Vue.js)  │                               │
│   │  - Cards per session        │                               │
│   │  - Grouped by project       │                               │
│   │  - Click → vscode:// link   │                               │
│   └─────────────────────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

### Components

| Component | Role | Tech |
|---|---|---|
| **Hook scripts** | Write session state to disk on every lifecycle event; emit OSC 0 for terminal tab titles | Bash + jq |
| **Local API server** | Serve `~/.claude/tab-state/*.json` as JSON endpoint; SSE for live updates; PID liveness checks | Node.js (Express + chokidar) |
| **Browser dashboard** | Render session cards grouped by project; stream updates via SSE; trigger deep-links on click | Vue.js 3 + Vite |
| **Deep-link bridge** | Open/resume session in VS Code when clicked from dashboard | `vscode://anthropic.claude-code/open?session=<id>` URI scheme |

---

## Feature A: Hook-based state management

### State file format

Each active session writes to `~/.claude/tab-state/<session_id>.json`:

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

### State file fields

| Field | Type | Source | Description |
|---|---|---|---|
| `session_id` | string | Hook stdin (`session_id`) | Unique session identifier from Claude Code |
| `name` | string | `CLAUDE_SESSION_NAME` env var or fallback | Human-readable session name. Fallback: `<last_cwd_segment>-<short_id>` (e.g. `ankorstore-a08f`) |
| `status` | enum | Hook event type | One of: `starting`, `working`, `done`, `attention`, `error` |
| `cwd` | string | Hook stdin (`cwd`) or `$PWD` | Working directory of the session |
| `pid` | number | `$PPID` or hook stdin | Process ID of the Claude Code process (used for liveness checks) |
| `last_activity` | ISO 8601 | Generated on write | Timestamp of the last hook event |
| `last_message_preview` | string | Hook stdin (`last_assistant_message`) | First ~80 chars of the last assistant message, plain text, stripped of markdown |
| `created_at` | ISO 8601 | Set on `init` event | Timestamp when the session was first seen (used for creation-order sorting) |

### Status values

| Status | Emoji | Trigger hook | Meaning |
|---|---|---|---|
| `starting` | 🔄 | `SessionStart` | Session just started or was resumed |
| `working` | 🟢 | `UserPromptSubmit` | User submitted a prompt, Claude is processing |
| `done` | ✅ | `Stop` | Claude finished responding, session is idle |
| `attention` | ⚠️ | `Notification` | Claude needs input (permission prompt, idle) |
| `error` | ❌ | `StopFailure` | API error (rate limit, auth failure, etc.) |

### Hook configuration

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh init" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh working" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh stop" }] }],
    "StopFailure": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh error" }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh attention" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command",
      "command": "bash ~/.claude/hooks/tab-state.sh cleanup" }] }]
  }
}
```

### Hook script behavior (`tab-state.sh`)

**Performance target:** < 200ms per invocation. No network calls. Minimal disk I/O.

The script receives JSON via stdin from Claude Code with `session_id`, `last_assistant_message`, `transcript_path`, and other fields depending on the event. The first positional argument (`$1`) determines which event is being handled.

**Parsing strategy:** Strict per-event. Each event type branches and parses only the fields that event provides. No loose fallback parsing.

**On `init` (SessionStart):**
1. Parse `session_id` and `cwd` from stdin using `jq`
2. Read `CLAUDE_SESSION_NAME` env var; if unset, generate fallback name: `<last_cwd_segment>-<first_4_chars_of_session_id>` (e.g. `ankorstore-a08f`)
3. Create state file with `status: "starting"`, `created_at`, `pid`
4. Write atomically (write to `.tmp`, then `mv`)
5. Emit OSC 0: `printf '\033]0;🔄 %s\033\\' "$SESSION_NAME"`
6. **Auto-launch server:** Check if server is running (`curl -s http://127.0.0.1:3847/api/health`). If not, start it: `nohup node ~/.claude/dashboard/server.js >> ~/.claude/dashboard/server.log 2>&1 &`

**On `working` (UserPromptSubmit):**
1. Parse `session_id` from stdin
2. Read existing state file
3. Update `status: "working"`, `last_activity`
4. Write atomically
5. Emit OSC 0: `printf '\033]0;🟢 %s\033\\' "$SESSION_NAME"`

**On `stop` (Stop):**
1. Parse `session_id` and `last_assistant_message` from stdin
2. Strip markdown formatting from `last_assistant_message`, truncate to 80 chars → `last_message_preview`
3. Update `status: "done"`, `last_activity`, `last_message_preview`
4. Write atomically
5. Emit OSC 0: `printf '\033]0;✅ %s\033\\' "$SESSION_NAME"`

**On `error` (StopFailure):**
1. Parse `session_id` from stdin
2. Update `status: "error"`, `last_activity`
3. Write atomically
4. Emit OSC 0: `printf '\033]0;❌ %s\033\\' "$SESSION_NAME"`

**On `attention` (Notification):**
1. Parse `session_id` from stdin
2. Update `status: "attention"`, `last_activity`
3. Write atomically
4. Emit OSC 0: `printf '\033]0;⚠️ %s\033\\' "$SESSION_NAME"`

**On `cleanup` (SessionEnd):**
1. Parse `session_id` from stdin
2. Remove the state file for this session

**Atomic writes:** All writes use write-to-`.tmp`-then-`mv` pattern. No file locking needed — `mv` is atomic on POSIX, and last-write-wins semantics are acceptable.

**Markdown stripping for preview:** Use `sed` to remove code fences, headers (`#`), bold/italic markers, links, and collapse newlines to spaces.

---

## Feature B: Local API server

A lightweight Express server that watches the state directory and serves data to the browser dashboard.

### Server configuration

| Setting | Value | Notes |
|---|---|---|
| **Bind address** | `127.0.0.1` | Local only, no network exposure |
| **Port** | `3847` (configurable via `PORT` env var) | Check if in use on startup |
| **State directory** | `~/.claude/tab-state/` | Created on first hook run |
| **Log output** | `~/.claude/dashboard/server.log` | Append mode, for debugging |
| **SSE debounce** | 300ms server-side | Coalesces rapid file-change events |
| **PID liveness interval** | 60 seconds | Checks all session PIDs periodically |
| **Lifecycle** | Runs until manually stopped | Started by SessionStart hook if not already running |

### Endpoints

| Endpoint | Method | Response |
|---|---|---|
| `GET /api/health` | GET | `{ "ok": true }` — used by hook script to check if server is running |
| `GET /api/sessions` | GET | Array of all session state objects, with `alive` boolean added per session |
| `GET /api/events` | SSE | Server-Sent Events stream; emits `session-update` when any `.json` file changes (debounced 300ms) |

### PID liveness checking

Every 60 seconds, the server iterates all loaded session state objects and checks if each PID is still alive using `process.kill(pid, 0)` (signal 0 = existence check, doesn't actually kill).

- If PID is dead and `status` is not `done`, set a synthetic `alive: false` flag on the session data returned by `/api/sessions`.
- The dashboard uses `alive: false` to visually gray out the session card and show a "Session ended unexpectedly" label.
- The server does **not** modify the state files on disk — it only annotates the API response. State files are cleaned up by the 24h pruning or manually.

### Server startup pruning

On startup, the server removes state files older than 24 hours (based on file modification time). This cleans up ghost entries from crashed sessions that never fired `SessionEnd`.

### File watching

Uses `chokidar` to watch `~/.claude/tab-state/` for `add`, `change`, and `unlink` events. On any event, a 300ms debounce timer starts (or resets). When the timer fires, the server pushes a `session-update` SSE event to all connected clients.

The SSE event payload is a simple `reload` signal — the client re-fetches `/api/sessions` to get the full updated list. This avoids the complexity of incremental updates while keeping the protocol simple.

---

## Feature C: Browser dashboard

### Tech stack

| Layer | Choice | Rationale |
|---|---|---|
| **Framework** | Vue.js 3 (Composition API) | User preference; reactive data binding fits well with SSE-driven updates |
| **Build tool** | Vite | Fast HMR in dev; produces static assets for production |
| **Styling** | CSS (scoped, in SFCs) | No Tailwind/framework needed for ~3 component types |
| **Deployment** | Static files served by Express server | Built `dist/` served via `express.static` at `http://127.0.0.1:3847` |

### UI layout

```
┌──────────────────────────────────────────────────────────┐
│  Claude Code Dashboard                      ● Connected  │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ankorstore                                              │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐     │
│  │🟢 auth-refac │ │✅ api-tests  │ │⚠️ db-migrat  │     │
│  │ 2m ago       │ │ 5m ago       │ │ just now     │     │
│  │ "Completed…" │ │ "All tests…" │ │ Needs input  │     │
│  │ [Open] [Copy]│ │ [Open] [Copy]│ │ [Open] [Copy]│     │
│  └──────────────┘ └──────────────┘ └──────────────┘     │
│                                                          │
│  claude-dashboard                                        │
│  ┌──────────────┐                                        │
│  │🟢 dashboar…  │                                        │
│  │ just now     │                                        │
│  │ "Writing…"   │                                        │
│  │ [Open] [Copy]│                                        │
│  └──────────────┘                                        │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### Grouping and sorting

- **Sessions are grouped by project.** The project name is the last segment of `cwd` (e.g. `/Users/tomas/projects/ankorstore` → `ankorstore`).
- **Project groups** with no active sessions disappear from the dashboard.
- **Cards have fixed positions within their group.** Position is determined by creation order (`created_at` timestamp). First session created = first card. New sessions append to the end. **Cards never reorder** — this preserves spatial memory so the user always knows where to look.

### Card anatomy

Each session card displays:

| Element | Content | Behavior |
|---|---|---|
| **Status indicator** | Emoji (🟢/✅/⚠️/❌/🔄) | Static, no animation |
| **Session name** | Human-readable name from state file | Truncated with ellipsis if > 15 chars |
| **Last activity** | Relative time ("2m ago", "just now") | Updates every 30s on the client |
| **Preview** | Plain text, first ~80 chars of last assistant message | Stripped of all markdown formatting |
| **Left border** | 4px solid color matching status | Static color, no pulse/animation |
| **"Open" button** | Primary action | Opens `vscode://anthropic.claude-code/open?session=<id>` |
| **"Copy ID" button** | Secondary action | Copies session ID to clipboard |
| **Stale indicator** | "Session ended unexpectedly" | Shown when `alive: false` from server; card grayed out |

### Card status colors

| Status | Left border color | Card background |
|---|---|---|
| 🟢 Working | `#27AE60` (green) | Default |
| ✅ Done | `#3498DB` (blue) | Default |
| ⚠️ Attention | `#F39C12` (amber) | Default |
| ❌ Error | `#E74C3C` (red) | Default |
| 🔄 Starting | `#95A5A6` (gray) | Default |
| Stale (alive: false) | `#BDC3C7` (light gray) | Grayed out (opacity: 0.5) |

### Theme

Respects `prefers-color-scheme` media query. Automatically matches OS light/dark mode.

| Token | Light | Dark |
|---|---|---|
| Background | `#FFFFFF` | `#1A1A2E` |
| Card background | `#F8F9FA` | `#16213E` |
| Text primary | `#2C3E50` | `#ECF0F1` |
| Text secondary | `#7F8C8D` | `#95A5A6` |
| Border | `#E0E0E0` | `#2C3E50` |

### Connection status

The dashboard header shows a connection indicator:
- **● Connected** (green dot): SSE connection is active.
- **● Reconnecting…** (amber dot): SSE connection lost, auto-reconnecting.
- **● Disconnected** (red dot): Server unreachable after retries.

SSE reconnection uses `EventSource` built-in reconnection with a 3-second retry interval.

### Auto-refresh

The dashboard connects to `/api/events` SSE endpoint. On every `session-update` event, it re-fetches `/api/sessions` and reactively updates the card grid. Relative timestamps ("2m ago") refresh every 30 seconds via a client-side interval.

---

## Feature D: Deep-linking to VS Code

### Primary action: "Open" button

Each card's "Open" button triggers:

```javascript
window.open(`vscode://anthropic.claude-code/open?session=${sessionId}`)
```

This opens (or resumes) the Claude Code session in VS Code. When invoked:
1. macOS dispatches the URI to VS Code via the registered URI scheme handler.
2. The Claude Code VS Code extension receives the URI and activates the corresponding session.
3. The VS Code window comes to the foreground.

### Known limitation

If the session is already running in a terminal tab, the URI handler may open a **new** tab rather than focusing the existing one. This is a known limitation of the current `vscode://` URI handler. The dashboard communicates this via the two-action card design — "Open" for the URI link, "Copy ID" for manual session management.

### Secondary action: "Copy ID" button

Copies the `session_id` to the clipboard. Useful for:
- Manually resuming a session via `claude --resume <session_id>`
- Searching for the session in VS Code's terminal list
- Debugging state file issues

### Deep-link strategy (future)

| Scenario | Strategy | Phase |
|---|---|---|
| Browser → open/resume session | `vscode://` URI (Phase 4, **in scope**) | Current |
| In-VS Code notification + click to focus | `vscode-terminal-osc-notifier` extension | Phase 5 (future) |
| Browser → focus specific running terminal | Custom VS Code extension with HTTP endpoint | Phase 6 (future) |

---

## Prerequisites

### VS Code settings

```json
{
  "terminal.integrated.tabs.title": "${sequence}",
  "terminal.integrated.tabs.description": "${task}${separator}${local}"
}
```

These settings ensure VS Code uses the OSC 0 escape sequence (emitted by the hook script) as the terminal tab title.

### VS Code extensions

| Extension | Purpose | Required? |
|---|---|---|
| `anthropic.claude-code` | Claude Code VS Code extension (provides `vscode://` URI handler) | Required for deep-links |
| `wenbopan.vscode-terminal-osc-notifier` | Parse OSC 9/777 from terminals → VS Code notifications | Optional (Phase 5) |

### Dependencies (local machine)

| Tool | Purpose | Install |
|---|---|---|
| `jq` | Parse hook JSON stdin in bash | `brew install jq` |
| `node` (18+) | Run the API server and build the dashboard | Pre-installed for Claude Code |

---

## File structure

```
~/.claude/
  hooks/
    tab-state.sh              # Main hook script (all events)
  tab-state/                  # Per-session state directory (auto-created)
    <session_id>.json         # Session state files
  dashboard/
    server.js                 # Express API server
    dist/                     # Built Vue.js dashboard (served as static)
    server.log                # Server log output
    package.json              # Server dependencies (express, chokidar)
  settings.json               # Hook configuration (merged with existing)

~/Projects/claude-dashboard/  # Source repository
  server/
    server.js                 # Express server source
    package.json
  dashboard/
    src/
      App.vue                 # Root component
      components/
        SessionCard.vue       # Individual session card
        ProjectGroup.vue      # Project grouping wrapper
        ConnectionStatus.vue  # SSE connection indicator
      composables/
        useSessions.js        # SSE + fetch logic
        useRelativeTime.js    # "2m ago" formatting
    index.html
    vite.config.js
    package.json
  hooks/
    tab-state.sh              # Hook script source
  install.sh                  # Copies files to ~/.claude/, installs deps
  README.md
```

### Installation

Distribution is a simple file copy. An `install.sh` script:
1. Creates `~/.claude/tab-state/` directory
2. Copies `hooks/tab-state.sh` to `~/.claude/hooks/tab-state.sh`
3. Builds the Vue.js dashboard (`npm run build`) and copies `dist/` to `~/.claude/dashboard/dist/`
4. Copies `server/server.js` and `server/package.json` to `~/.claude/dashboard/`
5. Runs `npm install --production` in `~/.claude/dashboard/`
6. Prints instructions for merging hook configuration into `~/.claude/settings.json`

---

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| State file race conditions | Stale data | Atomic writes (write to `.tmp`, then `mv`). Last-write-wins. Hooks have a 60s timeout so overlap is unlikely. |
| `vscode://` URI opens new tab instead of focusing existing | Duplicate tabs | Document this limitation. Two-action card design (Open + Copy ID) gives user alternatives. Phase 6 extension solves it. |
| Server port conflict (3847) | Dashboard won't start | Make port configurable via `PORT` env var. Check if port is in use on startup and log a clear error. |
| Stale state files from crashed sessions | Ghost entries | PID-based liveness check every 60s annotates dead sessions. `SessionEnd` hook cleans up normally. Server prunes files older than 24h on startup. |
| Multiple VS Code windows | Ambiguous which window to focus | `vscode://` scheme routes to the window that owns the workspace. Dashboard groups by project to provide context. |
| Hook script performance | Sluggish Claude Code UX | Target < 200ms. No network calls. Minimal jq + file write. Server health check uses curl with 1s timeout. |
| Server auto-launch race condition | Two hooks both try to start the server | Use a PID file (`~/.claude/dashboard/server.pid`). The hook checks the PID file before starting. If PID is alive, skip. |

---

## Success metrics

- **Session identification:** Reduce time to find the right terminal from ~5s (click through each) to <1s (glance at dashboard).
- **Status awareness:** At a glance, tell which of 3–5 terminals need attention without clicking into VS Code.
- **Deep-link success rate:** Dashboard click should land in the correct VS Code window/session 90%+ of the time.
- **Hook latency:** < 200ms per hook invocation measured end-to-end.
- **Dashboard freshness:** State changes reflected in the browser within 500ms (300ms server debounce + network).

---

## Milestones

| Phase | Deliverable | Effort | Priority |
|---|---|---|---|
| **1** | Hook scripts: state files + OSC tab titles + server auto-launch | 2–3h | P0 |
| **2** | Express server: JSON API + SSE + PID liveness + file watching | 2–3h | P0 |
| **3** | Vue.js dashboard: cards, grouping, SSE, theme, connection status | 3–4h | P0 |
| **4** | `vscode://` deep-links + Copy ID from dashboard cards | 1h | P1 |

**Total estimated effort:** ~9–11 hours.

---

## Future directions

- **OSC 9 notifications (Phase 5):** Emit OSC 9 from hooks for in-VS Code notification support via `vscode-terminal-osc-notifier`.
- **Custom VS Code extension (Phase 6):** HTTP endpoint for `terminal.show()` by name — solves the "focus existing tab" problem definitively.
- **macOS menu bar widget:** Wrap the dashboard in an Electron tray app or SwiftUI menu bar extra for always-on visibility.
- **AI-generated session names:** Use Haiku to derive meaningful 2–4 word labels from first assistant message.
- **Agent team awareness:** With `SubagentStart`/`SubagentStop` hooks, show active subagents per session.
- **Color-coded terminal tabs:** VS Code `terminal.integrated.tabs.defaultColor` support via custom extension.
