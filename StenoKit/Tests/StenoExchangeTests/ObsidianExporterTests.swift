import Foundation
import Testing
@testable import StenoExchange

@Suite("Obsidian exporter")
struct ObsidianExporterTests {

    private static func makeDocument(
        id: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        title: String = "Team Sync",
        date: Date,
        status: String = "ready",
        participants: [String] = ["Alice", "Bob"],
        body: String = "# Team Sync\n\n## Transcript\n\nhello"
    ) -> ObsidianVaultDocument {
        ObsidianVaultDocument(
            meetingID: id,
            title: title,
            createdAt: date,
            status: status,
            participants: participants,
            bodyMarkdown: body
        )
    }

    private static func utcDate(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)!
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func makeTemporaryVault() throws -> (url: URL, vault: ObsidianVault) {
        let base = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        let url = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, ObsidianVault(baseURL: url))
    }

    // MARK: Frontmatter rendering

    @Test("frontmatter carries title, date, status, participants and identity")
    func frontmatterRendering() throws {
        let document = Self.makeDocument(
            date: Self.utcDate("2026-08-26"),
            status: "ready"
        )
        let text = ObsidianExporter.render(document, calendar: Self.utcCalendar)
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines[0] == "---")
        #expect(lines.contains(#"title: "Team Sync""#))
        #expect(lines.contains("date: 2026-08-26"))
        #expect(lines.contains("status: ready"))
        #expect(lines.contains("participants:"))
        #expect(lines.contains("  - \"Alice\""))
        #expect(lines.contains("  - \"Bob\""))
        #expect(lines.contains("source: Steno"))
        #expect(lines.contains(
            "steno-id: 11111111-2222-3333-4444-555555555555"
        ))
        // The document continues past the frontmatter, so the closing fence
        // is not the last line: with empty lines dropped by split, the
        // element right after the second fence must be the first body line.
        let fences = lines.indices.filter { lines[$0] == "---" }
        #expect(fences.count == 2)
        let bodyStart = try #require(lines.firstIndex(of: "# Team Sync"))
        #expect(fences.last == lines.index(before: bodyStart))
        // Body follows after the closing fence and a blank line.
        #expect(text.contains("---\n\n# Team Sync"))
    }

    @Test("frontmatter omits empty participants and escapes quotes")
    func frontmatterEscaping() {
        let document = Self.makeDocument(
            title: #"Chapter 2: "The End""#,
            date: Self.utcDate("2026-01-02"),
            participants: []
        )
        let text = ObsidianExporter.frontmatter(for: document, calendar: Self.utcCalendar)
        #expect(!text.contains("participants"))
        #expect(text.contains(#"title: "Chapter 2: \"The End\"""#))
    }

    // MARK: File naming

    @Test("filename mirrors the markdown-export slug convention")
    func fileNameConvention() {
        let name = ObsidianExporter.fileName(
            date: Self.utcDate("2026-08-26"),
            title: "  Quarterly   Review: Q3/Plan?  ",
            calendar: Self.utcCalendar
        )
        #expect(name == "2026-08-26 Quarterly Review Q3 Plan.md")
    }

    @Test("empty or forbidden titles fall back to a named file")
    func fileNameFallback() {
        let name = ObsidianExporter.fileName(
            date: Self.utcDate("2026-08-26"),
            title: "///",
            calendar: Self.utcCalendar
        )
        #expect(name == "2026-08-26 meeting.md")
    }

    // MARK: Collision handling

    @Test("a foreign file owning the preferred name is never clobbered")
    func collisionGetsSuffixedName() throws {
        let (_, vault) = try makeTemporaryVault()
        try vault.write("hand-written note", fileName: "2026-08-26 Team Sync.md")

        let summary = ObsidianExporter.sync(
            [Self.makeDocument(date: Self.utcDate("2026-08-26"))],
            into: vault,
            calendar: Self.utcCalendar
        )

        #expect(summary.written == 1)
        #expect(vault.contents(fileName: "2026-08-26 Team Sync.md") == "hand-written note")
        #expect(vault.contents(fileName: "2026-08-26 Team Sync 2.md")?
            .contains("steno-id: 11111111") == true)
    }

    @Test("collision probing skips past multiple taken names")
    func collisionProbing() {
        // Compute candidates BEFORE the assertions: #expect arguments are
        // autoclosures and must stay pure reads, never closure-capture a
        // mutable local (documented Swift Testing pitfall).
        let taken: Set<String> = ["Note.md", "Note 2.md", "Note 3.md"]
        let isTaken: (String) -> Bool = { taken.contains($0) }

        let fourth = ObsidianExporter.collisionFreeName(
            preferred: "Note.md",
            isTaken: isTaken
        )
        #expect(fourth == "Note 4.md")

        let extended = taken.union([fourth])
        let fifth = ObsidianExporter.collisionFreeName(
            preferred: "Note.md",
            isTaken: { extended.contains($0) }
        )
        #expect(fifth == "Note 5.md")
    }

    // MARK: Idempotence

    @Test("second export without changes is diff-empty")
    func secondExportIsDiffEmpty() throws {
        let (_, vault) = try makeTemporaryVault()
        let documents = [
            Self.makeDocument(date: Self.utcDate("2026-08-26")),
            Self.makeDocument(
                id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                title: "Retro",
                date: Self.utcDate("2026-08-20"),
                participants: []
            ),
        ]

        let first = ObsidianExporter.sync(documents, into: vault, calendar: Self.utcCalendar)
        #expect(first.written == 2)

        let second = ObsidianExporter.sync(documents, into: vault, calendar: Self.utcCalendar)
        #expect(second.isDiffEmpty)
        #expect(second.written == 0 && second.updated == 0 && second.unchanged == 2)
    }

    @Test("changed content updates in place by stable filename")
    func reexportUpdatesByStableName() throws {
        let (_, vault) = try makeTemporaryVault()
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let original = Self.makeDocument(id: id, date: Self.utcDate("2026-08-26"))
        _ = ObsidianExporter.sync([original], into: vault, calendar: Self.utcCalendar)

        let edited = Self.makeDocument(
            id: id,
            date: Self.utcDate("2026-08-26"),
            body: "# Team Sync\n\n## Transcript\n\nedited"
        )
        let summary = ObsidianExporter.sync([edited], into: vault, calendar: Self.utcCalendar)

        #expect(summary.updated == 1)
        #expect(vault.contents(fileName: "2026-08-26 Team Sync.md")?.contains("edited") == true)
    }

    @Test("title change renames the existing mirror instead of duplicating")
    func titleChangeRenamesMirror() throws {
        let (_, vault) = try makeTemporaryVault()
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        _ = ObsidianExporter.sync(
            [Self.makeDocument(id: id, date: Self.utcDate("2026-08-26"))],
            into: vault,
            calendar: Self.utcCalendar
        )

        let renamed = Self.makeDocument(
            id: id,
            title: "Renamed Sync",
            date: Self.utcDate("2026-08-26")
        )
        let summary = ObsidianExporter.sync([renamed], into: vault, calendar: Self.utcCalendar)

        #expect(summary.updated == 1 && summary.written == 0)
        #expect(!vault.markdownFileNames().contains("2026-08-26 Team Sync.md"))
        #expect(vault.markdownFileNames() == ["2026-08-26 Renamed Sync.md"])
    }

    // MARK: One-way contract

    @Test("deleting a vault file never touches the library mirror state")
    func vaultDeletionIsInvisibleToSync() throws {
        let (_, vault) = try makeTemporaryVault()
        let document = Self.makeDocument(date: Self.utcDate("2026-08-26"))
        _ = ObsidianExporter.sync([document], into: vault, calendar: Self.utcCalendar)
        try FileManager.default.removeItem(
            at: vault.baseURL.appendingPathComponent("2026-08-26 Team Sync.md")
        )

        // The next sync simply re-mirrors it; nothing errors, nothing is
        // read back as a user edit.
        let summary = ObsidianExporter.sync([document], into: vault, calendar: Self.utcCalendar)
        #expect(summary.written == 1)
        #expect(vault.contents(fileName: "2026-08-26 Team Sync.md") != nil)
    }

    // MARK: Identity parsing

    @Test("steno-id parses from mirrored files and rejects foreign content")
    func stenoIDParsing() throws {
        let (_, vault) = try makeTemporaryVault()
        let document = Self.makeDocument(date: Self.utcDate("2026-08-26"))
        _ = ObsidianExporter.sync([document], into: vault, calendar: Self.utcCalendar)
        let mirrored = try #require(vault.contents(fileName: "2026-08-26 Team Sync.md"))
        #expect(ObsidianExporter.stenoMeetingID(ofMarkdown: mirrored) == document.meetingID)
        #expect(ObsidianExporter.stenoMeetingID(ofMarkdown: "# Just a note\n") == nil)
    }

    // MARK: Approval gate


    @Test("gate starts idle and grants only an open request")
    func approvalGateHappyPath() {
        var gate = ObsidianExportApprovalGate()
        // Mutating members must run OUTSIDE #expect: the macro re-emits
        // calls onto an immutable copy of the value.
        var gate2 = gate
        let staleGrant = gate2.beginExport()
        #expect(staleGrant == nil)

        gate.requestExport(into: "/vaults/private")
        let granted = gate.resolveApproval(true)
        #expect(granted)
        #expect(gate.requestedTargetPath == "/vaults/private")
        let path = gate.beginExport()
        #expect(path == "/vaults/private")
    }

    @Test("grant is consumable exactly once")
    func approvalGateSingleConsumption() {
        var gate = ObsidianExportApprovalGate()
        gate.requestExport(into: "/vaults/private")
        _ = gate.resolveApproval(true)
        let first = gate.beginExport()
        let second = gate.beginExport()
        #expect(first == "/vaults/private")
        #expect(second == nil)
    }

    @Test("decline never yields an export path")
    func approvalGateDecline() {
        var gate = ObsidianExportApprovalGate()
        gate.requestExport(into: "/vaults/private")
        let granted = gate.resolveApproval(false)
        let path = gate.beginExport()
        #expect(!granted)
        #expect(gate.phase == .declined(targetPath: "/vaults/private"))
        #expect(path == nil)
    }

    @Test("resolving without an open request cannot approve anything")
    func approvalGateRejectsStaleResolution() {
        var gate = ObsidianExportApprovalGate()
        var idle = gate
        let idleGrant = idle.resolveApproval(true)
        #expect(!idleGrant)

        gate.requestExport(into: "/a")
        gate.reset()
        let staleGrant = gate.resolveApproval(true)
        let path = gate.beginExport()
        #expect(!staleGrant)
        #expect(path == nil)
    }
}
