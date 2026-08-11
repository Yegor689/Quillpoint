import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// Deleting a project cascade-deletes every task inside it — the most destructive action
/// in the app, and one with no undo (the confirmation dialog is the only safeguard).
///
/// The cascade isn't code we wrote: it rests on `@Relationship(deleteRule: .cascade)` and
/// SwiftData honouring it, including for SUBTASKS, which are reached through a second
/// cascade from their parent. A partial failure here is quiet — orphaned rows survive in
/// the store with no project to reach them from, which is exactly the "vanished task"
/// shape the diagnostic invariant checker exists to catch.
///
/// The rest of ProjectStore is thin wrappers over context mutations and is deliberately
/// left untested.
@MainActor
struct ProjectStoreTests {

    private func makeStore() throws -> (TestStore, ProjectStore) {
        let ts = try TestStore(prefix: "ProjectStore")
        return (ts, ProjectStore(context: ts.context))
    }

    /// Deleting a project takes its tasks AND their subtasks, and leaves other projects
    /// completely intact.
    @Test func deletingAProjectCascadesToTasksAndSubtasksOnly() throws {
        let (ts, store) = try makeStore()
        let seed = try seedPersonalWork(into: ts.context, save: true)

        // Personal: "Clean" + 2 subtasks. Work: "Ship".
        #expect(try ts.context.fetch(FetchDescriptor<Task>()).count == 4)

        store.deleteProject(seed.personal)
        try ts.context.save()

        let projects = try ts.context.fetch(FetchDescriptor<Project>())
        let tasks = try ts.context.fetch(FetchDescriptor<Task>())

        #expect(projects.map(\.title) == ["Work"], "only the deleted project is gone")
        #expect(tasks.map(\.plainTitle) == ["Ship"],
                "the parent AND both subtasks went with it, and Work's task survived")
    }

    /// The failure mode worth guarding: a task left in the store that no project lists.
    /// It wouldn't appear anywhere in the UI but would still count against the data
    /// heartbeat and every backup.
    @Test func deletingAProjectLeavesNoOrphanedTasks() throws {
        let (ts, store) = try makeStore()
        let seed = try seedPersonalWork(into: ts.context, save: true)

        store.deleteProject(seed.personal)
        try ts.context.save()

        let projects = try ts.context.fetch(FetchDescriptor<Project>())
        let reachable = Set(projects.flatMap { $0.tasks }.map(\.id))
        for task in try ts.context.fetch(FetchDescriptor<Task>()) {
            #expect(reachable.contains(task.id),
                    "task \(task.plainTitle) survived with no project listing it")
        }
    }

    /// Deleting an empty project is a plain no-op on everything else — no stray removals.
    @Test func deletingAnEmptyProjectTouchesNothingElse() throws {
        let (ts, store) = try makeStore()
        let seed = try seedPersonalWork(into: ts.context, save: true)
        let empty = store.createProject(title: "Empty")
        try ts.context.save()

        store.deleteProject(empty)
        try ts.context.save()

        #expect(try ts.context.fetch(FetchDescriptor<Task>()).count == 4, "no tasks lost")
        #expect(Set(try ts.context.fetch(FetchDescriptor<Project>()).map(\.title))
                == [seed.personal.title, seed.work.title])
    }

    /// The delete must survive a reopen, not just look right in the live context — the
    /// same in-memory-vs-persisted distinction that hid the subtask nesting bug.
    @Test func theCascadeIsPersistedNotJustInMemory() throws {
        let ts = try TestStore(prefix: "ProjectStoreReopen")
        let url = ts.url
        do {
            let store = ProjectStore(context: ts.context)
            let seed = try seedPersonalWork(into: ts.context, save: true)
            store.deleteProject(seed.personal)
            try ts.context.save()
        }

        // Reopen the same file in a fresh container — what the next launch reads.
        let schema = Schema([Project.self, Task.self])
        let reopened = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let ctx = ModelContext(reopened)

        #expect(try ctx.fetch(FetchDescriptor<Project>()).map(\.title) == ["Work"])
        #expect(try ctx.fetch(FetchDescriptor<Task>()).map(\.plainTitle) == ["Ship"],
                "the cascade persisted; no rows came back from disk")
    }
}
