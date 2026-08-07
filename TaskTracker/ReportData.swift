import Foundation

/// A preset span for the report's date range, plus a custom option.
enum ReportRange: String, CaseIterable, Identifiable {
    case last7   = "Last 7 days"
    case last30  = "Last 30 days"
    case thisMonth = "This month"
    case allTime = "All time"
    case custom  = "Custom"

    var id: String { rawValue }

    /// Resolves the preset to a concrete [start, end) interval relative to `now`. `end` is
    /// exclusive (start of the day after the last day). Custom returns nil (the caller
    /// supplies the dates); `allTime` uses a distant past so every task falls inside it.
    func interval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        switch self {
        case .last7:
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
            return DateInterval(start: start, end: endOfToday)
        case .last30:
            let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
            return DateInterval(start: start, end: endOfToday)
        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: comps) ?? now
            return DateInterval(start: start, end: endOfToday)
        case .allTime:
            return DateInterval(start: Date(timeIntervalSince1970: 0), end: endOfToday)
        case .custom:
            return nil
        }
    }
}

/// A minimal snapshot of a task for the report — decouples the log from the @Model so it's
/// testable without a SwiftData store. `projectTitle` is captured up front.
struct TaskFacts {
    let id: UUID
    let title: String
    let createdAt: Date
    let completedAt: Date?
    let projectTitle: String
    /// The parent task's id for a subtask; nil for a root/standalone task.
    let parentID: UUID?

    var isSubtask: Bool { parentID != nil }
}

/// One task line in a day's completed list. Subtasks are never their own line — they
/// hang off their parent in `subtasks`, shown by an expander that starts collapsed.
struct ReportTask: Identifiable {
    let id: UUID
    let title: String
    let projectTitle: String
    /// Subtasks of this task that completed on the same day. Empty for a task with no
    /// subtasks, and for every subtask (nesting is one level, matching the data model).
    let subtasks: [ReportTask]
}

/// A single day's completed tasks. Only days with a completion appear in the log.
struct DayLog: Identifiable {
    let day: Date               // start-of-day
    let completed: [ReportTask] // tasks completed this day
    var id: Date { day }
}

/// A compact set of headline numbers for the range, shown above the day-by-day log.
/// `created` is kept as a stat even though the log itself lists only completions.
struct RangeSummary {
    let created: Int
    let completed: Int
    let activeDays: Int   // days with at least one completion
}

enum ReportBuilder {
    /// Headline numbers for the range: how many tasks were created and completed, and how
    /// many days had a completion. `facts`/`interval` are the same inputs as `build`.
    /// When `includeSubtasks` is false, subtasks are excluded from every count so the
    /// summary matches the parent-only log.
    static func summarize(facts: [TaskFacts], interval: DateInterval) -> RangeSummary {
        // Counts cover root tasks only, matching the log's top-level rows — subtasks are
        // detail nested under a parent, not separate items worth counting.
        let facts = facts.filter { !$0.isSubtask }
        func inRange(_ d: Date?) -> Bool { d.map { interval.contains($0) } ?? false }
        let created = facts.filter { inRange($0.createdAt) }.count
        let completedFacts = facts.filter { inRange($0.completedAt) }
        let days = Set(completedFacts.compactMap { $0.completedAt.map(Calendar.current.startOfDay) })
        return RangeSummary(created: created, completed: completedFacts.count, activeDays: days.count)
    }

    /// Builds the day-by-day log of COMPLETED tasks over `facts` within `interval`, newest
    /// day first. Days with no completion are omitted.
    ///
    /// Only root tasks become rows. A subtask is never listed on its own — it's nested
    /// under its parent, revealed by an expander that starts collapsed, and only when the
    /// parent completed on that same day. Because a parent completes exactly when its LAST
    /// subtask does, subtasks finished on earlier days have no completed parent to sit
    /// under on those days and are deliberately not shown then; they appear with the
    /// parent on the day the whole thing was finished.
    static func build(facts: [TaskFacts], interval: DateInterval,
                      calendar: Calendar = .current) -> [DayLog] {
        func inRange(_ d: Date?) -> Bool { d.map { interval.contains($0) } ?? false }
        func line(_ f: TaskFacts, subtasks: [ReportTask] = []) -> ReportTask {
            ReportTask(id: f.id, title: f.title.isEmpty ? "Untitled" : f.title,
                       projectTitle: f.projectTitle, subtasks: subtasks)
        }

        // Subtasks bucketed by parent and completion day, so a parent row can pick up the
        // children that finished alongside it.
        var subtasksByParentDay: [UUID: [Date: [TaskFacts]]] = [:]
        for f in facts where f.isSubtask {
            guard let parentID = f.parentID, let done = f.completedAt, inRange(done) else { continue }
            subtasksByParentDay[parentID, default: [:]][calendar.startOfDay(for: done), default: []].append(f)
        }

        var completedByDay: [Date: [ReportTask]] = [:]
        for f in facts where !f.isSubtask {
            guard let done = f.completedAt, inRange(done) else { continue }
            let day = calendar.startOfDay(for: done)
            let children = (subtasksByParentDay[f.id]?[day] ?? [])
                .map { line($0) }
                .sorted { $0.title < $1.title }
            completedByDay[day, default: []].append(line(f, subtasks: children))
        }

        return completedByDay.keys.sorted(by: >).map { day in
            DayLog(day: day, completed: (completedByDay[day] ?? []).sorted { $0.title < $1.title })
        }
    }
}
