#!/usr/bin/env node
"use strict";

const express = require("express");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawn } = require("child_process");

// --- Configuration ---
const PORT = parseInt(process.env.PORT, 10) || 3847;
const BIND_ADDRESS = "127.0.0.1";
const STATE_DIR = path.join(os.homedir(), ".claude", "tab-state");
const SESSIONS_DIR = path.join(os.homedir(), ".claude", "sessions");
const DASHBOARD_DIR = path.join(os.homedir(), ".claude", "dashboard");
const PID_FILE = path.join(DASHBOARD_DIR, "server.pid");
const SSE_DEBOUNCE_MS = 300;
const PID_LIVENESS_INTERVAL_MS = 15_000;
const PRUNE_AGE_MS = 24 * 60 * 60 * 1000; // 24 hours
const DEAD_SESSION_GRACE_MS = 2 * 60 * 1000; // 2 minutes after last activity before removing dead sessions
const CONFIG_FILE = path.join(__dirname, "..", "dashboard", "public", "config.json");
// Also check the built dashboard location
const CONFIG_FILE_DIST = path.join(DASHBOARD_DIR, "dist", "config.json");

// --- Ensure directories exist ---
fs.mkdirSync(STATE_DIR, { recursive: true });
fs.mkdirSync(DASHBOARD_DIR, { recursive: true });

