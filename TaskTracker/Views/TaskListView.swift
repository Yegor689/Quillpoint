import SwiftUI
import SwiftData
import AppKit


enum TaskFilter: String, CaseIterable {
    case all    = "All"
    case active = "Active"
    case done   = "Done"

    func matches(_ task: Task) -> Bool {
        switch self {
        case .all:    return true
        case .active: return !task.isDone
        case .done:   return task.isDone
        }
    }
}

extension Task {
    /// True if this task matches a (possibly empty) search query by title or description.
    func matchesSearch(_ query: String) -> Bool {
        query.isEmpty
            || plainTitle.localizedCaseInsensitiveContains(query)
            || plainDesc.localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Task List

struct TaskListView: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(ReminderManager.self) private var reminderManager
    @Environment(AppSettings.self) private var settings
    @Environment(\.undoManager) private var undoManager
    @Environment(\.appAccent) private var appAccent
    var project: Project
    @Binding var selection: SidebarSelection?

    @State private var path = NavigationPath()
    @State private var focusedTaskID: UUID?
    @AppStorage("taskFilter") private var filter: TaskFilter = .active
    @State private var searchText = ""
    @State private var taskPendingDelete: Task?

    // Custom drag-to-reorder engine (state + logic live in TaskDragController).
    @State private var drag = TaskDragController()

    // Flat ordered list: each root task followed by its visible subtasks.
    var flatTasks: [Task] {
        filteredTasks.flatMap { task -> [Task] in
            let subs = task.subtasks.sorted(by: Self.taskOrder).filter { filter.matches($0) }
            return [task] + subs
        }
    }

    var filteredTasks: [Task] {
        project.tasks
            .filter { $0.parent == nil && $0.matchesSearch(searchText) && filter.matches($0) }
            .sorted(by: Self.taskOrder)
    }

    /// Dragging is only meaningful when the list shows its natural manual order
    /// (no search, and not the Done-only filter where order is by completion).
    private var dragEnabled: Bool {
        searchText.isEmpty && (filter == .all || filter == .active)
    }

    /// Ordering shared by the list: incomplete tasks first in their manual
    /// (sortIndex) order, then completed tasks grouped at the bottom with the
    /// most recently completed on top. `nonisolated` — it's a pure comparator over
    /// model values, so it can be passed to `sorted(by:)` without main-actor
    /// isolation warnings.
    nonisolated static func taskOrder(_ lhs: Task, _ rhs: Task) -> Bool {
        if lhs.isDone != rhs.isDone { return !lhs.isDone }
        if lhs.isDone {
            // Both done: newest completion first (on top of the done group).
            let l = lhs.completedAt ?? lhs.createdAt
            let r = rhs.completedAt ?? rhs.createdAt
            return l > r
        }
        // Incomplete: manual order. (Priority no longer forces position now that
        // tasks can be dragged; the priority accent still marks them visually.)
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        return lhs.createdAt < rhs.createdAt
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredTasks) { task in
                        TaskRowView(
                            task: task,
                            isSubtask: false,
                            focusedID: $focusedTaskID,
                            onReturn:           { addTaskAfter(task) },
                            onReturnAtStart:    { addTaskBefore(task) },
                            onDeleteIfEmpty:    { deleteIfEmpty(task) },
                            onDelete:           { taskStore.deleteTask(task) },
                            onIndent:           { indentTask(task) },
                            onUnindent:         { },
                            onNavigateUp:       { navigateTo(task, direction: -1) },
                            onNavigateDown:     { navigateTo(task, direction: +1) },
                            onNavigateDownFrom: { navigateTo($0, direction: +1) },
                            navigate:           { t in path.append(t) },
                            dragGesture:        dragEnabled ? drag.rootGesture(for: task, roots: { filteredTasks }, store: taskStore, project: project) : nil,
                            dragContext:        DragContext(
                                draggingTaskID: drag.draggingTaskID,
                                dragOffset: drag.dragOffset,
                                promoteTargetID: drag.promoteTargetID,
                                coordinateSpace: TaskDragController.coordinateSpace,
                                subtaskGesture: { parent, sub in
                                    dragEnabled ? drag.subtaskGesture(for: sub, parent: parent, store: taskStore) : nil
                                }
                            ),
                            subtaskFilter: { filter.matches($0) }
                        )
                        .overlay {
                            // Highlight the row the dragged task would nest under.
                            if drag.nestTargetID == task.id {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(appAccent, lineWidth: 2)
                            }
                        }
                        .offset(
                            x: (drag.draggingTaskID == task.id && drag.nestTargetID != nil) ? 20 : 0,
                            y: drag.draggingTaskID == task.id ? drag.dragOffset : 0
                        )
                        .zIndex(drag.draggingTaskID == task.id ? 1 : 0)
                        // Non-dragged rows slide smoothly into new slots; the dragged
                        // row tracks the cursor without animation lag.
                        .animation(drag.draggingTaskID == task.id ? nil : .spring(duration: 0.25),
                                   value: filteredTasks.map(\.id))
                        .onTapGesture(count: 2) { path.append(task) }
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: RowMidYKey.self,
                                    value: [task.id: geo.frame(in: .named(TaskDragController.coordinateSpace)).midY]
                                )
                            }
                        )
                    }

                    if filter != .done && searchText.isEmpty {
                        NewItemButton { addTask() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .coordinateSpace(name: TaskDragController.coordinateSpace)
                .onPreferenceChange(RowMidYKey.self) { drag.rowMidYs = $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TaskStatsFooter(tasks: project.tasks, filter: filter)
            }
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .navigationDestination(for: Task.self) { task in
                TaskDetailView(task: task)
            }
            .searchable(text: $searchText, prompt: "Search tasks")
            .overlay {
                if filteredTasks.isEmpty {
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
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ProjectTitleMenu(selection: $selection)
                }
                ToolbarItem(placement: .principal) {
                    Picker("Filter", selection: $filter) {
                        ForEach(TaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                ToolbarItem {
                    Button { addTask() } label: {
                        Label("Add Task", systemImage: "plus")
                    }
                    .help("New Item (⌘N)")
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        .deleteConfirmation(pending: $taskPendingDelete) { performDelete($0) }
        .onChange(of: project.id) {
            path = NavigationPath()
            focusedTaskID = nil
        }
        .wireTaskStore(taskStore, undoManager: undoManager, reminderManager: reminderManager)
    }

    private func addTask() {
        let task = taskStore.addTask(priority: settings.defaultPriority, to: project)
        if filter == .done { filter = .active }
        focus(task.id)
    }

    private func addTaskAfter(_ task: Task) {
        // New tasks use the configured default priority — they don't inherit the
        // priority of the task they were created after.
        let newTask = taskStore.addTask(priority: settings.defaultPriority, to: project, after: task)
        focus(newTask.id)
    }

    /// Enter at the start of a task's title: insert a new empty task before it.
    private func addTaskBefore(_ task: Task) {
        let newTask = taskStore.addTask(priority: settings.defaultPriority, to: project, before: task)
        focus(newTask.id)
    }

    private func indentTask(_ task: Task) {
        // Subtasks only nest one level deep; indenting a task that already has
        // subtasks would hide those grandchildren, so disallow it.
        guard task.subtasks.isEmpty else { return }
        let roots = filteredTasks
        guard let idx = roots.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
        taskStore.indentTask(task, previousTask: roots[idx - 1])
        focus(task.id)
    }

    private func deleteIfEmpty(_ task: Task) {
        // Confirm deletion of a task with subtasks, unless the user turned that off.
        if settings.confirmDeletion(of: task) {
            taskPendingDelete = task
            return
        }
        performDelete(task)
    }

    private func performDelete(_ task: Task) {
        let tasks = filteredTasks
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            let prevID = idx > 0 ? tasks[idx - 1].id : nil
            taskStore.deleteTask(task)
            DispatchQueue.main.async { focusedTaskID = prevID }
        }
    }

    private func focus(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedTaskID = id }
    }

    private func navigateTo(_ task: Task, direction: Int) {
        let flat = flatTasks
        guard let idx = flat.firstIndex(where: { $0.id == task.id }) else { return }
        let next = idx + direction
        guard next >= 0 && next < flat.count else { return }
        focusedTaskID = flat[next].id
    }
}

// MARK: - Task Row (root + subtask, unified)

struct TaskRowView: View {
    @Bindable var task: Task
    var isSubtask: Bool
    @Environment(TaskStore.self) private var taskStore
    @Query(sort: \Project.title) private var projects: [Project]
    @Binding var focusedID: UUID?
    var onReturn:        () -> Void
    var onReturnAtStart: () -> Void = {}
    var onDeleteIfEmpty: () -> Void
    var onDelete:        () -> Void
    var onIndent:        () -> Void
    var onUnindent:      () -> Void
    var onNavigateUp:       () -> Void
    var onNavigateDown:     () -> Void
    var onNavigateDownFrom: (Task) -> Void
    var navigate:           (Task) -> Void
    /// Drag-to-reorder gesture, attached to the bullet. Nil = not draggable.
    var dragGesture: AnyGesture<Void>? = nil
    /// Shared drag context so subtask rows can take part in dragging too.
    var dragContext: DragContext? = nil
    /// When set, shows a small pill with the task's project name (used in the
    /// All Projects view when grouped by priority, where project context is lost).
    var showProjectBadge: Bool = false
    /// Which subtasks to display, so subtask rows honor the active list filter the
    /// same way root tasks do (e.g. the Active filter hides completed subtasks).
    /// Defaults to showing every subtask.
    var subtaskFilter: (Task) -> Bool = { _ in true }

    @Environment(ReminderManager.self) private var reminderManager
    @Environment(\.appAccent) private var appAccent
    @State private var isHovered = false
    @State private var showReminderPopover = false

    private var isFocused: Bool { focusedID == task.id }
    private var subtaskFocused: Bool { sortedSubtasks.contains { $0.id == focusedID } }
    private var anyFocused: Bool     { isFocused || subtaskFocused }
    // Same ordering as root tasks: manual order, with completed subtasks sunk to the
    // bottom (newest completion on top of the done group), filtered to those the
    // current list filter shows.
    private var sortedSubtasks: [Task] {
        task.subtasks.filter(subtaskFilter).sorted(by: TaskListView.taskOrder)
    }

    private var iconSize: CGFloat  { isSubtask ? 18 : 22 }
    private var titleFont: NSFont  { isSubtask ? .preferredFont(forTextStyle: .body) : .preferredFont(forTextStyle: .title3) }
    // Match the title field's frame to the font's natural line height so the text
    // fills it exactly (no vertical slack for the top-aligned glyphs to float in).
    private var lineHeight: CGFloat { ceil(titleFont.ascender - titleFont.descender + titleFont.leading) }
    private var infoSize: CGFloat  { isSubtask ? 13 : 15 }

    private var rowFill: Color {
        if isFocused { return Color.primary.opacity(0.06) }
        if isHovered { return Color.primary.opacity(0.035) }
        return .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .trailing) {
                HStack(alignment: .top, spacing: isSubtask ? 8 : 10) {
                    // The bullet doubles as the reorder handle. It's not a Button so
                    // the drag and tap don't conflict: a tap toggles done, a drag
                    // (≥4pt) reorders/nests and suppresses the toggle.
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isDone ? .green : (task.priorityLevel.isAccented ? task.priorityLevel.color : .secondary))
                        .font(.system(size: iconSize))
                        .frame(height: lineHeight)
                        .opacity(task.isDrivenBySubtasks ? 0.5 : 1) // dimmed: state is derived
                        .contentShape(Rectangle())
                        .modifier(BulletGestureModifier(
                            dragGesture: dragGesture,
                            onTap: { toggleCompletion() }
                        ))

                    VStack(alignment: .leading, spacing: 1) {
                        RichTitleField(
                            rtf: $task.titleRTF,
                            font: titleFont,
                            isFocused: isFocused,
                            isDone: task.isDone,
                            onFocus:         { focusedID = task.id },
                            onReturn:        onReturn,
                            onReturnAtStart: onReturnAtStart,
                            onDeleteIfEmpty: onDeleteIfEmpty,
                            onBlurIfEmpty:   onDeleteIfEmpty,
                            onTab:           onIndent,
                            onShiftTab:      onUnindent,
                            onNavigateUp:    onNavigateUp,
                            onNavigateDown:  onNavigateDown,
                            onCommit:        { taskStore.save() }
                        )
                        .frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .leading)

                        if !task.plainDesc.isEmpty {
                            Text(task.plainDesc)
                                .font(isSubtask ? .caption : .callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if showProjectBadge {
                            Label(task.project.title, systemImage: "folder")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                .padding(.top, 2)
                        }
                    }

                    if isHovered || anyFocused || showReminderPopover {
                        Spacer(minLength: 40)
                    }
                }

                if isHovered || anyFocused || showReminderPopover {
                    HStack(spacing: 4) {
                        Menu {
                            ForEach(Priority.allCases) { level in
                                Button {
                                    withAnimation(.spring(duration: 0.2)) { task.priorityLevel = level }
                                } label: {
                                    Label(level.label, systemImage: task.priorityLevel == level ? "checkmark" : level.iconName)
                                }
                            }
                        } label: {
                            Image(systemName: task.priorityLevel.iconName)
                                .foregroundStyle(task.priorityLevel.isAccented ? task.priorityLevel.color : Color.secondary.opacity(0.4))
                                .font(.system(size: infoSize))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Priority: \(task.priorityLevel.label)")

                        Divider().frame(height: infoSize)

                        Button { showReminderPopover = true } label: {
                            Image(systemName: task.reminderDate != nil ? "bell.fill" : "bell")
                                .foregroundStyle(task.reminderDate != nil ? appAccent : Color.secondary.opacity(0.4))
                                .font(.system(size: infoSize))
                        }
                        .buttonStyle(.plain)
                        .help(task.reminderDate != nil ? "Edit Reminder" : "Set Reminder")
                        .popover(isPresented: $showReminderPopover, arrowEdge: .bottom) {
                            ReminderPopover(task: task, reminderManager: reminderManager)
                        }

                        Divider().frame(height: infoSize)

                        Button { navigate(task) } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: infoSize))
                        }
                        .buttonStyle(.plain)
                        .help("Open Properties")
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.1)))
                }
            }
            .padding(.vertical, isSubtask ? 5 : 7)
            .padding(.horizontal, isSubtask ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowFill)
            )
            .overlay(alignment: .leading) {
                // Accent bar marking non-normal, not-yet-done tasks, colored by level.
                if task.priorityLevel.isAccented && !task.isDone {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(task.priorityLevel.color)
                        .frame(width: 3)
                        .padding(.vertical, isSubtask ? 4 : 5)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)

            if !isSubtask && !sortedSubtasks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedSubtasks) { subtask in
                        TaskRowView(
                            task: subtask,
                            isSubtask: true,
                            focusedID: $focusedID,
                            onReturn:           { addSubtaskAfter(subtask) },
                            onReturnAtStart:    { addSubtaskBefore(subtask) },
                            onDeleteIfEmpty:    { deleteSubtaskIfEmpty(subtask) },
                            onDelete:           { taskStore.deleteTask(subtask) },
                            onIndent:           { },
                            onUnindent:         { unindent(subtask) },
                            onNavigateUp:       { navigateSubtask(subtask, direction: -1) },
                            onNavigateDown:     { navigateSubtask(subtask, direction: +1) },
                            onNavigateDownFrom: { _ in navigateSubtask(subtask, direction: +1) },
                            navigate:           navigate,
                            dragGesture:        dragContext?.subtaskGesture(task, subtask)
                        )
                        // Promote highlight: dragged left to become a root task.
                        .overlay(alignment: .leading) {
                            if dragContext?.promoteTargetID == subtask.id {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(appAccent, lineWidth: 2)
                            }
                        }
                        .offset(
                            x: (dragContext?.draggingTaskID == subtask.id && dragContext?.promoteTargetID != nil) ? -20 : 0,
                            y: dragContext?.draggingTaskID == subtask.id ? (dragContext?.dragOffset ?? 0) : 0
                        )
                        .zIndex(dragContext?.draggingTaskID == subtask.id ? 1 : 0)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: RowMidYKey.self,
                                    value: [subtask.id: geo.frame(in: .named(dragContext?.coordinateSpace ?? "")).midY]
                                )
                            }
                        )
                    }
                }
                .padding(.leading, 26)
            }
        }
        .contextMenu {
            Button("Open Properties") { navigate(task) }
            Divider()
            Picker("Priority", selection: $task.priorityLevel) {
                ForEach(Priority.allCases) { level in
                    Label(level.label, systemImage: level.iconName).tag(level)
                }
            }
            // Only root tasks move between projects; subtasks follow their parent.
            if !isSubtask {
                let destinations = projects.filter { $0.id != task.project.id }
                if !destinations.isEmpty {
                    Menu("Move to") {
                        ForEach(destinations) { project in
                            Button(project.title) { taskStore.moveTask(task, to: project) }
                        }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .onHover { isHovered = $0 }
    }

    /// Bullet tap. A parent with subtasks has its completion driven by them, so its
    /// own bullet is a no-op. A subtask toggles itself, then re-derives its parent's
    /// completion (completing the last subtask completes the parent; reopening one
    /// reopens it).
    private func toggleCompletion() {
        guard !task.isDrivenBySubtasks else { return }
        withAnimation(.spring(duration: 0.25)) {
            task.toggleDone()
            task.parent?.syncDoneWithSubtasks()
        }
    }

    private func addSubtaskAfter(_ subtask: Task) {
        let sub = taskStore.addSubtask(to: task, after: subtask)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.focusedID = sub.id
        }
    }

    private func addSubtaskBefore(_ subtask: Task) {
        let sub = taskStore.addSubtask(to: task, before: subtask)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.focusedID = sub.id
        }
    }

    private func deleteSubtaskIfEmpty(_ subtask: Task) {
        let subs = sortedSubtasks
        if let idx = subs.firstIndex(where: { $0.id == subtask.id }) {
            let prevID: UUID? = idx > 0 ? subs[idx - 1].id : task.id
            taskStore.deleteTask(subtask)
            DispatchQueue.main.async { self.focusedID = prevID }
        }
    }

    private func unindent(_ subtask: Task) {
        taskStore.unindentTask(subtask)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.focusedID = subtask.id
        }
    }

    // Flat list for this parent: [parent] + sortedSubtasks.
    // `next == 0` lands on the parent task itself; that's handled by flat[0].
    private func navigateSubtask(_ subtask: Task, direction: Int) {
        let flat: [Task] = [task] + sortedSubtasks
        guard let idx = flat.firstIndex(where: { $0.id == subtask.id }) else { return }
        let next = idx + direction
        if next >= 0 && next < flat.count {
            // next == 0 selects the parent task
            focusedID = flat[next].id
        } else {
            // Below last subtask — navigate from the subtask's position in the full flat list
            onNavigateDownFrom(subtask)
        }
    }
}

