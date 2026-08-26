import Foundation
import StenoPipeline
import Testing

@Suite("Bulk export CSV builder and destination safety")
struct BulkExportCSVTests {
    // MARK: - Header

    @Test("Header row is exactly the legacy column list")
    func headerIsExact() {
        let lines = BulkExportCSV.build([]).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "title,date,duration,folders,attendees,summary,transcript")
        // Header only: one line plus the trailing newline.
        #expect(BulkExportCSV.build([]) == BulkExportCSV.headerLine + "\n")
    }

    // MARK: - Formula guard

    @Test("Leading formula trigger characters get a guard apostrophe")
    func formulaGuard() {
        for trigger in ["=", "+", "-", "@", "\t", "\r"] {
            #expect(BulkExportCSV.guardedCell(trigger + "cmd") == "'" + trigger + "cmd")
        }
        #expect(BulkExportCSV.guardedCell("-5 degrees") == "'-5 degrees")
        // Not at the start: untouched.
        #expect(BulkExportCSV.guardedCell("a = b") == "a = b")
        #expect(BulkExportCSV.guardedCell("") == "")
        #expect(BulkExportCSV.guardedCell("[00:01] Alice: Regular") == "[00:01] Alice: Regular")
    }

    // MARK: - Quoting round-trip

    @Test("Commas, quotes and newlines survive a CSV round-trip")
    func quotingRoundTrip() throws {
        let trickyTitle = "Q3 \"review\", part 1"
        let trickyTranscript = "line one\nline \"two\", continued\r\nlast"
        let csv = BulkExportCSV.build([
            BulkExportCSV.MeetingRow(
                title: trickyTitle,
                date: "2026-08-26T10:00:00Z",
                durationSeconds: 600,
                folders: ["Work, urgent"],
                attendees: ["Alice \"Al\" Doe"],
                summary: "=SUM(A1)",
                transcript: trickyTranscript
            ),
        ])
        let rows = try Self.parse(csv)
        #expect(rows.count == 2)
        let data = rows[1]
        #expect(data[0] == trickyTitle)
        #expect(data[2] == "600")
        #expect(data[3] == "Work, urgent")
        #expect(data[4] == "Alice \"Al\" Doe")
        // The guard apostrophe is the deliberate mitigation; the content
        // after it must still round-trip byte-for-byte.
        #expect(data[5] == "'=SUM(A1)")
        #expect(data[6] == trickyTranscript)
    }

    /// Minimal RFC-4180-aware reader so tests assert what a spreadsheet
    /// would actually see.
    static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var quoted = false
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == "," {
                                row.append(field); field = ""
                            } else if next == "\n" {
                                row.append(field); rows.append(row); row = []; field = ""
                            } else if next != "\r" {
                                field.append(next)
                            }
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                case "\r": break
                default: field.append(char)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: - List joining

    @Test("Folders and attendees join with a comma-space separator")
    func listJoining() {
        #expect(BulkExportCSV.joinedList(["A", "B", "C"]) == "A, B, C")
        #expect(BulkExportCSV.joinedList([]) == "")
    }

    // MARK: - Count accuracy

    @Test("Row count matches the meeting count exactly")
    func countAccuracy() {
        let rows = (0..<7).map { index in
            BulkExportCSV.MeetingRow(title: "Meeting \(index)")
        }
        let lines = BulkExportCSV.build(rows)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast() // trailing newline
        #expect(lines.count == 8)
        #expect(lines[3].hasPrefix("Meeting 2"))
    }

    // MARK: - Containment rule

    @Test("Target inside the library is rejected with the exact message")
    func containmentRejection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("meetings"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let message = BulkExportPathSafety.containmentErrorMessage

        // The library directory itself.
        #expect(
            BulkExportPathSafety.rejectionReason(
                targetDirectory: library, libraryDirectory: library
            ) == message
        )
        // A direct subfolder.
        #expect(
            BulkExportPathSafety.rejectionReason(
                targetDirectory: library.appendingPathComponent("exports"),
                libraryDirectory: library
            ) == message
        )
        // A deeper nested path through .. segments.
        #expect(
            BulkExportPathSafety.rejectionReason(
                targetDirectory: library.appendingPathComponent("meetings/../exports"),
                libraryDirectory: library
            ) == message
        )
    }

    @Test("Targets outside the library are accepted")
    func outsideAccepted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let elsewhere = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: library, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            BulkExportPathSafety.rejectionReason(
                targetDirectory: elsewhere, libraryDirectory: library
            ) == nil
        )
        // Sibling whose name merely shares a string prefix ("/Lib-x").
        #expect(
            BulkExportPathSafety.rejectionReason(
                targetDirectory: root.appendingPathComponent("Library-x"),
                libraryDirectory: library
            ) == nil
        )
    }

    @Test("A symlink pointing into the library is rejected")
    func symlinkAliasRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("inner"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: library.appendingPathComponent("inner")
        )
        #expect(
            BulkExportPathSafety.rejectionReason(
                targetDirectory: alias, libraryDirectory: library
            ) == BulkExportPathSafety.containmentErrorMessage
        )
    }
}
