import Foundation
import StenoDemo
import StenoDomain
import StenoIdentity
import StenoLibrary
import Testing
@testable import steno_macos

@Suite("Demo data presentation")
struct DemoDataPresentationTests {
    @Test("installation explains the three local synthetic meetings precisely")
    func installationConfirmationIsHonest() {
        let confirmation = DemoDataPresentation.installationConfirmation
        let english = Locale(identifier: "en")

        #expect(
            localized(confirmation.title, locale: english)
                == "Install demo meetings?"
        )
        #expect(
            localized(confirmation.message, locale: english)
                == "Steno installs three local synthetic meetings for screenshots and benchmarks. No model or network connection is used."
        )
        #expect(
            localized(confirmation.confirmationAction, locale: english)
                == "Install demo meetings"
        )
    }

    @Test("replacement makes keeping edits and replacing all demo data distinct")
    func replacementOptionsAreExplicit() {
        let english = Locale(identifier: "en")
        #expect(
            localized(DemoDataPresentation.keepEditedMeetingsAction, locale: english)
                == "Keep edited meetings"
        )
        #expect(
            localized(DemoDataPresentation.replaceAllDemoDataAction, locale: english)
                == "Replace all demo data"
        )
    }

    @Test("removal explains that marked meetings and edits move to Trash")
    func removalConfirmationUsesTrashCopy() {
        let confirmation = DemoDataPresentation.removalConfirmation
        let english = Locale(identifier: "en")

        #expect(
            localized(confirmation.title, locale: english)
                == "Remove demo data?"
        )
        #expect(
            localized(confirmation.message, locale: english)
                == "Marked demo meetings, including your changes, move to Trash. Other meetings stay in the library."
        )
        #expect(
            localized(confirmation.confirmationAction, locale: english)
                == "Remove demo data"
        )
    }

    @Test("badges use persisted demo provenance rather than titles or folders")
    func badgeDependsOnlyOnMeetingDemoState() {
        let realMeeting = Meeting(title: "DEMO: Not sample data", status: .ready)
        let demoMeeting = Meeting(
            title: "A renamed sample",
            status: .ready,
            metadata: MeetingMetadata(demoProvenance: DemoProvenance(
                datasetID: "synthetic-demo",
                datasetVersion: "1",
                itemID: "sample"
            ))
        )

        #expect(!DemoBadge.isVisible(for: realMeeting))
        #expect(DemoBadge.isVisible(for: demoMeeting))
    }

    @Test("every fixed demo item has a localized honest state line")
    func itemPresentationCoversEveryLifecycleState() {
        let english = Locale(identifier: "en")
        let cases: [(String, DemoLibraryItemState, String, String, String, String)] = [
            (
                "projektauftakt", .missing, "Project kickoff", "Not installed",
                "Install demo meetings to add this local synthetic meeting.",
                "arrow.down.circle"
            ),
            (
                "wochenrunde", .installed, "Weekly round", "Installed",
                "Matches the bundled demo data.", "checkmark.circle"
            ),
            (
                "produktinterview", .modified, "Product interview", "Edited",
                "Your changes stay unless you choose Replace all demo data.",
                "pencil.circle"
            ),
            (
                "projektauftakt", .outdated(installedVersion: "1.0"),
                "Project kickoff", "Update available",
                "Installed demo data is version 1.0.",
                "arrow.triangle.2.circlepath"
            ),
            (
                "wochenrunde", .conflictingMeeting, "Weekly round",
                "Conflicting meeting",
                "This meeting is not owned as demo data. Steno will not change it.",
                "exclamationmark.triangle"
            ),
        ]

        for (
            itemID,
            state,
            expectedTitle,
            expectedState,
            expectedDetail,
            expectedSymbol
        ) in cases {
            let item = DemoDataItemPresentation(
                itemID: itemID,
                state: state
            )
            #expect(localized(item.title, locale: english) == expectedTitle)
            #expect(localized(item.stateTitle, locale: english) == expectedState)
            #expect(localized(item.detail, locale: english) == expectedDetail)
            #expect(item.symbolName == expectedSymbol)
        }
    }

    @Test("demo action policy never treats a conflict as installed data")
    func actionPolicyHandlesFullStateMatrix() {
        #expect(
            DemoDataActionPolicy.actions(for: nil)
                == .init(canInstall: false, canReplace: false, canRemove: false)
        )
        let matrix: [([DemoLibraryItemState], DemoDataActionPolicy.Actions)] = [
            (
                [.missing, .missing, .missing],
                .init(canInstall: true, canReplace: false, canRemove: false)
            ),
            (
                [.installed, .missing, .missing],
                .init(canInstall: true, canReplace: false, canRemove: true)
            ),
            (
                [.installed, .modified, .outdated(installedVersion: "1.0")],
                .init(canInstall: false, canReplace: true, canRemove: true)
            ),
            (
                [.modified, .missing, .missing],
                .init(canInstall: true, canReplace: true, canRemove: true)
            ),
            (
                [.outdated(installedVersion: "1.0"), .missing, .missing],
                .init(canInstall: false, canReplace: true, canRemove: true)
            ),
            (
                [.installed, .installed, .installed],
                .init(canInstall: false, canReplace: false, canRemove: true)
            ),
            (
                [.installed, .conflictingMeeting, .missing],
                .init(canInstall: false, canReplace: false, canRemove: true)
            ),
            (
                [.modified, .conflictingMeeting, .missing],
                .init(canInstall: false, canReplace: false, canRemove: true)
            ),
            (
                [.conflictingMeeting, .missing, .missing],
                .init(canInstall: false, canReplace: false, canRemove: false)
            ),
        ]

        for (states, expected) in matrix {
            #expect(DemoDataActionPolicy.actions(for: status(states)) == expected)
        }
    }

    @Test("a foreign conflict still permits removing owned demo data")
    func actionPolicyAllowsRemoveAlongsideConflict() {
        let actions = DemoDataActionPolicy.actions(
            for: status([.installed, .conflictingMeeting, .missing])
        )

        #expect(!actions.canInstall)
        #expect(!actions.canReplace)
        #expect(actions.canRemove)
    }

    @Test("retained results do not claim why a meeting was kept")
    func retainedResultCopyIsNeutral() throws {
        let result = DemoLifecycleResult(retainedItems: ["projektauftakt"])
        let retained = try #require(
            DemoDataPresentation.lifecycleEntries(for: result).first
        )

        #expect(retained.kind == .retained)
        #expect(
            localized(retained.summary, locale: Locale(identifier: "en"))
                == "Some meetings were kept and will not be retried."
        )
    }

    @Test("a successful status refresh preserves a prior lifecycle error and partial result")
    func statusSuccessPreservesLifecycleOutcome() {
        let partialResult = DemoLifecycleResult(remainingItems: ["wochenrunde"])
        var state = DemoDataPresentationState(
            lifecycleError: "The operation failed.",
            lifecycleResult: partialResult
        )
        let token = state.beginStatusCheck()
        let didPublish = state.publish(
            status([.installed, .missing, .missing]),
            for: token
        )

        #expect(didPublish)
        #expect(state.lifecycleError == "The operation failed.")
        #expect(state.lifecycleResult == partialResult)
        #expect(state.statusError == nil)
        #expect(!state.isChecking)
        #expect(
            DemoDataPresentation.lifecycleEntries(for: partialResult).map(\.kind)
                == [.retryable]
        )
        #expect(
            DemoDataPresentation.lifecycleEntries(for: partialResult).first?.itemIDs
                == ["wochenrunde"]
        )
    }

    @Test("lifecycle outcomes keep retained, uncertain, and retryable items separate")
    func lifecycleEntriesSeparateOutcomeSemantics() {
        let result = DemoLifecycleResult(
            retainedItems: ["produktinterview", "projektauftakt"],
            uncertainItems: ["wochenrunde", "projektauftakt"],
            remainingItems: ["projektauftakt", "wochenrunde", "produktinterview", "retry"]
        )

        let entries = DemoDataPresentation.lifecycleEntries(for: result)

        #expect(entries.map(\.kind) == [.retained, .uncertain, .retryable])
        #expect(entries[0].itemIDs == ["produktinterview"])
        #expect(entries[1].itemIDs == ["projektauftakt", "wochenrunde"])
        #expect(entries[2].itemIDs == ["retry"])
    }

    @Test("a failed status refresh leaves the surface out of checking")
    func statusFailureEndsChecking() {
        var state = DemoDataPresentationState()
        let token = state.beginStatusCheck()
        let didPublishFailure = state.publishStatusFailure(
            "Could not check.",
            for: token
        )

        #expect(didPublishFailure)
        #expect(state.status == nil)
        #expect(state.statusError == "Could not check.")
        #expect(!state.isChecking)
    }

    @Test("a failed reconciliation never leaves the former status actionable")
    func failedReconciliationHidesStaleStatusAndActions() {
        var state = DemoDataPresentationState()
        let initial = state.beginStatusCheck()
        _ = state.publish(status([.installed, .installed, .installed]), for: initial)

        _ = state.invalidateStatus()
        let retry = state.beginStatusCheck()
        #expect(state.status == nil)
        #expect(DemoDataActionPolicy.actions(for: state.status)
            == .init(canInstall: false, canReplace: false, canRemove: false))

        _ = state.publishStatusFailure("Could not reconcile.", for: retry)

        #expect(state.status == nil)
        #expect(state.statusError == "Could not reconcile.")
        #expect(!state.isChecking)
        #expect(DemoDataActionPolicy.actions(for: state.status)
            == .init(canInstall: false, canReplace: false, canRemove: false))
    }

    @Test("status presentation derives its symbol from the actual result")
    func statusPresentationDoesNotUseSuccessForConflictingData() {
        let installed = DemoDataPresentation.statusPresentation(
            for: status([.installed, .installed, .installed])
        )
        let conflict = DemoDataPresentation.statusPresentation(
            for: status([.installed, .conflictingMeeting, .missing])
        )

        #expect(installed.symbolName == "checkmark.circle")
        #expect(conflict.symbolName == "exclamationmark.triangle")
        #expect(conflict.isAttention)
    }

    @Test("the app model remains idle when no library is open")
    @MainActor
    func appModelDoesNotLeaveDemoStatusCheckingWithoutRuntime() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let model = AppModel(
            meetingTransferTemporaryDirectory: { temporaryDirectory }
        )
        await model.refreshDemoDataStatus()

        #expect(model.demoDataStatus == nil)
        #expect(model.demoDataStatusError == nil)
        #expect(!model.isCheckingDemoDataStatus)
    }

    @Test("an unavailable lifecycle operation releases its management state")
    @MainActor
    func unavailableDemoOperationDoesNotRemainBusy() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let model = AppModel(
            meetingTransferTemporaryDirectory: { temporaryDirectory }
        )
        await model.installDemoData()

        #expect(!model.isManagingDemoData)
        #expect(model.demoDataError != nil)
        #expect(!model.isCheckingDemoDataStatus)
    }

    @Test("a stale publication token cannot replace current demo status")
    func staleTokenCannotPublish() {
        var state = DemoDataPresentationState()
        let stale = state.beginStatusCheck()
        let current = state.invalidateStatus()
        _ = state.beginStatusCheck()
        let expected = status([.missing, .missing, .missing])
        let publishedStaleStatus = state.publish(
            status([.installed, .installed, .installed]),
            for: stale
        )
        let publishedCurrentStatus = state.publish(expected, for: current)

        #expect(!publishedStaleStatus)
        #expect(publishedCurrentStatus)
        #expect(state.status == expected)
    }

    @Test("a publication context rejects a different library, folder store, or token")
    func publicationContextRejectsStaleRuntimeAndFolderStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-DemoDataPresentationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let firstLibrary = try Library.open(at: root.appendingPathComponent("first"))
        let firstFolders = try FolderStore.open(layout: firstLibrary.layout)
        let secondLibrary = try Library.open(at: root.appendingPathComponent("second"))
        let secondFolders = try FolderStore.open(layout: secondLibrary.layout)
        var state = DemoDataPresentationState()
        let token = state.beginStatusCheck()
        let context = DemoDataPublicationContext(
            library: firstLibrary,
            folders: firstFolders,
            token: token
        )

        #expect(context.isCurrent(
            library: firstLibrary,
            folders: firstFolders,
            token: token
        ))
        #expect(!context.isCurrent(
            library: secondLibrary,
            folders: firstFolders,
            token: token
        ))
        #expect(!context.isCurrent(
            library: firstLibrary,
            folders: secondFolders,
            token: token
        ))
        _ = state.invalidateStatus()
        #expect(!context.isCurrent(
            library: firstLibrary,
            folders: firstFolders,
            token: state.currentStatusToken
        ))
    }

    @Test("demo speaker review counts generic and multiple as reviewed")
    func demoSpeakerReviewIsReviewedRatherThanAssigned() {
        let meetingID = MeetingID()
        let runID = RunID()
        let clusters = [
            cluster(meetingID: meetingID, runID: runID, state: .unreviewed),
            cluster(meetingID: meetingID, runID: runID, state: .generic),
            cluster(meetingID: meetingID, runID: runID, state: .multiple),
        ]

        let progress = SpeakerReviewPresentation.reviewProgress(for: clusters)
        #expect(progress?.reviewed == 2)
        #expect(progress?.total == 3)
        #expect(SpeakerReviewPresentation.canLeaveGeneric(clusters[0]))
        #expect(!SpeakerReviewPresentation.canLeaveGeneric(clusters[1]))
        #expect(!SpeakerReviewPresentation.canLeaveGeneric(clusters[2]))
    }

    @Test("the language lock names demo data management in English")
    func languageManagementLockCopyIsLocalized() {
        #expect(
            localized(
                DemoDataPresentation.languageChangeLocked,
                locale: Locale(identifier: "en")
            ) == "The transcription language cannot change while demo data is being updated."
        )
        #expect(
            localized(
                DemoDataPresentation.retryStatusAction,
                locale: Locale(identifier: "en")
            ) == "Check again"
        )
    }

    private func status(_ states: [DemoLibraryItemState]) -> DemoLibraryStatus {
        DemoLibraryStatus(
            datasetID: "synthetic-demo",
            datasetVersion: "1",
            items: states.enumerated().map { index, state in
                DemoLibraryItemStatus(
                    meetingID: MeetingID(),
                    itemID: ["projektauftakt", "wochenrunde", "produktinterview"][index],
                    state: state
                )
            }
        )
    }

    private func cluster(
        meetingID: MeetingID,
        runID: RunID,
        state: IdentityCluster.ReviewState
    ) -> IdentityCluster {
        IdentityCluster(
            meetingID: meetingID,
            runID: runID,
            channel: "import",
            clusterID: UUID().uuidString,
            recordingType: .imported,
            embedding: [],
            speechDurationSeconds: 10,
            segmentCount: 1,
            reviewState: state
        )
    }

    private func localized(
        _ resource: LocalizedStringResource,
        locale: Locale
    ) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }
}
