<template>
  <div
    class="session-card"
    :class="{ closed: !session.alive }"
    :style="{ borderLeftColor: borderColor }"
  >
    <!-- Color bar -->
    <div
      v-if="session.color"
      class="color-bar"
      :style="{ backgroundColor: session.color }"
    ></div>

    <div class="card-header">
      <span class="status-indicator">
        <span
          v-if="session.status === 'working'"
          class="working-spinner"
        ></span>
        <span v-else-if="session.status === 'starting'" class="new-dot"></span>
        <span v-else class="status-emoji">{{ statusEmoji }}</span>
      </span>
      <span class="session-name" :title="session.name">{{
        truncatedName
      }}</span>
      <span v-if="!session.alive" class="closed-badge">Closed</span>
      <div class="card-header-actions">
        <!-- Color picker -->
        <span
          class="color-picker-trigger"
          :title="session.color ? 'Change color' : 'Set color'"
          @click="openColorPicker"
        >
          <span
            class="color-circle"
            :style="{
              backgroundColor: session.color || 'var(--text-secondary)',
            }"
          ></span>
        </span>
        <input
          ref="colorInputEl"
          type="color"
          class="color-input"
          :value="session.color || '#3498db'"
          @input="onColorPick"
        />
        <!-- Clear color button -->
        <button
          v-if="session.color"
          class="icon-btn"
          title="Clear color"
          @click="
            emit('update-annotations', session.session_id, { color: null })
          "
        >
          &times;
        </button>
      </div>
    </div>

    <div class="card-time">{{ relativeTime }}</div>
    <a
      v-if="session.cwd"
      class="card-path"
      :title="pathTarget"
      @click.prevent="openInVSCode"
      >{{ pathLabel }}</a
    >

    <div
      class="card-preview"
      v-if="session.last_message_preview"
      @click="previewExpanded = !previewExpanded"
    >
      <span class="preview-text" :class="{ expanded: previewExpanded }">{{
        session.last_message_preview
      }}</span>
      <span class="preview-chevron">{{ previewExpanded ? "▴" : "▾" }}</span>
    </div>

    <!-- Note display/edit -->
    <div v-if="editingNote" class="card-note-edit">
      <textarea
        ref="noteInput"
        v-model="noteText"
        class="note-textarea"
        placeholder="Add a note…"
        @blur="saveNote"
        @keydown.enter.exact.prevent="saveNote"
      ></textarea>
    </div>
    <div v-else-if="displayNote" class="card-note" @click="startEditNote">
      {{ displayNote }}
    </div>
    <button v-else class="btn-add-note" @click="startEditNote">
      + Add note
    </button>

    <div class="card-actions">
      <template v-if="session.alive">
        <button class="btn btn-open" @click="openInVSCode">Open</button>
      </template>
      <template v-else>
        <!-- Resume menu -->
        <div
          class="resume-menu-wrap"
          v-if="resumeOpen"
          v-click-outside="() => (resumeOpen = false)"
        >
          <div class="resume-menu">
            <button class="resume-menu-item" @click="resumeInVSCode">
              Open in VS Code
            </button>
            <button class="resume-menu-item" @click="copyResumeCommand">
              {{ resumeCopyLabel }}
            </button>
          </div>
        </div>
        <button class="btn btn-open" @click="resumeOpen = !resumeOpen">
          Resume
        </button>
      </template>
      <button class="btn btn-copy" @click="copyId">{{ copyLabel }}</button>
      <button
        v-if="!session.alive"
        class="btn btn-dismiss"
        @click="handleDismiss"
      >
        Dismiss
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch, nextTick } from "vue";
import { formatRelativeTime } from "../composables/useRelativeTime.js";

const props = defineProps({
  session: { type: Object, required: true },
  tick: { type: Number, default: 0 },
  workspaceOverrides: { type: Object, default: () => ({}) },
});

const emit = defineEmits(["dismiss", "update-annotations"]);

const STATUS_MAP = {
  starting: { emoji: null, color: "#95A5A6" },
  working: { emoji: null, color: "#E67E22" },
  done: { emoji: "✅", color: "#3498DB" },
  attention: { emoji: "⚠️", color: "#F39C12" },
  error: { emoji: "❌", color: "#E74C3C" },
};

const STALE_COLOR = "#BDC3C7";

const statusEmoji = computed(() => {
  const entry = STATUS_MAP[props.session.status];
  return entry ? entry.emoji : "❓";
});

