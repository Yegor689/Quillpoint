import SwiftUI
import SwiftData

// A clickable title that drops down a menu of all projects (plus All Projects),
// letting you switch projects without the sidebar visible.
struct ProjectTitleMenu: View {
    @Query(sort: \Project.title) private var projects: [Project]
    @Binding var selection: SidebarSelection?

    private var currentTitle: String {
        switch selection {
        case .project(let p): return p.title
        case .all:            return "All Projects"
        case .upcoming:       return "Upcoming"
        case .report:         return "Report"
        case nil:             return "Quillpoint"
        }
    }

    private var isAll: Bool {
        if case .all = selection { return true }
        return false
    }

    var body: some View {
        Menu {
            Button {
                selection = .all
            } label: {
                Label("All Projects", systemImage: isAll ? "checkmark" : "tray.2")
            }

            if !projects.isEmpty {
                Divider()
                ForEach(projects) { project in
                    Button {
                        selection = .project(project)
                    } label: {
                        if isCurrent(project) {
                            Label(project.title, systemImage: "checkmark")
                        } else {
                            Text(project.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentTitle)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func isCurrent(_ project: Project) -> Bool {
        if case .project(let p) = selection { return p.id == project.id }
        return false
    }
}
