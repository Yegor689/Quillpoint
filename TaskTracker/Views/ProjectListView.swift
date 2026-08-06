import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Environment(ProjectStore.self) private var projectStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Project.title) private var projects: [Project]

    @Binding var selection: SidebarSelection?
    @State private var isAddingProject = false
    @State private var newProjectTitle = ""
    @State private var newProjectDesc = ""
    @State private var projectToRename: Project?
    @State private var renameTitle = ""
    @State private var renameDesc = ""
    @State private var projectToDelete: Project?

    var body: some View {
        // A native List (not a custom ScrollView) so the sidebar reserves space
        // under the translucent title bar and content can't scroll up behind it.
        // Selection is driven entirely by the rows' own highlight + tap gestures;
        // the List itself has no `selection:` binding, so no native highlight is
        // drawn (that native highlight was the earlier "bleed" bug).
        List {
            SidebarLinkRow(title: "All Projects", systemImage: "tray.2", isSelected: selection == .all)
                .onTapGesture { selection = .all }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .listRowBackground(Color.clear)

            if settings.showUpcoming {
                SidebarLinkRow(title: "Upcoming", systemImage: "bell.badge", isSelected: selection == .upcoming)
                    .onTapGesture { selection = .upcoming }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .listRowBackground(Color.clear)
            }

            // A quiet header only over the projects group; the views above (All Projects /
            // Upcoming) stay unlabeled as the sidebar's "home" items. Report lives in the
            // toolbar instead, to keep the sidebar list uncluttered. Header shown only when
            // there ARE projects — the empty state is handled by the overlay.
            Section(projects.isEmpty ? "" : "Projects") {
                ForEach(projects) { project in
                    ProjectRowView(project: project, isSelected: selection == .project(project))
                        .onTapGesture { selection = .project(project) }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Rename") {
                                renameTitle = project.title
                                renameDesc = project.desc
                                projectToRename = project
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                projectToDelete = project
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Projects")
        // A gear pinned to the bottom of the sidebar opens the Settings window (⌘, still
        // works). macOS keeps Settings as a separate window per convention; this is just a
        // discoverable entry point, the way Things/Craft place a gear at the sidebar foot.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    try? openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .background(.bar)
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a project to start tracking tasks.")
                } actions: {
                    Button("New Project") { isAddingProject = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            // Report opens from the toolbar rather than a sidebar row, keeping the sidebar
            // list to just All Projects / Upcoming / your projects. The button highlights
            // when Report is the active view.
            ToolbarItem {
                Button { selection = .report } label: {
                    Label("Report", systemImage: "chart.bar.xaxis")
                }
                .help("Report")
                .foregroundStyle(selection == .report ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            ToolbarItem {
                Button { isAddingProject = true } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .help("New Project (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .confirmationDialog(
            "Delete \"\(projectToDelete?.title ?? "")\"?",
            isPresented: Binding(
                get: { projectToDelete != nil },
                set: { if !$0 { projectToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                guard let project = projectToDelete else { return }
                if selection == .project(project) { selection = .all }
                projectStore.deleteProject(project)
                projectToDelete = nil
            }
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: {
            Text("All tasks in this project will also be deleted. This cannot be undone.")
        }
        .sheet(isPresented: $isAddingProject) {
            ProjectFormSheet(heading: "New Project", title: $newProjectTitle, desc: $newProjectDesc) {
                projectStore.createProject(title: newProjectTitle, desc: newProjectDesc)
                newProjectTitle = ""
                newProjectDesc = ""
            }
        }
        .sheet(item: $projectToRename) { project in
            ProjectFormSheet(heading: "Rename Project", title: $renameTitle, desc: $renameDesc) {
                projectStore.updateProject(project, title: renameTitle, desc: renameDesc)
            }
        }
    }
}

/// A fixed top-level sidebar entry (All Projects, Report) — a labeled row with the
/// same selected/hover styling as the project rows.
private struct SidebarLinkRow: View {
    @Environment(\.appAccent) private var appAccent
    let title: String
    let systemImage: String
    var isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? appAccent : (isHovered ? Color.primary.opacity(0.07) : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private struct ProjectRowView: View {
    @Environment(\.appAccent) private var appAccent
    var project: Project
    var isSelected: Bool
    @State private var isHovered = false

    private var rootTasks: [Task] { project.tasks.filter { $0.parent == nil } }
    private var total: Int  { rootTasks.count }
    private var done: Int   { rootTasks.filter(\.isDone).count }
    private var pending: Int { total - done }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(project.title)
                    .fontWeight(.medium)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
                if pending > 0 {
                    Text("\(pending)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
            }
            if !project.desc.isEmpty {
                Text(project.desc)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : .secondary)
                    .lineLimit(1)
            }
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(done == total ? .green : (isSelected ? Color.white.opacity(0.9) : appAccent))
                    .animation(.easeInOut, value: done)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? appAccent : (isHovered ? Color.primary.opacity(0.07) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct ProjectFormSheet: View {
    let heading: String
    @Binding var title: String
    @Binding var desc: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text(heading).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .focused($titleFocused)
                TextField("Description (optional)", text: $desc)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear { titleFocused = true }
    }

    private func submit() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        title = trimmed
        onConfirm()
        dismiss()
    }
}
