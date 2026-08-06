import SwiftUI
import SwiftData

/// A cross-project list of tasks with reminders, grouped by when they're due
/// (Overdue / Today / Tomorrow / This week / Later). A companion to Report — Report looks
/// back at what you finished, Upcoming looks ahead at what you'll be nudged about. Derived
/// from existing `reminderDate`; no new data stored.
struct UpcomingView: View {
    @Query private var projects: [Project]
    @Environment(TaskStore.self) private var taskStore
    @Environment(ReminderManager.self) private var reminderManager
    @Environment(\.appAccent) private var appAccent
    @Binding var selection: SidebarSelection?

    /// Incomplete tasks (roots + subtasks) that have a reminder set.
    private var facts: [ReminderFacts] {
        projects.flatMap { project in
            project.tasks.compactMap { task -> ReminderFacts? in
                guard !task.isDone, let date = task.reminderDate else { return nil }
                return ReminderFacts(id: task.id, title: task.plainTitle,
                                     projectTitle: project.title, reminderDate: date)
            }
        }
    }

    private var sections: [UpcomingSection] {
        UpcomingBuilder.build(facts: facts, now: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let groups = sections
                if groups.isEmpty {
                    ContentUnavailableView("No upcoming reminders", systemImage: "bell.slash",
                                           description: Text("Set a reminder on a task and it'll show up here."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groups) { section in
                            sectionCard(section)
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Upcoming")
        }
    }

    private func sectionCard(_ section: UpcomingSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.bucket.title)
                    .font(.headline)
                    .foregroundStyle(section.bucket == .overdue ? .red : .primary)
                Spacer()
                Text("\(section.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(section.items) { item in
                    UpcomingRow(item: item, overdue: section.bucket == .overdue,
                                onComplete: { complete(item) },
                                onClear: { clearReminder(item) })
                    if item.id != section.items.last?.id { Divider() }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        )
    }

    // MARK: Actions

    private func task(for item: UpcomingItem) -> Task? {
        projects.lazy.flatMap(\.tasks).first { $0.id == item.id }
    }

    private func complete(_ item: UpcomingItem) {
        guard let t = task(for: item) else { return }
        withAnimation(.spring(duration: 0.25)) {
            taskStore.completeTask(t)      // completing clears the reminder in the store
        }
        reminderManager.cancel(taskID: item.id)
    }

    private func clearReminder(_ item: UpcomingItem) {
        guard let t = task(for: item) else { return }
        withAnimation { t.reminderDate = nil }
        reminderManager.cancel(taskID: item.id)
        taskStore.save()
    }
}

// MARK: - Row

private struct UpcomingRow: View {
    let item: UpcomingItem
    let overdue: Bool
    let onComplete: () -> Void
    let onClear: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Mark done")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                Text(item.projectTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Text(relativeDate)
                .font(.caption.monospacedDigit())
                .foregroundStyle(overdue ? .red : .secondary)

            // Clear-reminder button appears on hover so the row isn't cluttered at rest.
            Button(action: onClear) {
                Image(systemName: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .help("Remove reminder")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    /// Compact date: time only if it's today, otherwise abbreviated date + time.
    private var relativeDate: String {
        if Calendar.current.isDateInToday(item.date) {
            return item.date.formatted(date: .omitted, time: .shortened)
        }
        return item.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
