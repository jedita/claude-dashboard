# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A browser-based dashboard for monitoring active Claude Code sessions running in VS Code terminals. It shows session status, supports deep-linking back to the originating terminal tab, and updates in real-time via Server-Sent Events (SSE).

## Architecture

Three components work together using a **hybrid session discovery** model:

1. **Backend server** (`server/server.js`) — Express.js server on port 3847 (localhost only). **Primary session discovery**: watches `~/.claude/sessions/` (Claude Code's native session registry) and creates tab-state entries for any new sessions. Also watches `~/.claude/tab-state/` for hook-driven updates. Serves a REST API (`/api/sessions`, `/api/health`) and broadcasts changes over SSE (`/api/events`). Checks PID liveness every 60 seconds.

2. **Hook script** (`hooks/tab-state.sh`) — Bash script triggered by Claude Code lifecycle events. The `SessionStart` hook only auto-launches the server and opens the browser (no `jq` needed). Enrichment hooks (`UserPromptSubmit`, `Stop`, `StopFailure`, `Notification`, `SessionEnd`) update existing tab-state files with status changes, AI-generated names, message previews, and terminal tab titles via OSC 0 escape sequences. These hooks require `jq` but are optional — if they fail, sessions still appear via native discovery.

3. **Frontend dashboard** (`dashboard/`) — Vue 3 + Vite SPA. Uses Composition API with composables (`useSessions.js`, `useRelativeTime.js`). Sessions are grouped by project directory. Supports light/dark mode via CSS variables and `prefers-color-scheme`.

## Development Commands

### Frontend (dashboard/)
```bash
cd dashboard && npm install
npm run dev      # Vite dev server on http://localhost:5173 (proxies /api to :3847)
npm run build    # Production build to dist/
npm run preview  # Preview production build
```

### Backend (server/)
```bash
cd server && npm install
npm start        # or: node server.js — runs on http://127.0.0.1:3847
```

### Running locally
Run the server and dashboard dev server in separate terminals. The Vite config proxies `/api` requests to the backend.

### Testing hooks manually
```bash
# Test init (server launch only, no jq needed):
echo '{}' | bash hooks/tab-state.sh init

# Test enrichment hooks (requires jq):
echo '{"session_id":"test-123","prompt":"hello"}' | bash hooks/tab-state.sh working
```

### Full installation
```bash
bash install.sh  # Installs hooks, builds dashboard, copies to ~/.claude/
```

## Key Technical Details

- **Session discovery** uses Claude's native `~/.claude/sessions/<pid>.json` files (always written by Claude Code). The server creates tab-state entries from these. Enrichment hooks update tab-state with richer data when available.
- **State files** are JSON at `~/.claude/tab-state/<session_id>.json` with fields: `version`, `session_id`, `name`, `status`, `cwd`, `pid`, `last_activity`, `last_message_preview`, `created_at`. The `alive` field is computed by the server.
- **Session statuses**: `starting`, `working`, `done`, `error`, `attention`
- **Hook dependencies**: The `init` hook needs only `curl` and `node`. Enrichment hooks (`working`, `stop`, `error`, `attention`, `cleanup`) require `jq`. If `jq` is unavailable, sessions still appear via native discovery but without enriched status/names.
- **No test framework** is configured — test scenarios are documented in `test-scenarios.md` for manual verification.
- **No linter** is configured.
- **No root `package.json`** — dependencies must be installed separately in `dashboard/` and `server/`.
- **Plain JavaScript** throughout (no TypeScript).
- **Backend port** configurable via `PORT` env var (default 3847).
- **No root `.gitignore`** — only `dashboard/.gitignore` exists.
- The server serves the built dashboard static files in production; in development, Vite's dev server handles the frontend with API proxying.
