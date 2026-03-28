<template>
  <div class="connection-status" :class="status">
    <span class="status-dot"></span>
    <span class="status-label">{{ label }}</span>
  </div>
</template>

<script setup>
import { computed } from 'vue'

const props = defineProps({
  status: { type: String, required: true },
})

const label = computed(() => {
  switch (props.status) {
    case 'connected': return 'Connected'
    case 'reconnecting': return 'Reconnecting…'
    case 'restarting': return 'Restarting…'
    case 'disconnected': return 'Disconnected'
    default: return props.status
  }
})
</script>

<style scoped>
.connection-status {
  display: flex;
  align-items: center;
  gap: var(--space-sm);
  font-size: 0.78em;
  font-weight: 500;
  color: var(--text-secondary);
  padding: var(--space-xs) var(--space-sm);
  border-radius: 20px;
  background: var(--surface);
}

.status-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  display: inline-block;
  flex-shrink: 0;
}

.connected .status-dot {
  background-color: #27AE60;
  box-shadow: 0 0 0 3px rgba(39, 174, 96, 0.15);
}

.reconnecting .status-dot {
  background-color: #F39C12;
  box-shadow: 0 0 0 3px rgba(243, 156, 18, 0.15);
}

.restarting .status-dot {
  background-color: #3498DB;
  box-shadow: 0 0 0 3px rgba(52, 152, 219, 0.15);
}

.disconnected .status-dot {
  background-color: #E74C3C;
  box-shadow: 0 0 0 3px rgba(231, 76, 60, 0.15);
}
</style>
