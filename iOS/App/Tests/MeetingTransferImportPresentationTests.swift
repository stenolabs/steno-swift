import Foundation
import StenoDomain
import StenoExchange
import StenoPipeline
import Testing
@testable import Steno

@Suite("Meeting transfer import presentation")
struct MeetingTransferImportPresentationTests {
    private let meetingID = MeetingID(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test("preview shows content and cleartext boundaries")
    func previewContentAndWarnings() {
        let presentation = makePresentation(
            capabilities: [.notes, .transcript, .audio],
            visibleSpeakerLabels: ["Alex", "Guest 2"],
            audioTracks: [
                .init(label: "Microphone", byteCount: 1_500_000),
                .init(label: "System audio", byteCount: 2_500_000),
            ]
        )

        #expect(presentation.title == "Budget review")
        #expect(presentation.sourceMeetingID == meetingID)
        #expect(presentation.capabilityLabels.map(english) == ["Notes", "Transcript", "Audio"])
        #expect(presentation.audioTrackCount == 2)
        #expect(presentation.totalAudioBytes == 4_000_000)
        #expect(english(presentation.cleartextWarning).contains("unencrypted raw recording"))
        #expect(english(presentation.externalFileWarning).contains("Files"))
        #expect(english(presentation.externalFileWarning).contains("does not delete"))
        #expect(presentation.visibleSpeakerLabels == ["Alex", "Guest 2"])
        #expect(english(presentation.speakerLabelPrivacyHint).contains("visible"))
    }

    @Test("duplicate visible speaker labels retain separate presentation rows")
    func duplicateVisibleSpeakerLabelsRemainDistinct() {
        let presentation = makePresentation(visibleSpeakerLabels: ["Alex", "Alex"])

        #expect(presentation.speakerLabelRows.map(\.label) == ["Alex", "Alex"])
        #expect(presentation.speakerLabelRows.map(\.id) == [0, 1])
    }

    @Test("conflicts never offer a mutating action")
    func conflictBlocksImport() {
        #expect(
            MeetingTransferImportPresentation.actions(
                for: .conflict(meetingID),
                hasAudio: true
            ) == [.close]
        )
    }

    @Test("an already-present meeting opens without importing")
    func alreadyPresentOpensExistingMeeting() {
        #expect(
            MeetingTransferImportPresentation.actions(
                for: .alreadyPresent(meetingID),
                hasAudio: true
            ) == [.openExisting, .close]
        )
    }

    @Test("every new package requires the explicit import-only action")
    func newPackagesOnlyImportExplicitly() {
        #expect(
            MeetingTransferImportPresentation.actions(for: .new, hasAudio: false)
                == [.importOnly, .close]
        )
        #expect(
            MeetingTransferImportPresentation.actions(for: .new, hasAudio: true)
                == [.importOnly, .close]
        )
    }

    @Test("unknown import totals stay indeterminate and known totals clamp")
    func importProgressPresentation() {
        let unknown = MeetingTransferProgressPresentation.make(nil)
        #expect(unknown == .indeterminate)
        #expect(String(localized: unknown.accessibilityLabel) == "Import progress")
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .enumerating, processedBytes: 1, totalBytes: 0)
            ) == .indeterminate
        )
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .hashing, processedBytes: 1, totalBytes: -1)
            ) == .indeterminate
        )
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .writing, processedBytes: -1, totalBytes: 10)
            ) == .determinate(0)
        )
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .writing, processedBytes: 5, totalBytes: 10)
            ) == .determinate(0.5)
        )
        #expect(
            MeetingTransferProgressPresentation.make(
                .init(phase: .writing, processedBytes: 11, totalBytes: 10)
            ) == .determinate(1)
        )
    }

    @Test("imported meeting detail names origin content and source language")
    func importedDetailMetadata() {
        let detail = MeetingTransferDetailPresentation(
            receipt: MeetingTransferReceipt(
                sourceMeetingID: meetingID,
                sourceRevisionID: nil,
                sourcePackageContentDigest: String(repeating: "a", count: 64),
                importedAt: Date(timeIntervalSinceReferenceDate: 123_456),
                sourceAppVersion: "1.0",
                includedCapabilities: [.notes, .audio],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: MeetingTransferGenerationID()
            )
        )

        #expect(english(detail.originLabel) == "Imported via AirDrop")
        #expect(english(detail.contentLabel) == "Notes, Audio")
        #expect(english(detail.sourceLanguageLabel).contains("de-DE"))
        #expect(english(detail.externalFileWarning).contains("Files"))
        #expect(english(detail.externalFileWarning).contains("does not delete"))
    }

    @Test("successful imports use the existing compact and split meeting routes")
    func importedMeetingNavigation() {
        #expect(MeetingTransferNavigation.compactSelection(for: meetingID) == .meeting(meetingID))
        #expect(MeetingTransferNavigation.splitSelection(for: meetingID) == .meeting(meetingID))
    }

    private func makePresentation(
        capabilities: Set<MeetingTransferCapability> = [.notes],
        visibleSpeakerLabels: [String] = [],
        audioTracks: [MeetingTransferImportPresentation.AudioTrack] = []
    ) -> MeetingTransferImportPresentation {
        MeetingTransferImportPresentation(
            sessionID: sessionID,
            sourceMeetingID: meetingID,
            title: "Budget review",
            createdAt: Date(timeIntervalSinceReferenceDate: 123_456),
            capabilities: capabilities,
            visibleSpeakerLabels: visibleSpeakerLabels,
            audioTracks: audioTracks,
            localeIdentifier: "de-DE",
            localeOrigin: .explicit,
            disposition: .new
        )
    }
}

