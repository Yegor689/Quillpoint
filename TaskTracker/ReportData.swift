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
}

/// One task line in a day's created/completed list.
struct ReportTask: Identifiable {
    let id: UUID
    let title: String
    let projectTitle: String
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
    static func summarize(facts: [TaskFacts], interval: DateInterval) -> RangeSummary {
        func inRange(_ d: Date?) -> Bool { d.map { interval.contains($0) } ?? false }
        let created = facts.filter { inRange($0.createdAt) }.count
        let completedFacts = facts.filter { inRange($0.completedAt) }
        let days = Set(completedFacts.compactMap { $0.completedAt.map(Calendar.current.startOfDay) })
        return RangeSummary(created: created, completed: completedFacts.count, activeDays: days.count)
    }

    /// Builds the day-by-day log of COMPLETED tasks over `facts` within `interval`, newest
    /// day first. A task appears under the day its `completedAt` falls on. Days with no
    /// completion are omitted.
    static func build(facts: [TaskFacts], interval: DateInterval,
                      calendar: Calendar = .current) -> [DayLog] {
        func inRange(_ d: Date?) -> Bool { d.map { interval.contains($0) } ?? false }
        func line(_ f: TaskFacts) -> ReportTask {
            ReportTask(id: f.id, title: f.title.isEmpty ? "Untitled" : f.title, projectTitle: f.projectTitle)
        }

        var completedByDay: [Date: [ReportTask]] = [:]
        for f in facts {
            if let done = f.completedAt, inRange(done) {
                completedByDay[calendar.startOfDay(for: done), default: []].append(line(f))
            }
        }

        return completedByDay.keys.sorted(by: >).map { day in
            DayLog(day: day, completed: (completedByDay[day] ?? []).sorted { $0.title < $1.title })
        }
    }
}
