import Foundation
import StenoDomain
@testable import StenoExchange
import Testing

@Suite("MeetingTransferRoundTripTests")
struct MeetingTransferRoundTripTests {
    @Test("text archives preserve portable details in both device directions")
    func textArchivesPreservePortableDetailsInBothDirections() async throws {
        for direction in ["iPad to Mac", "Mac to iPad"] {
            let roundTrip = try await makeRoundTripPackage(
                name: direction,
                includesText: true,
                includesAudio: false
            )
            defer { roundTrip.close() }

            #expect(roundTrip.package.manifest.capabilities == [.notes, .transcript])
            #expect(roundTrip.package.notes == "Plan\n[00:12:34] Beschluss")
            let transcript = try #require(roundTrip.package.transcript)
            #expect(transcript.turns[0].segments[0].words[0].text == "Beschluss")
            #expect(transcript.turns[0].segments[0].words[0].start == 12.25)
            #expect(transcript.turns[0].segments[0].words[0].end == 12.75)
            #expect(transcript.speakers.map { $0.label } == [
                "Ada Bestätigt", "Sprecher 2",
            ])
            #expect(transcript.speakers.map { $0.kind } == [
                .confirmedDisplayName, .generic,
            ])
        }
    }

    @Test("audio-only archive is one regular uncompressed file")
    func audioOnlyArchiveIsOneRegularUncompressedFile() async throws {
        let roundTrip = try await makeRoundTripPackage(
            name: "iPad audio",
            includesText: false,
            includesAudio: true
        )
        defer { roundTrip.close() }

        let values = try roundTrip.packageURL.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey,
        ])
        #expect(values.isRegularFile == true)
        #expect(values.isDirectory == false)
        #expect(roundTrip.packageURL.pathExtension == "stenomeeting")
        #expect(roundTrip.package.manifest.capabilities == [.audio])
        #expect(roundTrip.package.notes == nil)
        #expect(roundTrip.package.transcript == nil)
        #expect(roundTrip.package.audio.count == 1)
        #expect(roundTrip.package.entryPaths == [
            "manifest.json", "meeting.json", "audio/track-1.caf", "audio/track-1.json",
        ])

        let headers = try readTransferArchiveHeaders(at: roundTrip.packageURL)
        #expect(headers.count == 4)
        for header in headers {
            #expect(header.map { $0.0 } == ["TYP", "PAT", "SIZ", "DAT"])
            #expect(header.map { $0.1 } == ["uint", "string", "uint", "blob"])
        }
        let importedAudio = try audioData(roundTrip.package.audio[0])
        #expect(importedAudio == roundTrip.audioBytes)
    }

    @Test("combined archive preserves exactly selected portable content")
    func combinedArchivePreservesExactlySelectedPortableContent() async throws {
        let roundTrip = try await makeRoundTripPackage(
            name: "Combined",
            includesText: true,
            includesAudio: true
        )
        defer { roundTrip.close() }

        #expect(roundTrip.package.manifest.capabilities == [.notes, .transcript, .audio])
        #expect(roundTrip.package.entryPaths == [
            "manifest.json", "meeting.json", "notes.md", "transcript.json",
            "audio/track-1.caf", "audio/track-1.json",
        ])
        #expect(roundTrip.package.audio.count == 1)
        #expect(try audioData(roundTrip.package.audio[0]) == roundTrip.audioBytes)
    }
}

private struct RoundTripPackage {
    let root: URL
    let packageURL: URL
    let package: ValidatedMeetingTransferPackage
    let audioBytes: Data?

    func close() {
        try? package.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeRoundTripPackage(
    name: String,
    includesText: Bool,
    includesAudio: Bool
) async throws -> RoundTripPackage {
    let root = try makeTemporaryDirectory()
    do {
        let sourceURL = root.appending(path: "source.caf")
        let audioDocuments: [MeetingTransferAudioDocument]
        let audioSources: [MeetingTransferAudioSourceBinding]
        let audioBytes: Data?
        if includesAudio {
            try makeTransferCAF(at: sourceURL)
            let document = try await makeTransferAudioDocument(
                logicalTrackID: "track-1",
                kind: .micTrack,
                sourceURL: sourceURL
            )
            audioDocuments = [document]
            audioSources = [MeetingTransferAudioSourceBinding(
                logicalTrackID: "track-1",
                sourceURL: sourceURL
            )]
            audioBytes = try Data(contentsOf: sourceURL)
        } else {
            audioDocuments = []
            audioSources = []
            audioBytes = nil
        }
        let transcript = includesText ? try roundTripTranscript() : nil
        let content = try MeetingTransferPackageContent(
            meeting: try MeetingTransferMeetingDocument(
                sourceMeetingID: MeetingID(),
                title: name,
                createdAt: Date(timeIntervalSinceReferenceDate: 4_321),
                sourceStatus: .ready
            ),
            notes: includesText ? "Plan\n[00:12:34] Beschluss" : nil,
            transcript: transcript,
            audio: audioDocuments
        )
        let packageURL = try await MeetingTransferArchiveWriter().write(
            content,
            audioSources: audioSources,
            sourceRevisionID: includesText ? RevisionID() : nil,
            sourceAppVersion: "Steno/RoundTrip",
            to: root.appending(path: "Export")
        )
        let package = try await MeetingTransferArchiveReader().validate(
            at: packageURL,
            validationRoot: root.appending(path: "Validation")
        )
        return RoundTripPackage(
            root: root,
            packageURL: packageURL,
            package: package,
            audioBytes: audioBytes
        )
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func roundTripTranscript() throws -> MeetingTransferTranscriptSnapshot {
    try MeetingTransferTranscriptSnapshot(
        localeIdentifier: "de-DE",
        localeOrigin: .explicit,
        speakers: [
            try .init(
                id: "speaker-confirmed",
                label: "Ada Bestätigt",
                kind: .confirmedDisplayName
            ),
            try .init(id: "speaker-generic", label: "Sprecher 2", kind: .generic),
        ],
        turns: [
            .init(
                speakerID: "speaker-confirmed",
                start: 12,
                end: 13,
                segments: [
                    .init(
                        text: "Beschluss",
                        start: 12,
                        end: 13,
                        words: [.init(text: "Beschluss", start: 12.25, end: 12.75)]
                    ),
                ]
            ),
        ]
    )
}

private func audioData(_ audio: ValidatedMeetingTransferAudio) throws -> Data {
    let lease = try audio.leaseSource()
    defer { lease.close() }
    return try Data(contentsOf: lease.sourceURL)
}
