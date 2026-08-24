import Foundation
import StenoDemo
import StenoDomain
import StenoIdentity
import StenoLibrary
import StenoPipeline
import SwiftUI
import Testing
@testable import Steno

@Suite("Demo data presentation")
struct DemoDataPresentationTests {
    @Test("demo actions share the structural library-operation lease") @MainActor
    func demoActionUsesExistingStructuralOperationBoundary() throws {
        let app = AppModel()
        let first = try #require(app.beginLibraryOperation())
        defer { app.endFolderOperation(first) }

        #expect(app.beginLibraryOperation() == nil)
    }

    @Test("sidebar selections have stable detail routes")
    func sidebarSelectionsRouteToTheExpectedDetail() {
        let meetingID = MeetingID()

        #expect(SidebarItem.demoData.detailRoute == .demoData)
        #expect(SidebarItem.recording.detailRoute == .recording)
        #expect(SidebarItem.meeting(meetingID).detailRoute == .meeting(meetingID))
    }

    @Test("install confirmation makes the local synthetic boundary explicit")
    func installConfirmationExplainsLocalSyntheticData() {
        #expect(english(DemoDataPresentation.installConfirmation.message)
            == "Install three local synthetic demo meetings. No model or network connection is used.")
    }

    @Test("replacement and removal copy state their data consequences")
    func replacementAndRemovalCopyAreExplicit() {
        #expect(english(DemoDataPresentation.keepEditedMeetings) == "Keep edited meetings")
        #expect(english(DemoDataPresentation.replaceAllDemoData) == "Replace all demo data")
        #expect(english(DemoDataPresentation.removeConfirmation.message)
            == "Marked demo meetings and their user changes are moved to Trash.")
    }

    @Test("badge depends on persisted provenance rather than title") @MainActor
    func badgeDependsOnlyOnDemoProvenance() {
        let realPrefixed = Meeting(title: "DEMO: Real meeting", status: .ready)
        let demo = Meeting(
            title: "Ordinary title",
            status: .ready,
            metadata: MeetingMetadata(
                demoProvenance: DemoProvenance(
                    datasetID: "org.steno.demo",
                    datasetVersion: "1",
                    itemID: "example"
                )
            )
        )

        #expect(!DemoBadge.shouldShow(for: realPrefixed))
        #expect(DemoBadge.shouldShow(for: demo))
    }

    @Test("demo badge describes synthetic provenance to VoiceOver") @MainActor
    func demoBadgeUsesSyntheticMeetingAccessibilityLabel() {
        #expect(english(DemoBadge.accessibilityLabel) == "Synthetic demo meeting")
    }

    @Test("demo recovery details offer a safe next step")
    func demoRecoveryDetailsAreExplicitInEnglish() {
        #expect(english(DemoDataPresentation.mutationErrorTitle)
            == "Demo data update needs attention.")
        #expect(english(DemoDataPresentation.lifecycleFailureDetail)
            == "Demo data may have changed. Check its status, then try again if needed.")
        #expect(english(DemoDataPresentation.statusFailureDetail)
            == "The current demo data status is unavailable. Check again.")
        #expect(english(DemoDataPresentation.meetingReconciliationFailureDetail)
            == "The meeting list could not be refreshed. Check again.")
        #expect(english(DemoDataPresentation.folderReconciliationFailureDetail)
            == "The folder list could not be refreshed. Meetings are up to date.")
    }

    @Test("demo speaker review retains only the evidence-free generic action")
    func demoSpeakerReviewOnlyKeepsGeneric() {
        let cluster = IdentityCluster(
            meetingID: MeetingID(),
            runID: RunID(),
            channel: "mic",
            clusterID: "A",
            recordingType: .inPerson,
            embedding: [1, 0],
            speechDurationSeconds: 12,
            segmentCount: 1,
            containsMultipleSpeakers: false,
            reviewState: .unreviewed
        )

        #expect(SpeakerReviewPresentation.actions(
            for: cluster,
            suggestion: nil,
            evidenceMutationIsAllowed: false
        ) == [.keepGeneric])
        #expect(SpeakerReviewPresentation.demoExplanation != nil)
    }

    @Test("each demo item has an honest localized state presentation")
    func itemStatePresentationCoversTheCompleteManifestMatrix() {
        let states: [(DemoLibraryItemState, String, String?)] = [
            (.missing, "Not installed", "Install demo meetings to add this local sample."),
            (.installed, "Installed", nil),
            (.modified, "Edited", "Your changes are kept unless you choose Replace all demo data."),
            (.outdated(installedVersion: "1"), "Update available", "Installed version 1 can be updated."),
            (.conflictingMeeting, "Needs attention", "A meeting with this ID is not demo data. It cannot be installed or replaced as demo data."),
        ]

        for (state, expectedStatus, expectedHint) in states {
            let presentation = DemoDataPresentation.itemPresentation(
                DemoLibraryItemStatus(
                    meetingID: MeetingID(),
                    itemID: "projektauftakt",
                    state: state
                )
            )
            #expect(english(presentation.status) == expectedStatus)
            #expect(presentation.hint.map(english) == expectedHint)
            #expect(!presentation.systemImage.isEmpty)
        }
    }

    @Test("status always exposes the three manifest item rows")
    func itemPresentationRowsUseTheFixedManifestOrder() {
        let rows = DemoDataPresentation.itemPresentations(for: status([
            .installed,
            .modified,
            .outdated(installedVersion: "1"),
        ]))

        #expect(rows.map(\.id) == ["projektauftakt", "wochenrunde", "produktinterview"])
        #expect(rows.map { english($0.title) }
            == ["Project kickoff", "Weekly round", "Product interview"])
    }

    @Test("action policy never treats a conflict as installed")
    func actionPolicyMatrixKeepsConflictsClosed() {
        let conflict = status([.conflictingMeeting, .installed, .missing])
        let conflictingModified = status([.conflictingMeeting, .modified, .missing])
        let onlyConflict = status([.conflictingMeeting, .missing, .missing])
        let partial = status([.missing, .installed, .modified])
        let missingAndOutdated = status([
            .missing, .outdated(installedVersion: "1"), .installed,
        ])
        let owned = status([.installed, .modified, .outdated(installedVersion: "1")])
        let installedAndMissing = status([.installed, .missing, .missing])
        let plainInstalled = status([.installed, .installed, .installed])
        let allMissing = status([.missing, .missing, .missing])

        #expect(DemoDataPresentation.actionPolicy(for: conflict)
            == DemoDataActionPolicy(install: false, replace: false, remove: true))
        #expect(DemoDataPresentation.actionPolicy(for: conflictingModified)
            == DemoDataActionPolicy(install: false, replace: false, remove: true))
        #expect(DemoDataPresentation.actionPolicy(for: onlyConflict) == .none)
        #expect(english(DemoDataPresentation.statusText(conflict))
            == "Demo data needs attention")
        #expect(DemoDataPresentation.actionPolicy(for: partial) == .all)
        #expect(DemoDataPresentation.actionPolicy(for: missingAndOutdated)
            == DemoDataActionPolicy(install: false, replace: true, remove: true))
        #expect(DemoDataPresentation.actionPolicy(for: owned)
            == DemoDataActionPolicy(install: false, replace: true, remove: true))
        #expect(DemoDataPresentation.actionPolicy(for: installedAndMissing)
            == DemoDataActionPolicy(install: true, replace: false, remove: true))
        #expect(DemoDataPresentation.actionPolicy(for: plainInstalled)
            == DemoDataActionPolicy(install: false, replace: false, remove: true))
        #expect(DemoDataPresentation.actionPolicy(for: allMissing)
            == DemoDataActionPolicy(install: true, replace: false, remove: false))
        #expect(english(DemoDataPresentation.statusText(status([
            .modified, .outdated(installedVersion: "1"), .modified,
        ]))) == "Demo meetings are installed with changes")
    }

    @Test("lifecycle results distinguish kept, uncertain and retryable items")
    func lifecycleResultMessagesAreNotInterchangeable() {
        let retained = DemoLifecycleResult(
            retainedItems: ["projektauftakt"],
            remainingItems: ["projektauftakt"]
        )
        let uncertain = DemoLifecycleResult(
            uncertainItems: ["wochenrunde"],
            remainingItems: ["wochenrunde"]
        )
        let retryable = DemoLifecycleResult(remainingItems: ["produktinterview"])

        #expect(DemoDataPresentation.resultText(
            retained,
            locale: Locale(identifier: "en")
        ) == "Kept edited demo meetings.")
        #expect(!DemoDataPresentation.hasPartialResult(retained))
        #expect(DemoDataPresentation.resultText(
            uncertain,
            locale: Locale(identifier: "en")
        ) == "The outcome of some demo meetings is unknown. Check their status.")
        #expect(DemoDataPresentation.hasPartialResult(uncertain))
        #expect(DemoDataPresentation.resultText(
            retryable,
            locale: Locale(identifier: "en")
        ) == "Retry to finish the remaining demo meetings.")
        #expect(DemoDataPresentation.hasPartialResult(retryable))
    }

    @Test("replacement confirmation routes each choice to a lifecycle operation")
    func replacementConfirmationRoutesUserChoices() {
        #expect(english(DemoDataPresentation.replacementConfirmation.message)
            == "Keeping edited meetings leaves their changes in place. Replace all demo data moves edited demo meetings and their user changes to Trash.")
        #expect(DemoDataPresentation.lifecycleCommand(for: .install) == .install)
        #expect(DemoDataPresentation.lifecycleCommand(for: .keepEditedMeetings)
            == .replace(replacingEditedMeetings: false))
        #expect(DemoDataPresentation.lifecycleCommand(for: .replaceAllDemoData)
            == .replace(replacingEditedMeetings: true))
        #expect(DemoDataPresentation.lifecycleCommand(for: .remove) == .remove)
        #expect(DemoDataPresentation.lifecycleCommand(for: .cancel) == nil)
    }

    @Test("a lifecycle failure still publishes a reconciled status and meeting list") @MainActor
    func lifecycleFailureStillReconcilesUnderTheSameOperation() async throws {
        let expectedStatus = status([.installed, .missing, .missing])
        let initialMeeting = Meeting(title: "Before refresh", status: .ready)
        let reconciledMeeting = Meeting(title: "After refresh", status: .ready)
        let fixture = try DemoDataLifecycleFixture(
            client: demoClient(
                status: .success(expectedStatus),
                install: .failure(.lifecycleFailed)
            ),
            meetings: [initialMeeting]
        )
        defer { fixture.remove() }
        await fixture.start()
        await fixture.reloadProbe.replaceMeetings(with: [reconciledMeeting])

        await fixture.app.installDemoData()

        #expect(fixture.app.demoDataError
            == String(localized: DemoDataPresentation.lifecycleFailureDetail))
        #expect(fixture.app.demoDataStatus == expectedStatus)
        #expect(fixture.app.meetings == [reconciledMeeting])
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError == nil)
        #expect(fixture.app.demoDataOperation == nil)
    }

    @Test("lifecycle and reconciliation failures remain separate") @MainActor
    func lifecycleAndReconciliationFailuresAreBothVisible() async throws {
        let expectedStatus = status([.installed, .missing, .missing])
        let fixture = try DemoDataLifecycleFixture(
            client: demoClient(
                status: .success(expectedStatus),
                install: .failure(.lifecycleFailed)
            ),
            meetings: [Meeting(title: "Before refresh", status: .ready)]
        )
        defer { fixture.remove() }
        await fixture.start()
        await fixture.reloadProbe.failNextLoad()

        await fixture.app.installDemoData()

        #expect(fixture.app.demoDataError
            == String(localized: DemoDataPresentation.lifecycleFailureDetail))
        #expect(fixture.app.demoDataStatus == expectedStatus)
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError
            == String(localized: DemoDataPresentation.meetingReconciliationFailureDetail))
        #expect(fixture.app.startupFailure == nil)
    }

    @Test("demo folder reconciliation keeps meetings visible without a sidebar failure") @MainActor
    func demoFolderReconciliationKeepsFailureInTheDemoSurface() async throws {
        let expectedStatus = status([.installed, .missing, .missing])
        let visibleMeeting = Meeting(title: "Visible meeting", status: .ready)
        let fixture = try DemoDataLifecycleFixture(
            client: demoClient(status: .success(expectedStatus)),
            meetings: [visibleMeeting]
        )
        defer { fixture.remove() }
        await fixture.start()
        await fixture.folderProbe.failNextLoad()

        await fixture.app.refreshDemoDataStatus()

        #expect(fixture.app.demoDataStatus == expectedStatus)
        #expect(fixture.app.meetings == [visibleMeeting])
        #expect(fixture.app.folders.isEmpty)
        #expect(fixture.app.demoDataReconciliationError
            == String(localized: DemoDataPresentation.folderReconciliationFailureDetail))
        #expect(fixture.app.startupFailure == nil)
    }

    @Test("status failures have their own recovery message") @MainActor
    func statusFailureDoesNotMasqueradeAsAChangeFailure() async throws {
        let fixture = try DemoDataLifecycleFixture(
            client: demoClient(
                status: .failure(.statusFailed),
                install: .success(())
            ),
            meetings: [Meeting(title: "Visible meeting", status: .ready)]
        )
        defer { fixture.remove() }
        await fixture.start()

        await fixture.app.installDemoData()

        #expect(fixture.app.demoDataError == nil)
        #expect(fixture.app.demoDataStatusError
            == String(localized: DemoDataPresentation.statusFailureDetail))
        #expect(fixture.app.demoDataReconciliationError == nil)
    }

    @Test("a successful demo lifecycle clears every previous feedback channel") @MainActor
    func successfulDemoLifecycleClearsPreviousFeedback() async throws {
        let expectedStatus = status([.installed, .installed, .installed])
        let statusSequence = DemoDataStatusSequence([
            .failure(.statusFailed),
            .success(expectedStatus),
        ])
        let installSequence = DemoDataInstallSequence([
            .failure(.lifecycleFailed),
            .success(()),
        ])
        let fixture = try DemoDataLifecycleFixture(
            client: DemoDataLifecycleClient(
                status: { try await statusSequence.next() },
                install: { try await installSequence.next() },
                replace: { _ in DemoLifecycleResult() },
                remove: { DemoLifecycleResult() }
            ),
            meetings: []
        )
        defer { fixture.remove() }
        await fixture.start()
        await fixture.reloadProbe.failNextLoad()

        await fixture.app.installDemoData()

        #expect(fixture.app.demoDataError != nil)
        #expect(fixture.app.demoDataStatusError != nil)
        #expect(fixture.app.demoDataReconciliationError != nil)

        await fixture.app.installDemoData()

        #expect(fixture.app.demoDataStatus == expectedStatus)
        #expect(fixture.app.demoDataError == nil)
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError == nil)
    }

    @Test("demo setup failures use the same safe lifecycle and status channels") @MainActor
    func setupFailuresUseSafeDemoRecoveryDetails() async throws {
        let fixture = try DemoDataLifecycleFixture(
            client: demoClient(status: .success(status([.missing, .missing, .missing]))),
            meetings: [],
            clientFactoryFailure: .setupFailed
        )
        defer { fixture.remove() }
        await fixture.start()

        await fixture.app.installDemoData()

        #expect(fixture.app.demoDataError
            == String(localized: DemoDataPresentation.lifecycleFailureDetail))
        #expect(fixture.app.demoDataStatus == nil)
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError == nil)

        let unpreparedApp = AppModel()
        await unpreparedApp.refreshDemoDataStatus()

        #expect(unpreparedApp.demoDataStatus == nil)
        #expect(unpreparedApp.demoDataError == nil)
        #expect(unpreparedApp.demoDataStatusError
            == String(localized: DemoDataPresentation.statusFailureDetail))
        #expect(unpreparedApp.demoDataReconciliationError == nil)
    }

    @Test("a failed reconciliation invalidates the previous demo status and policy") @MainActor
    func failedStatusReconciliationDoesNotLeaveInstalledDataActive() async throws {
        let installed = status([.installed, .installed, .installed])
        let statusSequence = DemoDataStatusSequence([
            .success(installed),
            .failure(.statusFailed),
        ])
        let fixture = try DemoDataLifecycleFixture(
            client: DemoDataLifecycleClient(
                status: { try await statusSequence.next() },
                install: {},
                replace: { _ in DemoLifecycleResult() },
                remove: { DemoLifecycleResult(completedItems: ["projektauftakt"]) }
            ),
            meetings: [Meeting(title: "Visible meeting", status: .ready)]
        )
        defer { fixture.remove() }
        await fixture.start()

        await fixture.app.refreshDemoDataStatus()
        #expect(fixture.app.demoDataStatus == installed)
        #expect(DemoDataPresentation.actionPolicy(for: fixture.app.demoDataStatus).remove)

        await fixture.app.removeDemoData()

        #expect(fixture.app.demoDataStatus == nil)
        #expect(DemoDataPresentation.itemPresentations(
            for: fixture.app.demoDataStatus
        ).isEmpty)
        #expect(DemoDataPresentation.actionPolicy(
            for: fixture.app.demoDataStatus
        ) == .none)
        #expect(english(DemoDataPresentation.statusText(fixture.app.demoDataStatus))
            == "Not checked yet")
        #expect(fixture.app.demoDataStatusError
            == String(localized: DemoDataPresentation.statusFailureDetail))
    }

    @Test("rejected parallel demo requests leave the active status refresh authoritative") @MainActor
    func rejectedParallelDemoRequestsDoNotPublishBusyErrors() async throws {
        let freshStatus = status([.installed, .installed, .installed])
        let statusGate = PausableDemoDataStatusClient(status: freshStatus)
        let fixture = try DemoDataLifecycleFixture(
            client: DemoDataLifecycleClient(
                status: { await statusGate.loadStatus() },
                install: {},
                replace: { _ in DemoLifecycleResult() },
                remove: { DemoLifecycleResult() }
            ),
            meetings: []
        )
        defer { fixture.remove() }
        await fixture.start()

        let firstRefresh = Task { @MainActor in
            await fixture.app.refreshDemoDataStatus()
        }
        await statusGate.waitUntilEntered()

        #expect(fixture.app.demoDataStatus == nil)
        #expect(fixture.app.demoDataError == nil)
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError == nil)
        #expect(fixture.app.demoDataOperation == .checkingStatus)

        await fixture.app.refreshDemoDataStatus()
        await fixture.app.removeDemoData()

        #expect(fixture.app.demoDataStatus == nil)
        #expect(fixture.app.demoDataError == nil)
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError == nil)
        #expect(fixture.app.demoDataOperation == .checkingStatus)

        await statusGate.release()
        await firstRefresh.value

        #expect(fixture.app.demoDataStatus == freshStatus)
        #expect(fixture.app.demoDataError == nil)
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError == nil)
        #expect(fixture.app.demoDataOperation == nil)
    }

    @Test("checking status retains the previous lifecycle error") @MainActor
    func checkingStatusDoesNotClearAnEarlierLifecycleFailure() async throws {
        let fixture = try DemoDataLifecycleFixture(
            client: demoClient(
                status: .success(status([.missing, .missing, .missing])),
                install: .failure(.lifecycleFailed)
            ),
            meetings: []
        )
        defer { fixture.remove() }
        await fixture.start()

        await fixture.app.installDemoData()
        await fixture.app.refreshDemoDataStatus()

        #expect(fixture.app.demoDataError
            == String(localized: DemoDataPresentation.lifecycleFailureDetail))
    }

    @Test("a busy folder operation leaves the existing demo state untouched") @MainActor
    func folderOperationBusyDoesNotMutateDemoState() async throws {
        let installed = status([.installed, .installed, .installed])
        let fixture = try DemoDataLifecycleFixture(
            client: demoClient(status: .success(installed)),
            meetings: []
        )
        defer { fixture.remove() }
        await fixture.start()

        await fixture.app.removeDemoData()
        let priorResult = try #require(fixture.app.demoDataResult)
        #expect(fixture.app.demoDataStatus == installed)
        #expect(fixture.app.demoDataError == nil)
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError == nil)

        let heldOperation = try #require(fixture.app.beginLibraryOperation())
        defer { fixture.app.endFolderOperation(heldOperation) }

        await fixture.app.refreshDemoDataStatus()
        await fixture.app.removeDemoData()

        #expect(fixture.app.demoDataStatus == installed)
        #expect(fixture.app.demoDataResult == priorResult)
        #expect(fixture.app.demoDataError == nil)
        #expect(fixture.app.demoDataStatusError == nil)
        #expect(fixture.app.demoDataReconciliationError == nil)
    }

    @Test("demo operation snapshots reject expired leases and replaced runtimes") @MainActor
    func demoOperationSnapshotsRequireTheCurrentRuntimeAndLease() async throws {
        let fixture = try DemoDataLifecycleFixture(
            client: demoClient(status: .success(status([.missing, .missing, .missing]))),
            meetings: []
        )
        defer { fixture.remove() }
        await fixture.start()
        let runtimeSnapshot = try #require(fixture.app.runtimeSnapshot())
        let operation = try #require(fixture.app.beginLibraryOperation())
        let operationSnapshot = try fixture.app.folderOperationSnapshot()

        #expect(fixture.app.isCurrent(operationSnapshot, operation: operation))
        fixture.app.endFolderOperation(operation)
        #expect(!fixture.app.isCurrent(operationSnapshot, operation: operation))

        await fixture.app.restartPipelineAfterConfigurationChange()
        #expect(!fixture.app.isCurrent(runtimeSnapshot))
    }

    @Test("runtime detachment waits for the active demo lease") @MainActor
    func runtimeDetachmentWaitsForTheActiveDemoLease() async throws {
        let expectedStatus = status([.installed, .installed, .installed])
        let statusGate = PausableDemoDataStatusClient(status: expectedStatus)
        let waiterRegistration = DemoDataWaiterRegistration()
        let pipelineStartGate = DemoDataPipelineStartGate()
        let fixture = try DemoDataLifecycleFixture(
            client: DemoDataLifecycleClient(
                status: { await statusGate.loadStatus() },
                install: {},
                replace: { _ in DemoLifecycleResult() },
                remove: { DemoLifecycleResult() }
            ),
            meetings: [],
            beforePipelineStart: { await pipelineStartGate.pauseIfRequested() },
            didRegisterFolderOperationWaiter: { waiterRegistration.record() }
        )
        defer { fixture.remove() }
        await fixture.start()
        let originalCoordinator = try #require(fixture.app.runtime?.coordinator)
        await pipelineStartGate.pauseTheNextStart()

        let refresh = Task { @MainActor in
            await fixture.app.refreshDemoDataStatus()
        }
        await statusGate.waitUntilEntered()

        let restart = Task { @MainActor in
            await fixture.app.restartPipelineAfterConfigurationChange()
        }
        await waiterRegistration.waitUntilRegistered()

        let coordinatorWhileWaiting = try #require(fixture.app.runtime?.coordinator)
        #expect(coordinatorWhileWaiting === originalCoordinator)
        #expect(fixture.app.demoDataOperation == .checkingStatus)

        await statusGate.release()
        await refresh.value

        #expect(fixture.app.demoDataStatus == expectedStatus)
        await pipelineStartGate.waitUntilEntered()
        #expect(fixture.app.runtime == nil)
        #expect(fixture.app.demoDataStatus == expectedStatus)

        await pipelineStartGate.resume()
        await restart.value
        let restartedCoordinator = try #require(fixture.app.runtime?.coordinator)
        #expect(restartedCoordinator !== originalCoordinator)
    }

    private func status(_ states: [DemoLibraryItemState]) -> DemoLibraryStatus {
        DemoLibraryStatus(
            datasetID: "org.steno.demo",
            datasetVersion: "1",
            items: zip(["projektauftakt", "wochenrunde", "produktinterview"], states)
                .map { itemID, state in
                    DemoLibraryItemStatus(
                        meetingID: MeetingID(),
                        itemID: itemID,
                        state: state
                    )
                }
        )
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var englishResource = resource
        englishResource.locale = Locale(identifier: "en")
        return String(localized: englishResource)
    }

    private func demoClient(
        status: Result<DemoLibraryStatus, DemoDataLifecycleTestError>,
        install: Result<Void, DemoDataLifecycleTestError> = .success(())
    ) -> DemoDataLifecycleClient {
        DemoDataLifecycleClient(
            status: {
                switch status {
                case .success(let value): value
                case .failure(let error): throw error
                }
            },
            install: {
                switch install {
                case .success: return
                case .failure(let error): throw error
                }
            },
            replace: { _ in DemoLifecycleResult() },
            remove: { DemoLifecycleResult() }
        )
    }
}

