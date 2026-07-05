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

    @Test func failedOpenLeavesStoreInPlace() throws {
        let tmp = TempDir()
        let storeURL = tmp.store()

        // Write a file that is not a valid SQLite/SwiftData store.
        try Data("not a database".utf8).write(to: storeURL)

        let state = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self)

        guard case .failed(_, let reportedURL) = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
        // CRITICAL: the store is NOT moved on failure — so "Try Again" retries the
        // same data and the app never silently comes up blank.
        #expect(reportedURL == storeURL)
        #expect(FileManager.default.fileExists(atPath: storeURL.path),
                "failed open must leave the store exactly where it is")
        // No Quarantine folder is created automatically.
        let quarantineDir = storeURL.deletingLastPathComponent().appending(component: "Quarantine")
        #expect(FileManager.default.fileExists(atPath: quarantineDir.path) == false)
    }

    @Test func startFreshQuarantinesStoreNeverDeletes() throws {
        let tmp = TempDir()
        let storeURL = tmp.store()
        try Data("not a database".utf8).write(to: storeURL)

        // Explicit user choice: set the store aside.
        let qURL = try #require(PersistenceController.startFresh(storeURL: storeURL),
                                "startFresh should report a quarantine URL")

        // Original moved out of the way; quarantined copy still exists (never deleted).
        #expect(FileManager.default.fileExists(atPath: storeURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: qURL.path))
        #expect(qURL.path.contains("Quarantine"))

        // A subsequent bring-up now opens a clean empty store successfully.
        let state = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self)
        guard case .ready = state else {
            Issue.record("expected .ready after startFresh, got \(state)")
            return
        }
    }
}
