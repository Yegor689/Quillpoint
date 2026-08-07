import SwiftUI

/// A single highlighted change shown on the What's New screen.
struct WhatsNewItem: Identifiable {
    let id = UUID()
    let icon: String       // SF Symbol
    let title: String
    let detail: String
}

/// One shipped release: its version, when it shipped, and exactly the highlights that
/// version presented to users.
///
/// `items` is a historical record — it reproduces what that release actually showed,
/// duplicates and all. Two versions repeating an entry (a patch that carried its
/// predecessor's notes forward) is faithful, not a mistake to tidy up.
struct WhatsNewRelease: Identifiable {
    let version: String        // matches CFBundleShortVersionString, e.g. "1.3.2"
    let date: String           // when this version shipped, e.g. "August 6, 2026"
    let items: [WhatsNewItem]
    /// Optional context shown above the list — used where the notes alone would look
    /// wrong, e.g. a patch that repeated its predecessor's highlights verbatim.
    var note: String? = nil
    var id: String { version }
}

/// Owns the "What's New" content and the once-per-version gating.
///
/// `releases` is an ARCHIVE, newest first: each version's highlights stay in the app
/// after it ships instead of being overwritten. An update presents just the new
/// version's entry; Help ▸ What's New shows the full history.
///
/// Each release: add a new `WhatsNewRelease` at the TOP of `releases` whose `version`
/// matches the bundle's marketing version. Nothing else here needs touching.
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

    /// Every release's highlights, NEWEST FIRST. Add to the top each version.
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(version: "1.3.2", date: "August 7, 2026", items: [
            WhatsNewItem(
                icon: "bell.badge",
                title: "Completed tasks stop nagging",
                detail: "Ticking a task off now clears its reminder, so a notification can't arrive for work you've already finished."),
            WhatsNewItem(
                icon: "textformat",
                title: "Simpler text editing",
                detail: "The asterisk and underscore typing shortcuts are gone — use ⌘B and ⌘I instead. Text you've already styled is unchanged."),
            WhatsNewItem(
                icon: "externaldrive.badge.checkmark",
                title: "Safer backups and imports",
                detail: "A failed backup or export now says so instead of quietly doing nothing, and restoring an older backup no longer warns you every launch afterwards."),
            WhatsNewItem(
                icon: "clock.arrow.circlepath",
                title: "History kept",
                detail: "What's New now keeps every release's notes — browse them from Help ▸ What's New."),
        ]),
        // Every earlier release exactly as it shipped, generated from that version's
        // tag — including entries a patch carried forward from its predecessor.
        WhatsNewRelease(version: "1.3.1", date: "August 6, 2026", items: [
            WhatsNewItem(
                icon: "checkmark.shield",
                title: "More reliable automatic backups",
                detail: "Automatic backups could skip a whole session spent rewording tasks, because editing text didn't register as a change. Those edits are now backed up like any other work."),
            WhatsNewItem(
                icon: "list.bullet.indent",
                title: "A tidier Report",
                detail: "Completed subtasks no longer pad the day-by-day log — it lists finished tasks only. A task that wrapped up subtasks shows a small arrow you can click to see them."),
            WhatsNewItem(
                icon: "gearshape",
                title: "Settings, reorganised",
                detail: "Settings is now split into General, Tasks, Reminders, and Appearance tabs, so nothing scrolls off. New options: the time of day reminder presets use, whether reminders play a sound, and a confirmation before deleting a project."),
            WhatsNewItem(
                icon: "wrench.and.screwdriver",
                title: "Fixes",
                detail: "Quillpoint no longer reopens on the Report screen after a restart, the New Project button stays put instead of drifting to the far edge of the window, and a failed export now tells you instead of quietly doing nothing."),
        ]),
        WhatsNewRelease(version: "1.3.0", date: "August 5, 2026", items: [
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
        ]),
        WhatsNewRelease(version: "1.2.0", date: "July 17, 2026", items: [
            WhatsNewItem(
                icon: "square.and.pencil",
                title: "Your edits save right away",
                detail: "New tasks and subtasks — and any title or note you type — are now saved the moment you make them. They'll be there when you reopen Quillpoint, even if you don't switch away first."),
            WhatsNewItem(
                icon: "list.bullet.indent",
                title: "Subtasks stay put",
                detail: "Indenting a task into a subtask (and moving one back out) now sticks. Your nesting is exactly as you left it after you quit and reopen."),
            WhatsNewItem(
                icon: "clock.arrow.circlepath",
                title: "Stronger, safer backups",
                detail: "Backups are captured more reliably, and restoring is fail-safe — if a restore can't complete, your current data is never moved or emptied, and Quillpoint tells you what happened instead of coming up blank."),
            WhatsNewItem(
                icon: "checkmark.shield",
                title: "A heads-up if something looks off",
                detail: "If the data Quillpoint opens looks older than what you had last time, it now warns you and helps you restore a backup — so you can recover before piling new work onto the wrong copy."),
        ]),
        WhatsNewRelease(version: "1.1.3", date: "July 10, 2026", items: [
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
        ]),
        WhatsNewRelease(version: "1.1.2", date: "July 9, 2026", items: [
            WhatsNewItem(
                icon: "clock.arrow.circlepath",
                title: "Restore your data when it won't open",
                detail: "If Quillpoint ever can't open your data, the recovery screen now gathers everything you can restore from — your backups and any data previously set aside — in one place. It only offers copies it can actually open, and your current data is set aside (never deleted) first."),
            WhatsNewItem(
                icon: "arrow.down.doc",
                title: "Restore from a JSON export",
                detail: "The recovery screen can also rebuild your data from a JSON export you've saved. Because a JSON file doesn't depend on the app's internal format, it's a dependable fallback even when a data file can't be read."),
            WhatsNewItem(
                icon: "arrow.up.circle",
                title: "Protects against older versions",
                detail: "If you open data that was created by a newer version of Quillpoint, this version now leaves it safely untouched and asks you to update — instead of risking your data by writing to it in an older format."),
        ]),
        WhatsNewRelease(version: "1.1.1", date: "July 5, 2026", items: [
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
        ], note: "A same-day patch to 1.1.0 that shipped its predecessor's notes unchanged — these are the 1.1.0 highlights, kept here as they were shown."),
        WhatsNewRelease(version: "1.1.0", date: "July 5, 2026", items: [
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
        ]),
    ]

    /// The entry for the running version, if this build has one.
    static var currentRelease: WhatsNewRelease? {
        releases.first { $0.version == currentVersion }
    }
}

