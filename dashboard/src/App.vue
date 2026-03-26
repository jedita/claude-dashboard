<template>
  <div class="dashboard">
    <header class="dashboard-header">
      <h1>Claude Code Dashboard</h1>
      <ConnectionStatus :status="connectionStatus" />
    </header>
    <main class="dashboard-main" :class="{ 'conn-impaired': connectionStatus !== 'connected' }">
      <div v-if="loading" class="empty-state">Loading sessions…</div>
      <div v-else-if="error" class="empty-state error-state">
        Unable to connect to server: {{ error }}
      </div>
      <div v-else-if="groupedSessions.length === 0" class="empty-state">
        No active sessions. Start a Claude Code session to see it here.
      </div>
      <template v-else>
        <ProjectGroup
          v-for="group in groupedSessions"
          :key="group.project"
          :project="group.project"
          :sessions="group.sessions"
          :tick="tick"
          @dismiss="dismissSession"
        />
      </template>
    </main>
  </div>
</template>

<script setup>
import { useSessions } from './composables/useSessions.js'
import { useRelativeTime } from './composables/useRelativeTime.js'
import ProjectGroup from './components/ProjectGroup.vue'
import ConnectionStatus from './components/ConnectionStatus.vue'

const { groupedSessions, loading, error, connectionStatus, dismissSession } = useSessions()
const { tick } = useRelativeTime()
</script>

<style>
:root {
  /* Spacing scale */
  --space-xs: 4px;
  --space-sm: 8px;
  --space-md: 16px;
  --space-lg: 24px;
  --space-xl: 40px;
  --space-2xl: 64px;

  /* Colors */
  --bg: #FAFBFC;
  --surface: #FFFFFF;
  --card-bg: #FFFFFF;
  --text-primary: #1a1a2e;
  --text-secondary: #6b7280;
  --border-color: #e5e7eb;
  --border-subtle: #f0f1f3;

  /* Shadows */
  --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.04);
  --shadow-md: 0 2px 8px rgba(0, 0, 0, 0.06);
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111119;
    --surface: #1a1a2e;
    --card-bg: #1e1e36;
    --text-primary: #ECF0F1;
    --text-secondary: #8b95a5;
    --border-color: #2a2a44;
    --border-subtle: #222238;
    --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.2);
    --shadow-md: 0 2px 8px rgba(0, 0, 0, 0.3);
  }
}

* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--bg);
  color: var(--text-primary);
  min-height: 100vh;
  -webkit-font-smoothing: antialiased;
}

.dashboard {
  max-width: 1080px;
  margin: 0 auto;
  padding: var(--space-xl) var(--space-lg);
}

.dashboard-header {
  margin-bottom: var(--space-xl);
  padding-bottom: var(--space-lg);
  border-bottom: 1px solid var(--border-subtle);
  display: flex;
  align-items: baseline;
  justify-content: space-between;
}

.dashboard-header h1 {
  font-size: 1.5em;
  font-weight: 700;
  letter-spacing: -0.02em;
}

.dashboard-main {
  display: flex;
  flex-direction: column;
  gap: var(--space-xl);
}

.empty-state {
  text-align: center;
  padding: var(--space-2xl) var(--space-lg);
  color: var(--text-secondary);
  font-size: 0.95em;
  line-height: 1.6;
  border: 1px dashed var(--border-color);
  border-radius: 12px;
}

.error-state {
  color: #E74C3C;
  border-color: rgba(231, 76, 60, 0.3);
}

.dashboard-main.conn-impaired {
  opacity: 0.4;
  pointer-events: none;
  user-select: none;
  transition: opacity 0.3s;
}
</style>
