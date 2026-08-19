import Foundation
import Testing
@testable import StenoExchange

@Suite("Legacy store scanner")
struct LegacyStoreTests {
    @Test("collects Unicode stems, collapses summary twins, and reports orphans and pending deletes")
    func scansStoreWithoutWritingIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFixture("store_twin_audio", extension: "m4a", to: root.appending(path: "recordings/twin.m4a"))
        try writeFixture("store_unicode_audio", extension: "wav", to: root.appending(path: "recordings/Überblick.wav"))
        try writeFixture("store_orphan_audio", extension: "webm", to: root.appending(path: "recordings/audio-only.webm"))
        try writeFixture("store_twin_transcript", extension: "txt", to: root.appending(path: "transcripts/twin_transcript.txt"))
        try writeFixture("store_orphan_transcript", extension: "txt", to: root.appending(path: "transcripts/transcript-only_transcript.txt"))
        try writeFixture("store_twin_summary", extension: "md", to: root.appending(path: "output/twin_summary.md"))
        try writeFixture("store_twin_summary", extension: "json", to: root.appending(path: "output/twin_summary.json"))
        try writeFixture("store_unicode_summary", extension: "md", to: root.appending(path: "output/Überblick_summary.md"))
        try writeFixture("store_orphan_summary", extension: "md", to: root.appending(path: "output/summary-only_summary.md"))
        try writeFixture("store_pending", extension: "json", to: root.appending(path: "output/.pending-delete/stale_speakers.json"))

        let snapshot = try LegacyStore(rootURL: root).scan()

        #expect(snapshot.entries.map(\.stem) == ["audio-only", "summary-only", "transcript-only", "twin", "Überblick"])
        let twin = try #require(snapshot.entries.first { $0.stem == "twin" })
        #expect(twin.recordings.map(\.pathExtension) == ["m4a"])
        #expect(twin.transcript?.lastPathComponent == "twin_transcript.txt")
        #expect(twin.summary?.kind == .markdown)
        #expect(twin.shadowedSummaryJSON?.lastPathComponent == "twin_summary.json")
        #expect(snapshot.orphans == [
            LegacyOrphan(stem: "audio-only", kind: .recordingWithoutSidecars),
            LegacyOrphan(stem: "summary-only", kind: .summaryWithoutTranscript),
            LegacyOrphan(stem: "transcript-only", kind: .transcriptWithoutSummary),
            LegacyOrphan(stem: "Überblick", kind: .summaryWithoutTranscript),
        ])
        #expect(snapshot.pendingDeleteFiles.map(\.lastPathComponent) == ["stale_speakers.json"])
    }
}
