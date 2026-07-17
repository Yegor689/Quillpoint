import Testing
import Foundation
import SwiftData
@testable import Quillpoint

/// StoreFingerprint reads a store's content mark (task count + latest activity) straight
/// from SQLite, so the backup system can reason about content instead of filenames.
@MainActor
struct StoreFingerprintTests {

    /// Creates an on-disk store with `count` tasks under one project, saves, and returns
    /// its URL (the container is released so the file is flushed and closed).
    private func makeStore(taskCount count: Int, in dir: URL) throws -> URL {
        let url = dir.appending(component: "fp-\(UUID().uuidString).store")
        let schema = Schema([Project.self, Task.self])
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, url: url))
        let ctx = container.mainContext
        let project = Project(title: "P")
        ctx.insert(project)
        for i in 0..<count {
            let t = Task(plainTitle: "t\(i)", project: project)
            ctx.insert(t)
            project.tasks.append(t)
        }
        try ctx.save()
        return url
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(component: "FP-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func readsTaskCount() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeStore(taskCount: 7, in: dir)
        let fp = try #require(StoreFingerprint.read(from: url))
        #expect(fp.taskCount == 7)
        #expect(fp.latestActivity > 0)
    }

    /// A store that HAS the ZTASK table but zero rows fingerprints as empty (count 0,
    /// no activity). A store where the table was never created reads as nil ("unknown");
    /// both are safe — callers never treat nil as a legitimately-empty store. Here we
    /// insert then delete a task so the table exists but is empty.
    @Test func emptyButTabledStoreFingerprintsAsZero() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(component: "empty.store")
        let schema = Schema([Project.self, Task.self])
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, url: url))
        let ctx = container.mainContext
        let p = Project(title: "P"); ctx.insert(p)
        let t = Task(plainTitle: "temp", project: p); ctx.insert(t); p.tasks.append(t)
        try ctx.save()
        ctx.delete(t)
        try ctx.save()

        let fp = try #require(StoreFingerprint.read(from: url))
        #expect(fp.taskCount == 0)
        #expect(fp.latestActivity == 0)
        #expect(fp.latestActivityDate == nil)
    }

    @Test func corruptOrMissingReturnsNilNotEmpty() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Missing file.
        #expect(StoreFingerprint.read(from: dir.appending(component: "nope.store")) == nil)
        // Not a database.
        let bad = dir.appending(component: "bad.store")
        try Data("not a database".utf8).write(to: bad)
        #expect(StoreFingerprint.read(from: bad) == nil)
    }

    /// The live (`fromTasks`) and file (`read`) fingerprints must agree for the same data,
    /// so a live-vs-backup comparison is valid. Uses ONE container (opening a second one
    /// on the same store SIGTRAPs on the 27 beta — see the migration-tests-sigtrap memory).
    @Test func liveAndFileFingerprintsAgree() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(component: "agree.store")
        let schema = Schema([Project.self, Task.self])
        let container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, url: url))
        let ctx = container.mainContext
        let p = Project(title: "P"); ctx.insert(p)
        for i in 0..<8 {
            let t = Task(plainTitle: "t\(i)", project: p); t.sortIndex = i
            if i % 2 == 0 { t.setDone(true) }
            ctx.insert(t); p.tasks.append(t)
        }
        try ctx.save()

        // Same container for the live fingerprint; read the file for the file fingerprint.
        let fromContext = StoreFingerprint.fromTasks(try ctx.fetch(FetchDescriptor<Task>()))
        let fromFile = try #require(StoreFingerprint.read(from: url))
        #expect(fromContext == fromFile)
    }

    @Test func sameContentComparesEqual() throws {
        let a = StoreFingerprint(taskCount: 50, latestActivity: 800_000_000)
        let b = StoreFingerprint(taskCount: 50, latestActivity: 800_000_000)
        let c = StoreFingerprint(taskCount: 50, latestActivity: 800_000_001)
        #expect(a == b)
        #expect(a != c)
    }
}
