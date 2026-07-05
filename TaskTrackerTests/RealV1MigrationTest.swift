import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// Migrates a REAL 1.0.x store (checked in at TaskTrackerTests/Fixtures/v1_0_x.store,
/// created by the actual 1.0.x app long before any migration code existed). Unlike the
/// self-seeded MigrationTests — which seed with SchemaV1Models and therefore can't
/// detect a SchemaV1-vs-shipped-shape mismatch — this opens a store the current code
/// never wrote, so it faithfully reproduces the production upgrade path.
///
/// This is the test that WOULD HAVE CAUGHT the 1.1.0 `loadIssueModelContainer` bug:
/// SchemaV1Models declared an explicit relationship inverse the shipped models lacked,
/// so a real 1.0.x store failed to open through the plan.
@MainActor
struct RealV1MigrationTest {

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
