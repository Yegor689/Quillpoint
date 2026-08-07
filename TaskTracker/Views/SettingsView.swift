import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        // A tabbed Settings window — the macOS-standard multi-pane layout (Mail, Safari,
        // Xcode). Each pane is short enough not to scroll; the toolbar of icons up top
        // replaces the old single, ever-growing scrolling form. Each pane reads AppSettings
        // from the environment and makes its own @Bindable.
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TaskSettings()
                .tabItem { Label("Tasks", systemImage: "checklist") }
            ReminderSettings()
                .tabItem { Label("Reminders", systemImage: "bell.badge") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        // Restore Defaults lives in a fixed footer under all tabs so it's always reachable.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    settings.restoreDefaults()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - Panes

/// On-launch behavior: which view opens and the starting filter.
private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("On launch") {
                Picker("Open", selection: $settings.defaultLandingRaw) {
                    Text("Last-used project").tag("")
                    Text("All Projects").tag("all")
                    Text("Upcoming").tag("upcoming")
                }

                Picker("Show filter", selection: $settings.defaultFilterRaw) {
                    Text("Remember last used").tag("")
                    ForEach(TaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
            }

            Section("Projects") {
                Toggle("Confirm before deleting a project", isOn: $settings.confirmBeforeDeleteProject)
            }
        }
        .formStyle(.grouped)
    }
}

/// Task defaults and the Report's subtask visibility.
private struct TaskSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("New tasks") {
                Picker("Default to", selection: $settings.defaultPriority) {
                    ForEach(Priority.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Confirm before deleting tasks with subtasks", isOn: $settings.confirmBeforeDelete)
            }
        }
        .formStyle(.grouped)
    }
}

/// Reminder behavior and the optional Upcoming sidebar view.
private struct ReminderSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Show Upcoming in the sidebar", isOn: $settings.showUpcoming)
                Toggle("Play sound with reminders", isOn: $settings.reminderSound)
            }

            Section("Defaults") {
                Picker("Default reminder", selection: $settings.defaultReminderPresetRaw) {
                    Text("1 hour from now").tag("")
                    Text("This evening").tag("This evening")
                    Text("Tomorrow").tag("Tomorrow 9 AM")
                    Text("Next week").tag("Next week")
                }

                Picker("Day reminders at", selection: $settings.reminderHour) {
                    ForEach(0..<24) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }

                Picker("Snooze reminders for", selection: $settings.snoozeMinutes) {
                    Text("15 minutes").tag(15)
                    Text("1 hour").tag(60)
                    Text("3 hours").tag(180)
                    Text("Tomorrow").tag(1440)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    /// A 12-hour clock label for an hour-of-day (e.g. 9 → "9:00 AM").
    private static func hourLabel(_ hour: Int) -> String {
        var comps = DateComponents(); comps.hour = hour; comps.minute = 0
        let date = Calendar.current.date(from: comps) ?? Date()
        return hourFormatter.string(from: date)
    }
}

/// Theme and accent color.
private struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppSettings.Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Accent color") {
                    AccentSwatchPicker(selection: $settings.accent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A row of color swatches for choosing the accent. The selected swatch is
/// ringed and shows a checkmark, so the current choice is obvious at a glance.
private struct AccentSwatchPicker: View {
    @Binding var selection: AppSettings.Accent

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppSettings.Accent.allCases) { accent in
                let isSelected = accent == selection
                Button {
                    selection = accent
                } label: {
                    Circle()
                        .fill(accent.color)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            // Ring around the selected swatch for an extra cue that
                            // reads even for very light colors.
                            Circle()
                                .strokeBorder(.primary.opacity(isSelected ? 0.5 : 0), lineWidth: 2)
                                .padding(-3)
                        }
                }
                .buttonStyle(.plain)
                .help(accent.label)
                .accessibilityLabel(accent.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}
