import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// Tests the store bring-up safety net: a healthy store opens `.ready`, and a
/// store that fails to open is QUARANTINED (moved aside, never deleted) with a
/// `.failed` result — replacing the old path that deleted the store and started
/// empty. Uses unique on-disk stores (in-memory SIGTRAPs on the beta toolchain).
@MainActor
struct PersistenceControllerTests {

    /// A unique temp directory that is cleaned up when the fixture is released.
    final class TempDir {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appending(component: "PCTest-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        func store(_ name: String = "TaskTracker.store") -> URL { url.appending(component: name) }
    }

    @Test func healthyStoreOpensReady() throws {
        let tmp = TempDir()
        let state = PersistenceController.bringUp(
            storeURL: tmp.store(),
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self)

        guard case .ready = state else {
            Issue.record("expected .ready, got \(state)")
            return
        }
    }

    @Test func corruptStoreIsQuarantinedNotDeleted() throws {
        let tmp = TempDir()
        let storeURL = tmp.store()

        // Write a file that is not a valid SQLite/SwiftData store.
        try Data("not a database".utf8).write(to: storeURL)

        let state = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self)

        // The open must fail and report a quarantine location.
        guard case .failed(_, let quarantineURL) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        let qURL = try #require(quarantineURL, "a quarantine URL should be reported")

        // The store was MOVED, not deleted: original gone, quarantine copy present.
        #expect(FileManager.default.fileExists(atPath: storeURL.path) == false,
                "original store should have been moved out of the way")
        #expect(FileManager.default.fileExists(atPath: qURL.path),
                "quarantined store must still exist — data is never deleted")
        #expect(qURL.path.contains("Quarantine"))
    }
}
