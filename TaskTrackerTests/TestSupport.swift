import Testing
import Foundation
import SwiftData
@testable import Quillpoint

// Shared test scaffolding. Every test file used to hand-roll the same SwiftData
// container fixture (Schema([Project, Task]) → a unique on-disk .store → deinit
// cleanup) under three different names. This centralizes that in one place.
//
// On-disk stores (not isStoredInMemoryOnly): the in-memory variant SIGTRAPs on the
// current macOS/Xcode 27 beta when several same-schema containers exist in one test
// process. Each TestStore uses a unique temp URL and removes it on deinit.

/// An isolated SwiftData store for a test. Holds the container and cleans up its
/// on-disk file when it deallocates. Add a `TaskStore` via `taskStore` when needed.
@MainActor
final class TestStore {
    let container: ModelContainer
    let url: URL

    init(prefix: String = "TestStore") throws {
        let schema = Schema([Project.self, Task.self])
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).store")
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url))
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var context: ModelContext { container.mainContext }
}

// MARK: - Common seed

/// The pieces produced by `seedPersonalWork`, so tests can assert on any of them.
@MainActor
struct PersonalWorkSeed {
    let personal: Project
    let work: Project
    let clean: Task      // root task in Personal
    let vacuum: Task     // subtask of clean
    let dishes: Task     // subtask of clean
    let ship: Task       // root task in Work
}

/// Seeds the fixture used across several suites: a "Personal" project with a root
/// task "Clean" that has two subtasks ("Vacuum", "Dishes"), and a "Work" project
/// with one root task ("Ship"). Options cover the small per-suite variations so the
/// same seed serves them all.
///
/// - descriptions: give projects/tasks non-empty descriptions (DataExportTests needs
///   this to exercise the RTF/desc round-trip).
/// - completeDishes: mark the "Dishes" subtask done (DataExportTests asserts on a
///   completed item surviving export/import).
/// - save: flush the context after seeding.
@MainActor
@discardableResult
func seedPersonalWork(into ctx: ModelContext,
                      descriptions: Bool = false,
                      completeDishes: Bool = false,
                      save: Bool = false) throws -> PersonalWorkSeed {
    let personal = Project(title: "Personal", desc: descriptions ? "home" : "")
    let work = Project(title: "Work", desc: descriptions ? "job" : "")
    ctx.insert(personal); ctx.insert(work)

    let clean = Task(plainTitle: "Clean", plainDesc: descriptions ? "deep clean" : "",
                     priority: descriptions ? 0 : 1, project: personal)
    ctx.insert(clean); personal.tasks.append(clean)

    let vacuum = Task(plainTitle: "Vacuum", priority: 1, project: personal, parent: clean)
    let dishes = Task(plainTitle: "Dishes", priority: descriptions ? 2 : 1, project: personal, parent: clean)
    for (i, s) in [vacuum, dishes].enumerated() {
        ctx.insert(s); personal.tasks.append(s); clean.subtasks.append(s); s.sortIndex = i
    }
    if completeDishes { dishes.setDone(true) }

    let ship = Task(plainTitle: "Ship", project: work)
    ctx.insert(ship); work.tasks.append(ship)

    if save { try ctx.save() }
    return PersonalWorkSeed(personal: personal, work: work, clean: clean,
                            vacuum: vacuum, dishes: dishes, ship: ship)
}
