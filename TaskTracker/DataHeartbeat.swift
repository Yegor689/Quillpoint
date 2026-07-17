import Foundation
import SwiftData

/// Detects when the store the app just opened is meaningfully OLDER than the data the
/// app last saw — the fingerprint of the shared-store hazard, where another build (or a
/// restore/downgrade) silently swapped the live store for a stale one. The app can't
/// prevent an older build from stomping the shared store (that build predates any guard
/// we ship), but it CAN notice the effect on the next launch and warn the user while the
/// diverged data may still be recoverable, instead of the loss surfacing days later.
///
/// The mark lives in `UserDefaults`, NOT in the store — so it survives exactly the store
/// swaps/restores we're trying to detect. It records the high-water mark of real task
/// activity we've legitimately seen; a launch whose store falls well behind that mark is
/// flagged.
enum DataHeartbeat {

    /// A snapshot of "how far along" the data was: how many tasks, and the latest moment
    /// any task was created or completed. Monotonic in normal use — it only moves forward
    /// as the user works. A launch where it moves BACKWARD means the store regressed.
    struct Mark: Codable, Equatable {
        var taskCount: Int
        /// Latest of any task's createdAt/completedAt, as a time interval; 0 if no tasks.
        var latestActivity: TimeInterval
    }

    private static let key = "dataHeartbeatMark"

    /// Tolerance for a backward move in `latestActivity` before we treat it as a
    /// regression. Small clock jitter or a same-session no-op shouldn't trip it; a real
    /// downgrade loses hours or days. One hour is comfortably above noise, well below the
    /// smallest loss worth warning about.
    private static let regressionTolerance: TimeInterval = 3600

    /// Computes the current store's mark. Read-only; never throws (a failed fetch yields
    /// an empty mark, which won't false-positive a regression).
    @MainActor
    static func currentMark(in context: ModelContext) -> Mark {
        let tasks = (try? context.fetch(FetchDescriptor<Task>())) ?? []
        let latest = tasks.reduce(0.0) { acc, t in
            let created = t.createdAt.timeIntervalSinceReferenceDate
            let done = t.completedAt?.timeIntervalSinceReferenceDate ?? 0
            return max(acc, max(created, done))
        }
        return Mark(taskCount: tasks.count, latestActivity: latest)
    }

    static func lastMark(defaults: UserDefaults = .standard) -> Mark? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Mark.self, from: data)
    }

    static func record(_ mark: Mark, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(mark) else { return }
        defaults.set(data, forKey: key)
    }

    /// True when `current` has regressed relative to `last` in a way that indicates the
    /// store was replaced by an older one: its latest activity is more than the tolerance
    /// BEHIND what we last saw. A drop in task count alone isn't enough (the user may have
    /// legitimately deleted tasks), and neither is an empty store on first run (no `last`).
    static func isRegressed(current: Mark, last: Mark) -> Bool {
        // No prior activity to fall behind, or the store is at/ahead of what we saw.
        guard last.latestActivity > 0 else { return false }
        return current.latestActivity < last.latestActivity - regressionTolerance
    }

    /// The launch-time check: compares the opened store to the last recorded mark and
    /// returns whether it regressed. Regardless of the result, it records the HIGHER of
    /// the two marks so the heartbeat always tracks the newest reality the app has seen —
    /// and so a user who dismisses the warning and keeps working isn't nagged every launch
    /// for the same regression (their new work advances the mark again).
    @MainActor
    @discardableResult
    static func checkAtLaunch(context: ModelContext, defaults: UserDefaults = .standard) -> Bool {
        let current = currentMark(in: context)
        let last = lastMark(defaults: defaults)

        let regressed = last.map { isRegressed(current: current, last: $0) } ?? false

        // Keep the mark at the furthest-forward point seen, so the baseline never drifts
        // backward to the stale store's level.
        let baseline = last ?? current
        let kept = Mark(
            taskCount: max(baseline.taskCount, current.taskCount),
            latestActivity: max(baseline.latestActivity, current.latestActivity))
        record(kept, defaults: defaults)

        return regressed
    }
}
