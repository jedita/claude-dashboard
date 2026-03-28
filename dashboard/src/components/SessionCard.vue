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
    <a v-if="session.cwd" class="card-path" :title="pathTarget" @click.prevent="openInVSCode">{{ pathLabel }}</a>
    <div class="card-preview" v-if="session.last_message_preview" @click="previewExpanded = !previewExpanded">
      <span class="preview-text" :class="{ expanded: previewExpanded }">{{ session.last_message_preview }}</span>
      <span class="preview-chevron">{{ previewExpanded ? '▴' : '▾' }}</span>
    </div>
    <div class="card-stale" v-if="!session.alive">Session ended unexpectedly</div>
    <div class="card-actions">
      <button class="btn btn-open" @click="openInVSCode">Open</button>
      <button class="btn btn-copy" @click="copyId">{{ copyLabel }}</button>
      <button v-if="!session.alive" class="btn btn-dismiss" @click="emit('dismiss', session.session_id)">Dismiss</button>
    </div>
  </div>
</template>

<script setup>
import { computed, ref } from 'vue'
import { formatRelativeTime } from '../composables/useRelativeTime.js'

const props = defineProps({
  session: { type: Object, required: true },
  tick: { type: Number, default: 0 },
  workspaceOverrides: { type: Object, default: () => ({}) },
})

const emit = defineEmits(['dismiss'])

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

const pathTarget = computed(() => {
  const cwd = props.session.cwd || ''
  return props.workspaceOverrides[cwd] || cwd
})

const pathLabel = computed(() => {
  const target = pathTarget.value
  if (!target) return ''
  // Show filename for workspace files, folder name for directories
  const parts = target.replace(/\/+$/, '').split('/')
  return parts[parts.length - 1] || target
})

const previewExpanded = ref(false)

function openInVSCode() {
  const target = pathTarget.value
  if (target) window.open(`vscode://file/${target}`)
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
  border-left: 3px solid var(--border-color);
  background: var(--card-bg);
  border-radius: 10px;
  padding: var(--space-md) var(--space-lg);
  display: flex;
  flex-direction: column;
  gap: var(--space-xs);
  box-shadow: var(--shadow-sm);
  transition: opacity 0.2s, box-shadow 0.2s;
}

.session-card:hover {
  box-shadow: var(--shadow-md);
}

.session-card.stale {
  opacity: 0.45;
}

/* -- Header: status + name -- */
.card-header {
  display: flex;
  align-items: center;
  gap: var(--space-sm);
  margin-bottom: 2px;
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
  font-size: 0.95em;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* -- Meta: time -- */
.card-time {
  font-size: 0.78em;
  color: var(--text-secondary);
}

/* -- Path link -- */
.card-path {
  font-size: 0.78em;
  color: var(--text-secondary);
  cursor: pointer;
  text-decoration: none;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  opacity: 0.7;
  transition: opacity 0.15s, color 0.15s;
}

.card-path:hover {
  opacity: 1;
  color: var(--text-primary);
  text-decoration: underline;
}

/* -- Preview -- */
.card-preview {
  font-size: 0.82em;
  color: var(--text-secondary);
  cursor: pointer;
  display: flex;
  align-items: baseline;
  gap: var(--space-xs);
  user-select: none;
  margin-top: var(--space-xs);
  padding: var(--space-sm) var(--space-sm);
  background: var(--bg);
  border-radius: 6px;
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
  opacity: 0.4;
  flex-shrink: 0;
  line-height: 1.6;
}

/* -- Stale warning -- */
.card-stale {
  font-size: 0.78em;
  color: #E74C3C;
  font-style: italic;
}

/* -- Actions -- */
.card-actions {
  display: flex;
  gap: var(--space-sm);
  margin-top: var(--space-sm);
  padding-top: var(--space-sm);
  border-top: 1px solid var(--border-subtle);
}

.btn {
  padding: var(--space-xs) var(--space-md);
  border-radius: 6px;
  border: 1px solid var(--border-color);
  background: transparent;
  color: var(--text-secondary);
  cursor: pointer;
  font-size: 0.78em;
  font-weight: 500;
  transition: background 0.15s, color 0.15s;
}

.btn:hover {
  background: var(--bg);
  color: var(--text-primary);
}

.btn-open {
  background: var(--text-primary);
  color: var(--card-bg);
  border-color: var(--text-primary);
}

.btn-open:hover {
  opacity: 0.85;
  background: var(--text-primary);
  color: var(--card-bg);
}

.btn-dismiss {
  margin-left: auto;
  color: #E74C3C;
  border-color: rgba(231, 76, 60, 0.3);
}

.btn-dismiss:hover {
  background: rgba(231, 76, 60, 0.1);
  color: #E74C3C;
}
</style>
