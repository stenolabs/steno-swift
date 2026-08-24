import CryptoKit
import Darwin
import Foundation
import StenoDomain
import Synchronization
import Testing
@testable import StenoLibrary

@Suite("Meeting transfer import")
struct MeetingTransferImportTests {
    @Test("transfer commit result captures the exact local generation")
    func commitResultPinsTransferGeneration() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(in: root, digest: "generation-result")
            defer { context.source.close() }
            let library = try Library.open(at: context.libraryRoot)
            let generationID = MeetingTransferGenerationID()
            let receipt = MeetingTransferReceipt(
                sourceMeetingID: context.meetingID,
                sourceRevisionID: nil,
                sourcePackageContentDigest: context.prepared.meeting.metadata?
                    .transferReceipt?.sourcePackageContentDigest ?? "generation-result",
                importedAt: Date(timeIntervalSinceReferenceDate: 1),
                sourceAppVersion: nil,
                includedCapabilities: [.audio],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: generationID
            )
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(id: context.meetingID, receipt: receipt),
                media: context.prepared.media,
                revision: nil,
                transferState: .importedOnly
            )

            #expect(try await library.commitPreparedMeeting(prepared)
                == .imported(context.meetingID, importGenerationID: generationID))
            #expect(try await library.commitPreparedMeeting(prepared)
                == .alreadyPresent(context.meetingID, importGenerationID: generationID))
        }
    }

    @Test("audio-only import commits a ready meeting without a current revision")
    func importsAudioOnlyWithoutRevision() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(in: root, digest: "package-a")
            defer { context.source.close() }
            let library = try Library.open(at: context.libraryRoot)

            let result = try await library.commitPreparedMeeting(context.prepared)

            #expect(result == .imported(context.meetingID))
            #expect(try await library.loadMeeting(context.meetingID).status == .ready)
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.currentRevision(context.meetingID).path
            ))
            #expect(try FileManager.default.contentsOfDirectory(
                at: library.layout.revisionsDirectory(context.meetingID),
                includingPropertiesForKeys: nil
            ).isEmpty)
            #expect(
                try await MeetingTransferStateStore(layout: library.layout)
                    .load(context.meetingID) == .importedOnly
            )
            #expect(
                try Data(contentsOf: library.layout.mediaFile(
                    context.meetingID,
                    fileName: context.asset.fileName
                )) == context.source.bytes
            )
            #expect(context.acquisitionCount.value == 1)
        }
    }

    @Test("transcript import writes exactly one revision and current pointer")
    func importsOptionalRevision() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appending(path: "Library")
            let library = try Library.open(at: libraryRoot)
            let meetingID = MeetingID()
            let receipt = makeReceipt(meetingID: meetingID, digest: "with-transcript")
            let revision = TranscriptRevision(
                meetingID: meetingID,
                origin: .meetingTransfer(
                    sourceMeetingID: meetingID,
                    sourceRevisionID: receipt.sourceRevisionID
                ),
                turns: []
            )
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(id: meetingID, receipt: receipt),
                media: [],
                revision: revision,
                transferState: .awaitingLanguageConfirmation
            )

            #expect(try await library.commitPreparedMeeting(prepared) == .imported(meetingID))
            #expect(try await library.loadCurrentRevision(meetingID: meetingID) == revision)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: library.layout.revisionsDirectory(meetingID),
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent) == ["\(revision.id).json"]
            )
        }
    }

    @Test("same receipt digest is a no-op after a local note edit")
    func duplicateIgnoresLocalNoteEditAndDoesNotAcquireSource() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(in: root, digest: "same-package")
            defer { context.source.close() }
            let library = try Library.open(at: context.libraryRoot)
            _ = try await library.commitPreparedMeeting(context.prepared)
            try await MeetingNotesStore(layout: library.layout).setNotes(
                context.meetingID,
                to: "local edit"
            )
            context.acquisitionCount.reset()
            let before = try directorySnapshot(at: context.libraryRoot)

            let result = try await library.commitPreparedMeeting(context.prepared)

            #expect(result == .alreadyPresent(context.meetingID))
            #expect(context.acquisitionCount.value == 0)
            #expect(try directorySnapshot(at: context.libraryRoot) == before)
            #expect(
                try await MeetingNotesStore(layout: library.layout)
                    .notes(context.meetingID) == "local edit"
            )
        }
    }

    @Test("different digest for the same source conflicts without mutation")
    func conflictingDigestDoesNotAcquireSource() async throws {
        try await withTemporaryDirectory { root in
            let original = try makeDescriptorImport(in: root, digest: "original")
            defer { original.source.close() }
            let library = try Library.open(at: original.libraryRoot)
            _ = try await library.commitPreparedMeeting(original.prepared)

            let conflicting = try makeDescriptorImport(
                in: root,
                digest: "different",
                meetingID: original.meetingID,
                libraryRoot: original.libraryRoot
            )
            defer { conflicting.source.close() }
            let before = try directorySnapshot(at: original.libraryRoot)

            do {
                _ = try await library.commitPreparedMeeting(conflicting.prepared)
                Issue.record("expected a meeting-transfer conflict")
            } catch let error as LibraryError {
                guard case .meetingTransferConflict(let existingMeetingID) = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
                #expect(existingMeetingID == original.meetingID)
            }
            #expect(conflicting.acquisitionCount.value == 0)
            #expect(try directorySnapshot(at: original.libraryRoot) == before)
        }
    }

    @Test("native meeting with the same ID conflicts without mutation")
    func sameIDWithoutReceiptConflicts() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appending(path: "Library")
            let library = try Library.open(at: libraryRoot)
            let meetingID = MeetingID()
            let legacySource = root.appending(path: "legacy.caf")
            try Data("legacy".utf8).write(to: legacySource)
            _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: Meeting(id: meetingID, title: "Native", status: .ready),
                media: [],
                revision: TranscriptRevision(
                    meetingID: meetingID,
                    origin: .legacyImport,
                    turns: []
                )
            ))
            let incoming = try makeDescriptorImport(
                in: root,
                digest: "incoming",
                meetingID: meetingID,
                libraryRoot: libraryRoot
            )
            defer { incoming.source.close() }
            let before = try directorySnapshot(at: libraryRoot)

            await #expect(throws: LibraryError.self) {
                _ = try await library.commitPreparedMeeting(incoming.prepared)
            }
            #expect(incoming.acquisitionCount.value == 0)
            #expect(try directorySnapshot(at: libraryRoot) == before)
        }
    }

    @Test("duplicate media provenance fails before descriptor acquisition")
    func duplicateMediaProvenanceFailsBeforeAcquisition() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appending(path: "Library")
            let library = try Library.open(at: libraryRoot)
            let source = root.appending(path: "existing.caf")
            try Data("existing".utf8).write(to: source)
            let existingID = MeetingID()
            let sharedProvenance = "transfer:source:track-1:hash"
            _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: Meeting(id: existingID, title: "Existing", status: .ready),
                media: [PreparedMediaImport(
                    asset: MediaAsset(
                        meetingID: existingID,
                        kind: .micTrack,
                        sampleRate: 48_000,
                        duration: 1,
                        provenanceKey: sharedProvenance,
                        fileName: "existing.caf"
                    ),
                    sourceURL: source
                )],
                revision: TranscriptRevision(
                    meetingID: existingID,
                    origin: .legacyImport,
                    turns: []
                )
            ))

            let incoming = try makeDescriptorImport(
                in: root,
                digest: "new-package",
                libraryRoot: libraryRoot,
                provenance: sharedProvenance
            )
            defer { incoming.source.close() }
            let before = try directorySnapshot(at: libraryRoot)

            await #expect(throws: LibraryError.self) {
                _ = try await library.commitPreparedMeeting(incoming.prepared)
            }
            #expect(incoming.acquisitionCount.value == 0)
            #expect(try directorySnapshot(at: libraryRoot) == before)
        }
    }

    @Test("descriptor source is verified and cloned from its anonymous read-only inode")
    func securelyClonesAnonymousDescriptor() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(in: root, digest: "clone")
            defer { context.source.close() }
            let library = try Library.open(at: context.libraryRoot)

            _ = try await library.commitPreparedMeeting(context.prepared)

            var sourceStatus = stat()
            #expect(fstat(context.source.fileDescriptor, &sourceStatus) == 0)
            #expect(sourceStatus.st_nlink == 0)
            #expect(fcntl(context.source.fileDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
            let stored = library.layout.mediaFile(
                context.meetingID,
                fileName: context.asset.fileName
            )
            var destinationStatus = stat()
            #expect(stored.path.withCString { lstat($0, &destinationStatus) } == 0)
            #expect(destinationStatus.st_mode & S_IFMT == S_IFREG)
            #expect(destinationStatus.st_dev == sourceStatus.st_dev)
            #expect(try Data(contentsOf: stored) == context.source.bytes)
        }
    }

    @Test("descriptor hash mismatch leaves no visible meeting")
    func descriptorHashMismatchFailsClosed() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(
                in: root,
                digest: "bad-hash",
                expectedSHA256: String(repeating: "0", count: 64)
            )
            defer { context.source.close() }
            let library = try Library.open(at: context.libraryRoot)

            await #expect(throws: LibraryError.self) {
                _ = try await library.commitPreparedMeeting(context.prepared)
            }

            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(context.meetingID).path
            ))
            #expect(context.acquisitionCount.value == 1)
        }
    }

    @Test("descriptor identity mismatch leaves no visible meeting")
    func descriptorIdentityMismatchFailsClosed() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(
                in: root,
                digest: "bad-identity",
                expectedIdentity: PreparedMediaSourceIdentity(
                    deviceID: UInt64.max,
                    fileID: UInt64.max
                )
            )
            defer { context.source.close() }
            let library = try Library.open(at: context.libraryRoot)

            await #expect(throws: LibraryError.self) {
                _ = try await library.commitPreparedMeeting(context.prepared)
            }
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(context.meetingID).path
            ))
        }
    }

    @Test("named or writable descriptor source is rejected")
    func rejectsNamedWritableDescriptor() async throws {
        try await withTemporaryDirectory { root in
            let libraryRoot = root.appending(path: "Library")
            let sourceURL = root.appending(path: "writable.caf")
            let bytes = Data("writable named source".utf8)
            try bytes.write(to: sourceURL)
            let descriptor = sourceURL.path.withCString { open($0, O_RDWR | O_CLOEXEC) }
            #expect(descriptor >= 0)
            defer { close(descriptor) }
            let meetingID = MeetingID()
            let receipt = makeReceipt(meetingID: meetingID, digest: "writable")
            let asset = makeAsset(meetingID: meetingID, provenance: "writable")
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(id: meetingID, receipt: receipt),
                media: [PreparedMediaImport(
                    asset: asset,
                    sourceDisposition: .cloneValidatedDescriptor(
                        PreparedDescriptorBackedMediaSource(
                            expectedByteCount: Int64(bytes.count),
                            expectedSHA256: sha256(bytes),
                            acquire: {
                                PreparedMediaDescriptorLease(
                                    sourceURL: URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                                    close: {}
                                )
                            }
                        )
                    )
                )],
                revision: nil,
                transferState: .importedOnly
            )
            let library = try Library.open(at: libraryRoot)

            await #expect(throws: LibraryError.self) {
                _ = try await library.commitPreparedMeeting(prepared)
            }
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(meetingID).path
            ))
        }
    }

    @Test("state is staged before sync and every pre-commit injection stays invisible")
    func injectedFailuresLeaveNoVisibleMeeting() async throws {
        let preCommitCheckpoints: [PreparedMeetingImportCheckpoint] = [
            .beforeFileSynchronization,
            .afterStagingSynchronization,
            .beforeVisibleRename,
        ]
        for checkpoint in preCommitCheckpoints {
            try await withTemporaryDirectory { root in
                let libraryRoot = root.appending(path: "Library")
                let library = try Library.open(at: libraryRoot)
                let meetingID = MeetingID()
                let receipt = makeReceipt(
                    meetingID: meetingID,
                    digest: "failure-\(checkpoint)"
                )
                let prepared = PreparedMeetingImport(
                    meeting: makeTransferMeeting(id: meetingID, receipt: receipt),
                    media: [],
                    revision: nil,
                    transferState: .awaitingLanguageConfirmation
                )

                do {
                    _ = try await library.commitPreparedMeeting(
                        prepared,
                        checkpoint: { reached, staging in
                            if reached == .beforeFileSynchronization {
                                #expect(FileManager.default.fileExists(
                                    atPath: staging.appending(path: "transfer-state.json").path
                                ))
                            }
                            if reached == checkpoint {
                                throw InjectedImportFailure.stop
                            }
                        }
                    )
                    Issue.record("expected injected failure at \(checkpoint)")
                } catch InjectedImportFailure.stop {
                    // Expected.
                }

                #expect(!FileManager.default.fileExists(
                    atPath: library.layout.meetingDirectory(meetingID).path
                ))
                #expect(try hiddenImportArtifacts(in: library.layout).isEmpty)
            }
        }
    }

    @Test("post-rename failures roll back before reporting failure")
    func postRenameFailuresRollBackVisibleMeeting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meetingID = MeetingID()
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: meetingID,
                    receipt: makeReceipt(meetingID: meetingID, digest: "post-rename")
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            )

            do {
                _ = try await library.commitPreparedMeeting(
                    prepared,
                    checkpoint: { reached, _ in
                        if reached == .afterVisibleRenameBeforeParentSynchronization {
                            throw InjectedImportFailure.stop
                        }
                    }
                )
                Issue.record("expected injected post-rename failure")
            } catch InjectedImportFailure.stop {
                // The exact visible directory was rolled back first.
            }

            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(meetingID).path
            ))
            #expect(try hiddenImportArtifacts(in: library.layout).isEmpty)
        }
    }

    @Test("failed pre-commit cleanup preserves ownership token and replacement")
    func failedPreCommitCleanupRetainsOwnershipEvidence() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meetingID = MeetingID()
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: meetingID,
                    receipt: makeReceipt(meetingID: meetingID, digest: "cleanup-evidence")
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            )
            var sentinel: URL?

            do {
                _ = try await library.commitPreparedMeeting(
                    prepared,
                    checkpoint: { reached, staging in
                        guard reached == .beforeVisibleRename else { return }
                        try FileManager.default.removeItem(at: staging)
                        try FileManager.default.createDirectory(
                            at: staging,
                            withIntermediateDirectories: false
                        )
                        let replacement = staging.appending(path: "foreign.txt")
                        try Data("foreign replacement".utf8).write(to: replacement)
                        sentinel = replacement
                        throw InjectedImportFailure.stop
                    }
                )
                Issue.record("expected injected pre-commit cleanup failure")
            } catch InjectedImportFailure.stop {
                // Expected.
            }

            #expect(try Data(contentsOf: #require(sentinel)) == Data("foreign replacement".utf8))
            #expect(try hiddenImportArtifacts(in: library.layout).contains {
                $0.pathExtension == "owner"
            })
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(meetingID).path
            ))
        }
    }

    @Test("recursive cleanup failure keeps quarantine recoverable and preserves replacement")
    func recursiveCleanupFailureKeepsRecoverableOwnership() throws {
        try withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let ownership = try PreparedMeetingImportOwnership.reserve(
                in: library.layout.meetingsDirectory
            )
            try ownership.createStagingDirectory()
            let identity = try ownership.bindToStagingDirectory()
            let payload = ownership.stagingURL.appending(path: "audio.caf")
            try Data("owned payload".utf8).write(to: payload)
            var quarantine: URL?
            var foreignSentinel: URL?

            do {
                try ownership.removeOwnedStagingDirectory(
                    expectedIdentity: identity,
                    afterQuarantineRename: { quarantinedURL in
                        quarantine = quarantinedURL
                        try FileManager.default.createDirectory(
                            at: ownership.stagingURL,
                            withIntermediateDirectories: false
                        )
                        let sentinel = ownership.stagingURL.appending(path: "foreign.txt")
                        try Data("foreign replacement".utf8).write(to: sentinel)
                        foreignSentinel = sentinel
                        throw InjectedImportFailure.stop
                    }
                )
                Issue.record("expected injected recursive cleanup failure")
            } catch InjectedImportFailure.stop {
                // The owned directory has already been quarantined.
            }

            let quarantinedURL = try #require(quarantine)
            #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
            #expect(try Data(contentsOf: quarantinedURL.appending(path: "audio.caf"))
                == Data("owned payload".utf8))
            #expect(FileManager.default.fileExists(atPath: ownership.tokenURL.path))
            #expect(try Data(contentsOf: #require(foreignSentinel))
                == Data("foreign replacement".utf8))
            #expect(throws: LibraryError.self) {
                try ownership.removeOwnedToken()
            }
            #expect(FileManager.default.fileExists(atPath: ownership.tokenURL.path))

            let report = try PreparedMeetingImportRecovery.recover(
                in: library.layout.meetingsDirectory
            )

            #expect(!FileManager.default.fileExists(atPath: quarantinedURL.path))
            #expect(!FileManager.default.fileExists(atPath: ownership.tokenURL.path))
            #expect(try Data(contentsOf: #require(foreignSentinel))
                == Data("foreign replacement".utf8))
            #expect(report.requiresAttention.map {
                $0.resolvingSymlinksInPath()
            }.contains(ownership.stagingURL.resolvingSymlinksInPath()))
        }
    }

    @Test("parent fsync failure rolls back before reporting failure")
    func parentSynchronizationFailureRollsBackVisibleMeeting() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meetingID = MeetingID()
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: meetingID,
                    receipt: makeReceipt(meetingID: meetingID, digest: "fsync-failure")
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            )

            do {
                _ = try await library.commitPreparedMeeting(
                    prepared,
                    checkpoint: { _, _ in },
                    parentDirectorySynchronizer: { _ in
                        throw InjectedImportFailure.stop
                    }
                )
                Issue.record("expected injected parent synchronization failure")
            } catch InjectedImportFailure.stop {
                // The exact visible directory was rolled back first.
            }

            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(meetingID).path
            ))
            #expect(try hiddenImportArtifacts(in: library.layout).isEmpty)
        }
    }

    @Test("rollback fsync failure returns uncertain and preserves recovery evidence")
    func rollbackSynchronizationFailureReturnsUncertain() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meetingID = MeetingID()
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: meetingID,
                    receipt: makeReceipt(meetingID: meetingID, digest: "rollback-fsync")
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            )
            var staging: URL?

            let result = try await library.commitPreparedMeeting(
                prepared,
                checkpoint: { reached, stagingURL in
                    if reached == .beforeVisibleRename {
                        staging = stagingURL
                    }
                },
                parentDirectorySynchronizer: { _ in
                    throw InjectedImportFailure.stop
                },
                rollbackDirectorySynchronizer: { _ in
                    throw InjectedImportFailure.rollbackSynchronization
                }
            )

            #expect(result == .commitOutcomeUncertain(meetingID))
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(meetingID).path
            ))
            #expect(FileManager.default.fileExists(atPath: try #require(staging).path))
            #expect(try hiddenImportArtifacts(in: library.layout).contains {
                $0.pathExtension == "owner"
            })

            let report = try PreparedMeetingImportRecovery.recover(
                in: library.layout.meetingsDirectory
            )

            #expect(report.requiresAttention.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: try #require(staging).path))
            #expect(try hiddenImportArtifacts(in: library.layout).isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(meetingID).path
            ))
        }
    }

    @Test("identical retry leaves orphan ownership evidence for later recovery")
    func identicalRetryAfterVisibleUncertainCommitDefersOwnershipRecovery() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meetingID = MeetingID()
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: meetingID,
                    receipt: makeReceipt(meetingID: meetingID, digest: "uncertain-retry")
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            )
            var staging: URL?

            let uncertain = try await library.commitPreparedMeeting(
                prepared,
                checkpoint: { reached, stagingURL in
                    if reached == .beforeVisibleRename {
                        staging = stagingURL
                    }
                },
                parentDirectorySynchronizer: { _ in
                    throw InjectedImportFailure.stop
                },
                rollbackDirectorySynchronizer: { _ in
                    throw InjectedImportFailure.rollbackSynchronization
                }
            )
            #expect(uncertain == .commitOutcomeUncertain(meetingID))
            let orphanToken = try #require(try hiddenImportArtifacts(in: library.layout)
                .first { $0.pathExtension == "owner" })
            let destination = library.layout.meetingDirectory(meetingID)
            try FileManager.default.moveItem(at: try #require(staging), to: destination)

            let foreignDirectory = library.layout.meetingsDirectory.appending(
                path: ".meeting-import-\(UUID().uuidString).tmp",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: foreignDirectory,
                withIntermediateDirectories: false
            )
            let foreignPayload = foreignDirectory.appending(path: "foreign.txt")
            try Data("foreign directory".utf8).write(to: foreignPayload)
            let foreignToken = library.layout.meetingsDirectory.appending(
                path: "\(PreparedMeetingImportRecovery.stagingDirectoryPrefix)\(UUID().uuidString)-\(UUID().uuidString).owner"
            )
            try Data("unproven token".utf8).write(to: foreignToken)

            let retry = try await library.commitPreparedMeeting(prepared)

            #expect(retry == .alreadyPresent(meetingID))
            #expect(FileManager.default.fileExists(atPath: orphanToken.path))
            #expect(try Data(contentsOf: foreignPayload) == Data("foreign directory".utf8))
            #expect(try Data(contentsOf: foreignToken) == Data("unproven token".utf8))
            #expect(try await library.loadMeeting(meetingID).id == meetingID)

            let recovery = try PreparedMeetingImportRecovery.recover(
                in: library.layout.meetingsDirectory
            )

            #expect(!FileManager.default.fileExists(atPath: orphanToken.path))
            #expect(try Data(contentsOf: foreignPayload) == Data("foreign directory".utf8))
            #expect(try Data(contentsOf: foreignToken) == Data("unproven token".utf8))
            #expect(Set(recovery.requiresAttention.map(\.standardizedFileURL)) == [
                foreignDirectory.standardizedFileURL,
                foreignToken.standardizedFileURL,
            ])
        }
    }

    @Test("receipt no-op never deletes another actor's active bound token")
    func receiptNoOpPreservesOtherActorActiveBoundToken() async throws {
        try await withBlockingTemporaryDirectory { root in
            let libraryRoot = root.appending(path: "Library")
            let noOpLibrary = try Library.open(at: libraryRoot)
            let noOpMeetingID = MeetingID()
            let noOpPrepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: noOpMeetingID,
                    receipt: makeReceipt(meetingID: noOpMeetingID, digest: "no-op")
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            )
            #expect(
                try await noOpLibrary.commitPreparedMeeting(noOpPrepared)
                    == .imported(noOpMeetingID)
            )

            let activeLibrary = try Library.open(at: libraryRoot)
            let activeMeetingID = MeetingID()
            let activePrepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: activeMeetingID,
                    receipt: makeReceipt(meetingID: activeMeetingID, digest: "active")
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            )
            let reachedPostRename = AsyncStream.makeStream(of: Void.self)
            let finishActiveCommit = BlockingTestPause(name: "active import commit")
            let activeCommit = blockingTestTask {
                try await activeLibrary.commitPreparedMeeting(
                    activePrepared,
                    checkpoint: { checkpoint, _ in
                        guard checkpoint == .afterVisibleRenameBeforeParentSynchronization else {
                            return
                        }
                        reachedPostRename.continuation.yield()
                        finishActiveCommit.arriveAndWait()
                    }
                )
            }

            var postRenameEvents = reachedPostRename.stream.makeAsyncIterator()
            _ = await postRenameEvents.next()
            guard let activeToken = try hiddenImportArtifacts(in: noOpLibrary.layout)
                .first(where: { $0.pathExtension == "owner" }) else {
                finishActiveCommit.release()
                _ = try? await activeCommit.value
                Issue.record("active import has no ownership token")
                return
            }

            let noOpStarted = AsyncStream.makeStream(of: Void.self)
            let noOpFinished = Mutex(false)
            let noOp = blockingTestTask {
                noOpStarted.continuation.yield()
                let result = try await noOpLibrary.commitPreparedMeeting(noOpPrepared)
                noOpFinished.withLock { $0 = true }
                return result
            }
            var noOpEvents = noOpStarted.stream.makeAsyncIterator()
            _ = await noOpEvents.next()
            try await Task.sleep(for: .milliseconds(50))
            let tokenSurvivedNoOp = FileManager.default.fileExists(
                atPath: activeToken.path
            )
            #expect(!noOpFinished.withLock { $0 })
            finishActiveCommit.release()
            let activeResult = try await activeCommit.value
            let noOpResult = try await noOp.value

            #expect(noOpResult == .alreadyPresent(noOpMeetingID))
            #expect(tokenSurvivedNoOp)
            #expect(activeResult == .imported(activeMeetingID))
        }
    }

    @Test("native token rejects a file added while a large source is being hashed")
    func nativeSnapshotDetectsAdditionDuringHash() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let native = try await library.createMeeting(title: "Native", status: .ready)
            let largeAudio = library.layout.mediaFile(native.id, fileName: "large.caf")
            try Data(repeating: 0xa5, count: 2_200_000).write(to: largeAudio)
            let token = try await library.nativeMeetingTransferSnapshotToken(for: native.id)
            let digest = String(repeating: "d", count: 64)
            let incoming = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: native.id,
                    receipt: makeReceipt(meetingID: native.id, digest: digest)
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly,
                nativeMeetingMatch: NativeMeetingTransferMatch(
                    meetingID: native.id,
                    contentDigest: digest,
                    snapshotToken: token
                )
            )
            let didMutate = Mutex(false)

            await #expect(throws: LibraryError.self) {
                try await library.commitPreparedMeeting(
                    incoming,
                    checkpoint: { _, _ in },
                    nativeSnapshotCheckpoint: { checkpoint in
                        guard case .hashedChunk(let relativePath, _) = checkpoint,
                              relativePath == "media/large.caf" else { return }
                        try didMutate.withLock { mutated in
                            guard !mutated else { return }
                            mutated = true
                            try AtomicFile.write(
                                Data("created during hash".utf8),
                                to: library.layout.userNotes(native.id)
                            )
                        }
                    }
                )
            }

            #expect(didMutate.withLock { $0 })
            #expect(try await library.loadMeeting(native.id).metadata?.transferReceipt == nil)
            #expect(try Data(contentsOf: library.layout.userNotes(native.id))
                == Data("created during hash".utf8))
        }
    }

    @Test("native no-op serializes the final decision with a notes edit")
    func nativeNoOpCoordinatesPostVerificationNotesEdit() async throws {
        try await withBlockingTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let native = try await library.createMeeting(title: "Native", status: .ready)
            let token = try await library.nativeMeetingTransferSnapshotToken(for: native.id)
            let digest = String(repeating: "e", count: 64)
            let incoming = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: native.id,
                    receipt: makeReceipt(meetingID: native.id, digest: digest)
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly,
                nativeMeetingMatch: NativeMeetingTransferMatch(
                    meetingID: native.id,
                    contentDigest: digest,
                    snapshotToken: token
                )
            )
            let reachedFinalVerification = AsyncStream.makeStream(of: Void.self)
            let finishDecision = BlockingTestPause(name: "native no-op decision")
            let commit = blockingTestTask {
                try await library.commitPreparedMeeting(
                    incoming,
                    checkpoint: { _, _ in },
                    nativeSnapshotCheckpoint: { checkpoint in
                        guard checkpoint == .finishedFinalVerification else { return }
                        reachedFinalVerification.continuation.yield()
                        finishDecision.arriveAndWait()
                    }
                )
            }
            var events = reachedFinalVerification.stream.makeAsyncIterator()
            _ = await events.next()

            let writerStarted = AsyncStream.makeStream(of: Void.self)
            let notesStore = MeetingNotesStore(layout: library.layout)
            let writer = blockingTestTask {
                writerStarted.continuation.yield()
                try await notesStore.setNotes(native.id, to: "after snapshot")
            }
            var writerEvents = writerStarted.stream.makeAsyncIterator()
            _ = await writerEvents.next()
            try await Task.sleep(for: .milliseconds(50))

            let changedBeforeDecision = FileManager.default.fileExists(
                atPath: library.layout.userNotes(native.id).path
            )
            finishDecision.release()
            let result = try await commit.value
            try await writer.value

            #expect(!changedBeforeDecision)
            #expect(result == .alreadyPresent(native.id))
            #expect(try await notesStore.notes(native.id) == "after snapshot")
        }
    }

    @Test("library-open recovery cannot cross a shared native snapshot decision")
    func nativeNoOpCoordinatesRevisionRecoveryAtLibraryOpen() async throws {
        try await withBlockingTemporaryDirectory { root in
            let libraryRoot = root.appending(path: "Library")
            let library = try Library.open(at: libraryRoot)
            let native = try await library.createMeeting(title: "Native", status: .ready)
            let interrupted = TranscriptRevision(
                meetingID: native.id,
                origin: .liveProvisional,
                turns: []
            )
            await #expect(throws: RevisionAppendInterruption.self) {
                _ = try await library.appendRevision(
                    interrupted,
                    interruptAfterRevisionWrite: true
                )
            }
            let reachedFinalVerification = AsyncStream.makeStream(of: Void.self)
            let finishSnapshot = BlockingTestPause(name: "native snapshot decision")
            let snapshot = blockingTestTask {
                try await library.nativeMeetingTransferSnapshotToken(
                    for: native.id,
                    checkpoint: { checkpoint in
                        guard checkpoint == .finishedFinalVerification else { return }
                        reachedFinalVerification.continuation.yield()
                        finishSnapshot.arriveAndWait()
                    }
                )
            }
            var decisionEvents = reachedFinalVerification.stream.makeAsyncIterator()
            _ = await decisionEvents.next()

            let reopenStarted = AsyncStream.makeStream(of: Void.self)
            let reopenFinished = Mutex(false)
            let reopened = blockingTestTask {
                reopenStarted.continuation.yield()
                let result = try Library.open(at: libraryRoot)
                reopenFinished.withLock { $0 = true }
                return result
            }
            var reopenEvents = reopenStarted.stream.makeAsyncIterator()
            _ = await reopenEvents.next()
            try await Task.sleep(for: .milliseconds(50))
            #expect(!reopenFinished.withLock { $0 })

            finishSnapshot.release()
            let tokenBeforeRecovery = try await snapshot.value
            let recoveredLibrary = try await reopened.value
            let tokenAfterRecovery = try await recoveredLibrary
                .nativeMeetingTransferSnapshotToken(for: native.id)
            #expect(tokenAfterRecovery != tokenBeforeRecovery)
            let digest = String(repeating: "f", count: 64)
            let incoming = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: native.id,
                    receipt: makeReceipt(meetingID: native.id, digest: digest)
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly,
                nativeMeetingMatch: NativeMeetingTransferMatch(
                    meetingID: native.id,
                    contentDigest: digest,
                    snapshotToken: tokenBeforeRecovery
                )
            )
            await #expect(throws: LibraryError.self) {
                _ = try await recoveredLibrary.commitPreparedMeeting(incoming)
            }
        }
    }

    @Test("native token includes the canonical directory set and metadata")
    func nativeSnapshotTokenIncludesDirectoriesAndMetadata() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let native = try await library.createMeeting(title: "Native", status: .ready)
            let initial = try await library.nativeMeetingTransferSnapshotToken(for: native.id)
            let emptyDirectory = library.layout.meetingDirectory(native.id).appending(
                path: "empty-canonical-directory",
                directoryHint: .isDirectory
            )

            try FileManager.default.createDirectory(
                at: emptyDirectory,
                withIntermediateDirectories: false
            )
            let withDirectory = try await library.nativeMeetingTransferSnapshotToken(
                for: native.id
            )
            let stableDirectory = try await library.nativeMeetingTransferSnapshotToken(
                for: native.id
            )
            #expect(withDirectory != initial)
            #expect(stableDirectory == withDirectory)

            let meetingURL = library.layout.meetingMetadata(native.id)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_234_567_890)],
                ofItemAtPath: meetingURL.path
            )
            let metadataChanged = try await library.nativeMeetingTransferSnapshotToken(
                for: native.id
            )
            #expect(metadataChanged != stableDirectory)
        }
    }

    @Test("failed post-rename rollback reports committed and preserves replacements")
    func failedPostRenameRollbackReturnsImported() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meetingID = MeetingID()
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(
                    id: meetingID,
                    receipt: makeReceipt(meetingID: meetingID, digest: "committed-fallback")
                ),
                media: [],
                revision: nil,
                transferState: .importedOnly
            )
            var replacement: URL?

            let result = try await library.commitPreparedMeeting(
                prepared,
                checkpoint: { reached, staging in
                    guard reached == .afterVisibleRenameBeforeParentSynchronization else {
                        return
                    }
                    try FileManager.default.createDirectory(
                        at: staging,
                        withIntermediateDirectories: false
                    )
                    let sentinel = staging.appending(path: "foreign.txt")
                    try Data("do not delete".utf8).write(to: sentinel)
                    replacement = sentinel
                },
                parentDirectorySynchronizer: { _ in
                    throw InjectedImportFailure.stop
                }
            )

            #expect(result == .imported(meetingID))
            #expect(try await library.loadMeeting(meetingID).id == meetingID)
            #expect(try Data(contentsOf: #require(replacement)) == Data("do not delete".utf8))
        }
    }

    @Test("recovery preserves an unmarked staging directory from before ownership")
    func recoveryPreservesDirectoryBeforeMarker() throws {
        try withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let meetings = library.layout.meetingsDirectory
            let foreign = meetings.appending(
                path: "\(PreparedMeetingImportRecovery.stagingDirectoryPrefix)\(UUID().uuidString)-\(UUID().uuidString).tmp",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
            try Data("foreign".utf8).write(to: foreign.appending(path: "keep.txt"))

            let report = try PreparedMeetingImportRecovery.recover(in: meetings)

            #expect(FileManager.default.fileExists(atPath: foreign.path))
            #expect(
                report.requiresAttention.map { $0.resolvingSymlinksInPath() }
                    == [foreign.resolvingSymlinksInPath()]
            )
        }
    }

    @Test("recovery removes bound complete staging and its sibling token")
    func recoveryRemovesBoundStagingAfterHardCrash() throws {
        try withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let ownership = try PreparedMeetingImportOwnership.reserve(
                in: library.layout.meetingsDirectory
            )
            try ownership.createStagingDirectory()
            try ownership.bindToStagingDirectory()
            try Data("fully staged audio".utf8).write(
                to: ownership.stagingURL.appending(path: "audio.caf")
            )
            #expect(FileManager.default.fileExists(atPath: ownership.tokenURL.path))
            #expect(try FileManager.default.contentsOfDirectory(
                at: ownership.stagingURL,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent) == ["audio.caf"])

            let report = try PreparedMeetingImportRecovery.recover(
                in: library.layout.meetingsDirectory
            )

            #expect(report.requiresAttention.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: ownership.stagingURL.path))
            #expect(!FileManager.default.fileExists(atPath: ownership.tokenURL.path))
        }
    }

    @Test("recovery removes an orphan reservation token")
    func recoveryRemovesOrphanToken() throws {
        try withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let ownership = try PreparedMeetingImportOwnership.reserve(
                in: library.layout.meetingsDirectory
            )

            let report = try PreparedMeetingImportRecovery.recover(
                in: library.layout.meetingsDirectory
            )

            #expect(report.requiresAttention.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: ownership.tokenURL.path))
        }
    }

    @Test("recovery never deletes a replacement with a mismatched inode")
    func recoveryPreservesIdentityMismatch() throws {
        try withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let ownership = try PreparedMeetingImportOwnership.reserve(
                in: library.layout.meetingsDirectory
            )
            try ownership.createStagingDirectory()
            try ownership.bindToStagingDirectory()
            try FileManager.default.removeItem(at: ownership.stagingURL)
            try FileManager.default.createDirectory(
                at: ownership.stagingURL,
                withIntermediateDirectories: false
            )
            let sentinel = ownership.stagingURL.appending(path: "foreign.txt")
            try Data("foreign replacement".utf8).write(to: sentinel)

            let report = try PreparedMeetingImportRecovery.recover(
                in: library.layout.meetingsDirectory
            )

            #expect(report.requiresAttention.map {
                $0.resolvingSymlinksInPath()
            }.contains(ownership.stagingURL.resolvingSymlinksInPath()))
            #expect(try Data(contentsOf: sentinel) == Data("foreign replacement".utf8))
            #expect(FileManager.default.fileExists(atPath: ownership.tokenURL.path))
        }
    }

    @Test("processing request for another meeting fails before source acquisition")
    func rejectsMismatchedTransferStateBeforeAcquisition() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(in: root, digest: "state-mismatch")
            defer { context.source.close() }
            let request = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: MeetingID(),
                localeIdentifier: "de-DE",
                createdAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
            let prepared = PreparedMeetingImport(
                meeting: context.prepared.meeting,
                media: context.prepared.media,
                revision: nil,
                transferState: .processingRequested(request)
            )
            let library = try Library.open(at: context.libraryRoot)

            await #expect(throws: LibraryError.self) {
                _ = try await library.commitPreparedMeeting(prepared)
            }
            #expect(context.acquisitionCount.value == 0)
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(context.meetingID).path
            ))
        }
    }

    @Test("processing request generation must match its local transfer receipt")
    func rejectsMismatchedTransferGenerationBeforeAcquisition() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(in: root, digest: "generation-mismatch")
            defer { context.source.close() }
            let receiptGeneration = MeetingTransferGenerationID()
            let receipt = MeetingTransferReceipt(
                sourceMeetingID: context.meetingID,
                sourceRevisionID: nil,
                sourcePackageContentDigest: String(repeating: "f", count: 64),
                importedAt: Date(timeIntervalSinceReferenceDate: 1),
                sourceAppVersion: nil,
                includedCapabilities: [.audio],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: receiptGeneration
            )
            let request = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: context.meetingID,
                localeIdentifier: "de-DE",
                createdAt: Date(timeIntervalSinceReferenceDate: 2),
                importGenerationID: MeetingTransferGenerationID()
            )
            let prepared = PreparedMeetingImport(
                meeting: makeTransferMeeting(id: context.meetingID, receipt: receipt),
                media: context.prepared.media,
                revision: nil,
                transferState: .processingRequested(request)
            )
            let library = try Library.open(at: context.libraryRoot)

            await #expect(throws: LibraryError.self) {
                _ = try await library.commitPreparedMeeting(prepared)
            }
            #expect(context.acquisitionCount.value == 0)
            #expect(!FileManager.default.fileExists(
                atPath: library.layout.meetingDirectory(context.meetingID).path
            ))
        }
    }

    @Test("transfer import rejects every mixture with legacy metadata")
    func rejectsMixedLegacyTransferMetadata() async throws {
        let mixedValues: [(String?, [String])] = [
            ("legacy:key", []),
            (nil, ["Legacy Folder"]),
            ("legacy:key", ["Legacy Folder"]),
        ]
        for (legacyKey, legacyFolders) in mixedValues {
            try await withTemporaryDirectory { root in
                let library = try Library.open(at: root.appending(path: "Library"))
                let meetingID = MeetingID()
                let receipt = makeReceipt(meetingID: meetingID, digest: "mixed")
                let meeting = Meeting(
                    id: meetingID,
                    title: "Mixed",
                    status: .ready,
                    metadata: MeetingMetadata(
                        legacyProvenanceKey: legacyKey,
                        legacyFolders: legacyFolders,
                        transferReceipt: receipt
                    )
                )

                await #expect(throws: LibraryError.self) {
                    _ = try await library.commitPreparedMeeting(PreparedMeetingImport(
                        meeting: meeting,
                        media: [],
                        revision: nil,
                        transferState: .importedOnly
                    ))
                }
                #expect(!FileManager.default.fileExists(
                    atPath: library.layout.meetingDirectory(meetingID).path
                ))
            }
        }
    }

    @Test("legacy copy keeps its source and current revision")
    func legacyCopyBehaviorIsUnchanged() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "Library"))
            let source = root.appending(path: "legacy.caf")
            let bytes = Data("legacy source remains".utf8)
            try bytes.write(to: source)
            let meetingID = MeetingID()
            let revision = TranscriptRevision(
                meetingID: meetingID,
                origin: .legacyImport,
                turns: []
            )
            let asset = makeAsset(meetingID: meetingID, provenance: "legacy:copy")

            let result = try await library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: Meeting(id: meetingID, title: "Legacy", status: .ready),
                media: [PreparedMediaImport(asset: asset, sourceURL: source)],
                revision: revision
            ))

            #expect(result == .imported(meetingID))
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try await library.loadCurrentRevision(meetingID: meetingID) == revision)
            #expect(try Data(contentsOf: library.layout.mediaFile(
                meetingID,
                fileName: asset.fileName
            )) == bytes)
        }
    }

    @Test("parallel identical imports produce one meeting and one descriptor acquisition")
    func parallelIdenticalImportsCommitOnce() async throws {
        try await withTemporaryDirectory { root in
            let context = try makeDescriptorImport(in: root, digest: "parallel")
            defer { context.source.close() }
            let library = try Library.open(at: context.libraryRoot)

            async let first = library.commitPreparedMeeting(context.prepared)
            async let second = library.commitPreparedMeeting(context.prepared)
            let results = try await [first, second]

            #expect(results.filter { $0 == .imported(context.meetingID) }.count == 1)
            #expect(results.filter { $0 == .alreadyPresent(context.meetingID) }.count == 1)
            #expect(try await library.listMeetings().map(\.id) == [context.meetingID])
            #expect(context.acquisitionCount.value == 1)
        }
    }
}