@MainActor
@Suite("Meeting transfer import lifecycle")
struct MeetingTransferImportLifecycleTests {
    @Test("a disconnected last scene cannot consume pending navigation before rehome")
    func staleSceneCannotConsumePendingNavigation() async throws {
        let sourceScene = MeetingTransferSceneID()
        let replacementScene = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(importResult: .imported(meetingID))
        let loader = MeetingListHarness(outcomes: [.success([meeting(meetingID)])])
        let model = makeModel(harness: harness, listLoader: loader.load)

        model.registerMeetingTransferScene(sourceScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/stale-navigation.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Navigation")
        try await waitForPreview(model)
        model.importMeetingPackage(for: sourceScene)
        try await waitForIdle(model)
        model.unregisterMeetingTransferScene(sourceScene)

        #expect(model.consumeSelectedMeetingIDIfAvailable(for: sourceScene) == nil)
        model.registerMeetingTransferScene(replacementScene)
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: replacementScene) == meetingID)
    }

    @Test("a disconnected last recovery scene cannot dismiss or mutate its visible result")
    func staleRecoverySceneCannotMutateAfterDisconnect() async throws {
        let sourceScene = MeetingTransferSceneID()
        let replacementScene = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(importResult: .pendingRecovery(meetingID))
        let model = makeModel(harness: harness)

        model.registerMeetingTransferScene(sourceScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/stale-recovery.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Recovery")
        try await waitForPreview(model)
        model.importMeetingPackage(for: sourceScene)
        try await waitForRecovery(model, meetingID: meetingID)
        model.unregisterMeetingTransferScene(sourceScene)

        #expect(!model.isPresentingMeetingTransfer(in: sourceScene))
        model.dismissMeetingTransferSheet(for: sourceScene)
        model.closeMeetingTransferImport(for: sourceScene)
        model.retryMeetingTransferCleanup(for: sourceScene)
        model.importMeetingPackage(for: sourceScene)
        model.openExistingMeetingFromTransferPreview(for: sourceScene)
        try await waitForRecovery(model, meetingID: meetingID)
        #expect(model.selectedMeetingID == nil)

        model.registerMeetingTransferScene(replacementScene)
        #expect(model.isPresentingMeetingTransfer(in: replacementScene))
        model.closeMeetingTransferImport(for: replacementScene)
        try await waitForIdle(model)
    }

    @Test("a disconnected cleanup scene cannot run its pinned cleanup until rehomed")
    func staleCleanupSceneCannotMutateAfterDisconnect() async throws {
        let sourceScene = MeetingTransferSceneID()
        let replacementScene = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let cleanupID = UUID()
        let harness = ImportLifecycleHarness(
            importError: MeetingTransferImportError.cleanupRequired(
                sessionID: cleanupID,
                committedResult: .imported(meetingID)
            )
        )
        let model = makeModel(harness: harness)

        model.registerMeetingTransferScene(sourceScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/stale-cleanup.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Cleanup")
        try await waitForPreview(model)
        model.importMeetingPackage(for: sourceScene)
        try await waitForCleanup(model, sessionID: cleanupID)
        model.unregisterMeetingTransferScene(sourceScene)

        #expect(!model.isPresentingMeetingTransfer(in: sourceScene))
        model.dismissMeetingTransferSheet(for: sourceScene)
        model.closeMeetingTransferImport(for: sourceScene)
        model.retryMeetingTransferCleanup(for: sourceScene)
        model.importMeetingPackage(for: sourceScene)
        model.openExistingMeetingFromTransferPreview(for: sourceScene)
        #expect(model.meetingTransferImportState?.cleanupSessionID == cleanupID)
        #expect(model.ownedMeetingTransferSession?.sessionID == cleanupID)
        #expect(await harness.discardedSessionIDs.isEmpty)

        model.registerMeetingTransferScene(replacementScene)
        #expect(model.isPresentingMeetingTransfer(in: replacementScene))
        model.retryMeetingTransferCleanup(for: replacementScene)
        try await waitForIdle(model)
        #expect(await harness.discardedSessionIDs == [cleanupID])
        #expect(model.ownedMeetingTransferSession == nil)
    }

    @Test("a disconnected completed scene cannot complete its result until rehomed")
    func staleCompletedSceneCannotMutateAfterDisconnect() async throws {
        let sourceScene = MeetingTransferSceneID()
        let replacementScene = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(holdsImport: true)
        let model = makeModel(harness: harness)

        model.registerMeetingTransferScene(sourceScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/stale-completed.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Completed")
        try await waitForPreview(model)
        model.importMeetingPackage(for: sourceScene)
        try await waitForImport(harness)
        model.closeMeetingTransferImport(for: sourceScene)
        await harness.resumeImport(with: .imported(meetingID))
        try await waitForCompleted(model, result: .imported(meetingID))
        model.unregisterMeetingTransferScene(sourceScene)

        #expect(!model.isPresentingMeetingTransfer(in: sourceScene))
        model.dismissMeetingTransferSheet(for: sourceScene)
        model.closeMeetingTransferImport(for: sourceScene)
        model.retryMeetingTransferCleanup(for: sourceScene)
        model.importMeetingPackage(for: sourceScene)
        model.openExistingMeetingFromTransferPreview(for: sourceScene)
        try await waitForCompleted(model, result: .imported(meetingID))
        #expect(model.selectedMeetingID == nil)

        model.registerMeetingTransferScene(replacementScene)
        #expect(model.isPresentingMeetingTransfer(in: replacementScene))
        model.closeMeetingTransferImport(for: replacementScene)
        try await waitForIdle(model)
    }

    @Test("disconnecting a preview scene discards through its pinned owner")
    func disconnectingPreviewDiscardsOwnedSession() async throws {
        let sourceScene = MeetingTransferSceneID()
        let remainingScene = MeetingTransferSceneID()
        let harness = ImportLifecycleHarness()
        let model = makeModel(harness: harness)

        model.registerMeetingTransferScene(sourceScene)
        model.registerMeetingTransferScene(remainingScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-preview.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        let sessionID = await harness.resumePrepare(title: "Disconnect preview")
        try await waitForPreview(model)

        model.unregisterMeetingTransferScene(sourceScene)
        try await waitForIdle(model)

        #expect(await harness.discardedSessionIDs == [sessionID])
        #expect(model.ownedMeetingTransferSession == nil)
    }

    @Test("failed preview cleanup is rehomed to a remaining scene")
    func disconnectingPreviewRehomesCleanupFailure() async throws {
        let sourceScene = MeetingTransferSceneID()
        let remainingScene = MeetingTransferSceneID()
        let harness = ImportLifecycleHarness(discardFailures: 1)
        let model = makeModel(harness: harness)

        model.registerMeetingTransferScene(sourceScene)
        model.registerMeetingTransferScene(remainingScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-preview-cleanup.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        let sessionID = await harness.resumePrepare(title: "Disconnect cleanup")
        try await waitForPreview(model)

        model.unregisterMeetingTransferScene(sourceScene)
        try await waitForCleanup(model, sessionID: sessionID)

        #expect(model.isPresentingMeetingTransfer(in: remainingScene))
        #expect(model.ownedMeetingTransferSession?.sessionID == sessionID)
    }

    @Test("disconnecting during prepare cancels and discards the late private session")
    func disconnectingDuringPrepareDoesNotForgetLateSession() async throws {
        let sourceScene = MeetingTransferSceneID()
        let remainingScene = MeetingTransferSceneID()
        let harness = ImportLifecycleHarness()
        let model = makeModel(harness: harness)

        model.registerMeetingTransferScene(sourceScene)
        model.registerMeetingTransferScene(remainingScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-prepare.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        model.unregisterMeetingTransferScene(sourceScene)
        let sessionID = await harness.resumePrepare(title: "Late prepare")
        try await waitForIdle(model)

        #expect(await harness.discardedSessionIDs == [sessionID])
        #expect(model.ownedMeetingTransferSession == nil)
    }

    @Test("disconnecting during import retains a late commit in the remaining scene")
    func disconnectingDuringImportRehomesLateCommittedResult() async throws {
        let sourceScene = MeetingTransferSceneID()
        let remainingScene = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(holdsImport: true)
        let model = makeModel(harness: harness)

        model.registerMeetingTransferScene(sourceScene)
        model.registerMeetingTransferScene(remainingScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-import.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Disconnect import")
        try await waitForPreview(model)
        model.importMeetingPackage(for: sourceScene)
        try await waitForImport(harness)

        model.unregisterMeetingTransferScene(sourceScene)
        await harness.resumeImport(with: .imported(meetingID))
        try await waitForCompleted(model, result: .imported(meetingID))

        #expect(model.isPresentingMeetingTransfer(in: remainingScene))
        #expect(model.ownedMeetingTransferSession == nil)
    }

    @Test("cleanup committed and recovery states rehome without mutation")
    func terminalStatesRehomeWithoutMutation() async throws {
        let sourceScene = MeetingTransferSceneID()
        let remainingScene = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let cleanupID = UUID()
        let cleanupHarness = ImportLifecycleHarness(
            importError: MeetingTransferImportError.cleanupRequired(
                sessionID: cleanupID,
                committedResult: .imported(meetingID)
            )
        )
        let cleanupModel = makeModel(harness: cleanupHarness)
        cleanupModel.registerMeetingTransferScene(sourceScene)
        cleanupModel.registerMeetingTransferScene(remainingScene)
        cleanupModel.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-cleanup.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(cleanupHarness)
        await cleanupHarness.resumePrepare(title: "Cleanup")
        try await waitForPreview(cleanupModel)
        cleanupModel.importMeetingPackage(for: sourceScene)
        try await waitForCleanup(cleanupModel, sessionID: cleanupID)
        cleanupModel.unregisterMeetingTransferScene(sourceScene)
        #expect(cleanupModel.isPresentingMeetingTransfer(in: remainingScene))
        #expect(cleanupModel.meetingTransferImportState?.cleanupSessionID == cleanupID)

        let completedHarness = ImportLifecycleHarness(holdsImport: true)
        let completedModel = makeModel(harness: completedHarness)
        completedModel.registerMeetingTransferScene(sourceScene)
        completedModel.registerMeetingTransferScene(remainingScene)
        completedModel.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-completed.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(completedHarness)
        await completedHarness.resumePrepare(title: "Completed")
        try await waitForPreview(completedModel)
        completedModel.importMeetingPackage(for: sourceScene)
        try await waitForImport(completedHarness)
        completedModel.closeMeetingTransferImport(for: sourceScene)
        await completedHarness.resumeImport(with: .imported(meetingID))
        try await waitForCompleted(completedModel, result: .imported(meetingID))
        completedModel.unregisterMeetingTransferScene(sourceScene)
        #expect(completedModel.isPresentingMeetingTransfer(in: remainingScene))
        #expect(completedModel.meetingTransferImportState == .completed(.imported(meetingID)))

        let recoveryHarness = ImportLifecycleHarness(
            importResult: .pendingRecovery(meetingID)
        )
        let recoveryModel = makeModel(harness: recoveryHarness)
        recoveryModel.registerMeetingTransferScene(sourceScene)
        recoveryModel.registerMeetingTransferScene(remainingScene)
        recoveryModel.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-recovery.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(recoveryHarness)
        await recoveryHarness.resumePrepare(title: "Recovery")
        try await waitForPreview(recoveryModel)
        recoveryModel.importMeetingPackage(for: sourceScene)
        try await waitForRecovery(recoveryModel, meetingID: meetingID)
        recoveryModel.unregisterMeetingTransferScene(sourceScene)
        #expect(recoveryModel.isPresentingMeetingTransfer(in: remainingScene))
        try await waitForRecovery(recoveryModel, meetingID: meetingID)
    }

    @Test("a disconnected cold-start scene releases its pending URL before access begins")
    func disconnectingColdStartSceneDropsPendingURL() async throws {
        let sourceScene = MeetingTransferSceneID()
        let remainingScene = MeetingTransferSceneID()
        let harness = ImportLifecycleHarness()
        let scope = SecurityScopeRecorder()
        let model = makeModel(harness: harness, scope: scope)
        model.meetingTransferClient = nil
        let url = URL(fileURLWithPath: "/tmp/disconnect-cold-start.stenomeeting")

        model.registerMeetingTransferScene(sourceScene)
        model.previewMeetingPackage(at: url, sceneID: sourceScene)
        #expect(model.pendingMeetingTransferURL == url)
        model.unregisterMeetingTransferScene(sourceScene)
        model.registerMeetingTransferScene(remainingScene)
        model.meetingTransferClient = harness.client()
        model.meetingTransferClientDidBecomeReady()
        await Task.yield()

        #expect(model.pendingMeetingTransferURL == nil)
        #expect(await harness.prepareCount == 0)
        #expect(scope.starts.isEmpty)
        #expect(scope.stops.isEmpty)
    }

    @Test("pending navigation is transferred when its original scene disconnects")
    func disconnectingSceneRehomesPendingNavigation() async throws {
        let sourceScene = MeetingTransferSceneID()
        let remainingScene = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(importResult: .imported(meetingID))
        let loader = MeetingListHarness(
            outcomes: [.failure(TestLifecycleError.failed), .success([meeting(meetingID)]) ]
        )
        let model = makeModel(harness: harness, listLoader: loader.load)

        model.registerMeetingTransferScene(sourceScene)
        model.registerMeetingTransferScene(remainingScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-navigation.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Navigation")
        try await waitForPreview(model)
        model.importMeetingPackage(for: sourceScene)
        try await waitForIdle(model)

        model.unregisterMeetingTransferScene(sourceScene)
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: sourceScene) == nil)
        await model.reloadMeetings()
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: remainingScene) == meetingID)
    }

    @Test("a later scene rehomes a visible result when the owner had no fallback")
    func laterSceneRehomesVisibleResultAfterLastOwnerDisconnects() async throws {
        let sourceScene = MeetingTransferSceneID()
        let laterScene = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(importResult: .pendingRecovery(meetingID))
        let model = makeModel(harness: harness)

        model.registerMeetingTransferScene(sourceScene)
        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/disconnect-last-scene.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Later scene")
        try await waitForPreview(model)
        model.importMeetingPackage(for: sourceScene)
        try await waitForRecovery(model, meetingID: meetingID)
        model.unregisterMeetingTransferScene(sourceScene)

        #expect(!model.isPresentingMeetingTransfer(in: laterScene))
        model.registerMeetingTransferScene(laterScene)
        #expect(model.isPresentingMeetingTransfer(in: laterScene))
        try await waitForRecovery(model, meetingID: meetingID)
    }

    @Test("only the receiving scene can present and consume an import navigation request")
    func sceneOwnsTransferPresentationAndNavigation() async throws {
        let meetingID = MeetingID()
        let sourceScene = MeetingTransferSceneID()
        let otherScene = MeetingTransferSceneID()
        let harness = ImportLifecycleHarness(importResult: .imported(meetingID))
        let loader = MeetingListHarness(outcomes: [.success([meeting(meetingID)])])
        let model = makeModel(harness: harness, listLoader: loader.load)

        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/source-scene.stenomeeting"),
            sceneID: sourceScene
        )
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Source scene")
        try await waitForPreview(model)

        #expect(model.isPresentingMeetingTransfer(in: sourceScene))
        #expect(!model.isPresentingMeetingTransfer(in: otherScene))
        model.dismissMeetingTransferSheet(for: otherScene)
        #expect(model.isPresentingMeetingTransfer(in: sourceScene))

        model.importMeetingPackage(for: sourceScene)
        try await waitForIdle(model)
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: otherScene) == nil)
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: sourceScene) == meetingID)
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: sourceScene) == nil)
    }

    @Test("cancellation during reload preserves the committed result until its scene closes it")
    func cancellationDuringReloadKeepsCommittedResultAndPendingSuccessor() async throws {
        let meetingID = MeetingID()
        let firstScene = MeetingTransferSceneID()
        let secondScene = MeetingTransferSceneID()
        let firstURL = URL(fileURLWithPath: "/tmp/reload-first.stenomeeting")
        let secondURL = URL(fileURLWithPath: "/tmp/reload-second.stenomeeting")
        let harness = ImportLifecycleHarness(importResult: .imported(meetingID))
        let loader = MeetingListHarness(
            outcomes: [.success([meeting(meetingID)])],
            heldLoads: 1
        )
        let model = makeModel(harness: harness, listLoader: loader.load)

        model.registerMeetingTransferScene(firstScene)
        model.registerMeetingTransferScene(secondScene)
        model.previewMeetingPackage(at: firstURL, sceneID: firstScene)
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "First")
        try await waitForPreview(model)
        model.importMeetingPackage(for: firstScene)
        try await eventually { await loader.loadCount == 1 }

        model.previewMeetingPackage(at: secondURL, sceneID: secondScene)
        await loader.resumeLoad(with: .success([meeting(meetingID)]))
        try await waitForCompleted(model, result: .imported(meetingID))

        #expect(model.isPresentingMeetingTransfer(in: firstScene))
        #expect(!model.isPresentingMeetingTransfer(in: secondScene))
        #expect(model.pendingMeetingTransferURL == secondURL)
        #expect(model.selectedMeetingID == nil)

        model.dismissMeetingTransferSheet(for: firstScene)
        try await waitForPrepare(harness, count: 2)
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: firstScene) == meetingID)
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: secondScene) == nil)
    }
    @Test("the external security scope ends once preparation has made the private snapshot")
    func securityScopeIsBalancedAfterPrepare() async throws {
        let harness = ImportLifecycleHarness()
        let scope = SecurityScopeRecorder()
        let model = makeModel(harness: harness, scope: scope)
        let url = URL(fileURLWithPath: "/tmp/received.stenomeeting")

        model.previewMeetingPackage(at: url)
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Private snapshot")
        try await waitForPreview(model)

        #expect(scope.starts == [url])
        #expect(scope.stops == [url])
        #expect(model.pendingMeetingTransferURL == nil)
    }

    @Test("the security scope is balanced after preparation errors and cancellation")
    func securityScopeIsBalancedAfterErrorAndCancellation() async throws {
        let failedScope = SecurityScopeRecorder()
        let failedHarness = ImportLifecycleHarness(prepareError: TestLifecycleError.failed)
        let failed = makeModel(harness: failedHarness, scope: failedScope)
        let failedURL = URL(fileURLWithPath: "/tmp/failed.stenomeeting")

        failed.previewMeetingPackage(at: failedURL)
        try await eventually { failed.meetingTransferImportState?.isBusy == false }
        #expect(failedScope.starts == [failedURL])
        #expect(failedScope.stops == [failedURL])

        let cancelledScope = SecurityScopeRecorder()
        let cancelledHarness = ImportLifecycleHarness()
        let cancelled = makeModel(harness: cancelledHarness, scope: cancelledScope)
        let cancelledURL = URL(fileURLWithPath: "/tmp/cancelled.stenomeeting")
        cancelled.previewMeetingPackage(at: cancelledURL)
        try await waitForPrepare(cancelledHarness)
        cancelled.closeMeetingTransferImport()
        await cancelledHarness.resumePrepare(title: "Cancelled")
        try await waitForIdle(cancelled)
        #expect(cancelledScope.starts == [cancelledURL])
        #expect(cancelledScope.stops == [cancelledURL])
    }

    @Test("the newest external URL wins and stale preparation cannot replace its dialog")
    func latestURLWins() async throws {
        let harness = ImportLifecycleHarness()
        let model = makeModel(harness: harness)
        let first = URL(fileURLWithPath: "/tmp/first.stenomeeting")
        let second = URL(fileURLWithPath: "/tmp/second.stenomeeting")

        model.previewMeetingPackage(at: first)
        try await waitForPrepare(harness)
        model.previewMeetingPackage(at: second)
        await harness.resumePrepare(at: 0, title: "Stale")
        try await waitForPrepare(harness, count: 2)
        await harness.resumePrepare(at: 1, title: "Latest")
        try await waitForPreview(model, title: "Latest")

        #expect(model.meetingTransferImportState?.preview?.title == "Latest")
        #expect(model.pendingMeetingTransferURL == nil)
    }

    @Test("closing a preview discards it through its preparing client")
    func previewCloseDiscardsOwnedSession() async throws {
        let harness = ImportLifecycleHarness()
        let model = makeModel(harness: harness)
        let url = URL(fileURLWithPath: "/tmp/close.stenomeeting")

        model.previewMeetingPackage(at: url)
        try await waitForPrepare(harness)
        let sessionID = await harness.resumePrepare(title: "Close")
        try await waitForPreview(model)
        model.closeMeetingTransferImport()
        try await waitForIdle(model)

        #expect(await harness.discardedSessionIDs == [sessionID])
        #expect(model.ownedMeetingTransferSession == nil)
    }

    @Test("imports use import-only and a late committed result remains visible after cancellation")
    func importCancellationRetainsCommittedResult() async throws {
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(holdsImport: true)
        let model = makeModel(harness: harness)

        model.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/import.stenomeeting"))
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Import")
        try await waitForPreview(model)
        model.importMeetingPackage()
        try await waitForImport(harness)
        model.closeMeetingTransferImport()
        await harness.resumeImport(with: .imported(meetingID))
        try await waitForCompleted(model, result: .imported(meetingID))

        #expect(await harness.choices == [.importOnly])
        #expect(model.selectedMeetingID == nil)
    }

    @Test("a late recovery result is never mistaken for cancellation success")
    func cancellationRetainsPendingRecovery() async throws {
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(holdsImport: true)
        let model = makeModel(harness: harness)

        model.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/recovery.stenomeeting"))
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Recovery")
        try await waitForPreview(model)
        model.importMeetingPackage()
        try await waitForImport(harness)
        model.closeMeetingTransferImport()
        await harness.resumeImport(with: .pendingRecovery(meetingID))
        try await waitForRecovery(model, meetingID: meetingID)
    }

    @Test("cleanup failure stays retryable and does not lose the prepared session")
    func cleanupRequiredCanRetry() async throws {
        let harness = ImportLifecycleHarness(discardFailures: 1)
        let model = makeModel(harness: harness)

        model.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/cleanup.stenomeeting"))
        try await waitForPrepare(harness)
        let sessionID = await harness.resumePrepare(title: "Cleanup")
        try await waitForPreview(model)
        model.closeMeetingTransferImport()
        try await waitForCleanup(model, sessionID: sessionID)
        model.retryMeetingTransferCleanup()
        try await waitForIdle(model)

        #expect(await harness.discardedSessionIDs == [sessionID])
    }

    @Test("preparation cleanup uses the client that created the orphaned session")
    func preparationCleanupRetryKeepsOriginalOwner() async throws {
        let sceneID = MeetingTransferSceneID()
        let sessionID = UUID()
        let first = ImportLifecycleHarness(
            prepareError: MeetingTransferImportError.preparationCleanupRequired(sessionID)
        )
        let second = ImportLifecycleHarness()
        let model = makeModel(harness: first)

        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/preparation-cleanup.stenomeeting"),
            sceneID: sceneID
        )
        try await waitForCleanup(model, sessionID: sessionID)
        model.meetingTransferClient = second.client()
        model.retryMeetingTransferCleanup(for: sceneID)
        try await waitForIdle(model)

        #expect(await first.discardedSessionIDs == [sessionID])
        #expect(await second.discardedSessionIDs.isEmpty)
        #expect(model.ownedMeetingTransferSession == nil)
    }

    @Test("committed cleanup retry uses its import owner and finishes only after cleanup")
    func committedCleanupRetryKeepsOriginalOwner() async throws {
        let sceneID = MeetingTransferSceneID()
        let meetingID = MeetingID()
        let cleanupSessionID = UUID()
        let first = ImportLifecycleHarness(
            importError: MeetingTransferImportError.cleanupRequired(
                sessionID: cleanupSessionID,
                committedResult: MeetingTransferImportResult.imported(meetingID)
            )
        )
        let second = ImportLifecycleHarness()
        let loader = MeetingListHarness(outcomes: [.success([meeting(meetingID)])])
        let model = makeModel(harness: first, listLoader: loader.load)

        model.previewMeetingPackage(
            at: URL(fileURLWithPath: "/tmp/committed-cleanup.stenomeeting"),
            sceneID: sceneID
        )
        try await waitForPrepare(first)
        await first.resumePrepare(title: "Committed cleanup")
        try await waitForPreview(model)
        model.importMeetingPackage(for: sceneID)
        try await waitForCleanup(model, sessionID: cleanupSessionID)
        model.meetingTransferClient = second.client()
        model.retryMeetingTransferCleanup(for: sceneID)
        try await waitForIdle(model)

        #expect(await first.choices == [MeetingTransferProcessingChoice.importOnly])
        #expect(await first.discardedSessionIDs == [cleanupSessionID])
        #expect(await second.discardedSessionIDs.isEmpty)
        #expect(model.ownedMeetingTransferSession == nil)
        #expect(model.consumeSelectedMeetingIDIfAvailable(for: sceneID) == meetingID)
    }

    @Test("successful and recovery imports release their pinned session owners")
    func terminalImportResultsReleaseOwners() async throws {
        let imported = ImportLifecycleHarness(importResult: .imported(MeetingID()))
        let importedModel = makeModel(harness: imported)
        importedModel.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/owner-success.stenomeeting"))
        try await waitForPrepare(imported)
        await imported.resumePrepare(title: "Success")
        try await waitForPreview(importedModel)
        importedModel.importMeetingPackage()
        try await waitForIdle(importedModel)
        #expect(importedModel.ownedMeetingTransferSession == nil)

        let recoveryMeetingID = MeetingID()
        let recovery = ImportLifecycleHarness(
            importResult: .pendingRecovery(recoveryMeetingID)
        )
        let recoveryModel = makeModel(harness: recovery)
        recoveryModel.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/owner-recovery.stenomeeting"))
        try await waitForPrepare(recovery)
        await recovery.resumePrepare(title: "Recovery")
        try await waitForPreview(recoveryModel)
        recoveryModel.importMeetingPackage()
        try await waitForRecovery(recoveryModel, meetingID: recoveryMeetingID)
        #expect(recoveryModel.ownedMeetingTransferSession == nil)
    }

    @Test("a prepared session remains owned by client A after client B becomes current")
    func clientSwapKeepsOwnerForCloseAndImport() async throws {
        let first = ImportLifecycleHarness()
        let second = ImportLifecycleHarness()
        let model = makeModel(harness: first)

        model.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/owner.stenomeeting"))
        try await waitForPrepare(first)
        let sessionID = await first.resumePrepare(title: "Owned")
        try await waitForPreview(model)
        model.meetingTransferClient = second.client()
        model.closeMeetingTransferImport()
        try await waitForIdle(model)

        #expect(await first.discardedSessionIDs == [sessionID])
        #expect(await second.discardedSessionIDs.isEmpty)
    }

    @Test("client replacement cannot route a prepared import through a foreign session store")
    func clientSwapKeepsOwnerForImport() async throws {
        let meetingID = MeetingID()
        let first = ImportLifecycleHarness(importResult: .imported(meetingID))
        let second = ImportLifecycleHarness()
        let model = makeModel(harness: first)

        model.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/owner-import.stenomeeting"))
        try await waitForPrepare(first)
        await first.resumePrepare(title: "Owned")
        try await waitForPreview(model)
        model.meetingTransferClient = second.client()
        model.importMeetingPackage()
        try await waitForIdle(model)

        #expect(await first.choices == [.importOnly])
        #expect(await second.choices.isEmpty)
    }

    @Test("a failed bootstrap cannot detach an already prepared owner")
    func failedBootstrapKeepsPreparedOwner() async throws {
        let harness = ImportLifecycleHarness()
        let model = AppModel(
            startPipeline: { _, _, _ in throw TestLifecycleError.failed },
            meetingTransferClient: harness.client()
        )
        model.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/restart.stenomeeting"))
        try await waitForPrepare(harness)
        let sessionID = await harness.resumePrepare(title: "Restart")
        try await waitForPreview(model)
        await model.bootstrap()
        model.closeMeetingTransferImport()
        try await waitForIdle(model)

        #expect(await harness.discardedSessionIDs == [sessionID])
    }

    @Test("reload completes before navigation is consumed and failed reload keeps the request")
    func importedNavigationWaitsForMeetingCache() async throws {
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness(importResult: .imported(meetingID))
        let loader = MeetingListHarness(outcomes: [.failure(TestLifecycleError.failed)])
        let model = makeModel(harness: harness, listLoader: loader.load)

        model.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/navigation.stenomeeting"))
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Navigation")
        try await waitForPreview(model)
        model.importMeetingPackage()
        try await waitForIdle(model)

        #expect(model.selectedMeetingID == meetingID)
        #expect(model.consumeSelectedMeetingIDIfAvailable() == nil)
        await loader.append(.success([meeting(meetingID)]))
        await model.reloadMeetings()
        #expect(model.consumeSelectedMeetingIDIfAvailable() == meetingID)
        #expect(model.consumeSelectedMeetingIDIfAvailable() == nil)
    }

    @Test("already-present navigation also waits until the existing meeting is cached")
    func existingNavigationWaitsForMeetingCache() async throws {
        let meetingID = MeetingID()
        let harness = ImportLifecycleHarness()
        let loader = MeetingListHarness(outcomes: [.success([]), .success([meeting(meetingID)])])
        let model = makeModel(harness: harness, listLoader: loader.load)

        model.previewMeetingPackage(at: URL(fileURLWithPath: "/tmp/existing.stenomeeting"))
        try await waitForPrepare(harness)
        await harness.resumePrepare(title: "Existing", disposition: .alreadyPresent(meetingID))
        try await waitForPreview(model)
        model.openExistingMeetingFromTransferPreview()
        try await waitForIdle(model)

        #expect(model.selectedMeetingID == meetingID)
        #expect(model.consumeSelectedMeetingIDIfAvailable() == nil)
        await model.reloadMeetings()
        #expect(model.consumeSelectedMeetingIDIfAvailable() == meetingID)
    }

    private func makeModel(
        harness: ImportLifecycleHarness,
        scope: SecurityScopeRecorder = SecurityScopeRecorder(),
        listLoader: (@MainActor @Sendable () async throws -> [Meeting])? = nil
    ) -> AppModel {
        AppModel(
            meetingTransferClient: harness.client(),
            meetingTransferSecurityScope: scope.resource,
            meetingListLoader: listLoader
        )
    }

    private func meeting(_ id: MeetingID) -> Meeting {
        Meeting(id: id, title: "Imported", status: .ready)
    }

    private func waitForPrepare(
        _ harness: ImportLifecycleHarness,
        count: Int = 1
    ) async throws {
        try await eventually { await harness.prepareCount >= count }
    }

    private func waitForImport(_ harness: ImportLifecycleHarness) async throws {
        try await eventually { await harness.importCount == 1 }
    }

    private func waitForPreview(
        _ model: AppModel,
        title: String? = nil
    ) async throws {
        try await eventually {
            guard case .preview(let preview) = model.meetingTransferImportState else {
                return false
            }
            return title.map { preview.title == $0 } ?? true
        }
    }

    private func waitForIdle(_ model: AppModel) async throws {
        try await eventually {
            model.meetingTransferImportState == nil && model.meetingTransferOperation == nil
        }
    }

    private func waitForCleanup(_ model: AppModel, sessionID: UUID) async throws {
        try await eventually { model.meetingTransferImportState?.cleanupSessionID == sessionID }
    }

    private func waitForCompleted(
        _ model: AppModel,
        result: MeetingTransferImportResult
    ) async throws {
        try await eventually { model.meetingTransferImportState == .completed(result) }
    }

    private func waitForRecovery(_ model: AppModel, meetingID: MeetingID) async throws {
        try await eventually { model.meetingTransferImportState == .recoveryRequired(meetingID) }
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
        throw TestLifecycleError.timedOut
    }
}

