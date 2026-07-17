import Foundation
import SQLite3

/// A content fingerprint of a Quillpoint `.store` file, read directly from SQLite
/// WITHOUT opening it through SwiftData. It answers "what data is actually in here?" —
/// task count and the latest moment any task was created or completed — so the backup
/// system can reason about content instead of only filenames and timestamps.
///
/// This is the fix for the subsystem's original flaw: backups were managed by write
/// time and filename, blind to whether two backups held the same data. With a
/// fingerprint the system can skip unchanged auto-backups, prune duplicates, and show
/// a backup's real content age instead of its (possibly misleading) write date.
struct StoreFingerprint: Equatable {
    /// Number of tasks in the store.
    let taskCount: Int
    /// Latest of any task's created/completed time, as seconds since the reference date;
    /// 0 when the store has no tasks. This is the store's content "high-water mark".
    let latestActivity: TimeInterval

    /// Two stores are treated as holding equivalent data when both the count and the
    /// high-water mark match. This is a practical "did anything change?" signal, not a
    /// cryptographic identity: a false match (same count and same newest date but a
    /// different edit in between) can at worst cause the auto-backup skip to miss ONE
    /// snapshot — bounded and harmless. Kept deliberately simple.
    static func == (lhs: StoreFingerprint, rhs: StoreFingerprint) -> Bool {
        lhs.taskCount == rhs.taskCount && lhs.latestActivity == rhs.latestActivity
    }

    /// The content date, if the store has any tasks — for display ("newest task …").
    var latestActivityDate: Date? {
        latestActivity > 0 ? Date(timeIntervalSinceReferenceDate: latestActivity) : nil
    }

    /// Computes the fingerprint from live `Task` models (the open context's current state),
    /// matching `read`'s SQL so a live fingerprint compares correctly against a backup file.
    static func fromTasks(_ tasks: [Task]) -> StoreFingerprint {
        let latest = tasks.reduce(0.0) { acc, t in
            max(acc, max(t.createdAt.timeIntervalSinceReferenceDate,
                         t.completedAt?.timeIntervalSinceReferenceDate ?? 0))
        }
        return StoreFingerprint(taskCount: tasks.count, latestActivity: latest)
    }

    /// Reads the fingerprint from a `.store` file on disk. Returns nil if the file can't
    /// be opened or lacks the expected schema (e.g. a corrupt or non-Quillpoint store) —
    /// callers treat nil as "unknown", never as "empty", so a read failure can't be
    /// mistaken for a legitimately empty store.
    static func read(from url: URL) -> StoreFingerprint? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // ZTASK is Core Data's table for the Task entity; ZCREATEDAT / ZCOMPLETEDAT are
        // its date columns (Core Data reference-date epoch — same units as latestActivity).
        // The checksum sums a per-row hash over the mutable columns so an edit that leaves
        // count and dates unchanged still changes the fingerprint. total_changes()-style
        // precision isn't needed; SUM over hashes is order-independent and cheap.
        // ZTASK is Core Data's table for the Task entity; ZCREATEDAT / ZCOMPLETEDAT are
        // its date columns (Core Data reference-date epoch — same units as latestActivity).
        let sql = "SELECT COUNT(*), COALESCE(MAX(MAX(COALESCE(ZCREATEDAT,0), COALESCE(ZCOMPLETEDAT,0))),0) FROM ZTASK;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_int64(stmt, 0))
        let latest = sqlite3_column_double(stmt, 1)
        return StoreFingerprint(taskCount: count, latestActivity: latest)
    }
}
