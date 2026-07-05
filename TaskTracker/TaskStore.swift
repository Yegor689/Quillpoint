import Foundation
import SwiftData
import AppKit

// Snapshot of a task used to reconstruct it on undo of a delete.
private struct TaskSnapshot {
    let titleRTF:   Data
    let descRTF:    Data
    let isDone:     Bool
    let priority:   Int
    let createdAt:  Date
    let sortIndex:  Int
    let subtasks:   [TaskSnapshot]

    init(_ task: Task) {
        titleRTF  = task.titleRTF
        descRTF   = task.descRTF
        isDone    = task.isDone
        priority  = task.priority
        createdAt = task.createdAt
        sortIndex = task.sortIndex
        subtasks  = task.subtasks.sorted { $0.sortIndex < $1.sortIndex }.map { TaskSnapshot($0) }
    }
}

@Observable
final class TaskStore {
    private let context: ModelContext
    var undoManager: UndoManager?
    var reminderManager: ReminderManager?
    private let diagnostics: DiagnosticLog

    init(context: ModelContext, diagnostics: DiagnosticLog = .shared) {
        self.context = context
        self.diagnostics = diagnostics
    }

    /// First 8 chars of a UUID — compact, correlatable id for the diagnostic log.
    fileprivate static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// One-time backfill: existing data has all sortIndex == 0. If a project's
    /// root tasks (or any task's subtasks) all share index 0, assign sequential
    /// indices from their legacy createdAt order so manual ordering has a basis.
    func backfillSortIndicesIfNeeded() {
        guard let projects = try? context.fetch(FetchDescriptor<Project>()) else { return }
        for project in projects {
            let roots = project.tasks.filter { $0.parent == nil }
            if needsBackfill(roots) {
                let ordered = roots.sorted { $0.createdAt < $1.createdAt }
                for (i, t) in ordered.enumerated() { t.sortIndex = i }
            }
            for task in project.tasks where !task.subtasks.isEmpty {
                if needsBackfill(task.subtasks) {
                    let ordered = task.subtasks.sorted { $0.createdAt < $1.createdAt }
                    for (i, s) in ordered.enumerated() { s.sortIndex = i }
                }
            }
        }
    }

    private func needsBackfill(_ tasks: [Task]) -> Bool {
        tasks.count > 1 && Set(tasks.map(\.sortIndex)).count == 1
    }

    // MARK: - Ordering helpers

