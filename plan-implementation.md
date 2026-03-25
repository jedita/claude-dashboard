# Implementation Plan: Claude Code Terminal Dashboard

**Created:** 2026-03-25 · **Based on:** prd-claude-code-terminal-dashboard.md

---

## Guiding principles

1. **Smallest testable MVP first.** Each slice should be something the user can run, see, and validate before moving on.
2. **Each slice is independently useful.** Even if you stop after slice 1, you get value (terminal tab titles showing status).
3. **No big bang.** The dashboard doesn't appear fully-formed in the last step — the user sees progress at every stage.

---

## Context & key decisions

### What this is
A local-only, browser-based dashboard that gives a bird's-eye view of all active Claude Code terminal sessions. It reads hook-generated state files and displays live session cards grouped by project, with deep-links back to VS Code.

### What this is NOT
- Not a VS Code extension (no extension API needed)
- Not a cloud service (everything runs on localhost)
- Not a replacement for the terminal (it's a companion view)

### Critical product assumptions
- The user runs 3–5 concurrent Claude Code sessions in VS Code terminals
- The user has `jq` and Node.js 18+ installed
- The user is on macOS (OSC escape sequences, `vscode://` URI scheme)
- State files are ephemeral — losing them is fine; they rebuild on next hook event

### Key UX decisions from the PRD
- **Cards never reorder** — spatial memory is preserved (sorted by `created_at`)
- **Grouped by project** (last segment of `cwd`) — projects with no active sessions disappear
- **No animations** — status emoji + colored left border are the visual indicators
- **Light/dark theme** follows OS `prefers-color-scheme` automatically
- **Two actions per card:** "Open" (deep-link) and "Copy ID" (clipboard)

---

## Implementation slices

### Slice 1: Hook script — state files + terminal tab titles

**What the user can test:** Run Claude Code in a terminal, see the terminal tab title change with status emoji, and inspect `~/.claude/tab-state/<id>.json` files appearing on disk.

**Scope:**
- `hooks/tab-state.sh` — the single bash script handling all 6 events
- Atomic writes (`.tmp` → `mv`)
- OSC 0 escape sequence for terminal tab titles
- Session name from `CLAUDE_SESSION_NAME` env var or `<dir>-<short_id>` fallback
- Markdown stripping for `last_message_preview` (sed-based)
- `SessionEnd` → cleanup (delete state file)
- Create `~/.claude/tab-state/` directory if missing

**NOT in this slice:**
- Server auto-launch (the `curl` health check + `nohup node` part) — added in Slice 3
- Hook configuration in `settings.json` — documented as manual step, scripted in Slice 6

**How to test:**
1. Manually pipe test JSON into the script: `echo '{"session_id":"abc-123","cwd":"/tmp/test"}' | bash hooks/tab-state.sh init`
2. Check `~/.claude/tab-state/abc-123.json` exists with correct fields
3. Register hooks manually in `~/.claude/settings.json`, start a Claude Code session, verify state file appears
4. Verify terminal tab title shows emoji + session name

**Done when:** State files reliably appear/update/disappear across the full session lifecycle (start → work → stop → end).

---

### Slice 2: Express server — JSON API + file watching + SSE

**What the user can test:** Start the server, `curl http://127.0.0.1:3847/api/sessions` and see session data. Open two terminal tabs, watch SSE events arrive in real-time via `curl http://127.0.0.1:3847/api/events`.

**Scope:**
- `server/server.js` + `server/package.json` (express, chokidar)
- `GET /api/health` — `{ "ok": true }`
- `GET /api/sessions` — reads all `~/.claude/tab-state/*.json`, returns array with `alive` boolean
- `GET /api/events` — SSE stream, pushes `session-update` event on file changes (300ms debounce)
- PID liveness check every 60s (annotates response, doesn't modify files)
- Startup pruning: remove state files older than 24h
- Bind to `127.0.0.1:3847` (configurable via `PORT`)
- PID file at `~/.claude/dashboard/server.pid` for preventing duplicate starts

**NOT in this slice:**
- Serving the dashboard static files (no `dist/` yet)
- Auto-launch from hooks

**How to test:**
1. Start server manually: `node server/server.js`
2. In another terminal, trigger hooks → state files appear
3. `curl http://127.0.0.1:3847/api/sessions` — verify JSON response
4. `curl -N http://127.0.0.1:3847/api/events` — verify SSE events fire when state files change
5. Kill a Claude Code process, wait 60s, verify `alive: false` appears in session data

**Done when:** API returns correct, live session data and SSE events fire within ~500ms of state file changes.

---

### Slice 3: Hook → server auto-launch

**What the user can test:** Start a Claude Code session with no server running. The hook automatically starts the server in the background. Subsequent sessions reuse the existing server.

**Scope:**
- Add server health check + auto-launch logic to `tab-state.sh` `init` event
- `curl -s --max-time 1 http://127.0.0.1:3847/api/health` → if fails, start server
- `nohup node ~/.claude/dashboard/server.js >> ~/.claude/dashboard/server.log 2>&1 &`
- Write PID to `~/.claude/dashboard/server.pid`
- Race condition guard: check PID file before starting

**How to test:**
1. Ensure server is NOT running
2. Start a Claude Code session (or simulate with `echo ... | bash hooks/tab-state.sh init`)
3. Verify server starts (check `curl http://127.0.0.1:3847/api/health`)
4. Start a second session — verify no duplicate server process

**Done when:** Server reliably auto-starts on first session and doesn't duplicate.

---

### Slice 4: Browser dashboard — static cards (no SSE yet)

**What the user can test:** Open `http://127.0.0.1:3847` in a browser, see session cards grouped by project with correct status, colors, and relative timestamps.

**Scope:**
- Vue.js 3 + Vite project scaffold (`dashboard/`)
- `App.vue` — layout, header, project groups
- `SessionCard.vue` — status emoji, name, relative time, preview, left border color
- `ProjectGroup.vue` — groups cards by last segment of `cwd`
- `useRelativeTime.js` composable — "just now", "2m ago", etc. (refreshes every 30s)
- `useSessions.js` composable — initial `fetch('/api/sessions')` only (no SSE yet)
- Light/dark theme via `prefers-color-scheme`
- Cards sorted by `created_at` within each group (never reorder)
- Stale card styling (grayed out when `alive: false`)
- Express serves `dist/` as static files at root

**NOT in this slice:**
- SSE live updates (next slice)
- Deep-links / button actions (Slice 6)
- Connection status indicator (Slice 5)

**How to test:**
1. Have 2–3 Claude Code sessions running (or mock state files)
2. Build dashboard: `cd dashboard && npm run build`
3. Copy `dist/` to server location, restart server
4. Open `http://127.0.0.1:3847` — verify cards appear, grouped correctly
5. Toggle OS dark mode — verify theme switches

**Done when:** Dashboard renders all active sessions with correct grouping, status colors, and relative times. Manual refresh shows updated data.

---

### Slice 5: Live updates — SSE + connection status

**What the user can test:** Dashboard updates in real-time without manual refresh. Connection indicator shows green/amber/red based on SSE state.

**Scope:**
- `useSessions.js` — add `EventSource` connection to `/api/events`, re-fetch on `session-update`
- `ConnectionStatus.vue` — green "Connected", amber "Reconnecting…", red "Disconnected"
- Auto-reconnect via `EventSource` built-in (3s retry)

**How to test:**
1. Open dashboard in browser
2. Start a new Claude Code session → card appears without refresh
3. Session changes status → card updates live
4. Stop the server → indicator turns amber/red
5. Restart server → indicator turns green, data refreshes

**Done when:** Dashboard is fully live — no manual refresh needed, and connection state is visible.

---

### Slice 6: Deep-links + actions + install script

**What the user can test:** Click "Open" on a card → VS Code opens/resumes that session. Click "Copy ID" → session ID in clipboard. Run `install.sh` to set everything up.

**Scope:**
- "Open" button: `window.open('vscode://anthropic.claude-code/open?session=<id>')`
- "Copy ID" button: `navigator.clipboard.writeText(sessionId)` with brief "Copied!" feedback
- `install.sh` script:
  - Creates directories
  - Copies hook script, server files, built dashboard
  - Installs server dependencies
  - Prints instructions for merging hooks into `~/.claude/settings.json`
- Document VS Code settings needed (`terminal.integrated.tabs.title: "${sequence}"`)

**How to test:**
1. Click "Open" on a card → VS Code activates
2. Click "Copy ID" → paste confirms correct ID
3. Run `install.sh` on a clean machine → everything works

**Done when:** Full end-to-end flow works: sessions appear, update live, deep-links work, and installation is scripted.

---

## Slice dependency graph

```
Slice 1 (Hooks)
    │
    ▼
Slice 2 (Server API)
    │
    ├──────────────────┐
    ▼                  ▼
Slice 3 (Auto-launch)  Slice 4 (Dashboard static)
                           │
                           ▼
                       Slice 5 (SSE + live updates)
                           │
                           ▼
                       Slice 6 (Deep-links + install)
```

Slices 3 and 4 can be done in parallel after Slice 2.

---

## What you get at each slice

| After slice | User experience |
|---|---|
| **1** | Terminal tabs show emoji + session name. State files on disk (inspectable but not visible in UI). |
| **2** | Can `curl` the API to see all sessions as JSON. SSE stream works. |
| **3** | Server auto-starts — no manual `node server.js` needed. |
| **4** | Browser dashboard shows all sessions with grouping, status, and theme. Requires manual refresh. |
| **5** | Dashboard is fully live — updates in real-time, shows connection health. |
| **6** | Click-to-open in VS Code works. One-command install. Production-ready. |

---

## Risk callouts

1. **`vscode://` URI may open new tab instead of focusing existing** — This is a known limitation documented in the PRD. The "Copy ID" button is the fallback. No mitigation needed in Phase 1–4.

2. **Hook performance budget (< 200ms)** — The `curl` health check in Slice 3 adds latency. Use `--max-time 1` and only check on `init` (not every event). All other events are just `jq` + file write.

3. **Chokidar on macOS** — `fsevents` native module is fast but can emit duplicate events. The 300ms debounce in the server handles this.

4. **Port conflict** — If 3847 is in use, the server should fail fast with a clear error message, not hang.

---

## Open questions for the implementer

1. **Should the install script auto-merge hooks into `settings.json`?** The PRD says "prints instructions." Auto-merge is riskier (could corrupt existing config) but more convenient. Recommendation: print instructions for now, auto-merge as a future improvement.

2. **Should the server serve the Vite dev server in development?** For faster iteration during development, the dashboard could use Vite's dev server with a proxy to the API. This isn't in the PRD but would speed up Slice 4–5 development. Recommendation: yes, add a `vite.config.js` proxy for `/api` → `localhost:3847`.

3. **State file format versioning?** If the format changes later (e.g., adding subagent data), old files could break parsing. Recommendation: add a `"version": 1` field to state files now. Low cost, high future value.
