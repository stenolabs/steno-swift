import Foundation
import StenoDomain
import StenoLibrary
import StenoPipeline
import Testing
@testable import Steno

@Suite("iOS app model folders", .serialized)
@MainActor
struct AppModelFolderIntegrationTests {
    @Test("a runtime opens one folder store and reloads persisted folders with meetings")
    func runtimeOwnsOneFolderStoreAndReloadsPersistedState() async throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        await fixture.start()

        #expect(fixture.app.folders.isEmpty)
        let meeting = try await fixture.library.createMeeting(
            title: "Planning",
            status: .ready
        )
        let work = try #require(
            await fixture.app.createFolder(named: "Work", parentFolderID: nil)
        )
        let weekly = try #require(
            await fixture.app.createFolder(named: "Weekly", parentFolderID: work.id)
        )

        #expect(fixture.app.folders.map(\.id) == [work.id, weekly.id])
        #expect(await fixture.app.moveMeeting(meeting.id, to: weekly.id))
        #expect(try await fixture.library.loadMeeting(meeting.id).folderID == weekly.id)
        #expect(fixture.openedFolderStoreCount == 1)
    }

    @Test("renaming a folder preserves its meeting assignments")
    func renamingFolderPreservesMeetingAssignments() async throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        await fixture.start()

        let folder = try #require(
            await fixture.app.createFolder(named: "Work", parentFolderID: nil)
        )
        let meeting = try await fixture.library.createMeeting(
            title: "Planning",
            status: .ready
        )
        #expect(await fixture.app.moveMeeting(meeting.id, to: folder.id))

        #expect(await fixture.app.renameFolder(folder.id, to: "Client work"))
        #expect(try await fixture.library.loadMeeting(meeting.id).folderID == folder.id)
        #expect(fixture.app.folders.first?.name == "Client work")
    }

    @Test("deleting a root unfiles direct meetings and promotes its children")
    func deletingRootUnfilesMeetingsAndPromotesChildren() async throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        await fixture.start()

        let root = try #require(
            await fixture.app.createFolder(named: "Work", parentFolderID: nil)
        )
        let child = try #require(
            await fixture.app.createFolder(named: "Weekly", parentFolderID: root.id)
        )
        let meeting = try await fixture.library.createMeeting(
            title: "Planning",
            status: .ready
        )
        #expect(await fixture.app.moveMeeting(meeting.id, to: root.id))

        #expect(await fixture.app.deleteFolder(root.id))
        #expect(try await fixture.library.loadMeeting(meeting.id).folderID == nil)
        #expect(
            try await fixture.store.listFolders().first { $0.id == child.id }?
                .parentFolderID == nil
        )
        #expect(fixture.app.folders.map(\.id) == [child.id])
    }

    @Test("an unknown move destination changes neither persisted nor visible meeting state")
    func unknownMoveDestinationLeavesMeetingUnchanged() async throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        await fixture.start()

        let folder = try #require(
            await fixture.app.createFolder(named: "Work", parentFolderID: nil)
        )
        let meeting = try await fixture.library.createMeeting(
            title: "Planning",
            status: .ready
        )
        #expect(await fixture.app.moveMeeting(meeting.id, to: folder.id))
        let visibleFolders = fixture.app.folders

        #expect(!(await fixture.app.moveMeeting(meeting.id, to: FolderID())))
        #expect(try await fixture.library.loadMeeting(meeting.id).folderID == folder.id)
        #expect(fixture.app.folders == visibleFolders)
        #expect(fixture.app.runtime != nil)
        #expect(fixture.app.recording.canRecord)
    }

    @Test("reordering a folder reloads the store order")
    func reorderingFolderReloadsPersistedOrder() async throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        await fixture.start()

        let first = try #require(
            await fixture.app.createFolder(named: "First", parentFolderID: nil)
        )
        let second = try #require(
            await fixture.app.createFolder(named: "Second", parentFolderID: nil)
        )

        #expect(await fixture.app.moveFolder(second.id, up: true))
        #expect(try await fixture.store.listFolders().map(\.id) == [second.id, first.id])
        #expect(fixture.app.folders.map(\.id) == [second.id, first.id])
    }

    @Test("a failed folder index deletion restores direct meeting assignments")
    func failedFolderDeletionRollsBackMeetingAssignments() async throws {
        let fixture = try FolderFixture(deleteFolder: { store, folderID in
            _ = store
            _ = folderID
            throw FolderFixtureError.deleteFailedBeforeCommit
        })
        defer { fixture.remove() }
        await fixture.start()

        let folder = try #require(
            await fixture.app.createFolder(named: "Work", parentFolderID: nil)
        )
        let meeting = try await fixture.library.createMeeting(
            title: "Planning",
            status: .ready
        )
        #expect(await fixture.app.moveMeeting(meeting.id, to: folder.id))

        #expect(!(await fixture.app.deleteFolder(folder.id)))
        #expect(try await fixture.library.loadMeeting(meeting.id).folderID == folder.id)
        #expect(fixture.app.runtime != nil)
        #expect(fixture.app.recording.canRecord)
    }

    @Test("a failed rollback reports the real partial state without detaching the runtime")
    func failedFolderDeletionRollbackKeepsRuntimeAttached() async throws {
        let fixture = try FolderFixture(deleteFolder: { store, folderID in
            _ = store
            _ = folderID
            throw FolderFixtureError.deleteFailedBeforeCommit
        })
        defer { fixture.remove() }
        await fixture.start()

        let folder = try #require(
            await fixture.app.createFolder(named: "Work", parentFolderID: nil)
        )
        let meeting = try await fixture.library.createMeeting(
            title: "Planning",
            status: .ready
        )
        #expect(await fixture.app.moveMeeting(meeting.id, to: folder.id))
        fixture.failFolderAssignmentRestoreAfterNextOperation()

        #expect(!(await fixture.app.deleteFolder(folder.id)))
        #expect(try await fixture.library.loadMeeting(meeting.id).folderID == nil)
        #expect(fixture.app.runtime != nil)
        #expect(fixture.app.recording.canRecord)
        #expect(fixture.app.startupFailure?.contains("could not be restored") == true)
    }

    @Test("an old reload cannot republish after its runtime was replaced")
    func staleReloadCannotPublishAfterRuntimeReplacement() async throws {
        let gate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            pauseMeetingLoadsFor: { library in library.layout.root.lastPathComponent == "R1" },
            meetingLoadGate: gate
        )
        defer { fixture.remove() }
        fixture.pauseTheNextMeetingLoad()

        let staleReload = Task { @MainActor in
            await fixture.app.reloadMeetings()
        }
        await gate.waitUntilEntered()
        await fixture.app.restartPipelineAfterConfigurationChange()
        await gate.resume()
        await staleReload.value

        #expect(fixture.app.meetings.map(\.title) == ["R2 meeting"])
        #expect(fixture.app.folders.map(\.name) == ["R2 folder"])
        #expect(fixture.folderStoreOpenCount == 2)
    }

    @Test("a concurrent folder mutation fails visibly while the first operation owns the snapshot")
    func concurrentFolderMutationDoesNotInterleave() async throws {
        let gate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            pauseMeetingFolderSet: true,
            meetingFolderSetGate: gate
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let firstFolder = try #require(fixture.folderIDs.first)
        let secondFolder = try #require(fixture.folderIDs.last)

        let firstMove = Task { @MainActor in
            await fixture.app.moveMeeting(meeting, to: firstFolder)
        }
        await gate.waitUntilEntered()
        #expect(!(await fixture.app.moveMeeting(meeting, to: secondFolder)))
        #expect(fixture.app.startupFailure?.contains("Another folder action") == true)
        await gate.resume()

        #expect(await firstMove.value)
        #expect(try await fixture.currentLibrary.loadMeeting(meeting).folderID == firstFolder)
    }

    @Test("a delete owns the folder transaction until its assignment rollback boundary is complete")
    func concurrentMoveCannotInterleaveWithDelete() async throws {
        let gate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            pauseMeetingFolderSet: true,
            meetingFolderSetGate: gate
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let deletingFolder = try #require(fixture.folderIDs.first)
        let otherFolder = try #require(fixture.folderIDs.last)

        let deletion = Task { @MainActor in await fixture.app.deleteFolder(deletingFolder) }
        await gate.waitUntilEntered()
        #expect(!(await fixture.app.moveMeeting(meeting, to: otherFolder)))
        await gate.resume()

        #expect(await deletion.value)
        #expect(try await fixture.currentLibrary.loadMeeting(meeting).folderID == nil)
        #expect(fixture.app.folders.map(\.id) == [otherFolder])
    }

    @Test("a runtime replacement waits for a paused mutation to commit")
    func runtimeReplacementWaitsForPausedMutation() async throws {
        let gate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            pauseMeetingFolderSet: true,
            meetingFolderSetGate: gate
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let oldFolder = try #require(fixture.folderIDs.first)

        let oldMove = Task { @MainActor in
            await fixture.app.moveMeeting(meeting, to: oldFolder)
        }
        await gate.waitUntilEntered()
        let restart = Task { @MainActor in
            await fixture.app.restartPipelineAfterConfigurationChange()
        }
        await gate.resume()

        #expect(await oldMove.value)
        await restart.value
        #expect(try await fixture.r1Library.loadMeeting(meeting).folderID == oldFolder)
        #expect(fixture.app.meetings.map(\.title) == ["R2 meeting"])
        #expect(fixture.app.folders.map(\.name) == ["R2 folder"])
    }

    @Test("a runtime transition lets a paused successful delete finish before detaching")
    func runtimeTransitionWaitsForSuccessfulDelete() async throws {
        let assignmentGate = FolderAsyncGate()
        let transitionGate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            meetingFolderSetGate: assignmentGate,
            runtimeTransitionStartGate: transitionGate
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)
        #expect(await fixture.app.moveMeeting(meeting, to: folder))
        fixture.pauseTheNextFolderSetAfterWrite()

        let deletion = Task { @MainActor in await fixture.app.deleteFolder(folder) }
        await assignmentGate.waitUntilEntered()
        let restart = Task { @MainActor in
            await fixture.app.restartPipelineAfterConfigurationChange()
        }
        await transitionGate.waitUntilEntered()
        await transitionGate.resume()
        await assignmentGate.resume()

        #expect(await deletion.value)
        await restart.value
        #expect(try await fixture.r1Library.loadMeeting(meeting).folderID == nil)
        let r1Store = try FolderStore.open(layout: fixture.r1Library.layout)
        #expect(try await r1Store.folder(folder) == nil)
    }

    @Test("a runtime transition lets a paused failed delete restore its assignment")
    func runtimeTransitionWaitsForDeleteRollback() async throws {
        let assignmentGate = FolderAsyncGate()
        let transitionGate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            meetingFolderSetGate: assignmentGate,
            runtimeTransitionStartGate: transitionGate,
            deleteFolder: { _, _ in throw FolderFixtureError.deleteFailedBeforeCommit }
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)
        #expect(await fixture.app.moveMeeting(meeting, to: folder))
        fixture.pauseTheNextFolderSetAfterWrite()

        let deletion = Task { @MainActor in await fixture.app.deleteFolder(folder) }
        await assignmentGate.waitUntilEntered()
        let restart = Task { @MainActor in
            await fixture.app.restartPipelineAfterConfigurationChange()
        }
        await transitionGate.waitUntilEntered()
        await transitionGate.resume()
        await assignmentGate.resume()

        #expect(!(await deletion.value))
        await restart.value
        #expect(try await fixture.r1Library.loadMeeting(meeting).folderID == folder)
        let r1Store = try FolderStore.open(layout: fixture.r1Library.layout)
        #expect(try await r1Store.folder(folder) != nil)
    }

    @Test("a reload requested during a folder operation publishes the later meeting commit")
    func reloadDuringFolderOperationIsCoalescedAfterFinalPublish() async throws {
        let folderGate = FolderAsyncGate()
        let completionGate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            folderLoadGate: folderGate,
            coalescedReloadGate: completionGate
        )
        defer { fixture.remove() }
        let folder = try #require(fixture.folderIDs.first)
        fixture.pauseTheNextFolderLoadAfterRead()

        let rename = Task { @MainActor in
            await fixture.app.renameFolder(folder, to: "Renamed")
        }
        await folderGate.waitUntilEntered()
        let laterMeeting = try await fixture.r1Library.createMeeting(
            title: "M1",
            status: .ready
        )
        let sceneID = MeetingTransferSceneID()
        fixture.app.registerMeetingTransferScene(sceneID)
        fixture.app.selectedMeetingID = laterMeeting.id
        fixture.app.selectedMeetingSceneID = sceneID
        await fixture.app.reloadMeetings()
        await fixture.app.reloadMeetings()
        await folderGate.resume()

        #expect(await rename.value)
        await completionGate.waitUntilEntered()
        #expect(fixture.app.meetings.map(\.id).contains(laterMeeting.id))
        #expect(fixture.app.consumeSelectedMeetingIDIfAvailable(for: sceneID) == laterMeeting.id)
        #expect(fixture.runtimeMeetingLoadCount == 3)
        await completionGate.resume()
    }

    @Test("a recording start is rejected after its button check when a language restart begins")
    func recordingStartRaceWithLanguageRestartFailsClosed() async throws {
        let folderGate = FolderAsyncGate()
        let recordingGate = FolderAsyncGate()
        let transitionGate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            pauseMeetingFolderSet: true,
            meetingFolderSetGate: folderGate,
            runtimeTransitionStartGate: transitionGate,
            beforeRecordingStartGate: recordingGate
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)
        let requestedLanguage = fixture.app.language.selectedID.caseInsensitiveCompare("de-DE")
            == .orderedSame ? "en-US" : "de-DE"

        let folderMove = Task { @MainActor in
            await fixture.app.moveMeeting(meeting, to: folder)
        }
        await folderGate.waitUntilEntered()
        let recordingAttempt = Task { @MainActor in await fixture.app.startRecording() }
        await recordingGate.waitUntilEntered()
        let languageChange = Task { @MainActor in
            await fixture.app.setLanguage(requestedLanguage)
        }
        await transitionGate.waitUntilEntered()
        await recordingGate.resume()

        #expect(!(await recordingAttempt.value))
        #expect(fixture.recordingStartLocales.isEmpty)
        await transitionGate.resume()
        await folderGate.resume()
        #expect(await folderMove.value)
        await languageChange.value
        #expect(fixture.runtimeLocaleIdentifiers.last == Locale(identifier: requestedLanguage).identifier)

        #expect(await fixture.app.startRecording())
        #expect(fixture.recordingStartLocales.last == Locale(identifier: requestedLanguage).identifier)
    }

    @Test("a pending reload waits without scheduling while a replacement bootstrap has no runtime")
    func pendingReloadParksAcrossFailedReplacementBootstrap() async throws {
        let transitionGate = FolderAsyncGate()
        let completionGate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            runtimeTransitionStartGate: transitionGate,
            coalescedReloadGate: completionGate,
            failPipelineAttempt: 2
        )
        defer { fixture.remove() }
        let requestedLanguage = fixture.app.language.selectedID.caseInsensitiveCompare("de-DE")
            == .orderedSame ? "en-US" : "de-DE"

        let languageChange = Task { @MainActor in
            await fixture.app.setLanguage(requestedLanguage)
        }
        await transitionGate.waitUntilEntered()
        await fixture.app.reloadMeetings()
        await fixture.app.reloadMeetings()
        await transitionGate.resume()
        await languageChange.value

        let loadsAfterFailure = fixture.runtimeMeetingLoadCount
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(fixture.runtimeMeetingLoadCount == loadsAfterFailure)
        #expect(fixture.coalescedReloadScheduleCount == 0)

        let sceneID = MeetingTransferSceneID()
        fixture.app.registerMeetingTransferScene(sceneID)
        fixture.app.selectedMeetingID = try #require(fixture.r2MeetingID)
        fixture.app.selectedMeetingSceneID = sceneID
        await fixture.app.bootstrap()
        await completionGate.waitUntilEntered()

        #expect(fixture.app.meetings.contains(where: { $0.id == fixture.r2MeetingID }))
        #expect(fixture.app.consumeSelectedMeetingIDIfAvailable(for: sceneID) == fixture.r2MeetingID)
        #expect(fixture.coalescedReloadScheduleCount == 1)
        await completionGate.resume()
    }

    @Test("a runtime transition rejects a new mutation after the old operation wakes it")
    func runtimeTransitionBarrierRejectsMutationBeforeDetach() async throws {
        let operationGate = FolderAsyncGate()
        let transitionGate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            pauseMeetingFolderSet: true,
            meetingFolderSetGate: operationGate,
            runtimeTransitionGate: transitionGate
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)

        let oldMove = Task { @MainActor in
            await fixture.app.moveMeeting(meeting, to: folder)
        }
        await operationGate.waitUntilEntered()
        let restart = Task { @MainActor in
            await fixture.app.restartPipelineAfterConfigurationChange()
        }
        await operationGate.resume()
        await transitionGate.waitUntilEntered()

        #expect(!(await fixture.app.moveMeeting(meeting, to: folder)))
        #expect(try await fixture.r1Library.loadMeeting(meeting).folderID == folder)
        await transitionGate.resume()
        #expect(await oldMove.value)
        await restart.value
        #expect(try await fixture.r1Library.loadMeeting(meeting).folderID == folder)
        #expect(fixture.app.meetings.map(\.title) == ["R2 meeting"])
    }

    @Test("a reload begun before delete cannot republish its old meeting assignment")
    func reloadBeforeMutationCannotPublishAfterDelete() async throws {
        let gate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            pauseMeetingLoadsFor: { library in library.layout.root.lastPathComponent == "R1" },
            meetingLoadGate: gate
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)
        #expect(await fixture.app.moveMeeting(meeting, to: folder))

        fixture.pauseTheNextMeetingLoad()
        let staleReload = Task { @MainActor in await fixture.app.reloadMeetings() }
        await gate.waitUntilEntered()

        #expect(await fixture.app.deleteFolder(folder))
        #expect(fixture.app.meetings.first?.folderID == nil)
        #expect(fixture.app.folders.map(\.id) == [try #require(fixture.folderIDs.last)])

        await gate.resume()
        await staleReload.value

        #expect(fixture.app.meetings.first?.folderID == nil)
        #expect(fixture.app.folders.map(\.id) == [try #require(fixture.folderIDs.last)])
    }

    @Test("an old-store reload cannot overwrite a freshly adopted recovery store")
    func oldStoreReloadCannotPublishAfterFreshStoreAdoption() async throws {
        let gate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            folderLoadGate: gate,
            deleteFolder: { _, _ in throw FolderFixtureError.deleteFailedBeforeCommit }
        )
        defer { fixture.remove() }
        let folder = try #require(fixture.folderIDs.first)

        fixture.pauseTheNextFolderLoadReturningEmpty()
        let staleReload = Task { @MainActor in await fixture.app.reloadMeetings() }
        await gate.waitUntilEntered()

        #expect(!(await fixture.app.deleteFolder(folder)))
        await gate.resume()
        await staleReload.value

        #expect(fixture.app.folders.map { $0.id } == fixture.folderIDs)
    }

    @Test("an external reload cannot publish delete's temporary unfiled assignment")
    func externalReloadCannotPublishDeleteIntermediateState() async throws {
        let gate = FolderAsyncGate()
        let fixture = try await FolderRaceFixture.make(
            meetingFolderSetGate: gate,
            deleteFolder: { _, _ in throw FolderFixtureError.deleteFailedBeforeCommit }
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)
        #expect(await fixture.app.moveMeeting(meeting, to: folder))
        fixture.pauseTheNextFolderSetAfterWrite()

        let deletion = Task { @MainActor in await fixture.app.deleteFolder(folder) }
        await gate.waitUntilEntered()
        await fixture.app.reloadMeetings()

        #expect(fixture.app.meetings.first?.folderID == folder)
        await gate.resume()
        #expect(!(await deletion.value))
        #expect(fixture.app.meetings.first?.folderID == folder)
    }

    @Test("a readable rollback failure keeps the freshly verified folder tree visible")
    func readableRollbackFailurePublishesFreshFolders() async throws {
        let fixture = try await FolderRaceFixture.make(
            deleteFolder: { _, _ in throw FolderFixtureError.deleteFailedBeforeCommit }
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)
        #expect(await fixture.app.moveMeeting(meeting, to: folder))
        fixture.failTheNextRollback()

        #expect(!(await fixture.app.deleteFolder(folder)))
        #expect(fixture.app.meetings.first?.folderID == nil)
        #expect(fixture.app.folders.map(\.id) == fixture.folderIDs)
        #expect(fixture.app.startupFailure?.contains("could not be restored") == true)
    }

    @Test("creating a folder reports failure unless its persisted state is published")
    func createFolderRequiresPublishedReload() async throws {
        let fixture = try await FolderRaceFixture.make()
        defer { fixture.remove() }
        fixture.failTheNextFolderLoad()

        #expect(await fixture.app.createFolder(named: "Unpublished") == nil)
        #expect(
            fixture.app.startupFailure?
                .contains(FolderFixtureError.storeOpenFailed.localizedDescription) == true
        )
    }

    @Test("a delete error after a committed index removal never restores an orphan folder ID")
    func committedDeleteErrorDoesNotRestoreOrphanedAssignment() async throws {
        let fixture = try await FolderRaceFixture.make(
            deleteFolder: { store, folderID in
                _ = try await store.deleteFolder(folderID)
                throw FolderFixtureError.deleteCommittedThenFailed
            }
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)
        #expect(await fixture.app.moveMeeting(meeting, to: folder))

        #expect(!(await fixture.app.deleteFolder(folder)))
        #expect(try await fixture.currentLibrary.loadMeeting(meeting).folderID == nil)
        #expect(fixture.app.folders.map(\.id) == [try #require(fixture.folderIDs.last)])
        #expect(fixture.app.startupFailure?.contains("persisted") == true)
    }

    @Test("partial recovery publishes readable meetings and clears an unreadable old folder tree")
    func partialRecoveryClearsUnreadableFolderTree() async throws {
        let fixture = try await FolderRaceFixture.make(
            deleteFolder: { store, folderID in
                try FileManager.default.removeItem(at: store.layout.folders)
                try FileManager.default.createDirectory(
                    at: store.layout.folders,
                    withIntermediateDirectories: false
                )
                return try await store.deleteFolder(folderID)
            },
            failRollback: true
        )
        defer { fixture.remove() }
        let meeting = try #require(fixture.meetingID)
        let folder = try #require(fixture.folderIDs.first)
        #expect(await fixture.app.moveMeeting(meeting, to: folder))
        fixture.failTheNextRollback()

        #expect(!(await fixture.app.deleteFolder(folder)))
        #expect(try await fixture.currentLibrary.loadMeeting(meeting).folderID == nil)
        #expect(fixture.app.meetings.map(\.id) == [meeting])
        #expect(fixture.app.folders.isEmpty)
        guard case .folders(let failure) = fixture.app.libraryIssue else {
            Issue.record("Expected the unreadable folder tree to publish a folder issue")
            return
        }
        #expect(!failure.isEmpty)
    }

    @Test("folder-store startup failure remains visible across meeting reloads")
    func folderStoreStartupFailureRemainsVisible() async throws {
        let fixture = try await FolderRaceFixture.make(openFolderStore: { _ in
            throw FolderFixtureError.storeOpenFailed
        })
        defer { fixture.remove() }

        let failure = try #require(fixture.app.startupFailure)
        await fixture.app.reloadMeetings()
        #expect(fixture.app.runtime != nil)
        #expect(fixture.app.recording.canRecord)
        #expect(fixture.app.folders.isEmpty)
        #expect(fixture.app.startupFailure == failure)
    }

    @Test("meeting-list loader leaves folders untouched without a real runtime")
    func meetingListLoaderLeavesFoldersUntouchedWithoutRuntime() async {
        let meeting = Meeting(title: "Loader meeting", status: .ready)
        let app = AppModel(meetingListLoader: { [meeting] in [meeting] })

        await app.reloadMeetings()

        #expect(app.meetings == [meeting])
        #expect(app.folders.isEmpty)
    }
}

