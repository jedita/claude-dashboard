import { ref, computed, onMounted, onUnmounted } from 'vue'

const sessions = ref([])
const loading = ref(true)
const error = ref(null)

// Connection status: 'connected', 'reconnecting', 'disconnected'
const connectionStatus = ref('disconnected')

async function fetchSessions() {
  try {
    const res = await fetch('/api/sessions')
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    sessions.value = await res.json()
    error.value = null
  } catch (err) {
    error.value = err.message
  } finally {
    loading.value = false
  }
}

const groupedSessions = computed(() => {
  const groups = new Map()

  for (const session of sessions.value) {
    const cwd = session.cwd || ''
    const parts = cwd.replace(/\/+$/, '').split('/')
    const project = parts[parts.length - 1] || 'unknown'

    if (!groups.has(project)) {
      groups.set(project, [])
    }
    groups.get(project).push(session)
  }

  // Sort sessions within each group by created_at (oldest first, stable order)
  for (const [, list] of groups) {
    list.sort((a, b) => {
      const ta = a.created_at || ''
      const tb = b.created_at || ''
      return ta < tb ? -1 : ta > tb ? 1 : 0
    })
  }

  // Convert to array of { project, sessions } sorted by project name
  return Array.from(groups.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([project, sessions]) => ({ project, sessions }))
})

let eventSource = null
let disconnectTimer = null

function connectSSE() {
  if (eventSource) {
    eventSource.close()
  }

  eventSource = new EventSource('/api/events')

  eventSource.onopen = () => {
    if (disconnectTimer) {
      clearTimeout(disconnectTimer)
      disconnectTimer = null
    }
    connectionStatus.value = 'connected'
    // Fetch fresh data on (re)connect
    fetchSessions()
  }

  eventSource.addEventListener('session-update', () => {
    fetchSessions()
  })

  eventSource.onerror = () => {
    // EventSource automatically reconnects; mark as reconnecting
    if (connectionStatus.value === 'connected') {
      connectionStatus.value = 'reconnecting'
    }
    // If still not reconnected after 10s, mark as disconnected
    if (!disconnectTimer) {
      disconnectTimer = setTimeout(() => {
        disconnectTimer = null
        if (connectionStatus.value === 'reconnecting') {
          connectionStatus.value = 'disconnected'
        }
      }, 10_000)
    }
  }
}

function disconnectSSE() {
  if (eventSource) {
    eventSource.close()
    eventSource = null
  }
  if (disconnectTimer) {
    clearTimeout(disconnectTimer)
    disconnectTimer = null
  }
  connectionStatus.value = 'disconnected'
}

export function useSessions() {
  onMounted(() => {
    fetchSessions()
    connectSSE()
  })

  onUnmounted(() => {
    disconnectSSE()
  })

  async function dismissSession(sessionId) {
    try {
      const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}`, { method: 'DELETE' })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      await fetchSessions()
    } catch (err) {
      console.error('Failed to dismiss session:', err)
    }
  }

  return {
    sessions,
    groupedSessions,
    loading,
    error,
    connectionStatus,
    fetchSessions,
    dismissSession,
  }
}
