import { ref, onMounted, onUnmounted } from 'vue'

export function formatRelativeTime(isoString) {
  if (!isoString) return ''
  const now = Date.now()
  const then = new Date(isoString).getTime()
  const diffMs = now - then

  if (diffMs < 0) return 'just now'

  const seconds = Math.floor(diffMs / 1000)
  if (seconds < 60) return 'just now'

  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`

  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`

  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

export function useRelativeTime() {
  const tick = ref(0)
  let timer = null

  onMounted(() => {
    timer = setInterval(() => {
      tick.value++
    }, 30_000)
  })

  onUnmounted(() => {
    if (timer) clearInterval(timer)
  })

  return { tick, formatRelativeTime }
}
