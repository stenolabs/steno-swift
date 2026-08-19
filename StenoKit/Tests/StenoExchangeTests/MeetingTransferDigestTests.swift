import CryptoKit
import Foundation
import Testing
@testable import StenoExchange
import StenoDomain

@Suite("Meeting transfer digest")
struct MeetingTransferDigestTests {
    @Test("content digest ignores export metadata and entry order")
    func digestIsCanonical() throws {
        let first = try digest(entries: [notesEntry, transcriptEntry], exportedAt: .distantPast)
        let second = try digest(entries: [transcriptEntry, notesEntry], exportedAt: .distantFuture)

        #expect(first == second)
    }

    @Test("content digest does not include manifest")
    func digestDoesNotIncludeManifest() throws {
        let digest = try MeetingTransferDigest.contentDigest(for: [notesEntry])
        let repeated = try MeetingTransferDigest.contentDigest(for: [notesEntry])
        #expect(digest == repeated)
    }

    @Test("file digest hashes a file in streaming chunks")
    func fileDigestMatchesCryptoKit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "payload.bin")
        let data = Data(repeating: 0xAB, count: 1_048_576 + 12)
        try data.write(to: url)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try await MeetingTransferDigest.sha256(of: url) == expected)
    }

    private let meetingID = MeetingID(rawValue: UUID(uuidString: "00000000-0000-7000-8000-000000000001")!)

    private var notesEntry: MeetingTransferManifest.Entry {
        MeetingTransferManifest.Entry(
            path: "notes.md", byteCount: 12, mediaType: "text/markdown", sha256: "notes"
        )
    }

    private var transcriptEntry: MeetingTransferManifest.Entry {
        MeetingTransferManifest.Entry(
            path: "transcript.json", byteCount: 34, mediaType: "application/json", sha256: "transcript"
        )
    }

    private func digest(
        entries: [MeetingTransferManifest.Entry],
        exportedAt: Date
    ) throws -> String {
        let manifest = try MeetingTransferManifest(
            sourceMeetingID: meetingID,
            sourceRevisionID: nil,
            exportedAt: exportedAt,
            sourceAppVersion: "1.0",
            capabilities: [.notes, .transcript],
            localeIdentifier: "de-DE",
            localeOrigin: .explicit,
            entries: [
                MeetingTransferManifest.Entry(
                    path: "meeting.json", byteCount: 10, mediaType: "application/json", sha256: "meeting"
                ),
            ] + entries,
            contentDigest: "unused"
        )
        return try MeetingTransferDigest.contentDigest(for: manifest.entries)
    }
}
