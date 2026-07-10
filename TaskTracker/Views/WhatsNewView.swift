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
            icon: "checkmark.shield",
            title: "Safer recovery",
            detail: "Restoring from the recovery screen is now fail-safe: if a restore can't complete, your current data is never moved or emptied, and you're told what happened — the app can no longer come up blank after a failed restore."),
        WhatsNewItem(
            icon: "clock.arrow.circlepath",
            title: "Restore your data when it won't open",
            detail: "If Quillpoint ever can't open your data, the recovery screen gathers everything you can restore from — your backups and any data previously set aside — in one place. It only offers copies it can actually open, and your current data is set aside (never deleted) first."),
        WhatsNewItem(
            icon: "arrow.down.doc",
            title: "Restore from a JSON export",
            detail: "The recovery screen can also rebuild your data from a JSON export you've saved. Because a JSON file doesn't depend on the app's internal format, it's a dependable fallback even when a data file can't be read."),
        WhatsNewItem(
            icon: "arrow.up.circle",
            title: "Protects against older versions",
            detail: "If you open data that was created by a newer version of Quillpoint, this version now leaves it safely untouched and asks you to update — instead of risking your data by writing to it in an older format."),
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
