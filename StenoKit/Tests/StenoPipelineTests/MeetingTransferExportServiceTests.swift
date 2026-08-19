import Darwin
import Foundation
import StenoDomain
import StenoExchange
import StenoIdentity
import StenoLibrary
@testable import StenoPipeline
import Synchronization
import Testing

@Suite("Meeting transfer export service")
struct MeetingTransferExportServiceTests {
    @Test("local import generation identity never enters a transfer package")
    func excludesLocalImportGeneration() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "library"))
            let meetingID = MeetingID()
            let generationID = MeetingTransferGenerationID(
                rawValue: UUID(
                    uuidString: "018f22e2-7c00-7000-8000-00000000abcd"
                )!
            )
            let receipt = MeetingTransferReceipt(
                sourceMeetingID: meetingID,
                sourceRevisionID: nil,
                sourcePackageContentDigest: String(repeating: "e", count: 64),
                importedAt: Date(timeIntervalSinceReferenceDate: 1),
                sourceAppVersion: nil,
                includedCapabilities: [.notes],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: generationID
            )
            _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: Meeting(
                    id: meetingID,
                    title: "Imported",
                    status: .ready,
                    metadata: MeetingMetadata(transferReceipt: receipt)
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly,
                notes: [.init(fileName: "user-notes.md", data: Data("Note".utf8))]
            ))

            let result = try await MeetingTransferExportService(library: library).export(
                meetingID: meetingID,
                selectedAudioAssetIDs: [],
                temporaryRoot: root.appending(path: "export"),
                sourceAppVersion: nil
            )

            let bytes = try Data(contentsOf: result.packageURL)
            #expect(bytes.range(of: Data(generationID.description.utf8)) == nil)
        }
    }

    @Test("a cleanly ended meeting offers registered existing audio")
    func cleanlyEndedMeetingOffersAudio() async throws {
        try await withTemporaryDirectory { root in
            let readyLibrary = try Library.open(at: root.appending(path: "ready"))
            let ready = try await readyLibrary.createMeeting(title: "Ready", status: .ready)
            let readyAsset = try await registerAudio(in: readyLibrary, meeting: ready, root: root)
            let readyPreview = try await MeetingTransferExportService(
                library: readyLibrary
            ).preview(meetingID: ready.id)
            #expect(readyPreview.audioTracks.map(\.assetID) == [readyAsset.id])

            let processingLibrary = try Library.open(at: root.appending(path: "processing"))
            let processing = try await processingLibrary.createMeeting(
                title: "Processing",
                status: .processing
            )
            let processingAsset = try await registerAudio(
                in: processingLibrary,
                meeting: processing,
                root: root
            )
            let processingService = MeetingTransferExportService(library: processingLibrary)
            let processingPreview = try await processingService.preview(
                meetingID: processing.id
            )
            #expect(processingPreview.audioTracks.map(\.assetID) == [processingAsset.id])
            let processingExport = try await processingService.export(
                meetingID: processing.id,
                selectedAudioAssetIDs: [processingAsset.id],
                temporaryRoot: root.appending(path: "processing-export"),
                sourceAppVersion: "test"
            )
            #expect(processingExport.capabilities.contains(.audio))
            let validated = try await MeetingTransferArchiveReader().validate(
                at: processingExport.packageURL,
                validationRoot: root.appending(path: "processing-validation")
            )
            defer { try? validated.close() }
            #expect(validated.meeting.sourceStatus == .ready)

            _ = try await processingLibrary.updateMeetingStatus(processing.id, to: .ready)
            let nativeMatch = try await processingService.nativeMeetingTransferMatch(
                for: validated
            )
            #expect(nativeMatch.contentDigest == processingExport.contentDigest)

            let interruptedLibrary = try Library.open(at: root.appending(path: "interrupted"))
            let interrupted = try await interruptedLibrary.createMeeting(
                title: "Interrupted",
                status: .interrupted
            )
            let interruptedAsset = try await registerAudio(
                in: interruptedLibrary,
                meeting: interrupted,
                root: root
            )
            let service = MeetingTransferExportService(library: interruptedLibrary)
            #expect(try await service.preview(meetingID: interrupted.id).audioTracks.isEmpty)
            await #expect(throws: MeetingTransferExportError.audioNotEligible) {
                try await service.export(
                    meetingID: interrupted.id,
                    selectedAudioAssetIDs: [interruptedAsset.id],
                    temporaryRoot: root.appending(path: "interrupted-export"),
                    sourceAppVersion: "test"
                )
            }
        }
    }

    @Test("a readable non-CAF asset is not offered for export")
    func readableNonCAFIsNotEligible() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "library"))
            let meeting = try await library.createMeeting(title: "WAV", status: .ready)
            let source = root.appending(path: "source.wav")
            try makePipelineTestCAF(at: source)
            #expect(try Data(contentsOf: source).prefix(4) == Data("RIFF".utf8))
            let asset = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 8_000,
                duration: 0.01
            )

            let service = MeetingTransferExportService(library: library)
            let preview = try await service.preview(meetingID: meeting.id)
            #expect(!preview.audioTracks.contains { $0.assetID == asset.id })
        }
    }

    @Test("preview and export reject a registered FIFO without waiting for a writer")
    func registeredFIFOIsRejectedPromptly() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "library"))
            let meeting = try await library.createMeeting(title: "FIFO", status: .ready)
            let asset = try await registerAudio(in: library, meeting: meeting, root: root)
            let source = library.layout.mediaFile(meeting.id, fileName: asset.fileName)
            try FileManager.default.removeItem(at: source)
            guard mkfifo(source.path, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let service = MeetingTransferExportService(library: library)

            let previewWriterOpened = LockedFlag()
            let previewUnblocker = delayedFIFOUnblocker(
                source,
                writerOpened: previewWriterOpened
            )
            let clock = ContinuousClock()
            let previewStarted = clock.now
            let preview = try await service.preview(meetingID: meeting.id)
            let previewElapsed = previewStarted.duration(to: clock.now)
            previewUnblocker.cancel()
            await previewUnblocker.value

            #expect(preview.audioTracks.isEmpty)
            #expect(previewElapsed < .milliseconds(250))
            #expect(!previewWriterOpened.value.withLock { $0 })

            let exportWriterOpened = LockedFlag()
            let exportUnblocker = delayedFIFOUnblocker(
                source,
                writerOpened: exportWriterOpened
            )
            let exportRoot = root.appending(path: "export")
            let exportStarted = clock.now
            await #expect(throws: MeetingTransferExportError.audioNotEligible) {
                try await service.export(
                    meetingID: meeting.id,
                    selectedAudioAssetIDs: [asset.id],
                    temporaryRoot: exportRoot,
                    sourceAppVersion: nil
                )
            }
            let exportElapsed = exportStarted.duration(to: clock.now)
            exportUnblocker.cancel()
            await exportUnblocker.value

            #expect(exportElapsed < .milliseconds(250))
            #expect(!exportWriterOpened.value.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: exportRoot.path))
        }
    }

    @Test("export rejects an atomic same-shape CAF replacement after preparation")
    func rejectsAtomicCAFReplacementAfterPreparation() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "library"))
            let meeting = try await library.createMeeting(title: "Swap", status: .ready)
            let asset = try await registerAudio(in: library, meeting: meeting, root: root)
            let source = library.layout.mediaFile(meeting.id, fileName: asset.fileName)
            let replacement = root.appending(path: "replacement.caf")
            try makePipelineTestCAF(at: replacement, sampleOffset: 3)
            let sourceData = try Data(contentsOf: source)
            let replacementData = try Data(contentsOf: replacement)
            #expect(sourceData.count == replacementData.count)
            #expect(sourceData != replacementData)
            let inspector = MeetingTransferAudioInspector()
            let sourceInspection = try inspector.inspectCAFSource(at: source)
            let replacementInspection = try inspector.inspectCAFSource(at: replacement)
            #expect(sourceInspection.byteCount == replacementInspection.byteCount)
            #expect(sourceInspection.sampleRate == replacementInspection.sampleRate)
            #expect(sourceInspection.channelCount == replacementInspection.channelCount)
            #expect(sourceInspection.duration == replacementInspection.duration)

            let didSwap = Mutex(false)
            let service = MeetingTransferExportService(
                library: library,
                exportCheckpoint: { checkpoint in
                    guard checkpoint == .afterAudioPreparation else { return }
                    try didSwap.withLock { swapped in
                        guard !swapped else { return }
                        guard rename(replacement.path, source.path) == 0 else {
                            throw POSIXError(.init(rawValue: errno) ?? .EIO)
                        }
                        swapped = true
                    }
                }
            )
            let exportRoot = root.appending(path: "swap-export")

            await #expect(
                throws: MeetingTransferArchiveWriterError.sourceIdentityMismatch("track-1")
            ) {
                try await service.export(
                    meetingID: meeting.id,
                    selectedAudioAssetIDs: [asset.id],
                    temporaryRoot: exportRoot,
                    sourceAppVersion: nil
                )
            }

            #expect(didSwap.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: exportRoot.path))
        }
    }

    @Test("missing unregistered and changed audio selections are rejected")
    func rejectsUnavailableAudioSelections() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "library"))
            let meeting = try await library.createMeeting(title: "Ready", status: .ready)
            try await MeetingNotesStore(layout: library.layout).setNotes(meeting.id, to: "Text")
            let asset = try await registerAudio(in: library, meeting: meeting, root: root)
            let service = MeetingTransferExportService(library: library)
            let preview = try await service.preview(meetingID: meeting.id)
            #expect(preview.audioTracks.map(\.assetID) == [asset.id])

            await #expect(throws: MeetingTransferExportError.audioNotEligible) {
                try await service.export(
                    meetingID: meeting.id,
                    selectedAudioAssetIDs: [MediaAssetID()],
                    temporaryRoot: root.appending(path: "unknown-export"),
                    sourceAppVersion: nil
                )
            }

            try FileManager.default.removeItem(
                at: library.layout.mediaMetadata(meeting.id, assetID: asset.id)
            )
            await #expect(throws: MeetingTransferExportError.audioNotEligible) {
                try await service.export(
                    meetingID: meeting.id,
                    selectedAudioAssetIDs: [asset.id],
                    temporaryRoot: root.appending(path: "changed-export"),
                    sourceAppVersion: nil
                )
            }

            let secondAsset = try await registerAudio(
                in: library,
                meeting: meeting,
                root: root,
                kind: .systemTrack
            )
            try FileManager.default.removeItem(
                at: library.layout.mediaFile(meeting.id, fileName: secondAsset.fileName)
            )
            let afterMissingFile = try await service.preview(meetingID: meeting.id)
            #expect(!afterMissingFile.audioTracks.contains { $0.assetID == secondAsset.id })
        }
    }

    @Test("an export without notes transcript or selected audio is rejected")
    func rejectsEmptyPackage() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "library"))
            let meeting = try await library.createMeeting(title: "Empty", status: .ready)
            let service = MeetingTransferExportService(library: library)
            #expect(try await service.preview(meetingID: meeting.id).textOnlyIsValid == false)

            await #expect(throws: MeetingTransferExportError.emptyPayload) {
                try await service.export(
                    meetingID: meeting.id,
                    selectedAudioAssetIDs: [],
                    temporaryRoot: root.appending(path: "export"),
                    sourceAppVersion: nil
                )
            }
        }
    }

    @Test("notes word times and safe speaker labels survive export")
    func exportsPortableTextSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePrivacyFixture(at: root)
            let service = MeetingTransferExportService(library: fixture.library)
            let preview = try await service.preview(meetingID: fixture.meeting.id)
            #expect(preview.includesNotes)
            #expect(preview.includesTranscript)
            #expect(preview.visibleSpeakerLabels == [
                "Ada Confirmed", "Ada Confirmed", "Speaker 3", "Speaker 4",
            ])

            let result = try await service.export(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: [],
                temporaryRoot: root.appending(path: "text-export"),
                sourceAppVersion: "Steno/Test-4"
            )
            let validated = try await MeetingTransferArchiveReader().validate(
                at: result.packageURL,
                validationRoot: root.appending(path: "text-validation")
            )
            defer { try? validated.close() }

            #expect(validated.notes == "Plan\n[00:12:34] Beschluss")
            let transcript = try #require(validated.transcript)
            #expect(transcript.turns[0].segments[0].words[0].start == 0.25)
            #expect(transcript.turns[0].segments[0].words[0].end == 0.75)
            #expect(transcript.speakers.map(\.label) == [
                "Ada Confirmed", "Ada Confirmed", "Speaker 3", "Speaker 4",
            ])
            #expect(transcript.speakers.map(\.kind) == [
                .confirmedDisplayName, .confirmedDisplayName, .generic, .generic,
            ])
            #expect(validated.manifest.sourceRevisionID == fixture.revision.id)
            #expect(validated.manifest.sourceAppVersion == "Steno/Test-4")
            #expect(result.contentDigest == validated.manifest.contentDigest)
        }
    }

    @Test("a confirmed mixed cluster remains a generic export label")
    func mixedClusterRemainsGeneric() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "library"))
            let meeting = try await library.createMeeting(title: "Mixed", status: .ready)
            let runID = RunID()
            let person = Person(displayName: "Must Not Export")
            try await IdentityStore(layout: library.layout).replacePersons([person])

            let revision = TranscriptRevision(
                meetingID: meeting.id,
                origin: .finalRun(runID),
                turns: [
                    TranscriptTurn(
                        speaker: .cluster(runID: runID, clusterID: "mixed"),
                        start: 0,
                        end: 1,
                        segments: [
                            TranscriptSegment(
                                text: "Mixed",
                                start: 0,
                                end: 1,
                                words: []
                            ),
                        ]
                    ),
                ]
            )
            _ = try await library.appendRevision(revision)
            try installSingleClusterReview(
                layout: library.layout,
                meetingID: meeting.id,
                revisionID: revision.id,
                runID: runID,
                personID: person.id,
                containsMultipleSpeakers: true,
                isSelf: false
            )

            let service = MeetingTransferExportService(library: library)
            let preview = try await service.preview(meetingID: meeting.id)
            #expect(preview.visibleSpeakerLabels == ["Speaker 1"])
            let result = try await service.export(
                meetingID: meeting.id,
                selectedAudioAssetIDs: [],
                temporaryRoot: root.appending(path: "export"),
                sourceAppVersion: nil
            )
            let validated = try await MeetingTransferArchiveReader().validate(
                at: result.packageURL,
                validationRoot: root.appending(path: "validation")
            )
            defer { try? validated.close() }
            let speaker = try #require(validated.transcript?.speakers.first)
            #expect(speaker.label == "Speaker 1")
            #expect(speaker.kind == .generic)
        }
    }

    @Test("privacy sentinels never enter text or explicitly selected audio packages")
    func excludesPrivateLibraryData() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePrivacyFixture(at: root)
            let service = MeetingTransferExportService(library: fixture.library)
            let preview = try await service.preview(meetingID: fixture.meeting.id)
            let assetID = try #require(preview.audioTracks.first?.assetID)

            let text = try await service.export(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: [],
                temporaryRoot: root.appending(path: "text-export"),
                sourceAppVersion: nil
            )
            let audio = try await service.export(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: [assetID],
                temporaryRoot: root.appending(path: "audio-export"),
                sourceAppVersion: nil
            )

            let forbidden = [
                "sentinel-person-email", "sentinel-company", "sentinel-embedding",
                "sentinel-review", "sentinel-suggestion", "sentinel-run",
                "sentinel-report", "sentinel-job", "sentinel-participant",
                "sentinel-folder", "sentinel-capture", "sentinel-model",
                fixture.confirmedPerson.id.description,
                fixture.participantID.description,
                fixture.folderID.description,
                fixture.diarizationRunID.description,
                assetID.description,
            ]
            for package in [text.packageURL, audio.packageURL] {
                let bytes = try Data(contentsOf: package)
                for token in forbidden {
                    #expect(bytes.range(of: Data(token.utf8)) == nil)
                }
                #expect(bytes.range(of: Data("Ada Confirmed".utf8)) != nil)
            }

            let validated = try await MeetingTransferArchiveReader().validate(
                at: audio.packageURL,
                validationRoot: root.appending(path: "audio-validation")
            )
            defer { try? validated.close() }
            #expect(validated.audio.count == 1)
            #expect(validated.manifest.capabilities == [.notes, .transcript, .audio])
            #expect(audio.contentDigest == validated.manifest.contentDigest)
        }
    }
}

