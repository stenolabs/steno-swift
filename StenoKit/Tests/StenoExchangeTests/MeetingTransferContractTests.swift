import CryptoKit
import Foundation
import Testing
@testable import StenoExchange
import StenoDomain

@Suite("Meeting transfer package contract")
struct MeetingTransferContractTests {
    @Test("portable JSON bytes are canonical and remain decodable")
    func portableJSONEncodingIsCanonical() throws {
        let document = try MeetingTransferMeetingDocument(
            sourceMeetingID: meetingID,
            title: "Planung",
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            sourceStatus: .ready
        )
        let expected = Data(
            #"{"createdAt":1000,"sourceMeetingID":"00000000-0000-7000-8000-000000000001","sourceStatus":"ready","title":"Planung"}"#.utf8
        )
        let encoded = try document.encodedData()
        #expect(encoded == expected)
        #expect(try JSONDecoder().decode(MeetingTransferMeetingDocument.self, from: encoded) == document)

        let packageManifest = try manifest(capabilities: [.notes], entries: [notesEntry])
        let manifestBytes = try packageManifest.encodedData()
        let manifestText = String(decoding: manifestBytes, as: UTF8.self)
        #expect(manifestText.hasPrefix(#"{"capabilities":["notes"],"contentDigest":"digest","entries":[{"byteCount":12,"mediaType":"application\/json","path":"meeting.json","sha256":"meeting"}"#))
        #expect(try JSONDecoder().decode(MeetingTransferManifest.self, from: manifestBytes) == packageManifest)

        let transcriptBytes = try transcript().encodedData()
        let audioBytes = try audioDocument().encodedData()
        let expectedPayloads = [encoded, transcriptBytes, audioBytes]
        let expectedDigest = try payloadDigest(expectedPayloads)
        for _ in 0..<32 {
            let payloads = try [
                document.encodedData(), transcript().encodedData(), audioDocument().encodedData(),
            ]
            #expect(payloads == expectedPayloads)
            #expect(try payloadDigest(payloads) == expectedDigest)
            #expect(try packageManifest.encodedData() == manifestBytes)
        }
    }

