import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// Verifies that nested subtasks created by the JSON-import path SURVIVE a save +
/// store reopen — i.e. the `project.tasks.append` / `parent.subtasks.append` double-write
/// in DataExportManager.insert (alongside setting the to-one side) does NOT leave the
/// relationship in a state that loads back flat, the way the old indentTask double-write
/// did. Uses the sequential-container pattern (close one, open another at the same URL)
/// that the migration tests use to avoid the beta's two-live-containers SIGTRAP.
@MainActor
struct RelationshipPersistenceTests {

    private func makeDoc() -> Data {
        // One project, one root task with two nested subtasks.
        let json = """
        {
          "app": "Quillpoint",
          "formatVersion": 1,
          "exportedAt": "2026-01-01T00:00:00.000Z",
          "projects": [{
            "id": "\(UUID().uuidString)",
            "title": "Imported",
            "desc": "",
            "createdAt": "2026-01-01T00:00:00.000Z",
            "tasks": [{
              "id": "\(UUID().uuidString)",
              "title": "Parent task",
              "titleRTF": "",
              "notes": "",
              "notesRTF": "",
              "isDone": false,
              "priority": 1,
              "createdAt": "2026-01-01T00:00:00.000Z",
              "sortIndex": 0,
              "completedAt": null,
              "reminderDate": null,
              "subtasks": [
                {"id": "\(UUID().uuidString)", "title": "Child one", "titleRTF": "", "notes": "", "notesRTF": "", "isDone": false, "priority": 1, "createdAt": "2026-01-01T00:01:00.000Z", "sortIndex": 0, "completedAt": null, "reminderDate": null, "subtasks": []},
                {"id": "\(UUID().uuidString)", "title": "Child two", "titleRTF": "", "notes": "", "notesRTF": "", "isDone": false, "priority": 1, "createdAt": "2026-01-01T00:02:00.000Z", "sortIndex": 1, "completedAt": null, "reminderDate": null, "subtasks": []}
              ]
            }]
          }]
        }
        """
        return Data(json.utf8)
    }

    @Test func importedNestingSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelPersist-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema([Project.self, Task.self])

        // Import into a fresh store, then let the container deallocate (do-scope).
        do {
            let c = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            try DataExportManager.importing(makeDoc(), into: c.mainContext, mode: .replace)
            try c.mainContext.save()
        }

        // Reopen the SAME store in a new container and inspect what actually persisted.
        let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let ctx = reopened.mainContext
        let allTasks = try ctx.fetch(FetchDescriptor<Task>())

        #expect(allTasks.count == 3, "expected parent + 2 subtasks, got \(allTasks.count)")

        let roots = allTasks.filter { $0.parent == nil }
        let children = allTasks.filter { $0.parent != nil }

        // The core assertion: after reopen, exactly ONE root and TWO children whose parent
        // is that root. If the double-write corrupted the relationship, children would load
        // as roots (roots.count == 3, children.count == 0) — the indentTask bug.
        #expect(roots.count == 1, "expected 1 root after reopen, got \(roots.count) — nesting was lost")
        #expect(children.count == 2, "expected 2 nested children after reopen, got \(children.count)")
        if let parent = roots.first {
            #expect(parent.subtasks.count == 2, "parent.subtasks should hydrate to 2, got \(parent.subtasks.count)")
            #expect(children.allSatisfy { $0.parent?.id == parent.id }, "children should point back at the one root")
        }
    }
}
