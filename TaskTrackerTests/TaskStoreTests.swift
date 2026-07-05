import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// Tests for TaskStore.moveTask — moving a root task (and its subtasks) between
/// projects, as driven by the row's "Move to" menu. The data logic is what's
/// risky here (subtask project FK reassignment, both relationship sides, undo),
/// so these exercise it directly against an isolated on-disk store.
@MainActor
struct TaskStoreTests {

    /// An isolated SwiftData store with a TaskStore over it. Uses a unique on-disk
    /// store rather than isStoredInMemoryOnly — the latter SIGTRAPs on the current
    /// macOS/Xcode 27 beta toolchain when several same-schema containers exist in
    /// one test process (see DataExportTests / SubtaskCompletionTests).
    @MainActor
    final class Fixture {
        let container: ModelContainer
        let store: TaskStore
        let undoManager = UndoManager()
        let diagnostics = DiagnosticLog()
        private let url: URL

        init() throws {
            let schema = Schema([Project.self, Task.self])
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TaskStoreTest-\(UUID().uuidString).store")
            container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url))
            store = TaskStore(context: container.mainContext, diagnostics: diagnostics)
            store.undoManager = undoManager
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        var context: ModelContext { container.mainContext }

        /// Entries flagged as invariant violations (the "vanished task" tripwire).
        var violations: [String] { diagnostics.entries.filter { $0.contains("INVARIANT") } }
    }

    /// Seeds two projects; Personal has one root task ("Clean") with two subtasks,
    /// Work has one root ("Ship"). Returns the pieces the tests assert on.
    private func seed(_ f: Fixture) -> (personal: Project, work: Project, clean: Task, vacuum: Task, dishes: Task) {
        let ctx = f.context
        let personal = Project(title: "Personal")
        let work = Project(title: "Work")
        ctx.insert(personal); ctx.insert(work)

        let clean = Task(plainTitle: "Clean", project: personal)
        ctx.insert(clean); personal.tasks.append(clean)

        let vacuum = Task(plainTitle: "Vacuum", project: personal, parent: clean)
        let dishes = Task(plainTitle: "Dishes", project: personal, parent: clean)
        for (i, s) in [vacuum, dishes].enumerated() {
            ctx.insert(s); personal.tasks.append(s); clean.subtasks.append(s); s.sortIndex = i
        }

        let ship = Task(plainTitle: "Ship", project: work)
        ctx.insert(ship); work.tasks.append(ship)

        return (personal, work, clean, vacuum, dishes)
    }

    @Test func moveTaskReassignsRootAndItsSubtasksToNewProject() throws {
        let f = try Fixture()
        let s = seed(f)

        f.store.moveTask(s.clean, to: s.work)

        // The root and both subtasks now belong to Work, on both relationship sides.
        #expect(s.clean.project.id == s.work.id)
        #expect(s.vacuum.project.id == s.work.id)
        #expect(s.dishes.project.id == s.work.id)
        #expect(s.work.tasks.contains { $0.id == s.clean.id })
        #expect(s.work.tasks.contains { $0.id == s.vacuum.id })
        #expect(s.personal.tasks.isEmpty)

        // Subtasks stay attached to their parent.
        #expect(Set(s.clean.subtasks.map(\.id)) == [s.vacuum.id, s.dishes.id])
        #expect(s.clean.parent == nil)
    }

    @Test func moveTaskIsUndoable() throws {
        let f = try Fixture()
        let s = seed(f)

        f.store.moveTask(s.clean, to: s.work)
        #expect(s.clean.project.id == s.work.id)

        f.undoManager.undo()

        // Back in Personal, subtasks too; Work is empty of the moved tree.
        #expect(s.clean.project.id == s.personal.id)
        #expect(s.vacuum.project.id == s.personal.id)
        #expect(s.dishes.project.id == s.personal.id)
        #expect(s.personal.tasks.contains { $0.id == s.clean.id })
        #expect(s.work.tasks.contains { $0.id == s.clean.id } == false)
    }

    @Test func moveTaskIgnoresSubtasksAndSameProject() throws {
        let f = try Fixture()
        let s = seed(f)

        // A subtask is not a root task — moving it directly is a no-op.
        f.store.moveTask(s.vacuum, to: s.work)
        #expect(s.vacuum.project.id == s.personal.id)
        #expect(s.vacuum.parent?.id == s.clean.id)

        // Moving to the project it's already in is a no-op.
        f.store.moveTask(s.clean, to: s.personal)
        #expect(s.clean.project.id == s.personal.id)
    }

    /// Reproduction for the reported edge case: moving a task that has subtasks
    /// could leave it reachable from no project (removed from the old, absent from
    /// the new). Persists and RE-FETCHES from the store between the move and the
    /// assertions — what the live UI's @Query does — and checks via fresh project
    /// membership rather than the in-memory object graph, plus the diagnostic
    /// invariant tripwire.
    @Test func moveTaskWithSubtasksAppearsInNewProjectAfterSaveAndRefetch() throws {
        let f = try Fixture()
        let s = seed(f)
        let cleanID = s.clean.id, personalID = s.personal.id, workID = s.work.id
        try f.context.save()

        f.store.moveTask(s.clean, to: s.work)
        try f.context.save()

        // Re-fetch everything fresh from the store, ignoring the in-memory graph.
        let projects = try f.context.fetch(FetchDescriptor<Project>())
        let work = try #require(projects.first { $0.id == workID })
        let personal = try #require(projects.first { $0.id == personalID })

        // The moved tree is present in Work and gone from Personal.
        #expect(work.tasks.contains { $0.id == cleanID })
        #expect(work.tasks.filter { $0.parent == nil }.contains { $0.id == cleanID })
        #expect(personal.tasks.isEmpty)

        // Every task is reachable from exactly ONE project, listed exactly once —
        // guards against both shapes of relationship corruption: a task reachable
        // from no project (the reported "vanish") and a task double-listed in a
        // project's `tasks`. NOTE: neither assertion was observed to fail against
        // the old manual-array implementation in this single-context save/refetch
        // geometry — the reported vanish was an intermittent in-vivo SwiftData
        // faulting condition under the live @Query UI that this store-layer test
        // does not deterministically reproduce. These remain as regression guards.
        let allTasks = try f.context.fetch(FetchDescriptor<Task>())
        let listed = projects.flatMap { $0.tasks }.map(\.id)
        let listedSet = Set(listed)
        for task in allTasks {
            #expect(listedSet.contains(task.id), "task \(task.id) is in no project (vanished)")
        }
        for project in projects {
            let ids = project.tasks.map(\.id)
            #expect(ids.count == Set(ids).count, "\(project.title) lists a task more than once: \(ids)")
        }

        // The diagnostic tripwire logged no membership violations.
        #expect(f.violations.isEmpty, "unexpected invariant violations: \(f.violations)")
    }
}
