# Spec: Session Annotations & Persistence

## Problem

The dashboard currently shows live Claude Code sessions but loses all context when sessions close. Users have no way to annotate sessions with personal notes or visual markers, and closed sessions disappear — losing the ability to resume conversations or recall what a session was about.

## Goals

1. Allow users to add a **personal note** (plain text) and a **custom color** (via full color picker) to any session card.
2. **Persist** annotations independently from hook-managed session data, surviving server restarts and session closures.
3. **Preserve closed sessions** that have annotations, showing them with a clear "closed" indication and offering the ability to resume the conversation.
4. Provide a **configurable cleanup policy** for unannotated closed sessions.

## Non-Goals

- Markdown or rich text in notes.
- A separate annotations overview/panel or filter view.
- Editing the config from the dashboard UI (config file only).
- Any changes to the hook scripts.

---

## Data Model

### User-Data Files

**Location:** `~/.claude/tab-state/<session_id>.user.json`

One file per session, created when the user first sets a note or color. Managed exclusively by the dashboard server API — never touched by hooks.

```json
{
  "session_id": "abc-123",
  "note": "Investigating the auth bug for sprint 42",
  "color": "#e74c3c",
  "snapshot": {
    "name": "Auth middleware refactor",
    "cwd": "/Users/me/projects/backend",
    "created_at": "2026-03-28T10:30:00Z"
  }
}
```

**Fields:**
- `session_id` — matches the tab-state file's session ID.
- `note` — plain text, no length limit. `null` or absent if unset.
- `color` — hex color string. `null` or absent if unset.
- `snapshot` — copied from tab-state at creation time. Contains `name`, `cwd`, `created_at`. Makes the user-data file self-sufficient for display and resume even if tab-state is deleted.

### Config Addition

**File:** `dashboard/public/config.json`

```json
{
  "preserveUnannotatedCards": false
}
```

- `false` (default): Closed sessions with no note and no custom color are removed immediately when detected as closed.
- `true`: All closed sessions are preserved regardless of annotations.

---

## API Changes

### Read: Merged into `GET /api/sessions`

Each session object in the response gains two new optional fields:

```json
{
  "session_id": "abc-123",
  "name": "Auth middleware refactor",
  "status": "done",
  "alive": false,
  "note": "Investigating the auth bug",
  "color": "#e74c3c",
  ...
}
```

The server merges user-data into the session response. Sessions that exist only as user-data files (orphans after restart) appear as closed sessions using their snapshot data.

### Write: `PUT /api/sessions/:id/annotations`

**Request body:**
```json
{
  "note": "Updated note text",
  "color": "#3498db"
}
```

Either field can be omitted to leave it unchanged. Set to `null` to clear.

**Behavior:**
- If the user-data file doesn't exist yet, create it and populate `snapshot` from the current tab-state.
- If both `note` and `color` are cleared (`null`), delete the user-data file (the session has no annotations).
- After writing, if the session is closed and now has no annotations and `preserveUnannotatedCards` is `false`, remove the session from the response (cleanup).

**Response:** The updated session object (merged).

### Delete: `DELETE /api/sessions/:id`

Removes a closed session card. Deletes the user-data file if it exists.

- If the session is still alive, return `400` — active sessions cannot be dismissed.
- Returns `204` on success.

---

## Server Behavior

### Session Discovery (existing + changes)

1. **Native discovery** (unchanged): Watch `~/.claude/sessions/` for PID files. Create tab-state entries.
2. **Enrichment hooks** (unchanged): Hooks update tab-state with status/names.
3. **User-data discovery** (new): On startup, scan `~/.claude/tab-state/*.user.json`. For any user-data file without a matching tab-state entry, create a synthetic closed session using the snapshot data.

### Cleanup Logic

On the PID liveness check (every 60s) and on startup:

1. If a session is detected as closed (`alive: false`):
   - If it has annotations (note or color set) → preserve it.
   - If it has no annotations AND `preserveUnannotatedCards` is `false` → remove the tab-state file and do not include in API response.
   - If it has no annotations AND `preserveUnannotatedCards` is `true` → preserve it.

### SSE Events

Existing SSE events continue unchanged. Annotation updates trigger a `session-updated` event so other open dashboard tabs see changes in real-time.

---

## Frontend UI

### Color Bar

- **Position:** Top of the card, full width.
- **Visibility:** Only shown when the user has set a custom color. No bar by default.
- **Height:** ~4px solid bar in the chosen color.
- **Picker:** Clicking a small color circle icon (in the card header/actions area) opens the native HTML `<input type="color">`. Selecting a color immediately persists it via `PUT /api/sessions/:id/annotations`.

### Note

- **Trigger:** A small "add note" icon/button on the card. Clicking reveals a plain text input area.
- **Display:** Once a note exists, it is always visible on the card (truncated is fine, but no max-height/scroll — full text shown).
- **Editing:** Clicking the note text turns it into an editable field. Blur or Enter saves via the API. No length limit.
- **Empty state:** If the user clears the note, the input hides and the "add note" icon returns.

### Closed Session Appearance

- **Opacity:** Card rendered at ~50% opacity.
- **Badge:** A "Closed" badge/chip displayed on the card (e.g., near the status area).
- **Color bar and note:** Remain visible and fully editable.
- **Resume button:** A button/action that shows a small menu with:
  - **"Open in VS Code"** — deep-links to VS Code and runs `claude --resume <session_id>` in a new terminal, targeting the session's `cwd`.
  - **"Copy resume command"** — copies `claude --resume <session_id>` to clipboard.

### Dismiss Button

- Visible on closed session cards (not on active sessions).
- Clicking dismisses/removes the card.
- **If the card has annotations** (note or color): show a confirmation dialog ("This session has notes/color. Remove anyway?").
- **If no annotations:** dismiss immediately without confirmation.
- Calls `DELETE /api/sessions/:id`.

---

## Success Criteria

1. User can add a note to any session card; note persists across page reloads and server restarts.
2. User can pick a color for any card; color shows as a top bar and persists the same way.
3. When a Claude session closes, the card remains if it has annotations, showing reduced opacity + "Closed" badge.
4. User can resume a closed session via VS Code deep-link or copied command.
5. User can dismiss any closed card, with confirmation when annotations exist.
6. Unannotated closed sessions are auto-cleaned when `preserveUnannotatedCards` is `false`.
7. After a full system restart, annotated sessions reappear as closed cards using snapshot data and can be resumed.
