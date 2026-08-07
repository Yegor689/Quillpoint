import Foundation
import SwiftData
import SQLite3

enum BackupKind: String {
    case auto       = "auto"
    case manual     = "manual"
    /// A snapshot of the store taken automatically right before a restore, so a
    /// destructive restore is always reversible. Never auto-pruned.
    case preRestore = "prerestore"
}

struct Backup: Identifiable, Comparable {
    let id = UUID()
    let url: URL
    let date: Date
    let name: String
    let kind: BackupKind
    /// User label ("" if none). Editable via BackupManager.rename.
    let label: String
    /// Pinned backups are protected from auto-pruning and float to the top.
    let isPinned: Bool
    /// Content fingerprint read from the backup file (task count + latest activity), or
    /// nil if unreadable. Lets the UI show a backup's REAL content age — distinct from
    /// `date`, which is only the write time and can misrepresent stale content.
    let fingerprint: StoreFingerprint?

    /// Newest first; pinned always above unpinned within a sort.
    static func < (lhs: Backup, rhs: Backup) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.date > rhs.date
    }
}

/// The single source of truth for the backup filename grammar. Every backup is a
/// bare `.store` file whose stem encodes all its metadata; this parses and rebuilds
/// that stem so the format lives in exactly one place.
///
/// Grammar: `{kind}-[pin-]{yyyy-MM-dd HH-mm-ss}[ {label}]`
/// - `kind` prefix stays first so existing kind detection is unaffected.
/// - optional `pin-` token marks a pinned backup.
/// - fixed-width timestamp.
/// - optional free-text label as the trailing remainder.
struct BackupName {
    var kind: BackupKind
    var isPinned: Bool
    var date: Date
    var label: String

    private static let pinToken = "pin-"

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    /// Parses a filename stem (no extension). Returns nil if it isn't a valid backup.
    static func parse(_ stem: String) -> BackupName? {
        let kind: BackupKind
        let afterKind: Substring
        if stem.hasPrefix("prerestore-") { kind = .preRestore; afterKind = stem.dropFirst("prerestore-".count) }
        else if stem.hasPrefix("auto-")   { kind = .auto;       afterKind = stem.dropFirst("auto-".count) }
        else if stem.hasPrefix("manual-") { kind = .manual;     afterKind = stem.dropFirst("manual-".count) }
        else { return nil }

        var rest = afterKind
        var pinned = false
        if rest.hasPrefix(pinToken) { pinned = true; rest = rest.dropFirst(pinToken.count) }

        // The timestamp is the first two space-separated fields ("date time").
        let fields = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2,
              let date = timestampFormatter.date(from: "\(fields[0]) \(fields[1])")
        else { return nil }

        let label = fields.count > 2 ? String(fields[2]) : ""
        return BackupName(kind: kind, isPinned: pinned, date: date, label: label)
    }

    /// Rebuilds the filename stem (no extension) from the fields.
    func stem() -> String {
        let ts = Self.timestampFormatter.string(from: date)
        let cleaned = Self.sanitize(label)
        var s = "\(kind.rawValue)-"
        if isPinned { s += Self.pinToken }
        s += ts
        if !cleaned.isEmpty { s += " \(cleaned)" }
        return s
    }

    /// Makes a label safe to embed in a filename without breaking parsing:
    /// no path separators or control characters, collapsed whitespace, length-capped.
    static func sanitize(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && !CharacterSet.controlCharacters.contains(scalar)
        }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(80))
    }
}

@Observable
final class BackupManager {
    private let storeURL: URL
    private let backupDir: URL
    private let defaults: UserDefaults
    /// The live model container. Restore mutates this directly so the UI updates
    /// in place — the same proven path the sample seeder uses — instead of swapping
    /// the store file or relaunching. Set by the app after construction.
    @ObservationIgnored var liveContainer: ModelContainer?

    private static let maxAutoBackups = 10
    /// Cap on pre-restore/pre-migration safety backups. These are `.preRestore` kind and
    /// were previously never pruned, so a repeated pre-migration backup (or many restores)
    /// grew them without bound. Keep a small rolling window of the most recent ones.
    private static let maxPreRestoreBackups = 5
    private static let intervalDefaultsKey = "autoBackupIntervalHours"

