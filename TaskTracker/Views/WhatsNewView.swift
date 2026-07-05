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
            icon: "shippingbox.and.arrow.backward",
            title: "Safer than ever",
            detail: "Your data is now protected across app updates. If a file ever can't be opened, it's set aside for recovery instead of being lost — and a backup is taken automatically before any upgrade."),
        WhatsNewItem(
            icon: "arrow.left.arrow.right",
            title: "Reliable move between projects",
            detail: "Fixed a rare issue where moving a task with subtasks to another project could make it disappear."),
        WhatsNewItem(
            icon: "pin.fill",
            title: "Pin & rename backups",
            detail: "Give backups meaningful names and pin the ones you want to keep — pinned backups are protected from automatic cleanup and grouped at the top."),
        WhatsNewItem(
            icon: "checklist",
            title: "Smarter subtasks",
            detail: "Completing every subtask now completes its parent automatically, the Active filter hides finished subtasks, and pressing Return at the start of a subtask inserts one above it."),
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
