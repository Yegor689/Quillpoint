import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shown at the scene root when the store fails to open (a corrupt store or a failed
/// migration). The store is LEFT IN PLACE on failure — never moved or deleted — so:
///   • "Try Again" retries against the same data (fixes a transient failure, or works
///     after installing a build that fixes the migration), and
///   • "Start Fresh" is an explicit, confirmed choice that sets the old data aside
///     (recoverable) and starts empty.
///   • "Restore from Backup" replaces the store with a chosen backup (the current
///     store is set aside in Quarantine first, so it's reversible), then reopens.
/// This avoids the trap where retrying silently opened a blank store.
struct RecoveryView: View {
    let reason: String
    let backupManager: BackupManager
    let onRetry: () -> Void
    let onStartFresh: () -> Void
    /// Restores the given backup by replacing the store, then re-attempts bring-up.
    let onRestore: (Backup) -> Void

    @State private var showDetails = false
    @State private var confirmStartFresh = false
    @State private var showBackupPicker = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Quillpoint couldn't open your data")
                .font(.title2.bold())

            VStack(spacing: 6) {
                Text("Your data has not been lost.")
                    .fontWeight(.medium)
                Text("It's still on your Mac, untouched. This often happens after an update — installing the latest version of Quillpoint and choosing Try Again usually fixes it. If you're stuck, export diagnostics and reach out before starting fresh.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)

            HStack(spacing: 12) {
                Button("Try Again", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                if !backupManager.backups.isEmpty {
                    Button("Restore from Backup…") { showBackupPicker = true }
                }
                Button("Export Diagnostics…", action: exportDiagnostics)
            }

            // Destructive, de-emphasized, and confirmed — never a one-click blank start.
            Button("Start Fresh…", role: .destructive) { confirmStartFresh = true }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .confirmationDialog(
                    "Start with an empty Quillpoint?",
                    isPresented: $confirmStartFresh,
                    titleVisibility: .visible
                ) {
                    Button("Start Fresh", role: .destructive, action: onStartFresh)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your current data will be set aside in a Quarantine folder (not deleted) so it can be recovered later, and Quillpoint will open empty.")
                }

            DisclosureGroup("Technical details", isExpanded: $showDetails) {
                ScrollView {
                    Text(reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(minWidth: 540, minHeight: 460)
        .sheet(isPresented: $showBackupPicker) {
            RecoveryBackupPicker(backups: backupManager.backups.sorted()) { backup in
                showBackupPicker = false
                onRestore(backup)
            } onCancel: {
                showBackupPicker = false
            }
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Quillpoint-diagnostics.txt"
        panel.title = "Export Diagnostics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? DiagnosticLog.shared.exportText().write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Lists available backups so the user can restore one from the recovery screen.
/// The current (unreadable) store is set aside — not deleted — when a choice is made,
/// so restoring is reversible.
private struct RecoveryBackupPicker: View {
    let backups: [Backup]
    let onPick: (Backup) -> Void
    let onCancel: () -> Void

    @State private var selection: Backup.ID?
    @State private var confirmRestore = false

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var selected: Backup? { backups.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore from a Backup")
                .font(.title3.bold())
            Text("Your current data will be set aside (moved to a Quarantine folder, not deleted) and replaced with the backup you choose. Quillpoint will then reopen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(backups) { backup in
                    HStack(spacing: 8) {
                        if backup.isPinned {
                            Image(systemName: "pin.fill").foregroundStyle(.tint).font(.caption)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.label.isEmpty ? Self.dateFormat.string(from: backup.date) : backup.label)
                            Text("\(backup.kind.rawValue) • \(Self.dateFormat.string(from: backup.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(backup.id)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore Selected") { confirmRestore = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 380)
        .confirmationDialog(
            "Restore this backup?",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) { if let s = selected { onPick(s) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let s = selected {
                Text("Your current data will be set aside and replaced with “\(s.label.isEmpty ? Self.dateFormat.string(from: s.date) : s.label)”.")
            }
        }
    }
}
