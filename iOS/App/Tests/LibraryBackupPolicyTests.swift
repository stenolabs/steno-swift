import Darwin
import Foundation
import StenoDiarization
import StenoDomain
import StenoLibrary
import StenoPipeline
import Synchronization
import Testing
@testable import Steno

@Suite("iOS library backup policy")
struct LibraryBackupPolicyTests {
    @Test("diarization model cache is excluded from backup")
    func excludesDiarizationModelCache() throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let cache = try LibraryLocation.modelCacheURL(cachesDirectory: fixture.container)

        #expect(
            cache == fixture.container.appendingPathComponent(
                "DiarizationModels",
                isDirectory: true
            )
        )
        #expect(try isExcludedFromBackup(cache))
    }

    @Test("successful diarization install restarts idle pipeline and retries only model failures")
    @MainActor
    func diarizationInstallRetriesEligibleJobs() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let suite = "DiarizationInstall-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installer = ImmediateDiarizationInstaller()
        let diarizationState = IOSModelInstallationState(
            coordinator: ModelInstallationCoordinator(installers: [installer]),
            consent: .diarization(defaults: defaults)
        )
        let attempts = BootstrapAttemptProbe()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                attempts.recordPipelineStart()
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            diarizationModels: diarizationState,
            libraryURL: fixture.libraryRoot
        )
        await model.bootstrap()
        let runtime = try #require(model.runtime)
        let meeting = try await runtime.library.createMeeting(
            title: "Missing speaker separation",
            status: .ready
        )
        let retryable = Job(
            kind: .diarization,
            meetingID: meeting.id,
            status: .failed,
            errorMessage: "missing",
            failureReason: .diarizationModelsNotInstalled
        )
        let finalASR = Job(
            kind: .finalASR,
            meetingID: meeting.id,
            status: .failed,
            errorMessage: "speech failure"
        )
        try await runtime.jobStore.enqueue(retryable)
        try await runtime.jobStore.enqueue(finalASR)

        await model.allowAndInstallDiarizationModels()

        #expect(await installer.installCount == 1)
        #expect(diarizationState.consent.record?.sources == ["huggingface.co"])
        #expect(attempts.pipelineStarts == 2)
        let reopened = try #require(model.runtime)
        let retryableAfterInstall = try await reopened.jobStore.load(retryable.id)
        #expect(retryableAfterInstall.status == .queued)
        #expect(retryableAfterInstall.attemptCount == 0)
        #expect(retryableAfterInstall.failureReason == nil)
        #expect(try await reopened.jobStore.load(finalASR.id).status == .failed)
        #expect(model.recording.canRecord)
    }

    @Test("speaker separation install does not lock new recordings")
    @MainActor
    func diarizationInstallDoesNotLockRecordingStart() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let suite = "DiarizationRecordingLock-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installer = SuspendedDiarizationInstaller()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            diarizationModels: IOSModelInstallationState(
                coordinator: ModelInstallationCoordinator(installers: [installer]),
                consent: .diarization(defaults: defaults)
            ),
            libraryURL: fixture.libraryRoot
        )
        await model.bootstrap()
        #expect(model.recording.canRecord)

        let install = Task { await model.allowAndInstallDiarizationModels() }
        await installer.waitUntilStarted()

        #expect(model.canStartRecording)
        await installer.finish()
        await install.value
        #expect(model.canStartRecording)
    }

    @Test("new library and validation roots are excluded from backup")
    func excludesNewLibrary() throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }

        try LibraryBackupPolicy.prepareAndVerify(
            libraryRoot: fixture.libraryRoot,
            validationRoot: fixture.validationRoot
        )

        #expect(try isExcludedFromBackup(fixture.libraryRoot))
        #expect(try isExcludedFromBackup(fixture.validationRoot))

        var status = stat()
        #expect(lstat(fixture.validationRoot.path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFDIR)
        #expect(status.st_mode & 0o7777 == 0o700)
        #expect(status.st_uid == geteuid())
    }

    @Test("existing library and validation snapshots survive backup exclusion")
    func preservesExistingContent() throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.libraryRoot,
            withIntermediateDirectories: true
        )
        let recording = fixture.libraryRoot.appending(path: "recording.caf")
        let recordingBytes = Data("existing recording".utf8)
        try recordingBytes.write(to: recording)
        try createPrivateDirectory(fixture.validationRoot)
        let snapshot = fixture.validationRoot.appending(path: "snapshot.stenomeeting")
        let snapshotBytes = Data("existing snapshot".utf8)
        try snapshotBytes.write(to: snapshot)

        try LibraryBackupPolicy.prepareAndVerify(
            libraryRoot: fixture.libraryRoot,
            validationRoot: fixture.validationRoot
        )

        #expect(try Data(contentsOf: recording) == recordingBytes)
        #expect(try Data(contentsOf: snapshot) == snapshotBytes)
    }

    @Test("reopening policy preserves newly written meeting content")
    func reopensExistingLibraryWithoutMigration() throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        try LibraryBackupPolicy.prepareAndVerify(
            libraryRoot: fixture.libraryRoot,
            validationRoot: fixture.validationRoot
        )

        let meeting = fixture.libraryRoot.appending(
            path: "meetings/0198-test",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let note = meeting.appending(path: "notes/user-notes.md")
        try FileManager.default.createDirectory(
            at: note.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let noteBytes = Data("[00:00:01] Bestehende Notiz".utf8)
        try noteBytes.write(to: note)
        let snapshot = fixture.validationRoot.appending(path: "held-snapshot")
        let snapshotBytes = Data("private transfer snapshot".utf8)
        try snapshotBytes.write(to: snapshot)

        try LibraryBackupPolicy.prepareAndVerify(
            libraryRoot: fixture.libraryRoot,
            validationRoot: fixture.validationRoot
        )

        #expect(try isExcludedFromBackup(fixture.libraryRoot))
        #expect(try isExcludedFromBackup(fixture.validationRoot))
        #expect(try Data(contentsOf: note) == noteBytes)
        #expect(try Data(contentsOf: snapshot) == snapshotBytes)
    }

    @Test("validation root symlinks fail closed")
    func rejectsValidationRootSymlink() throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let target = fixture.container.appending(path: "symlink-target", directoryHint: .isDirectory)
        try createPrivateDirectory(target)
        try FileManager.default.createSymbolicLink(
            at: fixture.validationRoot,
            withDestinationURL: target
        )

        #expect(
            throws: LibraryBackupPolicyError.privateValidationRootRejected(
                fixture.validationRoot
            )
        ) {
            try LibraryBackupPolicy.prepareAndVerify(
                libraryRoot: fixture.libraryRoot,
                validationRoot: fixture.validationRoot
            )
        }
    }

    @Test(
        "group or world accessible validation roots fail closed",
        arguments: [mode_t(0o750), mode_t(0o701)]
    )
    func rejectsAccessibleValidationRoot(mode: mode_t) throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.validationRoot,
            withIntermediateDirectories: false
        )
        #expect(chmod(fixture.validationRoot.path, mode) == 0)

        #expect(
            throws: LibraryBackupPolicyError.privateValidationRootRejected(
                fixture.validationRoot
            )
        ) {
            try LibraryBackupPolicy.prepareAndVerify(
                libraryRoot: fixture.libraryRoot,
                validationRoot: fixture.validationRoot
            )
        }
    }

    @Test("validation roots with special permission bits fail closed")
    func rejectsSpecialPermissionBits() throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.validationRoot,
            withIntermediateDirectories: false
        )
        #expect(chmod(fixture.validationRoot.path, 0o1700) == 0)

        #expect(
            throws: LibraryBackupPolicyError.privateValidationRootRejected(
                fixture.validationRoot
            )
        ) {
            try LibraryBackupPolicy.prepareAndVerify(
                libraryRoot: fixture.libraryRoot,
                validationRoot: fixture.validationRoot
            )
        }
    }

    @Test("backup policy failure is shown and prevents pipeline start")
    @MainActor
    func bootstrapStopsBeforePipeline() async {
        let pipelineProbe = PipelineStartProbe()
        let model = AppModel(
            prepareLibraryBackup: { _, _ in throw BootstrapPolicyFailure.rejected },
            startPipeline: { _, _, _ in
                await pipelineProbe.started()
                throw BootstrapPolicyFailure.pipelineMustNotStart
            }
        )

        await model.bootstrap()

        #expect(
            model.startupState
                == .failed(.libraryProtection(BootstrapPolicyFailure.rejected.localizedDescription))
        )
        #expect(model.startupFailure == BootstrapPolicyFailure.rejected.localizedDescription)
        #expect(!model.isReady)
        #expect(await pipelineProbe.startCount == 0)
    }

    @Test("failed restart invalidates the previously attached recording runtime")
    @MainActor
    func failedRestartInvalidatesOldRuntime() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let attempts = BootstrapAttemptProbe()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                let attempt = attempts.recordPolicyAttempt()
                if attempt == 2 {
                    throw BootstrapPolicyFailure.rejected
                }
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                attempts.recordPipelineStart()
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            }
        )

        await model.bootstrap()

        #expect(model.isReady)
        #expect(model.recording.canRecord)
        #expect(model.startupFailure == nil)
        #expect(attempts.pipelineStarts == 1)

        await model.restartPipelineAfterConfigurationChange()

        #expect(!model.isReady)
        #expect(!model.recording.canRecord)
        #expect(model.startupFailure == BootstrapPolicyFailure.rejected.localizedDescription)
        #expect(attempts.policyAttempts == 2)
        #expect(attempts.pipelineStarts == 1)
    }

    @Test("overlapping bootstraps share one attempt and a failure permits retry")
    @MainActor
    func overlappingBootstrapsCoalesceAndReleaseAfterFailure() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let attempts = BootstrapAttemptProbe()
        let pipelineGate = AsyncGate()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                attempts.recordPolicyAttempt()
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                let attempt = attempts.recordPipelineStart()
                if attempt == 1 {
                    await pipelineGate.suspend()
                    throw BootstrapPolicyFailure.rejected
                }
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            }
        )

        let first = Task { @MainActor in
            await model.bootstrap()
            return model.startupFailure
        }
        await pipelineGate.waitUntilSuspended()

        let secondEntered = MainActorFlag()
        let second = Task { @MainActor in
            secondEntered.value = true
            await model.bootstrap()
            return model.startupFailure
        }
        while !secondEntered.value {
            await Task.yield()
        }

        await pipelineGate.release()
        let firstFailure = await first.value
        let secondFailure = await second.value

        #expect(firstFailure == BootstrapPolicyFailure.rejected.localizedDescription)
        #expect(secondFailure == firstFailure)
        #expect(attempts.policyAttempts == 1)
        #expect(attempts.pipelineStarts == 1)
        #expect(!model.isReady)
        #expect(!model.recording.canRecord)

        let retry = Task { @MainActor in
            await model.retryStartup()
        }
        while attempts.pipelineStarts < 2 {
            await Task.yield()
        }
        #expect(model.startupState == .opening)
        await retry.value

        #expect(attempts.policyAttempts == 2)
        #expect(attempts.pipelineStarts == 2)
        #expect(model.isReady)
        #expect(model.recording.canRecord)
        #expect(model.startupFailure == nil)
    }

    @Test("fatal startup failure remains visible until retry starts")
    @MainActor
    func fatalFailureRemainsUntilRetryStarts() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let attempts = BootstrapAttemptProbe()
        let retryGate = AsyncGate()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                let attempt = attempts.recordPipelineStart()
                if attempt == 1 {
                    throw BootstrapPolicyFailure.rejected
                }
                await retryGate.suspend()
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            libraryURL: fixture.libraryRoot
        )

        #expect(model.startupState == .opening)
        await model.bootstrap()
        let failure = IOSStartupFailure.runtimeOpening(
            BootstrapPolicyFailure.rejected.localizedDescription
        )
        #expect(model.startupState == .failed(failure))

        let retry = Task { @MainActor in await model.retryStartup() }
        await retryGate.waitUntilSuspended()

        #expect(model.startupState == .opening)
        #expect(model.startupFailure == nil)
        #expect(attempts.pipelineStarts == 2)

        await retryGate.release()
        await retry.value

        #expect(model.startupState == .ready)
        #expect(model.recording.canRecord)
    }

    @Test("overlapping fatal retries join one replacement attempt")
    @MainActor
    func overlappingFatalRetriesJoin() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let attempts = BootstrapAttemptProbe()
        let retryGate = AsyncGate()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                let attempt = attempts.recordPipelineStart()
                if attempt == 1 {
                    throw BootstrapPolicyFailure.rejected
                }
                await retryGate.suspend()
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            libraryURL: fixture.libraryRoot
        )
        await model.bootstrap()

        let first = Task { @MainActor in await model.retryStartup() }
        await retryGate.waitUntilSuspended()
        let second = Task { @MainActor in await model.retryStartup() }
        await Task.yield()

        #expect(attempts.pipelineStarts == 2)
        await retryGate.release()
        await first.value
        await second.value

        #expect(attempts.pipelineStarts == 2)
        #expect(model.startupState == .ready)
    }

    @Test("fatal replacement keeps old warnings until a new runtime is ready")
    @MainActor
    func fatalReplacementKeepsWarningsUntilReady() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let backupAttempts = CounterProbe()
        let attempts = BootstrapAttemptProbe()
        let replacementGate = AsyncGate()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                if backupAttempts.increment() == 2 {
                    throw BootstrapPolicyFailure.rejected
                }
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                let attempt = attempts.recordPipelineStart()
                if attempt == 2 {
                    throw BootstrapPolicyFailure.rejected
                }
                if attempt == 3 {
                    await replacementGate.suspend()
                }
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            libraryURL: fixture.libraryRoot
        )
        await model.bootstrap()
        let retainedWarnings: [IOSStartupWarning] = [
            .captureRecovery("capture"),
            .pipeline("pipeline"),
            .missingModelRequeue("model"),
        ]
        for warning in retainedWarnings {
            model.reportStartupWarning(warning)
        }
        model.reportActionNotice(.draftCreation("draft"))

        await model.restartPipelineAfterConfigurationChange()

        #expect(
            model.startupState
                == .failed(.libraryProtection(BootstrapPolicyFailure.rejected.localizedDescription))
        )
        #expect(model.startupWarnings == retainedWarnings)
        #expect(model.actionNotice == .draftCreation("draft"))

        await model.retryStartup()

        #expect(
            model.startupState
                == .failed(.runtimeOpening(BootstrapPolicyFailure.rejected.localizedDescription))
        )
        #expect(model.startupWarnings == retainedWarnings)
        #expect(model.actionNotice == .draftCreation("draft"))

        let retry = Task { @MainActor in await model.retryStartup() }
        await replacementGate.waitUntilSuspended()

        #expect(model.startupState == .opening)
        #expect(model.startupWarnings == retainedWarnings)
        #expect(model.actionNotice == .draftCreation("draft"))

        await replacementGate.release()
        await retry.value

        #expect(model.startupState == .ready)
        #expect(model.startupWarnings == [.missingModelRequeue("model")])
        #expect(model.actionNotice == .draftCreation("draft"))
    }

    @Test("meeting issue retry reloads only meetings and preserves recording")
    @MainActor
    func meetingIssueRetryIsTargeted() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let pipelineAttempts = BootstrapAttemptProbe()
        let lists = LibraryListProbe(failFirstMeetingLoad: true)
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                pipelineAttempts.recordPipelineStart()
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            loadMeetings: { _ in try lists.loadMeetings() },
            loadFolders: { _ in try lists.loadFolders() },
            libraryURL: fixture.libraryRoot
        )

        await model.bootstrap()

        #expect(model.startupState == .ready)
        #expect(model.libraryIssue == .meetings("The meeting list could not be loaded."))
        #expect(model.recording.canRecord)
        #expect(lists.meetingLoads == 1)
        #expect(lists.folderLoads == 0)

        await model.retryLibraryIssue()

        #expect(model.libraryIssue == nil)
        #expect(model.startupState == .ready)
        #expect(model.recording.canRecord)
        #expect(pipelineAttempts.pipelineStarts == 1)
        #expect(lists.meetingLoads == 2)
        #expect(lists.folderLoads == 0)
    }

    @Test("folder issue retry reopens and reloads only folders")
    @MainActor
    func folderIssueRetryIsTargeted() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let pipelineAttempts = BootstrapAttemptProbe()
        let lists = LibraryListProbe(failFirstFolderLoad: true)
        let folderOpens = CounterProbe()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                pipelineAttempts.recordPipelineStart()
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            folderStoreOpener: { layout in
                folderOpens.increment()
                return try FolderStore.open(layout: layout)
            },
            loadMeetings: { _ in try lists.loadMeetings() },
            loadFolders: { _ in try lists.loadFolders() },
            libraryURL: fixture.libraryRoot
        )

        await model.bootstrap()

        let folderFailureDetail = "The folder list could not be loaded."
        let folderFailure = String(localized:
            "The folders could not be loaded. (\(folderFailureDetail))"
        )
        #expect(model.startupState == .ready)
        #expect(
            model.libraryIssue
                == .folders(folderFailure)
        )
        #expect(model.recording.canRecord)
        #expect(lists.meetingLoads == 1)
        #expect(lists.folderLoads == 1)
        #expect(folderOpens.value == 1)

        await model.retryLibraryIssue()

        #expect(model.libraryIssue == nil)
        #expect(model.recording.canRecord)
        #expect(pipelineAttempts.pipelineStarts == 1)
        #expect(lists.meetingLoads == 1)
        #expect(lists.folderLoads == 2)
        #expect(folderOpens.value == 2)
    }

    @Test("meeting and folder issues survive and retry independently")
    @MainActor
    func libraryIssuesAreIndependent() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let lists = LibraryListProbe(
            failingMeetingLoads: [2],
            failingFolderLoads: [1]
        )
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            loadMeetings: { _ in try lists.loadMeetings() },
            loadFolders: { _ in try lists.loadFolders() },
            libraryURL: fixture.libraryRoot
        )
        let meetingIssue = IOSLibraryIssue.meetings(
            "The meeting list could not be loaded."
        )
        let folderFailureDetail = "The folder list could not be loaded."
        let folderIssue = IOSLibraryIssue.folders(String(localized:
            "The folders could not be loaded. (\(folderFailureDetail))"
        ))
        await model.bootstrap()
        model.reportStartupWarning(.missingModelRequeue("model"))
        model.reportActionNotice(.draftCreation("draft"))

        #expect(model.libraryIssues == [folderIssue])

        await model.reloadMeetings()

        #expect(model.libraryIssues == [meetingIssue, folderIssue])
        #expect(lists.meetingLoads == 2)
        #expect(lists.folderLoads == 1)

        await model.retryLibraryIssue(meetingIssue)

        #expect(model.libraryIssues == [folderIssue])
        #expect(lists.meetingLoads == 3)
        #expect(lists.folderLoads == 1)
        #expect(model.recording.canRecord)
        #expect(model.startupWarnings == [.missingModelRequeue("model")])
        #expect(model.actionNotice == .draftCreation("draft"))
    }

    @Test("an older meeting retry cannot overwrite a newer meeting reload")
    @MainActor
    func staleMeetingRetryCannotPublish() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let gate = AsyncGate()
        let loads = CounterProbe()
        let staleMeeting = Meeting(title: "Stale", status: .ready)
        let freshMeeting = Meeting(title: "Fresh", status: .ready)
        let issue = IOSLibraryIssue.meetings("Meetings unavailable")
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            meetingListLoader: {
                let load = loads.increment()
                if load == 1 {
                    await gate.suspend()
                    return [staleMeeting]
                }
                return [freshMeeting]
            },
            libraryURL: fixture.libraryRoot
        )
        await model.bootstrap()
        model.reportLibraryIssue(issue)
        model.reportStartupWarning(.missingModelRequeue("model"))
        model.reportActionNotice(.draftCreation("draft"))

        let retry = Task { @MainActor in
            await model.retryLibraryIssue(issue)
        }
        await gate.waitUntilSuspended()
        await model.reloadMeetings()

        #expect(model.meetings == [freshMeeting])
        #expect(model.libraryIssues.isEmpty)

        await gate.release()
        await retry.value

        #expect(model.meetings == [freshMeeting])
        #expect(model.libraryIssues.isEmpty)
        #expect(model.startupWarnings == [.missingModelRequeue("model")])
        #expect(model.actionNotice == .draftCreation("draft"))
    }

    @Test("an older folder retry cannot restore its error after a newer reload")
    @MainActor
    func staleFolderRetryCannotPublishError() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let gate = AsyncGate()
        let loads = CounterProbe()
        let baselineFolder = Folder(name: "Baseline", sortIndex: 0)
        let freshFolder = Folder(name: "Fresh", sortIndex: 0)
        let issue = IOSLibraryIssue.folders("Folders unavailable")
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            loadFolders: { _ in
                let load = loads.increment()
                switch load {
                case 1:
                    return [baselineFolder]
                case 2:
                    await gate.suspend()
                    throw LibraryListProbeError.folders
                default:
                    return [freshFolder]
                }
            },
            libraryURL: fixture.libraryRoot
        )
        await model.bootstrap()
        model.reportLibraryIssue(issue)
        model.reportStartupWarning(.missingModelRequeue("model"))
        model.reportActionNotice(.draftCreation("draft"))

        let retry = Task { @MainActor in
            await model.retryLibraryIssue(issue)
        }
        await gate.waitUntilSuspended()
        await model.reloadMeetings()

        #expect(model.folders == [freshFolder])
        #expect(model.libraryIssues.isEmpty)

        await gate.release()
        await retry.value

        #expect(model.folders == [freshFolder])
        #expect(model.libraryIssues.isEmpty)
        #expect(model.startupWarnings == [.missingModelRequeue("model")])
        #expect(model.actionNotice == .draftCreation("draft"))
    }

    @Test("a newer folder retry publishes before an older stale reload is coalesced")
    @MainActor
    func newerFolderRetryPublishesBeforeCoalescedReload() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let library = try Library.open(at: fixture.libraryRoot)
        let store = try FolderStore.open(layout: library.layout)
        let recoveredFolder = try await store.createFolder(
            name: "Recovered",
            parentFolderID: nil
        )
        let oldReloadGate = AsyncGate()
        let folderRetryGate = AsyncGate()
        let coalescedReloadGate = AsyncGate()
        let meetingLoads = CounterProbe()
        let folderLoads = CounterProbe()
        let folderOpens = CounterProbe()
        let coalescedSchedules = CounterProbe()
        let model = AppModel(
            prepareLibraryBackup: { _, _ in },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                try makePipelineRuntime(at: libraryRoot, locale: locale)
            },
            folderStoreOpener: { layout in
                if folderOpens.increment() == 1 {
                    throw LibraryListProbeError.folders
                }
                return try FolderStore.open(layout: layout)
            },
            afterCoalescedFolderReload: {
                await coalescedReloadGate.suspend()
            },
            didScheduleCoalescedFolderReload: {
                coalescedSchedules.increment()
            },
            loadMeetings: { library in
                let load = meetingLoads.increment()
                let meetings = try await library.listMeetings()
                if load == 2 {
                    await oldReloadGate.suspend()
                }
                return meetings
            },
            loadFolders: { store in
                let load = folderLoads.increment()
                let folders = try await store.listFolders()
                if load == 1 {
                    await folderRetryGate.suspend()
                }
                return folders
            },
            libraryURL: fixture.libraryRoot
        )
        await model.bootstrap()
        let folderIssue = try #require(
            model.libraryIssues.first { $0.id == .folders }
        )

        let oldReload = Task { @MainActor in await model.reloadMeetings() }
        await oldReloadGate.waitUntilSuspended()
        let retry = Task { @MainActor in
            await model.retryLibraryIssue(folderIssue)
        }
        await folderRetryGate.waitUntilSuspended()

        await oldReloadGate.release()
        await oldReload.value
        await folderRetryGate.release()
        await retry.value
        await coalescedReloadGate.waitUntilSuspended()

        #expect(model.folders == [recoveredFolder])
        #expect(!model.libraryIssues.contains { $0.id == .folders })
        #expect(folderOpens.value == 2)
        #expect(folderLoads.value == 2)
        #expect(coalescedSchedules.value == 1)
        #expect(model.recording.canRecord)

        await coalescedReloadGate.release()
    }

    @Test("language changes are rejected while bootstrap is in flight and work afterward")
    @MainActor
    func languageChangeDoesNotRaceInFlightBootstrap() async throws {
        let fixture = try BackupPolicyFixture()
        defer { fixture.cleanUp() }
        let defaults = UserDefaults.standard
        let languageKey = "steno.transcription.language"
        let explicitChoiceKey = "steno.transcription.language.chosen"
        let savedLanguage = defaults.object(forKey: languageKey)
        let savedExplicitChoice = defaults.object(forKey: explicitChoiceKey)
        defer {
            restoreDefault(savedLanguage, forKey: languageKey)
            restoreDefault(savedExplicitChoice, forKey: explicitChoiceKey)
        }

        let pipelineGate = AsyncGate()
        let pipelineProbe = BootstrapLocaleProbe()
        let model = AppModel(
            prepareLibraryBackup: { libraryRoot, _ in
                try FileManager.default.createDirectory(
                    at: libraryRoot,
                    withIntermediateDirectories: true
                )
            },
            refreshLanguage: { _ in },
            startPipeline: { libraryRoot, locale, _ in
                let attempt = pipelineProbe.record(locale: locale)
                if attempt == 1 {
                    await pipelineGate.suspend()
                }
                return try makePipelineRuntime(at: libraryRoot, locale: locale)
            }
        )
        let originalID = model.language.selectedID
        let originalLocaleID = model.language.locale.identifier
        let wasOriginallyExplicit = model.language.wasChosenExplicitly
        let requestedID = originalID.caseInsensitiveCompare("de-DE") == .orderedSame
            ? "en-US"
            : "de-DE"

        let bootstrap = Task { @MainActor in
            await model.bootstrap()
        }
        await pipelineGate.waitUntilSuspended()

        #expect(!model.canChangeLanguage)
        let changeCompleted = MainActorFlag()
        let attemptedChange = Task { @MainActor in
            await model.setLanguage(requestedID)
            changeCompleted.value = true
        }
        let firstOutcome = await waitForLanguageAttempt(
            model: model,
            originalID: originalID,
            wasOriginallyExplicit: wasOriginallyExplicit,
            completion: changeCompleted
        )

        #expect(firstOutcome == .completedWithoutMutation)
        #expect(model.language.selectedID == originalID)
        #expect(model.language.wasChosenExplicitly == wasOriginallyExplicit)
        #expect(defaults.object(forKey: languageKey) as? String == savedLanguage as? String)
        #expect(
            defaults.object(forKey: explicitChoiceKey) as? Bool
                == savedExplicitChoice as? Bool
        )

        await pipelineGate.release()
        await bootstrap.value
        await attemptedChange.value

        #expect(model.isReady)
        #expect(model.startupFailure == nil)
        #expect(model.recording.canRecord)
        #expect(pipelineProbe.localeIdentifiers == [originalLocaleID])

        await model.setLanguage(requestedID)

        #expect(model.language.selectedID == requestedID)
        #expect(model.language.wasChosenExplicitly)
        #expect(model.isReady)
        #expect(model.startupFailure == nil)
        #expect(model.recording.canRecord)
        #expect(pipelineProbe.localeIdentifiers.count == 2)
        #expect(pipelineProbe.localeIdentifiers.last == Locale(identifier: requestedID).identifier)
    }
}