// MARK: - Stats Footer

private struct TaskStatsFooter: View {
    @Environment(\.appAccent) private var appAccent
    var tasks: [Task]
    var filter: TaskFilter

    // Always show whole-project stats so numbers are stable regardless of filter
    private var allTasks: [Task]  { tasks + tasks.flatMap(\.subtasks) }
    private var total:    Int     { allTasks.count }
    private var done:     Int     { allTasks.filter(\.isDone).count }
    private var critical: Int     { allTasks.filter { $0.priorityLevel == .critical && !$0.isDone }.count }

    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    var body: some View {
        if total > 0 {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: done == total ? "checkmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(done == total ? .green : .secondary)
                        Text("\(done) / \(total) done")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    // Compact progress track
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        GeometryReader { geo in
                            Capsule()
                                .fill(done == total ? Color.green : appAccent)
                                .frame(width: max(0, geo.size.width * fraction))
                        }
                    }
                    .frame(width: 120, height: 5)
                    .animation(.easeInOut, value: fraction)

                    if critical > 0 {
                        Label("\(critical) critical", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red.opacity(0.8))
                    }

                    Spacer()

                    if done == total {
                        Label("All done", systemImage: "party.popper.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
            }
            .background(.bar)
        }
    }
}

// MARK: - New Item Button

