import SwiftUI
import SwiftData

enum SidebarSelection: Hashable {
    case all
    case upcoming
    case report
    case project(Project)
}

extension Notification.Name {
    /// Posted by the app menu's "Backups…" command to open the Backups sheet.
    static let showBackups = Notification.Name("showBackups")
    /// Posted by the Help menu's "What's New" command to reopen that screen.
    static let showWhatsNew = Notification.Name("showWhatsNew")
}

struct ContentView: View {
    @Query(sort: \Project.title) private var projects: [Project]
    @Environment(BackupManager.self) private var backupManager
    @Environment(AppSettings.self) private var settings
    @State private var selection: SidebarSelection?
    @State private var showBackup = false
    // Persisted sidebar selection: "all", or a project UUID string.
    @AppStorage("sidebarSelection") private var savedSelection = ""

    var body: some View {
        NavigationSplitView {
            ProjectListView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            detailPane
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .reminderToast()
        .sheet(isPresented: $showBackup) {
            BackupView()
                .environment(backupManager)
        }
        // Opened from the app menu's "Backups…" command.
        .onReceive(NotificationCenter.default.publisher(for: .showBackups)) { _ in
            showBackup = true
        }
        .onAppear {
            if selection == nil {
                selection = initialSelection()
            }
        }
        .onChange(of: selection) { persistSelection() }
    }

    /// The detail pane for the current sidebar selection.
    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .all:
            AllTasksView(selection: $selection)
        case .upcoming:
            UpcomingView(selection: $selection)
        case .report:
            ReportView()
        case .project(let project):
            // Resolve the selection against the LIVE query results by id. A restore
            // deletes and recreates every project, so `project` here can be a deleted
            // instance (same id, new object) — rendering it shows an empty list until
            // the user reselects. Re-resolve to the current instance, or fall back if
            // it's genuinely gone, so the view recovers immediately after a restore.
            if let live = projects.first(where: { $0.id == project.id }) {
                TaskListView(project: live, selection: $selection)
            } else {
                ContentUnavailableView("Select a Project", systemImage: "folder")
                    .task { selection = projects.first.map { .project($0) } ?? .all }
            }
        case nil:
            ContentUnavailableView("Select a Project", systemImage: "folder")
        }
    }

    /// The view to open on a fresh launch. An explicit landing preference (All Projects /
    /// Upcoming) wins; otherwise restore the last-used project if that's enabled, else All.
    private func initialSelection() -> SidebarSelection {
        switch settings.defaultLandingRaw {
        case "all":      return .all
        case "upcoming": return .upcoming
        default:
            if settings.restoreLastProject {
                return restoredSelection() ?? projects.first.map { .project($0) } ?? .all
            }
            return .all
        }
    }

    /// Resolves the persisted selection string back into a SidebarSelection,
    /// or nil if it can't be matched (e.g. the project was deleted).
    private func restoredSelection() -> SidebarSelection? {
        if savedSelection == "all" { return .all }
        if savedSelection == "upcoming" { return .upcoming }
        if savedSelection == "report" { return .report }
        guard let uuid = UUID(uuidString: savedSelection),
              let project = projects.first(where: { $0.id == uuid }) else { return nil }
        return .project(project)
    }

    private func persistSelection() {
        switch selection {
        case .all:                   savedSelection = "all"
        case .upcoming:              savedSelection = "upcoming"
        case .report:                savedSelection = "report"
        case .project(let project):  savedSelection = project.id.uuidString
        case nil:                    break
        }
    }
}
