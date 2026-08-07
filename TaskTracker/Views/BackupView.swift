import SwiftUI

struct BackupView: View {
    @Environment(BackupManager.self) private var backupManager
    @Environment(\.dismiss) private var dismiss
    @State private var labelText = ""
    @State private var backupToRestore: Backup?
    @State private var showRestoreConfirm = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var errorTitle = "Restore Failed"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            backupList
        }
        .frame(width: 500, height: 520)
        .confirmationDialog(
            "Restore this backup?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                guard let backup = backupToRestore else { return }
                do {
                    try backupManager.restore(backup: backup)
                    dismiss()
                } catch {
                    errorTitle = "Restore Failed"
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let b = backupToRestore {
                Text("This replaces ALL projects and tasks with the snapshot from \(Self.dateFormatter.string(from: b.date)) — it is not a per-project restore. Your current data is saved to a single “Before Restore” backup first, so you can undo.")
            }
        }
        // Shared by restore and backup failures — errorTitle says which.
        .alert(errorTitle, isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Backups")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Each backup is a full snapshot of every project. Restoring replaces all current data with it — but a “Before Restore” copy is saved first, so you can undo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    // MARK: Controls (interval + create)

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Automatic backup", systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                Spacer()
                Picker("Automatic backup", selection: intervalBinding) {
                    ForEach(BackupManager.intervalOptions, id: \.self) { hours in
                        Text(intervalLabel(hours)).tag(hours)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            HStack(spacing: 10) {
                TextField("Label (optional)", text: $labelText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createBackup)

                Button(action: createBackup) {
                    Label("Create Backup", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    // MARK: List

    @ViewBuilder private var backupList: some View {
        if backupManager.backups.isEmpty {
            ContentUnavailableView("No Backups Yet", systemImage: "externaldrive",
                                   description: Text("Create one above, or wait for the next automatic backup."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                // Pinned backups get their own section at the top; they're filtered
                // out of their kind sections below so each appears exactly once.
                section("Pinned", backupManager.pinnedBackups)
                section("Before Restore", backupManager.preRestoreBackups.filter { !$0.isPinned })
                section("Manual", backupManager.manualBackups.filter { !$0.isPinned })
                section("Automatic", backupManager.autoBackups.filter { !$0.isPinned })
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Backup]) -> some View {
        if !items.isEmpty {
            // Pinned first, then newest first (Backup.< already encodes this).
            Section(title) {
                ForEach(items.sorted()) { backup in
                    BackupRow(backup: backup, formatter: Self.dateFormatter) {
                        backupToRestore = backup
                        showRestoreConfirm = true
                    } onDelete: {
                        backupManager.delete(backup: backup)
                    } onTogglePin: {
                        backupManager.setPinned(backup, !backup.isPinned)
                    } onRename: { newLabel in
                        backupManager.rename(backup, to: newLabel)
                    }
                }
            }
        }
    }

    // MARK: Actions / helpers

    /// createBackup returns nil when the snapshot fails (no store file, disk full,
    /// permissions). Discarding that left the button looking like it worked — the label
    /// field cleared and no row appeared — so the user believed they had a backup they
    /// didn't. Report it and keep the typed label so they can retry.
    private func createBackup() {
        let trimmed = labelText.trimmingCharacters(in: .whitespaces)
        guard backupManager.createBackup(label: trimmed) != nil else {
            errorTitle = "Backup Failed"
            errorMessage = "Couldn't write the backup. Check that there's enough free disk space and try again."
            showError = true
            return
        }
        labelText = ""
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { backupManager.autoBackupIntervalHours },
                set: { backupManager.autoBackupIntervalHours = $0 })
    }

    private func intervalLabel(_ hours: Int) -> String {
        switch hours {
        case 0:  return "Off"
        case 1:  return "Every hour"
        case 24: return "Daily"
        default: return "Every \(hours) hours"
        }
    }
}

private struct BackupRow: View {
    let backup: Backup
    let formatter: DateFormatter
    let onRestore: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    let onRename: (String) -> Void

    @Environment(\.appAccent) private var appAccent
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftLabel = ""
    @FocusState private var renameFocused: Bool

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Label", text: $draftLabel)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)   // Esc
                        .onChange(of: renameFocused) { _, focused in
                            if !focused { commitRename() }       // click-away commits
                        }
                } else {
                    HStack(spacing: 5) {
                        if backup.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(appAccent)
                                .help("Pinned — protected from automatic cleanup")
                        }
                        Text(title)
                            .font(.body)
                            .lineLimit(1)
                    }
                }
                Text(formatter.string(from: backup.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Real content age. Shown when the data inside is meaningfully older than
                // the backup's write date — the signal that a backup is stale (captured
                // from a frozen store), which the write date alone would hide.
                if let fp = backup.fingerprint, let contentDate = fp.latestActivityDate,
                   backup.date.timeIntervalSince(contentDate) > 86_400 {
                    Label("Newest content: \(formatter.string(from: contentDate))",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("The data in this backup is older than when the backup was made — it may have been captured from a store that stopped updating.")
                }
            }

            Spacer()

            if !isRenaming {
                // Relative age, fading out when the row is hovered to make room.
                Text(Self.relative.localizedString(for: backup.date, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 0 : 1)

                if isHovered {
                    Button(action: onTogglePin) {
                        Image(systemName: backup.isPinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(backup.isPinned ? "Unpin" : "Pin (protect from cleanup)")

                    Button(action: startRename) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Rename")

                    Button("Restore", action: onRestore)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Delete this backup")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private func startRename() {
        draftLabel = backup.label
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draftLabel.trimmingCharacters(in: .whitespaces)
        if trimmed != backup.label { onRename(trimmed) }
    }

    private func cancelRename() {
        isRenaming = false
    }

    /// The backup's user label, or a human description of its kind when unlabeled.
    private var title: String {
        if !backup.label.isEmpty { return backup.label }
        switch backup.kind {
        case .manual:     return "Manual backup"
        case .auto:       return "Automatic backup"
        case .preRestore: return "Before restore"
        }
    }

    private var icon: String {
        switch backup.kind {
        case .manual:     return "bookmark.fill"
        case .auto:       return "clock.arrow.circlepath"
        case .preRestore: return "arrow.uturn.backward.circle.fill"
        }
    }

    private var iconColor: Color {
        switch backup.kind {
        case .manual:     return appAccent
        case .auto:       return .secondary
        case .preRestore: return .orange
        }
    }
}
