import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// The list rules worth pinning: the shared ordering and the indent boundaries.
///
/// Deliberately NOT covering every pure helper here. A three-case filter switch or a
/// modulo cycle breaks visibly the moment you open the app, so a test for it only
/// restates the implementation and makes the suite noisier. These cover the cases that
/// are costly AND quiet: `ordered` is the fix for the freeze at ~1,500 tasks (nothing
/// guarded the property it exists for), legacy rows missing `completedAt`, an
/// out-of-range stored priority from a bad import, and the one-level nesting invariant.
@MainActor
struct TaskListLogicTests {

    private func makeStore() throws -> (TestStore, Project) {
        let store = try TestStore(prefix: "ListLogic")
        let project = Project(title: "P")
        store.context.insert(project)
        return (store, project)
    }

    @discardableResult
    private func task(_ ctx: ModelContext, _ project: Project, title: String = "",
                      done: Bool = false, sortIndex: Int = 0,
                      created: Date = Date(), completed: Date? = nil,
                      desc: String = "") -> Task {
        let t = Task(plainTitle: title, plainDesc: desc, project: project)
        t.isDone = done
        t.sortIndex = sortIndex
        t.createdAt = created
        t.completedAt = completed
        ctx.insert(t)
        return t
    }

    private func day(_ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 6, day: d))!
    }

    // MARK: - Priority

    /// `priority` is a stored Int, so a value outside the enum (bad import, future
    /// version) must degrade to .normal rather than trap.
    @Test func priorityLevelFallsBackToNormalForUnknownValues() throws {
        let (s, p) = try makeStore()
        let t = task(s.context, p)

        t.priority = 99
        #expect(t.priorityLevel == .normal, "unknown raw value degrades, never traps")
        t.priority = -1
        #expect(t.priorityLevel == .normal)

        t.priorityLevel = .low
        #expect(t.priority == 2, "the setter writes the raw value back")
    }

    // MARK: - ordered()

    /// Incomplete tasks come first in manual (sortIndex) order; completed ones sink to
    /// the bottom, newest completion on top.
    @Test func orderedPutsOpenTasksFirstThenCompletedNewestFirst() throws {
        let (s, p) = try makeStore()
        let b = task(s.context, p, title: "b-open", sortIndex: 1)
        let a = task(s.context, p, title: "a-open", sortIndex: 0)
        let oldDone = task(s.context, p, title: "old-done", done: true, completed: day(1))
        let newDone = task(s.context, p, title: "new-done", done: true, completed: day(5))

        let result = TaskListView.ordered([oldDone, b, newDone, a]).map(\.plainTitle)
        #expect(result == ["a-open", "b-open", "new-done", "old-done"])
    }

    /// createdAt only breaks ties between equal sortIndexes — it is not the primary key.
    @Test func orderedBreaksSortIndexTiesByCreationDate() throws {
        let (s, p) = try makeStore()
        let later = task(s.context, p, title: "later", sortIndex: 0, created: day(9))
        let earlier = task(s.context, p, title: "earlier", sortIndex: 0, created: day(2))

        #expect(TaskListView.ordered([later, earlier]).map(\.plainTitle) == ["earlier", "later"])
    }

    /// A completed task with no completedAt (legacy rows predate the field) must still
    /// sort sensibly rather than being dropped or crashing — it falls back to createdAt.
    @Test func orderedHandlesCompletedTasksMissingACompletionDate() throws {
        let (s, p) = try makeStore()
        let noStamp = task(s.context, p, title: "no-stamp", done: true, created: day(3), completed: nil)
        let stamped = task(s.context, p, title: "stamped", done: true, created: day(1), completed: day(7))

        let result = TaskListView.ordered([noStamp, stamped]).map(\.plainTitle)
        #expect(result == ["stamped", "no-stamp"], "falls back to createdAt for the unstamped one")
        #expect(result.count == 2, "neither task is dropped")
    }

    /// The whole reason `ordered` exists: it reads each task's fields once into a plain
    /// key struct, instead of letting the sort comparator touch SwiftData O(n log n)
    /// times. Sorting a large batch must stay fast — the old comparator hung the app at
    /// roughly this size.
    @Test func orderedSortsALargeListQuickly() throws {
        let (s, p) = try makeStore()
        let tasks = (0..<2_000).map { i in
            task(s.context, p, title: "t\(i)", done: i % 3 == 0,
                 sortIndex: (i * 7919) % 2_000, created: day((i % 28) + 1))
        }

        let start = Date()
        let result = TaskListView.ordered(tasks)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.count == 2_000, "nothing lost")
        #expect(elapsed < 2.0, "took \(elapsed)s — the per-comparison store reads are back")
        // Open tasks all precede completed ones.
        let firstDone = result.firstIndex(where: \.isDone) ?? result.count
        #expect(result[..<firstDone].allSatisfy { !$0.isDone })
        #expect(result[firstDone...].allSatisfy { $0.isDone })
    }

    // MARK: - Indent / previous-row rules

    @Test func previousTaskHandlesEmptyAndAbsentInputs() throws {
        let (s, p) = try makeStore()
        let orphan = task(s.context, p, title: "not shown")
        let other = task(s.context, p, title: "other")

        #expect(TaskListView.previousTask(before: orphan, in: []) == nil)
        #expect(TaskListView.previousTask(before: orphan, in: [other]) == nil,
                "a task absent from the visible list has no previous row")
        #expect(TaskListView.previousTask(before: other, in: [other]) == nil,
                "a single-row list has nothing above")
    }

    /// Filtering changes what "previous" means, which is the intended behaviour: you
    /// nest under the row you can see, not a hidden one.
    @Test func previousTaskFollowsTheVisibleListNotTheWholeProject() throws {
        let (s, p) = try makeStore()
        let a = task(s.context, p, title: "a")
        let hidden = task(s.context, p, title: "hidden", done: true)
        let c = task(s.context, p, title: "c")

        #expect(TaskListView.previousTask(before: c, in: [a, hidden, c])?.plainTitle == "hidden")
        #expect(TaskListView.previousTask(before: c, in: [a, c])?.plainTitle == "a",
                "with the completed row filtered out, 'a' is what's above")
    }

    /// Nesting is one level deep: a task that already has subtasks can't be indented,
    /// because its children would be orphaned into a third level.
    @Test func indentTargetRefusesATaskThatHasSubtasks() throws {
        let (s, p) = try makeStore()
        let first = task(s.context, p, title: "first")
        let parent = task(s.context, p, title: "parent")
        let child = Task(plainTitle: "child", project: p, parent: parent)
        s.context.insert(child)

        #expect(TaskListView.indentTarget(for: parent, in: [first, parent]) == nil,
                "indenting a task with subtasks would nest two levels deep")
        // The same task indents fine once it has no children.
        child.parent = nil
        #expect(TaskListView.indentTarget(for: parent, in: [first, parent])?.plainTitle == "first")
    }

}
