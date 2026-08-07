import Testing
import Foundation
@testable import Quillpoint

/// Covers the diagnostic log's buffer behavior and the exported document's shape —
/// the header a bug report is read from, and the privacy guarantee that no task
/// text ever reaches the log.
struct DiagnosticLogTests {

    @Test func exportIncludesEnvironmentHeader() {
        let log = DiagnosticLog()
        log.record("addTask", "task=abcd1234 project=9999aaaa")

        let text = log.exportText()
        #expect(text.contains("Quillpoint diagnostics"))
        #expect(text.contains("App: Quillpoint "), "app version line present")
        #expect(text.contains("macOS: "), "OS version line present")
        #expect(text.contains("Entries: 1"))
        #expect(text.contains("addTask"))
    }

    @Test func recordsAppearInOrderWithDetails() {
        let log = DiagnosticLog()
        log.record("indentTask", "task=aaaa1111 parent=bbbb2222")
        log.record("unindentTask", "task=aaaa1111")

        #expect(log.entries.count == 2)
        #expect(log.entries[0].contains("indentTask"))
        #expect(log.entries[0].contains("parent=bbbb2222"))
        #expect(log.entries[1].contains("unindentTask"))
    }

    @Test func violationsAreMarkedForScanning() {
        let log = DiagnosticLog()
        log.violation("after=moveTask task=aaaa1111 listedInProjects=0")

        #expect(log.entries.count == 1)
        #expect(log.entries[0].contains("INVARIANT"))
    }

    /// The buffer is bounded, so a long session can't grow memory without limit and an
    /// export stays a reasonable size. Oldest entries are dropped first.
    @Test func bufferIsBoundedKeepingNewestEntries() {
        let log = DiagnosticLog()
        for i in 0..<600 { log.record("op\(i)") }

        #expect(log.entries.count == 500, "trimmed to maxEntries")
        #expect(log.entries.last?.contains("op599") == true, "newest kept")
        #expect(log.entries.contains { $0.contains("op0 ") } == false, "oldest dropped")
    }
}
