import Foundation
import StenoDomain
import Testing
@testable import StenoExchange

@Suite("Meeting transfer audio inspector")
struct MeetingTransferAudioInspectorTests {
    @Test("inspector returns values derived from a supported nonempty audio file")
    func derivesAudioValues() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("track.caf")
        try makeTransferCAF(at: url, sampleRate: 8_000, channelCount: 2, frameCount: 160)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "room",
            kind: .imported,
            sourceURL: url,
            sampleRate: 8_000,
            channelCount: 2,
            duration: 0.02
        )

        let inspected = try MeetingTransferAudioInspector().inspect(
            sourceURL: url,
            document: document,
            byteSHA256: document.sha256
        )

        #expect(inspected.logicalTrackID == "room")
        #expect(inspected.kind == .imported)
        #expect(inspected.byteSHA256 == document.sha256)
        #expect(inspected.sampleRate == 8_000)
        #expect(inspected.channelCount == 2)
        #expect(abs(inspected.duration - 0.02) < 0.000_001)
    }

    @Test("inspector rejects unsupported audio bytes")
    func rejectsCorruptAudio() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("track.caf")
        let data = Data("not audio".utf8)
        try data.write(to: url)
        let document = try MeetingTransferAudioDocument(
            logicalTrackID: "corrupt",
            kind: .micTrack,
            byteCount: Int64(data.count),
            sha256: transferTestSHA256(data),
            sampleRate: 8_000,
            channelCount: 1,
            duration: 1
        )

        #expect(throws: MeetingTransferValidationError.unsupportedAudio("corrupt")) {
            try MeetingTransferAudioInspector().inspect(
                sourceURL: url,
                document: document,
                byteSHA256: document.sha256
            )
        }
    }

    @Test("inspector rejects a readable non-CAF container")
    func rejectsReadableNonCAFContainer() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("track.wav")
        try makeTransferCAF(at: url)
        #expect(try Data(contentsOf: url).prefix(4) == Data("RIFF".utf8))
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "not-caf",
            kind: .micTrack,
            sourceURL: url
        )

        #expect(throws: MeetingTransferValidationError.unsupportedAudio("not-caf")) {
            try MeetingTransferAudioInspector().inspect(
                sourceURL: url,
                document: document,
                byteSHA256: document.sha256
            )
        }
    }

    @Test("inspector rejects an audio container with zero samples")
    func rejectsZeroSamples() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("empty.caf")
        try makeTransferCAF(at: url, frameCount: 0)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "empty",
            kind: .micTrack,
            sourceURL: url,
            duration: 1
        )

        #expect(throws: MeetingTransferValidationError.emptyAudio("empty")) {
            try MeetingTransferAudioInspector().inspect(
                sourceURL: url,
                document: document,
                byteSHA256: document.sha256
            )
        }
    }

    @Test("inspector rejects plausible metadata that disagrees with derived audio")
    func rejectsMetadataMismatch() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("track.caf")
        try makeTransferCAF(at: url, sampleRate: 8_000, channelCount: 1, frameCount: 80)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "mismatch",
            kind: .micTrack,
            sourceURL: url,
            sampleRate: 16_000,
            duration: 0.01
        )

        #expect(throws: MeetingTransferValidationError.audioMetadataMismatch("mismatch")) {
            try MeetingTransferAudioInspector().inspect(
                sourceURL: url,
                document: document,
                byteSHA256: document.sha256
            )
        }
    }
}
