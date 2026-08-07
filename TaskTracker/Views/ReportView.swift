import SwiftUI
import SwiftData

/// A day-by-day log of task activity over a chosen date range: for each day, the tasks
/// created and the tasks completed that day. Derived entirely from existing
/// `createdAt` / `completedAt` — no new data is stored.
struct ReportView: View {
    @Query private var projects: [Project]
    @Environment(\.appAccent) private var appAccent

    @State private var range: ReportRange = .last30
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()

    /// The resolved interval for the active range (preset or custom).
    private var interval: DateInterval {
        if range == .custom {
            let cal = Calendar.current
            let start = cal.startOfDay(for: min(customStart, customEnd))
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customStart, customEnd))) ?? customEnd
            return DateInterval(start: start, end: end)
        }
        return range.interval(now: Date()) ?? DateInterval(start: customStart, end: customEnd)
    }

    /// Flattened task facts (roots + subtasks) for the log. `parentID` lets the builder nest
    /// each subtask under the parent it finished with.
    private var facts: [TaskFacts] {
        projects.flatMap { project in
            project.tasks.map { task in
                TaskFacts(id: task.id, title: task.plainTitle, createdAt: task.createdAt,
                          completedAt: task.completedAt, projectTitle: project.title,
                          parentID: task.parent?.id)
            }
        }
    }

    private var days: [DayLog] { ReportBuilder.build(facts: facts, interval: interval) }

    var body: some View {
        // Wrapped in a NavigationStack so the detail column has the same structure as the
        // task-list destinations (which each own a NavigationStack). Without it, switching
        // from a project with a task pushed onto ITS stack left that pushed task-detail
        // view lingering over the Report pane; a fresh empty stack here dismisses it, the
        // same way All Projects (AllTasksView, which has its own stack) already did.
        NavigationStack {
            reportContent
        }
    }

    private var reportContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                rangePicker

                let log = days
                if log.isEmpty {
                    // Center the empty state across the full content width, not within the
                    // leading-aligned column (which pushed it left of center).
                    ContentUnavailableView("No completed tasks in this range",
                                           systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else {
                    summaryCard(ReportBuilder.summarize(facts: facts, interval: interval))
                    ForEach(log) { day in
                        DaySection(day: day, tint: appAccent)
                    }
                }
            }
            // Cap the readable width but center the column in a wide window (the outer
            // frame does the centering; without it the capped block hugs the leading edge).
            .frame(maxWidth: 900)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Report")
    }

    // MARK: Range picker

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(ReportRange.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if range == .custom {
                HStack(spacing: 16) {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                }
                .datePickerStyle(.field)
                .font(.callout)
            } else {
                Text(intervalLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Summary card

    /// A compact stats strip above the day log — three headline numbers for the range.
    private func summaryCard(_ s: RangeSummary) -> some View {
        HStack(spacing: 0) {
            summaryStat("\(s.created)", "Created", tint: appAccent)
            Divider().frame(height: 34)
            summaryStat("\(s.completed)", "Completed", tint: .green)
            Divider().frame(height: 34)
            summaryStat("\(s.activeDays)", s.activeDays == 1 ? "Active day" : "Active days", tint: .secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        )
    }

    private func summaryStat(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint == .secondary ? .primary : tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var intervalLabel: String {
        if range == .allTime { return "All recorded activity" }
        let f = DateFormatter(); f.dateStyle = .medium
        // interval.end is exclusive; show the inclusive last day.
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "\(f.string(from: interval.start)) – \(f.string(from: lastDay))"
    }
}

// MARK: - Day section

private struct DaySection: View {
    let day: DayLog
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.day.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.headline)
                Spacer()
                Text("\(day.completed.count) completed")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            taskList(tasks: day.completed)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        )
    }

    private func taskList(tasks: [ReportTask]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tasks) { task in
                TaskRow(task: task)
            }
        }
    }
}

/// One completed task in a day's log. A task that finished alongside subtasks carries a
/// small inline chevron after its title; the subtasks stay hidden until it's clicked.
///
/// The chevron sits ON the title line rather than in a DisclosureGroup or its own row, so
/// a collapsed row is exactly as tall as a row with no subtasks — the log's height doesn't
/// change just because tasks happen to have children.
private struct TaskRow: View {
    let task: ReportTask
    @State private var isExpanded = false

    private var hasSubtasks: Bool { !task.subtasks.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] ?? $0[.bottom] }
                Text(task.title)
                    .font(.body)
                    .lineLimit(1)
                if hasSubtasks {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityLabel(isExpanded ? "Hide subtasks" : "Show subtasks")
                }
                Spacer(minLength: 8)
                Text(task.projectTitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasSubtasks else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            if hasSubtasks && isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(task.subtasks) { sub in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green.opacity(0.7))
                                .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] ?? $0[.bottom] }
                            Text(sub.title)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
    }
}
