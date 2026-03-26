<template>
  <div class="session-card" :class="{ stale: !session.alive }" :style="{ borderLeftColor: borderColor }">
    <div class="card-header">
      <span class="status-indicator">
        <span v-if="session.status === 'working'" class="working-spinner"></span>
        <span v-else-if="session.status === 'starting'" class="new-dot"></span>
        <span v-else class="status-emoji">{{ statusEmoji }}</span>
      </span>
      <span class="session-name" :title="session.name">{{ truncatedName }}</span>
    </div>
    <div class="card-time">{{ relativeTime }}</div>
    <div class="card-preview" v-if="session.last_message_preview" @click="previewExpanded = !previewExpanded">
      <span class="preview-text" :class="{ expanded: previewExpanded }">{{ session.last_message_preview }}</span>
      <span class="preview-chevron">{{ previewExpanded ? '▴' : '▾' }}</span>
    </div>
    <div class="card-stale" v-if="!session.alive">Session ended unexpectedly</div>
    <div class="card-actions">
      <button class="btn btn-open" @click="openInVSCode">Open</button>
      <button class="btn btn-copy" @click="copyId">{{ copyLabel }}</button>
    </div>
  </div>
</template>

<script setup>
import { computed, ref } from 'vue'
import { formatRelativeTime } from '../composables/useRelativeTime.js'

const props = defineProps({
  session: { type: Object, required: true },
  tick: { type: Number, default: 0 },
})

const STATUS_MAP = {
  starting: { emoji: null, color: '#95A5A6' },
  working: { emoji: null, color: '#E67E22' },
  done: { emoji: '✅', color: '#3498DB' },
  attention: { emoji: '⚠️', color: '#F39C12' },
  error: { emoji: '❌', color: '#E74C3C' },
}

const STALE_COLOR = '#BDC3C7'

const statusEmoji = computed(() => {
  const entry = STATUS_MAP[props.session.status]
  return entry ? entry.emoji : '❓'
})

const borderColor = computed(() => {
  if (!props.session.alive) return STALE_COLOR
  const entry = STATUS_MAP[props.session.status]
  return entry ? entry.color : STALE_COLOR
})

const truncatedName = computed(() => {
  const name = props.session.name || props.session.session_id || ''
  return name.length > 30 ? name.slice(0, 30) + '…' : name
})

const relativeTime = computed(() => {
  // Access tick to trigger reactivity on 30s intervals
  void props.tick
  return formatRelativeTime(props.session.last_activity)
})

const previewExpanded = ref(false)

function openInVSCode() {
  const target = props.session.cwd || props.session.session_id
  window.open(props.session.cwd ? `vscode://file/${target}` : `vscode://anthropic.claude-code/open?session=${target}`)
}

const copyLabel = ref('Copy ID')

async function copyId() {
  try {
    await navigator.clipboard.writeText(props.session.session_id)
    copyLabel.value = 'Copied!'
    setTimeout(() => { copyLabel.value = 'Copy ID' }, 2000)
  } catch {
    copyLabel.value = 'Failed'
    setTimeout(() => { copyLabel.value = 'Copy ID' }, 2000)
  }
}
</script>

<style scoped>
.session-card {
  border-left: 4px solid var(--border-color);
  background: var(--card-bg);
  border-radius: 8px;
  padding: 12px 16px;
  min-width: 280px;
  max-width: 400px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);
  transition: opacity 0.2s;
}

.session-card.stale {
  opacity: 0.5;
}

.card-header {
  display: flex;
  align-items: center;
  gap: 6px;
}

.status-indicator {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 1.1em;
  height: 1.1em;
  flex-shrink: 0;
}

.status-emoji {
  font-size: 1.1em;
  line-height: 1;
}

.working-spinner {
  display: inline-block;
  width: 13px;
  height: 13px;
  border: 2.5px solid rgba(230, 126, 34, 0.25);
  border-top-color: #E67E22;
  border-right-color: #E67E22;
  border-radius: 50%;
  animation: spin 0.7s linear infinite;
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

.new-dot {
  display: inline-block;
  width: 10px;
  height: 10px;
  border: 2px solid #95A5A6;
  border-radius: 50%;
  opacity: 0.6;
}

.session-name {
  font-weight: 600;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.card-time {
  font-size: 0.8em;
  color: var(--text-secondary);
}

.card-preview {
  font-size: 0.85em;
  color: var(--text-secondary);
  cursor: pointer;
  display: flex;
  align-items: baseline;
  gap: 4px;
  user-select: none;
}

.card-preview:hover {
  color: var(--text-primary);
}

.preview-text {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex: 1;
}

.preview-text.expanded {
  white-space: pre-wrap;
  overflow-y: auto;
  max-height: 140px;
  word-break: break-word;
  text-overflow: unset;
}

.preview-chevron {
  font-size: 0.75em;
  opacity: 0.5;
  flex-shrink: 0;
  line-height: 1.6;
}

.card-stale {
  font-size: 0.8em;
  color: #E74C3C;
  font-style: italic;
}

.card-actions {
  display: flex;
  gap: 8px;
  margin-top: 4px;
}

.btn {
  padding: 4px 10px;
  border-radius: 4px;
  border: 1px solid var(--border-color);
  background: var(--card-bg);
  color: var(--text-primary);
  cursor: pointer;
  font-size: 0.8em;
}

.btn:hover {
  opacity: 0.8;
}

.btn-open {
  background: var(--text-primary);
  color: var(--card-bg);
}
</style>