private func isExcludedFromBackup(_ url: URL) throws -> Bool {
    try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
}

private func createPrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    guard chmod(url.path, 0o700) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private struct BackupPolicyFixture {
    let container: URL
    let libraryRoot: URL
    let validationRoot: URL

    init() throws {
        container = FileManager.default.temporaryDirectory.appending(
            path: "Steno-LibraryBackupPolicyTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        libraryRoot = container.appending(path: "StenoLibrary", directoryHint: .isDirectory)
        validationRoot = LibraryLayout(root: libraryRoot).transferValidationRoot
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: container)
    }
}

private actor PipelineStartProbe {
    private(set) var startCount = 0

    func started() {
        startCount += 1
    }
}

private final class BootstrapAttemptProbe: Sendable {
    private struct State: Sendable {
        var policyAttempts = 0
        var pipelineStarts = 0
    }

    private let state = Mutex(State())

    @discardableResult
    func recordPolicyAttempt() -> Int {
        state.withLock {
            $0.policyAttempts += 1
            return $0.policyAttempts
        }
    }

    @discardableResult
    func recordPipelineStart() -> Int {
        state.withLock {
            $0.pipelineStarts += 1
            return $0.pipelineStarts
        }
    }

    var policyAttempts: Int {
        state.withLock { $0.policyAttempts }
    }

