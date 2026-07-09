import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The live services built once the store opens. Bundled so a successful bring-up
/// (initial OR retry) can populate them together, and a failed one leaves them nil.
private struct AppServices {
    let container: ModelContainer
    let projectStore: ProjectStore
    let taskStore: TaskStore
    let reminderManager: ReminderManager
}

@main
struct TaskTrackerApp: App {
    private let storeURL = URL.applicationSupportDirectory
        .appending(component: "TaskTracker.store")

    // BackupManager exists regardless — it takes the pre-migration backup before the
    // container opens and drives recovery.
    let backupManager: BackupManager
    let settings = AppSettings()

    /// The result of bringing up the store, and the services built from it. Both are
    /// @State so "Try Again" can rebuild them after a successful retry (the original
    /// version used `let`, so a retry could never populate the UI). nil services ⇒
    /// show recovery.
    @State private var bringUp: PersistenceController.State
    @State private var services: AppServices?
    /// Presents the What's New screen (auto once per new version, or via the menu).
    @State private var showWhatsNew = false

    init() {
        let backupManager = BackupManager(storeURL: storeURL)
        self.backupManager = backupManager

        let state = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self,
            backupManager: backupManager)
        _bringUp = State(initialValue: state)
        _services = State(initialValue: Self.buildServices(from: state, backupManager: backupManager))
    }

    /// Builds the live services from a bring-up result, or nil if it failed.
    private static func buildServices(from state: PersistenceController.State,
                                      backupManager: BackupManager) -> AppServices? {
        guard case .ready(let container) = state else { return nil }
        let taskStore = TaskStore(context: container.mainContext)
        backupManager.liveContainer = container
        taskStore.backfillSortIndicesIfNeeded()
        backupManager.startAutoBackup()
        return AppServices(
            container: container,
            projectStore: ProjectStore(context: container.mainContext),
            taskStore: taskStore,
            reminderManager: ReminderManager())
    }

    var body: some Scene {
        WindowGroup {
            // Show the normal UI only when services were built. Otherwise recovery —
            // never force-unwrap into a crash.
            if let services {
                readyView(container: services.container,
                          projectStore: services.projectStore,
                          taskStore: services.taskStore,
                          reminderManager: services.reminderManager)
            } else {
                let reason: String = {
                    if case .failed(let r, _) = bringUp { return r }
                    return "The app couldn't finish starting up."
                }()
                RecoveryView(reason: reason,
                             backupManager: backupManager,
                             quarantined: PersistenceController.quarantinedStores(storeURL: storeURL),
                             onRetry: retryBringUp,
                             onStartFresh: startFresh,
                             onRestore: restoreFromBackup,
                             onRestoreQuarantined: restoreFromQuarantine,
                             onRestoreJSON: restoreFromJSON)
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
            CommandGroup(replacing: .help) {
                Button("What's New in Quillpoint") {
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .tint(settings.accent.color)
                .environment(\.appAccent, settings.accent.color)
        }
    }

    /// The normal app UI. Dependencies are passed in (unwrapped by the caller in
    /// `body`), so this never force-unwraps and can't crash on the failed path.
    @ViewBuilder
    private func readyView(container: ModelContainer,
                           projectStore: ProjectStore,
                           taskStore: TaskStore,
                           reminderManager: ReminderManager) -> some View {
        ContentView()
            .modelContainer(container)
            .environment(projectStore)
            .environment(taskStore)
            .environment(backupManager)
            .environment(reminderManager)
            .environment(settings)
            .tint(settings.accent.color)
            .environment(\.appAccent, settings.accent.color)
            .frame(minWidth: 720, minHeight: 480)
            .onAppear {
                setApplicationIcon()
                settings.applyAppearance()
                clearExpiredReminders()
                applyDefaultFilter()
                if WhatsNew.shouldPresent() { showWhatsNew = true }
            }
            .sheet(isPresented: $showWhatsNew, onDismiss: { WhatsNew.markSeen() }) {
                WhatsNewView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
                showWhatsNew = true
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

    /// "Try Again": re-attempts bring-up against the SAME (untouched) store. If it now
    /// succeeds, services are rebuilt and the normal UI appears. Safe to press
    /// repeatedly — nothing is moved or cleared, so a retry never loses data.
    private func retryBringUp() {
        let state = PersistenceController.bringUp(
            storeURL: storeURL,
            schema: QuillpointSchema.current,
            migrationPlan: QuillpointMigrationPlan.self,
            backupManager: backupManager)
        bringUp = state
        services = Self.buildServices(from: state, backupManager: backupManager)
    }

    /// "Restore from Backup" (recovery screen): replaces the unreadable store with the
    /// chosen backup on disk (the current store is set aside in Quarantine, not deleted),
    /// then re-runs bring-up so the restored store opens (migrating forward if older).
    private func restoreFromBackup(_ backup: Backup) {
        do {
            try backupManager.restoreFromFile(backup: backup)
        } catch {
            DiagnosticLog.shared.record("recovery-restore-failed", String(describing: error))
        }
        backupManager.refresh()
        retryBringUp()
    }

    /// "Restore" a previously set-aside (quarantined) store: swaps it back in as the
    /// live store (the current store is set aside first, so this too is reversible),
    /// then re-runs bring-up. This is what makes Start Fresh's "recoverable later"
    /// promise real — a quarantined store is restorable, not just sitting in a folder.
    private func restoreFromQuarantine(_ store: PersistenceController.QuarantinedStore) {
        do {
            try backupManager.restoreStoreFile(at: store.url)
        } catch {
            DiagnosticLog.shared.record("recovery-restore-quarantine-failed", String(describing: error))
        }
        backupManager.refresh()
        retryBringUp()
    }

    /// "Restore from JSON" (recovery screen): rebuilds the store from a JSON export.
    /// A JSON export is schema-independent (just projects and tasks as data), so it's a
    /// recovery path that survives store corruption a `.store` backup might share.
    ///
    /// Validates the file first (a bad file changes nothing), then sets the unreadable
    /// store aside (Quarantine, never deleted), brings up a FRESH empty store, and
    /// imports the file into it with `.replace`. If anything fails the store is left as
    /// it was and recovery stays on screen.
    private func restoreFromJSON() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = false
        open.title = "Restore from JSON Export"
        guard open.runModal() == .OK, let url = open.url else { return }

        guard let data = try? Data(contentsOf: url) else {
            return showImportError(DataExportManager.ImportError.unreadable)
        }
        // Validate BEFORE touching the store, so a bad file is a no-op.
        do { _ = try DataExportManager.validate(data) }
        catch { return showImportError(error) }

        // Set the unreadable store aside and bring up a clean empty one to import into.
        PersistenceController.startFresh(storeURL: storeURL)
        backupManager.refresh()
        retryBringUp()
        guard let container = services?.container else {
            // The fresh store didn't open — nothing was imported; recovery remains.
            return showImportError(DataExportManager.ImportError.unreadable)
        }

        do {
            try DataExportManager.importing(data, into: container.mainContext, mode: .replace)
        } catch {
            showImportError(error)
        }
    }

    /// "Start Fresh": an EXPLICIT, confirmed choice to set the unreadable store aside
    /// (moved to Quarantine, never deleted) and open a clean empty store. Only invoked
    /// from the recovery screen after the user confirms; never automatic.
    private func startFresh() {
        PersistenceController.startFresh(storeURL: storeURL)
        backupManager.refresh()
        retryBringUp() // now opens a fresh empty store
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
        guard let container = services?.container else { return }
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
        guard let container = services?.container else { return }
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
        guard let services else { return }
        let container = services.container
        let reminderManager = services.reminderManager
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
