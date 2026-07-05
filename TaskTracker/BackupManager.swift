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

    static func < (lhs: Backup, rhs: Backup) -> Bool { lhs.date > rhs.date }
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

    /// The timestamp format embedded in every backup's filename. This — not the
    /// file's creation date — is the source of truth for when a backup was made,
    /// because copyItem preserves the source store's creation date, so on-disk
    /// metadata would make every backup look as old as the original store.
    private static let nameTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

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
            let kind: BackupKind
            if stem.hasPrefix("prerestore-") { kind = .preRestore }
            else if stem.hasPrefix("auto-")   { kind = .auto }
            else                              { kind = .manual }
            // Prefer the timestamp baked into the filename; the file's creation
            // date is unreliable because copyItem inherits the source store's.
            let date = Self.date(fromStem: stem)
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? Date.distantPast
            return Backup(url: url, date: date, name: stem, kind: kind)
        }.sorted()
    }

    /// Parses the "yyyy-MM-dd HH-mm-ss" timestamp out of a backup filename stem
    /// like "auto-2026-06-06 14-30-00 optional label".
    private static func date(fromStem stem: String) -> Date? {
        let withoutKind = stem.replacingOccurrences(
            of: "^(auto|manual|prerestore)-", with: "", options: .regularExpression)
        // The timestamp is the first two space-separated fields ("date time").
        let fields = withoutKind.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return nameTimestampFormatter.date(from: "\(fields[0]) \(fields[1])")
    }

    @discardableResult
    func createBackup(label: String = "", kind: BackupKind = .manual) -> Backup? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }

        let timestamp = Self.nameTimestampFormatter.string(from: Date())
        let prefix = kind.rawValue
        let name = label.isEmpty ? "\(prefix)-\(timestamp)" : "\(prefix)-\(timestamp) \(label)"
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

    func delete(backup: Backup) {
        let fm = FileManager.default
        try? fm.removeItem(at: backup.url)
        try? fm.removeItem(at: backup.url.appendingPathExtension("wal"))
        try? fm.removeItem(at: backup.url.appendingPathExtension("shm"))
        refresh()
    }

    private func pruneAutoBackups() {
        let autos = autoBackups // already sorted newest first
        let excess = autos.dropFirst(Self.maxAutoBackups)
        excess.forEach { delete(backup: $0) }
    }
}