    /// Root tasks of a project, ordered by sortIndex.
    static func orderedRoots(of project: Project) -> [Task] {
        project.tasks.filter { $0.parent == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Subtasks of a task, ordered by sortIndex.
    static func orderedSubtasks(of parent: Task) -> [Task] {
        parent.subtasks.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Rewrites sortIndex over an ordered list so positions are 0,1,2,…
    private func reindex(_ tasks: [Task]) {
        for (i, t) in tasks.enumerated() { t.sortIndex = i }
    }

    @discardableResult
    func addTask(plainTitle: String = "", priority: Int = 1, to project: Project, after afterTask: Task? = nil, before beforeTask: Task? = nil) -> Task {
        let task = Task(plainTitle: plainTitle, priority: priority, project: project)
        context.insert(task)
        project.tasks.append(task)

        // Position the new task: before `beforeTask`, else right after `afterTask`,
        // else at the end.
        var roots = Self.orderedRoots(of: project).filter { $0.id != task.id }
        if let beforeTask, let idx = roots.firstIndex(where: { $0.id == beforeTask.id }) {
            roots.insert(task, at: idx)
        } else if let afterTask, let idx = roots.firstIndex(where: { $0.id == afterTask.id }) {
            roots.insert(task, at: idx + 1)
        } else {
            roots.append(task)
        }
        reindex(roots)

        undoManager?.registerUndo(withTarget: self) { [weak project] store in
            guard let project else { return }
            store.undoManager?.setActionName("Add Task")
            store.deleteTask(task, in: project)
        }
        undoManager?.setActionName("Add Task")
        return task
    }

    func indentTask(_ task: Task, previousTask: Task?) {
        guard let parent = previousTask else { return }
        let project = task.project
        // Re-render the title at the subtask (body) font size so it doesn't stay
        // at the larger top-level (title3) size it was created with.
        task.titleRTF = Task.resizingFontRTF(task.titleRTF, to: NSFont.preferredFont(forTextStyle: .body).pointSize)
        task.parent = parent
        if !parent.subtasks.contains(where: { $0.id == task.id }) {
            parent.subtasks.append(task)
        }
        project.tasks.removeAll { $0.id == task.id }
        context.insert(task)
        // Place at the end of the parent's subtasks and renumber both lists.
        task.sortIndex = (parent.subtasks.map(\.sortIndex).max() ?? -1) + 1
        reindex(Self.orderedSubtasks(of: parent))
        reindex(Self.orderedRoots(of: project))

        undoManager?.registerUndo(withTarget: self) { [weak parent, weak project] store in
            guard let parent, let project else { return }
            store.undoManager?.setActionName("Indent")
            store.unindentTask(task, fromParent: parent, into: project)
        }
        undoManager?.setActionName("Indent")
    }

    func unindentTask(_ task: Task) {
        guard let parent = task.parent else { return }
        let project = task.project
        unindentTask(task, fromParent: parent, into: project)

        undoManager?.registerUndo(withTarget: self) { [weak parent] store in
            guard let parent else { return }
            store.undoManager?.setActionName("Unindent")
            store.indentTask(task, previousTask: parent)
        }
        undoManager?.setActionName("Unindent")
    }

    /// Drag-to-nest: makes `task` a subtask of `newParent`. No-op if it would nest
    /// deeper than one level. (Thin wrapper over indentTask with guards.)
    func nestTask(_ task: Task, under newParent: Task) {
        guard task.id != newParent.id,
              newParent.parent == nil,   // only nest under a root task
              task.subtasks.isEmpty      // the dragged task can't have its own subtasks
        else { return }
        indentTask(task, previousTask: newParent)
    }

    /// Applies a new ordering to a parent task's subtasks (drag reorder). Undoable.
    func reorderSubtasks(_ ordered: [Task], of parent: Task) {
        let beforeOrder = Self.orderedSubtasks(of: parent).map(\.id)
        reindex(ordered)
        undoManager?.registerUndo(withTarget: self) { [weak parent] store in
            guard let parent else { return }
            let byID = Dictionary(uniqueKeysWithValues: parent.subtasks.map { ($0.id, $0) })
            store.reindex(beforeOrder.compactMap { byID[$0] })
            store.undoManager?.setActionName("Move Subtask")
        }
        undoManager?.setActionName("Move Subtask")
    }

    // MARK: - Reorder (drag to move)

    /// Applies a new ordering to a project's root tasks (from a List .onMove).
    /// `ordered` is the visible root tasks in their new order; their sortIndex is
    /// rewritten to match. Undoable.
    func reorderRoots(_ ordered: [Task], in project: Project) {
        let before = Self.orderedRoots(of: project)
        let beforeOrder = before.map(\.id)

        // The visible list may be filtered (Active/Done). Rebuild the full root
        // order by replacing the visible subset's positions with the new order,
        // leaving any hidden roots where they were relative to the whole list.
        let visibleIDs = Set(ordered.map(\.id))
        var newOrder: [Task] = []
        var movedQueue = ordered
        for task in before {
            if visibleIDs.contains(task.id) {
                if !movedQueue.isEmpty { newOrder.append(movedQueue.removeFirst()) }
            } else {
                newOrder.append(task)
            }
        }
        reindex(newOrder)

        undoManager?.registerUndo(withTarget: self) { [weak project] store in
            guard let project else { return }
            let byID = Dictionary(uniqueKeysWithValues: project.tasks.map { ($0.id, $0) })
            store.reindex(beforeOrder.compactMap { byID[$0] })
            store.undoManager?.setActionName("Move Task")
        }
        undoManager?.setActionName("Move Task")
    }

    // MARK: - Move across projects

    /// Moves a root `task` (and its subtasks) from its current project to
    /// `newProject` — used by the row's "Move to" menu. Subtasks follow their
    /// parent: they stay attached via `parent`, but their `project` FK is reassigned
    /// too so every task's project matches the list it now lives in. Placed at the
    /// end of the new project's roots. No-op if the task isn't a root, has no current
    /// project, or is already in `newProject`. Undoable.
    func moveTask(_ task: Task, to newProject: Project) {
        let oldProject = task.project
        guard task.parent == nil, oldProject.id != newProject.id else { return }

        let oldSortIndex = task.sortIndex
        // Snapshot subtasks before reassigning — assigning a subtask's project
        // mutates the live relationship collections.
        let subtasks = Array(task.subtasks)
        diagnostics.record("moveTask",
            "task=\(Self.short(task.id)) from=\(Self.short(oldProject.id)) to=\(Self.short(newProject.id)) subtasks=\(subtasks.count)")

        // Reassign by setting only the to-one `project` side. With the explicit
        // inverse on Project.tasks, SwiftData maintains both projects' `tasks`
        // arrays; manual array surgery here would double-write and corrupt it.
        reassignProject(task, to: newProject)
        for subtask in subtasks {
            reassignProject(subtask, to: newProject)
        }

        // Place at the end of the new project's roots; renumber both projects.
        task.sortIndex = (Self.orderedRoots(of: newProject).filter { $0.id != task.id }.map(\.sortIndex).max() ?? -1) + 1
        reindex(Self.orderedRoots(of: newProject))
        reindex(Self.orderedRoots(of: oldProject))
        diagnostics.checkProjectMembership(in: context, after: "moveTask")

        undoManager?.registerUndo(withTarget: self) { [weak oldProject] store in
            guard let oldProject else { return }
            store.moveTaskBack(task, to: oldProject, restoringSortIndex: oldSortIndex)
            store.undoManager?.setActionName("Move Task to Project")
        }
        undoManager?.setActionName("Move Task to Project")
    }

    /// Undo counterpart to moveTask: returns `task` (and subtasks) to `project` and
    /// re-seats it at its previous position among that project's roots.
    private func moveTaskBack(_ task: Task, to project: Project, restoringSortIndex: Int) {
        let current = task.project
        guard current.id != project.id else { return }
        let subtasks = Array(task.subtasks) // snapshot before mutating relationships
        diagnostics.record("moveTaskBack",
            "task=\(Self.short(task.id)) from=\(Self.short(current.id)) to=\(Self.short(project.id)) subtasks=\(subtasks.count)")
        // Set only the to-one side; the explicit inverse maintains both projects' tasks.
        reassignProject(task, to: project)
        for subtask in subtasks {
            reassignProject(subtask, to: project)
        }
        var roots = Self.orderedRoots(of: project).filter { $0.id != task.id }
        let insertAt = min(restoringSortIndex, roots.count)
        roots.insert(task, at: insertAt)
        reindex(roots)
        reindex(Self.orderedRoots(of: current))
        diagnostics.checkProjectMembership(in: context, after: "moveTaskBack")

        undoManager?.registerUndo(withTarget: self) { store in
            store.moveTask(task, to: current)
            store.undoManager?.setActionName("Move Task to Project")
        }
    }

    /// Reassigns a task's project by setting only the to-one `project` side. With
    /// the explicit inverse declared on Project.tasks, SwiftData maintains both the
    /// old and new project's `tasks` arrays automatically.
    private func reassignProject(_ task: Task, to project: Project) {
        task.project = project
    }

    @discardableResult
    func addSubtask(plainTitle: String = "", priority: Int = 1, to parent: Task, after afterSubtask: Task? = nil, before beforeSubtask: Task? = nil) -> Task {
        let subtask = Task(plainTitle: plainTitle, priority: priority, project: parent.project, parent: parent)
        context.insert(subtask)
        parent.subtasks.append(subtask)
        // The new subtask is incomplete, so a parent that was marked done is no longer
        // fully done — re-derive its completion from its subtasks.
        parent.syncDoneWithSubtasks()

        // Position the new subtask: before `beforeSubtask`, else right after
        // `afterSubtask`, else at the end.
        var subs = Self.orderedSubtasks(of: parent).filter { $0.id != subtask.id }
        if let before = beforeSubtask, let idx = subs.firstIndex(where: { $0.id == before.id }) {
            subs.insert(subtask, at: idx)
        } else if let after = afterSubtask, let idx = subs.firstIndex(where: { $0.id == after.id }) {
            subs.insert(subtask, at: idx + 1)
        } else {
            subs.append(subtask)
        }
        reindex(subs)

        undoManager?.registerUndo(withTarget: self) { [weak parent] store in
            guard let parent else { return }
            store.undoManager?.setActionName("Add Subtask")
            store.deleteSubtask(subtask, from: parent)
        }
        undoManager?.setActionName("Add Subtask")
        return subtask
    }

    func completeTask(_ task: Task) {
        let wasParentDone      = task.isDone
        let wasParentCompleted = task.completedAt
        let wasReminder        = task.reminderDate
        let subtaskStates = task.subtasks.map { ($0, $0.isDone, $0.completedAt, $0.reminderDate) }
        task.setDone(true)
        task.reminderDate = nil
        for subtask in task.subtasks {
            subtask.setDone(true)
            subtask.reminderDate = nil
        }

        // Cancel reminders for completed tasks
        reminderManager?.cancel(taskID: task.id)
        for subtask in task.subtasks { reminderManager?.cancel(taskID: subtask.id) }

        undoManager?.registerUndo(withTarget: self) { store in
            store.undoManager?.setActionName("Complete Task")
            task.isDone = wasParentDone
            task.completedAt = wasParentCompleted
            task.reminderDate = wasReminder
            if wasReminder != nil { store.reminderManager?.schedule(task: task) }
            for (subtask, wasDone, wasCompleted, wasSubReminder) in subtaskStates {
                subtask.isDone = wasDone
                subtask.completedAt = wasCompleted
                subtask.reminderDate = wasSubReminder
                if wasSubReminder != nil { store.reminderManager?.schedule(task: subtask) }
            }
        }
        undoManager?.setActionName("Complete Task")
    }

    func deleteTask(_ task: Task) {
        deleteTask(task, in: task.project)
    }

    func deleteTask(_ task: Task, in project: Project) {
        let snapshot   = TaskSnapshot(task)
        let createdAt  = task.createdAt
        let afterIndex = project.tasks.firstIndex(where: { $0.id == task.id }).map { $0 - 1 }
        let afterTask  = afterIndex.flatMap { $0 >= 0 ? project.tasks[$0] : nil }

        // Cancel reminders before deleting
        reminderManager?.cancel(taskID: task.id)
        for subtask in task.subtasks { reminderManager?.cancel(taskID: subtask.id) }

        let formerParent = task.parent
        task.parent?.subtasks.removeAll { $0.id == task.id }
        project.tasks.removeAll { $0.id == task.id }
        context.delete(task)
        // Removing a subtask can change whether the parent is "all subtasks done".
        formerParent?.syncDoneWithSubtasks()

        undoManager?.registerUndo(withTarget: self) { [weak project] store in
            guard let project else { return }
            store.undoManager?.setActionName("Delete Task")
            store.restore(snapshot: snapshot, into: project, after: afterTask, at: createdAt)
        }
        undoManager?.setActionName("Delete Task")
    }

    // MARK: - Private helpers

    fileprivate func deleteSubtask(_ subtask: Task, from parent: Task) {
        parent.subtasks.removeAll { $0.id == subtask.id }
        subtask.project.tasks.removeAll { $0.id == subtask.id }
        context.delete(subtask)
    }

    fileprivate func unindentTask(_ task: Task, fromParent parent: Task, into project: Project) {
        // Restore the larger top-level (title3) title font when promoting back up.
        task.titleRTF = Task.resizingFontRTF(task.titleRTF, to: NSFont.preferredFont(forTextStyle: .title3).pointSize)
        task.parent = nil
        parent.subtasks.removeAll { $0.id == task.id }
        if !project.tasks.contains(where: { $0.id == task.id }) {
            project.tasks.append(task)
        }
        // Place at the end of the project's root tasks and renumber both lists.
        task.sortIndex = (Self.orderedRoots(of: project).filter { $0.id != task.id }.map(\.sortIndex).max() ?? -1) + 1
        reindex(Self.orderedRoots(of: project))
        reindex(Self.orderedSubtasks(of: parent))
        // The promoted task is no longer a subtask, so re-derive the former parent's
        // completion from whatever subtasks remain.
        parent.syncDoneWithSubtasks()
    }

    private func restore(snapshot: TaskSnapshot, into project: Project, after afterTask: Task?, at createdAt: Date) {
        let task = Task(priority: snapshot.priority, project: project)
        task.titleRTF  = snapshot.titleRTF
        task.descRTF   = snapshot.descRTF
        task.isDone    = snapshot.isDone
        task.createdAt = createdAt
        task.sortIndex = snapshot.sortIndex
        context.insert(task)
        project.tasks.append(task)

        for sub in snapshot.subtasks {
            let subtask = Task(priority: sub.priority, project: project, parent: task)
            subtask.titleRTF  = sub.titleRTF
            subtask.descRTF   = sub.descRTF
            subtask.isDone    = sub.isDone
            subtask.createdAt = sub.createdAt
            subtask.sortIndex = sub.sortIndex
            context.insert(subtask)
            task.subtasks.append(subtask)
        }

        // Re-seat the restored task at its original position among current roots.
        var roots = Self.orderedRoots(of: project).filter { $0.id != task.id }
        let insertAt = min(snapshot.sortIndex, roots.count)
        roots.insert(task, at: insertAt)
        reindex(roots)
        _ = afterTask // position now comes from the snapshot's sortIndex

        undoManager?.registerUndo(withTarget: self) { [weak project] store in
            guard let project else { return }
            store.undoManager?.setActionName("Add Task")
            store.deleteTask(task, in: project)
        }
        undoManager?.setActionName("Delete Task")
    }
}
