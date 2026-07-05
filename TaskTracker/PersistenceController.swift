import Foundation
import SwiftData

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

    /// Attempts to open the store, taking a pre-migration backup when needed. On
    /// failure the store is left untouched and `.failed` is returned — nothing is
    /// moved or deleted, so a retry (or a later fixed build) can still read it.
    static func bringUp(storeURL: URL,
                        schema: Schema,
                        migrationPlan: (any SchemaMigrationPlan.Type)?,
                        backupManager: BackupManager? = nil) -> State {
        let config = ModelConfiguration(schema: schema, url: storeURL)

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

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: Date())
    }
}
