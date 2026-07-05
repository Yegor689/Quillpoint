import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// V1→V2 migration guards. Seeds a store with the frozen V1 models (which MUST match
/// the shape shipped in 1.0.x — see the SchemaV1Models note) and opens it through the
/// plan. This can't catch a SchemaV1-vs-shipped-shape hash mismatch on its own (a
/// self-seeded store agrees with itself), so the real proof is opening a genuine 1.0.x
/// store — but it does guard that the migration plan runs and backfills correctly, and
/// that SchemaV1's declared shape stays loadable.
///
/// Uses a unique on-disk store; in-memory + migrating containers SIGTRAP on the beta.
@MainActor
struct MigrationTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "Mig-\(UUID().uuidString).store")
    }

    private func cleanup(_ url: URL) {
        for e in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + e)) }
    }

    @Test func orphanRootGoesToFirstProjectSubtaskInheritsParent() throws {
        let url = tempURL(); defer { cleanup(url) }
        let migrated = try migrateReturningURL(url) { ctx in
            let alpha = SchemaV1Models.Project(); alpha.title = "Alpha"
            let beta  = SchemaV1Models.Project(); beta.title  = "Beta"
            ctx.insert(alpha); ctx.insert(beta)
            let orphan = SchemaV1Models.Task(); orphan.titleRTF = Data("orphan".utf8); orphan.project = nil
            ctx.insert(orphan)
            let parent = SchemaV1Models.Task(); parent.titleRTF = Data("parent".utf8); parent.project = beta
            ctx.insert(parent); beta.tasks.append(parent)
            let sub = SchemaV1Models.Task(); sub.titleRTF = Data("sub".utf8); sub.project = nil; sub.parent = parent
            ctx.insert(sub); parent.subtasks.append(sub)
        }
        let ctx = migrated.mainContext
        let tasks = try ctx.fetch(FetchDescriptor<Task>())
        #expect(tasks.count == 3)
        let byTitle = Dictionary(uniqueKeysWithValues: tasks.map { (String(decoding: $0.titleRTF, as: UTF8.self), $0) })
        #expect(try #require(byTitle["orphan"]).project.title == "Alpha")  // first project
        #expect(try #require(byTitle["sub"]).project.title == "Beta")      // inherits parent
    }

    @Test func healthyV1MigratesUnchanged() throws {
        let url = tempURL(); defer { cleanup(url) }
        let migrated = try migrateReturningURL(url) { ctx in
            let p = SchemaV1Models.Project(); p.title = "Work"; ctx.insert(p)
            for n in ["a", "b"] { let t = SchemaV1Models.Task(); t.titleRTF = Data(n.utf8); t.project = p; ctx.insert(t); p.tasks.append(t) }
        }
        let tasks = try migrated.mainContext.fetch(FetchDescriptor<Task>())
        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { $0.project.title == "Work" })
    }

    /// Seeds a V1 store at `url` via the frozen V1 models, then reopens it through the
    /// migration plan and returns the migrated (V2) container.
    private func migrateReturningURL(_ url: URL, seed: (ModelContext) throws -> Void) throws -> ModelContainer {
        do {
            let schema = Schema(versionedSchema: SchemaV1.self)
            let c = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            try seed(c.mainContext)
            try c.mainContext.save()
        }
        return try ModelContainer(
            for: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self,
            configurations: ModelConfiguration(schema: QuillpointSchema.current, url: url))
    }
}
