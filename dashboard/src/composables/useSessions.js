import { ref, computed, onMounted } from 'vue'

const sessions = ref([])
const loading = ref(true)
const error = ref(null)

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

export function useSessions() {
  onMounted(() => {
    fetchSessions()
  })

  return {
    sessions,
    groupedSessions,
    loading,
    error,
    fetchSessions,
  }
}
