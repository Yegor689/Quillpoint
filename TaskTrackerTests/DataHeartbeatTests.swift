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
}
