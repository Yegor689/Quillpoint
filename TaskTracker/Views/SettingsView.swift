import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppSettings.Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Accent color") {
                    AccentSwatchPicker(selection: $settings.accent)
                }
            }

            Section("Tasks") {
                Picker("New tasks default to", selection: $settings.defaultPriority) {
                    ForEach(Priority.allCases) { Text($0.label).tag($0.rawValue) }
                }

                Toggle("Confirm before deleting tasks with subtasks", isOn: $settings.confirmBeforeDelete)
            }

            Section("Reminders") {
                Toggle("Show Upcoming in the sidebar", isOn: $settings.showUpcoming)

                Picker("Snooze reminders for", selection: $settings.snoozeMinutes) {
                    Text("15 minutes").tag(15)
                    Text("1 hour").tag(60)
                    Text("3 hours").tag(180)
                    Text("Tomorrow").tag(1440)
                }

                Picker("Default reminder", selection: $settings.defaultReminderPresetRaw) {
                    Text("1 hour from now").tag("")
                    Text("This evening").tag("This evening")
                    Text("Tomorrow 9 AM").tag("Tomorrow 9 AM")
                    Text("Next week").tag("Next week")
                }
            }

            Section("On launch") {
                Picker("Open", selection: $settings.defaultLandingRaw) {
                    Text("Last-used project").tag("")
                    Text("All Projects").tag("all")
                    Text("Upcoming").tag("upcoming")
                }

                if settings.defaultLandingRaw.isEmpty {
                    Toggle("Reopen the last-used project", isOn: $settings.restoreLastProject)
                }

                Picker("Show filter", selection: $settings.defaultFilterRaw) {
                    Text("Remember last used").tag("")
                    ForEach(TaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
        }
        .formStyle(.grouped)
        // Restore Defaults lives in a fixed footer so it's always visible without
        // scrolling, regardless of how tall the form grows.
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
        .frame(width: 460, height: 580)
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
