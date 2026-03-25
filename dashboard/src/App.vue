<template>
  <div class="dashboard">
    <header class="dashboard-header">
      <h1>Claude Code Dashboard</h1>
    </header>
    <main class="dashboard-main">
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
        />
      </template>
    </main>
  </div>
</template>

<script setup>
import { useSessions } from './composables/useSessions.js'
import { useRelativeTime } from './composables/useRelativeTime.js'
import ProjectGroup from './components/ProjectGroup.vue'

const { groupedSessions, loading, error } = useSessions()
const { tick } = useRelativeTime()
</script>

<style>
:root {
  --bg: #FFFFFF;
  --card-bg: #F8F9FA;
  --text-primary: #2C3E50;
  --text-secondary: #7F8C8D;
  --border-color: #E0E0E0;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #1A1A2E;
    --card-bg: #16213E;
    --text-primary: #ECF0F1;
    --text-secondary: #95A5A6;
    --border-color: #2C3E50;
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
}

.dashboard {
  max-width: 960px;
  margin: 0 auto;
  padding: 24px;
}

.dashboard-header {
  margin-bottom: 24px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.dashboard-header h1 {
  font-size: 1.4em;
  font-weight: 700;
}

.empty-state {
  text-align: center;
  padding: 48px 24px;
  color: var(--text-secondary);
  font-size: 1em;
}

.error-state {
  color: #E74C3C;
}
</style>