    @Test("manifest capabilities encode in canonical order and decode in any order")
    func manifestCapabilitiesAreCanonical() throws {
        let packageManifest = try manifest(
            capabilities: [.transcript, .audio, .notes],
            entries: [
                notesEntry,
                transcriptEntry,
                audioEntry(track: 1, extension: "caf"),
                audioMetadataEntry(track: 1),
            ]
        )
        let encoded = try packageManifest.encodedData()
        #expect(
            String(decoding: encoded, as: UTF8.self)
                .contains(#""capabilities":["audio","notes","transcript"]"#)
        )

        let reordered = try transferTestJSON(from: encoded) {
            $0["capabilities"] = ["transcript", "notes", "audio"]
        }
        #expect(
            try JSONDecoder().decode(MeetingTransferManifest.self, from: reordered).capabilities
                == [.audio, .notes, .transcript]
        )
    }

    @Test("text package round-trips")
    func textPackageRoundTrips() throws {
        let content = try MeetingTransferPackageContent(
            meeting: meeting(status: .processing),
            notes: "Plan\n[00:12:34] Beschluss",
            transcript: transcript(),
            audio: []
        )

        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(MeetingTransferPackageContent.self, from: data) == content)
        #expect(content.capabilities == [.notes, .transcript])
    }

    @Test("recording package round-trips")
    func recordingPackageRoundTrips() throws {
        let sourceLocale = try MeetingSourceLocale(
            localeIdentifier: "de-DE",
            origin: .explicit
        )
        let content = try MeetingTransferPackageContent(
            meeting: meeting(status: .ready),
            notes: nil,
            transcript: nil,
            audio: [try audioDocument()],
            sourceLocale: sourceLocale
        )

        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(MeetingTransferPackageContent.self, from: data) == content)
        #expect(content.capabilities == [.audio])
        #expect(content.sourceLocale == sourceLocale)
    }

    @Test("package locale must match a present transcript")
    func packageAndTranscriptLocaleMustMatch() throws {
        let sourceLocale = try MeetingSourceLocale(
            localeIdentifier: "en-US",
            origin: .explicit
        )

        #expect(throws: MeetingTransferContractError.inconsistentSourceLocale) {
            try MeetingTransferPackageContent(
                meeting: meeting(status: .ready),
                notes: nil,
                transcript: transcript(),
                audio: [],
                sourceLocale: sourceLocale
            )
        }
    }

    @Test("text and recording package round-trips")
    func textAndRecordingPackageRoundTrips() throws {
        let content = try MeetingTransferPackageContent(
            meeting: meeting(status: .ready),
            notes: "Beschluss",
            transcript: transcript(),
            audio: [try audioDocument()]
        )

        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(MeetingTransferPackageContent.self, from: data) == content)
        #expect(content.capabilities == [.notes, .transcript, .audio])
    }

    @Test("an empty package profile is rejected")
    func emptyProfileFails() {
        #expect(throws: MeetingTransferContractError.emptyPayload) {
            try MeetingTransferPackageContent(meeting: meeting(), notes: nil, transcript: nil, audio: [])
        }
    }

    @Test("recording payload requires a cleanly ended source meeting")
    func recordingRequiresCleanlyEndedMeeting() throws {
        _ = try MeetingTransferPackageContent(
            meeting: meeting(status: .ready),
            notes: nil,
            transcript: nil,
            audio: [try audioDocument()]
        )

        for status in [Meeting.Status.recording, .interrupted, .processing, .draft] {
            #expect(throws: MeetingTransferContractError.audioRequiresReadyMeeting) {
                try MeetingTransferPackageContent(
                    meeting: meeting(status: status),
                    notes: nil,
                    transcript: nil,
                    audio: [try audioDocument()]
                )
            }
        }
    }

    @Test("decode rejects an unknown format major")
    func rejectsUnknownFormatMajor() {
        let data = Data(
            """
            {
              "formatMajor": 2,
              "formatMinor": 0,
              "sourceMeetingID": "00000000-0000-7000-8000-000000000001",
              "exportedAt": 0,
              "capabilities": ["notes"],
              "localeOrigin": "absent",
              "entries": [{
                "path": "notes.md",
                "byteCount": 1,
                "mediaType": "text/markdown",
                "sha256": "notes"
              }],
              "contentDigest": "digest"
            }
            """.utf8
        )
        #expect(throws: MeetingTransferContractError.unsupportedFormatMajor(2)) {
            try JSONDecoder().decode(MeetingTransferManifest.self, from: data)
        }
    }

    @Test("decode rejects an unknown capability")
    func rejectsUnknownCapability() {
        let data = Data(
            """
            {
              "formatMajor": 1,
              "formatMinor": 0,
              "sourceMeetingID": "00000000-0000-7000-8000-000000000001",
              "exportedAt": 0,
              "capabilities": ["notes", "unknown"],
              "localeOrigin": "absent",
              "entries": [],
              "contentDigest": "digest"
            }
            """.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MeetingTransferManifest.self, from: data)
        }
    }

    @Test("decode rejects capabilities that contradict entries")
    func rejectsContradictoryCapabilities() {
        let data = Data(
            """
            {
              "formatMajor": 1,
              "formatMinor": 0,
              "sourceMeetingID": "00000000-0000-7000-8000-000000000001",
              "exportedAt": 0,
              "capabilities": ["notes"],
              "localeOrigin": "absent",
              "entries": [{
                "path": "meeting.json",
                "byteCount": 1,
                "mediaType": "application/json",
                "sha256": "meeting"
              }, {
                "path": "transcript.json",
                "byteCount": 1,
                "mediaType": "application/json",
                "sha256": "transcript"
              }],
              "contentDigest": "digest"
            }
            """.utf8
        )
        #expect(throws: MeetingTransferContractError.inconsistentCapabilities) {
            try JSONDecoder().decode(MeetingTransferManifest.self, from: data)
        }
    }

    @Test("manifest never describes itself")
    func manifestIsNotAnEntry() {
        #expect(throws: MeetingTransferContractError.manifestMustNotBeAnEntry) {
            try manifest(capabilities: [], entries: [
                MeetingTransferManifest.Entry(
                    path: "manifest.json", byteCount: 10, mediaType: "application/json", sha256: "abc"
                ),
            ])
        }
    }

    @Test("manifest requires exactly one meeting document")
    func manifestRequiresExactlyOneMeetingDocument() {
        #expect(throws: MeetingTransferContractError.missingMeetingDocument) {
            try MeetingTransferManifest(
                sourceMeetingID: meetingID,
                sourceRevisionID: nil,
                exportedAt: .distantPast,
                sourceAppVersion: nil,
                capabilities: [.notes],
                localeIdentifier: nil,
                localeOrigin: .absent,
                entries: [notesEntry],
                contentDigest: "digest"
            )
        }
        #expect(throws: MeetingTransferContractError.duplicateManifestEntryPath("meeting.json")) {
            try manifest(capabilities: [], entries: [meetingEntry])
        }
    }

    @Test("manifest rejects unknown duplicate and malformed V1 paths")
    func manifestRejectsNonAllowlistedPaths() {
        #expect(throws: MeetingTransferContractError.invalidManifestEntryPath("reports/report.md")) {
            try manifest(capabilities: [], entries: [
                MeetingTransferManifest.Entry(
                    path: "reports/report.md", byteCount: 1, mediaType: "text/markdown", sha256: "report"
                ),
            ])
        }
        #expect(throws: MeetingTransferContractError.duplicateManifestEntryPath("notes.md")) {
            try manifest(capabilities: [.notes], entries: [notesEntry, notesEntry])
        }
        #expect(throws: MeetingTransferContractError.invalidManifestEntryPath("audio/track-01.caf")) {
            try manifest(capabilities: [.audio], entries: [
                audioEntry(track: 1, extension: "caf"),
                audioMetadataEntry(track: 1),
                MeetingTransferManifest.Entry(
                    path: "audio/track-01.caf", byteCount: 1, mediaType: "audio/x-caf", sha256: "bad"
                ),
            ])
        }
    }

    @Test("manifest requires canonical paired sequential audio tracks")
    func manifestRequiresCompleteCanonicalAudioPairs() {
        #expect(throws: MeetingTransferContractError.unpairedAudioTrack("track-1")) {
            try manifest(capabilities: [.audio], entries: [audioEntry(track: 1, extension: "caf")])
        }
        #expect(throws: MeetingTransferContractError.noncanonicalAudioTrack("track-2")) {
            try manifest(capabilities: [.audio], entries: [
                audioEntry(track: 2, extension: "caf"),
                audioMetadataEntry(track: 2),
            ])
        }
        #expect(throws: MeetingTransferContractError.invalidManifestEntryPath("audio/track-1.wav")) {
            try manifest(capabilities: [.audio], entries: [
                audioEntry(track: 1, extension: "wav"),
                audioMetadataEntry(track: 1),
            ])
        }
    }

    @Test("newer minor cannot add an unknown V1 entry")
    func newerMinorCannotSmuggleUnknownEntry() {
        #expect(throws: MeetingTransferContractError.invalidManifestEntryPath("future.json")) {
            try MeetingTransferManifest(
                formatMinor: 1,
                sourceMeetingID: meetingID,
                sourceRevisionID: nil,
                exportedAt: .distantPast,
                sourceAppVersion: nil,
                capabilities: [],
                localeIdentifier: nil,
                localeOrigin: .absent,
                entries: [meetingEntry, MeetingTransferManifest.Entry(
                    path: "future.json", byteCount: 1, mediaType: "application/json", sha256: "future"
                )],
                contentDigest: "digest"
            )
        }
    }

    @Test("file count includes the manifest")
    func fileCountIncludesManifest() {
        let entries = (0 ..< MeetingTransferLimits.maximumFileCount).map { index in
            MeetingTransferManifest.Entry(
                path: "audio/track-\(index).caf",
                byteCount: 1,
                mediaType: "audio/x-caf",
                sha256: "\(index)"
            )
        }

        #expect(throws: MeetingTransferContractError.fileCountExceedsLimit) {
            try manifest(capabilities: [.audio], entries: entries)
        }
    }

    @Test("total DAT bytes include the manifest")
    func totalBytesIncludeManifest() {
        let twelveGiB: Int64 = 12 * 1_024 * 1_024 * 1_024
        #expect(throws: MeetingTransferContractError.totalBytesExceedLimit) {
            try manifest(capabilities: [.audio], entries: [
                MeetingTransferManifest.Entry(
                    path: "audio/track-1.caf", byteCount: twelveGiB, mediaType: "audio/x-caf", sha256: "audio-1"
                ),
                audioMetadataEntry(track: 1),
                MeetingTransferManifest.Entry(
                    path: "audio/track-2.caf", byteCount: twelveGiB, mediaType: "audio/x-caf", sha256: "audio-2"
                ),
                audioMetadataEntry(track: 2),
            ])
        }
    }

    @Test("manifest meeting document and audio metadata enforce their own byte limits")
    func payloadByteLimitsAreEnforced() throws {
        #expect(throws: MeetingTransferContractError.meetingDocumentExceedsLimit) {
            try MeetingTransferMeetingDocument.validateEncodedByteCount(
                MeetingTransferLimits.maximumMeetingDocumentBytes + 1
            )
        }

        #expect(throws: MeetingTransferContractError.audioMetadataExceedsLimit) {
            try MeetingTransferAudioDocument(
                logicalTrackID: String(repeating: "a", count: MeetingTransferLimits.maximumAudioMetadataBytes + 1),
                kind: .micTrack,
                byteCount: 1,
                sha256: "abc",
                sampleRate: 48_000,
                channelCount: 1,
                duration: 1
            ).encodedData()
        }

        #expect(throws: MeetingTransferContractError.manifestExceedsLimit) {
            try MeetingTransferManifest(
                sourceMeetingID: meetingID,
                sourceRevisionID: nil,
                exportedAt: .distantPast,
                sourceAppVersion: String(repeating: "a", count: MeetingTransferLimits.maximumManifestBytes + 1),
                capabilities: [],
                localeIdentifier: nil,
                localeOrigin: .absent,
                entries: [meetingEntry],
                contentDigest: "digest"
            )
        }
    }

    @Test("payload constructors enforce notes titles and audio limits")
    func payloadConstructorsEnforceLimits() {
        #expect(throws: MeetingTransferContractError.notesExceedsLimit) {
            try MeetingTransferPackageContent(
                meeting: meeting(),
                notes: String(repeating: "a", count: MeetingTransferLimits.maximumNotesBytes + 1),
                transcript: nil,
                audio: []
            )
        }
        #expect(throws: MeetingTransferContractError.meetingTitleExceedsLimit) {
            try MeetingTransferMeetingDocument(
                sourceMeetingID: meetingID,
                title: String(repeating: "é", count: 513),
                createdAt: .distantPast,
                sourceStatus: .draft
            )
        }
        #expect(throws: MeetingTransferContractError.invalidAudioByteCount) {
            try MeetingTransferAudioDocument(
                logicalTrackID: "track-1", kind: .micTrack, byteCount: 0, sha256: "audio",
                sampleRate: 48_000, channelCount: 1, duration: 1
            )
        }
        #expect(throws: MeetingTransferContractError.audioBytesExceedLimit) {
            try MeetingTransferAudioDocument(
                logicalTrackID: "track-1", kind: .micTrack,
                byteCount: MeetingTransferLimits.maximumAudioBytes + 1, sha256: "audio",
                sampleRate: 48_000, channelCount: 1, duration: 1
            )
        }
    }

    @Test("payload decoders rerun constructor validation")
    func payloadDecodersRerunConstructorValidation() {
        let data = Data(
            """
            {
              "logicalTrackID": "track-1",
              "kind": "micTrack",
              "byteCount": -1,
              "sha256": "audio",
              "sampleRate": 48000,
              "channelCount": 1,
              "duration": 1
            }
            """.utf8
        )
        #expect(throws: MeetingTransferContractError.invalidAudioByteCount) {
            try JSONDecoder().decode(MeetingTransferAudioDocument.self, from: data)
        }
    }

    @Test("encoded payload accounting rejects exact boundary overflows without allocating them")
    func encodedPayloadAccountingRejectsBoundaryOverflows() {
        #expect(throws: MeetingTransferContractError.transcriptExceedsLimit) {
            try MeetingTransferTranscriptSnapshot.validateEncodedByteCount(
                MeetingTransferLimits.maximumTranscriptBytes + 1
            )
        }
        #expect(throws: MeetingTransferContractError.meetingDocumentExceedsLimit) {
            try MeetingTransferMeetingDocument.validateEncodedByteCount(
                MeetingTransferLimits.maximumMeetingDocumentBytes + 1
            )
        }
        #expect(throws: MeetingTransferContractError.audioMetadataExceedsLimit) {
            try MeetingTransferAudioDocument.validateEncodedByteCount(
                MeetingTransferLimits.maximumAudioMetadataBytes + 1
            )
        }
    }

    @Test("audio aggregation rejects totals above the package limit")
    func audioAggregationRejectsOversizedPackage() throws {
        let twelveGiB: Int64 = 12 * 1_024 * 1_024 * 1_024
        let audio = try [
            audioDocument(track: "track-1", byteCount: twelveGiB),
            audioDocument(track: "track-2", byteCount: twelveGiB),
            audioDocument(track: "track-3", byteCount: 1),
        ]
        #expect(throws: MeetingTransferContractError.audioBytesExceedLimit) {
            try MeetingTransferPackageContent(
                meeting: meeting(status: .ready), notes: nil, transcript: nil, audio: audio
            )
        }
    }

    @Test("audio aggregation accepts two individually valid 12 GiB tracks")
    func audioAggregationAcceptsTwoTwelveGiBTracks() throws {
        let twelveGiB: Int64 = 12 * 1_024 * 1_024 * 1_024
        let audio = try [
            audioDocument(track: "track-1", byteCount: twelveGiB),
            audioDocument(track: "track-2", byteCount: twelveGiB),
        ]

        _ = try MeetingTransferPackageContent(
            meeting: meeting(status: .ready), notes: nil, transcript: nil, audio: audio
        )
    }

    @Test("portable speaker labels reject whitespace and oversized values")
    func portableSpeakerLabelsAreBoundedAndNonEmpty() {
        #expect(throws: MeetingTransferContractError.invalidSpeakerLabel) {
            try MeetingTransferTranscriptSnapshot.Speaker(
                id: "speaker-1", label: " \n\t ", kind: .confirmedDisplayName
            )
        }
        #expect(throws: MeetingTransferContractError.speakerLabelExceedsLimit) {
            try MeetingTransferTranscriptSnapshot.Speaker(
                id: "speaker-1",
                label: String(repeating: "a", count: MeetingTransferLimits.maximumLabelBytes + 1),
                kind: .generic
            )
        }
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

    private var meetingEntry: MeetingTransferManifest.Entry {
        MeetingTransferManifest.Entry(
            path: "meeting.json", byteCount: 12, mediaType: "application/json", sha256: "meeting"
        )
    }

    private func meeting(status: Meeting.Status = .draft) -> MeetingTransferMeetingDocument {
        try! MeetingTransferMeetingDocument(
            sourceMeetingID: meetingID,
            title: "Planung",
            createdAt: .distantPast,
            sourceStatus: status
        )
    }

    private func transcript() -> MeetingTransferTranscriptSnapshot {
        try! MeetingTransferTranscriptSnapshot(
            localeIdentifier: "de-DE",
            localeOrigin: .explicit,
            speakers: [
                try! .init(id: "speaker-1", label: "Sprecher 1", kind: .generic),
            ],
            turns: [
                .init(
                    speakerID: "speaker-1",
                    start: 0,
                    end: 1,
                    segments: [.init(text: "Beschluss", start: 0, end: 1, words: [])]
                ),
            ]
        )
    }

    private func audioDocument(
        track: String = "track-1",
        byteCount: Int64 = 123
    ) throws -> MeetingTransferAudioDocument {
        try MeetingTransferAudioDocument(
            logicalTrackID: track,
            kind: .micTrack,
            byteCount: byteCount,
            sha256: "audio",
            sampleRate: 48_000,
            channelCount: 1,
            duration: 1
        )
    }

    private func audioEntry(track: Int, extension fileExtension: String) -> MeetingTransferManifest.Entry {
        MeetingTransferManifest.Entry(
            path: "audio/track-\(track).\(fileExtension)",
            byteCount: 1,
            mediaType: "audio/x-caf",
            sha256: "audio-\(track)"
        )
    }

    private func payloadDigest(_ payloads: [Data]) throws -> String {
        let paths = ["meeting.json", "transcript.json", "audio/track-1.json"]
        let entries = zip(paths, payloads).map { path, data in
            MeetingTransferManifest.Entry(
                path: path,
                byteCount: Int64(data.count),
                mediaType: "application/json",
                sha256: SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
            )
        }
        return try MeetingTransferDigest.contentDigest(for: entries)
    }

    private func audioMetadataEntry(track: Int) -> MeetingTransferManifest.Entry {
        MeetingTransferManifest.Entry(
            path: "audio/track-\(track).json",
            byteCount: 1,
            mediaType: "application/json",
            sha256: "metadata-\(track)"
        )
    }

    private func manifest(
        capabilities: Set<MeetingTransferCapability>,
        entries: [MeetingTransferManifest.Entry]
    ) throws -> MeetingTransferManifest {
        try MeetingTransferManifest(
            sourceMeetingID: meetingID,
            sourceRevisionID: nil,
            exportedAt: .distantPast,
            sourceAppVersion: "1.0",
            capabilities: capabilities,
            localeIdentifier: nil,
            localeOrigin: .absent,
            entries: [meetingEntry] + entries,
            contentDigest: "digest"
        )
    }
}