private enum DemoDataLifecycleTestError: Error, Sendable {
    case lifecycleFailed
    case statusFailed
    case reloadFailed
    case setupFailed
}

private actor DemoDataReloadProbe {
    private var meetings: [Meeting]
    private var shouldFailNextLoad = false

    init(meetings: [Meeting]) {
        self.meetings = meetings
    }

    func replaceMeetings(with meetings: [Meeting]) {
        self.meetings = meetings
    }

    func failNextLoad() {
        shouldFailNextLoad = true
    }

    func loadMeetings() throws -> [Meeting] {
        if shouldFailNextLoad {
            shouldFailNextLoad = false
            throw DemoDataLifecycleTestError.reloadFailed
        }
        return meetings
    }
}

private actor DemoDataStatusSequence {
    private var results: [Result<DemoLibraryStatus, DemoDataLifecycleTestError>]

    init(_ results: [Result<DemoLibraryStatus, DemoDataLifecycleTestError>]) {
        self.results = results
    }

    func next() throws -> DemoLibraryStatus {
        guard !results.isEmpty else { throw DemoDataLifecycleTestError.statusFailed }
        return try results.removeFirst().get()
    }
}

private actor DemoDataInstallSequence {
    private var results: [Result<Void, DemoDataLifecycleTestError>]

    init(_ results: [Result<Void, DemoDataLifecycleTestError>]) {
        self.results = results
    }

    func next() throws {
        guard !results.isEmpty else { throw DemoDataLifecycleTestError.lifecycleFailed }
        try results.removeFirst().get()
    }
}

