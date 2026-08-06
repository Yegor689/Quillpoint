import SwiftUI
import SwiftData

enum TaskGrouping: String, CaseIterable {
    case project  = "Project"
    case priority = "Priority"
}

struct AllTasksView: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(ReminderManager.self) private var reminderManager
    @Environment(AppSettings.self) private var settings
    @Environment(\.undoManager) private var undoManager
    @Query(sort: \Project.title) private var projects: [Project]
    @Binding var selection: SidebarSelection?

    @State private var path = NavigationPath()
    @AppStorage("taskFilter") private var filter: TaskFilter = .active
    @State private var searchText = ""
    @AppStorage("allTasksGrouping") private var grouping: TaskGrouping = .project
    @State private var focusedTaskID: UUID?
    @State private var taskPendingDelete: Task?

    var allTasks: [Task] {
        TaskListView.ordered(
            projects
                .flatMap { $0.tasks.filter { $0.parent == nil } }
                .filter { $0.matchesSearch(searchText) && filter.matches($0) }
        )
    }

    var groupedSections: [(header: String, tasks: [Task])] {
        // Completed tasks are pulled out of their project/priority group and
        // collected into a single "Completed" section at the very end of the list.
        let active = allTasks.filter { !$0.isDone }
        let done   = allTasks.filter {  $0.isDone }

        var sections: [(header: String, tasks: [Task])]
        switch grouping {
        case .project:
            sections = projects.compactMap { project in
                let tasks = active.filter { $0.project.id == project.id }
                guard !tasks.isEmpty else { return nil }
                return (header: project.title, tasks: tasks)
            }
        case .priority:
            sections = Priority.allCases.compactMap { level in
                let tasks = active.filter { $0.priorityLevel == level }
                guard !tasks.isEmpty else { return nil }
                return (header: level.label, tasks: tasks)
            }
        }

        if !done.isEmpty {
            sections.append((header: "Completed", tasks: done))
        }
        return sections
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // LazyVStack so large task lists only build the rows scrolled into view;
                // each row hosts a live NSTextView, so an eager VStack materialized them
                // all at once and made big lists slow (see TaskListView).
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedSections, id: \.header) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if section.header == "Completed" {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                } else if grouping == .priority,
                                   let level = Priority.allCases.first(where: { $0.label == section.header }) {
                                    Image(systemName: level.isAccented ? level.iconName : "circle")
                                        .foregroundStyle(level.isAccented ? level.color : .secondary)
                                        .font(.caption)
                                }
                                Text(section.header)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                Text("\(section.tasks.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)

                            ForEach(section.tasks) { task in
                                TaskRowView(
                                    task: task,
                                    isSubtask: false,
                                    focusedID: $focusedTaskID,
                                    onReturn:           { },
                                    onDeleteIfEmpty:    { deleteIfEmpty(task) },
                                    onDelete:           { taskStore.deleteTask(task) },
                                    onIndent:           { },
                                    onUnindent:         { },
                                    onNavigateUp:       { navigateTo(task, direction: -1) },
                                    onNavigateDown:     { navigateTo(task, direction: +1) },
                                    onNavigateDownFrom: { navigateTo($0, direction: +1) },
                                    navigate:           { t in path.append(t) },
                                    showProjectBadge:   grouping == .priority,
                                    subtaskFilter:      { filter.matches($0) }
                                )
                                .onTapGesture(count: 2) { path.append(task) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .navigationDestination(for: Task.self) { task in
                TaskDetailView(task: task)
            }
            .searchable(text: $searchText, prompt: "Search all tasks")
            .overlay {
                if allTasks.isEmpty {
                    if !searchText.isEmpty {
                        ContentUnavailableView {
                            Label("No Results", systemImage: "magnifyingglass")
                        } description: {
                            Text("No tasks match \"\(searchText)\".")
                        }
                    } else if filter != .all {
                        ContentUnavailableView {
                            Label("No \(filter.rawValue) Tasks", systemImage: "checklist")
                        }
                    } else {
                        ContentUnavailableView {
                            Label("No Tasks", systemImage: "checklist")
                        } description: {
                            Text("Add tasks to your projects to see them here.")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ProjectTitleMenu(selection: $selection)
                }
                // Group the controls on the trailing side (before search), the way native
                // macOS apps lay out toolbars — title leading, controls trailing — rather
                // than centering a segmented control, which leaves awkward gaps on a wide
                // window. ToolbarItemGroup keeps them together as one cluster.
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Filter", selection: $filter) {
                        ForEach(TaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    Picker("Group By", selection: $grouping) {
                        ForEach(TaskGrouping.allCases, id: \.self) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .help("Group by")
                }
            }
        }
        .wireTaskStore(taskStore, undoManager: undoManager, reminderManager: reminderManager)
        .deleteConfirmation(pending: $taskPendingDelete) { taskStore.deleteTask($0) }
    }

    private func deleteIfEmpty(_ task: Task) {
        // Confirm deletion of a task with subtasks, unless the user turned that off.
        if settings.confirmDeletion(of: task) {
            taskPendingDelete = task
            return
        }
        taskStore.deleteTask(task)
    }

    private func navigateTo(_ task: Task, direction: Int) {
        let flat = groupedSections.flatMap { $0.tasks }.flatMap { [$0] + $0.subtasks.sorted { $0.sortIndex < $1.sortIndex } }
        guard let idx = flat.firstIndex(where: { $0.id == task.id }) else { return }
        let next = idx + direction
        guard next >= 0 && next < flat.count else { return }
        focusedTaskID = flat[next].id
    }
}
