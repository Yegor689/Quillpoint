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

    // MARK: - Real 1.0.x store

    /// Migrates a REAL 1.0.x store (checked in at TaskTrackerTests/Fixtures/v1_0_x.store,
    /// created by the actual 1.0.x app long before any migration code existed). Unlike
    /// the self-seeded tests above — which seed with SchemaV1Models and therefore can't
    /// detect a SchemaV1-vs-shipped-shape mismatch — this opens a store the current code
    /// never wrote, so it faithfully reproduces the production upgrade path.
    ///
    /// This is the test that WOULD HAVE CAUGHT the 1.1.0 `loadIssueModelContainer` bug:
    /// SchemaV1Models declared an explicit relationship inverse the shipped models
    /// lacked, so a real 1.0.x store failed to open through the plan.
    @Test func realV1StoreMigratesThroughThePlan() throws {
        // Locate the fixture inside the test bundle.
        let fixture = try #require(
            Bundle(for: BundleToken.self).url(forResource: "v1_0_x", withExtension: "store"),
            "v1_0_x.store fixture missing from the test bundle")

        // Work on a copy so the fixture is never migrated in place.
        let work = FileManager.default.temporaryDirectory
            .appending(component: "realv1-\(UUID().uuidString).store")
        try FileManager.default.copyItem(at: fixture, to: work)
        defer { for e in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: work.path + e)) } }

        // THE CHECK: opening the real store through the plan must not throw
        // (loadIssueModelContainer is the production failure) and must migrate the data.
        let container = try ModelContainer(
            for: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self,
            configurations: ModelConfiguration(schema: QuillpointSchema.current, url: work))

        let ctx = container.mainContext
        let projects = try ctx.fetch(FetchDescriptor<Project>())
        let tasks = try ctx.fetch(FetchDescriptor<Task>())

        // Data survived the migration and every task has its (now required) project.
        #expect(!projects.isEmpty)
        #expect(!tasks.isEmpty)
        // `task.project` is non-optional in V2; a successful fetch already proves no
        // orphan violated the constraint. Assert membership is coherent too.
        let projectIDs = Set(projects.map(\.id))
        #expect(tasks.allSatisfy { projectIDs.contains($0.project.id) })
    }
}

/// Anchors `Bundle(for:)` to the test target so the fixture resolves.
private final class BundleToken {}
