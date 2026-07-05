# Migration Architecture for Quillpoint

*Safe schema evolution for live customer data. Saved for later — not yet implemented.*

## Context

The app persists with SwiftData but has **no schema versioning** — `TaskTrackerApp.init`
builds `Schema([Project.self, Task.self])` directly with no `VersionedSchema` /
`SchemaMigrationPlan`. Today that works only because every change so far has been
additive (SwiftData's implicit lightweight migration). The next change —
making `Task.project` non-optional (there is no domain reason for it to be optional;
it's what made the inferred inverse unreliable and caused #26) — is a **breaking**
migration that requires a data backfill (assign a project to any task whose
`project` is nil) and cannot be done implicitly.

Worse, the current failure path is a **data-loss trap**: if the container fails
to open (exactly what a failed migration does), `TaskTrackerApp.init` does
`FileManager.removeItem(storeURL)` and recreates an **empty** store
(`TaskTrackerApp.swift:22-29`). For a live customer with old data, a migration bug
currently means silent total loss.

**Goal:** a reusable mechanism that lets us evolve the schema across releases so
**existing customer data is never corrupted or silently destroyed**, with the
`Task.project` change as its first real use.

### Decisions (agreed)
- **Engine:** SwiftData `VersionedSchema` + `SchemaMigrationPlan` as the backbone
  (idiomatic, least custom code), with custom migration stages for data backfill.
- **Failure policy:** **Quarantine + halt** — on any open/migration failure, move
  the live store aside to a timestamped quarantine copy (never delete) and show a
  recovery UI; replace the current rm-and-recreate entirely.

## Architecture

### 1. Versioned schema (new file `TaskTracker/Models/SchemaVersions.swift`)
- Wrap the current models in `enum SchemaV1: VersionedSchema` (versionIdentifier
  `1.0.0`) — `Task.project` stays `Project?` here, matching what's on disk for
  every existing user.
- `enum SchemaV2: VersionedSchema` (`2.0.0`) — `Task.project` becomes non-optional.
  V2 redeclares the models (SwiftData requires each version own its model types).
  Pragmatic idiom: keep the live `Project`/`Task` as the latest version's types,
  and capture V1 only as far as the migration needs to read the old nullable field.
- `enum QuillpointMigrationPlan: SchemaMigrationPlan` with
  `schemas = [SchemaV1, SchemaV2]` and one
  `MigrationStage.custom(fromV1, toV2, willMigrate:didMigrate:)`.

### 2. The V1→V2 data backfill (in the custom stage's `willMigrate`/`didMigrate`)
- Before the structural change is enforced, find every `Task` with `project == nil`
  and assign one. Preference order: the task's `parent?.project`; else a dedicated
  **"Unfiled"/"Inbox" project** created on the fly (so we never invent a wrong
  association and never drop a task). Guarantees the not-null constraint is
  satisfiable for all rows. Reuse `TaskStore.orderedRoots` / append patterns.
- This stage is also the single home for any future backfill/cleanup —
  "fix the data to fit the new shape."

### 3. Safe container bring-up (rewrite `TaskTrackerApp.init`, new `TaskTracker/PersistenceController.swift`)
Replace the inline container creation + the rm-and-recreate block with a small
`PersistenceController` that owns the bring-up sequence:
1. **Pre-migration backup gate:** before opening with the new plan, detect whether
   a migration will run (store's on-disk version < latest). If so, take a labeled
   safety backup via the existing `BackupManager.sqliteOnlineBackup` /
   `createBackup(label: "before migration vN→vM", kind: .preRestore)` — reuse, don't
   reinvent. (Restructure so the backup primitive is callable before the live
   container exists — it only needs `storeURL`, which it already has.)
2. Open: `ModelContainer(for: latestSchema, migrationPlan: QuillpointMigrationPlan.self, configurations:)`.
3. **On failure → quarantine + halt:** move `TaskTracker.store` (+ `-wal`/`-shm`) to
   `…/Quarantine/TaskTracker-<timestamp>.store` (copy/move, **never delete**), then
   surface a recovery state to the UI instead of constructing an empty store.
   No more `FileManager.removeItem(storeURL)`.

### 4. Recovery UI (new `TaskTracker/Views/RecoveryView.swift`)
When bring-up fails, `ContentView` shows a recovery screen instead of the task
list: explains data was preserved (quarantined), and offers **Restore from Backup**
(drives existing `BackupManager.restore` / Backups UI), **Retry**, and **Export
Diagnostics** (existing `DiagnosticLog.exportText`). Wire via a published
`PersistenceController.state` (`.ready(container)` / `.failed(reason, quarantineURL)`).

### 5. Make `Task.project` non-optional (the first real migration)
- `Models/Task.swift`: `var project: Project` (drop `?`); drop the `= nil` default
  from `init`. Update `cloneScalars()` neighbors as needed.
- `Models/Project.swift`: keep the explicit `inverse: \Task.project` (now required
  on both sides — even cleaner).
- Collapse the now-unnecessary nil handling: `guard let … = task.project` sites in
  `TaskStore.swift:211,247,339` become direct access; `task.project?.title` / `?.id`
  in `TaskListView.swift:372,505` and `AllTasksView.swift:41` lose the `?`.
- `BackupManager.restore` (line 255): the `if let pid = st.project?.id` becomes
  required; a backup row with no project gets the same Unfiled fallback as the
  migration (keep restore and migration using one shared backfill helper so they
  can't diverge).

### 6. Tests (`TaskTrackerTests/MigrationTests.swift`, on-disk stores per the beta-toolchain memory)
- **Seed a V1 store** (nullable project, including a task with `project == nil` and a
  subtask whose parent has a project), open it through the plan, assert: V2 opens,
  no task lost, every previously-nil task now has a project (parent's project or
  Unfiled), counts preserved.
- **Quarantine path:** point the controller at a deliberately corrupt store; assert
  it is moved to Quarantine (still exists there) and NOT deleted, and state is `.failed`.
- **Pre-migration backup:** assert a `.preRestore`-kind backup exists after a
  migrating open.
- Use unique on-disk `ModelConfiguration(url:)` — `isStoredInMemoryOnly` SIGTRAPs on
  the current macOS/Xcode 27 beta toolchain.

## Sequencing (suggested commits, on a branch e.g. `feat/migration-framework`)
1. `PersistenceController` + quarantine-on-failure (no behavior change for healthy
   stores; removes the data-loss trap). Recovery UI.
2. `VersionedSchema` scaffolding (V1 only) + `MigrationPlan` wired in, latest == V1
   (no migration runs yet) — proves the plumbing on real data without a schema diff.
3. Add V2 + the `project`-non-optional change + shared Unfiled backfill + migration
   stage. This is the first migration that actually runs.
4. Tests.

This order lands the **safety net before the first breaking migration uses it**.

## Verification
- `xcodebuild build -scheme TaskTracker -destination 'platform=macOS'` clean.
- `xcodebuild test … -only-testing:TaskTrackerTests/MigrationTests` green
  (V1→V2 backfill, quarantine, pre-migration backup).
- **Manual in Xcode (critical, real customer path):** copy an existing real
  `TaskTracker.store` (V1 data with tasks) into place, launch via Xcode, confirm all
  tasks survive, nil-project tasks land in Unfiled, and a "before migration" backup
  appears in Backups. Then corrupt a store and confirm the recovery screen shows
  (data quarantined, not deleted).
- User verifies in Xcode (do not launch the app from the shell).

## Reusable assets already in the codebase
- `BackupManager.sqliteOnlineBackup` / `createBackup(kind:)` / `restore(backup:)` —
  consistent WAL-safe snapshots + reversible in-place restore + pre-restore snapshots.
- `DiagnosticLog.shared.exportText()` — for the recovery screen's diagnostics export.
- `cloneScalars()` on `Task`/`Project` — field-explicit copy used by restore.
