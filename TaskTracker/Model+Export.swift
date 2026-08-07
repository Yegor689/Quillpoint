import Foundation

// MARK: - Export DTOs (the JSON wire format)

/// Top-level export document. `DataExportManager` encodes/decodes this.
struct ExportDocument: Codable {
    var app = "Quillpoint"
    var formatVersion = 1
    var exportedAt: Date
    let projects: [ProjectDTO]
}

struct ProjectDTO: Codable {
    let id: UUID
    let title: String
    let desc: String
    let createdAt: Date
    let tasks: [TaskDTO]   // root tasks only; subtasks nested within
}

struct TaskDTO: Codable {
    let id: UUID
    let title: String          // plain text, for readability
    let titleRTF: String       // base64 of the raw RTF, for lossless round-trip
    let notes: String          // plain text of the description
    let notesRTF: String       // base64 of the raw RTF
    let isDone: Bool
    let priority: Int
    let createdAt: Date
    let sortIndex: Int
    let completedAt: Date?
    let reminderDate: Date?
    let subtasks: [TaskDTO]
}

// MARK: - Field mapping lives on the models
//
// The list of fields each model carries is defined here, next to the models, so a
// new field is added in ONE place (export, import, and the merge-equality check all
// flow through these). DataExportManager only orchestrates; it never names a field.

extension Project {
    /// Snapshot this project (and its root tasks) for export.
    @MainActor
    func exportDTO() -> ProjectDTO {
        ProjectDTO(
            id: id,
            title: title,
            desc: desc,
            createdAt: createdAt,
            tasks: TaskStore.orderedRoots(of: self).map { $0.exportDTO() })
    }

    /// Create a project from an export DTO (scalar fields only; the caller wires
    /// tasks). `keepID` keeps the file's id (replace) vs. a fresh one (merge).
    convenience init(fromExport dto: ProjectDTO, keepID: Bool) {
        self.init(title: dto.title, desc: dto.desc)
        if keepID { id = dto.id }
        createdAt = dto.createdAt
    }

    /// A project matches an export DTO when its scalar fields are identical. Tasks
    /// are compared separately, so a matching project can still gain new tasks.
    func matchesExport(_ dto: ProjectDTO) -> Bool {
        title == dto.title && desc == dto.desc && ExportMatch.sameInstant(createdAt, dto.createdAt)
    }
}

extension Task {
    /// Snapshot this task (and its subtasks) for export.
    @MainActor
    func exportDTO() -> TaskDTO {
        TaskDTO(
            id: id,
            title: plainTitle,
            titleRTF: titleRTF.base64EncodedString(),
            notes: plainDesc,
            notesRTF: descRTF.base64EncodedString(),
            isDone: isDone,
            priority: priority,
            createdAt: createdAt,
            sortIndex: sortIndex,
            completedAt: completedAt,
            reminderDate: reminderDate,
            subtasks: TaskStore.orderedSubtasks(of: self).map { $0.exportDTO() })
    }

    /// Copy an export DTO's scalar fields onto this task (relationships are wired by
    /// the caller). `keepID` keeps the file's id vs. leaving the fresh one.
    func apply(_ dto: TaskDTO, keepID: Bool) {
        if keepID { id = dto.id }
        titleRTF = ExportMatch.rtf(base64: dto.titleRTF, plainFallback: dto.title)
        descRTF = ExportMatch.rtf(base64: dto.notesRTF, plainFallback: dto.notes)
        isDone = dto.isDone
        priority = dto.priority
        createdAt = dto.createdAt
        sortIndex = dto.sortIndex
        completedAt = dto.completedAt
        reminderDate = dto.reminderDate
    }

    /// A task matches an export DTO when EVERY scalar field is identical (RTF bytes
    /// included). Any difference makes it a distinct task that should be added.
    /// Subtasks are matched separately by the recursive merge.
    func matchesExport(_ dto: TaskDTO) -> Bool {
        titleRTF == ExportMatch.rtf(base64: dto.titleRTF, plainFallback: dto.title)
            && descRTF == ExportMatch.rtf(base64: dto.notesRTF, plainFallback: dto.notes)
            && isDone == dto.isDone
            && priority == dto.priority
            && ExportMatch.sameInstant(createdAt, dto.createdAt)
            && sortIndex == dto.sortIndex
            && ExportMatch.sameInstant(completedAt, dto.completedAt)
            && ExportMatch.sameInstant(reminderDate, dto.reminderDate)
    }
}

/// Date comparison for export matching. Dates export as millisecond-precision
/// ISO8601, so a stored Date and its round-tripped copy can differ sub-millisecond;
/// comparing at millisecond granularity keeps a re-imported item matching its
/// original (idempotent merge) rather than looking "new" and duplicating.
enum ExportMatch {
    /// Decodes an export's base64 RTF, falling back to the plain-text field when the RTF
    /// is absent OR empty.
    ///
    /// `Data(base64Encoded: "")` returns EMPTY DATA, not nil — so `?? Task.rtf(from:)`
    /// never fired for an entry whose `titleRTF` was an empty string, and the task
    /// imported blank while its plain `title` sat right there in the file. Hand-written
    /// and script-generated exports hit this constantly; a real Quillpoint export doesn't,
    /// which is why it survived. Checking `isEmpty` is the whole fix.
    static func rtf(base64: String, plainFallback: String) -> Data {
        if let decoded = Data(base64Encoded: base64), !decoded.isEmpty { return decoded }
        return Task.rtf(from: plainFallback)
    }

    static func sameInstant(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSinceReferenceDate - b.timeIntervalSinceReferenceDate) < 0.001
    }
    static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return sameInstant(x, y)
        default: return false
        }
    }
}