private struct PrivacyFixture {
    let library: Library
    let meeting: Meeting
    let revision: TranscriptRevision
    let confirmedPerson: Person
    let participantID: PersonID
    let folderID: FolderID
    let diarizationRunID: RunID
}

private func registerAudio(
    in library: Library,
    meeting: Meeting,
    root: URL,
    kind: MediaAsset.Kind = .micTrack
) async throws -> MediaAsset {
    let source = root.appending(path: "source-\(UUID().uuidString).caf")
    try makePipelineTestCAF(at: source)
    return try await library.registerMediaAsset(
        for: meeting.id,
        sourceURL: source,
        kind: kind,
        sampleRate: 8_000,
        duration: 0.01
    )
}

private func delayedFIFOUnblocker(
    _ fifo: URL,
    writerOpened: LockedFlag
) -> Task<Void, Never> {
    Task.detached {
        do {
            try await Task.sleep(for: .milliseconds(500))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        writerOpened.value.withLock { $0 = true }
        _ = Darwin.close(descriptor)
    }
}

private final class LockedFlag: @unchecked Sendable {
    let value = Mutex(false)
}

private func makePrivacyFixture(at root: URL) async throws -> PrivacyFixture {
    let library = try Library.open(at: root.appending(path: "library"))
    let participant = Person(displayName: "sentinel-participant")
    let folderID = FolderID()
    var meeting = try await library.createMeeting(title: "Privacy", status: .ready)
    meeting = try await library.setMeetingParticipants(
        meeting.id,
        participantIDs: [participant.id]
    )
    meeting = try await library.setMeetingFolder(meeting.id, folderID: folderID)
    try await MeetingNotesStore(layout: library.layout).setNotes(
        meeting.id,
        to: "Plan\n[00:12:34] Beschluss"
    )
    _ = try await registerAudio(in: library, meeting: meeting, root: root)

    let diarizationRunID = RunID()
    let confirmedPersonID = PersonID()
    let confirmedPerson = Person(
        id: confirmedPersonID,
        displayName: "Ada Confirmed",
        email: "sentinel-person-email",
        organization: "sentinel-company",
        prototypes: [
            SpeakerPrototype(
                personID: confirmedPersonID,
                embedding: [0.125, 0.25],
                recordingType: .inPerson,
                channel: MediaAsset.Kind.micTrack.rawValue,
                meetingID: meeting.id,
                runID: diarizationRunID,
                clusterID: "sentinel-embedding",
                speechDurationSeconds: 1,
                segmentCount: 1,
                source: .userConfirmed
            ),
        ]
    )
    try await IdentityStore(layout: library.layout).replacePersons([
        confirmedPerson, participant,
    ])

    let references: [SpeakerReference] = [
        .person(confirmedPerson.id),
        .cluster(runID: diarizationRunID, clusterID: "sentinel-review-confirmed"),
        .cluster(runID: diarizationRunID, clusterID: "stale-cluster"),
        .cluster(runID: diarizationRunID, clusterID: "suggested-cluster"),
    ]
    let revision = TranscriptRevision(
        meetingID: meeting.id,
        origin: .finalRun(diarizationRunID),
        turns: references.enumerated().map { offset, reference in
            let start = Double(offset)
            return TranscriptTurn(
                speaker: reference,
                start: start,
                end: start + 1,
                segments: [
                    TranscriptSegment(
                        text: "Turn \(offset + 1)",
                        start: start,
                        end: start + 1,
                        words: [
                            TranscriptWord(
                                text: "Turn",
                                start: start + 0.25,
                                end: start + 0.75
                            ),
                        ]
                    ),
                ]
            )
        }
    )
    _ = try await library.appendRevision(revision)

    try installReviewArtifacts(
        layout: library.layout,
        meetingID: meeting.id,
        revisionID: revision.id,
        diarizationRunID: diarizationRunID,
        confirmedPersonID: confirmedPerson.id
    )
    try writeSentinelFiles(layout: library.layout, meetingID: meeting.id)
    return PrivacyFixture(
        library: library,
        meeting: meeting,
        revision: revision,
        confirmedPerson: confirmedPerson,
        participantID: participant.id,
        folderID: folderID,
        diarizationRunID: diarizationRunID
    )
}

private func installReviewArtifacts(
    layout: LibraryLayout,
    meetingID: MeetingID,
    revisionID: RevisionID,
    diarizationRunID: RunID,
    confirmedPersonID: PersonID
) throws {
    let engine = EngineDescriptor(name: "sentinel-run", version: "1")
    let track = DiarizationTrackResult(
        assetID: MediaAssetID(),
        assetKind: .micTrack,
        engine: engine,
        segments: [],
        clusters: [
            .init(
                clusterID: "sentinel-review-confirmed",
                embedding: [0.1],
                speechDurationSeconds: 3,
                segmentCount: 1
            ),
            .init(
                clusterID: "stale-cluster",
                embedding: [0.2],
                speechDurationSeconds: 2,
                segmentCount: 1
            ),
            .init(
                clusterID: "suggested-cluster",
                embedding: [0.3],
                speechDurationSeconds: 1,
                segmentCount: 1
            ),
        ]
    )
    let diarizationDirectory = layout.runDirectory(meetingID, runID: diarizationRunID)
    try FileManager.default.createDirectory(
        at: diarizationDirectory,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(
        DiarizationArtifact(
            jobID: JobID(),
            sourceRunID: RunID(),
            revisionID: revisionID,
            tracks: [track]
        )
    ).write(to: layout.runDiarization(meetingID, runID: diarizationRunID))

    let suggestionRun = ProcessingRun(
        meetingID: meetingID,
        kind: .identitySuggestion,
        engine: engine,
        status: .finished
    )
    let suggestionDirectory = layout.runDirectory(meetingID, runID: suggestionRun.id)
    try FileManager.default.createDirectory(
        at: suggestionDirectory,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(suggestionRun).write(
        to: layout.runMetadata(meetingID, runID: suggestionRun.id)
    )
    try JSONEncoder().encode(
        IdentitySuggestionArtifact(
            jobID: JobID(),
            sourceRunID: diarizationRunID,
            clusterResolutions: [],
            identityEvidenceFingerprint: "sentinel-suggestion",
            suggestions: [
                ClusterSuggestion(
                    meetingID: meetingID,
                    runID: diarizationRunID,
                    channel: MediaAsset.Kind.micTrack.rawValue,
                    clusterID: "suggested-cluster",
                    status: .confirmed,
                    suggestedPersonID: confirmedPersonID,
                    suggestedName: "sentinel-suggestion"
                ),
            ]
        )
    ).write(to: suggestionDirectory.appending(path: "suggestions.json"))

    let clusters = [
        IdentityCluster(
            meetingID: meetingID,
            runID: diarizationRunID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "sentinel-review-confirmed",
            recordingType: .inPerson,
            embedding: [0.1],
            speechDurationSeconds: 3,
            segmentCount: 1,
            reviewState: .confirmed(confirmedPersonID)
        ),
        IdentityCluster(
            meetingID: meetingID,
            runID: diarizationRunID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "stale-cluster",
            recordingType: .inPerson,
            embedding: [0.2],
            speechDurationSeconds: 2,
            segmentCount: 1,
            reviewState: .stale(confirmedPersonID)
        ),
        IdentityCluster(
            meetingID: meetingID,
            runID: diarizationRunID,
            channel: MediaAsset.Kind.micTrack.rawValue,
            clusterID: "suggested-cluster",
            recordingType: .inPerson,
            embedding: [0.3],
            speechDurationSeconds: 1,
            segmentCount: 1,
            reviewState: .unreviewed
        ),
    ]
    try MeetingReviewStore(layout: layout).save(
        MeetingReviewDocument(runID: diarizationRunID, clusters: clusters),
        meetingID: meetingID
    )
}

private func installSingleClusterReview(
    layout: LibraryLayout,
    meetingID: MeetingID,
    revisionID: RevisionID,
    runID: RunID,
    personID: PersonID,
    containsMultipleSpeakers: Bool,
    isSelf: Bool
) throws {
    let engine = EngineDescriptor(name: "test", version: "1")
    let diarizationDirectory = layout.runDirectory(meetingID, runID: runID)
    try FileManager.default.createDirectory(
        at: diarizationDirectory,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(
        DiarizationArtifact(
            jobID: JobID(),
            sourceRunID: RunID(),
            revisionID: revisionID,
            tracks: [
                DiarizationTrackResult(
                    assetID: MediaAssetID(),
                    assetKind: .micTrack,
                    engine: engine,
                    segments: [],
                    clusters: [
                        .init(
                            clusterID: "mixed",
                            embedding: [0.1, 0.2],
                            speechDurationSeconds: 3,
                            segmentCount: 1
                        ),
                    ]
                ),
            ]
        )
    ).write(to: layout.runDiarization(meetingID, runID: runID))

    let suggestionRun = ProcessingRun(
        meetingID: meetingID,
        kind: .identitySuggestion,
        engine: engine,
        status: .finished
    )
    let suggestionDirectory = layout.runDirectory(meetingID, runID: suggestionRun.id)
    try FileManager.default.createDirectory(
        at: suggestionDirectory,
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(suggestionRun).write(
        to: layout.runMetadata(meetingID, runID: suggestionRun.id)
    )
    try JSONEncoder().encode(
        IdentitySuggestionArtifact(
            jobID: JobID(),
            sourceRunID: runID,
            clusterResolutions: [],
            identityEvidenceFingerprint: "mixed",
            suggestions: []
        )
    ).write(to: suggestionDirectory.appending(path: "suggestions.json"))

    try MeetingReviewStore(layout: layout).save(
        MeetingReviewDocument(
            runID: runID,
            clusters: [
                IdentityCluster(
                    meetingID: meetingID,
                    runID: runID,
                    channel: MediaAsset.Kind.micTrack.rawValue,
                    clusterID: "mixed",
                    recordingType: .inPerson,
                    embedding: [0.1, 0.2],
                    speechDurationSeconds: 3,
                    segmentCount: 1,
                    containsMultipleSpeakers: containsMultipleSpeakers,
                    reviewState: .confirmed(personID),
                    isSelf: isSelf
                ),
            ]
        ),
        meetingID: meetingID
    )
}

private func writeSentinelFiles(layout: LibraryLayout, meetingID: MeetingID) throws {
    try Data("sentinel-folder".utf8).write(to: layout.folders)
    try Data("sentinel-job".utf8).write(
        to: layout.jobsDirectory.appending(path: "sentinel-job.json")
    )
    try Data("sentinel-report".utf8).write(
        to: layout.reportsDirectory(meetingID).appending(path: "sentinel-report.json")
    )
    let capture = layout.captureDirectory(meetingID)
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    try Data("sentinel-capture".utf8).write(to: capture.appending(path: "partial.caf"))
    try Data("sentinel-model".utf8).write(to: layout.root.appending(path: "model.bin"))
}
