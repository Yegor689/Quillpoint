import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// #32: a parent task's completion is derived from its subtasks. Tests the model
/// rule (syncDoneWithSubtasks) and the store paths that must keep it in sync.
/// Uses a unique on-disk store (in-memory SIGTRAPs on the current beta toolchain).
@MainActor
struct SubtaskCompletionTests {

    @MainActor
    final class Fixture {
        let testStore = try! TestStore(prefix: "SubtaskTest")
        let store: TaskStore
        init() throws { store = TaskStore(context: testStore.context) }
        var context: ModelContext { testStore.context }
    }

    /// Parent with two subtasks. Returns (parent, subA, subB).
    private func seed(_ f: Fixture) throws -> (Task, Task, Task) {
        let project = Project(title: "P")
        f.context.insert(project)
        let parent = Task(plainTitle: "Parent", project: project)
        f.context.insert(parent); project.tasks.append(parent)
        let a = Task(plainTitle: "A", project: project, parent: parent)
        let b = Task(plainTitle: "B", project: project, parent: parent)
        for s in [a, b] { f.context.insert(s); project.tasks.append(s); parent.subtasks.append(s) }
        try f.context.save()
        return (parent, a, b)
    }

    @Test func parentCompletesWhenLastSubtaskDone() throws {
        let f = try Fixture()
        let (parent, a, b) = try seed(f)
        #expect(parent.isDone == false)

        a.setDone(true); parent.syncDoneWithSubtasks()
        #expect(parent.isDone == false) // one still open

        b.setDone(true); parent.syncDoneWithSubtasks()
        #expect(parent.isDone == true)  // all done -> parent done
    }

    @Test func parentReopensWhenASubtaskReopens() throws {
        let f = try Fixture()
        let (parent, a, b) = try seed(f)
        a.setDone(true); b.setDone(true); parent.syncDoneWithSubtasks()
        #expect(parent.isDone)

        a.setDone(false); parent.syncDoneWithSubtasks()
        #expect(parent.isDone == false)
    }

    @Test func parentIsDrivenBySubtasksFlag() throws {
        let f = try Fixture()
        let (parent, _, _) = try seed(f)
        #expect(parent.isDrivenBySubtasks)        // has subtasks
        let lone = Task(plainTitle: "Lone", project: parent.project)
        #expect(lone.isDrivenBySubtasks == false) // none
    }

    @Test func addingIncompleteSubtaskReopensADoneParent() throws {
        let f = try Fixture()
        let (parent, a, b) = try seed(f)
        a.setDone(true); b.setDone(true); parent.syncDoneWithSubtasks()
        #expect(parent.isDone)

        // Add a fresh (incomplete) subtask via the store — parent should reopen.
        _ = f.store.addSubtask(plainTitle: "C", to: parent)
        #expect(parent.isDone == false)
    }

    @Test func deletingLastIncompleteSubtaskCompletesParent() throws {
        let f = try Fixture()
        let (parent, a, b) = try seed(f)
        a.setDone(true)            // A done, B still open
        parent.syncDoneWithSubtasks()
        #expect(parent.isDone == false)

        // Delete the only incomplete subtask (B); the remaining subtask (A) is done.
        f.store.deleteTask(b)
        #expect(parent.isDone == true)
    }
}