    /// Selectable auto-backup intervals. `nil` rawValue (0) means disabled.
    static let intervalOptions = [0, 1, 6, 12, 24]

    private(set) var backups: [Backup] = []
    private var timer: Timer?

    /// How often to auto-back-up, in hours. 0 = off. Persisted in UserDefaults.
    var autoBackupIntervalHours: Int {
        didSet {
            defaults.set(autoBackupIntervalHours, forKey: Self.intervalDefaultsKey)
            scheduleTimer()
        }
    }

    var autoBackups:       [Backup] { backups.filter { $0.kind == .auto       } }
    var manualBackups:     [Backup] { backups.filter { $0.kind == .manual     } }
    var preRestoreBackups: [Backup] { backups.filter { $0.kind == .preRestore } }
    /// All pinned backups regardless of kind — for the UI's dedicated "Pinned"
    /// section. Purely additive; the kind lists above are unchanged (a pinned backup
    /// still appears in its kind list too, so the VIEW is responsible for showing it
    /// in only one section).
    var pinnedBackups:     [Backup] { backups.filter { $0.isPinned } }

    /// - Parameters:
    ///   - storeURL: the SwiftData store to back up / restore into.
    ///   - backupDir: where backup files live. Defaults to the production location;
    ///     tests pass a temporary directory so they never touch production data.
    ///   - defaults: the UserDefaults used for the auto-backup interval. Tests pass
    ///     an isolated suite so they don't read or pollute production preferences.
    init(storeURL: URL,
         backupDir: URL = URL.applicationSupportDirectory
            .appending(component: "TaskTrackerBackups", directoryHint: .isDirectory),
         defaults: UserDefaults = .standard) {
        self.storeURL = storeURL
        self.backupDir = backupDir
        self.defaults = defaults
        // Default to daily (24h) on first run if nothing stored yet.
        if defaults.object(forKey: Self.intervalDefaultsKey) == nil {
            self.autoBackupIntervalHours = 24
        } else {
            self.autoBackupIntervalHours = defaults.integer(forKey: Self.intervalDefaultsKey)
        }
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        refresh()
    }

    // Called on launch: backs up if the configured interval has elapsed since the
    // last auto-backup, then arms the timer so interval backups keep running while
    // the app stays open. (Launch backups are simply "is one due?" — no separate
    // toggle.)
    func startAutoBackup() {
        createAutoBackupIfDue()
        scheduleTimer()
    }

    /// Creates an auto-backup if the configured interval has elapsed AND the data has
    /// actually changed since the last auto-backup. The content check is the important
    /// half: without it, a store that stops changing (a stale/frozen store, e.g. after an
    /// older build detached the live data) still gets a fresh backup every interval —
    /// filling the pruning window with identical snapshots and evicting the last genuinely
    /// distinct backup. Backing up unchanged data isn't a backup; it's noise that crowds
    /// out real history.
    private func createAutoBackupIfDue() {
        guard autoBackupIntervalHours > 0 else { return }
        let interval = TimeInterval(autoBackupIntervalHours) * 3600
        if let latest = autoBackups.first, Date().timeIntervalSince(latest.date) < interval { return }

        // Skip if the live store's content matches the newest auto-backup's — nothing to
        // capture. The live fingerprint is computed from the open CONTEXT, not by reading
        // the store file: the live store is WAL-mode and recent edits may not be
        // checkpointed into the base file yet, so a file read could see stale content and
        // wrongly skip. Backup files, by contrast, are self-contained (online-backup
        // output, no WAL) and safe to read. Only skip on a CONFIDENT match; if the live
        // fingerprint is unavailable, fall through and back up (never skip on uncertainty).
        if let latestAuto = autoBackups.first,
           let lastFP = latestAuto.fingerprint,
           let liveFP = liveFingerprint(),
           liveFP == lastFP {
            return
        }

        createBackup(kind: .auto)
        pruneAutoBackups()
    }

