import Foundation

/// Which time bucket a reminder falls into, relative to "now". Ordered as displayed.
enum UpcomingBucket: Int, CaseIterable, Identifiable {
    case overdue, today, tomorrow, thisWeek, later
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue:  return "Overdue"
        case .today:    return "Today"
        case .tomorrow: return "Tomorrow"
        case .thisWeek: return "This week"
        case .later:    return "Later"
        }
    }
}

/// A minimal snapshot of a task with a reminder — decouples grouping from the @Model so
/// it's testable without a SwiftData store.
struct ReminderFacts {
    let id: UUID
    let title: String
    let projectTitle: String
    let reminderDate: Date
}

/// One reminder row in the Upcoming list.
struct UpcomingItem: Identifiable {
    let id: UUID
    let title: String
    let projectTitle: String
    let date: Date
}

/// A displayed section: a bucket and the reminders in it, soonest first.
struct UpcomingSection: Identifiable {
    let bucket: UpcomingBucket
    let items: [UpcomingItem]
    var id: Int { bucket.rawValue }
}

enum UpcomingBuilder {
    /// Groups reminder facts into time buckets relative to `now`, each sorted soonest
    /// first, with empty buckets omitted. Overdue = strictly before now; Today/Tomorrow =
    /// that calendar day; This week = within the next 7 days; Later = beyond.
    static func build(facts: [ReminderFacts], now: Date, calendar: Calendar = .current) -> [UpcomingSection] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let startOfDayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? now

        func bucket(for date: Date) -> UpcomingBucket {
            if date < now { return .overdue }
            if date < startOfTomorrow { return .today }
            if date < startOfDayAfter { return .tomorrow }
            if date < endOfWeek { return .thisWeek }
            return .later
        }

        var byBucket: [UpcomingBucket: [UpcomingItem]] = [:]
        for f in facts {
            let item = UpcomingItem(id: f.id, title: f.title.isEmpty ? "Untitled" : f.title,
                                    projectTitle: f.projectTitle, date: f.reminderDate)
            byBucket[bucket(for: f.reminderDate), default: []].append(item)
        }

        return UpcomingBucket.allCases.compactMap { b in
            guard let items = byBucket[b], !items.isEmpty else { return nil }
            return UpcomingSection(bucket: b, items: items.sorted { $0.date < $1.date })
        }
    }
}