// --- Startup pruning: remove state files older than 24h ---
function pruneOldStateFiles() {
  const now = Date.now();
  try {
    const files = fs.readdirSync(STATE_DIR);
    for (const file of files) {
      if (!file.endsWith(".json")) continue;
      if (file.endsWith(".user.json")) continue; // Never prune user-data files by age
      const filePath = path.join(STATE_DIR, file);
      try {
        const stat = fs.statSync(filePath);
        if (now - stat.mtimeMs > PRUNE_AGE_MS) {
          // Check if this session has annotations — if so, preserve it
          const sessionId = file.replace(/\.json$/, "");
          const userData = readUserData(sessionId);
          if (hasAnnotations(userData)) continue;

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
process.on("exit", () => {
  try {
    fs.unlinkSync(PID_FILE);
  } catch (_) {}
});
function gracefulShutdown(signal) {
  console.log(`Received ${signal} — shutting down`);
  process.exit(0);
}

process.on("SIGINT", () => gracefulShutdown("SIGINT"));
process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));

// --- PID liveness cache ---
const pidLivenessCache = new Map();

function checkPidAlive(pid) {
  if (typeof pid !== "number" || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === "EPERM";
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

// --- Config reader ---
function readConfig() {
  for (const cfgPath of [CONFIG_FILE, CONFIG_FILE_DIST]) {
    try {
      const content = fs.readFileSync(cfgPath, "utf8");
      return JSON.parse(content);
    } catch (_) {}
  }
  return {};
}

// --- User-data file helpers ---
function userDataPath(sessionId) {
  const safeId = sessionId.replace(/[^a-zA-Z0-9_-]/g, "_");
  return path.join(STATE_DIR, `${safeId}.user.json`);
}

function readUserData(sessionId) {
  try {
    const content = fs.readFileSync(userDataPath(sessionId), "utf8");
    return JSON.parse(content);
  } catch (_) {
    return null;
  }
}

function writeUserData(sessionId, data) {
  fs.writeFileSync(userDataPath(sessionId), JSON.stringify(data, null, 2));
}

function deleteUserData(sessionId) {
  try {
    fs.unlinkSync(userDataPath(sessionId));
  } catch (_) {}
}

function hasAnnotations(userData) {
  if (!userData) return false;
  return !!(userData.note || userData.color);
}

function readAllUserData() {
  const result = new Map();
  try {
    const files = fs.readdirSync(STATE_DIR);
    for (const file of files) {
      if (!file.endsWith(".user.json")) continue;
      const filePath = path.join(STATE_DIR, file);
      try {
        const content = fs.readFileSync(filePath, "utf8");
        const data = JSON.parse(content);
        if (data.session_id) {
          result.set(data.session_id, data);
        }
      } catch (_) {}
    }
  } catch (_) {}
  return result;
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
    if (!file.endsWith(".json")) continue;
    if (file.endsWith(".user.json")) continue;
    if (file.startsWith(".")) continue;
    const filePath = path.join(STATE_DIR, file);
    try {
      const content = fs.readFileSync(filePath, "utf8");
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
  const allUserData = readAllUserData();
  const seenSessionIds = new Set();
  const config = readConfig();
  const preserveUnannotated = config.preserveUnannotatedCards === true;

  const result = [];

  for (const session of sessions) {
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

    const userData = allUserData.get(session.session_id);
    const merged = { ...session, alive };
    if (userData) {
      if (userData.note) merged.note = userData.note;
      if (userData.color) merged.color = userData.color;
    }

    if (session.session_id) seenSessionIds.add(session.session_id);
    result.push(merged);
  }

  // Add orphan user-data sessions (user-data exists but no tab-state)
  for (const [sessionId, userData] of allUserData) {
    if (seenSessionIds.has(sessionId)) continue;
    if (!hasAnnotations(userData)) continue;
    const snapshot = userData.snapshot || {};
    result.push({
      session_id: sessionId,
      name: snapshot.name || sessionId,
      cwd: snapshot.cwd || "",
      created_at: snapshot.created_at || "",
      status: "done",
      alive: false,
      note: userData.note || null,
      color: userData.color || null,
    });
  }

  return result;
}

// --- SSE broadcast (moved up so native session sync can use it) ---
let debounceTimer = null;

function scheduleSSEBroadcast() {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }
  debounceTimer = setTimeout(() => {
    debounceTimer = null;
    broadcastSSE("session-update", { type: "reload" });
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
    if (!file.endsWith(".json")) continue;
    const filePath = path.join(SESSIONS_DIR, file);
    try {
      const content = fs.readFileSync(filePath, "utf8");
      const native = JSON.parse(content);
      if (!native.sessionId || !native.pid) continue;

      // Check if tab-state file already exists for this session
      const safeId = native.sessionId.replace(/[^a-zA-Z0-9_-]/g, "_");
      const stateFile = path.join(STATE_DIR, `${safeId}.json`);
      if (fs.existsSync(stateFile)) continue;

      // Derive session name from cwd basename + short session ID
      const cwd = native.cwd || "";
      const dirName = cwd ? path.basename(cwd) : "unknown";
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
        status: "starting",
        cwd,
        pid: native.pid,
        last_activity: createdAt,
        last_message_preview: "",
        created_at: createdAt,
        ai_name_generated: false,
      };

      fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
      created++;
      console.log(
        `Created tab-state from native session: ${native.sessionId} (pid ${native.pid})`,
      );
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
    if (filename.endsWith(".json")) {
      scheduleSyncNativeSessions();
      // When a native session file is removed, prune orphaned tab-state
      setTimeout(() => pruneOrphanedTabState(), SSE_DEBOUNCE_MS + 100);
    }
  });
} catch (err) {
  console.warn("Could not watch native sessions directory:", err.message);
}

// Sync on startup to catch sessions that started before the server
syncNativeSessions();
pruneOrphanedTabState();

// --- Static file serving ---
const DIST_DIR = path.join(DASHBOARD_DIR, "dist");

// --- Express app ---
const app = express();

app.use(express.json());

// Health endpoint — B1.1, B1.2
app.get("/api/health", (req, res) => {
  res.json({ ok: true });
});

// Sessions endpoint — B2.1–B2.6
app.get("/api/sessions", (req, res) => {
  const sessions = getSessionsWithLiveness();
  res.json(sessions);
});

// Annotations endpoint — update note/color for a session
app.put("/api/sessions/:id/annotations", (req, res) => {
  const sessionId = req.params.id;
  if (!req.body) {
    return res.status(400).json({ error: "Request body is required" });
  }
  const { note, color } = req.body;

  // Read existing user-data or create new
  let userData = readUserData(sessionId) || { session_id: sessionId };

  // Populate snapshot on first creation
  if (!userData.snapshot) {
    const sessions = readAllSessions();
    const session = sessions.find((s) => s.session_id === sessionId);
    if (session) {
      userData.snapshot = {
        name: session.name || sessionId,
        cwd: session.cwd || "",
        created_at: session.created_at || "",
      };
    } else {
      userData.snapshot = { name: sessionId, cwd: "", created_at: "" };
    }
  }

  // Update fields (undefined = leave unchanged, null = clear)
  if (note !== undefined) userData.note = note;
  if (color !== undefined) userData.color = color;

  // If both cleared, delete the user-data file
  if (!userData.note && !userData.color) {
    deleteUserData(sessionId);
    console.log(`Annotations cleared for session: ${sessionId}`);
  } else {
    writeUserData(sessionId, userData);
    console.log(`Annotations saved for session: ${sessionId} (note: ${!!userData.note}, color: ${!!userData.color})`);
  }

  // Build merged response
  const allSessions = getSessionsWithLiveness();
  const merged = allSessions.find((s) => s.session_id === sessionId);

  // Broadcast update
  broadcastSSE("session-update", { type: "reload" });

  if (merged) {
    res.json(merged);
  } else {
    res.json({ session_id: sessionId, note: userData.note, color: userData.color });
  }
});

// Dismiss a session — removes its state file and user-data
app.delete("/api/sessions/:id", (req, res) => {
  const sessionId = req.params.id;
  const safeId = sessionId.replace(/[^a-zA-Z0-9_-]/g, "_");

  // Check if session is still alive
  const sessions = getSessionsWithLiveness();
  const session = sessions.find((s) => s.session_id === sessionId);
  if (session && session.alive) {
    return res.status(400).json({ error: "Cannot dismiss an active session" });
  }

  const filePath = path.join(STATE_DIR, `${safeId}.json`);
  let deleted = false;
  try {
    fs.unlinkSync(filePath);
    deleted = true;
  } catch (err) {
    if (err.code !== "ENOENT") {
      return res.status(500).json({ error: err.message });
    }
  }

  // Also delete user-data file
  const hadUserData = !!readUserData(sessionId);
  deleteUserData(sessionId);

  if (!deleted && !hadUserData) {
    return res.status(404).json({ error: "Session not found" });
  }

  broadcastSSE("session-update", { type: "reload" });
  res.status(204).end();
});

// Restart server — spawns a new instance and exits
app.post("/api/restart", (req, res) => {
  res.json({ ok: true });

  broadcastSSE("server-restarting", { type: "restart" });

  // Close all SSE connections so server.close() can complete
  for (const client of sseClients) {
    client.end();
  }
  sseClients.clear();

  function spawnAndExit() {
    const logFd = fs.openSync(path.join(DASHBOARD_DIR, "server.log"), "a");
    const child = spawn(process.execPath, [__filename], {
      detached: true,
      stdio: ["ignore", logFd, logFd],
    });
    child.unref();
    process.exit(0);
  }

  server.close(() => spawnAndExit());

  // Safety: if server.close() hangs, force restart after 3s
  setTimeout(spawnAndExit, 3000);
});

// SSE endpoint — B3.1–B3.6
const sseClients = new Set();

app.get("/api/events", (req, res) => {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });

  res.write("retry: 3000\n\n");
  sseClients.add(res);

  req.on("close", () => {
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
    res.sendFile(path.join(DIST_DIR, "index.html"));
  });
}

// --- File watching with fs.watch ---
fs.watch(STATE_DIR, (eventType, filename) => {
  if (!filename) return;
  if (filename.endsWith(".json") && !filename.startsWith(".")) {
    scheduleSSEBroadcast();
  }
});

// Note: .user.json changes also match the above pattern, which is fine —
// they trigger a broadcast so other dashboard tabs see annotation updates.

// --- Prune orphaned tab-state entries not in native sessions ---
function pruneOrphanedTabState() {
  // Collect all session IDs from native session files (source of truth)
  const nativeSessionIds = new Set();
  try {
    const nativeFiles = fs.readdirSync(SESSIONS_DIR);
    for (const file of nativeFiles) {
      if (!file.endsWith(".json")) continue;
      try {
        const content = fs.readFileSync(path.join(SESSIONS_DIR, file), "utf8");
        const native = JSON.parse(content);
        if (native.sessionId) nativeSessionIds.add(native.sessionId);
      } catch (_) {}
    }
  } catch (_) {
    return; // Can't read native sessions — skip
  }

  // Remove tab-state entries with no native session and a dead PID
  let pruned = 0;
  const sessions = readAllSessions();
  const config = readConfig();
  const preserveUnannotated = config.preserveUnannotatedCards === true;

  for (const session of sessions) {
    if (!session.session_id) continue;
    if (nativeSessionIds.has(session.session_id)) continue;
    if (session.pid && checkPidAlive(session.pid)) continue;

    // If session has annotations, always preserve
    const userData = readUserData(session.session_id);
    if (hasAnnotations(userData)) continue;

    // If preserveUnannotatedCards is true, preserve all
    if (preserveUnannotated) continue;

    const safeId = session.session_id.replace(/[^a-zA-Z0-9_-]/g, "_");
    const filePath = path.join(STATE_DIR, `${safeId}.json`);
    try {
      fs.unlinkSync(filePath);
      pruned++;
      console.log(
        `Pruned orphaned tab-state: ${session.session_id} (no native session, pid ${session.pid} dead)`,
      );
    } catch (_) {}
  }

  if (pruned > 0) {
    scheduleSSEBroadcast();
  }
}

// --- Auto-prune dead sessions past grace period ---
function pruneDeadSessions() {
  const now = Date.now();
  const sessions = readAllSessions();
  const config = readConfig();
  const preserveUnannotated = config.preserveUnannotatedCards === true;

  for (const session of sessions) {
    if (!session.pid || !session.session_id) continue;
    const alive = checkPidAlive(session.pid);
    if (alive) continue;

    // Check if last_activity is old enough past the grace period
    const lastActivity = session.last_activity
      ? new Date(session.last_activity).getTime()
      : 0;
    if (now - lastActivity > DEAD_SESSION_GRACE_MS) {
      // If session has annotations, always preserve
      const userData = readUserData(session.session_id);
      if (hasAnnotations(userData)) continue;

      // If preserveUnannotatedCards is true, preserve all closed sessions
      if (preserveUnannotated) continue;

      const safeId = session.session_id.replace(/[^a-zA-Z0-9_-]/g, "_");
      const filePath = path.join(STATE_DIR, `${safeId}.json`);
      try {
        fs.unlinkSync(filePath);
        console.log(
          `Auto-pruned dead session: ${session.session_id} (pid ${session.pid})`,
        );
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
  pruneOrphanedTabState();
  broadcastSSE("session-update", { type: "reload" });
}, PID_LIVENESS_INTERVAL_MS);

// --- Start server ---
const server = app.listen(PORT, BIND_ADDRESS, () => {
  console.log(
    `Claude Dashboard server listening on http://${BIND_ADDRESS}:${PORT}`,
  );
  console.log(`Watching state files in: ${STATE_DIR}`);
  console.log(`Watching native sessions in: ${SESSIONS_DIR}`);
});

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.error(
      `Error: Port ${PORT} is already in use. Set PORT env var to use a different port.`,
    );
    process.exit(1);
  }
  throw err;
});
