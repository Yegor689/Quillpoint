import Foundation
import SwiftData

/// Exports all user data (projects, tasks, subtasks) to a single JSON document so
/// users can keep their own portable copy or move it elsewhere. Unlike a .store
/// backup this is human-readable and tool-agnostic. Rich text is exported both as
/// plain text (readable) and as the raw RTF in base64 (lossless), so the file
/// preserves everything without depending on SwiftData/SQLite internals.
///
/// This type handles serialization and merge/replace orchestration only; the
/// knowledge of which fields a Task/Project has lives on the models themselves
/// (see Model+Export.swift) so there's one place to update when a field is added.
enum DataExportManager {

    /// ISO8601 WITH fractional seconds, used for both encoding and decoding so dates
    /// round-trip to the exact same value. Plain `.iso8601` truncates to whole
    /// seconds, which made a re-imported task's createdAt differ by sub-second and
    /// look "new", breaking merge idempotency.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var dateEncoding: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
    }

    private static var dateDecoding: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = isoFormatter.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Invalid ISO8601 date: \(s)"))
            }
            return date
        }
    }

    enum ImportMode { case merge, replace }

    enum ImportError: LocalizedError {
        case unreadable
        case malformed(String)
        /// The pre-import safety backup couldn't be written, so the import was abandoned
        /// rather than changing data the user has no way back from.
        case safetyBackupFailed
        var errorDescription: String? {
            switch self {
            case .unreadable:        return "The file could not be read."
            case .malformed(let d):  return "The file isn't a valid Quillpoint export.\n\(d)"
            case .safetyBackupFailed:
                return "Couldn't create a backup before importing, so nothing was changed. "
                     + "Your current data is untouched. Check that there's enough free disk space and try again."
            }
        }
    }

    // MARK: - Encoding

    /// Builds the pretty-printed JSON for everything in the store. Read-only: it
    /// only fetches and encodes, never mutates.
    @MainActor
    static func json(from context: ModelContext) throws -> Data {
        // Fetch unsorted, then sort in Swift. A keypath SortDescriptor inside the
        // FetchDescriptor traps on this toolchain; ordering here avoids that and the
        // export order isn't load-bearing anyway.
        let fetched = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let projects = fetched.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        let document = ExportDocument(exportedAt: Date(), projects: projects.map { $0.exportDTO() })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = dateEncoding
        return try encoder.encode(document)
    }

    // MARK: - Import

    /// Decodes and validates a JSON export. Throws ImportError on a bad file and
    /// does NOT touch any data — call this first so a malformed file is rejected
    /// before anything is changed. Returns the number of projects/tasks for a
    /// confirmation prompt.
    static func validate(_ data: Data) throws -> (projects: Int, tasks: Int) {
        let doc = try decode(data)
        func count(_ tasks: [TaskDTO]) -> Int { tasks.reduce(0) { $0 + 1 + count($1.subtasks) } }
        let taskCount = doc.projects.reduce(0) { $0 + count($1.tasks) }
        return (doc.projects.count, taskCount)
    }

    /// Applies a validated import into `context`. In `.replace` mode the caller is
    /// responsible for having taken a safety backup first; this wipes all existing
    /// projects/tasks. In `.merge` mode imported items are added alongside existing
    /// data, skipping any that already exist. Saves on success.
    @MainActor
    static func importing(_ data: Data, into context: ModelContext, mode: ImportMode) throws {
        let doc = try decode(data)

        switch mode {
        case .replace:
            for project in (try? context.fetch(FetchDescriptor<Project>())) ?? [] {
                context.delete(project) // cascade removes its tasks
            }
            // Empty store: recreate verbatim, keeping the file's ids.
            for pdto in doc.projects {
                let project = Project(fromExport: pdto, keepID: true)
                context.insert(project)
                for tdto in pdto.tasks {
                    insert(tdto, into: project, parent: nil, context: context, keepID: true)
                }
            }

        case .merge:
            let existing = (try? context.fetch(FetchDescriptor<Project>())) ?? []
            for pdto in doc.projects {
                // Reuse an existing project that matches the import rather than
                // duplicating it; otherwise create a new one (fresh id).
                let project = existing.first(where: { $0.matchesExport(pdto) }) ?? {
                    let p = Project(fromExport: pdto, keepID: false)
                    context.insert(p)
                    return p
                }()
                for tdto in pdto.tasks {
                    mergeTask(tdto, into: project, parent: nil, context: context)
                }
            }
        }
        try context.save()
    }

    private static func decode(_ data: Data) throws -> ExportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecoding
        let doc: ExportDocument
        do { doc = try decoder.decode(ExportDocument.self, from: data) }
        catch { throw ImportError.malformed(error.localizedDescription) }
        guard doc.app == "Quillpoint" else {
            throw ImportError.malformed("Unrecognized file (app = \"\(doc.app)\").")
        }
        return doc
    }

    // MARK: - Merge

    /// Merge a task DTO under `project`/`parent`: if a task that matches the import in
    /// every field already exists at this level, keep it (and recurse into its
    /// subtasks so new children are still added); otherwise add it and its subtasks.
    @MainActor
    private static func mergeTask(_ dto: TaskDTO, into project: Project, parent: Task?, context: ModelContext) {
        let siblings = parent?.subtasks ?? project.tasks.filter { $0.parent == nil }
        if let match = siblings.first(where: { $0.matchesExport(dto) }) {
            for sub in dto.subtasks {
                mergeTask(sub, into: project, parent: match, context: context)
            }
        } else {
            insert(dto, into: project, parent: parent, context: context, keepID: false)
        }
    }

    /// Recreates a task (and its subtasks) from a DTO under `project` / `parent`.
    @MainActor
    private static func insert(_ dto: TaskDTO, into project: Project, parent: Task?,
                               context: ModelContext, keepID: Bool) {
        let task = Task(project: project, parent: parent)
        task.apply(dto, keepID: keepID)
        context.insert(task)
        project.tasks.append(task)
        if let parent { parent.subtasks.append(task) }
        for sub in dto.subtasks {
            insert(sub, into: project, parent: task, context: context, keepID: keepID)
        }
    }
}
