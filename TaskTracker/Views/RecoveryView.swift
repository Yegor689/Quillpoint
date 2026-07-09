import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shown at the scene root when the store fails to open (a corrupt store or a failed
/// migration). The store is LEFT IN PLACE on failure — never moved or deleted. Recovery
/// options, in order of least to most drastic:
///   • "Try Again" retries against the same data (fixes a transient failure, or works
///     after installing a build that fixes the migration).
///   • "Restore Data…" opens one picker covering every recoverable source — backups,
///     data previously set aside (Quarantine), and a JSON export. Restoring sets the
///     current store aside first, so it's reversible.
///   • "Start Fresh" is an explicit, confirmed choice that sets the current data aside
///     (recoverable — it then shows up under Set-aside data) and starts empty.
/// This avoids the trap where retrying silently opened a blank store, and makes the
/// "your data can be recovered" promise real: every set-aside store is restorable here.
struct RecoveryView: View {
    let reason: String
    let backupManager: BackupManager
    /// Stores previously set aside in Quarantine, offered for restore (closes the loop
    /// on Start Fresh's "recoverable later" promise).
    let quarantined: [PersistenceController.QuarantinedStore]
    let onRetry: () -> Void
    let onStartFresh: () -> Void
    /// Restores the given backup by replacing the store, then re-attempts bring-up.
    let onRestore: (Backup) -> Void
    /// Restores a previously set-aside (quarantined) store.
    let onRestoreQuarantined: (PersistenceController.QuarantinedStore) -> Void
    /// Rebuilds the store from a JSON export (schema-independent recovery path).
    let onRestoreJSON: () -> Void

    @State private var showDetails = false
    @State private var confirmStartFresh = false
    @State private var showRestore = false

    /// True when the store was written by a NEWER build of Quillpoint. The advice
    /// differs: Try Again won't help (the data really is newer) — the fix is to update
    /// the app, and Start Fresh would needlessly set aside good data.
    private var isDowngrade: Bool {
        reason.hasPrefix(PersistenceController.downgradeReasonPrefix)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isDowngrade ? "arrow.up.circle" : "exclamationmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(isDowngrade ? .blue : .orange)

            Text(isDowngrade
                 ? "This data was made by a newer Quillpoint"
                 : "Quillpoint couldn't open your data")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                Text("Your data has not been lost.")
                    .fontWeight(.medium)
                Text(isDowngrade
                     ? "This copy of your data was created by a newer version of Quillpoint, and this older version can't open it safely. Update Quillpoint to the latest version, then reopen — your data is untouched. Don't Start Fresh; that would set this data aside."
                     : "It's still on your Mac, untouched. Try Again first — installing the latest version and retrying usually fixes it. If you're stuck, restore from a backup, a previously set-aside copy, or a JSON export.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)

            // Primary actions: retry, then a single "Restore Data" entry point that
            // gathers every recoverable source in one place.
            HStack(spacing: 12) {
                Button("Try Again", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                Button("Restore Data…") { showRestore = true }
            }

            // Secondary, de-emphasized actions.
            HStack(spacing: 16) {
                Button("Export Diagnostics…", action: exportDiagnostics)
                Button("Start Fresh…", role: .destructive) { confirmStartFresh = true }
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .confirmationDialog(
                "Start with an empty Quillpoint?",
                isPresented: $confirmStartFresh,
                titleVisibility: .visible
            ) {
                Button("Start Fresh", role: .destructive, action: onStartFresh)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your current data will be set aside (moved to a Quarantine folder, not deleted) so you can restore it later from “Restore Data,” and Quillpoint will open empty.")
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
        .frame(minWidth: 540, minHeight: 480)
        .sheet(isPresented: $showRestore) {
            RestoreDataPicker(
                backups: backupManager.backups.sorted(),
                quarantined: quarantined,
                onPickBackup: { showRestore = false; onRestore($0) },
                onPickQuarantined: { showRestore = false; onRestoreQuarantined($0) },
                onPickJSON: { showRestore = false; onRestoreJSON() },
                onCancel: { showRestore = false })
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

/// One place to restore data from, covering every recoverable source: backups, stores
/// previously set aside (Quarantine), and a JSON export chosen from disk. Whatever the
/// source, the current store is set aside first, so restoring is always reversible.
private struct RestoreDataPicker: View {
    let backups: [Backup]
    let quarantined: [PersistenceController.QuarantinedStore]
    let onPickBackup: (Backup) -> Void
    let onPickQuarantined: (PersistenceController.QuarantinedStore) -> Void
    let onPickJSON: () -> Void
    let onCancel: () -> Void

    /// A row's identity: either a backup or a quarantined store.
    private enum Selection: Hashable { case backup(Backup.ID), quarantined(UUID) }
    @State private var selection: Selection?
    @State private var confirm = false
    @State private var unopenableAlert = false

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // Lists are pre-filtered to sources this build can plausibly open, with a cheap
    // metadata check — corrupt files and stores from a newer version are hidden (never
    // offered as a dead option). The one the user picks is then fully trial-opened as a
    // final guard before we touch the live store.
    private var openableBackups: [Backup] { backups.filter { PersistenceController.looksOpenable(storeURL: $0.url) } }
    private var openableQuarantined: [PersistenceController.QuarantinedStore] {
        quarantined.filter { PersistenceController.looksOpenable(storeURL: $0.url) }
    }
    private var hiddenBackupCount: Int { backups.count - openableBackups.count }
    private var hiddenQuarantinedCount: Int { quarantined.count - openableQuarantined.count }

    private var selectedBackup: Backup? {
        if case .backup(let id) = selection { return openableBackups.first { $0.id == id } }
        return nil
    }
    private var selectedQuarantined: PersistenceController.QuarantinedStore? {
        if case .quarantined(let id) = selection { return openableQuarantined.first { $0.id == id } }
        return nil
    }
    private var hasSelection: Bool { selectedBackup != nil || selectedQuarantined != nil }

    private var selectedURL: URL? { selectedBackup?.url ?? selectedQuarantined?.url }

    private var selectionName: String {
        if let b = selectedBackup { return b.label.isEmpty ? Self.dateFormat.string(from: b.date) : b.label }
        if let q = selectedQuarantined { return "set-aside data from \(Self.dateFormat.string(from: q.date))" }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore Data")
                .font(.title3.bold())
            Text("Your current data is set aside first (moved to a Quarantine folder, not deleted), then replaced with what you choose. Quillpoint then reopens.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                if !openableQuarantined.isEmpty {
                    Section("Set-aside data") {
                        ForEach(openableQuarantined) { store in
                            row(icon: "tray.and.arrow.up",
                                title: Self.dateFormat.string(from: store.date),
                                subtitle: "Previously set aside")
                                .tag(Selection.quarantined(store.id))
                        }
                    }
                }
                if !openableBackups.isEmpty {
                    Section("Backups") {
                        ForEach(openableBackups) { backup in
                            row(icon: backup.isPinned ? "pin.fill" : "clock.arrow.circlepath",
                                title: backup.label.isEmpty ? Self.dateFormat.string(from: backup.date) : backup.label,
                                subtitle: "\(backup.kind.rawValue) • \(Self.dateFormat.string(from: backup.date))")
                                .tag(Selection.backup(backup.id))
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            if hiddenBackupCount + hiddenQuarantinedCount > 0 {
                let n = hiddenBackupCount + hiddenQuarantinedCount
                Text("\(n) \(n == 1 ? "item" : "items") can't be opened by this version and \(n == 1 ? "is" : "are") hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // JSON is a separate action (it opens a file panel rather than selecting a
            // listed row), kept beside the list so all restore sources live together.
            Button {
                onPickJSON()
            } label: {
                Label("Restore from a JSON export…", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.link)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore Selected") { confirm = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasSelection)
            }
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 420)
        .confirmationDialog(
            "Restore this data?",
            isPresented: $confirm,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive, action: restoreSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current data will be set aside and replaced with \(selectionName).")
        }
        .alert("This copy can't be opened", isPresented: $unopenableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This data can't be opened by this version of Quillpoint, so it wasn't restored (your current data is unchanged). Try a different backup, a set-aside copy, or a JSON export.")
        }
    }

    /// Final guard before restoring: fully trial-open the selected store. Only if it
    /// really opens do we hand it to the restore handler; otherwise warn and change
    /// nothing (the live store is never touched). Catches old-shape stores the cheap
    /// list filter can't detect.
    private func restoreSelected() {
        guard let url = selectedURL else { return }
        guard PersistenceController.canOpen(storeURL: url) else {
            unopenableAlert = true
            return
        }
        if let b = selectedBackup { onPickBackup(b) }
        else if let q = selectedQuarantined { onPickQuarantined(q) }
    }

    private func row(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint).font(.caption).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
