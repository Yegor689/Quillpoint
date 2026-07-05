import Foundation
import SwiftData

/// Owns SwiftData container bring-up so the app never loses data on a failed open
/// or migration. The old inline path deleted the store and started empty on any
/// failure — for a customer with real data that meant silent total loss. Instead:
///
/// 1. If a migration will run (on-disk schema older than the code's), take a safety
///    backup first via `BackupManager` so there is always a rollback point.
/// 2. Open the container with the migration plan.
/// 3. On failure, QUARANTINE the store (move it aside, never delete) and report
///    `.failed` so the UI can show a recovery screen instead of an empty app.
enum PersistenceController {

    /// Result of bringing up the store. `.ready` carries the live container;
    /// `.failed` carries a human-readable reason and, when we managed to preserve
    /// the store, the quarantine location to show the user.
    enum State {
        case ready(ModelContainer)
        case failed(reason: String, quarantineURL: URL?)
    }

    /// Attempts to open the store, taking a pre-migration backup when needed and
    /// quarantining the store (never deleting) if the open throws.
    ///
    /// - Parameters:
    ///   - storeURL: the live SwiftData store.
    ///   - schema: the current (latest) schema.
    ///   - migrationPlan: the migration plan mapping older on-disk versions forward.
    ///   - backupManager: used to snapshot before a migration. Optional so tests can
    ///     exercise the open/quarantine path without the backup machinery.
    static func bringUp(storeURL: URL,
                        schema: Schema,
                        migrationPlan: (any SchemaMigrationPlan.Type)?,
                        backupManager: BackupManager? = nil) -> State {
        let config = ModelConfiguration(schema: schema, url: storeURL)

        // Safety backup before a migration mutates the store. We can't cheaply know
        // the exact on-disk version here, so we snapshot whenever a store already
        // exists and a migration plan is in play — a spare backup is harmless; a
        // missing one before a lossy migration is not.
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
            let quarantined = quarantine(storeURL: storeURL)
            return .failed(reason: String(describing: error), quarantineURL: quarantined)
        }
    }

    /// Moves the store and its `-wal`/`-shm` sidecars into a timestamped Quarantine
    /// folder next to the store. NEVER deletes. Returns the quarantined store URL, or
    /// nil if there was nothing to move / the move failed.
    private static func quarantine(storeURL: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }

        let quarantineDir = storeURL.deletingLastPathComponent()
            .appending(component: "Quarantine", directoryHint: .isDirectory)
        try? fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)

        let stamp = timestamp()
        let base = storeURL.deletingPathExtension().lastPathComponent
        let dest = quarantineDir.appending(component: "\(base)-\(stamp).store")

        // Move the base store; best-effort move the sidecars alongside it.
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