const borderColor = computed(() => {
  if (!props.session.alive) return STALE_COLOR;
  const entry = STATUS_MAP[props.session.status];
  return entry ? entry.color : STALE_COLOR;
});

const truncatedName = computed(() => {
  const name = props.session.name || props.session.session_id || "";
  return name.length > 30 ? name.slice(0, 30) + "…" : name;
});

const relativeTime = computed(() => {
  void props.tick;
  return formatRelativeTime(props.session.last_activity);
});

const pathTarget = computed(() => {
  const cwd = props.session.cwd || "";
  return props.workspaceOverrides[cwd] || cwd;
});

const pathLabel = computed(() => {
  const target = pathTarget.value;
  if (!target) return "";
  const parts = target.replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] || target;
});

const previewExpanded = ref(false);

function openInVSCode() {
  const target = pathTarget.value;
  if (target) window.open(`vscode://file/${target}`);
}

// --- Copy ID ---
const copyLabel = ref("Copy ID");

async function copyId() {
  try {
    await navigator.clipboard.writeText(props.session.session_id);
    copyLabel.value = "Copied!";
    setTimeout(() => {
      copyLabel.value = "Copy ID";
    }, 2000);
  } catch {
    copyLabel.value = "Failed";
    setTimeout(() => {
      copyLabel.value = "Copy ID";
    }, 2000);
  }
}

// --- Color picker ---
const colorInputEl = ref(null);

function openColorPicker() {
  colorInputEl.value?.click();
}

function onColorPick(e) {
  emit("update-annotations", props.session.session_id, {
    color: e.target.value,
  });
}

// --- Note editing ---
const editingNote = ref(false);
const noteText = ref("");
const noteInput = ref(null);
const pendingNote = ref(undefined); // optimistic value while server saves

const displayNote = computed(() => {
  if (pendingNote.value !== undefined) return pendingNote.value;
  return props.session.note;
});

// Clear optimistic value once server data arrives
watch(
  () => props.session.note,
  () => {
    pendingNote.value = undefined;
  },
);

function startEditNote() {
  noteText.value = displayNote.value || "";
  editingNote.value = true;
  nextTick(() => {
    noteInput.value?.focus();
  });
}

function saveNote() {
  if (!editingNote.value) return; // guard against double-call (Enter + blur)
  editingNote.value = false;
  const trimmed = noteText.value.trim();
  const newNote = trimmed || null;
  pendingNote.value = newNote;
  if (newNote !== (props.session.note || null)) {
    emit("update-annotations", props.session.session_id, { note: newNote });
  }
}

// --- Resume menu ---
const resumeOpen = ref(false);
const resumeCopyLabel = ref("Copy resume command");

function resumeInVSCode() {
  resumeOpen.value = false;
  const cwd = props.session.cwd || "";
  const cmd = `claude --resume ${props.session.session_id}`;
  // Deep-link: open folder in VS Code, then run command in terminal
  if (cwd) {
    window.open(`vscode://file/${cwd}`);
  }
  // Also copy the resume command for convenience
  navigator.clipboard.writeText(cmd).catch(() => {});
}

async function copyResumeCommand() {
  const cmd = `claude --resume ${props.session.session_id}`;
  try {
    await navigator.clipboard.writeText(cmd);
    resumeCopyLabel.value = "Copied!";
    setTimeout(() => {
      resumeCopyLabel.value = "Copy resume command";
      resumeOpen.value = false;
    }, 1500);
  } catch {
    resumeCopyLabel.value = "Failed";
    setTimeout(() => {
      resumeCopyLabel.value = "Copy resume command";
    }, 2000);
  }
}

// --- Dismiss with confirmation ---
function handleDismiss() {
  if (props.session.note || props.session.color) {
    if (!window.confirm("This session has notes/color. Remove anyway?")) return;
  }
  emit("dismiss", props.session.session_id);
}

// --- v-click-outside directive ---
const vClickOutside = {
  mounted(el, binding) {
    el._clickOutside = (e) => {
      if (!el.contains(e.target)) binding.value();
    };
    document.addEventListener("click", el._clickOutside, true);
  },
  unmounted(el) {
    document.removeEventListener("click", el._clickOutside, true);
  },
};
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
  transition:
    opacity 0.2s,
    box-shadow 0.2s;
  position: relative;
  overflow: hidden;
}