    var pipelineStarts: Int {
        state.withLock { $0.pipelineStarts }
    }
}

private final class CounterProbe: Sendable {
    private let count = Mutex(0)

    @discardableResult
    func increment() -> Int {
        count.withLock {
            $0 += 1
            return $0
        }
    }

    var value: Int { count.withLock { $0 } }
}

private final class LibraryListProbe: Sendable {
    private struct State: Sendable {
        var meetingLoads = 0
        var folderLoads = 0
        var failingMeetingLoads: Set<Int>
        var failingFolderLoads: Set<Int>
    }

    private let state: Mutex<State>

    convenience init(
        failFirstMeetingLoad: Bool = false,
        failFirstFolderLoad: Bool = false
    ) {
        self.init(
            failingMeetingLoads: failFirstMeetingLoad ? [1] : [],
            failingFolderLoads: failFirstFolderLoad ? [1] : []
        )
    }

    init(
        failingMeetingLoads: Set<Int>,
        failingFolderLoads: Set<Int>
    ) {
        state = Mutex(State(
            failingMeetingLoads: failingMeetingLoads,
            failingFolderLoads: failingFolderLoads
        ))
    }

    func loadMeetings() throws -> [Meeting] {
        try state.withLock {
            $0.meetingLoads += 1
            if $0.failingMeetingLoads.contains($0.meetingLoads) {
                throw LibraryListProbeError.meetings
            }
            return []
        }
    }

