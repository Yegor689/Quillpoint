import SwiftUI

/// A single highlighted change shown on the What's New screen.
struct WhatsNewItem: Identifiable {
    let id = UUID()
    let icon: String       // SF Symbol
    let title: String
    let detail: String
}

/// Owns the "What's New" content for the CURRENT app version and the once-per-version
/// gating. Each release: bump nothing here except `highlights` — the version is read
/// from the bundle, and the "last seen" check decides whether to present.
enum WhatsNew {
    /// The running app's marketing version (e.g. "1.1.0"), from the bundle.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private static let lastSeenKey = "whatsNewLastSeenVersion"

    /// True when the app has been updated to a version whose What's New the user
    /// hasn't seen yet. False on a brand-new install (nothing to announce) so a
    /// first-time user isn't greeted by a changelog.
    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        guard let lastSeen = defaults.string(forKey: lastSeenKey) else {
            // First run ever: record the current version, don't show the changelog.
            defaults.set(currentVersion, forKey: lastSeenKey)
            return false
        }
        return lastSeen != currentVersion
    }

    /// Marks the current version as seen so it won't auto-present again.
    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: lastSeenKey)
    }

    /// Highlights for the current release. Re-author this list each version.
    static let highlights: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "chart.bar.xaxis",
            title: "See what you got done",
            detail: "The new Report view lays out the tasks you completed, day by day, over any date range you pick — with a quick summary of how much you created and finished."),
        WhatsNewItem(
            icon: "bell.badge",
            title: "Upcoming reminders in one place",
            detail: "Turn on Upcoming in Settings to gather every task with a reminder — across all your projects — into a single list, grouped by when it's due: Overdue, Today, Tomorrow, This week, Later."),
        WhatsNewItem(
            icon: "clock.badge.checkmark",
            title: "Faster reminders, and Snooze",
            detail: "Set a reminder with one-tap presets like \"Tomorrow 9 AM,\" and snooze a notification you can't act on right now. Choose your default preset and snooze length in Settings."),
        WhatsNewItem(
            icon: "bolt.fill",
            title: "Snappier with lots of tasks",
            detail: "Big task lists are much faster to scroll and search — the app no longer slows to a crawl when a project has hundreds or thousands of tasks."),
    ]
}

/// A polished "What's New" screen presented once after an update.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(WhatsNew.highlights) { item in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: item.icon)
                                .font(.system(size: 22))
                                .foregroundStyle(.tint)
                                .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(28)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 560)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("What's New in Quillpoint")
                .font(.title2.weight(.bold))
            Text("Version \(WhatsNew.currentVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 22)
    }

    private var footer: some View {
        Button {
            dismiss()
        } label: {
            Text("Continue")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .padding(20)
    }
}
