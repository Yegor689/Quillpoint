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

/// V1 — the shape shipped through 1.0.x: `Task.project` is optional.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Project.self, Task.self] }
}

/// Entry point the app and backups build their `Schema` from — always the latest.
enum QuillpointSchema {
    static var current: Schema { Schema(versionedSchema: SchemaV1.self) }
}

/// Maps older on-disk schema versions forward. One stage per breaking change.
enum QuillpointMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
