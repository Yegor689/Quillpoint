import Foundation
import SwiftData

/// FROZEN point-in-time copies of the models as they existed in schema V1
/// (`Task.project` optional). These exist ONLY so `SchemaV1` can describe the old
/// on-disk shape for the V1→V2 migration; nothing else in the app uses them and
/// they must never change. The live `Project`/`Task` types are the current (V2)
/// schema.
///
/// The persisted entity/attribute names must match the live models exactly (same
/// class names `Project`/`Task`, same property names) so SwiftData treats them as
/// the same store entities across versions — hence the `SchemaV1` enum namespace to
/// avoid a Swift type-name collision while keeping the SwiftData model names equal.
enum SchemaV1Models {

    @Model
    final class Project {
        var id: UUID = UUID()
        var title: String = ""
        var desc: String = ""
        var createdAt: Date = Date()
        // IMPORTANT: this must match the shape SHIPPED in 1.0.x exactly, or SwiftData
        // computes a different schema hash for V1 than what's recorded on disk and
        // the migration can't start (loadIssueModelContainer). 1.0.x declared this
        // relationship with an INFERRED inverse (no `inverse:`); the explicit inverse
        // was a later (V2) change and must NOT appear here.
        @Relationship(deleteRule: .cascade) var tasks: [Task] = []

        init() {}
    }

    @Model
    final class Task {
        var id: UUID = UUID()
        var titleRTF: Data = Data()
        var descRTF: Data = Data()
        var isDone: Bool = false
        var priority: Int = 1
        var createdAt: Date = Date()
        var sortIndex: Int = 0
        var completedAt: Date?
        var reminderDate: Date?
        // The V1 shape: optional project. This is the field the V2 migration backfills.
        var project: Project?
        @Relationship(inverse: \Task.subtasks) var parent: Task?
        @Relationship(deleteRule: .cascade) var subtasks: [Task] = []

        init() {}
    }
}
