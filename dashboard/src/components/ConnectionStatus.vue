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
    case 'disconnected': return 'Disconnected'
    default: return props.status
  }
})
</script>

<style scoped>
.connection-status {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 0.85em;
  color: var(--text-secondary);
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  display: inline-block;
}

.connected .status-dot {
  background-color: #27AE60;
}

.reconnecting .status-dot {
  background-color: #F39C12;
}

.disconnected .status-dot {
  background-color: #E74C3C;
}
</style>