private enum InjectedImportFailure: Error {
    case stop
    case rollbackSynchronization
}

private struct DescriptorImportContext {
    let libraryRoot: URL
    let meetingID: MeetingID
    let asset: MediaAsset
    let prepared: PreparedMeetingImport
    let source: AnonymousReadOnlyFile
    let acquisitionCount: LockedCounter
}

private final class LockedCounter: @unchecked Sendable {
    private let storage = Mutex(0)

    var value: Int {
        storage.withLock { $0 }
    }

    func increment() {
        storage.withLock { $0 += 1 }
    }

    func reset() {
        storage.withLock { $0 = 0 }
    }
}

private final class AnonymousReadOnlyFile: @unchecked Sendable {
    let fileDescriptor: Int32
    let bytes: Data

    init(in directory: URL, bytes: Data) throws {
        self.bytes = bytes
        let url = directory.appending(path: "anonymous-source-\(UUID().uuidString)")
        let writer = url.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard writer >= 0 else {
            throw POSIXFailure(operation: "create anonymous test source", code: errno)
        }
        do {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(
                        writer,
                        buffer.baseAddress!.advanced(by: offset),
                        buffer.count - offset
                    )
                    guard written >= 0 else {
                        throw POSIXFailure(operation: "write anonymous test source", code: errno)
                    }
                    offset += written
                }
            }
            guard fsync(writer) == 0 else {
                throw POSIXFailure(operation: "sync anonymous test source", code: errno)
            }
            let reader = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
            guard reader >= 0 else {
                throw POSIXFailure(operation: "open anonymous test source", code: errno)
            }
            guard unlink(url.path) == 0 else {
                Darwin.close(reader)
                throw POSIXFailure(operation: "unlink anonymous test source", code: errno)
            }
            Darwin.close(writer)
            fileDescriptor = reader
        } catch {
            Darwin.close(writer)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func close() {
        Darwin.close(fileDescriptor)
    }
}

