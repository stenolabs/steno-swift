import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary
import StenoPipeline
import Testing
import UniformTypeIdentifiers
@testable import Steno

@Suite("Meeting transfer export presentation")
struct MeetingTransferExportPresentationTests {
    @Test("audio is off for every new export sheet")
    func audioDefaultsOff() {
        #expect(MeetingTransferExportPresentation.initialAudioSelection.isEmpty)
    }

    @Test("text payload names notes markers transcript and visible speakers")
    func textPayloadIsVisible() {
        let preview = makePreview(
            includesNotes: true,
            includesTranscript: true,
            visibleSpeakerLabels: ["Ada", "Speaker 2"]
        )

        #expect(MeetingTransferExportPresentation.textContent(for: preview) == [
            "Notes, including any time markers",
            "Transcript",
            "Speakers: Ada, Speaker 2",
        ])
    }

    @Test("audio summary and warning use only the selected offered tracks")
    func audioSelectionControlsSummaryAndWarning() {
        let microphoneID = MediaAssetID()
        let systemAudioID = MediaAssetID()
        let preview = makePreview(audioTracks: [
            .init(assetID: microphoneID, label: "Microphone", byteCount: 1_048_576),
            .init(assetID: systemAudioID, label: "System audio", byteCount: 2_097_152),
        ])

        #expect(MeetingTransferExportPresentation.audioSummary(
            for: preview,
            selectedAudioAssetIDs: [microphoneID]
        ) == "1 track selected, 1 MB total")
        let microphoneWarning = MeetingTransferExportPresentation.audioWarning(
            for: preview,
            selectedAudioAssetIDs: [microphoneID]
        )
        #expect(microphoneWarning?.contains("Adding 1 MB") == true)
        #expect(microphoneWarning?.contains("2 MB") == false)
        #expect(microphoneWarning?.contains("3 MB") == false)

        #expect(MeetingTransferExportPresentation.audioSummary(
            for: preview,
            selectedAudioAssetIDs: [systemAudioID]
        ) == "1 track selected, 2 MB total")
        #expect(MeetingTransferExportPresentation.audioWarning(
            for: preview,
            selectedAudioAssetIDs: [systemAudioID]
        )?.contains("Adding 2 MB") == true)

        #expect(MeetingTransferExportPresentation.audioSummary(
            for: preview,
            selectedAudioAssetIDs: [microphoneID, systemAudioID]
        ) == "2 tracks selected, 3 MB total")
        #expect(MeetingTransferExportPresentation.audioRows(for: preview) == [
            "Microphone - 1 MB",
            "System audio - 2 MB",
        ])
    }

    @Test("empty audio selection is explicitly off and has no audio warning")
    func emptyAudioSelectionHasNoWarning() {
        let audioID = MediaAssetID()
        let preview = makePreview(audioTracks: [
            .init(assetID: audioID, label: "Microphone", byteCount: 1_048_576),
        ])

        #expect(MeetingTransferExportPresentation.audioSummary(
            for: preview,
            selectedAudioAssetIDs: []
        ) == "Audio off - 0 tracks selected")
        #expect(MeetingTransferExportPresentation.audioWarning(
            for: preview,
            selectedAudioAssetIDs: []
        ) == nil)
        #expect(MeetingTransferExportPresentation.audioWarning(
            for: preview,
            selectedAudioAssetIDs: [MediaAssetID()]
        ) == nil)
    }

    @Test("selected audio warning names cleartext raw recording and bystanders")
    func warningIsConcrete() throws {
        let audioID = MediaAssetID()
        let preview = makePreview(audioTracks: [
            .init(assetID: audioID, label: "Microphone", byteCount: 1_048_576),
        ])
        let text = try #require(MeetingTransferExportPresentation.audioWarning(
            for: preview,
            selectedAudioAssetIDs: [audioID]
        ))

        #expect(text.contains("1 MB"))
        #expect(text.contains("unencrypted raw recording"))
        #expect(text.contains("other voices in the room"))
        #expect(text.contains("cleartext file"))
    }

    @Test("preparing keeps the share action name and exposes its progress separately")
    func preparingShareAccessibilityIsStable() {
        #expect(MeetingTransferExportPresentation.shareActionLabel == "Share meeting")
        #expect(
            MeetingTransferExportPresentation.shareAccessibilityValue(isPreparing: false).isEmpty
        )
        #expect(
            MeetingTransferExportPresentation.shareAccessibilityValue(isPreparing: true)
                == "Preparing package"
        )
        #expect(
            MeetingTransferExportPresentation.shareAccessibilityHint(isPreparing: true)
                .contains("being created")
        )
    }

    @Test("share stays disabled until the payload contains text or selected offered audio")
    func emptyPayloadCannotBeShared() {
        let audioID = MediaAssetID()
        let empty = makePreview(textOnlyIsValid: false)
        let audioOnly = makePreview(
            audioTracks: [.init(assetID: audioID, label: "Microphone", byteCount: 42)],
            textOnlyIsValid: false
        )

        #expect(!MeetingTransferExportPresentation.canShare(
            preview: empty,
            selectedAudioAssetIDs: []
        ))
        #expect(!MeetingTransferExportPresentation.canShare(
            preview: audioOnly,
            selectedAudioAssetIDs: []
        ))
        #expect(!MeetingTransferExportPresentation.canShare(
            preview: audioOnly,
            selectedAudioAssetIDs: [MediaAssetID()]
        ))
        #expect(MeetingTransferExportPresentation.canShare(
            preview: audioOnly,
            selectedAudioAssetIDs: [audioID]
        ))
    }

    @Test("the sheet explicitly directs the user to AirDrop")
    func airDropInstructionIsExplicit() {
        #expect(
            MeetingTransferExportPresentation.airDropInstruction
                == "Choose AirDrop in the share sheet."
        )
    }

    @Test("the local document type is the shareable archive from the approved contract")
    func documentTypeMatchesContract() throws {
        #expect(UTType.stenoMeetingTransfer.identifier == "org.steno.meeting-transfer")

        let declarations = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations")
                as? [[String: Any]]
        )
        let meetingTransfer = try #require(declarations.first {
            $0["UTTypeIdentifier"] as? String == "org.steno.meeting-transfer"
        })
        let conformances = try #require(meetingTransfer["UTTypeConformsTo"] as? [String])

        #expect(Set(conformances) == ["public.archive", "public.content", "public.data"])
    }

    @Test("only loaded non-recording and non-interrupted meetings offer sharing")
    func meetingStatusControlsShareAction() {
        #expect(!MeetingPresentation.canShareMeeting(status: nil))
        #expect(!MeetingPresentation.canShareMeeting(status: .recording))
        #expect(!MeetingPresentation.canShareMeeting(status: .interrupted))
        #expect(MeetingPresentation.canShareMeeting(status: .draft))
        #expect(MeetingPresentation.canShareMeeting(status: .processing))
        #expect(MeetingPresentation.canShareMeeting(status: .ready))
    }

    @Test("preview creates no package and the deliberate action uses the real export service")
    @MainActor
    func packageIsCreatedOnlyByShareAction() async throws {
        let fixture = try await ExportFixture(notes: "Plan\n[00:00:12] Decision")
        defer { fixture.cleanUp() }
        let model = fixture.makeAppModel()
        await model.bootstrap()

        let preview = try await model.meetingTransferPreview(fixture.meeting.id)

        #expect(preview.includesNotes)
        #expect(try fixture.exportDirectoryContents().isEmpty)

        let result = try await model.prepareMeetingTransferExport(
            meetingID: fixture.meeting.id,
            selectedAudioAssetIDs: []
        )

        #expect(FileManager.default.fileExists(atPath: result.packageURL.path))
        #expect(result.packageURL.pathExtension == "stenomeeting")
        #expect(try fixture.exportDirectoryContents() == [result.cleanupRoot])

        try model.cleanupMeetingTransferExport(result)

        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("export error and cancellation leave no temporary residue")
    @MainActor
    func failuresCleanTheirWorkspace() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let model = fixture.makeAppModel()
        await model.bootstrap()

        await #expect(throws: MeetingTransferExportError.emptyPayload) {
            try await model.prepareMeetingTransferExport(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: []
            )
        }
        #expect(try fixture.exportDirectoryContents().isEmpty)

        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory,
            identifier: UUID()
        )
        await #expect(throws: CancellationError.self) {
            try await workspace.perform { root -> MeetingTransferExportResult in
                try Data("partial cleartext".utf8).write(
                    to: root.appending(path: "partial.stenomeeting")
                )
                throw CancellationError()
            }
        }
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("an existing temporary name is never adopted or deleted")
    func existingWorkspaceIsNotOwned() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let identifier = UUID()
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory,
            identifier: identifier
        )
        try FileManager.default.createDirectory(
            at: workspace.rootURL,
            withIntermediateDirectories: false
        )
        let sentinel = workspace.rootURL.appending(path: "not-owned.txt")
        try Data("not owned by this export".utf8).write(to: sentinel)

        await #expect(throws: MeetingTransferExportCleanupError.invalidTemporaryExport) {
            try await workspace.perform { _ -> MeetingTransferExportResult in
                throw CancellationError()
            }
        }

        #expect(try Data(contentsOf: sentinel) == Data("not owned by this export".utf8))
    }

    @Test("share completion cleans on success cancellation and sheet teardown exactly once")
    @MainActor
    func shareLifecycleAlwaysCleans() async throws {
        for completion in [true, false, nil] {
            let fixture = try await ExportFixture(notes: "Text")
            defer { fixture.cleanUp() }
            let model = fixture.makeAppModel()
            await model.bootstrap()
            let result = try await model.prepareMeetingTransferExport(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: []
            )
            var cleanupCalls = 0
            let lifecycle = MeetingTransferShareLifecycle {
                cleanupCalls += 1
                try? model.cleanupMeetingTransferExport(result)
            }

            if let completion {
                lifecycle.activityDidFinish(completed: completion)
            } else {
                lifecycle.presentationEnded()
            }
            lifecycle.presentationEnded()

            #expect(cleanupCalls == 1)
            #expect(try fixture.exportDirectoryContents().isEmpty)
        }
    }

    @Test("cleanup refuses external files and the activity controller receives only the package URL")
    @MainActor
    func cleanupStaysInsideOwnedRoot() async throws {
        let fixture = try await ExportFixture(notes: "Text")
        defer { fixture.cleanUp() }
        let model = fixture.makeAppModel()
        await model.bootstrap()
        let externalRoot = fixture.root.appending(path: "received", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: false)
        let externalPackage = externalRoot.appending(path: "Received.stenomeeting")
        try Data("received package".utf8).write(to: externalPackage)
        let externalResult = MeetingTransferExportResult(
            packageURL: externalPackage,
            cleanupRoot: externalRoot,
            contentDigest: "external",
            capabilities: [.notes],
            totalByteCount: 16
        )

        #expect(throws: MeetingTransferExportCleanupError.notOwned) {
            try model.cleanupMeetingTransferExport(externalResult)
        }
        #expect(FileManager.default.fileExists(atPath: externalPackage.path))

        let activityItems = MeetingTransferShareSheet.activityItems(packageURL: externalPackage)
        #expect(activityItems.count == 1)
        #expect(activityItems.first as? URL == externalPackage)
    }
}

