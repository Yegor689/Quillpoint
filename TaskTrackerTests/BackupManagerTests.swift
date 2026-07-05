import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// Black-box tests for BackupManager. They exercise only the public API
/// (createBackup / restore / backups), run against an isolated temporary store
/// and backup directory (never production data or preferences), and focus on
/// the one thing that matters here: a backup → mutate → restore round-trip must
/// preserve user data exactly. A bug here means data loss.
@MainActor
struct BackupManagerTests {

    // MARK: - Isolated fixture

    /// An isolated app-like environment: a SwiftData store and a BackupManager
    /// whose backup directory and defaults live in a unique temp folder.
    @MainActor
    final class Fixture {
        let dir: URL
        let storeURL: URL
        let backupDir: URL
        let container: ModelContainer
        let manager: BackupManager

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("TTTest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            storeURL = dir.appendingPathComponent("Test.store")
            backupDir = dir.appendingPathComponent("Backups", isDirectory: true)

            let schema = Schema([Project.self, Task.self])
            container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL))

            let suiteName = "TTTest-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            manager = BackupManager(
                storeURL: storeURL,
                backupDir: backupDir,
                defaults: defaults)
            manager.liveContainer = container
        }

        var context: ModelContext { container.mainContext }

        /// Persists pending changes to disk so a backup (which reads the file)
        /// sees them.
        func save() throws { try context.save() }

        func tasks() throws -> [Task] { try context.fetch(FetchDescriptor<Task>()) }
        func projects() throws -> [Project] { try context.fetch(FetchDescriptor<Project>()) }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// A value snapshot of a task's persisted fields, for asserting round-trip
    /// integrity by id. Lives in the test (not production) and lists the fields a
    /// restore must preserve — if a model field is added and a restore should keep
    /// it, add it here and the integrity test starts enforcing it.
    struct TaskFields: Equatable {
        let titleRTF: Data
        let descRTF: Data
        let isDone: Bool
        let priority: Int
        let createdAt: Date
        let sortIndex: Int
        let completedAt: Date?
        let reminderDate: Date?
        let projectID: UUID?
        let parentID: UUID?
        init(_ t: Task) {
            titleRTF = t.titleRTF
            descRTF = t.descRTF
            isDone = t.isDone
            priority = t.priority
            createdAt = t.createdAt
            sortIndex = t.sortIndex
            completedAt = t.completedAt
            reminderDate = t.reminderDate
            projectID = t.project.id
            parentID = t.parent?.id
        }
    }

    /// Every task in the live store as TaskFields keyed by id.
    private func taskFields(_ f: Fixture) throws -> [UUID: TaskFields] {
        Dictionary(uniqueKeysWithValues: try f.tasks().map { ($0.id, TaskFields($0)) })
    }

    /// Seeds a representative dataset covering every field/edge: multiple
    /// projects, critical/normal/low priorities, completed + incomplete tasks,
    /// subtasks, and rich-text descriptions.
    private func seed(_ f: Fixture) throws {
        let ctx = f.context
        let personal = Project(title: "Personal", desc: "home")
        let work = Project(title: "Work", desc: "job")
        ctx.insert(personal); ctx.insert(work)

        func task(_ title: String, _ project: Project, priority: Int, done: Bool,
                  parent: Task? = nil, sortIndex: Int = 0, desc: String = "") -> Task {
            let t = Task(plainTitle: title, plainDesc: desc, priority: priority,
                         project: project, parent: parent)
            t.setDone(done)
            t.sortIndex = sortIndex
            ctx.insert(t)
            project.tasks.append(t)
            if let parent { parent.subtasks.append(t) }
            return t
        }

        let clean = task("Clean flat", personal, priority: 0, done: false, sortIndex: 0, desc: "deep clean")
        _ = task("Vacuum", personal, priority: 1, done: false, parent: clean, sortIndex: 0)
        _ = task("Dishes", personal, priority: 2, done: true, parent: clean, sortIndex: 1)
        _ = task("Dentist", personal, priority: 0, done: true, sortIndex: 1)
        _ = task("Ship release", work, priority: 0, done: false, sortIndex: 0, desc: "v2")
        _ = task("Email client", work, priority: 2, done: false, sortIndex: 1)
        try f.save()
    }

    // MARK: - Round-trip integrity

    /// The core data-integrity guarantee: after backup → arbitrary mutation →
    /// restore, the live store matches the backed-up state exactly — compared via
    /// TaskFields, which captures every persisted field. Mutates in every way a
    /// user can (edit fields incl. the #18 priority/completion regression, delete a
    /// task, add a new one) so the single equality assertion exercises restore
    /// comprehensively.
    @Test func backupThenRestoreReplacesLiveDataWithExactSnapshot() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        let before = try taskFields(f)
        #expect(before.count == 6)

        let backup = try #require(f.manager.createBackup(label: "snap"))

        // Mutate destructively in every direction.
        let all = try f.tasks()
        let edited = try #require(all.first { $0.plainTitle == "Ship release" })
        edited.setDone(true)              // completion change
        edited.priority = 2               // priority change (was critical)
        f.context.delete(try #require(all.first { $0.plainTitle == "Email client" }))
        f.context.insert(Task(plainTitle: "Added later", project: try f.projects().first!))
        try f.save()
        #expect(try f.tasks().count == 6) // 6 - 1 deleted + 1 added

        try f.manager.restore(backup: backup)

        // Exact match: every restored field, deleted task back, added task gone.
        #expect(try taskFields(f) == before)
        #expect(try f.tasks().contains { $0.plainTitle == "Added later" } == false)

        // Both relationship sides hydrate: the project lists its root tasks and a
        // parent lists its subtasks.
        let personal = try #require(try f.projects().first { $0.title == "Personal" })
        #expect(personal.tasks.filter { $0.parent == nil }.count == 2)
        let clean = try #require(try f.tasks().first { $0.plainTitle == "Clean flat" })
        #expect(Set(clean.subtasks.map(\.plainTitle)) == ["Vacuum", "Dishes"])
    }

    // MARK: - Backup management

    @Test func restoreCreatesSingleRollingPreRestoreBackup() throws {
        // #16: each restore keeps exactly one "before restore" safety backup.
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        let backup = try #require(f.manager.createBackup())

        try f.manager.restore(backup: backup)
        #expect(f.manager.preRestoreBackups.count == 1)
        try f.manager.restore(backup: backup)
        #expect(f.manager.preRestoreBackups.count == 1) // replaced, not accumulated
    }

    @Test func createBackupAppearsInList() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        #expect(f.manager.manualBackups.isEmpty)
        _ = try #require(f.manager.createBackup(label: "first"))
        #expect(f.manager.manualBackups.count == 1)
    }

    // MARK: - Rename

    @Test func renameChangesLabelKeepingKindAndDate() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        let backup = try #require(f.manager.createBackup(label: "first"))
        #expect(backup.label == "first")

        f.manager.rename(backup, to: "Q1 snapshot")
        let renamed = try #require(f.manager.manualBackups.first)
        #expect(renamed.label == "Q1 snapshot")
        #expect(renamed.kind == .manual)
        #expect(renamed.date == backup.date)          // timestamp preserved
        #expect(f.manager.manualBackups.count == 1)   // renamed, not duplicated
    }

    @Test func renameToEmptyClearsLabel() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        let backup = try #require(f.manager.createBackup(label: "temp"))
        f.manager.rename(backup, to: "")
        #expect(f.manager.manualBackups.first?.label == "")
    }

    @Test func renameSanitizesUnsafeCharacters() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        let backup = try #require(f.manager.createBackup())
        f.manager.rename(backup, to: "a/b:c\nd")   // slash, colon, newline stripped
        let label = try #require(f.manager.manualBackups.first?.label)
        #expect(!label.contains("/"))
        #expect(!label.contains(":"))
        #expect(!label.contains("\n"))
    }

    // MARK: - Pin

    @Test func pinTogglesAndPersistsInFilename() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        let backup = try #require(f.manager.createBackup(label: "keep me"))
        #expect(backup.isPinned == false)

        f.manager.setPinned(backup, true)
        let pinned = try #require(f.manager.manualBackups.first)
        #expect(pinned.isPinned)
        #expect(pinned.name.contains("pin-"))
        #expect(pinned.label == "keep me")   // pin doesn't disturb the label

        f.manager.setPinned(pinned, false)
        #expect(f.manager.manualBackups.first?.isPinned == false)
    }

    @Test func pinnedSortsAboveUnpinned() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        // Plant three auto backups with distinct timestamps; pin the OLDEST.
        plantAuto(f, "2026-01-01 10-00-00")
        plantAuto(f, "2026-01-02 10-00-00")
        let oldPinned = plantAuto(f, "2025-12-01 10-00-00")
        f.manager.refresh()
        f.manager.setPinned(try #require(f.manager.autoBackups.first { $0.name.contains(oldPinned) }), true)

        // Sorted() puts the pinned one first even though it's the oldest.
        #expect(f.manager.autoBackups.sorted().first?.isPinned == true)
    }

    // MARK: - Prune protection

    @Test func pinnedAutoBackupSurvivesPruning() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        // Plant 12 auto backups (over the keep-10 limit) with distinct timestamps.
        var names: [String] = []
        for day in 1...12 {
            names.append(plantAuto(f, String(format: "2026-01-%02d 10-00-00", day)))
        }
        f.manager.refresh()
        #expect(f.manager.autoBackups.count == 12)

        // Pin the OLDEST (day 1) — it would normally be pruned first.
        let oldestName = try #require(names.first)
        let oldest = try #require(f.manager.autoBackups.first { $0.name.contains(oldestName) })
        f.manager.setPinned(oldest, true)

        // Trigger a prune by making a real auto backup (createAutoBackupIfDue path
        // isn't public; use the same public trigger the app uses on interval).
        f.manager.autoBackupIntervalHours = 1
        f.manager.startAutoBackup()

        // The pinned oldest must still be present even though it's beyond keep-10;
        // and pruning kept the non-pinned set at the limit (10) plus the pinned one.
        let survivors = f.manager.autoBackups
        #expect(survivors.contains { $0.isPinned }, "pinned auto backup was pruned")
        let unpinnedCount = survivors.filter { !$0.isPinned }.count
        #expect(unpinnedCount <= BackupManagerTests.maxAutoBackupsForTest)
    }

    /// Mirror of BackupManager's private maxAutoBackups for assertions.
    private static let maxAutoBackupsForTest = 10

    /// Plants a valid `.store` auto-backup file with the given "yyyy-MM-dd HH-mm-ss"
    /// timestamp by snapshotting the live store into a crafted filename. Returns the
    /// timestamp string (unique substring of the filename) for lookup.
    @discardableResult
    private func plantAuto(_ f: Fixture, _ timestamp: String) -> String {
        let src = f.storeURL
        let dest = f.backupDir.appendingPathComponent("auto-\(timestamp).store")
        try? FileManager.default.copyItem(at: src, to: dest)
        return timestamp
    }
}
