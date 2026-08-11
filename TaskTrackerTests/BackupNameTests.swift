import Testing
import Foundation
@testable import Quillpoint

/// A backup's FILENAME is the source of truth for its kind, date, label, and pinned
/// state — there is no sidecar metadata. `refresh()` drops any file whose stem won't
/// parse (`guard let parsed = BackupName.parse(stem) else { return nil }`), so a parsing
/// gap doesn't surface as a wrong label: the backup disappears from the UI entirely
/// while still sitting on disk, unreachable for restore.
///
/// These tests pin the round-trip (`stem()` → `parse()`) and the edge cases a user can
/// actually produce by typing a label.
struct BackupNameTests {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (y, mo, d, h, mi, s)
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: Round-trip

    /// Anything stem() writes, parse() must read back identically — otherwise a backup
    /// this app created becomes invisible to it.
    @Test func roundTripsEveryKindPinStateAndLabel() throws {
        let when = date(2026, 8, 7, 14, 30, 5)
        for kind in [BackupKind.auto, .manual, .preRestore] {
            for pinned in [true, false] {
                for label in ["", "before import", "v2 final"] {
                    let original = BackupName(kind: kind, isPinned: pinned, date: when, label: label)
                    let parsed = try #require(BackupName.parse(original.stem()),
                                              "stem [\(original.stem())] failed to parse back")
                    #expect(parsed.kind == kind)
                    #expect(parsed.isPinned == pinned)
                    #expect(parsed.label == label)
                    // Timestamps serialise to second precision.
                    #expect(abs(parsed.date.timeIntervalSince(when)) < 1)
                }
            }
        }
    }

    // MARK: Labels the user can actually type

    /// sanitize() strips characters that would break the filename or the parse. A label
    /// that survives sanitising must still round-trip.
    @Test func labelsWithAwkwardCharactersStillRoundTrip() throws {
        let when = date(2026, 8, 7, 9, 0, 0)
        let awkward = [
            "path/with/slashes",
            "colons:everywhere",
            "  leading and trailing  ",
            "multiple   inner   spaces",
            "émoji 🦊 and accents",
            String(repeating: "x", count: 200),   // length-capped
        ]
        for raw in awkward {
            let name = BackupName(kind: .manual, isPinned: false, date: when, label: raw)
            let stem = name.stem()
            #expect(!stem.contains("/"), "a slash would create a subdirectory: [\(stem)]")
            #expect(!stem.contains(":"), "a colon is not filename-safe: [\(stem)]")
            let parsed = try #require(BackupName.parse(stem), "[\(stem)] failed to parse")
            #expect(parsed.label == BackupName.sanitize(raw))
            #expect(parsed.kind == .manual)
        }
    }

    /// The label is the trailing remainder after the timestamp, so a label that itself
    /// looks like a date must not be mistaken for one.
    @Test func labelResemblingATimestampDoesNotConfuseTheParse() throws {
        let when = date(2026, 8, 7, 9, 0, 0)
        let name = BackupName(kind: .auto, isPinned: false, date: when, label: "2020-01-01 00-00-00")
        let parsed = try #require(BackupName.parse(name.stem()))
        #expect(parsed.label == "2020-01-01 00-00-00")
        #expect(abs(parsed.date.timeIntervalSince(when)) < 1, "the real timestamp wins")
    }

    /// A pinned backup whose label begins with the pin token must not be double-stripped.
    @Test func labelStartingWithThePinTokenIsPreserved() throws {
        let when = date(2026, 8, 7, 9, 0, 0)
        let name = BackupName(kind: .manual, isPinned: false, date: when, label: "pin-this-one")
        let parsed = try #require(BackupName.parse(name.stem()))
        #expect(parsed.isPinned == false, "the label is not the pin marker")
        #expect(parsed.label == "pin-this-one")
    }

    // MARK: Rejection

    /// Non-backup files in the directory must parse as nil rather than as a bogus entry.
    @Test func rejectsStemsThatArentBackups() {
        for bad in [
            "",
            "random-file",
            "TaskTracker",                       // the live store's own name
            "auto-",                             // kind but no timestamp
            "auto-not-a-date",
            "unknownkind-2026-08-07 14-30-05",   // unrecognised kind prefix
            "2026-08-07 14-30-05",               // timestamp with no kind
        ] {
            #expect(BackupName.parse(bad) == nil, "[\(bad)] should not parse as a backup")
        }
    }

    // MARK: Sanitising

    @Test func sanitizeCollapsesWhitespaceAndCapsLength() {
        #expect(BackupName.sanitize("  a   b  ") == "a b")
        #expect(BackupName.sanitize("") == "")
        #expect(BackupName.sanitize(String(repeating: "x", count: 500)).count == 80)
        #expect(BackupName.sanitize("a/b:c").contains("/") == false)
        #expect(BackupName.sanitize("a/b:c").contains(":") == false)
    }
}
