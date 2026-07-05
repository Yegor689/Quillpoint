import Foundation
import SwiftData

/// Single home for "a task must belong to a project" backfill logic, shared by the
/// V1→V2 migration (when `Task.project` became non-optional) and by backup restore
/// (an older backup may hold a task with no project). Keeping one implementation
/// means the two paths can't drift apart and reintroduce an orphan.
enum ProjectBackfill {

    /// Chooses a project for a task that currently has none:
    /// 1. its parent's project (a subtask always belongs where its parent does), else
    /// 2. the alphabetically-first existing project, else
    /// 3. a freshly created fallback project (only when the store has NO projects at
    ///    all — an orphan can't be assigned to nothing).
    ///
    /// Inserts and returns the chosen project. Never returns nil, so callers can
    /// satisfy the non-optional `project` for every task.
    @discardableResult
    static func assignProject(to task: Task, in context: ModelContext) -> Project {
        if let parentProject = task.parent?.project {
            task.project = parentProject
            return parentProject
        }
        let project = firstProject(in: context) ?? makeFallback(in: context)
        task.project = project
        return project
    }

    /// The alphabetically-first project in the store, if any.
    private static func firstProject(in context: ModelContext) -> Project? {
        var descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.title)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Creates the fallback project used only when the store has no projects at all.
    private static func makeFallback(in context: ModelContext) -> Project {
        let project = Project(title: "Tasks")
        context.insert(project)
        return project
    }

    // MARK: - V1 migration variant

    /// Same policy as `assignProject`, but operates on the frozen V1 model types
    /// during the V1→V2 migration's `willMigrate` (which sees the old, still-optional
    /// store). Kept alongside the live version so the policy stays in one file.
    @discardableResult
    static func assignV1Project(to task: SchemaV1Models.Task,
                                in context: ModelContext) -> SchemaV1Models.Project {
        if let parentProject = task.parent?.project {
            task.project = parentProject
            return parentProject
        }
        let project = firstV1Project(in: context) ?? makeV1Fallback(in: context)
        task.project = project
        return project
    }

    private static func firstV1Project(in context: ModelContext) -> SchemaV1Models.Project? {
        var descriptor = FetchDescriptor<SchemaV1Models.Project>(sortBy: [SortDescriptor(\.title)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func makeV1Fallback(in context: ModelContext) -> SchemaV1Models.Project {
        let project = SchemaV1Models.Project()
        project.title = "Tasks"
        context.insert(project)
        return project
    }
}
