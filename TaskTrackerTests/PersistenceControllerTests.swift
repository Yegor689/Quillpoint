import Testing
import Foundation
import SwiftData
import CoreData
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

    // MARK: - Downgrade guard

    /// A store written by a NEWER build (higher schema version than this build knows)
    /// must be REFUSED — not opened, not migrated, not touched — so an older build can
    /// never silently rewrite a newer store in the old shape.
    @Test func storeFromNewerBuildIsRefusedAndLeftUntouched() throws {
        let tmp = TempDir()
        let storeURL = tmp.store()

        // Create a normal store, then stamp its recorded version to one NEWER than any
        // this build understands (2.0.0 → 99.0.0), simulating a future build's store.
        do {
            let c = try ModelContainer(
                for: QuillpointSchema.current,
                configurations: ModelConfiguration(schema: QuillpointSchema.current, url: storeURL))
            _ = c // opened & created the file with its real metadata
        }
        try bumpRecordedVersion(of: storeURL, to: "99.0.0")

        // Sanity: the guard's reader sees the bumped version.
        let seen = PersistenceController.onDiskVersion(storeURL: storeURL)
        #expect(seen == Schema.Version(99, 0, 0))

        let before = try Data(contentsOf: storeURL)
        let state = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self)

        guard case .failed(let reason, let reportedURL) = state else {
            Issue.record("expected .failed (downgrade guard), got \(state)")
            return
        }
        #expect(reason.hasPrefix(PersistenceController.downgradeReasonPrefix))
        #expect(reportedURL == storeURL)
        // Untouched: still there, byte-for-byte, not quarantined.
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(try Data(contentsOf: storeURL) == before, "guard must not modify the store")
        let quarantineDir = storeURL.deletingLastPathComponent().appending(component: "Quarantine")
        #expect(FileManager.default.fileExists(atPath: quarantineDir.path) == false)
    }

    /// A store at the CURRENT version opens normally — the guard only trips on newer.
    @Test func storeAtCurrentVersionOpensNormally() throws {
        let tmp = TempDir()
        let storeURL = tmp.store()
        do {
            let c = try ModelContainer(
                for: QuillpointSchema.current,
                configurations: ModelConfiguration(schema: QuillpointSchema.current, url: storeURL))
            _ = c
        }
        // onDiskVersion should read the current (2.0.0) version, which is not > newest.
        let seen = PersistenceController.onDiskVersion(storeURL: storeURL)
        #expect(seen == QuillpointSchema.newestKnownVersion)

        let state = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self)
        guard case .ready = state else {
            Issue.record("expected .ready for current-version store, got \(state)")
            return
        }
    }

    /// Rewrites the store's recorded `NSStoreModelVersionIdentifiers` to `version`,
    /// without opening it through SwiftData — mimics a store written by another build.
    private func bumpRecordedVersion(of storeURL: URL, to version: String) throws {
        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: storeURL)
        metadata[NSStoreModelVersionIdentifiersKey] = [version]
        try NSPersistentStoreCoordinator.setMetadata(
            metadata, forPersistentStoreOfType: NSSQLiteStoreType, at: storeURL)
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
