#!/usr/bin/env node
'use strict';

const express = require('express');
const fs = require('fs');
const path = require('path');
const os = require('os');

// --- Configuration ---
const PORT = parseInt(process.env.PORT, 10) || 3847;
const BIND_ADDRESS = '127.0.0.1';
const STATE_DIR = path.join(os.homedir(), '.claude', 'tab-state');
const SESSIONS_DIR = path.join(os.homedir(), '.claude', 'sessions');
const DASHBOARD_DIR = path.join(os.homedir(), '.claude', 'dashboard');
const PID_FILE = path.join(DASHBOARD_DIR, 'server.pid');
const SSE_DEBOUNCE_MS = 300;
const PID_LIVENESS_INTERVAL_MS = 60_000;
const PRUNE_AGE_MS = 24 * 60 * 60 * 1000; // 24 hours
const DEAD_SESSION_GRACE_MS = 5 * 60 * 1000; // 5 minutes after last activity before removing dead sessions

// --- Ensure directories exist ---
fs.mkdirSync(STATE_DIR, { recursive: true });
fs.mkdirSync(DASHBOARD_DIR, { recursive: true });

// --- Startup pruning: remove state files older than 24h ---
function pruneOldStateFiles() {
  const now = Date.now();
  try {
    const files = fs.readdirSync(STATE_DIR);
    for (const file of files) {
      if (!file.endsWith('.json')) continue;
      const filePath = path.join(STATE_DIR, file);
      try {
        const stat = fs.statSync(filePath);
        if (now - stat.mtimeMs > PRUNE_AGE_MS) {
          fs.unlinkSync(filePath);
          console.log(`Pruned stale state file: ${file}`);
        }
      } catch (err) {
        // File may have been deleted between readdir and stat
      }
    }
  } catch (err) {
    // STATE_DIR may not exist yet — that's fine
  }
}

pruneOldStateFiles();

// --- Write PID file ---
fs.writeFileSync(PID_FILE, String(process.pid));
process.on('exit', () => {
  try { fs.unlinkSync(PID_FILE); } catch (_) {}
});
function gracefulShutdown(signal) {
  const sessions = readAllSessions();
  const activeSessions = sessions.filter(s => s.pid && checkPidAlive(s.pid));
  if (activeSessions.length > 0) {
    console.log(`Received ${signal} but ${activeSessions.length} active session(s) — ignoring`);
    return;
  }
  console.log(`Received ${signal} with no active sessions — shutting down`);
  process.exit(0);
}

process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));

// --- PID liveness cache ---
const pidLivenessCache = new Map();

function checkPidAlive(pid) {
  if (typeof pid !== 'number' || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

function refreshPidLiveness() {
  const sessions = readAllSessions();
  for (const session of sessions) {
    if (session.pid) {
      pidLivenessCache.set(session.pid, checkPidAlive(session.pid));
    }
  }
}

// --- Read session state files ---
function readAllSessions() {
  const sessions = [];
  let files;
  try {
    files = fs.readdirSync(STATE_DIR);
  } catch (err) {
    return sessions;
  }

  for (const file of files) {
    if (!file.endsWith('.json')) continue;
    if (file.startsWith('.')) continue;
    const filePath = path.join(STATE_DIR, file);
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      const data = JSON.parse(content);
      sessions.push(data);
    } catch (err) {
      console.warn(`Skipping invalid state file: ${file}`);
    }
  }

  return sessions;
}

function getSessionsWithLiveness() {
  const sessions = readAllSessions();
  return sessions.map(session => {
    let alive;
    if (session.pid) {
      if (pidLivenessCache.has(session.pid)) {
        alive = pidLivenessCache.get(session.pid);
      } else {
        alive = checkPidAlive(session.pid);
        pidLivenessCache.set(session.pid, alive);
      }
    } else {
      alive = false;
    }
    return { ...session, alive };
  });
}

// --- SSE broadcast (moved up so native session sync can use it) ---
let debounceTimer = null;

function scheduleSSEBroadcast() {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }
  debounceTimer = setTimeout(() => {
    debounceTimer = null;
    broadcastSSE('session-update', { type: 'reload' });
  }, SSE_DEBOUNCE_MS);
}

// --- Native session discovery ---
// Claude Code writes session files to ~/.claude/sessions/<pid>.json for every
// session, regardless of how Claude was launched. We watch this directory and
// create tab-state entries for any sessions that don't already have one. This
// ensures sessions started via VS Code shortcuts (where hooks may fail) still
// appear on the dashboard. Enrichment hooks (working, stop, error, attention)
// can then update the tab-state file with richer data when they do fire.