private func makeDescriptorImport(
    in root: URL,
    digest: String,
    meetingID: MeetingID = MeetingID(),
    libraryRoot: URL? = nil,
    provenance: String? = nil,
    expectedSHA256: String? = nil,
    expectedIdentity: PreparedMediaSourceIdentity? = nil
) throws -> DescriptorImportContext {
    let resolvedLibraryRoot = libraryRoot ?? root.appending(path: "Library")
    let sourceDirectory = resolvedLibraryRoot.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: sourceDirectory,
        withIntermediateDirectories: true
    )
    let bytes = Data("validated audio for \(digest)".utf8)
    let source = try AnonymousReadOnlyFile(in: sourceDirectory, bytes: bytes)
    let acquisitions = LockedCounter()
    let receipt = makeReceipt(meetingID: meetingID, digest: digest)
    let asset = makeAsset(
        meetingID: meetingID,
        provenance: provenance ?? "transfer:\(meetingID):track-1:\(sha256(bytes))"
    )
    let descriptorSource = PreparedDescriptorBackedMediaSource(
        expectedByteCount: Int64(bytes.count),
        expectedSHA256: expectedSHA256 ?? sha256(bytes),
        expectedIdentity: expectedIdentity,
        acquire: {
            acquisitions.increment()
            return PreparedMediaDescriptorLease(
                sourceURL: URL(fileURLWithPath: "/dev/fd/\(source.fileDescriptor)"),
                close: {}
            )
        }
    )
    let prepared = PreparedMeetingImport(
        meeting: makeTransferMeeting(id: meetingID, receipt: receipt),
        media: [PreparedMediaImport(
            asset: asset,
            sourceDisposition: .cloneValidatedDescriptor(descriptorSource)
        )],
        revision: nil,
        transferState: .importedOnly
    )
    return DescriptorImportContext(
        libraryRoot: resolvedLibraryRoot,
        meetingID: meetingID,
        asset: asset,
        prepared: prepared,
        source: source,
        acquisitionCount: acquisitions
    )
}