private func makePreview(
    includesNotes: Bool = false,
    includesTranscript: Bool = false,
    visibleSpeakerLabels: [String] = [],
    audioTracks: [MeetingTransferExportPreview.AudioTrack] = [],
    textOnlyIsValid: Bool = true
) -> MeetingTransferExportPreview {
    MeetingTransferExportPreview(
        meetingID: MeetingID(),
        title: "Planning",
        createdAt: Date(timeIntervalSince1970: 1_000),
        includesNotes: includesNotes,
        includesTranscript: includesTranscript,
        visibleSpeakerLabels: visibleSpeakerLabels,
        audioTracks: audioTracks,
        textOnlyIsValid: textOnlyIsValid
    )
}

private struct ExportFixture {
    let root: URL
    let exportDirectory: URL
    let library: Library
    let meeting: Meeting

    init(notes: String?) async throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "Steno-MeetingTransferExportPresentationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        exportDirectory = root.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        library = try Library.open(at: root.appending(path: "library"))
        meeting = try await library.createMeeting(title: "Planning", status: .ready)
        if let notes {
            try await MeetingNotesStore(layout: library.layout).setNotes(meeting.id, to: notes)
        }
    }

    @MainActor
    func makeAppModel() -> AppModel {
        let runtimeLibrary = library
        let temporaryDirectory = exportDirectory
        return AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, locale, _ in
                let jobStore = try JobStore(layout: runtimeLibrary.layout)
                let coordinator = PipelineCoordinator(
                    library: runtimeLibrary,
                    jobStore: jobStore,
                    providers: [:],
                    locale: locale
                )
                return PipelineRuntime(
                    library: runtimeLibrary,
                    jobStore: jobStore,
                    coordinator: coordinator
                )
            },
            meetingTransferTemporaryDirectory: { temporaryDirectory }
        )
    }

    func exportDirectoryContents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: exportDirectory,
            includingPropertiesForKeys: nil
        ).sorted { $0.path < $1.path }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
