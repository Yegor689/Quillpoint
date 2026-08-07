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
    /// Total byte length of every task's title+notes RTF, plus the sum of the mutable
    /// scalar columns. Count and latestActivity alone are blind to edits that neither add
    /// a task nor complete one — retitling or rewriting notes, reprioritising, reordering.
    /// A whole session spent editing text used to look "unchanged", so the auto-backup
    /// skipped for as long as the editing continued and none of that work was captured.
    let contentSize: Int

    /// Two stores are treated as holding equivalent data when the count, the high-water
    /// mark, and the content size all match. This is a practical "did anything change?"
    /// signal, not a cryptographic identity: a false match (an edit that preserves every
    /// one of those, e.g. swapping two characters in a title) can at worst cause the
    /// auto-backup skip to miss ONE snapshot. Kept deliberately cheap.
    static func == (lhs: StoreFingerprint, rhs: StoreFingerprint) -> Bool {
        lhs.taskCount == rhs.taskCount
            && lhs.latestActivity == rhs.latestActivity
            && lhs.contentSize == rhs.contentSize
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
        // Must match `read`'s SQL term-for-term: RTF byte lengths plus the mutable
        // scalars. `liveAndFileFingerprintsAgree` enforces that the two stay in step.
        let size = tasks.reduce(0) { acc, t in
            acc + t.titleRTF.count + t.descRTF.count
                + (t.isDone ? 1 : 0) + t.priority + t.sortIndex
        }
        return StoreFingerprint(taskCount: tasks.count, latestActivity: latest, contentSize: size)
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

        // ZTASK is Core Data's table for the Task entity; ZCREATEDAT / ZCOMPLETEDAT are its
        // date columns (Core Data reference-date epoch — same units as latestActivity).
        // The third term is contentSize: RTF byte lengths plus the mutable scalars, so a
        // text edit (which changes neither count nor dates) still moves the fingerprint.
        // It must match `fromTasks` term-for-term — `liveAndFileFingerprintsAgree` checks it.
        let sql = """
        SELECT COUNT(*),
               COALESCE(MAX(MAX(COALESCE(ZCREATEDAT,0), COALESCE(ZCOMPLETEDAT,0))),0),
               COALESCE(SUM(COALESCE(LENGTH(CAST(ZTITLERTF AS BLOB)),0)
                          + COALESCE(LENGTH(CAST(ZDESCRTF AS BLOB)),0)
                          + COALESCE(ZISDONE,0) + COALESCE(ZPRIORITY,0)
                          + COALESCE(ZSORTINDEX,0)),0)
        FROM ZTASK;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_int64(stmt, 0))
        let latest = sqlite3_column_double(stmt, 1)
        let size = Int(sqlite3_column_int64(stmt, 2))
        return StoreFingerprint(taskCount: count, latestActivity: latest, contentSize: size)
    }
}
