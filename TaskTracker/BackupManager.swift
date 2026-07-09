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

    /// Creates an auto-backup if the configured interval has elapsed since the last one.
    private func createAutoBackupIfDue() {
        guard autoBackupIntervalHours > 0 else { return }
        let interval = TimeInterval(autoBackupIntervalHours) * 3600
        if let latest = autoBackups.first, Date().timeIntervalSince(latest.date) < interval { return }
        createBackup(kind: .auto)
        pruneAutoBackups()
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
                          kind: parsed.kind, label: parsed.label, isPinned: parsed.isPinned)
        }.sorted()
    }

    @discardableResult
    func createBackup(label: String = "", kind: BackupKind = .manual) -> Backup? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }

        let name = BackupName(kind: kind, isPinned: false, date: Date(),
                              label: BackupName.sanitize(label)).stem()
        let dest = backupDir.appending(component: "\(name).store")

        // Snapshot via SQLite's online backup API rather than copying the files.
        // The live store is WAL-mode and the app has it open, so recent changes
        // (e.g. just-toggled completion or priority) live in the -wal, not yet in
        // the base .store. A plain file copy captured an inconsistent trio, so a
        // restore could lose those recent changes — or everything. The backup API
        // reads the live DB consistently and writes a single self-contained file
        // with no -wal/-shm dependency.
        guard Self.sqliteOnlineBackup(from: storeURL, to: dest) else { return nil }

        refresh()
        return backups.first
    }

    /// Copies a live (possibly open, WAL-mode) SQLite database into `dest` as a
    /// single consistent, self-contained file using SQLite's online backup API.
    /// Returns true on success.
    private static func sqliteOnlineBackup(from src: URL, to dest: URL) -> Bool {
        try? FileManager.default.removeItem(at: dest)

        var srcDB: OpaquePointer?
        var dstDB: OpaquePointer?
        defer { sqlite3_close(srcDB); sqlite3_close(dstDB) }

        guard sqlite3_open_v2(src.path, &srcDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(dest.path, &dstDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else { return false }

        guard let backup = sqlite3_backup_init(dstDB, "main", srcDB, "main") else { return false }
        sqlite3_backup_step(backup, -1) // copy all pages
        let rc = sqlite3_backup_finish(backup)
        return rc == SQLITE_OK
    }

    enum RestoreError: Error { case noLiveContainer }

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

        // Single rolling pre-restore safety backup so a restore is reversible
        // (#16: replace any previous one). Skip when restoring a pre-restore backup.
        if backup.kind != .preRestore {
            try? live.save() // flush pending edits so the safety snapshot is current
            preRestoreBackups.forEach { delete(backup: $0) }
            createBackup(label: "before restore", kind: .preRestore)
        }

        // Read the backup with a separate container so the live one is untouched.
        // Use the versioned schema + migration plan so an older backup migrates
        // forward on read, same as the live store would.
        let schema = QuillpointSchema.current
        let config = ModelConfiguration(schema: schema, url: backup.url)
        let source = ModelContext(try ModelContainer(for: schema,
                                                     migrationPlan: QuillpointMigrationPlan.self,
                                                     configurations: config))
        let sourceProjects = try source.fetch(FetchDescriptor<Project>())
        let sourceTasks = try source.fetch(FetchDescriptor<Task>())

        // Wipe current data (cascades delete tasks), then recreate from the snapshot.
        for project in try live.fetch(FetchDescriptor<Project>()) { live.delete(project) }
        for task in try live.fetch(FetchDescriptor<Task>()) { live.delete(task) }

        // Recreate each model by cloning its scalar fields (the field list lives on
        // the model's cloneScalars()), keyed by id. Relationships are wired below.
        var liveProjectsByID: [UUID: Project] = [:]
        for sp in sourceProjects {
            let project = sp.cloneScalars()
            live.insert(project)
            liveProjectsByID[sp.id] = project
        }

        // Recreate each task in its destination project. The source is read through
        // the migration plan, so `st.project` is already the (now non-optional) V2
        // shape; if a source row somehow still has no mapped project, fall back via
        // ProjectBackfill so a restored task is never left orphaned.
        var liveTasksByID: [UUID: Task] = [:]
        for st in sourceTasks {
            let mapped = liveProjectsByID[st.project.id]
                ?? liveProjectsByID.values.sorted { $0.title < $1.title }.first
                ?? { let p = Project(title: "Tasks"); live.insert(p); liveProjectsByID[p.id] = p; return p }()
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
        let fm = FileManager.default

        // Set the current store aside (recoverable), clearing the destination so the
        // copy lands cleanly. Reuses the same Quarantine location as "Start Fresh".
        PersistenceController.startFresh(storeURL: storeURL)

        // Copy the backup into place as the new live store. Sidecars normally don't
        // exist (the online backup writes a single self-contained file), but copy any
        // that do so the restored store is consistent.
        try fm.copyItem(at: backup.url, to: storeURL)
        for ext in ["wal", "shm"] {
            let side = backup.url.appendingPathExtension(ext)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: storeURL.appendingPathExtension(ext))
            }
        }
    }

    func delete(backup: Backup) {
        let fm = FileManager.default
        try? fm.removeItem(at: backup.url)
        try? fm.removeItem(at: backup.url.appendingPathExtension("wal"))
        try? fm.removeItem(at: backup.url.appendingPathExtension("shm"))
        refresh()
    }

    /// Prunes old AUTO backups down to `maxAutoBackups`, keeping the newest and
    /// NEVER deleting a pinned one — pinning is how a user keeps a specific auto
    /// backup indefinitely.
    private func pruneAutoBackups() {
        let prunable = autoBackups.filter { !$0.isPinned } // sorted newest first
        let excess = prunable.dropFirst(Self.maxAutoBackups)
        excess.forEach { delete(backup: $0) }
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
