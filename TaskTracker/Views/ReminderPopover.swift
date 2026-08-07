import SwiftUI

struct ReminderPopover: View {
    @Bindable var task: Task
    var reminderManager: ReminderManager

    @State private var pickedDate: Date = defaultDate()
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    private static func defaultDate() -> Date {
        Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    }

    /// Quick-set presets. Each returns a concrete fire date from `now`, or nil if it
    /// doesn't make sense right now (e.g. "This evening" once it's already past 6pm).
    private enum Preset: String, CaseIterable, Identifiable {
        case oneHour = "In 1 hour"
        case evening = "This evening"
        case tomorrow = "Tomorrow 9 AM"
        case nextWeek = "Next week"
        var id: String { rawValue }

        /// Label for the preset pills.
        var short: String {
            switch self {
            case .oneHour:  return "1 hour"
            case .evening:  return "Tonight"
            case .tomorrow: return "Tomorrow"
            case .nextWeek: return "Next week"
            }
        }

        /// `hour` is the user's chosen time-of-day for day-based presets ("Tomorrow",
        /// "Next week"); "In 1 hour" and "This evening" ignore it.
        func date(from now: Date, hour: Int = 9, calendar: Calendar = .current) -> Date? {
            switch self {
            case .oneHour:
                return calendar.date(byAdding: .hour, value: 1, to: now)
            case .evening:
                let six = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
                return (six.map { $0 > now } == true) ? six : nil   // only if 6pm is still ahead
            case .tomorrow:
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
                return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)
            case .nextWeek:
                let wk = calendar.date(byAdding: .day, value: 7, to: now) ?? now
                return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: wk)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Reminder")
                .font(.headline)

            // Quick presets — subtle pills; tapping one sets the picker (still editable).
            let now = Date()
            let available = Preset.allCases.compactMap { p in
                p.date(from: now, hour: settings.reminderHour).map { (p, $0) }
            }
            HStack(spacing: 6) {
                ForEach(available, id: \.0) { preset, date in
                    PresetPill(label: preset.short, selected: isSelected(date)) { pickedDate = date }
                }
                Spacer(minLength: 0)
            }

            DatePicker("", selection: $pickedDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if task.reminderDate != nil {
                    Button("Remove") {
                        task.reminderDate = nil
                        reminderManager.cancel(taskID: task.id)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    task.reminderDate = pickedDate
                    reminderManager.schedule(task: task)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            // Existing reminder → edit it. Otherwise seed from the user's default preset
            // (Settings), falling back to one hour out.
            if let existing = task.reminderDate {
                pickedDate = existing
            } else if let preset = Preset(rawValue: settings.defaultReminderPresetRaw),
                      let date = preset.date(from: Date(), hour: settings.reminderHour) {
                pickedDate = date
            } else {
                pickedDate = Self.defaultDate()
            }
            _Concurrency.Task { await reminderManager.requestPermissionIfNeeded() }
        }
    }

    /// Whether the picker currently matches a preset's date (to the minute), so the
    /// tapped preset pill reads as selected.
    private func isSelected(_ date: Date) -> Bool {
        abs(pickedDate.timeIntervalSince(date)) < 60
    }
}

/// A quiet capsule "chip" for a quick-set preset. Filled with the accent when selected,
/// a faint fill otherwise — lighter than a bordered button so the row of presets doesn't
/// dominate the popover.
private struct PresetPill: View {
    @Environment(\.appAccent) private var appAccent
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        selected ? appAccent
                        : (hovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06)))
                )
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