/// A polished "What's New" screen presented once after an update.
///
/// Shows exactly ONE release at a time, starting on the version that just installed.
/// A picker in the header steps back through the archive, so the history is reachable
/// without turning the screen into a long scroll of every release ever shipped.
struct WhatsNewView: View {
    /// True when the screen opened itself after an update, rather than being asked for
    /// from Help. The automatic presentation is an announcement of what just changed —
    /// the ship date is noise there, and there's no history to step through yet — so it
    /// shows a plain version label. Browsing from Help gets the picker and dates.
    var isAutoPresented = false

    @Environment(\.dismiss) private var dismiss

    /// The release on screen. Starts at the running version, falling back to the newest
    /// entry when this build has none (e.g. a dev build between releases).
    @State private var selectedVersion: String =
        WhatsNew.currentRelease?.version ?? WhatsNew.releases.first?.version ?? ""

    private var release: WhatsNewRelease? {
        WhatsNew.releases.first { $0.version == selectedVersion }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let note = release?.note {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(release?.items ?? []) { item in
                        row(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 560)
    }

    private func row(_ item: WhatsNewItem) -> some View {
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

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("What's New in Quillpoint")
                .font(.title2.weight(.bold))

            // Auto-presented after an update: just name the version. Opened from Help:
            // a picker to step back through the archive, with ship dates to orient by.
            if isAutoPresented || WhatsNew.releases.count <= 1 {
                Text("Version \(release?.version ?? WhatsNew.currentVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Version", selection: $selectedVersion) {
                    ForEach(WhatsNew.releases) { r in
                        Text("Version \(r.version) — \(r.date)").tag(r.version)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 20)
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