.session-card:hover {
  box-shadow: var(--shadow-md);
}

.session-card.closed {
  opacity: 0.5;
}

/* -- Color bar -- */
.color-bar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 6px;
}

/* -- Header: status + name + badge + actions -- */
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
  border-top-color: #e67e22;
  border-right-color: #e67e22;
  border-radius: 50%;
  animation: spin 0.7s linear infinite;
}

@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}

.new-dot {
  display: inline-block;
  width: 10px;
  height: 10px;
  border: 2px solid #95a5a6;
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
  flex: 1;
}

.closed-badge {
  font-size: 0.68em;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--text-secondary);
  background: var(--bg);
  border: 1px solid var(--border-color);
  border-radius: 4px;
  padding: 1px 6px;
  flex-shrink: 0;
}

.card-header-actions {
  display: flex;
  align-items: center;
  gap: 2px;
  flex-shrink: 0;
  margin-left: auto;
}

/* -- Color picker -- */
.color-picker-trigger {
  display: flex;
  align-items: center;
  cursor: pointer;
}

.color-circle {
  width: 14px;
  height: 14px;
  border-radius: 50%;
  border: 1.5px solid var(--border-color);
  transition: transform 0.15s;
}

.color-picker-trigger:hover .color-circle {
  transform: scale(1.2);
}

.color-input {
  position: absolute;
  opacity: 0;
  width: 0;
  height: 0;
  padding: 0;
  border: 0;
  overflow: hidden;
  pointer-events: none;
}

.icon-btn {
  background: none;
  border: none;
  color: var(--text-secondary);
  cursor: pointer;
  font-size: 1em;
  line-height: 1;
  padding: 0 2px;
  opacity: 0.5;
  transition: opacity 0.15s;
}

.icon-btn:hover {
  opacity: 1;
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
  transition:
    opacity 0.15s,
    color 0.15s;
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

/* -- Note -- */
.card-note {
  font-size: 0.82em;
  color: var(--text-primary);
  background: var(--bg);
  border-radius: 6px;
  padding: var(--space-sm);
  margin-top: var(--space-xs);
  cursor: pointer;
  white-space: pre-wrap;
  word-break: break-word;
  border-left: 2px solid var(--border-color);
}

.card-note:hover {
  background: var(--surface);
}

.card-note-edit {
  margin-top: var(--space-xs);
}

.note-textarea {
  width: 100%;
  min-height: 48px;
  font-family: inherit;
  font-size: 0.82em;
  color: var(--text-primary);
  background: var(--bg);
  border: 1px solid var(--border-color);
  border-radius: 6px;
  padding: var(--space-sm);
  resize: vertical;
  outline: none;
}

.note-textarea:focus {
  border-color: var(--text-secondary);
}

.btn-add-note {
  background: none;
  border: none;
  color: var(--text-secondary);
  font-size: 0.78em;
  cursor: pointer;
  padding: var(--space-xs) 0;
  opacity: 0.6;
  transition: opacity 0.15s;
  text-align: left;
}

.btn-add-note:hover {
  opacity: 1;
}

/* -- Actions -- */
.card-actions {
  display: flex;
  gap: var(--space-sm);
  margin-top: var(--space-sm);
  padding-top: var(--space-sm);
  border-top: 1px solid var(--border-subtle);
  position: relative;
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
  transition:
    background 0.15s,
    color 0.15s;
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
  color: #e74c3c;
  border-color: rgba(231, 76, 60, 0.3);
}

.btn-dismiss:hover {
  background: rgba(231, 76, 60, 0.1);
  color: #e74c3c;
}

/* -- Resume menu -- */
.resume-menu-wrap {
  position: absolute;
  bottom: 100%;
  left: 0;
  margin-bottom: 4px;
  z-index: 10;
}

.resume-menu {
  background: var(--card-bg);
  border: 1px solid var(--border-color);
  border-radius: 8px;
  box-shadow: var(--shadow-md);
  overflow: hidden;
  min-width: 180px;
}

.resume-menu-item {
  display: block;
  width: 100%;
  text-align: left;
  padding: var(--space-sm) var(--space-md);
  background: none;
  border: none;
  color: var(--text-primary);
  font-size: 0.82em;
  cursor: pointer;
  transition: background 0.15s;
}

.resume-menu-item:hover {
  background: var(--bg);
}

.resume-menu-item + .resume-menu-item {
  border-top: 1px solid var(--border-subtle);
}
</style>
