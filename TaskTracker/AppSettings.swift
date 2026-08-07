import SwiftUI

/// User-facing app preferences, persisted in UserDefaults and surfaced in the
/// Settings window. Injected into the environment so views can read defaults.
@Observable
final class AppSettings {

    // MARK: Appearance

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }
        /// AppKit appearance to apply app-wide. nil = follow the system.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light:  return NSAppearance(named: .aqua)
            case .dark:   return NSAppearance(named: .darkAqua)
            }
        }
    }

    enum Accent: String, CaseIterable, Identifiable {
        case blue, purple, pink, red, orange, green, teal, graphite
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .blue:     return .blue
            case .purple:   return .purple
            case .pink:     return .pink
            case .red:      return .red
            case .orange:   return .orange
            case .green:    return .green
            case .teal:     return .teal
            case .graphite: return .gray
            }
        }
    }

    var theme: Theme {
        didSet {
            defaults.set(theme.rawValue, forKey: Keys.theme)
            applyAppearance()
        }
    }

    /// Sets the app-wide AppKit appearance so every window (main + Settings)
    /// updates immediately, including switching back to System (nil).
    func applyAppearance() {
        NSApp.appearance = theme.nsAppearance
    }
    var accent: Accent {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    // MARK: Behavior

    /// Priority new tasks start at (raw Priority value).
    var defaultPriority: Int {
        didSet { defaults.set(defaultPriority, forKey: Keys.defaultPriority) }
    }
    /// Whether to confirm before deleting a task that has subtasks.
    var confirmBeforeDelete: Bool {
        didSet { defaults.set(confirmBeforeDelete, forKey: Keys.confirmDelete) }
    }
    /// Whether to confirm before deleting a project (which cascade-deletes all its tasks).
    var confirmBeforeDeleteProject: Bool {
        didSet { defaults.set(confirmBeforeDeleteProject, forKey: Keys.confirmDeleteProject) }
    }
    /// Filter the app opens to. Empty = remember the last-used filter.
    var defaultFilterRaw: String {
        didSet { defaults.set(defaultFilterRaw, forKey: Keys.defaultFilter) }
    }

    // MARK: Reminders

    /// How many minutes "Snooze" pushes a fired reminder forward.
    var snoozeMinutes: Int {
        didSet { defaults.set(snoozeMinutes, forKey: Keys.snoozeMinutes) }
    }

    /// The hour of day (0–23) that day-based reminder presets ("Tomorrow", "Next week")
    /// land on. Defaults to 9 (9 AM).
    var reminderHour: Int {
        didSet { defaults.set(reminderHour, forKey: Keys.reminderHour) }
    }

    /// Whether reminder notifications play a sound.
    var reminderSound: Bool {
        didSet { defaults.set(reminderSound, forKey: Keys.reminderSound) }
    }

    /// Which quick-preset the reminder popover pre-selects when opened for a task that has
    /// no reminder yet. Empty = the popover's built-in default (one hour out).
    var defaultReminderPresetRaw: String {
        didSet { defaults.set(defaultReminderPresetRaw, forKey: Keys.defaultReminderPreset) }
    }

    /// Which view a fresh launch lands on: "all" (All Projects), "upcoming" (Upcoming),
    /// or "" (restore the last-used project).
    var defaultLandingRaw: String {
        didSet { defaults.set(defaultLandingRaw, forKey: Keys.defaultLanding) }
    }

    /// Whether the Upcoming view appears in the sidebar. Off by default — opt in from
    /// Settings if you use reminders and want the cross-project due list.
    var showUpcoming: Bool {
        didSet { defaults.set(showUpcoming, forKey: Keys.showUpcoming) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let theme           = "settings.theme"
        static let accent          = "settings.accent"
        static let defaultPriority = "settings.defaultPriority"
        static let confirmDelete   = "settings.confirmBeforeDelete"
        static let confirmDeleteProject = "settings.confirmBeforeDeleteProject"
        static let defaultFilter   = "settings.defaultFilter"
        static let snoozeMinutes         = "settings.snoozeMinutes"
        static let reminderHour          = "settings.reminderHour"
        static let reminderSound         = "settings.reminderSound"
        static let defaultReminderPreset = "settings.defaultReminderPreset"
        static let defaultLanding        = "settings.defaultLanding"
        static let showUpcoming          = "settings.showUpcoming"
    }

    init() {
        let d = UserDefaults.standard
        theme  = Theme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .system
        accent = Accent(rawValue: d.string(forKey: Keys.accent) ?? "") ?? .blue
        defaultPriority     = d.object(forKey: Keys.defaultPriority) as? Int ?? Priority.normal.rawValue
        confirmBeforeDelete = d.object(forKey: Keys.confirmDelete) as? Bool ?? true
        confirmBeforeDeleteProject = d.object(forKey: Keys.confirmDeleteProject) as? Bool ?? true
        defaultFilterRaw    = d.string(forKey: Keys.defaultFilter) ?? ""   // "" = remember last
        snoozeMinutes            = d.object(forKey: Keys.snoozeMinutes) as? Int ?? 60
        reminderHour             = d.object(forKey: Keys.reminderHour) as? Int ?? 9
        reminderSound            = d.object(forKey: Keys.reminderSound) as? Bool ?? true
        defaultReminderPresetRaw = d.string(forKey: Keys.defaultReminderPreset) ?? ""
        defaultLandingRaw        = d.string(forKey: Keys.defaultLanding) ?? ""
        showUpcoming             = d.object(forKey: Keys.showUpcoming) as? Bool ?? false
    }

    /// The filter a fresh launch should use, or nil to keep the last-used one.
    var defaultFilter: TaskFilter? { TaskFilter(rawValue: defaultFilterRaw) }

    /// Resets every preference to its first-launch default.
    func restoreDefaults() {
        theme               = .system
        accent              = .blue
        defaultPriority     = Priority.normal.rawValue
        confirmBeforeDelete = true
        confirmBeforeDeleteProject = true
        defaultFilterRaw    = ""
        snoozeMinutes            = 60
        reminderHour             = 9
        reminderSound            = true
        defaultReminderPresetRaw = ""
        defaultLandingRaw        = ""
        showUpcoming             = false
    }
}

// MARK: - Accent color environment

private struct AppAccentKey: EnvironmentKey {
    // Matches the AppSettings.Accent default (.blue) so views have a sane value
    // even before the real accent is injected.
    static let defaultValue: Color = .blue
}

extension EnvironmentValues {
    /// The user's chosen accent color (AppSettings.accent), threaded through the
    /// view tree. Views use this instead of `Color.accentColor`, which on macOS
    /// resolves to the *system* accent and ignores the in-app picker.
    var appAccent: Color {
        get { self[AppAccentKey.self] }
        set { self[AppAccentKey.self] = newValue }
    }
}