private struct NewItemButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(isHovered ? .primary : .tertiary)
                    .font(.system(size: 16))
                Text("New item")
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
                    .font(.body)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Store wiring

private struct WireTaskStore: ViewModifier {
    let taskStore: TaskStore
    let undoManager: UndoManager?
    let reminderManager: ReminderManager

    func body(content: Content) -> some View {
        content
            .onAppear {
                taskStore.undoManager = undoManager
                taskStore.reminderManager = reminderManager
            }
            .onChange(of: undoManager) { taskStore.undoManager = undoManager }
    }
}

extension View {
    /// Wires the environment's UndoManager and the ReminderManager into the shared
    /// TaskStore. Used by the task list views that mutate tasks.
    func wireTaskStore(_ store: TaskStore, undoManager: UndoManager?, reminderManager: ReminderManager) -> some View {
        modifier(WireTaskStore(taskStore: store, undoManager: undoManager, reminderManager: reminderManager))
    }
}

// MARK: - Delete confirmation

/// Owns the "Delete Task?" confirmation alert shared by the task list views, so
/// the alert markup and the `confirmBeforeDelete` policy live in one place
/// instead of being copied (and drifting) between views.
private struct DeleteConfirmation: ViewModifier {
    @Binding var pending: Task?
    let onConfirm: (Task) -> Void

    func body(content: Content) -> some View {
        content.alert("Delete Task?", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let task = pending { pending = nil; onConfirm(task) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let task = pending {
                Text("\"\(task.plainTitle)\" has \(task.subtasks.count) subtask\(task.subtasks.count == 1 ? "" : "s") that will also be deleted.")
            }
        }
    }
}

extension View {
    /// Presents the shared delete-confirmation alert, calling `onConfirm` when the
    /// user confirms. Callers gate which tasks reach `pending` via `confirmDeletion`.
    func deleteConfirmation(pending: Binding<Task?>, onConfirm: @escaping (Task) -> Void) -> some View {
        modifier(DeleteConfirmation(pending: pending, onConfirm: onConfirm))
    }
}

extension AppSettings {
    /// Whether deleting `task` should be confirmed first: only tasks with subtasks,
    /// and only when the user hasn't turned confirmation off. The single source of
    /// truth for the delete-confirmation policy, shared by the task list views.
    func confirmDeletion(of task: Task) -> Bool {
        !task.subtasks.isEmpty && confirmBeforeDelete
    }
}
