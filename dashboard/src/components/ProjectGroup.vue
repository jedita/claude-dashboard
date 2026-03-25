<template>
  <section class="project-group">
    <h2 class="project-heading">{{ project }}</h2>
    <div class="cards-row">
      <SessionCard
        v-for="session in sessions"
        :key="session.session_id"
        :session="session"
        :tick="tick"
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
})
</script>

<style scoped>
.project-group {
  margin-bottom: 24px;
}

.project-heading {
  font-size: 1.1em;
  font-weight: 600;
  color: var(--text-primary);
  margin: 0 0 12px 0;
  padding-bottom: 4px;
  border-bottom: 1px solid var(--border-color);
}

.cards-row {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
}
</style>
