import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// Tests for JSON export + import. Uses UNIQUE ON-DISK temp stores rather than
/// isStoredInMemoryOnly, which SIGTRAPs on the current Xcode 27 / macOS 27 day-1
/// beta toolchain when multiple containers for the same schema exist in one process.
@MainActor
struct DataExportTests {

    typealias Store = TestStore

    /// Seeds Personal (root "Clean" with subtasks "Vacuum"+"Dishes", Dishes done) and
    /// Work ("Ship") with descriptions/priorities, saved — the export round-trip needs
    /// the full shape. Delegates to the shared `seedPersonalWork`.
    @discardableResult
    private func seed(_ ctx: ModelContext) throws -> (personal: Project, work: Project) {
        let s = try seedPersonalWork(into: ctx, descriptions: true, completeDishes: true, save: true)
        return (s.personal, s.work)
    }

    // MARK: - Export

    @Test func exportProducesValidJSONWithNestedSubtasks() throws {
        let s = try Store()
        try seed(s.context)
        let data = try DataExportManager.json(from: s.context)

        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["app"] as? String == "Quillpoint")
        let projects = try #require(obj["projects"] as? [[String: Any]])
        #expect(projects.count == 2)

        let personal = try #require(projects.first { $0["title"] as? String == "Personal" })
        let roots = try #require(personal["tasks"] as? [[String: Any]])
        #expect(roots.count == 1)
        let clean = try #require(roots.first)
        #expect(clean["title"] as? String == "Clean")
        #expect((clean["titleRTF"] as? String)?.isEmpty == false) // lossless RTF present
        #expect((clean["subtasks"] as? [[String: Any]])?.count == 2)
    }

    @Test func validateRejectsMalformedFile() throws {
        #expect(throws: DataExportManager.ImportError.self) {
            try DataExportManager.validate(Data("not json".utf8))
        }
        // Valid JSON but not a Quillpoint document.
        #expect(throws: DataExportManager.ImportError.self) {
            try DataExportManager.validate(Data(#"{"app":"Other","formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","projects":[]}"#.utf8))
        }
    }

    /// An export whose RTF fields are empty strings must fall back to the plain text.
    ///
    /// `Data(base64Encoded: "")` returns EMPTY DATA rather than nil, so the
    /// `?? Task.rtf(from:)` fallback never fired and the task imported completely blank —
    /// with its title sitting right there in the file's plain `title` field. Quillpoint's
    /// own exports always populate the RTF, so this only bites hand-written or
    /// script-generated files, which is exactly what someone migrating data would write.
    @Test func importFallsBackToPlainTextWhenRTFIsEmpty() throws {
        let json = """
        {"app":"Quillpoint","formatVersion":1,"exportedAt":"2026-01-01T00:00:00.000Z",
         "projects":[{"id":"\(UUID().uuidString)","title":"Imported","desc":"",
          "createdAt":"2026-01-01T00:00:00.000Z",
          "tasks":[{"id":"\(UUID().uuidString)","title":"Buy milk","titleRTF":"",
                    "notes":"two litres","notesRTF":"","isDone":false,"priority":1,
                    "createdAt":"2026-01-01T00:00:00.000Z","sortIndex":0,
                    "completedAt":null,"reminderDate":null,"subtasks":[]}]}]}
        """
        let dst = try Store()
        try DataExportManager.importing(Data(json.utf8), into: dst.context, mode: .replace)

        let tasks = try dst.context.fetch(FetchDescriptor<Task>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.plainTitle == "Buy milk", "empty titleRTF must fall back to `title`")
        #expect(tasks.first?.plainDesc == "two litres", "empty notesRTF must fall back to `notes`")
    }

    // MARK: - Round-trip

    /// Export from one store, import into a fresh empty store (replace), and confirm
    /// every project/task/subtask and its fields survived the round-trip.
    @Test func roundTripReplacePreservesEverything() throws {
        let src = try Store()
        try seed(src.context)
        let data = try DataExportManager.json(from: src.context)

        let dst = try Store()
        try DataExportManager.importing(data, into: dst.context, mode: .replace)

        let projects = try dst.context.fetch(FetchDescriptor<Project>())
        #expect(projects.count == 2)
        let personal = try #require(projects.first { $0.title == "Personal" })
        let clean = try #require(personal.tasks.first { $0.parent == nil && $0.plainTitle == "Clean" })
        #expect(clean.plainDesc == "deep clean")
        #expect(clean.priorityLevel == .critical)         // priority 0 preserved
        #expect(Set(clean.subtasks.map(\.plainTitle)) == ["Vacuum", "Dishes"])
        let dishes = try #require(clean.subtasks.first { $0.plainTitle == "Dishes" })
        #expect(dishes.isDone)                            // completion preserved
        // Every task belongs to exactly the project it was nested under.
        let allTasks = try dst.context.fetch(FetchDescriptor<Task>())
        #expect(allTasks.allSatisfy { $0.project != nil })
    }

    // MARK: - Import modes

    @Test func replaceWipesExistingData() throws {
        let src = try Store()
        try seed(src.context)
        let data = try DataExportManager.json(from: src.context)

        // Destination already has its own unrelated project.
        let dst = try Store()
        let old = Project(title: "Old Project")
        dst.context.insert(old)
        let oldTask = Task(plainTitle: "old task", project: old)
        dst.context.insert(oldTask); old.tasks.append(oldTask)
        try dst.context.save()

        try DataExportManager.importing(data, into: dst.context, mode: .replace)

        let projects = try dst.context.fetch(FetchDescriptor<Project>())
        #expect(projects.contains { $0.title == "Old Project" } == false) // wiped
        #expect(Set(projects.map(\.title)) == ["Personal", "Work"])
    }

    @Test func mergeAddsNewProjectsAlongsideExisting() throws {
        let src = try Store()
        try seed(src.context)
        let data = try DataExportManager.json(from: src.context)

        let dst = try Store()
        let keep = Project(title: "Keep")
        dst.context.insert(keep)
        try dst.context.save()

        try DataExportManager.importing(data, into: dst.context, mode: .merge)

        let projects = try dst.context.fetch(FetchDescriptor<Project>())
        #expect(Set(projects.map(\.title)) == ["Keep", "Personal", "Work"])
        let personal = try #require(projects.first { $0.title == "Personal" })
        #expect(personal.tasks.first { $0.plainTitle == "Clean" }?.subtasks.count == 2)
    }

    /// Re-importing the same export into the same store (merge) must be idempotent:
    /// no duplicate projects or tasks the second time.
    @Test func mergeIsIdempotentOnReimport() throws {
        let store = try Store()
        try seed(store.context)
        let data = try DataExportManager.json(from: store.context)

        let projectsBefore = try store.context.fetch(FetchDescriptor<Project>()).count
        let tasksBefore = try store.context.fetch(FetchDescriptor<Task>()).count

        // Import the store's own export back into itself — must add nothing.
        try DataExportManager.importing(data, into: store.context, mode: .merge)

        #expect(try store.context.fetch(FetchDescriptor<Project>()).count == projectsBefore)
        #expect(try store.context.fetch(FetchDescriptor<Task>()).count == tasksBefore)
    }

    /// Merge into a matching project adds only the genuinely new task, reusing the
    /// existing project rather than duplicating it. The destination is built FROM the
    /// source's export so existing items are byte-identical (matching createdAt etc.),
    /// then a superset export (with an extra task) is merged in.
    @Test func mergeAddsOnlyNewTaskIntoMatchingProject() throws {
        // Source state #1: the plain seed. Export it — this is what the destination
        // already has, identical down to createdAt.
        let src = try Store()
        let (personal, _) = try seed(src.context)
        let baseExport = try DataExportManager.json(from: src.context)

        // Destination = a fresh store loaded from that base export (so fields match).
        let dst = try Store()
        try DataExportManager.importing(baseExport, into: dst.context, mode: .replace)
        let dstPersonalID = try #require(try dst.context.fetch(FetchDescriptor<Project>())
            .first { $0.title == "Personal" }).id

        // Source state #2: add a new root task, then export the superset.
        let laundry = Task(plainTitle: "Laundry", project: personal)
        src.context.insert(laundry); personal.tasks.append(laundry); laundry.sortIndex = 1
        try src.context.save()
        let supersetExport = try DataExportManager.json(from: src.context)

        // Merge the superset into the destination.
        try DataExportManager.importing(supersetExport, into: dst.context, mode: .merge)

        let projects = try dst.context.fetch(FetchDescriptor<Project>())
        // Personal reused (same id), not duplicated.
        #expect(projects.filter { $0.title == "Personal" }.count == 1)
        let personalAfter = try #require(projects.first { $0.title == "Personal" })
        #expect(personalAfter.id == dstPersonalID)
        // Clean not duplicated; Laundry added.
        let roots = personalAfter.tasks.filter { $0.parent == nil }
        #expect(roots.filter { $0.plainTitle == "Clean" }.count == 1)
        #expect(roots.contains { $0.plainTitle == "Laundry" })
        let clean = try #require(roots.first { $0.plainTitle == "Clean" })
        #expect(clean.subtasks.count == 2) // no subtask dupes
    }
}
