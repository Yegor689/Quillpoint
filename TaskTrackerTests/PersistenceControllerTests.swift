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

    /// Opening a store that is ALREADY at the current version must NOT take a
    /// "before migration" backup — no migration will run. Regression for the bug where
    /// the pre-migration backup fired on every launch (migrationPlan always non-nil),
    /// piling up unbounded "before migration" backups.
    @Test func noPreMigrationBackupWhenStoreIsCurrent() throws {
        let tmp = TempDir()
        let storeURL = tmp.store()
        let backupDir = tmp.url.appending(component: "Backups", directoryHint: .isDirectory)
        let defaults = UserDefaults(suiteName: "pc-\(UUID().uuidString)")!
        let mgr = BackupManager(storeURL: storeURL, backupDir: backupDir, defaults: defaults)

        // First open creates the store at the CURRENT version.
        _ = PersistenceController.bringUp(storeURL: storeURL, schema: QuillpointSchema.current,
                                          migrationPlan: QuillpointMigrationPlan.self, backupManager: mgr)
        mgr.refresh()
        let afterFirst = mgr.preRestoreBackups.count

        // Second open of the now-current store must NOT add a "before migration" backup.
        _ = PersistenceController.bringUp(storeURL: storeURL, schema: QuillpointSchema.current,
                                          migrationPlan: QuillpointMigrationPlan.self, backupManager: mgr)
        mgr.refresh()
        #expect(mgr.preRestoreBackups.count == afterFirst,
                "a current-version store must not trigger a pre-migration backup")
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

    // MARK: - Quarantine listing (recovery-screen restore source)

    /// A store set aside by startFresh shows up in `quarantinedStores`, so the recovery
    /// screen can offer it for restore — making "recoverable later" real.
    @Test func startFreshStoreIsListedAsQuarantined() throws {
        let tmp = TempDir()
        let storeURL = tmp.store()
        try Data("not a database".utf8).write(to: storeURL)

        #expect(PersistenceController.quarantinedStores(storeURL: storeURL).isEmpty)

        PersistenceController.startFresh(storeURL: storeURL)

        let listed = PersistenceController.quarantinedStores(storeURL: storeURL)
        #expect(listed.count == 1)
        #expect(listed.first?.url.pathExtension == "store")
        #expect(listed.first?.url.path.contains("Quarantine") == true)
    }

    /// Multiple set-aside stores are listed newest-first.
    @Test func quarantinedStoresSortedNewestFirst() throws {
        let tmp = TempDir()
        let storeURL = tmp.store()
        let qDir = storeURL.deletingLastPathComponent().appending(component: "Quarantine")
        try FileManager.default.createDirectory(at: qDir, withIntermediateDirectories: true)

        let older = qDir.appending(component: "TaskTracker-2020-01-01 00-00-00.store")
        let newer = qDir.appending(component: "TaskTracker-2025-01-01 00-00-00.store")
        try Data("a".utf8).write(to: older)
        try Data("b".utf8).write(to: newer)
        // Stamp modification dates so ordering is deterministic.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)

        let listed = PersistenceController.quarantinedStores(storeURL: storeURL)
        #expect(listed.count == 2)
        #expect(listed.first?.url.lastPathComponent == newer.lastPathComponent)
    }

    /// `canOpen` probes a real open: a valid current store passes, a corrupt file fails.
    /// This is what the recovery picker uses to hide dead set-aside stores.
    @Test func canOpenAcceptsValidStoreAndRejectsCorrupt() throws {
        let tmp = TempDir()
        let good = tmp.store("good.store")
        do {
            let c = try ModelContainer(
                for: QuillpointSchema.current,
                configurations: ModelConfiguration(schema: QuillpointSchema.current, url: good))
            _ = c
        }
        #expect(PersistenceController.canOpen(storeURL: good) == true)

        let bad = tmp.store("bad.store")
        try Data("not a database".utf8).write(to: bad)
        #expect(PersistenceController.canOpen(storeURL: bad) == false)

        let missing = tmp.store("missing.store")
        #expect(PersistenceController.canOpen(storeURL: missing) == false)
    }

    /// canOpen probes a COPY, so it has to copy the sidecars too.
    ///
    /// Its sidecar paths were built with appendingPathExtension ("<store>.store.wal"),
    /// which never exists — so the probe copied the base file without its WAL and returned
    /// a verdict about a store that isn't the one being restored. This is the final guard
    /// before a restore, so a wrong answer here sends the user into a restore that was
    /// never really checked.
    @Test func canOpenCopiesSidecarsAlongsideTheStore() throws {
        let tmp = TempDir()
        let store = tmp.store("withsidecars.store")
        do {
            let c = try ModelContainer(
                for: QuillpointSchema.current,
                configurations: ModelConfiguration(schema: QuillpointSchema.current, url: store))
            _ = c
        }

        // A store with sidecars present must still probe as openable — and the probe must
        // clean up after itself rather than leaving copies in the temp directory.
        let fm = FileManager.default
        if !fm.fileExists(atPath: store.path + "-wal") {
            try Data().write(to: URL(fileURLWithPath: store.path + "-wal"))
        }
        #expect(PersistenceController.canOpen(storeURL: store) == true)

        let strays = try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)
            .filter { $0.hasPrefix("probe-") }
        #expect(strays.isEmpty, "probe temp files cleaned up")
    }

    /// `looksOpenable` (the cheap list pre-filter): accepts a valid current store,
    /// rejects a corrupt file and a store recorded as a newer version — without a full
    /// migration open.
    @Test func looksOpenableFiltersCorruptAndNewer() throws {
        let tmp = TempDir()

        let good = tmp.store("good.store")
        do {
            let c = try ModelContainer(
                for: QuillpointSchema.current,
                configurations: ModelConfiguration(schema: QuillpointSchema.current, url: good))
            _ = c
        }
        #expect(PersistenceController.looksOpenable(storeURL: good) == true)

        let corrupt = tmp.store("corrupt.store")
        try Data("not a database".utf8).write(to: corrupt)
        #expect(PersistenceController.looksOpenable(storeURL: corrupt) == false)

        let newer = tmp.store("newer.store")
        do {
            let c = try ModelContainer(
                for: QuillpointSchema.current,
                configurations: ModelConfiguration(schema: QuillpointSchema.current, url: newer))
            _ = c
        }
        try bumpRecordedVersion(of: newer, to: "99.0.0")
        #expect(PersistenceController.looksOpenable(storeURL: newer) == false)
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
