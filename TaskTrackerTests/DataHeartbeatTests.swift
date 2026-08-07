import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// The heartbeat flags a store that opened meaningfully OLDER than the data the app last
/// saw — the detectable effect of the shared-store hazard (an old build or a restore
/// swapping in a stale store). Pure logic tests over Mark; no store needed.
@MainActor
struct DataHeartbeatTests {

    private func mark(_ count: Int, _ activity: TimeInterval) -> DataHeartbeat.Mark {
        DataHeartbeat.Mark(taskCount: count, latestActivity: activity)
    }

    @Test func regressionDetectedWhenActivityGoesBackward() {
        let last = mark(50, 800_000_000)          // what we last saw
        let now  = mark(50, 800_000_000 - 86_400) // a day older — a stale store
        #expect(DataHeartbeat.isRegressed(current: now, last: last))
    }

    @Test func noRegressionWhenStoreIsAtOrAheadOfLastSeen() {
        let last = mark(50, 800_000_000)
        #expect(!DataHeartbeat.isRegressed(current: mark(50, 800_000_000), last: last))
        #expect(!DataHeartbeat.isRegressed(current: mark(52, 800_000_100), last: last))
    }

    @Test func smallBackwardMoveWithinToleranceIsNotFlagged() {
        // Clock jitter / sub-hour noise must not false-positive.
        let last = mark(50, 800_000_000)
        let now  = mark(50, 800_000_000 - 60) // one minute behind
        #expect(!DataHeartbeat.isRegressed(current: now, last: last))
    }

    @Test func firstRunNeverRegresses() {
        // No prior activity to fall behind.
        let last = mark(0, 0)
        #expect(!DataHeartbeat.isRegressed(current: mark(10, 800_000_000), last: last))
    }

    @Test func checkAtLaunchRecordsForwardMarkAndDetectsRegression() {
        let defaults = UserDefaults(suiteName: "heartbeat-\(UUID().uuidString)")!
        // Seed a high-water mark.
        DataHeartbeat.record(mark(50, 800_000_000), defaults: defaults)

        // A stale store opens: fewer tasks, older activity.
        let stale = mark(40, 800_000_000 - 172_800) // two days behind
        #expect(DataHeartbeat.isRegressed(current: stale, last: DataHeartbeat.lastMark(defaults: defaults)!))

        // The recorded mark must not drift backward to the stale level.
        let baseline = DataHeartbeat.lastMark(defaults: defaults)!
        let kept = DataHeartbeat.Mark(
            taskCount: max(baseline.taskCount, stale.taskCount),
            latestActivity: max(baseline.latestActivity, stale.latestActivity))
        #expect(kept.latestActivity == 800_000_000)
    }

    /// A deliberate restore to an older backup must not put the app in a permanent
    /// "your data may be out of date" state.
    ///
    /// The mark only ever moves FORWARD (`max(baseline, current)`), and nothing resets it
    /// after a restore. So once a user intentionally restores an older backup, every
    /// subsequent launch keeps comparing the restored store against the pre-restore
    /// high-water mark and flags a regression — routing them to the recovery screen again
    /// and again for a state they chose. The warning is only useful if it clears once the
    /// user has acknowledged the new reality.
    @Test func restoringAnOlderBackupDoesNotWarnForever() throws {
        let defaults = UserDefaults(suiteName: "heartbeat-\(UUID().uuidString)")!
        let store = try TestStore(prefix: "Heartbeat")
        let ctx = store.context

        // Launch 1: the user has been working; a high-water mark gets recorded.
        let project = Project(title: "P")
        ctx.insert(project)
        for i in 0..<5 {
            let t = Task(plainTitle: "task \(i)", project: project)
            t.createdAt = Date()
            ctx.insert(t)
        }
        try ctx.save()
        #expect(DataHeartbeat.checkAtLaunch(context: ctx, defaults: defaults) == false)

        // The user deliberately restores an older backup: fewer tasks, all older activity.
        for t in try ctx.fetch(FetchDescriptor<Task>()) { ctx.delete(t) }
        let old = Task(plainTitle: "old", project: project)
        old.createdAt = Date().addingTimeInterval(-30 * 86_400) // a month back
        ctx.insert(old)
        try ctx.save()

        // Launch 2: flagging here is CORRECT — the app can't know the restore was intended.
        #expect(DataHeartbeat.checkAtLaunch(context: ctx, defaults: defaults),
                "the first launch after a restore legitimately warns")

        // Launch 3: nothing has changed since the user saw and accepted that warning.
        // Warning again — and on every launch after — is the bug.
        #expect(DataHeartbeat.checkAtLaunch(context: ctx, defaults: defaults) == false,
                "a warning already shown must not repeat every launch for the same state")
    }

    /// Settling the baseline after a regression must not disarm the guard: a store that
    /// falls behind AGAIN is a new event and has to warn again. Otherwise the fix for the
    /// sticky warning would silently trade away the protection it exists for.
    @Test func aFurtherRegressionStillWarnsAfterTheFirstOneSettles() throws {
        let defaults = UserDefaults(suiteName: "heartbeat-\(UUID().uuidString)")!
        let store = try TestStore(prefix: "HeartbeatAgain")
        let ctx = store.context
        let project = Project(title: "P")
        ctx.insert(project)

        func setActivity(_ daysAgo: TimeInterval) throws {
            for t in try ctx.fetch(FetchDescriptor<Task>()) { ctx.delete(t) }
            let t = Task(plainTitle: "t", project: project)
            t.createdAt = Date().addingTimeInterval(-daysAgo * 86_400)
            ctx.insert(t)
            try ctx.save()
        }

        // Establish a recent high-water mark.
        try setActivity(0)
        #expect(DataHeartbeat.checkAtLaunch(context: ctx, defaults: defaults) == false)

        // First regression: a month back. Warns, then settles.
        try setActivity(30)
        #expect(DataHeartbeat.checkAtLaunch(context: ctx, defaults: defaults), "first regression warns")
        #expect(DataHeartbeat.checkAtLaunch(context: ctx, defaults: defaults) == false, "then settles")

        // A SECOND, deeper regression is a new event — it must warn again.
        try setActivity(90)
        #expect(DataHeartbeat.checkAtLaunch(context: ctx, defaults: defaults),
                "a further backward jump is a new regression and must still warn")
    }
}
