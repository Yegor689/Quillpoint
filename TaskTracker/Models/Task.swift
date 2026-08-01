import Foundation
import SwiftData
import AppKit
import SwiftUI

/// Task priority. Stored as the raw `Int` on `Task.priority` so existing data
/// (0 = critical, 1 = normal) stays valid; 2 = low is the new level.
/// The rawValue doubles as the sort order (lower = more urgent, sorts first).
enum Priority: Int, CaseIterable, Identifiable {
    case critical = 0
    case normal   = 1
    case low      = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .critical: return "Critical"
        case .normal:   return "Normal"
        case .low:      return "Low"
        }
    }

    var color: Color {
        switch self {
        case .critical: return .red
        case .normal:   return .secondary
        case .low:      return .blue
        }
    }

    /// SF Symbol shown on the inline priority button / detail chip.
    var iconName: String {
        switch self {
        case .critical: return "exclamationmark.circle.fill"
        case .normal:   return "flag"
        case .low:      return "arrow.down.circle"
        }
    }

    /// Whether this level warrants a visual accent (color, bold, leading bar).
    var isAccented: Bool { self != .normal }

    /// The next level when cycling via the inline button: Critical → Normal → Low → Critical.
    var next: Priority {
        Priority(rawValue: (rawValue + 1) % Priority.allCases.count) ?? .normal
    }
}

@Model
class Task {
    var id: UUID
    var titleRTF: Data
    var descRTF: Data
    var isDone: Bool
    var priority: Int  // raw value of Priority: 0 = critical, 1 = normal, 2 = low
    var createdAt: Date
    /// Manual position within the task's parent context (its project for root tasks,
    /// or its parent task for subtasks). Lower comes first. This is the primary
    /// ordering key; createdAt is only a tiebreaker / migration fallback.
    var sortIndex: Int = 0
    /// When the task was most recently marked done; nil while incomplete. Used to
    /// order completed tasks (newest completion on top of the done group).
    var completedAt: Date?
    var reminderDate: Date?
    /// The project this task belongs to. Non-optional since 2.0.0: every task always
    /// lives in a project (a subtask in its parent's). The V1→V2 migration backfills
    /// any legacy orphan — see [ProjectBackfill].
    var project: Project
    @Relationship(inverse: \Task.subtasks) var parent: Task?
    @Relationship(deleteRule: .cascade) var subtasks: [Task]

    // Caches the decoded plain text so hot paths (row rendering, search) don't re-parse
    // the RTF on every read. Keyed by the RTF bytes, so any edit misses the cache and
    // re-decodes — it can't go stale. @Transient keeps these out of the store.
    @Transient private var cachedTitle: (rtf: Data, text: String)?
    @Transient private var cachedDesc:  (rtf: Data, text: String)?

    init(plainTitle: String = "", plainDesc: String = "", priority: Int = 1, project: Project, parent: Task? = nil) {
        self.id = UUID()
        self.titleRTF = Task.rtf(from: plainTitle)
        self.descRTF = Task.rtf(from: plainDesc)
        self.isDone = false
        self.priority = priority
        self.createdAt = Date()
        self.project = project
        self.parent = parent
        self.subtasks = []
    }

    /// Returns a detached copy carrying every SCALAR field of this task, placed in
    /// `project` — used by backup restore to recreate a task in another store. The
    /// `parent`/`subtasks` relationships are deliberately NOT copied; the caller
    /// wires them by id in the destination store. `project` is required at init (a
    /// task always belongs to one), so the destination project is passed in.
    /// Keeping this next to the stored properties is the single place to update when
    /// a field is added — see the backup round-trip integrity test.
    func cloneScalars(into project: Project) -> Task {
        let copy = Task(project: project)
        copy.id = id
        copy.titleRTF = titleRTF
        copy.descRTF = descRTF
        copy.isDone = isDone
        copy.priority = priority
        copy.createdAt = createdAt
        copy.sortIndex = sortIndex
        copy.completedAt = completedAt
        copy.reminderDate = reminderDate
        return copy
    }

    /// Typed view over the stored `priority` Int. Falls back to `.normal` for any
    /// unexpected stored value so the UI never breaks on bad data.
    var priorityLevel: Priority {
        get { Priority(rawValue: priority) ?? .normal }
        set { priority = newValue.rawValue }
    }

    /// Plain text of the title, decoded from `titleRTF` (cached — see `cachedTitle`).
    var plainTitle: String {
        if let c = cachedTitle, c.rtf == titleRTF { return c.text }
        let text = Task.plain(from: titleRTF)
        cachedTitle = (titleRTF, text)
        return text
    }

    /// Plain text of the description, decoded from `descRTF` (cached).
    var plainDesc: String {
        if let c = cachedDesc, c.rtf == descRTF { return c.text }
        let text = Task.plain(from: descRTF)
        cachedDesc = (descRTF, text)
        return text
    }

    /// Sets completion state and stamps `completedAt` so completed tasks can be
    /// ordered by when they were finished. Always use this instead of mutating
    /// `isDone` directly.
    func setDone(_ done: Bool) {
        guard done != isDone else { return }
        isDone = done
        completedAt = done ? Date() : nil
    }

    func toggleDone() { setDone(!isDone) }

    /// A parent task's completion is DERIVED from its subtasks: it's done exactly
    /// when it has subtasks and they're all done. Tasks without subtasks keep their
    /// own state. Call after a subtask's completion changes to keep the parent in
    /// sync (completing the last subtask completes the parent; reopening one reopens
    /// the parent).
    func syncDoneWithSubtasks() {
        guard !subtasks.isEmpty else { return }
        setDone(subtasks.allSatisfy(\.isDone))
    }

    /// Whether this task's completion is controlled by its subtasks (so its own
    /// checkbox shouldn't be directly toggleable).
    var isDrivenBySubtasks: Bool { !subtasks.isEmpty }

    static func rtf(from plain: String, font: NSFont = .preferredFont(forTextStyle: .body)) -> Data {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let attrStr = NSAttributedString(string: plain, attributes: attrs)
        return (try? attrStr.data(from: NSRange(location: 0, length: attrStr.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
    }

    /// Returns a copy of the given title RTF with every font run resized to
    /// `pointSize`, preserving family and traits (bold/italic). Used when a task
    /// changes level (top-level title3 ↔ subtask body) so its baked-in font size
    /// matches its siblings. Returns the input unchanged on failure.
    static func resizingFontRTF(_ rtf: Data, to pointSize: CGFloat) -> Data {
        guard !rtf.isEmpty,
              let attr = try? NSAttributedString(data: rtf,
                                                 options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                 documentAttributes: nil)
        else { return rtf }
        let mutable = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.font, in: full) { value, range, _ in
            let base = (value as? NSFont) ?? .preferredFont(forTextStyle: .body)
            let resized = NSFontManager.shared.convert(base, toSize: pointSize)
            mutable.addAttribute(.font, value: resized, range: range)
        }
        return (try? mutable.data(from: NSRange(location: 0, length: mutable.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? rtf
    }

    static func plain(from rtf: Data) -> String {
        guard !rtf.isEmpty,
              let attrStr = try? NSAttributedString(data: rtf,
                                                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                    documentAttributes: nil)
        else { return "" }
        return attrStr.string
    }
}
