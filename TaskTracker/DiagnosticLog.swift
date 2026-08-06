import Foundation
import SwiftData
import os

/// A lightweight, shareable record of mutating actions, for diagnosing edge cases
/// from bug reports. Entries hold only structural facts — operation name, UUIDs,
/// and counts — never task titles or descriptions, so the exported log carries no
/// user content and is safe to send. Kept as a bounded in-memory ring buffer and
/// mirrored to the unified log (Console.app) as it happens.
@Observable
final class DiagnosticLog {
    /// The shared instance the stores log into.
    static let shared = DiagnosticLog()

    private static let logger = Logger(subsystem: "co.TaskTracker", category: "Diagnostics")
    private static let maxEntries = 500
    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private(set) var entries: [String] = []

    /// Records one action. `op` is the operation name; `details` are already
    /// privacy-safe key=value fragments (ids and counts only).
    func record(_ op: String, _ details: String = "") {
        let line = "\(Self.timestamp.string(from: Date())) \(op)\(details.isEmpty ? "" : " \(details)")"
        append(line)
        Self.logger.info("\(line, privacy: .public)")
    }

    /// Records an invariant violation — a self-tripwire for structural corruption
    /// (e.g. a task that ended up in no project, or more than one). Logged loudly.
    func violation(_ message: String) {
        let line = "\(Self.timestamp.string(from: Date())) ⚠️ INVARIANT \(message)"
        append(line)
        Self.logger.error("\(line, privacy: .public)")
    }

    private func append(_ line: String) {
        entries.append(line)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// The full buffer as a single text document, for export.
    func exportText() -> String {
        let header = """
        Quillpoint diagnostics
        Exported: \(Self.timestamp.string(from: Date()))
        Entries: \(entries.count)
        (Structural actions only - no task titles or descriptions.)

        """
        return header + entries.joined(separator: "\n") + "\n"
    }

    // MARK: - Invariant checking

    /// Verifies, after a structural change, that every task is reachable from
    /// exactly one project's `tasks` collection. A task reachable from zero
    /// projects is the "vanished" bug; from more than one is double-listing.
    /// Logs a violation for each offender. `context` labels the call site.
    ///
    /// This only reads `id` on freshly fetched objects and the `tasks` collections —
    /// it deliberately never dereferences a task's `project` relationship, which can
    /// point at a deleted/invalidated model and trap fatally (the very crash this
    /// check must not cause).
    @MainActor
    func checkProjectMembership(in modelContext: ModelContext, after context: String) {
        guard let projects = try? modelContext.fetch(FetchDescriptor<Project>()),
              let tasks = try? modelContext.fetch(FetchDescriptor<Task>())
        else { return }

        // Count how many projects list each task id.
        var listings: [UUID: Int] = [:]
        for project in projects {
            for task in project.tasks { listings[task.id, default: 0] += 1 }
        }

        for task in tasks {
            let count = listings[task.id] ?? 0
            if count != 1 {
                violation("after=\(context) task=\(short(task.id)) listedInProjects=\(count)")
            }
        }
    }

    /// First 8 chars of a UUID — enough to correlate within a session, compact in
    /// the log.
    private func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
}
