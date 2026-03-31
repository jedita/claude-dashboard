<template>
  <section class="project-group">
    <h2 class="project-heading">{{ project }}</h2>
    <div class="cards-row">
      <SessionCard
        v-for="session in sessions"
        :key="session.session_id"
        :session="session"
        :tick="tick"
        :workspace-overrides="workspaceOverrides"
        @dismiss="id => emit('dismiss', id)"
        @update-annotations="(id, data) => emit('update-annotations', id, data)"
      />
    </div>
  </section>
</template>

<script setup>
import SessionCard from './SessionCard.vue'

defineProps({
  project: { type: String, required: true },
  sessions: { type: Array, required: true },
  tick: { type: Number, default: 0 },
  workspaceOverrides: { type: Object, default: () => ({}) },
})

const emit = defineEmits(['dismiss', 'update-annotations'])
</script>

<style scoped>
.project-group {
  /* No bottom margin — parent gap handles separation */
}

.project-heading {
  font-size: 0.75em;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-secondary);
  margin: 0 0 var(--space-md) 0;
  padding: 0;
  border: none;
}

.cards-row {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: var(--space-md);
  align-items: start;
}
</style>