private func makeReceipt(meetingID: MeetingID, digest: String) -> MeetingTransferReceipt {
    MeetingTransferReceipt(
        sourceMeetingID: meetingID,
        sourceRevisionID: RevisionID(),
        sourcePackageContentDigest: digest,
        importedAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceAppVersion: "1.0",
        includedCapabilities: [.audio],
        sourceLocaleIdentifier: "de-DE",
        sourceLocaleOrigin: .explicit
    )
}

private func makeTransferMeeting(
    id: MeetingID,
    receipt: MeetingTransferReceipt
) -> Meeting {
    Meeting(
        id: id,
        title: "Imported",
        createdAt: Date(timeIntervalSince1970: 1_690_000_000),
        status: .ready,
        participantIDs: [],
        additionalParticipantIDs: [],
        folderID: nil,
        metadata: MeetingMetadata(transferReceipt: receipt)
    )
}

private func makeAsset(meetingID: MeetingID, provenance: String) -> MediaAsset {
    let assetID = MediaAssetID()
    return MediaAsset(
        id: assetID,
        meetingID: meetingID,
        kind: .micTrack,
        sampleRate: 48_000,
        duration: 1,
        provenanceKey: provenance,
        fileName: "\(assetID).caf"
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func hiddenImportArtifacts(in layout: LibraryLayout) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: layout.meetingsDirectory,
        includingPropertiesForKeys: nil,
        options: []
    ).filter { $0.lastPathComponent.hasPrefix(PreparedMeetingImportRecovery.stagingDirectoryPrefix) }
}

private func directorySnapshot(at root: URL) throws -> [String: Data] {
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    )
    var snapshot: [String: Data] = [:]
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        snapshot[relative] = try Data(contentsOf: url)
    }
    return snapshot
}
