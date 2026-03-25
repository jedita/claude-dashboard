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
const DASHBOARD_DIR = path.join(os.homedir(), '.claude', 'dashboard');
const PID_FILE = path.join(DASHBOARD_DIR, 'server.pid');
const SSE_DEBOUNCE_MS = 300;
const PID_LIVENESS_INTERVAL_MS = 60_000;
const PRUNE_AGE_MS = 24 * 60 * 60 * 1000; // 24 hours

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
process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));

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

// SSE endpoint — B3.1–B3.6
const sseClients = new Set();

app.get('/api/events', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  res.write(':connected\n\n');
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

fs.watch(STATE_DIR, (eventType, filename) => {
  if (!filename) return;
  if (filename.endsWith('.json') && !filename.startsWith('.')) {
    scheduleSSEBroadcast();
  }
});

// --- PID liveness check interval — B4.1 ---
setInterval(() => {
  refreshPidLiveness();
  broadcastSSE('session-update', { type: 'reload' });
}, PID_LIVENESS_INTERVAL_MS);

// --- Start server ---
const server = app.listen(PORT, BIND_ADDRESS, () => {
  console.log(`Claude Dashboard server listening on http://${BIND_ADDRESS}:${PORT}`);
  console.log(`Watching state files in: ${STATE_DIR}`);
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Error: Port ${PORT} is already in use. Set PORT env var to use a different port.`);
    process.exit(1);
  }
  throw err;
});
