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

    /// Flushes pending changes to disk NOW. SwiftData's autosave is deferred (it fires
    /// on run-loop ticks and on graceful termination), so a new task/subtask can be lost
    /// if the process dies before a tick — an Xcode rebuild (SIGKILL) or a freeze that
    /// never reaches a clean quit. Every public mutation calls this so an edit is durable
    /// the instant it happens. Failures are logged, not thrown: a mutation must never
    /// crash the UI, and the pending change stays in the context for the next save/quit.
    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            diagnostics.record("save-failed", "\(error)")
        }
    }

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
        diagnostics.record("addTask", "task=\(Self.short(task.id)) project=\(Self.short(project.id))")

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
        save()
        return task
    }

    func indentTask(_ task: Task, previousTask: Task?) {
        guard let parent = previousTask else { return }
        let project = task.project
        diagnostics.record("indentTask",
            "task=\(Self.short(task.id)) parent=\(Self.short(parent.id)) project=\(Self.short(project.id))")
        // Re-render the title at the subtask (body) font size so it doesn't stay
        // at the larger top-level (title3) size it was created with.
        task.titleRTF = Task.resizingFontRTF(task.titleRTF, to: NSFont.preferredFont(forTextStyle: .body).pointSize)
        // Nest by setting ONLY the to-one `parent` side; the explicit inverses let
        // SwiftData maintain parent.subtasks and drop the task from its root position.
        // Setting them by hand (append/removeAll) double-writes those collections and the
        // nesting doesn't survive save/reload — the task loads back as a root task. (Same
        // hazard/fix as reassignProject.)
        task.parent = parent
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
        save()
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
        save()
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
        save()
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
        save()
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
        save()
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
        save()
    }

    /// Reassigns a task's project by setting only the to-one `project` side. With
    /// the explicit inverse declared on Project.tasks, SwiftData maintains both the
    /// old and new project's `tasks` arrays automatically.
    private func reassignProject(_ task: Task, to project: Project) {
        task.project = project
    }

    @discardableResult
    func addSubtask(plainTitle: String = "", priority: Int = 1, to parent: Task, after afterSubtask: Task? = nil, before beforeSubtask: Task? = nil) -> Task {
        // `parent:` at init sets the to-one side; the inverse maintains parent.subtasks.
        // Don't append manually too — same double-write hazard as indentTask.
        let subtask = Task(plainTitle: plainTitle, priority: priority, project: parent.project, parent: parent)
        context.insert(subtask)
        diagnostics.record("addSubtask",
            "task=\(Self.short(subtask.id)) parent=\(Self.short(parent.id))")
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
        save()
        return subtask
    }

    /// Flips a task's completion from a checkbox, keeping the side effects the store owns:
    /// cancelling the reminder when it's completed (so a finished task can't still fire a
    /// notification), re-deriving its parent's completion, registering undo, and saving.
    ///
    /// The list checkbox and the detail view's chips used to call `task.toggleDone()`
    /// straight on the model, which skipped all of that — a ticked task kept its reminder
    /// and fired later, ⌘Z couldn't reverse it, and the change sat unsaved until the app
    /// lost focus. Completion is derived for a task WITH subtasks, so those are left to
    /// `syncDoneWithSubtasks` and ignored here.
    func toggleDone(_ task: Task) {
        guard !task.isDrivenBySubtasks else { return }

        let wasDone      = task.isDone
        let wasCompleted = task.completedAt
        let wasReminder  = task.reminderDate
        let parent       = task.parent
        let parentWasDone      = parent?.isDone
        let parentWasCompleted = parent?.completedAt

        task.setDone(!wasDone)
        if task.isDone {
            task.reminderDate = nil
            reminderManager?.cancel(taskID: task.id)
        }
        parent?.syncDoneWithSubtasks()

        undoManager?.registerUndo(withTarget: self) { store in
            store.undoManager?.setActionName(wasDone ? "Complete Task" : "Reopen Task")
            task.isDone = wasDone
            task.completedAt = wasCompleted
            task.reminderDate = wasReminder
            if wasReminder != nil { store.reminderManager?.schedule(task: task) }
            if let parent, let parentWasDone {
                parent.isDone = parentWasDone
                parent.completedAt = parentWasCompleted
            }
        }
        undoManager?.setActionName(wasDone ? "Reopen Task" : "Complete Task")
        save()
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

        // A parent's completion is DERIVED from its subtasks, so completing the last
        // outstanding one has to complete the parent. The checkbox and detail views
        // already did this; completeTask (the notification's Mark Done action) didn't, so
        // finishing a subtask from a reminder left the parent open even though all its
        // subtasks were done — the same action giving a different result depending on
        // where it was invoked from.
        let formerParent = task.parent
        let parentWasDone = formerParent?.isDone
        let parentWasCompleted = formerParent?.completedAt
        formerParent?.syncDoneWithSubtasks()

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
            // Restore the parent's own completion, which the sync above may have flipped.
            if let formerParent, let parentWasDone {
                formerParent.isDone = parentWasDone
                formerParent.completedAt = parentWasCompleted
            }
        }
        undoManager?.setActionName("Complete Task")
        save()
    }

    func deleteTask(_ task: Task) {
        deleteTask(task, in: task.project)
    }

    func deleteTask(_ task: Task, in project: Project) {
        let snapshot   = TaskSnapshot(task)
        let createdAt  = task.createdAt
        let afterIndex = project.tasks.firstIndex(where: { $0.id == task.id }).map { $0 - 1 }
        let afterTask  = afterIndex.flatMap { $0 >= 0 ? project.tasks[$0] : nil }
        diagnostics.record("deleteTask",
            "task=\(Self.short(task.id)) project=\(Self.short(project.id)) subtasks=\(task.subtasks.count) isSubtask=\(task.parent != nil)")

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
        save()
    }

    // MARK: - Private helpers

    fileprivate func deleteSubtask(_ subtask: Task, from parent: Task) {
        diagnostics.record("deleteSubtask",
            "task=\(Self.short(subtask.id)) parent=\(Self.short(parent.id))")
        parent.subtasks.removeAll { $0.id == subtask.id }
        subtask.project.tasks.removeAll { $0.id == subtask.id }
        context.delete(subtask)
        save()
    }

    fileprivate func unindentTask(_ task: Task, fromParent parent: Task, into project: Project) {
        diagnostics.record("unindentTask",
            "task=\(Self.short(task.id)) fromParent=\(Self.short(parent.id)) project=\(Self.short(project.id))")
        // Restore the larger top-level (title3) title font when promoting back up.
        task.titleRTF = Task.resizingFontRTF(task.titleRTF, to: NSFont.preferredFont(forTextStyle: .title3).pointSize)
        // Clear ONLY the to-one `parent` side (the un-nest mirror of indentTask); the
        // explicit inverses drop it from parent.subtasks and list it as a root again.
        task.parent = nil
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
        save()
    }
}
