import Testing
import Foundation
@testable import Quillpoint

/// Unit tests for the Upcoming view's pure time-bucketing. No SwiftData — feeds
/// ReminderFacts directly and pins `now` so the buckets are deterministic.
struct UpcomingBuilderTests {

    private let cal = Calendar(identifier: .gregorian)

    // Fixed "now": Wed Jun 3 2026, 12:00.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12))! }

    private func at(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }
    private func fact(_ title: String, _ date: Date, project: String = "A") -> ReminderFacts {
        ReminderFacts(id: UUID(), title: title, projectTitle: project, reminderDate: date)
    }

    @Test func bucketsByRelativeTime() {
        let facts = [
            fact("Past",     at(6, 2, 9)),          // yesterday → Overdue
            fact("EarlierToday", at(6, 3, 9)),      // today 9am, before now(12) → Overdue
            fact("LaterToday",   at(6, 3, 18)),     // today 6pm → Today
            fact("Tmrw",     at(6, 4, 10)),         // tomorrow → Tomorrow
            fact("Weekend",  at(6, 6, 10)),         // +3 days → This week
            fact("FarOff",   at(6, 20, 10)),        // +17 days → Later
        ]
        let sections = UpcomingBuilder.build(facts: facts, now: now, calendar: cal)
        let byBucket = Dictionary(uniqueKeysWithValues: sections.map { ($0.bucket, $0.items.map(\.title)) })

        #expect(byBucket[.overdue]?.sorted() == ["EarlierToday", "Past"])
        #expect(byBucket[.today] == ["LaterToday"])
        #expect(byBucket[.tomorrow] == ["Tmrw"])
        #expect(byBucket[.thisWeek] == ["Weekend"])
        #expect(byBucket[.later] == ["FarOff"])
    }

    @Test func sectionsOrderedAndSortedSoonestFirst() {
        let facts = [
            fact("B", at(6, 3, 20)),   // today, later
            fact("A", at(6, 3, 14)),   // today, sooner
            fact("Over", at(6, 1, 8)), // overdue
        ]
        let sections = UpcomingBuilder.build(facts: facts, now: now, calendar: cal)
        // Overdue section comes before Today (enum order).
        #expect(sections.map(\.bucket) == [.overdue, .today])
        // Within Today, sorted soonest first.
        #expect(sections.first { $0.bucket == .today }?.items.map(\.title) == ["A", "B"])
    }

    @Test func emptyBucketsOmitted() {
        let facts = [fact("Only", at(6, 20, 10))]  // Later only
        let sections = UpcomingBuilder.build(facts: facts, now: now, calendar: cal)
        #expect(sections.map(\.bucket) == [.later])
    }

    @Test func emptyTitleShowsUntitled() {
        let sections = UpcomingBuilder.build(facts: [fact("", at(6, 4, 9))], now: now, calendar: cal)
        #expect(sections.first?.items.first?.title == "Untitled")
    }

    @Test func noFactsNoSections() {
        #expect(UpcomingBuilder.build(facts: [], now: now, calendar: cal).isEmpty)
    }
}