function syncNativeSessions() {
  let nativeFiles;
  try {
    nativeFiles = fs.readdirSync(SESSIONS_DIR);
  } catch (err) {
    return; // sessions dir may not exist
  }

  let created = 0;
  for (const file of nativeFiles) {
    if (!file.endsWith('.json')) continue;
    const filePath = path.join(SESSIONS_DIR, file);
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      const native = JSON.parse(content);
      if (!native.sessionId || !native.pid) continue;

      // Check if tab-state file already exists for this session
      const safeId = native.sessionId.replace(/[^a-zA-Z0-9_-]/g, '_');
      const stateFile = path.join(STATE_DIR, `${safeId}.json`);
      if (fs.existsSync(stateFile)) continue;

      // Derive session name from cwd basename + short session ID
      const cwd = native.cwd || '';
      const dirName = cwd ? path.basename(cwd) : 'unknown';
      const shortId = native.sessionId.slice(0, 4);
      const name = `${dirName}-${shortId}`;

      // Convert startedAt (ms epoch) to ISO 8601
      const createdAt = native.startedAt
        ? new Date(native.startedAt).toISOString()
        : new Date().toISOString();

      const state = {
        version: 1,
        session_id: native.sessionId,
        name,
        status: 'starting',
        cwd,
        pid: native.pid,
        last_activity: createdAt,
        last_message_preview: '',
        created_at: createdAt,
        ai_name_generated: false,
        tty_path: '',
      };

      fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
      created++;
      console.log(`Created tab-state from native session: ${native.sessionId} (pid ${native.pid})`);
    } catch (err) {
      // Skip unreadable native session files
    }
  }

  if (created > 0) {
    scheduleSSEBroadcast();
  }
}

// Watch native sessions directory for new/removed session files
let sessionsSyncTimer = null;

function scheduleSyncNativeSessions() {
  if (sessionsSyncTimer) {
    clearTimeout(sessionsSyncTimer);
  }
  sessionsSyncTimer = setTimeout(() => {
    sessionsSyncTimer = null;
    syncNativeSessions();
  }, SSE_DEBOUNCE_MS);
}

try {
  fs.watch(SESSIONS_DIR, (eventType, filename) => {
    if (!filename) return;
    if (filename.endsWith('.json')) {
      scheduleSyncNativeSessions();
    }
  });
} catch (err) {
  console.warn('Could not watch native sessions directory:', err.message);
}

// Sync on startup to catch sessions that started before the server
syncNativeSessions();

// --- Static file serving ---
const DIST_DIR = path.join(DASHBOARD_DIR, 'dist');

// --- Express app ---
const app = express();

// Health endpoint — B1.1, B1.2
app.get('/api/health', (req, res) => {
  res.json({ ok: true });
});

// Sessions endpoint — B2.1–B2.6
app.get('/api/sessions', (req, res) => {
  const sessions = getSessionsWithLiveness();
  res.json(sessions);
});

// Dismiss a session — removes its state file
app.delete('/api/sessions/:id', (req, res) => {
  const safeId = req.params.id.replace(/[^a-zA-Z0-9_-]/g, '_');
  const filePath = path.join(STATE_DIR, `${safeId}.json`);
  try {
    fs.unlinkSync(filePath);
    res.json({ ok: true });
  } catch (err) {
    if (err.code === 'ENOENT') {
      res.status(404).json({ error: 'Session not found' });
    } else {
      res.status(500).json({ error: err.message });
    }
  }
});

// SSE endpoint — B3.1–B3.6
const sseClients = new Set();

app.get('/api/events', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  res.write('retry: 3000\n\n');
  sseClients.add(res);

  req.on('close', () => {
    sseClients.delete(res);
  });
});

function broadcastSSE(eventName, data) {
  const payload = `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const client of sseClients) {
    client.write(payload);
  }
}

// --- Serve static dashboard files (B6.1, B6.2) ---
if (fs.existsSync(DIST_DIR)) {
  app.use(express.static(DIST_DIR));
  // SPA fallback: serve index.html for non-API routes
  app.get(/^(?!\/api).*/, (req, res) => {
    res.sendFile(path.join(DIST_DIR, 'index.html'));
  });
}

// --- File watching with fs.watch ---
fs.watch(STATE_DIR, (eventType, filename) => {
  if (!filename) return;
  if (filename.endsWith('.json') && !filename.startsWith('.')) {
    scheduleSSEBroadcast();
  }
});

// --- Auto-prune dead sessions past grace period ---
function pruneDeadSessions() {
  const now = Date.now();
  const sessions = readAllSessions();
  for (const session of sessions) {
    if (!session.pid || !session.session_id) continue;
    const alive = checkPidAlive(session.pid);
    if (alive) continue;

    // Check if last_activity is old enough past the grace period
    const lastActivity = session.last_activity ? new Date(session.last_activity).getTime() : 0;
    if (now - lastActivity > DEAD_SESSION_GRACE_MS) {
      const safeId = session.session_id.replace(/[^a-zA-Z0-9_-]/g, '_');
      const filePath = path.join(STATE_DIR, `${safeId}.json`);
      try {
        fs.unlinkSync(filePath);
        console.log(`Auto-pruned dead session: ${session.session_id} (pid ${session.pid})`);
      } catch (err) {
        // File may already be gone
      }
    }
  }
}

// --- PID liveness check interval — B4.1 ---
setInterval(() => {
  syncNativeSessions();
  refreshPidLiveness();
  pruneDeadSessions();
  broadcastSSE('session-update', { type: 'reload' });
}, PID_LIVENESS_INTERVAL_MS);

// --- Start server ---
const server = app.listen(PORT, BIND_ADDRESS, () => {
  console.log(`Claude Dashboard server listening on http://${BIND_ADDRESS}:${PORT}`);
  console.log(`Watching state files in: ${STATE_DIR}`);
  console.log(`Watching native sessions in: ${SESSIONS_DIR}`);
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Error: Port ${PORT} is already in use. Set PORT env var to use a different port.`);
    process.exit(1);
  }
  throw err;
});
