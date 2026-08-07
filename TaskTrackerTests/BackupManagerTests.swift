import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// A small deterministic RNG so fuzz failures reproduce exactly (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

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

    /// Subtask nesting must survive a restore *on disk*, not just in the live context.
    ///
    /// `restore(backup:)` wires parent/child by setting BOTH sides (`task.parent = parent`
    /// AND `parent.subtasks.append(task)`). With an explicit `@Relationship(inverse:)` that
    /// is a double-write, and the same pattern in TaskStore.indentTask made nesting silently
    /// fail to persist — subtasks loaded back as ROOT tasks after a reopen. The existing
    /// round-trip test only inspects the in-memory context right after restore, where the
    /// objects look correct either way, so it cannot catch that class of bug.
    ///
    /// This closes the app's worst-case gap: a restore that looks fine, then loses the
    /// hierarchy on the next launch. Reopens the store from disk and re-asserts.
    @Test func restoredNestingSurvivesReopeningTheStore() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        let backup = try #require(f.manager.createBackup(label: "nesting"))

        // Flatten the hierarchy so the restore has real work to do: promote both subtasks
        // to root tasks. If restore didn't rebuild nesting, the reopen below would show
        // these as roots and the test fails.
        for t in try f.tasks() where t.parent != nil { t.parent = nil }
        try f.save()
        #expect(try f.tasks().allSatisfy { $0.parent == nil }, "hierarchy flattened")

        try f.manager.restore(backup: backup)
        try f.context.save()

        // Snapshot the restored store to a NEW file, then open that — equivalent to what
        // the next launch reads, but at a fresh URL, so we never reopen a container at a
        // URL another container still holds (which SIGTRAPs on the current beta).
        let copyURL = f.dir.appendingPathComponent("reopened-\(UUID().uuidString).store")
        let snapshotted = try #require(f.manager.createBackup(label: "verify"))
        try FileManager.default.copyItem(at: snapshotted.url, to: copyURL)

        let schema = Schema([Project.self, Task.self])
        let reopened = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: copyURL))
        let ctx = ModelContext(reopened)

        let all = try ctx.fetch(FetchDescriptor<Task>())
        #expect(all.count == 6)

        let clean = try #require(all.first { $0.plainTitle == "Clean flat" })
        #expect(Set(clean.subtasks.map(\.plainTitle)) == ["Vacuum", "Dishes"],
                "parent still lists both subtasks after reopen")

        // The to-one side is what actually persists; assert it directly.
        for title in ["Vacuum", "Dishes"] {
            let sub = try #require(all.first { $0.plainTitle == title })
            #expect(sub.parent?.id == clean.id, "\(title) is still nested under Clean flat")
        }
        // And nothing silently became a root task.
        #expect(all.filter { $0.parent == nil }.count == 4,
                "exactly the 4 seeded root tasks remain roots")
    }

    /// Deleting a backup must remove its SQLite sidecars too.
    ///
    /// SQLite names them "<store>-wal" / "<store>-shm". deleteFile previously built those
    /// paths with appendingPathExtension, which yields "<store>.store.wal" — a file that
    /// never exists — so the removals silently no-opped and sidecars were orphaned. A
    /// leftover -wal outliving its .store can later attach to a new backup that reuses the
    /// filename, which is a corruption vector rather than mere litter.
    @Test func deletingABackupRemovesItsSidecarFiles() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)
        let backup = try #require(f.manager.createBackup(label: "sidecars"))

        // VACUUM INTO writes a self-contained file, so simulate the sidecars that a
        // copied-in store (e.g. via restoreStoreFile) would bring with it.
        let fm = FileManager.default
        let wal = URL(fileURLWithPath: backup.url.path + "-wal")
        let shm = URL(fileURLWithPath: backup.url.path + "-shm")
        try Data("wal".utf8).write(to: wal)
        try Data("shm".utf8).write(to: shm)
        #expect(fm.fileExists(atPath: wal.path))

        f.manager.delete(backup: backup)

        #expect(fm.fileExists(atPath: backup.url.path) == false, "store removed")
        #expect(fm.fileExists(atPath: wal.path) == false, "-wal sidecar removed")
        #expect(fm.fileExists(atPath: shm.path) == false, "-shm sidecar removed")
    }

    /// Editing task TEXT must not be invisible to the auto-backup content check.
    ///
    /// The fingerprint is (taskCount, latestActivity). Retitling or rewriting a task's
    /// notes changes neither, so a session spent editing text looks "unchanged" and the
    /// auto-backup skips — not once, but for as long as the editing continues. The user
    /// believes auto-backup is on while none of that work is ever captured.
    @Test func editingTaskTextIsVisibleToTheContentFingerprint() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)

        let before = try #require(StoreFingerprint.fromTasks(try f.tasks()))

        // Rewrite a task's title and notes — no adds, deletes, or completions.
        let t = try #require(try f.tasks().first { $0.plainTitle == "Clean flat" })
        t.titleRTF = Task.rtf(from: "Completely different title")
        t.descRTF = Task.rtf(from: "and different notes")
        try f.save()

        let after = StoreFingerprint.fromTasks(try f.tasks())
        #expect(after != before,
                "a text edit must change the fingerprint, or auto-backup skips it forever")
    }

    /// restoreStoreFile must carry a source's SQLite sidecars across with it.
    ///
    /// This is the recovery-screen path, used when the store won't open at all. Its sidecar
    /// paths were built with appendingPathExtension ("<store>.store.wal"), so a source that
    /// did have a -wal/-shm had them silently skipped on both the copy and the move, and the
    /// restored store arrived without them. Backups written by VACUUM INTO are
    /// self-contained, but this same method also restores QUARANTINED stores — real
    /// WAL-mode stores that can carry a populated -wal.
    @Test func restoreStoreFileCarriesSidecarsAcross() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)

        // A source store standing in for a quarantined WAL-mode store: base file + sidecars.
        let source = f.dir.appendingPathComponent("source.store")
        let backup = try #require(f.manager.createBackup(label: "src"))
        let fm = FileManager.default
        try fm.copyItem(at: backup.url, to: source)
        try Data("wal-contents".utf8).write(to: URL(fileURLWithPath: source.path + "-wal"))
        try Data("shm-contents".utf8).write(to: URL(fileURLWithPath: source.path + "-shm"))

        try f.manager.restoreStoreFile(at: source)

        let liveWal = URL(fileURLWithPath: f.storeURL.path + "-wal")
        let liveShm = URL(fileURLWithPath: f.storeURL.path + "-shm")
        #expect(fm.fileExists(atPath: f.storeURL.path), "store swapped in")
        #expect(fm.fileExists(atPath: liveWal.path), "-wal came across")
        #expect(fm.fileExists(atPath: liveShm.path), "-shm came across")
        #expect(try Data(contentsOf: liveWal) == Data("wal-contents".utf8),
                "the source's -wal, not a leftover")

        // The staging temp file and its sidecars are cleaned up, not left in /tmp.
        let strays = try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)
            .filter { $0.hasPrefix("restore-") }
        #expect(strays.isEmpty, "staged temp files removed")
    }

    /// FUZZ: many randomized datasets, each round-tripped backup→restore, asserting EXACT
    /// per-field equality. This is the guard against silent `cloneScalars` field drops —
    /// if a Task field stops being copied on restore, some random dataset will differ and
    /// this fails. Deterministic (seeded) so a failure is reproducible.
    @Test func fuzzRoundTripPreservesEveryField() throws {
        var rng = SeededRNG(seed: 0xC0FFEE)
        for iteration in 0..<40 {
            let f = try Fixture(); defer { f.cleanup() }
            try seedRandom(f, rng: &rng)
            let before = try taskFields(f)

            let backup = try #require(f.manager.createBackup(label: "fuzz\(iteration)"))

            // Mutate arbitrarily so restore has real work to undo.
            for t in try f.tasks() where Bool.random(using: &rng) {
                t.setDone(Bool.random(using: &rng))
                t.priority = Int.random(in: 0...2, using: &rng)
                t.sortIndex = Int.random(in: 0...99, using: &rng)
            }
            if let victim = try f.tasks().first(where: { $0.parent == nil }) {
                f.context.delete(victim)
            }
            try f.save()

            try f.manager.restore(backup: backup)

            #expect(try taskFields(f) == before, "field drift on fuzz iteration \(iteration)")
        }
    }

    /// Seeds a random but valid dataset: 1–3 projects, each with 0–6 root tasks, each
    /// root with 0–3 subtasks; randomized titles/descriptions (incl. non-ASCII), done
    /// state, priority, sortIndex, completedAt, reminderDate.
    private func seedRandom(_ f: Fixture, rng: inout SeededRNG) throws {
        let ctx = f.context
        let projectCount = Int.random(in: 1...3, using: &rng)
        for p in 0..<projectCount {
            let project = Project(title: "Proj \(p) \(randomText(&rng))", desc: randomText(&rng))
            ctx.insert(project)
            let rootCount = Int.random(in: 0...6, using: &rng)
            for r in 0..<rootCount {
                let root = makeRandomTask(&rng, "r\(p).\(r)", project: project, parent: nil)
                ctx.insert(root); project.tasks.append(root)
                for s in 0..<Int.random(in: 0...3, using: &rng) {
                    let sub = makeRandomTask(&rng, "s\(p).\(r).\(s)", project: project, parent: root)
                    ctx.insert(sub); root.subtasks.append(sub)
                }
            }
        }
        try f.save()
    }

    private func makeRandomTask(_ rng: inout SeededRNG, _ tag: String, project: Project, parent: Task?) -> Task {
        let t = Task(plainTitle: "\(tag) \(randomText(&rng))", plainDesc: randomText(&rng),
                     priority: Int.random(in: 0...2, using: &rng), project: project, parent: parent)
        t.sortIndex = Int.random(in: 0...99, using: &rng)
        if Bool.random(using: &rng) { t.setDone(true) }
        if Bool.random(using: &rng) {
            t.reminderDate = Date(timeIntervalSinceReferenceDate: Double(Int.random(in: 0...800_000_000, using: &rng)))
        }
        return t
    }

    private func randomText(_ rng: inout SeededRNG) -> String {
        let words = ["alpha", "β-test", "café", "日本語", "quick", "brown", "🦊", "task", "note"]
        return (0..<Int.random(in: 1...4, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
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

    // MARK: - Recovery restore safety

    /// A restore from a BAD source must throw and leave the live store exactly in place.
    /// Regression for the bug where restoreStoreFile moved the live store aside BEFORE
    /// the (failing) copy, leaving the app with no store — the caller then opened blank.
    /// The staged-copy-first ordering means a bad source throws before anything is moved.
    @Test func restoreFromBadSourceThrowsAndKeepsLiveStore() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)

        let liveBytesBefore = try Data(contentsOf: f.storeURL)
        let missingSource = f.dir.appendingPathComponent("does-not-exist.store")

        #expect(throws: (any Error).self) {
            try f.manager.restoreStoreFile(at: missingSource)
        }

        // The live store is untouched, and nothing was set aside into Quarantine.
        #expect(FileManager.default.fileExists(atPath: f.storeURL.path))
        #expect(try Data(contentsOf: f.storeURL) == liveBytesBefore)
        let quarantine = f.storeURL.deletingLastPathComponent().appending(component: "Quarantine")
        #expect(FileManager.default.fileExists(atPath: quarantine.path) == false)
    }

    /// createBackup returns the backup it just wrote, even when a pinned (older) backup
    /// sorts ahead of it. Regression for returning `backups.first` (pinned-first sorted).
    @Test func createBackupReturnsTheNewBackupNotAPinnedOne() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f)

        // Plant and pin an older auto backup so it sorts to the front of `backups`.
        let pinnedName = plantAuto(f, "2020-01-01 10-00-00")
        f.manager.refresh()
        f.manager.setPinned(try #require(f.manager.autoBackups.first { $0.name.contains(pinnedName) }), true)

        let made = try #require(f.manager.createBackup(label: "fresh one"))
        #expect(made.label == "fresh one")
        #expect(made.isPinned == false)
        #expect(made.kind == .manual)
    }

    // MARK: - Content-aware auto-backup

    /// An auto-backup is NOT taken when the store's content is unchanged since the last
    /// one — the fix for a frozen store filling the window with identical snapshots. Uses
    /// an OLD-dated planted backup so the interval guard is satisfied and the CONTENT
    /// check is what decides.
    @Test func autoBackupSkipsWhenContentUnchanged() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f); try f.save()

        // Make a REAL auto-backup of current content (consistent online-backup snapshot),
        // then back-date its filename so the interval has "elapsed" — leaving CONTENT as
        // the only thing that decides whether the next run backs up.
        try makeOldAutoBackupOfCurrentContent(f, dated: "2020-01-01 10-00-00")
        let before = f.manager.autoBackups.count

        f.manager.autoBackupIntervalHours = 1
        f.manager.startAutoBackup() // interval elapsed, but content identical → must skip
        #expect(f.manager.autoBackups.count == before, "unchanged content must not create a new auto-backup")
    }

    /// A real change DOES produce a new auto-backup (the skip only applies to no-ops).
    @Test func autoBackupTakenWhenContentChanged() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f); try f.save()

        try makeOldAutoBackupOfCurrentContent(f, dated: "2020-01-01 10-00-00")
        let before = f.manager.autoBackups.count

        // Change the store so the live fingerprint differs from the planted backup.
        let p = try #require(try f.projects().first)
        let t = Task(plainTitle: "brand new", project: p); f.context.insert(t); p.tasks.append(t)
        try f.save()

        f.manager.autoBackupIntervalHours = 1
        f.manager.startAutoBackup() // content changed → must back up
        #expect(f.manager.autoBackups.count == before + 1, "changed content must create a new auto-backup")
    }

    /// Pruning removes content-DUPLICATE auto-backups, keeping distinct states — so a
    /// frozen store's identical snapshots can't evict genuinely different older backups.
    @Test func pruneDropsContentDuplicates() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try seed(f); try f.save()

        // Plant 6 IDENTICAL-content auto backups (plantAuto copies the same live store).
        for day in 1...6 { plantAuto(f, String(format: "2026-02-%02d 10-00-00", day)) }
        f.manager.refresh()
        #expect(f.manager.autoBackups.count == 6)

        // Trigger a prune. All 6 share one fingerprint, so dedup should collapse them to
        // the single newest distinct state (plus whatever the trigger itself creates).
        f.manager.autoBackupIntervalHours = 1
        f.manager.startAutoBackup()

        // Group survivors by fingerprint; no fingerprint should have more than one.
        let survivors = f.manager.autoBackups.filter { !$0.isPinned }
        let byFingerprint = Dictionary(grouping: survivors) { b in
            b.fingerprint.map { "\($0.taskCount):\($0.latestActivity)" } ?? UUID().uuidString
        }
        for (_, group) in byFingerprint {
            #expect(group.count == 1, "content duplicates were not pruned")
        }
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

    /// Makes a REAL auto-backup of the current live content via the manager (consistent
    /// online-backup snapshot, so its fingerprint matches the live context deterministically
    /// regardless of WAL checkpoint state), then renames it to an old-dated auto filename
    /// so the interval guard is satisfied and the content check is what's under test.
    private func makeOldAutoBackupOfCurrentContent(_ f: Fixture, dated timestamp: String) throws {
        let made = try #require(f.manager.createBackup(kind: .auto))
        let dest = f.backupDir.appendingPathComponent("auto-\(timestamp).store")
        try FileManager.default.moveItem(at: made.url, to: dest)
        f.manager.refresh()
    }
}