    func loadFolders() throws -> [Folder] {
        try state.withLock {
            $0.folderLoads += 1
            if $0.failingFolderLoads.contains($0.folderLoads) {
                throw LibraryListProbeError.folders
            }
            return []
        }
    }

    var meetingLoads: Int { state.withLock { $0.meetingLoads } }
    var folderLoads: Int { state.withLock { $0.folderLoads } }
}

private enum LibraryListProbeError: LocalizedError {
    case meetings
    case folders

    var errorDescription: String? {
        switch self {
        case .meetings:
            "The meeting list could not be loaded."
        case .folders:
            "The folder list could not be loaded."
        }
    }
}

private final class BootstrapLocaleProbe: Sendable {
    private let locales = Mutex<[String]>([])

    @discardableResult
    func record(locale: Locale) -> Int {
        locales.withLock {
            $0.append(locale.identifier)
            return $0.count
        }
    }

    var localeIdentifiers: [String] {
        locales.withLock { $0 }
    }
}

private actor AsyncGate {
    private var isSuspended = false
    private var suspension: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            suspension = continuation
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        suspension?.resume()
        suspension = nil
    }
}

@MainActor
private final class MainActorFlag {
    var value = false
}

private enum LanguageAttemptOutcome: Equatable {
    case completedWithoutMutation
    case mutatedBeforeCompletion
}

