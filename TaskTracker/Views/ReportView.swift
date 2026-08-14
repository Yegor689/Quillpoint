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
    @State private var path = NavigationPath()

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

    /// The report is built from `TaskFacts` value types, not the models themselves, so a
    /// row only knows its task's `id`. Resolve it back through the same `projects` query
    /// the report was built from — a row whose task has since been deleted simply won't
    /// open, rather than pushing a dangling detail view.
    private func task(withID id: UUID) -> Task? {
        for project in projects {
            if let match = project.tasks.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    var body: some View {
        // Wrapped in a NavigationStack so the detail column has the same structure as the
        // task-list destinations (which each own a NavigationStack). Without it, switching
        // from a project with a task pushed onto ITS stack left that pushed task-detail
        // view lingering over the Report pane; a fresh empty stack here dismisses it, the
        // same way All Projects (AllTasksView, which has its own stack) already did.
        NavigationStack(path: $path) {
            reportContent
                .navigationDestination(for: Task.self) { task in
                    TaskDetailView(task: task)
                }
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
                        DaySection(day: day, tint: appAccent) { id in
                            if let task = task(withID: id) { path.append(task) }
                        }
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
    let open: (UUID) -> Void

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
                TaskRow(task: task, open: open)
            }
        }
    }
}

/// One completed task in a day's log. Double-clicking a row opens that task's detail view,
/// matching the task list and All Projects — the back button returns to the report.
///
/// A task that finished alongside subtasks carries a small inline chevron after its title.
/// The chevron is its own click target rather than the whole row: the row's click belongs
/// to opening the task, so expanding has to be a deliberate hit on the disclosure control.
///
/// The chevron sits ON the title line rather than in a DisclosureGroup or its own row, so
/// a collapsed row is exactly as tall as a row with no subtasks — the log's height doesn't
/// change just because tasks happen to have children.
private struct TaskRow: View {
    let task: ReportTask
    let open: (UUID) -> Void
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
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide subtasks" : "Show subtasks")
                    .accessibilityLabel(isExpanded ? "Hide subtasks" : "Show subtasks")
                }
                Spacer(minLength: 8)
                Text(task.projectTitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(task.id) }

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
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(sub.id) }
                    }
                }
                .padding(.leading, 24)
            }
        }
    }
}