private actor ImportLifecycleHarness {
    struct PendingPrepare {
        let sessionID: UUID
        let continuation: CheckedContinuation<MeetingTransferImportPresentation, Error>
    }

    private var pendingPrepares: [PendingPrepare] = []
    private var pendingImport: CheckedContinuation<MeetingTransferImportResult, Never>?
    private var remainingDiscardFailures: Int
    private let holdsImport: Bool
    private let importResult: MeetingTransferImportResult?
    private let importError: Error?
    private let prepareError: Error?
    private(set) var choices: [MeetingTransferProcessingChoice] = []
    private(set) var discardedSessionIDs: [UUID] = []

    var prepareCount: Int { pendingPrepares.count }
    var importCount: Int { choices.count }

    init(
        holdsImport: Bool = false,
        importResult: MeetingTransferImportResult? = nil,
        importError: Error? = nil,
        prepareError: Error? = nil,
        discardFailures: Int = 0
    ) {
        self.holdsImport = holdsImport
        self.importResult = importResult
        self.importError = importError
        self.prepareError = prepareError
        remainingDiscardFailures = discardFailures
    }

    nonisolated func client() -> MeetingTransferImportClient {
        MeetingTransferImportClient(
            prepareImport: { [weak self] _, _ in
                guard let self else { throw CancellationError() }
                return try await self.prepare()
            },
            importPrepared: { [weak self] _, choice, _ in
                guard let self else { throw CancellationError() }
                return try await self.importPrepared(choice)
            },
            discardPrepared: { [weak self] sessionID in
                guard let self else { throw CancellationError() }
                try await self.discard(sessionID)
            }
        )
    }

    private func prepare() async throws -> MeetingTransferImportPresentation {
        if let prepareError { throw prepareError }
        return try await withCheckedThrowingContinuation { continuation in
            pendingPrepares.append(.init(sessionID: UUID(), continuation: continuation))
        }
    }

    @discardableResult
    func resumePrepare(
        at index: Int = 0,
        title: String,
        disposition: MeetingTransferImportDisposition = .new
    ) -> UUID {
        let pending = pendingPrepares[index]
        pending.continuation.resume(returning: .init(
            sessionID: pending.sessionID,
            sourceMeetingID: MeetingID(),
            title: title,
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            capabilities: [.notes],
            visibleSpeakerLabels: [],
            audioTracks: [],
            localeIdentifier: "de-DE",
            localeOrigin: .explicit,
            disposition: disposition
        ))
        return pending.sessionID
    }

    private func importPrepared(
        _ choice: MeetingTransferProcessingChoice
    ) async throws -> MeetingTransferImportResult {
        choices.append(choice)
        if holdsImport {
            return await withCheckedContinuation { pendingImport = $0 }
        }
        if let importError { throw importError }
        return importResult ?? .imported(MeetingID())
    }

    func resumeImport(with result: MeetingTransferImportResult) {
        pendingImport?.resume(returning: result)
        pendingImport = nil
    }

    private func discard(_ sessionID: UUID) throws {
        if remainingDiscardFailures > 0 {
            remainingDiscardFailures -= 1
            throw TestLifecycleError.failed
        }
        discardedSessionIDs.append(sessionID)
    }
}