private actor DemoDataFolderProbe {
    private var shouldFailNextLoad = false

    func failNextLoad() {
        shouldFailNextLoad = true
    }

    func loadFolders() throws -> [Folder] {
        if shouldFailNextLoad {
            shouldFailNextLoad = false
            throw DemoDataLifecycleTestError.reloadFailed
        }
        return []
    }
}

private actor PausableDemoDataStatusClient {
    private let status: DemoLibraryStatus
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(status: DemoLibraryStatus) {
        self.status = status
    }

    func loadStatus() async -> DemoLibraryStatus {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseContinuation = $0 }
        return status
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class DemoDataWaiterRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        lock.lock()
        registered = true
        let pendingWaiters = waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitUntilRegistered() async {
        guard !isRegistered else { return }
        await withCheckedContinuation { continuation in
            register(continuation)
        }
    }

    private var isRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if registered {
            lock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

private actor DemoDataPipelineStartGate {
    private var shouldPauseNextStart = false
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseTheNextStart() {
        shouldPauseNextStart = true
    }

    func pauseIfRequested() async {
        guard shouldPauseNextStart else { return }
        shouldPauseNextStart = false
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class DemoDataLifecycleFixture {
    let root: URL
    let app: AppModel
    let reloadProbe: DemoDataReloadProbe
    let folderProbe: DemoDataFolderProbe

    init(
        client: DemoDataLifecycleClient,
        meetings: [Meeting],
        clientFactoryFailure: DemoDataLifecycleTestError? = nil,
        beforePipelineStart: @escaping @Sendable () async -> Void = {},
        didRegisterFolderOperationWaiter: @escaping @Sendable () -> Void = {}
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-DemoDataLifecycleTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let library = try Library.open(at: root)
        let reloadProbe = DemoDataReloadProbe(meetings: meetings)
        let folderProbe = DemoDataFolderProbe()
        self.reloadProbe = reloadProbe
        self.folderProbe = folderProbe
        app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, locale, _ in
                await beforePipelineStart()
                return try Self.makeRuntime(for: library, locale: locale)
            },
            didRegisterFolderOperationWaiter: didRegisterFolderOperationWaiter,
            loadMeetings: { _ in try await reloadProbe.loadMeetings() },
            loadFolders: { _ in try await folderProbe.loadFolders() },
            demoDataClientFactory: { _, _ in
                if let clientFactoryFailure { throw clientFactoryFailure }
                return client
            },
            libraryURL: root
        )
    }

    func start() async {
        await app.bootstrap()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeRuntime(
        for library: Library,
        locale: Locale
    ) throws -> PipelineRuntime {
        let jobStore = try JobStore(layout: library.layout)
        let coordinator = PipelineCoordinator(
            library: library,
            jobStore: jobStore,
            providers: [:],
            locale: locale
        )
        return PipelineRuntime(
            library: library,
            jobStore: jobStore,
            coordinator: coordinator
        )
    }
}
