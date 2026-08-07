import Testing
import Foundation
@testable import Quillpoint

/// Unit tests for the report's pure day-by-day log of COMPLETED tasks, plus the summary
/// rollup. No SwiftData — feeds TaskFacts directly.
struct ReportBuilderTests {

    private let cal = Calendar(identifier: .gregorian)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private func startOfDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func fact(_ title: String, created: Date, completed: Date? = nil,
                      project: String = "A", id: UUID = UUID(),
                      parentID: UUID? = nil) -> TaskFacts {
        TaskFacts(id: id, title: title, createdAt: created, completedAt: completed,
                  projectTitle: project, parentID: parentID)
    }

    /// Jun 1–10 inclusive: [Jun 1 00:00, Jun 11 00:00).
    private var june: DateInterval {
        DateInterval(start: startOfDay(2026, 6, 1), end: startOfDay(2026, 6, 11))
    }

    @Test func logsCompletedTasksByDayNewestFirst() {
        let facts = [
            fact("Alpha", created: day(2026, 6, 2), completed: day(2026, 6, 2)),
            fact("Beta",  created: day(2026, 6, 2)),                                // open → not in log
            fact("Gamma", created: day(2026, 5, 20), completed: day(2026, 6, 5)),  // completed Jun 5
            fact("Delta", created: day(2026, 6, 5), completed: day(2026, 6, 5)),   // completed Jun 5
        ]
        let log = ReportBuilder.build(facts: facts, interval: june, calendar: cal)

        // Two days with completions, newest first: Jun 5 then Jun 2.
        #expect(log.map { cal.component(.day, from: $0.day) } == [5, 2])
        #expect(log.first { cal.component(.day, from: $0.day) == 2 }?.completed.map(\.title) == ["Alpha"])
        // Jun 5: Delta + Gamma, title-sorted.
        #expect(log.first { cal.component(.day, from: $0.day) == 5 }?.completed.map(\.title) == ["Delta", "Gamma"])
    }

    @Test func completedOnItsCompletionDayNotCreationDay() {
        // Created Jun 3, completed Jun 7 → appears only under Jun 7.
        let facts = [fact("Split", created: day(2026, 6, 3), completed: day(2026, 6, 7))]
        let log = ReportBuilder.build(facts: facts, interval: june, calendar: cal)
        #expect(log.count == 1)
        #expect(cal.component(.day, from: log[0].day) == 7)
        #expect(log[0].completed.map(\.title) == ["Split"])
    }

    @Test func omitsCompletionsOutsideRange() {
        let facts = [
            fact("Inside", created: day(2026, 6, 4), completed: day(2026, 6, 4)),
            fact("Before", created: day(2026, 1, 1), completed: day(2026, 1, 2)),
            fact("Open",   created: day(2026, 6, 4)),
        ]
        let log = ReportBuilder.build(facts: facts, interval: june, calendar: cal)
        #expect(log.count == 1)
        #expect(log[0].completed.map(\.title) == ["Inside"])
    }

    @Test func emptyTitleShowsUntitled() {
        let facts = [fact("", created: day(2026, 6, 2), completed: day(2026, 6, 2))]
        let log = ReportBuilder.build(facts: facts, interval: june, calendar: cal)
        #expect(log.first?.completed.first?.title == "Untitled")
    }

    @Test func emptyWhenNoCompletionsInRange() {
        // A task created in range but never completed produces an empty log.
        let log = ReportBuilder.build(facts: [fact("Open", created: day(2026, 6, 3))],
                                      interval: june, calendar: cal)
        #expect(log.isEmpty)
    }

    /// Subtasks are never their own row — they nest under the parent they finished with,
    /// so the log's top level stays one line per real task.
    @Test func subtasksNestUnderTheirParentInsteadOfListingFlat() {
        let parentID = UUID()
        let facts = [
            fact("Parent",  created: day(2026, 6, 2), completed: day(2026, 6, 2), id: parentID),
            fact("Child B", created: day(2026, 6, 2), completed: day(2026, 6, 2), parentID: parentID),
            fact("Child A", created: day(2026, 6, 2), completed: day(2026, 6, 2), parentID: parentID),
        ]
        let log = ReportBuilder.build(facts: facts, interval: june, calendar: cal)

        // One top-level row, not three.
        #expect(log.first?.completed.map(\.title) == ["Parent"])
        // Both children hang off it, title-sorted.
        #expect(log.first?.completed.first?.subtasks.map(\.title) == ["Child A", "Child B"])
    }

    /// A parent completes exactly when its LAST subtask does, so subtasks finished on
    /// earlier days have no completed parent to sit under. Those days show nothing rather
    /// than orphan rows; the work appears with the parent on the day it was all finished.
    @Test func subtasksFinishedBeforeTheirParentAreNotShownOnThoseDays() {
        let parentID = UUID()
        let facts = [
            // Parent completes Jun 5, along with its final subtask.
            fact("Parent", created: day(2026, 6, 1), completed: day(2026, 6, 5), id: parentID),
            fact("Late",   created: day(2026, 6, 1), completed: day(2026, 6, 5), parentID: parentID),
            // This one finished Jun 2, while the parent was still open.
            fact("Early",  created: day(2026, 6, 1), completed: day(2026, 6, 2), parentID: parentID),
        ]
        let log = ReportBuilder.build(facts: facts, interval: june, calendar: cal)

        // Only Jun 5 has a day entry — Jun 2's lone subtask doesn't create one.
        #expect(log.map { cal.component(.day, from: $0.day) } == [5])
        #expect(log.first?.completed.map(\.title) == ["Parent"])
        #expect(log.first?.completed.first?.subtasks.map(\.title) == ["Late"],
                "only the subtask that finished with the parent nests under it")
    }

    /// A task with no subtasks carries an empty `subtasks`, so the view shows no expander
    /// and the row keeps its normal height.
    @Test func taskWithoutSubtasksHasNoNestedChildren() {
        let log = ReportBuilder.build(
            facts: [fact("Solo", created: day(2026, 6, 2), completed: day(2026, 6, 2))],
            interval: june, calendar: cal)
        #expect(log.first?.completed.first?.subtasks.isEmpty == true)
    }

    /// Summary counts follow the log's top level: subtasks are detail, not separate items.
    @Test func summaryCountsRootTasksOnly() {
        let parentID = UUID()
        let facts = [
            fact("Parent", created: day(2026, 6, 2), completed: day(2026, 6, 3), id: parentID),
            fact("Child",  created: day(2026, 6, 2), completed: day(2026, 6, 3), parentID: parentID),
        ]
        let s = ReportBuilder.summarize(facts: facts, interval: june)
        #expect(s.created == 1, "only the parent counts")
        #expect(s.completed == 1, "only the parent counts")
        #expect(s.activeDays == 1)
    }

    @Test func summaryCountsCreatedCompletedAndActiveDays() {
        let facts = [
            fact("Alpha", created: day(2026, 6, 2), completed: day(2026, 6, 2)),
            fact("Beta",  created: day(2026, 6, 2)),                                // created only
            fact("Gamma", created: day(2026, 5, 20), completed: day(2026, 6, 5)),  // completed only
        ]
        let s = ReportBuilder.summarize(facts: facts, interval: june)
        #expect(s.created == 2, "Alpha + Beta created in range")
        #expect(s.completed == 2, "Alpha + Gamma completed in range")
        #expect(s.activeDays == 2, "completions on Jun 2 and Jun 5")
    }
}