@MainActor
private final class FolderFixture {
    typealias DeleteFolder = @Sendable (FolderStore, FolderID) async throws
        -> FolderDeletionResult?

    let root: URL
    let library: Library
    let store: FolderStore
    let app: AppModel
    private let probe: FolderFixtureProbe

    var openedFolderStoreCount: Int {
        probe.openedFolderStoreCount
    }

    init(deleteFolder: @escaping DeleteFolder = { store, folderID in
        try store.deleteFolder(folderID)
    }) throws {
        let probe = FolderFixtureProbe()
        self.probe = probe
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-AppModelFolderIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        library = try Library.open(at: root)
        store = try FolderStore.open(layout: library.layout)
        let jobStore = try JobStore(layout: library.layout)
        let coordinator = PipelineCoordinator(
            library: library,
            jobStore: jobStore,
            providers: [:],
            locale: Locale(identifier: "de-DE")
        )
        let runtime = PipelineRuntime(
            library: library,
            jobStore: jobStore,
            coordinator: coordinator
        )
        app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, _, _ in runtime },
            folderStoreOpener: { layout in
                probe.recordFolderStoreOpen()
                return try FolderStore.open(layout: layout)
            },
            deleteFolder: deleteFolder,
            setMeetingFolders: { library, meetingIDs, folderID in
                if probe.consumeFolderAssignmentRestoreFailure() {
                    throw FolderFixtureError.restoreFailed
                }
                return try await library.setMeetingFolders(
                    meetingIDs,
                    folderID: folderID
                )
            },
            libraryURL: root
        )
    }

    func start() async {
        await app.bootstrap()
    }

    func failFolderAssignmentRestoreAfterNextOperation() {
        probe.failFolderAssignmentRestoreAfterNextOperation()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum FolderFixtureError: LocalizedError {
    case restoreFailed
    case deleteFailedBeforeCommit
    case deleteCommittedThenFailed
    case storeOpenFailed

    var errorDescription: String? {
        switch self {
        case .restoreFailed:
            "The test prevented the assignment rollback."
        case .deleteFailedBeforeCommit:
            "The test prevented the index deletion before it reached disk."
        case .deleteCommittedThenFailed:
            "The index removal reached disk before the test threw."
        case .storeOpenFailed:
            "The test prevented opening the folder index."
        }
    }
}

private final class FolderFixtureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var openedFolderStores = 0
    private var successfulFolderAssignmentOperationsBeforeFailure: Int?

    var openedFolderStoreCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openedFolderStores
    }

    func recordFolderStoreOpen() {
        lock.lock()
        openedFolderStores += 1
        lock.unlock()
    }

    func failFolderAssignmentRestoreAfterNextOperation() {
        lock.lock()
        successfulFolderAssignmentOperationsBeforeFailure = 1
        lock.unlock()
    }

    func consumeFolderAssignmentRestoreFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let remaining = successfulFolderAssignmentOperationsBeforeFailure else {
            return false
        }
        guard remaining == 0 else {
            successfulFolderAssignmentOperationsBeforeFailure = remaining - 1
            return false
        }
        successfulFolderAssignmentOperationsBeforeFailure = nil
        return true
    }
}

