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
        save()
        return project
    }

    func updateProject(_ project: Project, title: String? = nil, desc: String? = nil) {
        if let title { project.title = title }
        if let desc  { project.desc  = desc  }
        save()
    }

    func deleteProject(_ project: Project) {
        context.delete(project)
        save()
    }
}
