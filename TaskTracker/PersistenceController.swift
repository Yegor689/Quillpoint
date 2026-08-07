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

    /// Prefix on the recovery `reason` when the store opened fine but its content looks
    /// meaningfully OLDER than last session (a suspected regression from a stale-store
    /// swap). RecoveryView branches on this to show the protective "restore or continue"
    /// variant rather than a hard open-failure.
    static let regressionReasonPrefix = "Your data may be out of date."

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

        // Safety backup ONLY when a migration will actually run — i.e. the store on disk
        // is at an OLDER schema version than this build. Without this version check the
        // backup fired on EVERY launch (migrationPlan is always non-nil and the store
        // always exists), piling up unbounded "before migration" backups. A migration
        // runs only when the recorded version is strictly older than the newest known.
        if let backupManager,
           migrationPlan != nil,
           FileManager.default.fileExists(atPath: storeURL.path),
           let onDisk = onDiskVersion(storeURL: storeURL),
           onDisk < QuillpointSchema.newestKnownVersion {
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

    /// A store previously set aside in the Quarantine folder (by Start Fresh or by a
    /// restore), which the recovery screen can offer to restore — closing the loop on
    /// the "your data can be recovered later" promise.
    struct QuarantinedStore: Identifiable {
        let id = UUID()
        let url: URL
        let date: Date
    }

    /// A CHEAP openability pre-check for list filtering: is this a valid SQLite/SwiftData
    /// store whose recorded version this build understands? Reads metadata only (no copy,
    /// no migration open), so it's fast enough to run over a whole backup folder. Catches
    /// the common dead cases — corrupt files (metadata unreadable) and stores from a newer
    /// build (version > newest). It can't detect an old-shape store that will fail
    /// migration; the lazy `canOpen` probe on the selected store is the final guard.
    nonisolated static func looksOpenable(storeURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }
        guard (try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: storeURL)) != nil
        else { return false }  // not a valid store (corrupt / not SQLite)
        // If it records a version, it must not be newer than this build understands.
        if let v = onDiskVersion(storeURL: storeURL), v > QuillpointSchema.newestKnownVersion { return false }
        return true
    }

    /// Trial-opens a `.store` file through the current schema + migration plan on a
    /// throwaway COPY (the original is never touched) to decide whether it can actually
    /// be restored. Returns false for corrupt files and for old-shape stores that would
    /// fail migration. This is the only reliable check — a store's metadata can look
    /// valid yet still fail to migrate. Used as the lazy final guard on the selected
    /// store; `looksOpenable` is the cheap pre-filter for lists.
    @MainActor
    static func canOpen(storeURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return false }
        let tmp = fm.temporaryDirectory.appending(component: "probe-\(UUID().uuidString).store")
        defer { for e in ["", "-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: tmp.path + e)) } }
        do {
            try fm.copyItem(at: storeURL, to: tmp)
            // SQLite sidecars are "<store>-wal"/"-shm". Built with appendingPathExtension
            // this asked for "<store>.store.wal", which never exists, so the probe copied
            // the base file WITHOUT its WAL and answered for a store that isn't the one
            // being restored — a store whose committed-but-uncheckpointed transactions
            // live in that -wal could be judged on incomplete data. Matches the `defer`
            // cleanup directly above.
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: storeURL.path + suffix)
                if fm.fileExists(atPath: side.path) {
                    try? fm.copyItem(at: side, to: URL(fileURLWithPath: tmp.path + suffix))
                }
            }
            _ = try ModelContainer(
                for: QuillpointSchema.current,
                migrationPlan: QuillpointMigrationPlan.self,
                configurations: ModelConfiguration(schema: QuillpointSchema.current, url: tmp))
            return true
        } catch {
            return false
        }
    }

    /// Lists stores in the Quarantine folder next to `storeURL`, newest first. These are
    /// full `.store` files set aside on Start Fresh / restore; each can be restored via
    /// `BackupManager.restoreStoreFile(at:)`. Returns [] if the folder doesn't exist.
    /// Lists stores in the Quarantine folder next to `storeURL`, newest first. Returns []
    /// if the folder doesn't exist. Openability isn't checked here — it's probed lazily
    /// with `canOpen` only for the ONE store the user selects to restore, so the recovery
    /// screen doesn't trial-open a whole folder up front.
    nonisolated static func quarantinedStores(storeURL: URL) -> [QuarantinedStore] {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
            .appending(component: "Quarantine", directoryHint: .isDirectory)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        return entries
            .filter { $0.pathExtension == "store" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return QuarantinedStore(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
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