@MainActor
private func waitForLanguageAttempt(
    model: AppModel,
    originalID: String,
    wasOriginallyExplicit: Bool,
    completion: MainActorFlag
) async -> LanguageAttemptOutcome {
    while true {
        if model.language.selectedID != originalID
            || model.language.wasChosenExplicitly != wasOriginallyExplicit {
            return .mutatedBeforeCompletion
        }
        if completion.value {
            return .completedWithoutMutation
        }
        await Task.yield()
    }
}

private func restoreDefault(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private func makePipelineRuntime(at root: URL, locale: Locale) throws -> PipelineRuntime {
    let library = try Library.open(at: root)
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

private enum BootstrapPolicyFailure: LocalizedError {
    case rejected
    case pipelineMustNotStart

    var errorDescription: String? {
        switch self {
        case .rejected:
            "Steno could not verify that the library is excluded from device backup."
        case .pipelineMustNotStart:
            "The pipeline started before the backup policy passed."
        }
    }
}

private actor ImmediateDiarizationInstaller: ModelInstalling {
    nonisolated let bundleDescription = ModelBundleDescription(
        title: "Speaker separation",
        source: .huggingFace,
        approximateBytes: 509_902_848
    )
    private(set) var installCount = 0
    private var installed = false

    func readiness(for locales: [Locale]) -> ModelReadiness {
        if installed {
            return ModelReadiness(installed: Set(locales), missing: [:])
        }
        return ModelReadiness(
            installed: [],
            missing: Dictionary(uniqueKeysWithValues: locales.map {
                ($0, [bundleDescription.title])
            })
        )
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) {
        installCount += 1
        progress(ModelInstallProgress(fraction: 1, title: bundleDescription.title))
        installed = true
    }

    func cancelInstall() {}
}

private actor SuspendedDiarizationInstaller: ModelInstalling {
    nonisolated let bundleDescription = DiarizationModelInstaller.expectedBundleDescription
    private var installed = false
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func readiness(for locales: [Locale]) -> ModelReadiness {
        guard installed else {
            return ModelReadiness(
                installed: [],
                missing: Dictionary(uniqueKeysWithValues: locales.map {
                    ($0, [bundleDescription.title])
                })
            )
        }
        return ModelReadiness(installed: Set(locales), missing: [:])
    }

    func install(
        for locale: Locale,
        progress: @Sendable @escaping (ModelInstallProgress) -> Void
    ) async {
        started = true
        progress(ModelInstallProgress(fraction: 0.5, title: bundleDescription.title))
        await withCheckedContinuation { continuation = $0 }
        installed = true
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }

    func cancelInstall() {
        finish()
    }
}
