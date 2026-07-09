import Foundation
import SwiftData

/// Versioned schema history for the store. Every breaking change adds a new
/// `VersionedSchema` here and a `MigrationStage` to `QuillpointMigrationPlan`, so
/// existing customer stores migrate forward deterministically instead of relying on
/// SwiftData's implicit lightweight migration (which silently fails on breaking
/// changes and, with the old bring-up path, took the data with it).
///
/// Convention: the models the app uses at runtime are always the LATEST version's
/// models (the real `Project`/`Task` types). Older `VersionedSchema`s exist only to
/// describe past on-disk shapes so migrations can read them.

/// V1 — the shape shipped through 1.0.x: `Task.project` is optional. Described by
/// the frozen [SchemaV1Models] copies, not the live types (which are now V2).
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SchemaV1Models.Project.self, SchemaV1Models.Task.self]
    }
}

/// V2 — `Task.project` becomes non-optional. The live model types describe V2.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Project.self, Task.self] }
}

/// Entry point the app and backups build their `Schema` from — always the latest.
enum QuillpointSchema {
    static var current: Schema { Schema(versionedSchema: SchemaV2.self) }

    /// The newest schema version this build understands. A store recorded with a
    /// version GREATER than this was written by a newer build of Quillpoint, and this
    /// build must NOT open it (there is no downgrade migration — opening it would let
    /// an older build silently rewrite a newer store in the old shape). Used by the
    /// downgrade guard in `PersistenceController`.
    static var newestKnownVersion: Schema.Version { SchemaV2.versionIdentifier }
}

/// Maps older on-disk schema versions forward. One stage per breaking change.
enum QuillpointMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] { [migrateV1toV2] }

    /// V1→V2: `Task.project` went from optional to required. `willMigrate` sees the
    /// OLD (V1) store, where `project` is still optional and settable — so we assign a
    /// project to every orphan there, before the non-optional V2 shape is enforced.
    /// A subtask inherits its parent's project; a root orphan goes to the first
    /// existing project, or a created fallback if the store has none.
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: { context in
            let orphans = try context.fetch(FetchDescriptor<SchemaV1Models.Task>(
                predicate: #Predicate { $0.project == nil }))
            for task in orphans {
                ProjectBackfill.assignV1Project(to: task, in: context)
            }
            try context.save()
        },
        didMigrate: nil
    )
}