    /// The live store's current content fingerprint, computed from the OPEN context (which
    /// always reflects the latest edits, unlike a separate connection's view of the WAL).
    /// Its arithmetic MUST match `StoreFingerprint.read`'s SQL exactly — a dedicated test
    /// (`liveAndFileFingerprintsAgree`) enforces that, so the skip/dedup comparison between
    /// a live fingerprint and a backup-file fingerprint is always valid.
    private func liveFingerprint() -> StoreFingerprint? {
        guard let liveContainer,
              let tasks = try? liveContainer.mainContext.fetch(FetchDescriptor<Task>())
        else { return nil }
        return StoreFingerprint.fromTasks(tasks)
    }

    /// How often we wake up to check whether an auto-backup is due. We poll rather
    /// than scheduling a single fire at the full interval so that a backup happens
    /// `interval` after the *last backup* (not after launch), and so it still fires
    /// for a long-running app even across system sleep, where a one-shot long timer
    /// is unreliable.
    private static let dueCheckCadence: TimeInterval = 5 * 60

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard autoBackupIntervalHours > 0 else { return }
        let t = Timer(timeInterval: Self.dueCheckCadence, repeats: true) { [weak self] _ in
            self?.createAutoBackupIfDue()
        }
        t.tolerance = Self.dueCheckCadence * 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        backups = files.compactMap { url -> Backup? in
            guard url.pathExtension == "store" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            // The filename is the source of truth for kind/date/label/pin (the file's
            // own creation date is unreliable — the online backup inherits the source
            // store's). Fall back to creation date only if the timestamp won't parse.
            guard let parsed = BackupName.parse(stem) else { return nil }
            return Backup(url: url, date: parsed.date, name: stem,
                          kind: parsed.kind, label: parsed.label, isPinned: parsed.isPinned,
                          fingerprint: StoreFingerprint.read(from: url))
        }.sorted()
    }

    @discardableResult
    func createBackup(label: String = "", kind: BackupKind = .manual) -> Backup? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }

        let name = BackupName(kind: kind, isPinned: false, date: Date(),
                              label: BackupName.sanitize(label)).stem()
        let dest = backupDir.appending(component: "\(name).store")

        guard Self.snapshot(liveContainer: liveContainer, storeURL: storeURL, to: dest) else { return nil }

        refresh()
        // Pre-restore/pre-migration safety backups are capped so they can't grow without
        // bound (they are never pinned and aren't covered by the auto-backup prune).
        if kind == .preRestore { prunePreRestoreBackups() }
        // Return the backup we just wrote — identified by its stem, NOT `backups.first`.
        // `backups` is sorted pinned-first, so `.first` can be an older pinned backup
        // rather than this newly-created (never-pinned) one.
        return backups.first { $0.name == name }
    }

    /// Writes a consistent, self-contained snapshot of the live store to `dest` using
    /// `VACUUM INTO` — the approach Apple/SQLite guidance recommends for WAL-mode stores.
    /// It runs as a single SQLite transaction and produces a fully self-contained file
    /// with NO -wal/-shm sidecars, so a snapshot can never be an inconsistent trio and a
    /// backup file is always safe to read/restore on its own.
    ///
    /// Coordination is the key correctness point (the previous online-backup path opened
    /// a SECOND connection to a store SwiftData already held open — the pattern that
    /// caused flaky reads and lock contention). Here we:
    ///   1. Save the live context (flush pending edits to the WAL), and
    ///   2. Checkpoint the WAL into the base file,
    /// through the app's own store BEFORE snapshotting, so the base file is complete and
    /// the VACUUM sees every committed change. Returns true on success; on any failure the
    /// partial destination is removed so a half-written file is never left behind.
    @discardableResult
    private static func snapshot(liveContainer: ModelContainer?, storeURL: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        for e in ["-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: dest.path + e)) }

        // Flush the live context so recent edits are in the store, then checkpoint the
        // WAL into the base file. Both are best-effort: if there's no live container
        // (e.g. pre-migration backup before the app wires one up), the on-disk store is
        // already the source of truth.
        if let liveContainer {
            try? liveContainer.mainContext.save()
        }
        checkpoint(storeURL: storeURL)

        // VACUUM INTO a fresh destination. Single transaction, self-contained output.
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        // Bind the destination path as a parameter so a path with quotes/spaces is safe.
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "VACUUM INTO ?;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, dest.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) // SQLITE_TRANSIENT
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        if !ok {
            try? fm.removeItem(at: dest)
            return false
        }
        return true
    }

    /// Checkpoints the store's WAL into its base file so the base file reflects all
    /// committed changes. Uses a short-lived read/write connection; TRUNCATE mode also
    /// resets the WAL. Best-effort — a failure just means the VACUUM reads slightly less
    /// current base data, which the live-context save above has already minimized.
    private static func checkpoint(storeURL: URL) {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    enum RestoreError: Error, LocalizedError {
        case noLiveContainer
        /// The pre-restore safety backup couldn't be written, so a restore would wipe the
        /// current data with no way back. We refuse rather than proceed unprotected.
        case safetyBackupFailed
        /// A task in the backup references a project that isn't in the backup — the
        /// snapshot is internally inconsistent. Surfaced instead of silently refiling.
        case inconsistentBackup(orphanTaskCount: Int)

        var errorDescription: String? {
            switch self {
            case .noLiveContainer:
                return "Quillpoint isn't ready to restore yet."
            case .safetyBackupFailed:
                return "Couldn't save a safety backup of your current data, so the restore was cancelled. Your current data is unchanged."
            case .inconsistentBackup(let n):
                return "This backup is damaged (\(n) task\(n == 1 ? "" : "s") reference a missing project) and wasn't restored. Your current data is unchanged."
            }
        }
    }

    /// Restores a backup IN PLACE: reads the backup with a throwaway container and
    /// rewrites the live store's contents to match, so the UI updates immediately —
    /// no relaunch, no swapping the store file under the open SwiftData connection.
    /// Replaces ALL projects/tasks with the snapshot.
    ///
    /// Each task/project is recreated by copying its fields onto a fresh model.
    /// There is no field-agnostic clone: SwiftData's backing data is bound to its
    /// source store and does not transfer across the backup→live boundary, so the
    /// field list is necessarily explicit here. Relationships are wired by id,
    /// setting BOTH sides (`project.tasks.append`, `parent.subtasks.append`);
    /// setting only the to-one side leaves the inverse collections empty, which
    /// made an earlier attempt render nothing.
    @MainActor
    func restore(backup: Backup) throws {
        guard let liveContainer else { throw RestoreError.noLiveContainer }
        let live = liveContainer.mainContext

        // 1. Read the backup FIRST (separate container, live one untouched) and validate
        //    it before touching any live data — so a bad backup can never leave the app
        //    in a half-wiped state. Uses the versioned schema + plan so an older backup
        //    migrates forward on read, same as the live store would.
        let schema = QuillpointSchema.current
        let config = ModelConfiguration(schema: schema, url: backup.url)
        let source = ModelContext(try ModelContainer(for: schema,
                                                     migrationPlan: QuillpointMigrationPlan.self,
                                                     configurations: config))
        let sourceProjects = try source.fetch(FetchDescriptor<Project>())
        let sourceTasks = try source.fetch(FetchDescriptor<Task>())

        // Validate internal consistency: every task's project must be present in the
        // backup. An orphan means the snapshot is damaged; refuse rather than silently
        // refiling the task under a wrong project (which would hide the corruption).
        let sourceProjectIDs = Set(sourceProjects.map(\.id))
        let orphans = sourceTasks.filter { !sourceProjectIDs.contains($0.project.id) }
        guard orphans.isEmpty else {
            throw RestoreError.inconsistentBackup(orphanTaskCount: orphans.count)
        }

        // 2. Take the rolling pre-restore safety backup. If it FAILS, abort — never wipe
        //    the current data without a way back. (Skip when restoring a pre-restore
        //    backup, which would otherwise back up the very thing we're rolling back to.)
        if backup.kind != .preRestore {
            try? live.save() // flush pending edits so the safety snapshot is current
            guard createBackup(label: "before restore", kind: .preRestore) != nil else {
                throw RestoreError.safetyBackupFailed
            }
            // Only remove OLDER pre-restore backups after the new one succeeded, so we're
            // never left with none. (Keep the newest; drop the rest.)
            preRestoreBackups.dropFirst().forEach { delete(backup: $0) }
        }

        // 3. Now it's safe to wipe and recreate — validation and safety backup both passed.
        for project in try live.fetch(FetchDescriptor<Project>()) { live.delete(project) }
        for task in try live.fetch(FetchDescriptor<Task>()) { live.delete(task) }

        var liveProjectsByID: [UUID: Project] = [:]
        for sp in sourceProjects {
            let project = sp.cloneScalars()
            live.insert(project)
            liveProjectsByID[sp.id] = project
        }

        // Every task's project is guaranteed present (validated above), so this is a
        // direct lookup — no silent fallback.
        var liveTasksByID: [UUID: Task] = [:]
        for st in sourceTasks {
            guard let mapped = liveProjectsByID[st.project.id] else {
                // Unreachable given the orphan check, but fail loudly rather than refile.
                throw RestoreError.inconsistentBackup(orphanTaskCount: 1)
            }
            let task = st.cloneScalars(into: mapped)
            live.insert(task)
            mapped.tasks.append(task)
            liveTasksByID[st.id] = task
        }

        // Wire the parent/subtask relationships by id, setting BOTH sides so inverse
        // collections hydrate. (Project is already set at creation above.)
        for st in sourceTasks {
            guard let task = liveTasksByID[st.id] else { continue }
            if let parentID = st.parent?.id, let parent = liveTasksByID[parentID] {
                task.parent = parent
                parent.subtasks.append(task)
            }
        }

        try live.save()
    }

    /// Restores a backup by REPLACING the store file on disk, used by the recovery
    /// screen where no live container exists (the store failed to open, so the normal
    /// in-place `restore(backup:)` — which mutates a live container — can't run).
    ///
    /// The current (unreadable) store is moved to Quarantine first, never deleted, so
    /// this is reversible. After it returns, the caller re-runs bring-up, which opens
    /// the restored store (migrating it forward through the plan if it's older).
    func restoreFromFile(backup: Backup) throws {
        try restoreStoreFile(at: backup.url)
    }

    /// Restores any `.store` file (a backup OR a quarantined store) by REPLACING the
    /// live store on disk. The current store is moved to Quarantine first (never
    /// deleted), so this is reversible; the caller then re-runs bring-up.
    ///
    /// Ordering matters: the source is copied to a temp location BEFORE the live store
    /// is moved aside, so a copy failure (bad source, disk full, permissions) throws
    /// while the live store is still in place — never leaving the app with no store.
    /// Only once the copy has succeeded do we set the current store aside and move the
    /// staged copy into place.
    func restoreStoreFile(at sourceURL: URL) throws {
        let fm = FileManager.default

        // Stage the source into a temp file first — this is the step that can fail.
        let staged = fm.temporaryDirectory.appending(component: "restore-\(UUID().uuidString).store")
        defer { for e in ["", "-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: staged.path + e)) } }
        try fm.copyItem(at: sourceURL, to: staged)
        for ext in ["wal", "shm"] {
            let side = sourceURL.appendingPathExtension(ext)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: staged.appendingPathExtension(ext)) }
        }

        // Copy succeeded — now it's safe to set the current store aside and swap in the
        // staged copy. Reuses the same Quarantine location as "Start Fresh".
        PersistenceController.startFresh(storeURL: storeURL)
        try fm.moveItem(at: staged, to: storeURL)
        for ext in ["wal", "shm"] {
            let side = staged.appendingPathExtension(ext)
            if fm.fileExists(atPath: side.path) { try? fm.moveItem(at: side, to: storeURL.appendingPathExtension(ext)) }
        }
    }

    func delete(backup: Backup) {
        deleteFile(backup)
        refresh()
    }

    /// Removes a backup's files without refreshing — for batch deletes (prune) that
    /// refresh once at the end instead of after every removal.
    private func deleteFile(_ backup: Backup) {
        let fm = FileManager.default
        try? fm.removeItem(at: backup.url)
        // SQLite names its sidecars "<store>-wal"/"<store>-shm", NOT "<store>.wal".
        // appendingPathExtension produced the latter, so these removals silently
        // no-opped and any sidecar was left behind — and an orphaned -wal outliving
        // its .store could later attach to a new backup that reuses the filename.
        // Same string-append form the snapshot/restore paths already use.
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: backup.url.path + suffix))
        }
    }

    /// Prunes AUTO backups, NEVER deleting a pinned one (pinning keeps an auto backup
    /// indefinitely). Two passes:
    ///
    /// 1. Content dedup — among unpinned auto backups, keep only the NEWEST of each
    ///    distinct content fingerprint and delete the older duplicates. This is what
    ///    stops a frozen store from filling the window with identical snapshots that
    ///    evict genuinely different older states. Backups with an unreadable fingerprint
    ///    are treated as distinct (never deduped away on uncertainty).
    /// 2. Count cap — trim whatever distinct backups remain down to `maxAutoBackups`,
    ///    newest first.
    private func pruneAutoBackups() {
        let unpinned = autoBackups.filter { !$0.isPinned } // sorted newest first

        // Pass 1: drop older duplicates of an already-seen fingerprint.
        var seen = Set<String>()
        var distinct: [Backup] = []
        var toDelete: [Backup] = []
        for b in unpinned { // newest first, so the first of each fingerprint is the keeper
            if let fp = b.fingerprint {
                let key = "\(fp.taskCount):\(fp.latestActivity)"
                if seen.contains(key) { toDelete.append(b); continue }
                seen.insert(key)
            }
            distinct.append(b)
        }

        // Pass 2: enforce the count cap on the surviving distinct backups.
        toDelete.append(contentsOf: distinct.dropFirst(Self.maxAutoBackups))

        guard !toDelete.isEmpty else { return }
        toDelete.forEach { deleteFile($0) }
        refresh()
    }

    /// Trims pre-restore/pre-migration backups to the newest `maxPreRestoreBackups`,
    /// never deleting a pinned one. Keeps a small rolling safety window instead of the
    /// previous unbounded growth.
    private func prunePreRestoreBackups() {
        let prunable = preRestoreBackups.filter { !$0.isPinned } // sorted newest first
        let excess = Array(prunable.dropFirst(Self.maxPreRestoreBackups))
        guard !excess.isEmpty else { return }
        excess.forEach { deleteFile($0) }
        refresh()
    }

    // MARK: - Rename / pin (filename is the source of truth)

    /// Gives a backup a new user label (or clears it when empty). Renames the file
    /// in place, preserving kind, pin state, and timestamp. No-op if the target name
    /// already exists (shouldn't happen — timestamp is unique).
    func rename(_ backup: Backup, to label: String) {
        guard var parsed = BackupName.parse(backup.name) else { return }
        parsed.label = BackupName.sanitize(label)
        moveBackup(backup, toStem: parsed.stem())
    }

    /// Pins or unpins a backup. Pinned backups survive auto-pruning and sort to the
    /// top. Implemented by adding/removing the `pin-` token in the filename.
    func setPinned(_ backup: Backup, _ pinned: Bool) {
        guard var parsed = BackupName.parse(backup.name), parsed.isPinned != pinned else { return }
        parsed.isPinned = pinned
        moveBackup(backup, toStem: parsed.stem())
    }

    /// Renames a backup's `.store` (and any `-wal`/`-shm` sidecars) to a new stem,
    /// then refreshes. Sidecars normally don't exist (the online backup writes a
    /// single self-contained file), but move them if present so nothing is orphaned.
    private func moveBackup(_ backup: Backup, toStem newStem: String) {
        let fm = FileManager.default
        let dest = backupDir.appending(component: "\(newStem).store")
        guard dest != backup.url, !fm.fileExists(atPath: dest.path) else { return }
        do {
            try fm.moveItem(at: backup.url, to: dest)
        } catch {
            return
        }
        for ext in ["wal", "shm"] {
            let side = backup.url.appendingPathExtension(ext)
            if fm.fileExists(atPath: side.path) {
                try? fm.moveItem(at: side, to: dest.appendingPathExtension(ext))
            }
        }
        refresh()
    }
}
