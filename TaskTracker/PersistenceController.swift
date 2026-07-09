import Foundation
import SwiftData
import CoreData

/// Owns SwiftData container bring-up so the app never loses data on a failed open
/// or migration. The original inline path deleted the store and started empty on any
/// failure — silent total loss. This does the opposite:
///
/// 1. If a migration will run, take a safety backup first via `BackupManager`.
/// 2. Open the container (with the migration plan).
/// 3. On failure, LEAVE THE STORE IN PLACE and report `.failed`. The store is NOT
///    moved or deleted, so "Try Again" retries against the same data (useful for a
///    transient failure) and the app never silently comes up blank. Setting the store
///    aside to start fresh is an EXPLICIT user choice via `startFresh(storeURL:)`.
enum PersistenceController {

    /// Result of bringing up the store. `.ready` carries the live container; `.failed`
    /// carries the reason and the store URL (left in place, not moved).
    enum State {
        case ready(ModelContainer)
        case failed(reason: String, storeURL: URL)
    }

    /// Prefix on the `.failed` reason when the store was written by a newer build. The
    /// recovery UI could branch on this later; for now it just makes the log clear.
    static let downgradeReasonPrefix = "This data was created by a newer version of Quillpoint."

    /// Attempts to open the store, taking a pre-migration backup when needed. On
    /// failure the store is left untouched and `.failed` is returned — nothing is
    /// moved or deleted, so a retry (or a later fixed build) can still read it.
    static func bringUp(storeURL: URL,
                        schema: Schema,
                        migrationPlan: (any SchemaMigrationPlan.Type)?,
                        backupManager: BackupManager? = nil) -> State {
        let config = ModelConfiguration(schema: schema, url: storeURL)

        // Downgrade guard: if the store on disk was written by a NEWER build of
        // Quillpoint than this one, refuse to open it. There is no downgrade migration,
        // so opening it would let this older build silently rewrite a newer store in the
        // old shape (the root cause of the 2026-07 corruption). Fail into recovery
        // instead — the data is left completely untouched.
        if let storeVersion = onDiskVersion(storeURL: storeURL),
           storeVersion > QuillpointSchema.newestKnownVersion {
            let reason = "\(downgradeReasonPrefix) The data is version \(storeVersion.description), "
                + "but this build only understands up to \(QuillpointSchema.newestKnownVersion.description). "
                + "Update Quillpoint to open it. Your data has been left untouched."
            return .failed(reason: reason, storeURL: storeURL)
        }

        // Safety backup before a migration mutates the store.
        if let backupManager,
           migrationPlan != nil,
           FileManager.default.fileExists(atPath: storeURL.path) {
            backupManager.createBackup(label: "before migration", kind: .preRestore)
        }

        do {
            let container: ModelContainer
            if let migrationPlan {
                container = try ModelContainer(for: schema,
                                               migrationPlan: migrationPlan,
                                               configurations: config)
            } else {
                container = try ModelContainer(for: schema, configurations: config)
            }
            return .ready(container)
        } catch {
            // Leave the store exactly where it is. Recovery is the user's call.
            return .failed(reason: String(describing: error), storeURL: storeURL)
        }
    }

    /// EXPLICIT "start fresh": moves the unreadable store (and `-wal`/`-shm`) into a
    /// timestamped Quarantine folder — NEVER deletes — so a subsequent bring-up
    /// creates a clean empty store while the old data stays recoverable. Returns the
    /// quarantine URL, or nil if there was nothing to move. Only call this in response
    /// to a deliberate user action, never automatically.
    @discardableResult
    static func startFresh(storeURL: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }

        let quarantineDir = storeURL.deletingLastPathComponent()
            .appending(component: "Quarantine", directoryHint: .isDirectory)
        try? fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)

        let stamp = timestamp()
        let base = storeURL.deletingPathExtension().lastPathComponent
        let dest = quarantineDir.appending(component: "\(base)-\(stamp).store")

        do {
            try fm.moveItem(at: storeURL, to: dest)
        } catch {
            return nil
        }
        for ext in ["store-wal", "store-shm"] {
            let side = storeURL.deletingPathExtension().appendingPathExtension(ext)
            let sideDest = dest.deletingPathExtension().appendingPathExtension(ext)
            try? fm.moveItem(at: side, to: sideDest)
        }
        return dest
    }

    /// Reads the schema version recorded in the store's metadata WITHOUT opening it
    /// through SwiftData (which is exactly what may fail). SwiftData/Core Data writes
    /// the writing schema's version identifier into the store's `NSStoreModelVersionIdentifiers`
    /// metadata key; we return the largest one found, or nil if the store is absent or
    /// unreadable (in which case the normal open path handles it). Never throws.
    nonisolated static func onDiskVersion(storeURL: URL) -> Schema.Version? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: storeURL)
        else { return nil }

        guard let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [String]
        else { return nil }

        // Identifiers look like "2.0.0"; parse and take the max.
        return identifiers.compactMap(Self.parseVersion).max()
    }

    /// Parses a "major.minor.patch" identifier into a `Schema.Version`. Returns nil for
    /// anything that doesn't have three numeric components.
    nonisolated private static func parseVersion(_ s: String) -> Schema.Version? {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Schema.Version(parts[0], parts[1], parts[2])
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: Date())
    }
}
