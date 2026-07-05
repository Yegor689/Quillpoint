import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct TaskTrackerApp: App {
    private let storeURL = URL.applicationSupportDirectory
        .appending(component: "TaskTracker.store")

    // Populated only when the store opens successfully. On failure these stay nil
    // and the scene shows RecoveryView instead (the store is quarantined, not lost).
    let container: ModelContainer?
    let projectStore: ProjectStore?
    let taskStore: TaskStore?
    let reminderManager: ReminderManager?
    // BackupManager exists regardless — it's needed to take the pre-migration backup
    // before the container opens, and to drive recovery.
    let backupManager: BackupManager
    let settings = AppSettings()

    /// The result of bringing up the store. Drives whether the app shows its normal
    /// UI or the recovery screen.
    @State private var bringUp: PersistenceController.State

    init() {
        let backupManager = BackupManager(storeURL: storeURL)
        self.backupManager = backupManager

        let state = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self,
            backupManager: backupManager)
        _bringUp = State(initialValue: state)

        switch state {
        case .ready(let container):
            self.container = container
            let taskStore = TaskStore(context: container.mainContext)
            self.taskStore = taskStore
            projectStore = ProjectStore(context: container.mainContext)
            reminderManager = ReminderManager()
            backupManager.liveContainer = container
            taskStore.backfillSortIndicesIfNeeded()
            backupManager.startAutoBackup()
        case .failed:
            container = nil
            taskStore = nil
            projectStore = nil
            reminderManager = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            switch bringUp {
            case .ready:
                readyView
            case .failed(let reason, let quarantineURL):
                RecoveryView(reason: reason, quarantineURL: quarantineURL, onRetry: retryBringUp)
            }
        }
        .defaultSize(width: 960, height: 620)
        .commands {
            // App (Quillpoint) menu: backups, data export/import, and diagnostics.
            CommandGroup(after: .appSettings) {
                Button("Backups…") {
                    NotificationCenter.default.post(name: .showBackups, object: nil)
                }
                Divider()
                Button("Export All Data (JSON)…") { exportData() }
                Button("Import Data (JSON)…") { importData() }
                Button("Export Diagnostics…") { exportDiagnostics() }
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .tint(settings.accent.color)
                .environment(\.appAccent, settings.accent.color)
        }
    }

    /// The normal app UI. Only built when bring-up succeeded, so the force-unwraps
    /// here are safe — `.ready` implies all of these are populated.
    @ViewBuilder
    private var readyView: some View {
        let container = container!
        let taskStore = taskStore!
        ContentView()
            .modelContainer(container)
            .environment(projectStore!)
            .environment(taskStore)
            .environment(backupManager)
            .environment(reminderManager!)
            .environment(settings)
            .tint(settings.accent.color)
            .environment(\.appAccent, settings.accent.color)
            .frame(minWidth: 720, minHeight: 480)
            .onAppear {
                setApplicationIcon()
                settings.applyAppearance()
                clearExpiredReminders()
                applyDefaultFilter()
            }
            .onReceive(NotificationCenter.default.publisher(for: .markTaskDone)) { note in
                guard let idStr = note.object as? String,
                      let uuid  = UUID(uuidString: idStr) else { return }
                // Find the task by ID and mark it done through the store so it's undoable.
                let descriptor = FetchDescriptor<Task>(
                    predicate: #Predicate { $0.id == uuid }
                )
                if let task = try? container.mainContext.fetch(descriptor).first {
                    taskStore.completeTask(task)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reminderFired)) { note in
                guard let idStr = note.object as? String,
                      let uuid  = UUID(uuidString: idStr) else { return }
                // The reminder fired; clear its date so the UI stops showing it.
                let descriptor = FetchDescriptor<Task>(
                    predicate: #Predicate { $0.id == uuid }
                )
                if let task = try? container.mainContext.fetch(descriptor).first {
                    task.reminderDate = nil
                }
            }
    }

    /// Re-attempts bring-up (the recovery screen's "Try Again"). If it now succeeds,
    /// the switch in `body` renders the normal UI. A relaunch is still the cleanest
    /// path, but retrying in place covers transient failures.
    private func retryBringUp() {
        bringUp = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self,
            backupManager: backupManager)
    }

    /// Ensure the About panel shows the real app icon. macOS loads the icon from
    /// the compiled asset catalog (AppIcon.icns) at launch; we only force it from
    /// that same .icns file. NSImage(named: "AppIcon") is NOT used here because on
    /// macOS that lookup can resolve to a generic template image, which would
    /// override the correct icon with a placeholder (the source of issue #10's
    /// recurrence). If the .icns can't be loaded we leave the system default in
    /// place rather than risk replacing it with something worse.
    /// Writes the diagnostic action log to a user-chosen .txt file so it can be
    /// attached to a bug report. The log holds only structural facts (operation
    /// names, short ids, counts) — no task titles or descriptions.
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Quillpoint-diagnostics.txt"
        panel.title = "Export Diagnostics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? DiagnosticLog.shared.exportText().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Exports all projects and tasks to a user-chosen JSON file — a portable,
    /// human-readable copy of everything in the app. Read-only; never mutates data.
    private func exportData() {
        guard let container else { return }
        guard let data = try? DataExportManager.json(from: container.mainContext) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10) // yyyy-MM-dd
        panel.nameFieldStringValue = "Quillpoint-data-\(stamp).json"
        panel.title = "Export All Data"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Imports a JSON export. Validates first (a bad file changes nothing), asks the
    /// user whether to merge or replace, takes a safety backup, then applies. The
    /// destructive parts only run after explicit confirmation.
    private func importData() {
        guard let container else { return }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = false
        open.title = "Import Data"
        guard open.runModal() == .OK, let url = open.url else { return }

        guard let data = try? Data(contentsOf: url) else {
            return showImportError(DataExportManager.ImportError.unreadable)
        }

        // Validate before touching anything.
        let counts: (projects: Int, tasks: Int)
        do { counts = try DataExportManager.validate(data) }
        catch { return showImportError(error) }

        // Ask: merge or replace (or cancel).
        let alert = NSAlert()
        alert.messageText = "Import \(counts.projects) project\(counts.projects == 1 ? "" : "s") and \(counts.tasks) task\(counts.tasks == 1 ? "" : "s")?"
        alert.informativeText = "Merge adds the imported items alongside your current data. Replace removes all current data first. A backup is taken either way."
        alert.addButton(withTitle: "Merge")        // .alertFirstButtonReturn
        alert.addButton(withTitle: "Replace All")  // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")       // .alertThirdButtonReturn
        let choice = alert.runModal()
        let mode: DataExportManager.ImportMode
        switch choice {
        case .alertFirstButtonReturn:  mode = .merge
        case .alertSecondButtonReturn: mode = .replace
        default: return // cancel
        }

        // Safety backup before any change, then apply.
        backupManager.createBackup(label: "before import", kind: .manual)
        do {
            try DataExportManager.importing(data, into: container.mainContext, mode: mode)
        } catch {
            showImportError(error)
        }
    }

    private func showImportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Import Failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func setApplicationIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }

    /// If the user picked a fixed startup filter (not "remember last used"), apply
    /// it once at launch by writing the shared taskFilter default that the task
    /// views read via @AppStorage.
    private func applyDefaultFilter() {
        if let f = settings.defaultFilter {
            UserDefaults.standard.set(f.rawValue, forKey: "taskFilter")
        }
    }

    /// Clears reminders whose time has already passed (e.g. fired or were missed while the app was closed)
    /// so the UI never shows a stale past reminder.
    private func clearExpiredReminders() {
        guard let container, let reminderManager else { return }
        let now = Date()
        let descriptor = FetchDescriptor<Task>(
            predicate: #Predicate { $0.reminderDate != nil && $0.reminderDate! < now }
        )
        guard let expired = try? container.mainContext.fetch(descriptor) else { return }
        for task in expired {
            task.reminderDate = nil
            reminderManager.cancel(taskID: task.id)
        }
    }
}
