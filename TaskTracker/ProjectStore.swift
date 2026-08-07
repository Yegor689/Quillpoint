import Foundation
import SwiftData

@Observable
final class ProjectStore {
    private let context: ModelContext
    private let diagnostics: DiagnosticLog

    init(context: ModelContext, diagnostics: DiagnosticLog = .shared) {
        self.context = context
        self.diagnostics = diagnostics
    }

    /// Flushes pending changes to disk NOW. SwiftData's autosave is deferred, so a new
    /// or renamed project can be lost if the process dies before an autosave tick (an
    /// Xcode rebuild / a freeze). Every mutation calls this so the change is durable
    /// immediately. Failures are logged, not thrown — a mutation must never crash the UI.
    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            diagnostics.record("project-save-failed", "\(error)")
        }
    }

    @discardableResult
    func createProject(title: String, desc: String = "") -> Project {
        let project = Project(title: title, desc: desc)
        context.insert(project)
        diagnostics.record("createProject", "project=\(Self.short(project.id))")
        save()
        return project
    }

    func updateProject(_ project: Project, title: String? = nil, desc: String? = nil) {
        if let title { project.title = title }
        if let desc  { project.desc  = desc  }
        diagnostics.record("updateProject", "project=\(Self.short(project.id))")
        save()
    }

    /// Deletes a project, cascade-deleting every task in it — the most destructive action
    /// in the app, so the task count is recorded before the delete for bug reports.
    func deleteProject(_ project: Project) {
        diagnostics.record("deleteProject",
            "project=\(Self.short(project.id)) tasks=\(project.tasks.count)")
        context.delete(project)
        save()
    }

    /// First 8 chars of a UUID — compact, correlatable id for the diagnostic log.
    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
}