private actor MeetingListHarness {
    private var outcomes: [Result<[Meeting], Error>]
    private var heldLoads: Int
    private var pendingLoad: CheckedContinuation<Result<[Meeting], Error>, Never>?
    private(set) var loadCount = 0

    init(
        outcomes: [Result<[Meeting], Error>],
        heldLoads: Int = 0
    ) {
        self.outcomes = outcomes
        self.heldLoads = heldLoads
    }

    nonisolated var load: @MainActor @Sendable () async throws -> [Meeting] {
        { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.next()
        }
    }

    func append(_ outcome: Result<[Meeting], Error>) {
        outcomes.append(outcome)
    }

    func resumeLoad(with outcome: Result<[Meeting], Error>) {
        pendingLoad?.resume(returning: outcome)
        pendingLoad = nil
    }

    private func next() async throws -> [Meeting] {
        loadCount += 1
        if heldLoads > 0 {
            heldLoads -= 1
            return try await withCheckedContinuation { continuation in
                pendingLoad = continuation
            }.get()
        }
        guard !outcomes.isEmpty else { return [] }
        return try outcomes.removeFirst().get()
    }
}

private final class SecurityScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStarts: [URL] = []
    private var recordedStops: [URL] = []

    var starts: [URL] { lock.withLock { recordedStarts } }
    var stops: [URL] { lock.withLock { recordedStops } }

    var resource: MeetingTransferSecurityScopedResource {
        MeetingTransferSecurityScopedResource(
            startAccessing: { [weak self] url in
                self?.lock.withLock { self?.recordedStarts.append(url) }
                return true
            },
            stopAccessing: { [weak self] url in
                self?.lock.withLock { self?.recordedStops.append(url) }
            }
        )
    }
}

private enum TestLifecycleError: Error {
    case failed
    case timedOut
}

private func english(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}
