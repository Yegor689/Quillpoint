# Data Model

## Project

Represents a top-level grouping of tasks.

| Field | Type | Notes |
|-------|------|-------|
| `id` | `UUID` | Unique identifier |
| `title` | `String` | Display name |
| `desc` | `String` | Optional details |
| `createdAt` | `Date` | Timestamp set on creation |
| `tasks` | `[Task]` | All tasks belonging to this project. `@Relationship(deleteRule: .cascade, inverse: \Task.project)` — the explicit inverse makes SwiftData maintain both sides on a to-one assignment (fixed the cross-project move data loss) |

---

## Task

Every task belongs to a project (`project` is non-optional as of the V2 schema) and
can be nested one level deep (subtasks via `parent`).

| Field | Type | Notes |
|-------|------|-------|
| `id` | `UUID` | Unique identifier |
| `titleRTF` | `Data` | Rich text title serialized as RTF |
| `descRTF` | `Data` | Rich text description serialized as RTF |
| `isDone` | `Bool` | Completion state |
| `priority` | `Int` | Raw `Priority` value: `0` = critical, `1` = normal, `2` = low |
| `createdAt` | `Date` | Timestamp set on creation; tiebreaker / migration fallback for ordering |
| `completedAt` | `Date?` | When most recently marked done; `nil` while incomplete. Orders the completed group (newest on top) |
| `sortIndex` | `Int` | Manual position within the parent context (project for roots, parent task for subtasks). Primary ordering key |
| `reminderDate` | `Date?` | Optional reminder time; `nil` when no reminder is set |
| `project` | `Project` | Owning project (SwiftData relationship). Non-optional as of schema V2 — every task always belongs to a project (a subtask inherits its parent's). Legacy stores are migrated forward, backfilling any orphan |
| `parent` | `Task?` | `nil` for root tasks; set to parent task for subtasks |
| `subtasks` | `[Task]` | Child tasks (cascade-delete on parent delete) |

`Priority` is an `Int`-backed enum (`critical`/`normal`/`low`) and the single source of truth for each level's label, color, icon, and accent. `task.priorityLevel` is the typed accessor over the stored `priority` Int.

### Computed properties

| Property | Type | Notes |
|----------|------|-------|
| `plainTitle` | `String` | Plain text extracted from `titleRTF` |
| `plainDesc` | `String` | Plain text extracted from `descRTF` |
| `priorityLevel` | `Priority` | Typed get/set over `priority`; falls back to `.normal` for bad values |

### Methods & static helpers

| Helper | Notes |
|--------|-------|
| `setDone(_:)` / `toggleDone()` | Sets completion and stamps `completedAt` — always use instead of mutating `isDone` directly |
| `syncDoneWithSubtasks()` | Re-derives a parent's completion from its subtasks (done exactly when it has subtasks and all are done). Call after a subtask's completion changes |
| `isDrivenBySubtasks` | True when a task has subtasks, so its own checkbox is a no-op (completion is derived) |
| `Task.rtf(from:font:)` | Converts a plain `String` to RTF `Data` with default label color |
| `Task.plain(from:)` | Extracts plain text from RTF `Data` |
| `Task.resizingFontRTF(_:to:)` | Re-renders title RTF at a new font size (used when a task changes level) |

---

## Hierarchy

Tasks form a two-level tree within each project. Root tasks have `parent == nil`. Subtasks point to their parent task.

```
Project
├── Task (parent: nil)
├── Task (parent: nil)
└── Task (parent: nil)
    ├── SubTask (parent: task)
    └── SubTask (parent: task)
```

---

## Relationships

```
Project 1 ──< Task (root)
                └──< SubTask
Project 2 ──< Task (root)
```

- One project has many tasks; every task has exactly one project (`project` is
  non-optional, with an explicit inverse on `Project.tasks`)
- A task may have many subtasks (`parent` self-reference on `Task`, cascade-delete)
- Deleting a project cascade-deletes its tasks
- Deleting a task cascade-deletes its subtasks

---

## Storage

Rich text fields (`titleRTF`, `descRTF`) are the single source of truth. There is no separate plain-text field — `plainTitle` and `plainDesc` are derived on demand. RTF (not RTFD) is used so the data round-trips cleanly through SwiftData without attachment blobs.

## Ordering

Tasks are ordered by `sortIndex` within their context (root tasks within a project, subtasks within their parent), set by drag-and-drop and by insert position. The shared `TaskListView.taskOrder` comparator sorts incomplete tasks by `sortIndex`, then sinks completed tasks to the bottom ordered by `completedAt` (newest first). `createdAt` is only a tiebreaker and the basis for a one-time `sortIndex` backfill of pre-existing data.

---

## Views

| View | Purpose |
|------|---------|
| `ContentView` | Root `NavigationSplitView`; hosts the sidebar and the selected detail (a project, All Projects, Upcoming, or Report), and the Backups sheet. Picks the launch view from settings (last project / All Projects / Upcoming) |
| `TaskListView` | Tasks for a single selected project; filter (All/Active/Done), search, inline editing, indent/unindent, and drag-to-reorder/nest |
| `TaskDragController` | `@Observable` engine holding all drag state + logic for reorder/nest/promote |
| `AllTasksView` | Tasks across all projects; filter, search, group-by (Project or Priority), and a "Completed" section at the bottom |
| `TaskDetailView` | Full detail for a single task — rich text title/description, subtask list, priority, reminder, completion |
| `ReportView` | Day-by-day log of tasks completed in a chosen date range (presets + custom), with a created/completed/active-days summary. Opened from a toolbar button. Grouping is a pure `ReportBuilder` (in `ReportData.swift`), unit-tested. Completed subtasks are hidden by default (parent/standalone tasks only); the "Include subtasks" setting shows them flat |
| `UpcomingView` | Cross-project list of tasks with reminders, grouped by due time (Overdue/Today/Tomorrow/This week/Later). Optional sidebar entry (off by default, toggled in Settings). Bucketing is a pure `UpcomingBuilder` (in `UpcomingData.swift`), unit-tested |
| `ProjectListView` | Sidebar: "All Projects" and (optionally) "Upcoming" entries, the project list under a "Projects" heading, a Report toolbar button, and a Settings gear at the foot |
| `SettingsView` | Tabbed Settings window (General, Tasks, Reminders, Appearance), opened via ⌘, or the sidebar gear |
| `BackupView` | Backup management sheet — view, create, restore, rename, and pin; opened from the Backups menu command |
| `RecoveryView` | Shown at the scene root when the store fails to open. Leaves data in place; offers Try Again and a unified **Restore Data** picker (backups, previously set-aside/Quarantine stores, and a JSON export in one sheet), plus Export Diagnostics and a confirmed Start Fresh. The picker hides sources this build can't open (cheap `PersistenceController.looksOpenable` filter, with an "N hidden" note) and fully trial-opens (`canOpen`) the selected one before touching the live store, warning instead of stranding the user. A store written by a newer build shows a distinct "update to open" variant |
| `WhatsNewView` | Per-version highlights, shown once after an update and via Help → What's New |
| `ReminderPopover` / `ReminderToast` | Reminder date/time picker and the in-app banner shown when one fires |

## Non-model managers

| Type | Purpose |
|------|---------|
| `TaskStore` | All task mutations (add/delete/complete/indent/reorder) with undo registration. Records structural mutations to `DiagnosticLog` |
| `ProjectStore` | Project mutations. Records create/update/delete (with task count) to `DiagnosticLog` |
| `DiagnosticLog` | Bounded (500-entry) in-memory ring buffer of structural mutations — op name, 8-char id prefixes, and counts only, never task text — mirrored to the unified log. Backs Export Diagnostics; the export leads with an app/macOS version header. Also hosts `checkProjectMembership`, an invariant tripwire that logs a violation when a task is reachable from zero or multiple projects |
| `BackupManager` | Auto / manual / pre-restore backups. Snapshots the live store with SQLite's `VACUUM INTO` — a WAL checkpoint then a single-transaction copy, so the snapshot is consistent and self-contained (no `-wal`/`-shm` sidecars); `restore(backup:)` rewrites the live store from a snapshot in place, keeping a single rolling pre-restore safety backup. `restoreStoreFile(at:)` is the recovery-path variant used when no live container exists — it swaps any `.store` file (a backup or a set-aside store) in as the live store after setting the current one aside |
| `StoreFingerprint` | A store's content mark — task count, latest created/completed time, and a content size (RTF byte lengths + mutable scalars) — read straight from SQLite or computed from live models. Backs the auto-backup "skip if unchanged" check and duplicate pruning. The `read` SQL and `fromTasks` must stay term-for-term identical; `liveAndFileFingerprintsAgree` enforces it. Includes content size because count+dates alone are blind to text edits, which silently suppressed auto-backups for the length of an editing session |
| `ReminderManager` | Schedules local notifications and handles their actions (Mark Done, Snooze). Reads `AppSettings` for the notification-sound preference. Re-schedules all future reminders on launch so the app — not the system's pending queue — is the source of truth |
| `AppSettings` | Persisted user preferences (theme, accent, task defaults, project-delete confirmation, report subtask visibility, reminder snooze/preset/hour/sound, sidebar and on-launch options), surfaced in the tabbed Settings window |

## Persistence & migration

| Type | Purpose |
|------|---------|
| `PersistenceController` | Owns store bring-up: takes a pre-migration backup, opens the container with the migration plan, and on failure LEAVES the store in place and reports `.failed` (never auto-moves or deletes). A **downgrade guard** refuses to open a store recorded as a newer schema version than this build knows (`onDiskVersion` vs `QuillpointSchema.newestKnownVersion`), so an older build can't silently rewrite a newer store. `startFresh(storeURL:)` moves the store to a Quarantine folder only on an explicit, confirmed user action; `quarantinedStores(storeURL:)` lists those for the recovery picker. `looksOpenable` (cheap metadata check) and `canOpen` (full trial-open on a copy) back the recovery picker's filtering and final guard |
| `QuillpointSchema` / `QuillpointMigrationPlan` | The current schema (latest `VersionedSchema`) and the ordered migration stages. `SchemaV1` (frozen, in `SchemaV1Models`) must match the shape shipped in 1.0.x exactly; `SchemaV2` makes `Task.project` non-optional with a custom stage that backfills orphans via `ProjectBackfill` |
