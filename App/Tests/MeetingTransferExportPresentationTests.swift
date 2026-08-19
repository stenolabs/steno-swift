import AppKit
import Darwin
import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Meeting transfer export presentation", .serialized)
struct MeetingTransferExportPresentationTests {
    @Test("the built app declares the meeting transfer as a shareable document")
    func builtDocumentTypeIsShareableContent() throws {
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

    @Test("audio is off for every new export sheet")
    func audioDefaultsOff() {
        #expect(MeetingTransferExportPresentation.initialAudioSelection.isEmpty)
    }

    @Test("text payload names notes markers transcript and visible speakers truthfully")
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

    @Test("audio summary rows and warning use only selected offered tracks")
    func audioSelectionControlsPresentation() throws {
        let microphoneID = MediaAssetID()
        let systemAudioID = MediaAssetID()
        let preview = makePreview(audioTracks: [
            .init(assetID: microphoneID, label: "Microphone", byteCount: 1_048_576),
            .init(assetID: systemAudioID, label: "System audio", byteCount: 2_097_152),
        ])

        #expect(MeetingTransferExportPresentation.audioRows(for: preview) == [
            "Microphone - 1 MB",
            "System audio - 2 MB",
        ])
        #expect(MeetingTransferExportPresentation.audioSummary(
            for: preview,
            selectedAudioAssetIDs: [microphoneID]
        ) == "1 track selected, 1 MB total")
        let microphoneWarning = try #require(MeetingTransferExportPresentation.audioWarning(
            for: preview,
            selectedAudioAssetIDs: [microphoneID]
        ))
        #expect(microphoneWarning.contains("Adding 1 MB"))
        #expect(!microphoneWarning.contains("2 MB"))
        #expect(!microphoneWarning.contains("3 MB"))
        #expect(microphoneWarning.contains("unencrypted raw recording"))
        #expect(microphoneWarning.contains("other voices in the room"))
        #expect(microphoneWarning.contains("cleartext file"))

        #expect(MeetingTransferExportPresentation.audioSummary(
            for: preview,
            selectedAudioAssetIDs: [microphoneID, systemAudioID]
        ) == "2 tracks selected, 3 MB total")
    }

    @Test("empty or unknown audio selection stays off and shows no recording warning")
    func emptyAudioSelectionHasNoWarning() {
        let offeredID = MediaAssetID()
        let preview = makePreview(audioTracks: [
            .init(assetID: offeredID, label: "Microphone", byteCount: 1_048_576),
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

    @Test("share stays disabled until text or selected offered audio exists")
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
            selectedAudioAssetIDs: [MediaAssetID()]
        ))
        #expect(MeetingTransferExportPresentation.canShare(
            preview: audioOnly,
            selectedAudioAssetIDs: [audioID]
        ))
    }

    @Test("share wording keeps AirDrop selection explicit")
    func airDropInstructionIsExplicit() {
        #expect(MeetingTransferExportPresentation.shareActionLabel == "Share meeting")
        #expect(MeetingTransferExportPresentation.airDropInstruction.contains(
            "may open AirDrop directly or show the Share menu"
        ))
        #expect(MeetingTransferExportPresentation.airDropInstruction.contains(
            "choose AirDrop"
        ))
        #expect(MeetingTransferExportPresentation.shareAccessibilityValue(isPreparing: true)
            == "Preparing package")
        let accessibilityHint = MeetingTransferExportPresentation.shareAccessibilityHint(
            isPreparing: false
        )
        #expect(accessibilityHint.contains("system sharing"))
        #expect(!accessibilityHint.contains("opens AirDrop"))
        #expect(MeetingTransferExportPresentation.sharingStatusText.contains(
            "system sharing"
        ))
        #expect(!MeetingTransferExportPresentation.sharingStatusText.contains(
            "AirDrop is open"
        ))
        #expect(MeetingTransferSharingError.serviceUnavailable.localizedDescription.contains(
            "Activate Share meeting again"
        ))
        #expect(!MeetingTransferSharingError.serviceUnavailable.localizedDescription.contains(
            "Click"
        ))
    }

    @Test("cleanup retry remains an inline action after an alert is dismissed")
    func cleanupRetryIsPersistentPresentationState() {
        #expect(MeetingTransferExportPresentation.cleanupActionLabel(
            for: .cleanupRequired("retry")
        ) == "Retry cleanup")
        #expect(MeetingTransferExportPresentation.cleanupActionLabel(
            for: .failed("failed")
        ) == nil)
        #expect(MeetingTransferExportPresentation.cleanupActionLabel(
            for: nil
        ) == nil)
    }

    @Test("invalid persisted source locale is explained without guessing")
    func invalidSourceLocaleIsExplained() {
        #expect(MeetingTransferExportPresentation.errorMessage(
            MeetingTransferExportError.invalidSourceLocale
        ) == "The meeting contains inconsistent source-language information and cannot be shared.")
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

    @Test("preview creates no package and export rechecks current core eligibility")
    @MainActor
    func packageIsCreatedOnlyByExplicitExport() async throws {
        let fixture = try await ExportFixture(notes: "Plan\n[00:00:12] Decision")
        defer { fixture.cleanUp() }
        let service = MeetingTransferExportService(library: fixture.library)

        let preview = try await service.preview(meetingID: fixture.meeting.id)

        #expect(preview.includesNotes)
        #expect(try fixture.exportDirectoryContents().isEmpty)

        let successfulWorkspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory
        )
        let owned = try await successfulWorkspace.perform { root in
            try await service.export(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: [],
                temporaryRoot: root,
                sourceAppVersion: "test"
            )
        }
        #expect(FileManager.default.fileExists(atPath: owned.result.packageURL.path))
        #expect(owned.result.packageURL.pathExtension == "stenomeeting")
        try owned.cleanup()
        #expect(try fixture.exportDirectoryContents().isEmpty)

        try await fixture.notesStore.setNotes(fixture.meeting.id, to: nil)
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory
        )
        await #expect(throws: MeetingTransferExportError.emptyPayload) {
            try await workspace.perform { root in
                try await service.export(
                    meetingID: fixture.meeting.id,
                    selectedAudioAssetIDs: [],
                    temporaryRoot: root,
                    sourceAppVersion: "test"
                )
            }
        }
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("workspace is exclusive private backup-excluded and explicitly cleaned")
    @MainActor
    func workspaceOwnershipAndBackupBoundary() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let owned = try await fixture.makeOwnedExport()

        #expect(directoryMode(owned.result.cleanupRoot) == 0o700)
        #expect(try owned.result.cleanupRoot.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true)
        #expect(try owned.result.packageURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true)
        #expect(Set(try FileManager.default.contentsOfDirectory(
            atPath: owned.result.cleanupRoot.path
        )) == ["Planning.stenomeeting", ".steno-export-owner"])

        try owned.cleanup()

        #expect(!FileManager.default.fileExists(atPath: owned.result.cleanupRoot.path))
    }

    @Test("ownership marker is durable before package creation begins")
    @MainActor
    func ownershipPrecedesPayload() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let identifier = UUID()
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory,
            identifier: identifier,
            selection: MeetingTransferExportSelection(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: []
            )
        )
        var entriesBeforePayload: Set<String> = []
        var markerBeforePayload: [String: Any] = [:]

        let owned = try await workspace.perform { root in
            entriesBeforePayload = Set(try FileManager.default.contentsOfDirectory(
                atPath: root.path
            ))
            let markerData = try Data(
                contentsOf: root.appending(path: ".steno-export-owner")
            )
            markerBeforePayload = try #require(
                JSONSerialization.jsonObject(with: markerData) as? [String: Any]
            )
            return try fixture.writeTestPackage(root)
        }

        #expect(entriesBeforePayload == [".steno-export-owner"])
        #expect(markerBeforePayload["schema"] as? Int == 2)
        #expect(UUID(uuidString: markerBeforePayload["token"] as? String ?? "") != nil)
        #expect(markerBeforePayload["rootName"] as? String == workspace.rootURL.lastPathComponent)
        #expect(markerBeforePayload["rootIdentifier"] as? String == identifier.uuidString)
        #expect(markerBeforePayload["packagePolicy"] as? String
            == "singleDirectStenoMeeting")
        #expect(markerBeforePayload["packageName"] == nil)
        let rootIdentity = try #require(
            markerBeforePayload["rootIdentity"] as? [String: Any]
        )
        #expect(rootIdentity["owner"] as? Int == Int(geteuid()))
        #expect(rootIdentity["mode"] as? Int == 0o700)
        #expect(rootIdentity["device"] != nil)
        #expect(rootIdentity["inode"] != nil)
        try owned.cleanup()
    }

    @Test("failed export keeps its durable marker until blocked cleanup can retry")
    @MainActor
    func failedExportCleanupRetainsRecoveryProof() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory,
            selection: MeetingTransferExportSelection(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: []
            )
        )
        let unexpectedDirectory = workspace.rootURL.appending(
            path: "unexpected-directory",
            directoryHint: .isDirectory
        )

        await #expect(throws: MeetingTransferExportCleanupError.cleanupFailed) {
            try await workspace.perform { root in
                _ = try fixture.writeTestPackage(root)
                try FileManager.default.createDirectory(
                    at: unexpectedDirectory,
                    withIntermediateDirectories: false
                )
                throw MeetingTransferExportCleanupError.runtimeUnavailable
            }
        }

        let marker = workspace.rootURL.appending(path: ".steno-export-owner")
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )
        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )
        let recovery = try #require(sharing.pendingCleanupSession)
        #expect(model.notice?.isError == true)

        try FileManager.default.removeItem(at: unexpectedDirectory)
        try recovery.retryCleanup()
        #expect(!FileManager.default.fileExists(atPath: workspace.rootURL.path))
    }

    @Test("writer failure recovers its archive session before unpublished root cleanup")
    @MainActor
    func writerFailureRecoversArchiveSession() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory,
            selection: MeetingTransferExportSelection(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: []
            )
        )
        var cleartext: URL?

        await #expect(throws: MeetingTransferExportCleanupError.runtimeUnavailable) {
            try await workspace.perform { root in
                cleartext = try makeAbandonedValidationSession(in: root).entry
                throw MeetingTransferExportCleanupError.runtimeUnavailable
            }
        }

        #expect(!FileManager.default.fileExists(atPath: workspace.rootURL.path))
        #expect(cleartext.map { FileManager.default.fileExists(atPath: $0.path) } == false)
    }

    @Test("writer failure preserves an unexpected payload for startup cleanup retry")
    @MainActor
    func writerFailurePreservesUnexpectedPayloadAfterArchiveRecovery() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory,
            selection: MeetingTransferExportSelection(
                meetingID: fixture.meeting.id,
                selectedAudioAssetIDs: []
            )
        )
        let unexpected = workspace.rootURL.appending(path: "unexpected.bin")
        var cleartext: URL?

        await #expect(throws: MeetingTransferExportCleanupError.cleanupFailed) {
            try await workspace.perform { root in
                cleartext = try makeAbandonedValidationSession(in: root).entry
                try Data("preserve".utf8).write(to: unexpected)
                throw MeetingTransferExportCleanupError.runtimeUnavailable
            }
        }

        #expect(cleartext.map { FileManager.default.fileExists(atPath: $0.path) } == false)
        #expect(try Data(contentsOf: unexpected) == Data("preserve".utf8))

        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )
        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )
        let recovery = try #require(sharing.pendingCleanupSession)
        #expect(model.notice?.isError == true)

        try FileManager.default.removeItem(at: unexpected)
        try recovery.retryCleanup()
        #expect(!FileManager.default.fileExists(atPath: workspace.rootURL.path))
    }

    @Test("an existing temporary name is never adopted or deleted")
    @MainActor
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
        try Data("not owned".utf8).write(to: sentinel)

        await #expect(throws: MeetingTransferExportCleanupError.invalidTemporaryExport) {
            try await workspace.perform { _ in
                throw CancellationError()
            }
        }

        #expect(try Data(contentsOf: sentinel) == Data("not owned".utf8))
    }

    @Test("cleanup refuses an external result and a replaced root but can retry its own root")
    @MainActor
    func cleanupIsExactAndRetryable() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }

        let receivedRoot = fixture.root.appending(path: "received")
        try FileManager.default.createDirectory(
            at: receivedRoot,
            withIntermediateDirectories: false
        )
        let receivedPackage = receivedRoot.appending(path: "Received.stenomeeting")
        try Data("received".utf8).write(to: receivedPackage)
        let externalResult = MeetingTransferExportResult(
            packageURL: receivedPackage,
            cleanupRoot: receivedRoot,
            contentDigest: "received",
            capabilities: [.notes],
            totalByteCount: 8
        )
        let rejectingWorkspace = MeetingTransferExportWorkspace(
            parentDirectory: fixture.exportDirectory
        )

        await #expect(throws: MeetingTransferExportCleanupError.invalidTemporaryExport) {
            try await rejectingWorkspace.perform { _ in externalResult }
        }
        #expect(try Data(contentsOf: receivedPackage) == Data("received".utf8))

        let owned = try await fixture.makeOwnedExport()
        let originalRoot = owned.result.cleanupRoot
        let parkedRoot = fixture.root.appending(path: "parked-owned-root")
        try FileManager.default.moveItem(at: originalRoot, to: parkedRoot)
        try FileManager.default.createDirectory(
            at: originalRoot,
            withIntermediateDirectories: false
        )
        let external = originalRoot.appending(path: "received.stenomeeting")
        try Data("external".utf8).write(to: external)

        #expect(throws: MeetingTransferExportCleanupError.notOwned) {
            try owned.cleanup()
        }
        #expect(try Data(contentsOf: external) == Data("external".utf8))

        try FileManager.default.moveItem(
            at: originalRoot,
            to: fixture.root.appending(path: "replacement-root")
        )
        try FileManager.default.moveItem(at: parkedRoot, to: originalRoot)
        try owned.cleanup()

        #expect(!FileManager.default.fileExists(atPath: originalRoot.path))
    }

    @Test("share keeps the exact package until success then cleans once")
    @MainActor
    func successfulShareOwnsPackageThroughCallback() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let harness = SharePerformerHarness()
        let sharing = MeetingTransferSharing(performerFactory: harness.factory)
        let session = try await fixture.prepareExport(using: sharing)

        try session.start(anchor: nil)

        #expect(session.state == .sharing)
        #expect(FileManager.default.fileExists(atPath: session.result.packageURL.path))
        #expect(MeetingTransferSystemSharePerformer.activityItems(
            packageURL: session.result.packageURL
        ).count == 1)
        #expect(MeetingTransferSystemSharePerformer.activityItems(
            packageURL: session.result.packageURL
        ).first as? URL == session.result.packageURL)

        harness.performers[0].complete(.shared)
        harness.performers[0].complete(.failed("stale callback"))

        #expect(session.state == .completed)
        #expect(!FileManager.default.fileExists(atPath: session.result.cleanupRoot.path))
    }

    @Test("share failure is visible after its temporary package is cleaned")
    @MainActor
    func failedShareReportsErrorAfterCleanup() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let harness = SharePerformerHarness()
        let sharing = MeetingTransferSharing(performerFactory: harness.factory)
        let session = try await fixture.prepareExport(using: sharing)
        try session.start(anchor: nil)

        harness.performers[0].complete(.failed("AirDrop failed"))

        #expect(session.state == .failed("AirDrop failed"))
        #expect(!FileManager.default.fileExists(atPath: session.result.cleanupRoot.path))
    }

    @Test("window close cannot delete a package while the system service may still use it")
    @MainActor
    func windowCloseRetainsUnfinishedShare() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let harness = SharePerformerHarness(canCancel: false)
        let sharing = MeetingTransferSharing(performerFactory: harness.factory)
        let session = try await fixture.prepareExport(using: sharing)
        try session.start(anchor: nil)

        session.presentationDidClose()

        #expect(session.state == .sharing)
        #expect(FileManager.default.fileExists(atPath: session.result.packageURL.path))

        harness.performers[0].complete(.cancelled)

        #expect(session.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: session.result.cleanupRoot.path))
    }

    @Test("a cancellable picker dismissal cleans its package")
    @MainActor
    func pickerCancellationCleans() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let harness = SharePerformerHarness(canCancel: true)
        let sharing = MeetingTransferSharing(performerFactory: harness.factory)
        let session = try await fixture.prepareExport(using: sharing)
        try session.start(anchor: nil)

        session.presentationDidClose()

        #expect(session.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: session.result.cleanupRoot.path))
    }

    @Test("registry survives the presenting owner and finishes without a view")
    @MainActor
    func appModelReplacementDoesNotReleaseActiveShare() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let harness = SharePerformerHarness()
        var sharing: MeetingTransferSharing? = MeetingTransferSharing(
            performerFactory: harness.factory
        )
        var model: AppModel? = AppModel(meetingTransferSharing: sharing!)
        var session: MeetingTransferSharingSession? = try await fixture.prepareExport(
            using: model!.meetingTransferSharing
        )
        try session?.start(anchor: nil)
        weak let weakSession = session
        weak let weakModel = model
        weak let weakSharing = sharing

        model = nil
        sharing = nil
        session = nil

        #expect(weakModel == nil)
        #expect(weakSharing == nil)
        #expect(weakSession != nil)
        #expect(try fixture.exportDirectoryContents().count == 1)

        harness.performers[0].complete(.shared)

        #expect(weakSession == nil)
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("a callbackless share blocks every later export before package creation")
    @MainActor
    func callbacklessShareBoundsProcessRegistry() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let harness = SharePerformerHarness()
        let sharing = MeetingTransferSharing(performerFactory: harness.factory)
        let selection = MeetingTransferExportSelection(
            meetingID: fixture.meeting.id,
            selectedAudioAssetIDs: []
        )
        let first = try await sharing.prepareExport(
            parentDirectory: fixture.exportDirectory,
            selection: selection,
            operation: fixture.writeTestPackage
        )
        try first.start(anchor: nil)
        let secondWindowSharing = MeetingTransferSharing()
        var didCreateSecondPackage = false

        await #expect(throws: MeetingTransferSharingError.sharingStillActive) {
            try await secondWindowSharing.prepareExport(
                parentDirectory: fixture.exportDirectory,
                selection: selection
            ) { root in
                didCreateSecondPackage = true
                return try fixture.writeTestPackage(root)
            }
        }

        #expect(!didCreateSecondPackage)
        #expect(sharing.currentSession === first)
        #expect(secondWindowSharing.currentSession === first)
        #expect(try fixture.exportDirectoryContents().count == 1)

        harness.performers[0].complete(.cancelled)
        harness.performers[0].complete(.failed("late"))
        #expect(first.state == .cancelled)
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("selection changes invalidate a prepared package and retry regenerates it")
    @MainActor
    func selectionFingerprintPreventsStaleAudioShare() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let sharing = MeetingTransferSharing()
        let firstSelection = MeetingTransferExportSelection(
            meetingID: fixture.meeting.id,
            selectedAudioAssetIDs: [MediaAssetID()]
        )
        let secondSelection = MeetingTransferExportSelection(
            meetingID: fixture.meeting.id,
            selectedAudioAssetIDs: [MediaAssetID()]
        )
        let first = try await sharing.prepareExport(
            parentDirectory: fixture.exportDirectory,
            selection: firstSelection,
            operation: fixture.writeTestPackage
        )
        let firstRoot = first.result.cleanupRoot

        #expect(throws: MeetingTransferSharingError.selectionChanged) {
            try first.start(anchor: nil, selection: secondSelection)
        }
        #expect(first.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: firstRoot.path))
        #expect(sharing.currentSession == nil)

        let second = try await sharing.prepareExport(
            parentDirectory: fixture.exportDirectory,
            selection: secondSelection,
            operation: fixture.writeTestPackage
        )
        #expect(second.selection == secondSelection)
        #expect(second.result.cleanupRoot != firstRoot)
        try second.cleanupPrepared()
    }

    @Test("factory failure cleans the registered package and never leaves it reusable")
    @MainActor
    func factoryFailureTransitionsRegisteredSession() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let sharing = MeetingTransferSharing { _, _, _ in
            throw MeetingTransferSharingError.serviceUnavailable
        }
        let selection = MeetingTransferExportSelection(
            meetingID: fixture.meeting.id,
            selectedAudioAssetIDs: []
        )
        let session = try await sharing.prepareExport(
            parentDirectory: fixture.exportDirectory,
            selection: selection,
            operation: fixture.writeTestPackage
        )

        #expect(sharing.currentSession === session)
        #expect(throws: MeetingTransferSharingError.serviceUnavailable) {
            try session.start(anchor: nil, selection: selection)
        }

        #expect(session.state == .failed(
            MeetingTransferSharingError.serviceUnavailable.localizedDescription
        ))
        #expect(sharing.currentSession == nil)
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("factory failure with blocked cleanup keeps the exact retry handle")
    @MainActor
    func factoryFailureCleanupRemainsReachable() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let sharing = MeetingTransferSharing { _, _, _ in
            throw MeetingTransferSharingError.serviceUnavailable
        }
        let selection = MeetingTransferExportSelection(
            meetingID: fixture.meeting.id,
            selectedAudioAssetIDs: []
        )
        let session = try await sharing.prepareExport(
            parentDirectory: fixture.exportDirectory,
            selection: selection,
            operation: fixture.writeTestPackage
        )
        let unexpected = session.result.cleanupRoot.appending(path: "unexpected")
        try Data("preserve".utf8).write(to: unexpected)

        #expect(throws: MeetingTransferSharingError.serviceUnavailable) {
            try session.start(anchor: nil, selection: selection)
        }
        guard case .cleanupRequired = session.state else {
            Issue.record("Expected cleanupRequired after the start error")
            return
        }
        #expect(sharing.currentSession === session)
        #expect(sharing.pendingCleanupSession === session)

        var didCreateAnotherPackage = false
        await #expect(throws: MeetingTransferSharingError.sharingStillActive) {
            try await sharing.prepareExport(
                parentDirectory: fixture.exportDirectory,
                selection: selection
            ) { root in
                didCreateAnotherPackage = true
                return try fixture.writeTestPackage(root)
            }
        }
        #expect(!didCreateAnotherPackage)

        try FileManager.default.removeItem(at: unexpected)
        try session.retryCleanup()
        #expect(sharing.currentSession == nil)
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("performer start failure cleans the registered package before retry")
    @MainActor
    func performerStartFailureIsNeverReusable() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let sharing = MeetingTransferSharing { _, _, _ in
            FailingStartSharePerformer()
        }
        let session = try await fixture.prepareExport(using: sharing)

        #expect(throws: MeetingTransferSharingError.serviceUnavailable) {
            try session.start(anchor: nil)
        }

        #expect(session.state == .failed(
            MeetingTransferSharingError.serviceUnavailable.localizedDescription
        ))
        #expect(sharing.currentSession == nil)
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("an abandoned owned export is swept on startup before a new export")
    @MainActor
    func startupSweepRemovesProvenOrphan() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let selection = MeetingTransferExportSelection(
            meetingID: fixture.meeting.id,
            selectedAudioAssetIDs: []
        )
        let firstRegistry = MeetingTransferSharingRegistry()
        var firstSharing: MeetingTransferSharing? = MeetingTransferSharing(
            registry: firstRegistry
        )
        var abandoned: MeetingTransferSharingSession? = try await firstSharing?.prepareExport(
            parentDirectory: fixture.exportDirectory,
            selection: selection,
            operation: fixture.writeTestPackage
        )
        let abandonedRoot = try #require(abandoned?.result.cleanupRoot)
        #expect(FileManager.default.fileExists(atPath: abandonedRoot.path))

        abandoned = nil
        firstRegistry.simulateProcessExitForTesting()
        firstSharing = nil

        let restartedSharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )
        let replacement = try await restartedSharing.prepareExport(
            parentDirectory: fixture.exportDirectory,
            selection: selection,
            operation: fixture.writeTestPackage
        )

        #expect(!FileManager.default.fileExists(atPath: abandonedRoot.path))
        let remainingRoots = try fixture.exportDirectoryContents()
        #expect(remainingRoots.count == 1)
        #expect(remainingRoots.first?.standardizedFileURL
            == replacement.result.cleanupRoot.standardizedFileURL)
        try replacement.cleanupPrepared()
    }

    @Test("AppModel startup sweeps an owned package abandoned before registration")
    @MainActor
    func appStartupSweepsPreRegistryCrashFixture() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var abandoned: MeetingTransferOwnedExport? = try await fixture.makeOwnedExport()
        let abandonedRoot = try #require(abandoned?.result.cleanupRoot)
        #expect(FileManager.default.fileExists(atPath: abandonedRoot.path))

        abandoned = nil
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )
        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        #expect(!FileManager.default.fileExists(atPath: abandonedRoot.path))
        #expect(model.notice == nil)
        #expect(sharing.currentSession == nil)
    }

    @Test("AppModel startup removes one regular writer quarantine after a hard crash")
    @MainActor
    func appStartupRecoversWriterQuarantineCrashFixture() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var abandoned: MeetingTransferOwnedExport? = try await fixture.makeOwnedExport()
        let root = try #require(abandoned?.result.cleanupRoot)
        let package = try #require(abandoned?.result.packageURL)
        let packageBytes = try Data(contentsOf: package)
        let quarantine = root.appending(
            path: ".stenomeeting-quarantine-\(UUID().uuidString)"
        )
        try FileManager.default.moveItem(at: package, to: quarantine)
        #expect(try Data(contentsOf: quarantine) == packageBytes)
        abandoned = nil
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )

        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        #expect(model.notice == nil)
        #expect(sharing.currentSession == nil)
        #expect(!FileManager.default.fileExists(atPath: quarantine.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let replacement = try await fixture.prepareExport(using: sharing)
        try replacement.cleanupPrepared()
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("AppModel startup preserves a writer quarantine directory")
    @MainActor
    func appStartupRefusesWriterQuarantineDirectory() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var abandoned: MeetingTransferOwnedExport? = try await fixture.makeOwnedExport()
        let root = try #require(abandoned?.result.cleanupRoot)
        let package = try #require(abandoned?.result.packageURL)
        try FileManager.default.removeItem(at: package)
        let quarantine = root.appending(
            path: ".stenomeeting-quarantine-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: quarantine,
            withIntermediateDirectories: false
        )
        abandoned = nil
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )

        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        let recovery = try #require(sharing.pendingCleanupSession)
        #expect(model.notice?.isError == true)
        var status = stat()
        #expect(lstat(quarantine.path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFDIR)

        try FileManager.default.removeItem(at: quarantine)
        try recovery.retryCleanup()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("AppModel startup preserves a writer quarantine symlink and its target")
    @MainActor
    func appStartupRefusesWriterQuarantineSymlink() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var abandoned: MeetingTransferOwnedExport? = try await fixture.makeOwnedExport()
        let root = try #require(abandoned?.result.cleanupRoot)
        let package = try #require(abandoned?.result.packageURL)
        try FileManager.default.removeItem(at: package)
        let external = fixture.root.appending(path: "foreign-writer-quarantine")
        let externalBytes = Data("preserve-external".utf8)
        try externalBytes.write(to: external)
        let quarantine = root.appending(
            path: ".stenomeeting-quarantine-\(UUID().uuidString)"
        )
        guard Darwin.symlink(external.path, quarantine.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        abandoned = nil
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )

        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        let recovery = try #require(sharing.pendingCleanupSession)
        #expect(model.notice?.isError == true)
        #expect(try Data(contentsOf: external) == externalBytes)
        var status = stat()
        #expect(lstat(quarantine.path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFLNK)

        try FileManager.default.removeItem(at: quarantine)
        try recovery.retryCleanup()
        #expect(try Data(contentsOf: external) == externalBytes)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("AppModel startup preserves ambiguous regular writer quarantines")
    @MainActor
    func appStartupRefusesMultipleWriterQuarantines() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var abandoned: MeetingTransferOwnedExport? = try await fixture.makeOwnedExport()
        let root = try #require(abandoned?.result.cleanupRoot)
        let package = try #require(abandoned?.result.packageURL)
        let packageBytes = try Data(contentsOf: package)
        let first = root.appending(
            path: ".stenomeeting-quarantine-\(UUID().uuidString)"
        )
        let second = root.appending(
            path: ".stenomeeting-quarantine-\(UUID().uuidString)"
        )
        try FileManager.default.moveItem(at: package, to: first)
        try Data("second-candidate".utf8).write(to: second)
        abandoned = nil
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )

        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        let recovery = try #require(sharing.pendingCleanupSession)
        #expect(model.notice?.isError == true)
        #expect(try Data(contentsOf: first) == packageBytes)
        #expect(try Data(contentsOf: second) == Data("second-candidate".utf8))

        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        try recovery.retryCleanup()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("AppModel startup preserves a malformed writer quarantine name")
    @MainActor
    func appStartupRefusesMalformedWriterQuarantine() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var abandoned: MeetingTransferOwnedExport? = try await fixture.makeOwnedExport()
        let root = try #require(abandoned?.result.cleanupRoot)
        let package = try #require(abandoned?.result.packageURL)
        let packageBytes = try Data(contentsOf: package)
        let quarantine = root.appending(
            path: ".stenomeeting-quarantine-not-a-uuid"
        )
        try FileManager.default.moveItem(at: package, to: quarantine)
        abandoned = nil
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )

        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        let recovery = try #require(sharing.pendingCleanupSession)
        #expect(model.notice?.isError == true)
        #expect(try Data(contentsOf: quarantine) == packageBytes)

        try FileManager.default.removeItem(at: quarantine)
        try recovery.retryCleanup()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("AppModel startup recovers archive cleartext before a pre-registry root")
    @MainActor
    func appStartupRecoversArchiveSessionBeforeExportRoot() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var abandoned: MeetingTransferOwnedExport? = try await fixture.makeOwnedExport()
        let root = try #require(abandoned?.result.cleanupRoot)
        let package = try #require(abandoned?.result.packageURL)
        abandoned = nil
        try FileManager.default.removeItem(at: package)
        let validation = try makeAbandonedValidationSession(in: root)
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )

        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        #expect(!FileManager.default.fileExists(atPath: validation.entry.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(sharing.currentSession == nil)
        #expect(model.notice == nil)
    }

    @Test("startup archive recovery failure stays reachable for explicit retry")
    @MainActor
    func appStartupArchiveRecoveryFailureIsRetryable() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var abandoned: MeetingTransferOwnedExport? = try await fixture.makeOwnedExport()
        let root = try #require(abandoned?.result.cleanupRoot)
        let package = try #require(abandoned?.result.packageURL)
        abandoned = nil
        try FileManager.default.removeItem(at: package)
        let validation = try makeAbandonedValidationSession(in: root)
        let recoveryHarness = ValidationSessionRecoveryHarness()
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry(),
            validationSessionRecovery: recoveryHarness.recover
        )

        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        let recovery = try #require(sharing.pendingCleanupSession)
        #expect(model.notice?.isError == true)
        #expect(FileManager.default.fileExists(atPath: validation.entry.path))
        #expect(recoveryHarness.callCount == 1)

        recoveryHarness.shouldFail = false
        try recovery.retryCleanup()

        #expect(recoveryHarness.callCount == 2)
        #expect(sharing.currentSession == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("startup sweep skips a root whose live owner still holds its lease")
    @MainActor
    func startupSweepPreservesLiveExport() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let selection = MeetingTransferExportSelection(
            meetingID: fixture.meeting.id,
            selectedAudioAssetIDs: []
        )
        let liveSharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )
        let live = try await liveSharing.prepareExport(
            parentDirectory: fixture.exportDirectory,
            selection: selection,
            operation: fixture.writeTestPackage
        )
        let restartedSharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )

        try restartedSharing.recoverAbandonedExports(
            parentDirectory: fixture.exportDirectory
        )

        #expect(FileManager.default.fileExists(atPath: live.result.packageURL.path))
        #expect(restartedSharing.currentSession == nil)
        try live.cleanupPrepared()
    }

    @Test("startup cleanup failure remains the sole reachable retry session")
    @MainActor
    func startupCleanupFailureIsReachable() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let firstRegistry = MeetingTransferSharingRegistry()
        var firstSharing: MeetingTransferSharing? = MeetingTransferSharing(
            registry: firstRegistry
        )
        var abandoned: MeetingTransferSharingSession? = try await fixture.prepareExport(
            using: firstSharing!
        )
        let unexpected = try #require(abandoned?.result.cleanupRoot)
            .appending(path: "unexpected")
        try Data("preserve".utf8).write(to: unexpected)
        abandoned = nil
        firstRegistry.simulateProcessExitForTesting()
        firstSharing = nil

        let restartedSharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )
        #expect(throws: MeetingTransferSharingError.cleanupRequired) {
            try restartedSharing.recoverAbandonedExports(
                parentDirectory: fixture.exportDirectory
            )
        }
        let recovery = try #require(restartedSharing.pendingCleanupSession)
        #expect(restartedSharing.currentSession === recovery)
        guard case .cleanupRequired = recovery.state else {
            Issue.record("Expected the recovered cleanup handle")
            return
        }

        try FileManager.default.removeItem(at: unexpected)
        try recovery.retryCleanup()
        #expect(restartedSharing.currentSession == nil)
        #expect(try fixture.exportDirectoryContents().isEmpty)
    }

    @Test("startup sweep preserves an unproved lookalike root")
    @MainActor
    func startupSweepPreservesLookalike() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let lookalike = fixture.exportDirectory.appending(
            path: "Steno-MeetingTransferExport-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: lookalike,
            withIntermediateDirectories: false
        )
        let sentinel = lookalike.appending(path: "external")
        try Data("preserve".utf8).write(to: sentinel)
        let sharing = MeetingTransferSharing()

        let session = try await fixture.prepareExport(using: sharing)

        #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
        try session.cleanupPrepared()
        #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
    }

    @Test("AppModel startup preserves and reports an unmarked package lookalike")
    @MainActor
    func appStartupReportsUnmarkedPackageLookalike() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let lookalike = fixture.exportDirectory.appending(
            path: "Steno-MeetingTransferExport-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: lookalike,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let package = lookalike.appending(path: "Preserve.stenomeeting")
        let bytes = Data("not-proven-owned".utf8)
        try bytes.write(to: package)
        let validation = try makeAbandonedValidationSession(in: lookalike)
        let recoveryHarness = ValidationSessionRecoveryHarness()
        recoveryHarness.shouldFail = false
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry(),
            validationSessionRecovery: recoveryHarness.recover
        )

        let model = AppModel(
            meetingTransferSharing: sharing,
            meetingTransferTemporaryDirectory: { fixture.exportDirectory }
        )

        #expect(try Data(contentsOf: package) == bytes)
        #expect(try Data(contentsOf: validation.entry) == Data("cleartext".utf8))
        #expect(recoveryHarness.callCount == 0)
        let notice = try #require(model.notice)
        #expect(notice.isError)
        #expect(notice.text.contains("preserved for manual cleanup"))
    }

    @Test("registered start failure recovers archive cleartext before export cleanup")
    @MainActor
    func startFailureRecoversArchiveSession() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let sharing = MeetingTransferSharing(
            performerFactory: { _, _, _ in
                throw MeetingTransferSharingError.serviceUnavailable
            },
            registry: MeetingTransferSharingRegistry()
        )
        let session = try await fixture.prepareExport(using: sharing)
        let root = session.result.cleanupRoot
        let validation = try makeAbandonedValidationSession(in: root)

        #expect(throws: MeetingTransferSharingError.serviceUnavailable) {
            try session.start(anchor: nil)
        }

        #expect(!FileManager.default.fileExists(atPath: validation.entry.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(session.state == .failed(
            MeetingTransferSharingError.serviceUnavailable.localizedDescription
        ))
        #expect(sharing.currentSession == nil)
    }

    @Test("cleanup refuses unexpected entries and succeeds after explicit retry")
    @MainActor
    func cleanupRequiresExactRootContents() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let owned = try await fixture.makeOwnedExport()
        let unexpected = owned.result.cleanupRoot.appending(path: "unexpected")
        try Data("preserve".utf8).write(to: unexpected)

        #expect(throws: MeetingTransferExportCleanupError.unexpectedEntry) {
            try owned.cleanup()
        }
        #expect(try Data(contentsOf: unexpected) == Data("preserve".utf8))

        try FileManager.default.removeItem(at: unexpected)
        try owned.cleanup()
        #expect(!FileManager.default.fileExists(atPath: owned.result.cleanupRoot.path))
    }

    @Test("parent sync failure retries only durability and then permits a new export")
    @MainActor
    func parentSyncFailureHasRetryableCleanupPhase() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        var syncAttempts = 0
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry(),
            cleanupParentSync: { descriptor in
                syncAttempts += 1
                if syncAttempts == 1 {
                    throw MeetingTransferExportCleanupError.cleanupFailed
                }
                guard fsync(descriptor) == 0 else {
                    throw MeetingTransferExportCleanupError.cleanupFailed
                }
            }
        )
        let session = try await fixture.prepareExport(using: sharing)
        let root = session.result.cleanupRoot

        #expect(throws: MeetingTransferExportCleanupError.cleanupFailed) {
            try session.cleanupPrepared()
        }
        guard case .cleanupRequired = session.state else {
            Issue.record("Expected cleanupRequired while parent durability is pending")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(syncAttempts == 1)
        #expect(sharing.pendingCleanupSession === session)

        try session.retryCleanup()

        #expect(syncAttempts == 2)
        #expect(session.state == .cancelled)
        #expect(sharing.currentSession == nil)

        let next = try await fixture.prepareExport(using: sharing)
        try next.cleanupPrepared()
        #expect(syncAttempts == 3)
    }

    @Test("archive recovery failure stays registered and succeeds on explicit retry")
    @MainActor
    func archiveRecoveryFailureIsRetryable() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let recoveryHarness = ValidationSessionRecoveryHarness()
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry(),
            validationSessionRecovery: recoveryHarness.recover
        )
        let session = try await fixture.prepareExport(using: sharing)
        let root = session.result.cleanupRoot
        let validation = try makeAbandonedValidationSession(in: root)

        #expect(throws: MeetingTransferExportCleanupError.cleanupFailed) {
            try session.cleanupPrepared()
        }
        guard case .cleanupRequired = session.state else {
            Issue.record("Expected cleanupRequired after archive recovery failed")
            return
        }
        #expect(FileManager.default.fileExists(atPath: validation.entry.path))
        #expect(sharing.pendingCleanupSession === session)

        var createdAnotherPackage = false
        await #expect(throws: MeetingTransferSharingError.sharingStillActive) {
            try await sharing.prepareExport(
                parentDirectory: fixture.exportDirectory,
                selection: session.selection
            ) { root in
                createdAnotherPackage = true
                return try fixture.writeTestPackage(root)
            }
        }
        #expect(!createdAnotherPackage)

        recoveryHarness.shouldFail = false
        try session.retryCleanup()

        #expect(session.state == .cancelled)
        #expect(sharing.currentSession == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let next = try await fixture.prepareExport(using: sharing)
        try next.cleanupPrepared()
    }

    @Test("archive recovery preserves a foreign symlink session and requires retry")
    @MainActor
    func archiveRecoveryRefusesSymlinkSession() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let sharing = MeetingTransferSharing(
            registry: MeetingTransferSharingRegistry()
        )
        let session = try await fixture.prepareExport(using: sharing)
        let external = fixture.root.appending(
            path: "foreign-validation-target",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false
        )
        let sentinel = external.appending(path: "preserve")
        let sentinelBytes = Data("foreign-cleartext".utf8)
        try sentinelBytes.write(to: sentinel)
        let sessionName = ".stenomeeting-validation-\(UUID().uuidString)"
        let symlink = session.result.cleanupRoot.appending(path: sessionName)
        guard Darwin.symlink(external.path, symlink.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        #expect(throws: MeetingTransferValidationError.cleanupIdentityMismatch(
            sessionName
        )) {
            try session.cleanupPrepared()
        }
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(sharing.pendingCleanupSession === session)

        try FileManager.default.removeItem(at: symlink)
        try session.retryCleanup()

        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(!FileManager.default.fileExists(atPath: session.result.cleanupRoot.path))
    }

    @Test("package swap at cleanup checkpoint preserves the replacement")
    @MainActor
    func packageSwapBetweenCheckAndRemovalFailsClosed() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let savedOwned = fixture.root.appending(path: "saved-owned-package")
        let replacementBytes = Data("replacement-must-survive".utf8)
        var replacementURL: URL?
        var didSwap = false
        let owned = try await fixture.makeOwnedExport { checkpoint in
            guard case .beforePackageRemoval(let quarantineURL) = checkpoint,
                  !didSwap else { return }
            didSwap = true
            try FileManager.default.moveItem(at: quarantineURL, to: savedOwned)
            try replacementBytes.write(to: quarantineURL)
            replacementURL = quarantineURL
        }

        #expect(throws: MeetingTransferExportCleanupError.notOwned) {
            try owned.cleanup()
        }
        let preserved = try #require(replacementURL)
        #expect(try Data(contentsOf: preserved) == replacementBytes)
        #expect(FileManager.default.fileExists(atPath: savedOwned.path))

        try FileManager.default.removeItem(at: preserved)
        try FileManager.default.moveItem(at: savedOwned, to: owned.result.packageURL)
        try owned.cleanup()
    }

    @Test("root swap at cleanup checkpoint preserves the replacement directory")
    @MainActor
    func rootSwapBetweenCheckAndRemovalFailsClosed() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let savedOwned = fixture.root.appending(path: "saved-owned-root")
        let replacementBytes = Data("replacement-root-must-survive".utf8)
        var replacementRoot: URL?
        var didSwap = false
        let owned = try await fixture.makeOwnedExport { checkpoint in
            guard case .beforeRootRemoval(let quarantineURL) = checkpoint,
                  !didSwap else { return }
            didSwap = true
            try FileManager.default.moveItem(at: quarantineURL, to: savedOwned)
            try FileManager.default.createDirectory(
                at: quarantineURL,
                withIntermediateDirectories: false
            )
            try replacementBytes.write(
                to: quarantineURL.appending(path: "preserve")
            )
            replacementRoot = quarantineURL
        }

        #expect(throws: MeetingTransferExportCleanupError.notOwned) {
            try owned.cleanup()
        }
        let preserved = try #require(replacementRoot)
        #expect(try Data(contentsOf: preserved.appending(path: "preserve"))
            == replacementBytes)

        try FileManager.default.removeItem(at: preserved)
        try FileManager.default.moveItem(at: savedOwned, to: owned.result.cleanupRoot)
        try owned.cleanup()
    }

    @Test("cleanup failure stays visible and retryable after sharing ends")
    @MainActor
    func sharingCleanupCanBeRetried() async throws {
        let fixture = try await ExportFixture(notes: nil)
        defer { fixture.cleanUp() }
        let harness = SharePerformerHarness()
        let sharing = MeetingTransferSharing(performerFactory: harness.factory)
        let session = try await fixture.prepareExport(using: sharing)
        let originalRoot = session.result.cleanupRoot
        let parkedRoot = fixture.root.appending(path: "parked-sharing-root")
        try FileManager.default.moveItem(at: originalRoot, to: parkedRoot)
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: false)
        try session.start(anchor: nil)

        harness.performers[0].complete(.shared)

        guard case .cleanupRequired = session.state else {
            Issue.record("Expected an explicit cleanup-required state")
            return
        }
        #expect(sharing.pendingCleanupSession === session)
        #expect(FileManager.default.fileExists(atPath: originalRoot.path))

        try FileManager.default.moveItem(
            at: originalRoot,
            to: fixture.root.appending(path: "replacement-sharing-root")
        )
        try FileManager.default.moveItem(at: parkedRoot, to: originalRoot)
        try session.retryCleanup()

        #expect(session.state == .completed)
        #expect(sharing.pendingCleanupSession == nil)
        #expect(!FileManager.default.fileExists(atPath: originalRoot.path))
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

