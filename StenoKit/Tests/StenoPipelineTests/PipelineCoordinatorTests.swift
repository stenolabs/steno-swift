import Foundation
import StenoDomain
@testable import StenoLibrary
@testable import StenoPipeline
import StenoTranscription
import Synchronization
import Testing

@Suite("Final ASR pipeline")
struct PipelineCoordinatorTests {
    @Test("a clone cleanup failure is visible and retried by the next startup")
    func cloneCleanupFailureIsVisibleAndRetryable() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let failFirstRemoval = Mutex(true)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE"),
                importedStateCheckpoint: { _ in },
                mediaCleanupCheckpoint: { checkpoint in
                    guard case .beforeRemoveSession = checkpoint,
                          failFirstRemoval.withLock({ value in
                              defer { value = false }
                              return value
                          }) else { return }
                    throw PipelineCleanupTestError.injected
                }
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let failed = try await fixture.jobStore.load(fixture.job.id)
            #expect(failed.status == .failed)
            #expect(failed.errorMessage?.contains("cleanup") == true)
            #expect(try pipelineSnapshotSessions(library: fixture.library).count == 1)
            await coordinator.stop()

            let restarted = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "de-DE")
            )
            await restarted.start()
            try await restarted.waitUntilIdle()

            #expect(try pipelineSnapshotSessions(library: fixture.library).isEmpty)
            #expect(try await fixture.jobStore.load(fixture.job.id).status == .failed)
            await restarted.stop()
        }
    }

    @Test("cleanup remains retryable after the clone directory was removed")
    func cloneCleanupAfterDirectoryRemovalIsRetryable() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let failAfterDirectoryRemoval = Mutex(true)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE"),
                importedStateCheckpoint: { _ in },
                mediaCleanupCheckpoint: { checkpoint in
                    guard case .afterRemoveSession = checkpoint,
                          failAfterDirectoryRemoval.withLock({ value in
                              defer { value = false }
                              return value
                          }) else { return }
                    throw PipelineCleanupTestError.injected
                }
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(try await fixture.jobStore.load(fixture.job.id).status == .failed)
            #expect(try pipelineSnapshotSessions(library: fixture.library).isEmpty)
            #expect(try pipelineSnapshotOwnerTokens(library: fixture.library).count == 1)
            await coordinator.stop()

            let restarted = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "de-DE")
            )
            await restarted.start()
            try await restarted.waitUntilIdle()

            #expect(try pipelineSnapshotOwnerTokens(library: fixture.library).isEmpty)
            #expect(try await fixture.jobStore.load(fixture.job.id).status == .failed)
            await restarted.stop()
        }
    }

    @Test("startup removes a proven orphan clone session left by process termination")
    func startupSweepsProvenHardCrashClone() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Crash", status: .ready)
            let source = root.appending(path: "crash-source.caf")
            try Data("crash-audio".utf8).write(to: source)
            let asset = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 48_000,
                duration: 1
            )
            var binding: PipelineMediaBinding? = try LibraryMutationCoordination
                .withExclusiveTransaction(layout: library.layout) { transaction in
                    try PipelineMediaBinder.bind(
                        assets: [asset],
                        meetingID: meeting.id,
                        layout: library.layout,
                        transaction: transaction
                    )
                }
            let cloneURL = try #require(binding?.inputs.first?.lease.sourceURL)
            let sessionURL = cloneURL.deletingLastPathComponent()
            let markerURL = sessionURL.appending(path: ".owner-token.json")
            let ownerTokenURL = sessionURL.deletingLastPathComponent().appending(
                path: ".owner-\(try #require(binding?.sessionID).uuidString.lowercased()).json"
            )
            var sourceStatus = stat()
            var cloneStatus = stat()
            var sessionStatus = stat()
            var markerStatus = stat()
            var ownerTokenStatus = stat()
            #expect(lstat(
                library.layout.mediaFile(meeting.id, fileName: asset.fileName).path,
                &sourceStatus
            ) == 0)
            #expect(lstat(cloneURL.path, &cloneStatus) == 0)
            #expect(lstat(sessionURL.path, &sessionStatus) == 0)
            #expect(lstat(markerURL.path, &markerStatus) == 0)
            #expect(lstat(ownerTokenURL.path, &ownerTokenStatus) == 0)
            #expect(cloneStatus.st_dev == sourceStatus.st_dev)
            #expect(cloneStatus.st_ino != sourceStatus.st_ino)
            #expect(cloneStatus.st_nlink == 1)
            #expect(cloneStatus.st_mode & 0o777 == 0o400)
            #expect(sessionStatus.st_mode & 0o777 == 0o700)
            #expect(markerStatus.st_mode & 0o777 == 0o600)
            #expect(ownerTokenStatus.st_mode & 0o777 == 0o600)
            #expect(try sessionURL.deletingLastPathComponent().resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup == true)

            binding = nil
            #expect(FileManager.default.fileExists(atPath: sessionURL.path))

            let failedSweep = PipelineCoordinator(
                library: library,
                jobStore: try JobStore(layout: library.layout),
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "de-DE"),
                importedStateCheckpoint: { _ in },
                mediaCleanupCheckpoint: { checkpoint in
                    guard case .beforeRemoveSession = checkpoint else { return }
                    throw PipelineCleanupTestError.injected
                }
            )
            await failedSweep.start()
            await #expect(throws: PipelineError.self) {
                try await failedSweep.waitUntilIdle()
            }
            #expect(FileManager.default.fileExists(atPath: sessionURL.path))
            #expect(FileManager.default.fileExists(atPath: ownerTokenURL.path))
            await failedSweep.stop()

            let coordinator = PipelineCoordinator(
                library: library,
                jobStore: try JobStore(layout: library.layout),
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "de-DE")
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
            #expect(!FileManager.default.fileExists(atPath: ownerTokenURL.path))
            await coordinator.stop()
        }
    }

    @Test("startup preserves active, foreign, symlink, and lookalike media sessions")
    func startupSweepPreservesUnprovenSessions() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Active", status: .ready)
            let source = root.appending(path: "active-source.caf")
            try Data("active-audio".utf8).write(to: source)
            let asset = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 48_000,
                duration: 1
            )
            let binding = try LibraryMutationCoordination.withExclusiveTransaction(
                layout: library.layout
            ) { transaction in
                try PipelineMediaBinder.bind(
                    assets: [asset],
                    meetingID: meeting.id,
                    layout: library.layout,
                    transaction: transaction
                )
            }
            let activeSession = try #require(binding.inputs.first?.lease.sourceURL)
                .deletingLastPathComponent()
            let inputRoot = activeSession.deletingLastPathComponent()
            let foreign = inputRoot.appending(path: UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(
                at: foreign,
                withIntermediateDirectories: false
            )
            try Data("not-owned".utf8).write(
                to: foreign.appending(path: ".owner-token.json")
            )
            let lookalike = inputRoot.appending(path: "not-a-session")
            try FileManager.default.createDirectory(
                at: lookalike,
                withIntermediateDirectories: false
            )
            let symlink = inputRoot.appending(path: UUID().uuidString.lowercased())
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: foreign)
            let foreignOwnerToken = inputRoot.appending(
                path: ".owner-\(UUID().uuidString.lowercased()).json"
            )
            try Data("not-owned".utf8).write(to: foreignOwnerToken)
            let symlinkOwnerToken = inputRoot.appending(
                path: ".owner-\(UUID().uuidString.lowercased()).json"
            )
            try FileManager.default.createSymbolicLink(
                at: symlinkOwnerToken,
                withDestinationURL: foreignOwnerToken
            )

            let coordinator = PipelineCoordinator(
                library: library,
                jobStore: try JobStore(layout: library.layout),
                providers: [:],
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "de-DE")
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(FileManager.default.fileExists(atPath: activeSession.path))
            #expect(FileManager.default.fileExists(atPath: foreign.path))
            #expect(FileManager.default.fileExists(atPath: lookalike.path))
            #expect(FileManager.default.fileExists(atPath: foreignOwnerToken.path))
            var symlinkStatus = stat()
            #expect(lstat(symlink.path, &symlinkStatus) == 0)
            #expect(symlinkStatus.st_mode & S_IFMT == S_IFLNK)
            var tokenSymlinkStatus = stat()
            #expect(lstat(symlinkOwnerToken.path, &tokenSymlinkStatus) == 0)
            #expect(tokenSymlinkStatus.st_mode & S_IFMT == S_IFLNK)
            try binding.close()
            await coordinator.stop()
        }
    }

    @Test("a filesystem without COW cloning fails closed without a copy fallback")
    func unavailableCloneFailsClosed() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "No clone", status: .ready)
            let source = root.appending(path: "no-clone.caf")
            try Data("immutable-original".utf8).write(to: source)
            let asset = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 48_000,
                duration: 1
            )
            let originalURL = library.layout.mediaFile(
                meeting.id,
                fileName: asset.fileName
            )
            let originalBytes = try Data(contentsOf: originalURL)

            #expect(throws: (any Error).self) {
                _ = try LibraryMutationCoordination.withExclusiveTransaction(
                    layout: library.layout
                ) { transaction in
                    try PipelineMediaBinder.bind(
                        assets: [asset],
                        meetingID: meeting.id,
                        layout: library.layout,
                        transaction: transaction,
                        cloneAction: { _, _, _ in
                            errno = ENOTSUP
                            return -1
                        }
                    )
                }
            }
            #expect(try Data(contentsOf: originalURL) == originalBytes)
            #expect(try pipelineSnapshotSessions(library: library).isEmpty)
        }
    }

    @Test("a provider can never mutate the registered original through its input URL")
    func providerMutationCannotReachRegisteredOriginal() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let originalURL = fixture.library.layout.mediaFile(
                fixture.meeting.id,
                fileName: "imported.caf"
            )
            let originalBytes = try Data(contentsOf: originalURL)
            var originalStatus = stat()
            #expect(lstat(originalURL.path, &originalStatus) == 0)
            let provider = FakeTranscriptionProvider(behavior: .mutateInputAndFail)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let requested = try #require(await provider.requestedIdentities().first)
            #expect(requested.deviceID == UInt64(originalStatus.st_dev))
            #expect(requested.fileID != UInt64(originalStatus.st_ino))
            #expect(requested.linkCount == 1)
            #expect(originalStatus.st_nlink == 1)
            #expect(try Data(contentsOf: originalURL) == originalBytes)
            #expect(try await fixture.jobStore.load(fixture.job.id).status == .failed)
            #expect(try pipelineSnapshotSessions(library: fixture.library).isEmpty)
            await coordinator.stop()
        }
    }

    @Test("a provider result is rejected when the private clone was mutated")
    func mutatedPrivateCloneCannotProduceAResult() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let originalURL = fixture.library.layout.mediaFile(
                fixture.meeting.id,
                fileName: "imported.caf"
            )
            let originalBytes = try Data(contentsOf: originalURL)
            let provider = FakeTranscriptionProvider(behavior: .mutateInputAndSucceed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(try Data(contentsOf: originalURL) == originalBytes)
            #expect(try await fixture.jobStore.load(fixture.job.id).status == .failed)
            #expect(try revisionDocuments(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first?.status == .failed)
            await coordinator.stop()
        }
    }

    @Test("nil-generation imported job is rejected before meeting or provider mutation")
    func nilGenerationCannotBypassImportedGuard() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let receipt = try #require(fixture.meeting.metadata?.transferReceipt)
            try MeetingTransferStateStore.writeCommitPendingGuard(
                meetingID: fixture.meeting.id,
                receipt: receipt,
                to: fixture.library.layout.transferCommitPending(fixture.meeting.id)
            )
            try overwriteJob(
                fixture.job,
                status: .queued,
                layout: fixture.library.layout,
                importGenerationID: nil
            )
            let originalMedia = try Data(contentsOf: fixture.library.layout.mediaFile(
                fixture.meeting.id,
                fileName: "imported.caf"
            ))
            let provider = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(await provider.callCount() == 0)
            #expect(try await fixture.jobStore.load(fixture.job.id).status == .cancelled)
            #expect(try await fixture.library.loadMeeting(fixture.meeting.id).status == .ready)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.library.layout.currentRevision(fixture.meeting.id).path
            ))
            #expect(try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try Data(contentsOf: fixture.library.layout.mediaFile(
                fixture.meeting.id,
                fileName: "imported.caf"
            )) == originalMedia)
            await coordinator.stop()
        }
    }

    @Test("nil-generation native job keeps its existing pipeline behavior")
    func nilGenerationNativeJobStillRuns() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let provider = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(await provider.callCount() == 2)
            let terminalJob = try await fixture.jobStore.load(fixture.job.id)
            #expect(terminalJob.status == .finished)
            #expect(terminalJob.errorMessage == nil)
            #expect(try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ).meetingID == fixture.meeting.id)
            await coordinator.stop()
        }
    }

    @Test("generation-pinned imported job does not execute against a replacement meeting")
    func staleImportedJobIsCancelledBeforeProviderExecution() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let oldGeneration = try #require(fixture.job.importGenerationID)
            let provider = FakeTranscriptionProvider(behavior: .succeed)
            let pause = PipelineStatePause()
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US"),
                importedStateCheckpoint: { checkpoint in
                    guard checkpoint == .beforeImportedGenerationValidation(
                        fixture.job.id
                    ) else { return }
                    pause.arriveAndWait()
                }
            )
            await coordinator.start()
            try await eventually { pause.hasArrived }

            _ = try await fixture.library.trashMeeting(fixture.meeting.id)
            let replacementGeneration = MeetingTransferGenerationID()
            #expect(replacementGeneration != oldGeneration)
            let receipt = MeetingTransferReceipt(
                sourceMeetingID: fixture.meeting.id,
                sourceRevisionID: nil,
                sourcePackageContentDigest: String(repeating: "d", count: 64),
                importedAt: Date(timeIntervalSinceReferenceDate: 200),
                sourceAppVersion: nil,
                includedCapabilities: [.notes],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: replacementGeneration
            )
            _ = try await fixture.library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: Meeting(
                    id: fixture.meeting.id,
                    title: "Replacement",
                    status: .ready,
                    metadata: MeetingMetadata(transferReceipt: receipt)
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            ))

            pause.release()
            try await coordinator.waitUntilIdle()

            #expect(await provider.callCount() == 0)
            let staleJob = try await fixture.jobStore.load(fixture.job.id)
            #expect(staleJob.status == .cancelled)
            #expect(staleJob.errorMessage == "Imported meeting generation changed.")
            #expect(try await fixture.library.loadMeeting(fixture.meeting.id).status == .ready)
            #expect(try await MeetingTransferStateStore(layout: fixture.library.layout)
                .load(fixture.meeting.id) == .importedOnly)
            await coordinator.stop()
        }
    }

    @Test("generation-bound media stays pinned while a meeting is replaced during inference")
    func generationBoundMediaLeaseRejectsReplacementCommits() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let originalGeneration = try #require(fixture.job.importGenerationID)
            let originalBytes = Data(MediaAsset.Kind.micTrack.rawValue.utf8)
            let replacementBytes = Data(MediaAsset.Kind.systemTrack.rawValue.utf8)
            let provider = FakeTranscriptionProvider(behavior: .succeed)
            let pause = PipelineStatePause()
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US"),
                importedStateCheckpoint: { checkpoint in
                    guard checkpoint == .afterImportedGenerationInputBinding(
                        fixture.job.id
                    ) else { return }
                    pause.arriveAndWait()
                }
            )
            await coordinator.start()
            try await eventually { pause.hasArrived }

            _ = try await fixture.library.trashMeeting(fixture.meeting.id)
            let replacementGeneration = MeetingTransferGenerationID()
            #expect(replacementGeneration != originalGeneration)
            let replacementReceipt = MeetingTransferReceipt(
                sourceMeetingID: fixture.meeting.id,
                sourceRevisionID: nil,
                sourcePackageContentDigest: String(repeating: "e", count: 64),
                importedAt: Date(timeIntervalSinceReferenceDate: 300),
                sourceAppVersion: nil,
                includedCapabilities: [.audio],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: replacementGeneration
            )
            let replacement = Meeting(
                id: fixture.meeting.id,
                title: "Replacement during provider call",
                status: .ready,
                metadata: MeetingMetadata(transferReceipt: replacementReceipt)
            )
            let replacementSource = root.appending(path: "replacement.caf")
            try replacementBytes.write(to: replacementSource)
            let replacementAsset = MediaAsset(
                meetingID: fixture.meeting.id,
                kind: .micTrack,
                sampleRate: 48_000,
                duration: 1,
                provenanceKey: "transfer:\(fixture.meeting.id):track-1:\(String(repeating: "f", count: 64))",
                fileName: "imported.caf"
            )
            _ = try await fixture.library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: replacement,
                media: [.init(asset: replacementAsset, sourceURL: replacementSource)],
                revision: nil,
                transferState: .importedOnly
            ))

            pause.release()
            try await coordinator.waitUntilIdle()

            #expect(await provider.requestedSources() == [originalBytes])
            let providerFiles = await provider.requestedFiles()
            #expect(providerFiles.allSatisfy {
                $0.path.contains("/.pipeline-inputs/")
                    && $0 != fixture.library.layout.mediaFile(
                        fixture.meeting.id,
                        fileName: "imported.caf"
                    )
            })
            #expect(providerFiles.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            })
            let staleJob = try await fixture.jobStore.load(fixture.job.id)
            #expect(staleJob.status == .cancelled)
            #expect(staleJob.errorMessage == "Imported meeting generation changed.")
            #expect(try await fixture.library.loadMeeting(fixture.meeting.id).status == .ready)
            #expect(try await MeetingTransferStateStore(layout: fixture.library.layout)
                .load(fixture.meeting.id) == .importedOnly)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.library.layout.currentRevision(fixture.meeting.id).path
            ))
            #expect(try revisionDocuments(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try Data(contentsOf: fixture.library.layout.mediaFile(
                fixture.meeting.id,
                fileName: "imported.caf"
            )) == replacementBytes)
            await coordinator.stop()
        }
    }

    @Test("failed imported final ASR becomes a local manual-retry state without requeue")
    func importedFailureNeedsManualRetry() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(try await fixture.jobStore.list().map(\.id) == [fixture.job.id])
            #expect(try await fixture.jobStore.load(fixture.job.id).status == .failed)
            #expect(try await MeetingTransferStateStore(layout: fixture.library.layout)
                .load(fixture.meeting.id) == .needsManualRetry(
                    jobID: fixture.job.id,
                    localeIdentifier: "de-DE",
                    reason: "Processing failed."
                ))
            await coordinator.stop()
        }
    }

    @Test("cancelled imported final ASR becomes a local manual-retry state without requeue")
    func importedCancellationNeedsManualRetry() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let provider = FakeTranscriptionProvider(behavior: .block)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US")
            )
            await coordinator.start()
            try await eventually {
                let running = try await fixture.jobStore.load(fixture.job.id).status == .running
                let calls = await provider.callCount()
                return running && calls == 1
            }

            try await coordinator.cancel(jobID: fixture.job.id)
            try await coordinator.waitUntilIdle()

            #expect(try await fixture.jobStore.list().map(\.id) == [fixture.job.id])
            #expect(try await fixture.jobStore.load(fixture.job.id).status == .cancelled)
            #expect(try await MeetingTransferStateStore(layout: fixture.library.layout)
                .load(fixture.meeting.id) == .needsManualRetry(
                    jobID: fixture.job.id,
                    localeIdentifier: "de-DE",
                    reason: "Processing was cancelled."
                ))
            await coordinator.stop()
        }
    }

    @Test("imported failure cannot overwrite a newer processing request")
    func importedFailureTransitionIsMonotonic() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let pause = PipelineStatePause()
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .fail)),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US"),
                importedStateCheckpoint: { checkpoint in
                    guard checkpoint == .beforeManualRetryTransition(fixture.job.id) else { return }
                    pause.arriveAndWait()
                }
            )
            await coordinator.start()
            try await eventually { pause.hasArrived }
            let newer = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: fixture.meeting.id,
                localeIdentifier: "fr-FR",
                createdAt: Date(timeIntervalSinceReferenceDate: 500),
                importGenerationID: fixture.job.importGenerationID
            )
            let stateStore = MeetingTransferStateStore(layout: fixture.library.layout)
            try await stateStore.save(.processingRequested(newer), for: fixture.meeting.id)
            pause.release()
            try await coordinator.waitUntilIdle()

            #expect(try await stateStore.load(fixture.meeting.id) == .processingRequested(newer))
            await coordinator.stop()
        }
    }

    @Test("imported cancellation cannot overwrite a newer processing request")
    func importedCancellationTransitionIsMonotonic() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makeImportedPipelineFixture(at: root)
            let provider = FakeTranscriptionProvider(behavior: .block)
            let pause = PipelineStatePause()
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US"),
                importedStateCheckpoint: { checkpoint in
                    guard checkpoint == .beforeManualRetryTransition(fixture.job.id) else { return }
                    pause.arriveAndWait()
                }
            )
            await coordinator.start()
            try await eventually {
                let running = try await fixture.jobStore.load(fixture.job.id).status == .running
                let calls = await provider.callCount()
                return running && calls == 1
            }
            let cancellation = Task { try await coordinator.cancel(jobID: fixture.job.id) }
            try await eventually { pause.hasArrived }
            let newer = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: fixture.meeting.id,
                localeIdentifier: "fr-FR",
                createdAt: Date(timeIntervalSinceReferenceDate: 501),
                importGenerationID: fixture.job.importGenerationID
            )
            let stateStore = MeetingTransferStateStore(layout: fixture.library.layout)
            try await stateStore.save(.processingRequested(newer), for: fixture.meeting.id)
            pause.release()
            try await cancellation.value
            try await coordinator.waitUntilIdle()

            #expect(try await stateStore.load(fixture.meeting.id) == .processingRequested(newer))
            await coordinator.stop()
        }
    }

    @Test("pinned job locale wins over coordinator locale and is recorded on the run")
    func pinnedLocaleWins() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(
                at: root,
                jobLocaleIdentifier: "de-DE"
            )
            let provider = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "en-US")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let run = try #require(processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .finalASR })
            #expect(await provider.requestedLocales() == ["de-DE", "de-DE"])
            #expect(run.localeIdentifier == "de-DE")
            await coordinator.stop()
        }
    }

    @Test("a meeting becomes ready only after every downstream job is terminal")
    func marksMeetingReadyOnlyAfterPipelineChain() {
        let meetingID = MeetingID()
        let current = Job(
            kind: .finalASR,
            meetingID: meetingID,
            status: .running
        )
        let downstream = Job(
            kind: .diarization,
            meetingID: meetingID,
            status: .queued
        )

        #expect(!PipelineCompletionPolicy.shouldMarkMeetingReady(
            after: current,
            jobs: [current, downstream]
        ))
        var finishedDownstream = downstream
        finishedDownstream.status = .finished
        #expect(PipelineCompletionPolicy.shouldMarkMeetingReady(
            after: current,
            jobs: [current, finishedDownstream]
        ))
    }

    @Test(
        "transcription and diarization completion ignore a parallel report job",
        arguments: [Job.Kind.finalASR, .diarization]
    )
    func pipelineCompletionIgnoresReportJob(_ upstreamKind: Job.Kind) {
        let meetingID = MeetingID()
        let failed = Job(
            kind: upstreamKind,
            meetingID: meetingID,
            status: .failed
        )
        let queued = Job(
            kind: .templateRender,
            meetingID: meetingID,
            status: .queued
        )

        #expect(PipelineCompletionPolicy.meetingStatus(
            after: failed,
            jobs: [failed, queued],
            whenNoActiveJobs: .interrupted
        ) == .interrupted)
        var finished = queued
        finished.status = .finished
        #expect(PipelineCompletionPolicy.meetingStatus(
            after: failed,
            jobs: [failed, finished],
            whenNoActiveJobs: .interrupted
        ) == .interrupted)
    }

    @Test("cancelling a queued report job never settles the meeting")
    func cancellingQueuedReportDoesNotSettleMeeting() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            _ = try await fixture.jobStore.transition(fixture.job.id, to: .running)
            _ = try await fixture.jobStore.transition(fixture.job.id, to: .failed)
            let queued = Job(
                kind: .templateRender,
                meetingID: fixture.meeting.id,
                templateID: "meeting-minutes"
            )
            try await fixture.jobStore.enqueue(queued)
            _ = try await fixture.library.updateMeetingStatus(
                fixture.meeting.id,
                to: .processing
            )
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            try await coordinator.cancel(jobID: queued.id)

            #expect(try await fixture.jobStore.load(queued.id).status == .cancelled)
            #expect(try await fixture.library.loadMeeting(fixture.meeting.id).status == .processing)
        }
    }

    @Test("cancelling a failed report job never settles the meeting")
    func cancellingFailedReportDoesNotSettleMeeting() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            _ = try await fixture.jobStore.transition(fixture.job.id, to: .running)
            _ = try await fixture.jobStore.transition(fixture.job.id, to: .failed)
            let failed = Job(
                kind: .templateRender,
                meetingID: fixture.meeting.id,
                templateID: "meeting-minutes"
            )
            try await fixture.jobStore.enqueue(failed)
            _ = try await fixture.jobStore.transition(failed.id, to: .running)
            _ = try await fixture.jobStore.transition(failed.id, to: .failed)
            _ = try await fixture.library.updateMeetingStatus(
                fixture.meeting.id,
                to: .processing
            )
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            try await coordinator.cancel(jobID: failed.id)

            #expect(try await fixture.jobStore.load(failed.id).status == .cancelled)
            #expect(try await fixture.library.loadMeeting(fixture.meeting.id).status == .processing)
        }
    }

    @Test("waitUntilIdle includes jobs running in another coordinator")
    func waitsForExternallyRunningJob() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            _ = try await fixture.jobStore.transition(fixture.job.id, to: .running)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: FakeTranscriptionProvider(behavior: .succeed)),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )
            let completion = CompletionProbe()
            let waiter = Task {
                await completion.markStarted()
                try await coordinator.waitUntilIdle()
                await completion.markCompleted()
            }

            try await eventually { await completion.hasStarted() }
            try await Task.sleep(for: .milliseconds(50))
            #expect(!(await completion.isCompleted()))
            _ = try await fixture.jobStore.transition(fixture.job.id, to: .failed)
            try await waiter.value
            #expect(await completion.isCompleted())
        }
    }

    @Test("a final ASR job transcribes every track and commits its revision before follow-up jobs")
    func successfulJob() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let microphoneProvider = FakeTranscriptionProvider(behavior: .succeed)
            let systemProvider = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: [
                    .micTrack: microphoneProvider,
                    .systemTrack: systemProvider,
                ],
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let finishedJob = try await fixture.jobStore.load(fixture.job.id)
            let runs = try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            )
            let run = try #require(runs.first { $0.kind == .finalASR })
            let artifact = try JSONDecoder().decode(
                FinalASRArtifact.self,
                from: Data(contentsOf: fixture.library.layout.runTranscript(
                    fixture.meeting.id,
                    runID: run.id
                ))
            )
            let revision = try await fixture.library.loadRevision(
                artifact.revisionID,
                meetingID: fixture.meeting.id
            )

            #expect(finishedJob.status == .finished)
            #expect(finishedJob.attemptCount == 1)
            #expect(await microphoneProvider.callCount() == 1)
            #expect(await systemProvider.callCount() == 1)
            #expect(runs.count == 3)
            #expect(run.status == .finished)
            #expect(run.id.rawValue != fixture.job.id.rawValue)
            #expect(revision.id.rawValue != fixture.job.id.rawValue)
            #expect(revision.id.rawValue != run.id.rawValue)
            #expect(revision.origin == .finalRun(run.id))
            #expect(revision.turns.map(\.speaker) == [
                .channel("Ich"),
                .channel("Andere"),
            ])
            #expect(try revisionDocuments(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 2)
            #expect(try temporaryRunDirectories(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            await coordinator.stop()
        }
    }

    @Test("final ASR skips an empty track when another track contains audio")
    func skipsEmptyTrack() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(
                at: root,
                durations: [.micTrack: 0, .systemTrack: 2]
            )
            let microphoneProvider = FakeTranscriptionProvider(behavior: .fail)
            let systemProvider = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: [
                    .micTrack: microphoneProvider,
                    .systemTrack: systemProvider,
                ],
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            #expect(try await fixture.jobStore.load(fixture.job.id).status == .finished)
            #expect(await microphoneProvider.callCount() == 0)
            #expect(await systemProvider.callCount() == 1)
            await coordinator.stop()
        }
    }

    @Test("final ASR fails promptly when every track is empty")
    func failsWhenEveryTrackIsEmpty() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(
                at: root,
                durations: [.micTrack: 0, .systemTrack: 0]
            )
            let provider = FakeTranscriptionProvider(behavior: .block)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let job = try await fixture.jobStore.load(fixture.job.id)
            #expect(job.status == .failed)
            #expect(job.errorMessage == "The recording contains no audio samples.")
            #expect(await provider.callCount() == 0)
            await coordinator.stop()
        }
    }

    @Test("a final ASR revision remains a candidate when the current revision is a user edit")
    func preservesUserEdits() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let base = TranscriptRevision(
                meetingID: fixture.meeting.id,
                origin: .liveProvisional,
                turns: []
            )
            let userEdit = TranscriptRevision(
                meetingID: fixture.meeting.id,
                origin: .userEdit(base.id),
                turns: []
            )
            _ = try await fixture.library.appendRevision(base)
            _ = try await fixture.library.appendRevision(userEdit)
            let provider = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let pointer = try await fixture.library.loadCurrentRevisionPointer(
                meetingID: fixture.meeting.id
            )
            #expect(pointer.currentRevisionID == userEdit.id)
            #expect(pointer.pendingCandidate != nil)
            #expect(pointer.pendingCandidate?.rawValue != fixture.job.id.rawValue)
            #expect(try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == userEdit)
            await coordinator.stop()
        }
    }

    @Test("launch recovery resumes an interrupted running job without duplicate revisions")
    func crashRecoveryIsIdempotent() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let blockingProvider = FakeTranscriptionProvider(behavior: .block)
            let interrupted = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: blockingProvider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )
            await interrupted.start()
            try await eventually {
                let status = try await fixture.jobStore.load(fixture.job.id).status
                let callCount = await blockingProvider.callCount()
                return status == .running && callCount == 1
            }

            await interrupted.stop()

            #expect(try await fixture.jobStore.load(fixture.job.id).status == .running)
            #expect(try temporaryRunDirectories(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 1)

            let resumedProvider = FakeTranscriptionProvider(behavior: .succeed)
            let runtime = try await startPipeline(
                at: root,
                providers: providers(using: resumedProvider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )
            try await runtime.coordinator.waitUntilIdle()

            let finishedJob = try await runtime.jobStore.load(fixture.job.id)
            #expect(finishedJob.status == .finished)
            #expect(finishedJob.attemptCount == 2)
            #expect(await resumedProvider.callCount() == 2)
            #expect(try revisionDocuments(
                library: runtime.library,
                meetingID: fixture.meeting.id
            ).count == 2)
            #expect(try temporaryRunDirectories(
                library: runtime.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            await runtime.coordinator.stop()

            try overwriteJob(
                finishedJob,
                status: .running,
                layout: runtime.library.layout
            )

            let providerThatMustNotRun = FakeTranscriptionProvider(behavior: .fail)
            let diarizationThatMustNotRun = FakeDiarizationProvider(behavior: .fail)
            let secondRestart = try await startPipeline(
                at: root,
                providers: providers(using: providerThatMustNotRun),
                diarizationProvider: diarizationThatMustNotRun,
                locale: Locale(identifier: "de-DE")
            )
            try await secondRestart.coordinator.waitUntilIdle()

            #expect(try await secondRestart.jobStore.load(fixture.job.id).status == .finished)
            #expect(await providerThatMustNotRun.callCount() == 0)
            #expect(await diarizationThatMustNotRun.callCount() == 0)
            #expect(try revisionDocuments(
                library: secondRestart.library,
                meetingID: fixture.meeting.id
            ).count == 2)
            await secondRestart.coordinator.stop()
        }
    }

    @Test("cancelling an active job marks it cancelled and removes partial runs")
    func cancellationCleansUp() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let provider = FakeTranscriptionProvider(behavior: .block)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )
            await coordinator.start()
            try await eventually {
                let status = try await fixture.jobStore.load(fixture.job.id).status
                let callCount = await provider.callCount()
                return status == .running && callCount == 1
            }

            try await coordinator.cancel(jobID: fixture.job.id)
            try await coordinator.waitUntilIdle()

            #expect(try await fixture.jobStore.load(fixture.job.id).status == .cancelled)
            #expect(try temporaryRunDirectories(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).isEmpty)
            #expect(try pipelineSnapshotSessions(library: fixture.library).isEmpty)
            await coordinator.stop()
        }
    }

    @Test("a provider error fails the job and preserves the current revision")
    func providerFailurePreservesCurrentRevision() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let live = TranscriptRevision(
                meetingID: fixture.meeting.id,
                origin: .liveProvisional,
                turns: []
            )
            _ = try await fixture.library.appendRevision(live)
            let provider = FakeTranscriptionProvider(behavior: .fail)
            let coordinator = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )

            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let failedJob = try await fixture.jobStore.load(fixture.job.id)
            let failedRun = try #require(processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first)
            #expect(failedJob.status == .failed)
            #expect(failedJob.errorMessage != nil)
            #expect(failedRun.status == .failed)
            #expect(try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == live)
            #expect(try revisionDocuments(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 1)
            #expect(await provider.requestedFiles().allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            })
            #expect(try pipelineSnapshotSessions(library: fixture.library).isEmpty)
            await coordinator.stop()
        }
    }

    @Test("two coordinators claim a queued job only once")
    func concurrentCoordinatorsDoNotDuplicateWork() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let provider = FakeTranscriptionProvider(behavior: .succeed)
            let configuredProviders = providers(using: provider)
            let diarization = FakeDiarizationProvider(behavior: .succeed)
            let first = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: configuredProviders,
                diarizationProvider: diarization,
                locale: Locale(identifier: "de-DE")
            )
            let second = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: configuredProviders,
                diarizationProvider: diarization,
                locale: Locale(identifier: "de-DE")
            )

            await first.start()
            await second.start()
            try await eventually {
                let jobs = try await fixture.jobStore.list()
                return jobs.count == 3 && jobs.allSatisfy { $0.status == .finished }
            }

            #expect(await provider.callCount() == 2)
            #expect(try revisionDocuments(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 2)
            #expect(try processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).count == 3)
            await first.stop()
            await second.stop()
        }
    }

    @Test("a corrupt committed transcript is quarantined and the job fails safely")
    func corruptCommittedRunIsQuarantined() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try await makePipelineFixture(at: root)
            let initialProvider = FakeTranscriptionProvider(behavior: .succeed)
            let initial = PipelineCoordinator(
                library: fixture.library,
                jobStore: fixture.jobStore,
                providers: providers(using: initialProvider),
                diarizationProvider: FakeDiarizationProvider(behavior: .succeed),
                locale: Locale(identifier: "de-DE")
            )
            await initial.start()
            try await initial.waitUntilIdle()
            await initial.stop()

            let current = try await fixture.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            )
            let finishedJob = try await fixture.jobStore.load(fixture.job.id)
            let run = try #require(processingRuns(
                library: fixture.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .finalASR })
            try AtomicFile.write(
                Data("not json".utf8),
                to: fixture.library.layout.runTranscript(
                    fixture.meeting.id,
                    runID: run.id
                )
            )
            try overwriteJob(
                finishedJob,
                status: .running,
                layout: fixture.library.layout
            )

            let providerThatMustNotRun = FakeTranscriptionProvider(behavior: .fail)
            let restarted = try await startPipeline(
                at: root,
                providers: providers(using: providerThatMustNotRun),
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "de-DE")
            )
            try await restarted.coordinator.waitUntilIdle()

            #expect(try await restarted.jobStore.load(fixture.job.id).status == .failed)
            #expect(await providerThatMustNotRun.callCount() == 0)
            #expect(try await restarted.library.loadCurrentRevision(
                meetingID: fixture.meeting.id
            ) == current)
            let runEntries = try FileManager.default.contentsOfDirectory(
                at: restarted.library.layout.runsDirectory(fixture.meeting.id),
                includingPropertiesForKeys: nil
            )
            #expect(runEntries.contains {
                $0.lastPathComponent.hasPrefix("\(run.id).corrupt-")
            })
            #expect(try processingRuns(
                library: restarted.library,
                meetingID: fixture.meeting.id
            ).first { $0.kind == .finalASR }?.status == .failed)
            await restarted.coordinator.stop()
        }
    }
}

private enum PipelineCleanupTestError: Error {
    case injected
}

private actor CompletionProbe {
    private var started = false
    private var completed = false

    func markStarted() {
        started = true
    }

    func hasStarted() -> Bool {
        started
    }

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private final class PipelineStatePause: @unchecked Sendable {
    private let arrived = Mutex(false)
    private let resume = DispatchSemaphore(value: 0)

    var hasArrived: Bool { arrived.withLock { $0 } }

    func arriveAndWait() {
        arrived.withLock { $0 = true }
        resume.wait()
    }

    func release() {
        resume.signal()
    }
}