private actor FolderAsyncGate {
    private var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        hasEntered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !hasEntered { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FolderRaceFixture {
    typealias DeleteFolder = @Sendable (FolderStore, FolderID) async throws
        -> FolderDeletionResult?
    typealias OpenFolderStore = @Sendable (LibraryLayout) throws -> FolderStore

    let root: URL
    let r1Library: Library
    let r2Library: Library
    let app: AppModel
    let meetingID: MeetingID?
    let r2MeetingID: MeetingID?
    let folderIDs: [FolderID]
    private let probe: FolderRaceProbe

    var currentLibrary: Library {
        probe.activeRuntimeIndex == 2 ? r2Library : r1Library
    }

    var folderStoreOpenCount: Int { probe.folderStoreOpenCount }
    var runtimeMeetingLoadCount: Int { probe.runtimeMeetingLoadCount }
    var runtimeLocaleIdentifiers: [String] { probe.runtimeLocaleIdentifiers }
    var recordingStartLocales: [String] { probe.recordingStartLocales }
    var coalescedReloadScheduleCount: Int { probe.coalescedReloadScheduleCount }

    static func make(
        pauseMeetingLoadsFor: @escaping @Sendable (Library) -> Bool = { _ in false },
        meetingLoadGate: FolderAsyncGate? = nil,
        pauseMeetingFolderSet: Bool = false,
        meetingFolderSetGate: FolderAsyncGate? = nil,
        folderLoadGate: FolderAsyncGate? = nil,
        runtimeTransitionGate: FolderAsyncGate? = nil,
        runtimeTransitionStartGate: FolderAsyncGate? = nil,
        coalescedReloadGate: FolderAsyncGate? = nil,
        beforeRecordingStartGate: FolderAsyncGate? = nil,
        failPipelineAttempt: Int? = nil,
        deleteFolder: @escaping DeleteFolder = { store, folderID in
            try await store.deleteFolder(folderID)
        },
        openFolderStore: @escaping OpenFolderStore = { layout in
            try FolderStore.open(layout: layout)
        },
        failRollback: Bool = false
    ) async throws -> FolderRaceFixture {
        let fixture = try await FolderRaceFixture(
            pauseMeetingLoadsFor: pauseMeetingLoadsFor,
            meetingLoadGate: meetingLoadGate,
            pauseMeetingFolderSet: pauseMeetingFolderSet,
            meetingFolderSetGate: meetingFolderSetGate,
            folderLoadGate: folderLoadGate,
            runtimeTransitionGate: runtimeTransitionGate,
            runtimeTransitionStartGate: runtimeTransitionStartGate,
            coalescedReloadGate: coalescedReloadGate,
            beforeRecordingStartGate: beforeRecordingStartGate,
            failPipelineAttempt: failPipelineAttempt,
            deleteFolder: deleteFolder,
            openFolderStore: openFolderStore,
            failRollback: failRollback
        )
        await fixture.app.bootstrap()
        return fixture
    }

    private init(
        pauseMeetingLoadsFor: @escaping @Sendable (Library) -> Bool,
        meetingLoadGate: FolderAsyncGate?,
        pauseMeetingFolderSet: Bool,
        meetingFolderSetGate: FolderAsyncGate?,
        folderLoadGate: FolderAsyncGate?,
        runtimeTransitionGate: FolderAsyncGate?,
        runtimeTransitionStartGate: FolderAsyncGate?,
        coalescedReloadGate: FolderAsyncGate?,
        beforeRecordingStartGate: FolderAsyncGate?,
        failPipelineAttempt: Int?,
        deleteFolder: @escaping DeleteFolder,
        openFolderStore: @escaping OpenFolderStore,
        failRollback: Bool
    ) async throws {
        let probe = FolderRaceProbe(
            pauseMeetingLoadsFor: pauseMeetingLoadsFor,
            meetingLoadGate: meetingLoadGate,
            pauseMeetingFolderSet: pauseMeetingFolderSet,
            meetingFolderSetGate: meetingFolderSetGate,
            folderLoadGate: folderLoadGate,
            runtimeTransitionGate: runtimeTransitionGate,
            runtimeTransitionStartGate: runtimeTransitionStartGate,
            coalescedReloadGate: coalescedReloadGate,
            beforeRecordingStartGate: beforeRecordingStartGate,
            failPipelineAttempt: failPipelineAttempt,
            failRollback: failRollback
        )
        self.probe = probe
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-FolderRaceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let r1Root = root.appendingPathComponent("R1", isDirectory: true)
        let r2Root = root.appendingPathComponent("R2", isDirectory: true)
        try FileManager.default.createDirectory(at: r1Root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: r2Root, withIntermediateDirectories: true)
        r1Library = try Library.open(at: r1Root)
        r2Library = try Library.open(at: r2Root)
        let r1Store = try FolderStore.open(layout: r1Library.layout)
        let r2Store = try FolderStore.open(layout: r2Library.layout)
        let first = try await r1Store.createFolder(name: "R1 folder", parentFolderID: nil)
        let second = try await r1Store.createFolder(name: "R1 other", parentFolderID: nil)
        _ = try await r2Store.createFolder(name: "R2 folder", parentFolderID: nil)
        let meeting = try await r1Library.createMeeting(title: "R1 meeting", status: .ready)
        let r2Meeting = try await r2Library.createMeeting(title: "R2 meeting", status: .ready)
        meetingID = meeting.id
        r2MeetingID = r2Meeting.id
        folderIDs = [first.id, second.id]

        let r1Runtime = try Self.makeRuntime(for: r1Library)
        let r2Runtime = try Self.makeRuntime(for: r2Library)
        probe.setRuntimes([r1Runtime, r2Runtime])
        app = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { _, locale, _ in try probe.nextRuntime(locale: locale) },
            folderStoreOpener: { layout in
                probe.recordFolderStoreOpen()
                return try openFolderStore(layout)
            },
            deleteFolder: deleteFolder,
            setMeetingFolders: { library, meetingIDs, folderID in
                if probe.consumeFolderAssignmentRestoreFailure() {
                    throw FolderFixtureError.restoreFailed
                }
                let meetings = try await library.setMeetingFolders(meetingIDs, folderID: folderID)
                if probe.consumeFolderSetPauseAfterWrite(), let gate = probe.meetingFolderSetGate {
                    await gate.pause()
                }
                return meetings
            },
            beforeMeetingFolderSet: {
                if probe.consumeFolderSetPause(), let gate = probe.meetingFolderSetGate {
                    await gate.pause()
                }
            },
            beforeRuntimeTransitionDetach: {
                if let gate = probe.runtimeTransitionGate {
                    await gate.pause()
                }
            },
            afterRuntimeTransitionBarrierStarts: {
                if let gate = probe.runtimeTransitionStartGate {
                    await gate.pause()
                }
            },
            afterCoalescedFolderReload: {
                if let gate = probe.coalescedReloadGate {
                    await gate.pause()
                }
            },
            beforeRecordingStart: {
                if let gate = probe.takeRecordingStartGateIfNeeded() {
                    await gate.pause()
                }
            },
            recordingStarter: { _, locale, _ in
                probe.recordRecordingStart(locale)
            },
            didScheduleCoalescedFolderReload: {
                probe.recordCoalescedReloadSchedule()
            },
            loadMeetings: { library in
                let meetings = try await library.listMeetings()
                probe.recordMeetingLoad()
                if probe.consumeMeetingLoadPause(for: library), let gate = probe.meetingLoadGate {
                    await gate.pause()
                }
                return meetings
            },
            loadFolders: { store in
                if probe.consumeFolderLoadPauseReturningEmpty(), let gate = probe.folderLoadGate {
                    await gate.pause()
                    return []
                }
                if probe.consumeFolderLoadFailure() {
                    throw FolderFixtureError.storeOpenFailed
                }
                let folders = try await store.listFolders()
                if probe.consumeFolderLoadPauseAfterRead(), let gate = probe.folderLoadGate {
                    await gate.pause()
                }
                return folders
            },
            libraryURL: r1Root
        )
    }

    private static func makeRuntime(for library: Library) throws -> PipelineRuntime {
        let jobStore = try JobStore(layout: library.layout)
        let coordinator = PipelineCoordinator(
            library: library,
            jobStore: jobStore,
            providers: [:],
            locale: Locale(identifier: "de-DE")
        )
        return PipelineRuntime(library: library, jobStore: jobStore, coordinator: coordinator)
    }

    func pauseTheNextMeetingLoad() { probe.pauseTheNextMeetingLoad() }
    func pauseTheNextFolderLoadReturningEmpty() { probe.pauseTheNextFolderLoadReturningEmpty() }
    func pauseTheNextFolderLoadAfterRead() { probe.pauseTheNextFolderLoadAfterRead() }
    func pauseTheNextFolderSetAfterWrite() { probe.pauseTheNextFolderSetAfterWrite() }
    func failTheNextFolderLoad() { probe.failTheNextFolderLoad() }
    func failTheNextRollback() { probe.failFolderAssignmentRestoreAfterNextOperation() }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class FolderRaceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimes: [PipelineRuntime] = []
    private var nextRuntimeIndex = 0
    private var activeIndex = 0
    private let pauseMeetingLoadsFor: @Sendable (Library) -> Bool
    let meetingLoadGate: FolderAsyncGate?
    let meetingFolderSetGate: FolderAsyncGate?
    let folderLoadGate: FolderAsyncGate?
    let runtimeTransitionGate: FolderAsyncGate?
    let runtimeTransitionStartGate: FolderAsyncGate?
    let coalescedReloadGate: FolderAsyncGate?
    let beforeRecordingStartGate: FolderAsyncGate?
    private let failPipelineAttempt: Int?
    private var pauseNextMeetingLoad = false
    private var pauseNextFolderSet: Bool
    private var pauseNextFolderSetAfterWrite = false
    private var pauseNextFolderLoadReturningEmpty = false
    private var pauseNextFolderLoadAfterRead = false
    private var failNextFolderLoad = false
    private var openedFolderStores = 0
    private var loadedMeetings = 0
    private var runtimeLocales: [String] = []
    private var recordingLocales: [String] = []
    private var coalescedReloadSchedules = 0
    private var pauseNextRecordingStart: Bool
    private var successfulFolderAssignmentOperationsBeforeFailure: Int?

    init(
        pauseMeetingLoadsFor: @escaping @Sendable (Library) -> Bool,
        meetingLoadGate: FolderAsyncGate?,
        pauseMeetingFolderSet: Bool,
        meetingFolderSetGate: FolderAsyncGate?,
        folderLoadGate: FolderAsyncGate?,
        runtimeTransitionGate: FolderAsyncGate?,
        runtimeTransitionStartGate: FolderAsyncGate?,
        coalescedReloadGate: FolderAsyncGate?,
        beforeRecordingStartGate: FolderAsyncGate?,
        failPipelineAttempt: Int?,
        failRollback: Bool
    ) {
        self.pauseMeetingLoadsFor = pauseMeetingLoadsFor
        self.meetingLoadGate = meetingLoadGate
        self.meetingFolderSetGate = meetingFolderSetGate
        self.folderLoadGate = folderLoadGate
        self.runtimeTransitionGate = runtimeTransitionGate
        self.runtimeTransitionStartGate = runtimeTransitionStartGate
        self.coalescedReloadGate = coalescedReloadGate
        self.beforeRecordingStartGate = beforeRecordingStartGate
        self.failPipelineAttempt = failPipelineAttempt
        pauseNextRecordingStart = beforeRecordingStartGate != nil
        pauseNextFolderSet = pauseMeetingFolderSet
        if failRollback { successfulFolderAssignmentOperationsBeforeFailure = nil }
    }

    var activeRuntimeIndex: Int {
        lock.lock(); defer { lock.unlock() }
        return activeIndex
    }

    var folderStoreOpenCount: Int {
        lock.lock(); defer { lock.unlock() }
        return openedFolderStores
    }

    var runtimeMeetingLoadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return loadedMeetings
    }

    var runtimeLocaleIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return runtimeLocales
    }

    var recordingStartLocales: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordingLocales
    }

    var coalescedReloadScheduleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return coalescedReloadSchedules
    }

    func recordFolderStoreOpen() {
        lock.lock(); defer { lock.unlock() }
        openedFolderStores += 1
    }

    func setRuntimes(_ runtimes: [PipelineRuntime]) {
        lock.lock(); defer { lock.unlock() }
        self.runtimes = runtimes
    }

    func nextRuntime(locale: Locale) throws -> PipelineRuntime {
        lock.lock(); defer { lock.unlock() }
        let index = min(nextRuntimeIndex, runtimes.count - 1)
        nextRuntimeIndex += 1
        runtimeLocales.append(locale.identifier)
        if nextRuntimeIndex == failPipelineAttempt {
            throw FolderFixtureError.storeOpenFailed
        }
        activeIndex = index + 1
        return runtimes[index]
    }

    func recordRecordingStart(_ locale: Locale) {
        lock.lock(); defer { lock.unlock() }
        recordingLocales.append(locale.identifier)
    }

    func recordCoalescedReloadSchedule() {
        lock.lock(); defer { lock.unlock() }
        coalescedReloadSchedules += 1
    }

    func takeRecordingStartGateIfNeeded() -> FolderAsyncGate? {
        lock.lock()
        let shouldPause = pauseNextRecordingStart
        pauseNextRecordingStart = false
        let gate = beforeRecordingStartGate
        lock.unlock()
        return shouldPause ? gate : nil
    }

    func pauseTheNextMeetingLoad() {
        lock.lock(); defer { lock.unlock() }
        pauseNextMeetingLoad = true
    }

    func consumeMeetingLoadPause(for library: Library) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pauseNextMeetingLoad, pauseMeetingLoadsFor(library) else { return false }
        pauseNextMeetingLoad = false
        return true
    }

    func recordMeetingLoad() {
        lock.lock(); defer { lock.unlock() }
        loadedMeetings += 1
    }

    func consumeFolderSetPause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pauseNextFolderSet else { return false }
        pauseNextFolderSet = false
        return true
    }

    func pauseTheNextFolderSetAfterWrite() {
        lock.lock(); defer { lock.unlock() }
        pauseNextFolderSetAfterWrite = true
    }

    func consumeFolderSetPauseAfterWrite() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pauseNextFolderSetAfterWrite else { return false }
        pauseNextFolderSetAfterWrite = false
        return true
    }

    func pauseTheNextFolderLoadReturningEmpty() {
        lock.lock(); defer { lock.unlock() }
        pauseNextFolderLoadReturningEmpty = true
    }

    func consumeFolderLoadPauseReturningEmpty() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pauseNextFolderLoadReturningEmpty else { return false }
        pauseNextFolderLoadReturningEmpty = false
        return true
    }

    func pauseTheNextFolderLoadAfterRead() {
        lock.lock(); defer { lock.unlock() }
        pauseNextFolderLoadAfterRead = true
    }

    func consumeFolderLoadPauseAfterRead() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pauseNextFolderLoadAfterRead else { return false }
        pauseNextFolderLoadAfterRead = false
        return true
    }

    func failTheNextFolderLoad() {
        lock.lock(); defer { lock.unlock() }
        failNextFolderLoad = true
    }

    func consumeFolderLoadFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failNextFolderLoad else { return false }
        failNextFolderLoad = false
        return true
    }

    func failFolderAssignmentRestoreAfterNextOperation() {
        lock.lock(); defer { lock.unlock() }
        successfulFolderAssignmentOperationsBeforeFailure = 1
    }

    func consumeFolderAssignmentRestoreFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let remaining = successfulFolderAssignmentOperationsBeforeFailure else { return false }
        guard remaining == 0 else {
            successfulFolderAssignmentOperationsBeforeFailure = remaining - 1
            return false
        }
        successfulFolderAssignmentOperationsBeforeFailure = nil
        return true
    }
}