private func makeAbandonedValidationSession(
    in root: URL
) throws -> (session: URL, entry: URL) {
    let session = root.appending(
        path: ".stenomeeting-validation-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: session,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    guard chmod(session.path, S_IRWXU) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let entry = session.appending(path: "entry-0001")
    try Data("cleartext".utf8).write(to: entry)
    guard chmod(entry.path, S_IRUSR | S_IWUSR) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return (session, entry)
}

@MainActor
private final class ValidationSessionRecoveryHarness {
    var shouldFail = true
    private(set) var callCount = 0

    func recover(_ root: URL) throws {
        callCount += 1
        if shouldFail {
            throw MeetingTransferExportCleanupError.cleanupFailed
        }
        try MeetingTransferArchiveReader().recoverAbandonedSessions(
            validationRoot: root
        )
    }
}

private struct ExportFixture {
    let root: URL
    let exportDirectory: URL
    let library: Library
    let notesStore: MeetingNotesStore
    let meeting: Meeting

    init(notes: String?) async throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "Steno-MacMeetingTransferExportTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        exportDirectory = root.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        library = try Library.open(at: root.appending(path: "library"))
        notesStore = MeetingNotesStore(layout: library.layout)
        meeting = try await library.createMeeting(title: "Planning", status: .ready)
        if let notes {
            try await notesStore.setNotes(meeting.id, to: notes)
        }
    }

    @MainActor
    func makeOwnedExport(
        namespaceCheckpoint: @escaping MeetingTransferExportNamespaceCheckpoint = { _ in }
    ) async throws -> MeetingTransferOwnedExport {
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: exportDirectory,
            namespaceCheckpoint: namespaceCheckpoint
        )
        return try await workspace.perform { root in
            try writeTestPackage(root)
        }
    }

    func writeTestPackage(_ root: URL) throws -> MeetingTransferExportResult {
        let package = root.appending(path: "Planning.stenomeeting")
        try Data("package bytes".utf8).write(to: package)
        return MeetingTransferExportResult(
            packageURL: package,
            cleanupRoot: root,
            contentDigest: "digest",
            capabilities: [.notes],
            totalByteCount: 13
        )
    }

    @MainActor
    func prepareExport(
        using sharing: MeetingTransferSharing
    ) async throws -> MeetingTransferSharingSession {
        try await sharing.prepareExport(
            parentDirectory: exportDirectory,
            selection: MeetingTransferExportSelection(
                meetingID: meeting.id,
                selectedAudioAssetIDs: []
            ),
            operation: writeTestPackage
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

@MainActor
private final class SharePerformerHarness {
    private let canCancel: Bool
    private(set) var performers: [ControlledSharePerformer] = []

    init(canCancel: Bool = false) {
        self.canCancel = canCancel
    }

    lazy var factory: MeetingTransferSharePerformerFactory = { [weak self] packageURL, _, completion in
        guard let self else { throw MeetingTransferSharingError.serviceUnavailable }
        let performer = ControlledSharePerformer(
            packageURL: packageURL,
            canCancel: canCancel,
            completion: completion
        )
        performers.append(performer)
        return performer
    }
}

@MainActor
private final class ControlledSharePerformer: MeetingTransferSharePerforming {
    let packageURL: URL
    private let canCancel: Bool
    private var completion: ((MeetingTransferShareOutcome) -> Void)?

    init(
        packageURL: URL,
        canCancel: Bool,
        completion: @escaping (MeetingTransferShareOutcome) -> Void
    ) {
        self.packageURL = packageURL
        self.canCancel = canCancel
        self.completion = completion
    }

    func start() throws {}

    func cancelIfPossible() -> Bool {
        guard canCancel else { return false }
        complete(.cancelled)
        return true
    }

    func complete(_ outcome: MeetingTransferShareOutcome) {
        completion?(outcome)
    }
}

@MainActor
private final class FailingStartSharePerformer: MeetingTransferSharePerforming {
    func start() throws {
        throw MeetingTransferSharingError.serviceUnavailable
    }

    func cancelIfPossible() -> Bool { false }
}

private func directoryMode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & mode_t(0o7777)
}
