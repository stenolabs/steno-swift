import AppleArchive
@preconcurrency import AVFAudio
import CryptoKit
import Darwin
import Foundation
import StenoDomain
@testable import StenoExchange
import StenoLibrary
@testable import StenoPipeline
import Synchronization
import Testing

@Suite("Meeting transfer import service")
struct MeetingTransferImportServiceTests {
    @Test("first prepare sweeps only an unambiguously owned abandoned validation session")
    func startSweepRemovesAbandonedSession() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, notes: "sweep")
            let target = try await makeImportTarget(at: root)
            try FileManager.default.createDirectory(
                at: target.library.layout.transferValidationRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let abandoned = target.library.layout.transferValidationRoot.appending(
                path: ".stenomeeting-validation-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: abandoned,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let ownedFile = abandoned.appending(path: "snapshot.stenomeeting")
            _ = FileManager.default.createFile(
                atPath: ownedFile.path,
                contents: Data("orphan".utf8),
                attributes: [.posixPermissions: 0o600]
            )
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )

            let prepared = try await service.prepareImport(at: package.url)

            #expect(!FileManager.default.fileExists(atPath: abandoned.path))
            try await service.discardPrepared(sessionID: prepared.sessionID)
        }
    }

    @Test("startup sweep never removes another active import session")
    func startupSweepPreservesActiveSession() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root)
            let target = try await makeImportTarget(at: root)
            let first = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let second = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let firstPrepared = try await first.prepareImport(at: package.url)

            await #expect(throws: MeetingTransferValidationError.sessionInUse) {
                try await second.prepareImport(at: package.url)
            }
            #expect(try validationSessions(in: target.library.layout).count == 1)

            try await first.discardPrepared(sessionID: firstPrepared.sessionID)
            let secondPrepared = try await second.prepareImport(at: package.url)
            try await second.discardPrepared(sessionID: secondPrepared.sessionID)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("prepare exposes only validated snapshot data and exact digests")
    func preparesValidatedPreview() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(
                at: root,
                title: "Original",
                notes: "[00:00:01] Notiz",
                localeIdentifier: "de-DE",
                localeOrigin: .explicit
            )
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )

            let prepared = try await service.prepareImport(at: package.url)
            let independentlyValidated = try await MeetingTransferArchiveReader().validate(
                at: package.url,
                validationRoot: root.appending(path: "IndependentValidation")
            )
            defer { try? independentlyValidated.close() }

            #expect(prepared.preview.sourceMeetingID == package.meetingID)
            #expect(prepared.preview.title == "Original")
            #expect(prepared.preview.contentDigest == independentlyValidated.manifest.contentDigest)
            #expect(prepared.preview.transportDigest == independentlyValidated.transportDigest)
            #expect(prepared.preview.localeIdentifier == "de-DE")
            #expect(prepared.preview.localeOrigin == .explicit)
            #expect(prepared.preview.visibleSpeakerLabels == ["Ada"])
            #expect(prepared.preview.disposition == .new)

            try await service.discardPrepared(sessionID: prepared.sessionID)
        }
    }

    @Test("external replacement after prepare cannot change the imported snapshot")
    func externalReplacementDoesNotChangeSnapshot() async throws {
        try await withTemporaryDirectory { root in
            let original = try await makeImportPackage(
                at: root,
                title: "Original",
                notes: "erste Notiz"
            )
            let replacement = try await makeImportPackage(
                at: root,
                title: "Replacement",
                notes: "zweite Notiz"
            )
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: original.url)

            try FileManager.default.removeItem(at: original.url)
            try FileManager.default.copyItem(at: replacement.url, to: original.url)
            let result = try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .importOnly
            )

            #expect(result == .imported(original.meetingID))
            #expect(try await target.library.loadMeeting(original.meetingID).title == "Original")
            #expect(
                try await MeetingNotesStore(layout: target.library.layout)
                    .notes(original.meetingID) == "erste Notiz"
            )
        }
    }

    @Test("private snapshot mutation is rejected by the second validation")
    func snapshotMutationIsRejected() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, notes: "sicher")
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                importCheckpoint: { checkpoint in
                    guard case .beforeSecondValidation(let snapshotURL) = checkpoint else {
                        return
                    }
                    let handle = try FileHandle(forWritingTo: snapshotURL)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: Data("broken".utf8))
                }
            )
            let prepared = try await service.prepareImport(at: package.url)

            await #expect(throws: MeetingTransferValidationError.self) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                )
            }
            #expect(try await target.library.listMeetings().isEmpty)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("revalidation parse cleanup failure remains discardable by prepared session ID")
    func failedRevalidationCleanupIsAddressable() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, notes: "sicher")
            let target = try await makeImportTarget(at: root)
            let failCleanup = Mutex(true)
            let reader = MeetingTransferArchiveReader(cleanupAction: { _ in
                if failCleanup.withLock({ $0 }) {
                    throw ImportServiceTestError.injected
                }
            })
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                testingReader: reader,
                importCheckpoint: { checkpoint in
                    guard case .beforeSecondValidation(let snapshotURL) = checkpoint else {
                        return
                    }
                    let size = try Data(contentsOf: snapshotURL).count
                    try Data(repeating: 0, count: size).write(to: snapshotURL)
                }
            )
            let prepared = try await service.prepareImport(at: package.url)

            await #expect(throws: MeetingTransferValidationError.notRawAppleArchive) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                )
            }
            #expect(try validationSessions(in: target.library.layout).count == 2)

            failCleanup.withLock { $0 = false }
            try await service.discardPrepared(sessionID: prepared.sessionID)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("changed valid snapshot remains discardable when its cleanup first fails")
    func changedValidSnapshotCleanupIsRetryable() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, notes: "eins")
            let originalByteCount = try Data(contentsOf: package.url).count
            var matchedReplacementBytes: Data?
            for _ in 0..<32 where matchedReplacementBytes == nil {
                let replacement = try await makeImportPackage(at: root, notes: "zwei")
                let bytes = try Data(contentsOf: replacement.url)
                if bytes.count == originalByteCount {
                    matchedReplacementBytes = bytes
                }
            }
            let replacementBytes = try #require(matchedReplacementBytes)
            let target = try await makeImportTarget(at: root)
            let failures = Mutex(1)
            let reader = MeetingTransferArchiveReader(cleanupAction: { _ in
                try failures.withLock { remaining in
                    guard remaining > 0 else { return }
                    remaining -= 1
                    throw ImportServiceTestError.injected
                }
            })
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                testingReader: reader,
                importCheckpoint: { checkpoint in
                    guard case .beforeSecondValidation(let snapshotURL) = checkpoint else {
                        return
                    }
                    let handle = try FileHandle(forWritingTo: snapshotURL)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: replacementBytes)
                }
            )
            let prepared = try await service.prepareImport(at: package.url)

            await #expect(throws: MeetingTransferValidationError.self) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                )
            }
            #expect(try !validationSessions(in: target.library.layout).isEmpty)

            try await service.discardPrepared(sessionID: prepared.sessionID)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("discard removes every owned validation artifact")
    func discardCleansValidationSession() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, notes: "discard")
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)
            #expect(try !validationSessions(in: target.library.layout).isEmpty)

            try await service.discardPrepared(sessionID: prepared.sessionID)

            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("cleanup failure is visible and discard retries the same session")
    func cleanupFailureIsRetryable() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, notes: "cleanup")
            let target = try await makeImportTarget(at: root)
            let failures = Mutex(1)
            let reader = MeetingTransferArchiveReader(cleanupAction: { _ in
                try failures.withLock { remaining in
                    guard remaining > 0 else { return }
                    remaining -= 1
                    throw ImportServiceTestError.injected
                }
            })
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                testingReader: reader
            )
            let prepared = try await service.prepareImport(at: package.url)

            await #expect(throws: MeetingTransferValidationError.self) {
                try await service.discardPrepared(sessionID: prepared.sessionID)
            }
            #expect(try !validationSessions(in: target.library.layout).isEmpty)

            try await service.discardPrepared(sessionID: prepared.sessionID)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("prepare cleanup failure returns a discardable session")
    func prepareCleanupFailureIsRetryable() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root)
            let target = try await makeImportTarget(at: root)
            let corrupt = try await target.library.createMeeting(
                title: "Corrupt",
                status: .ready
            )
            try Data("{".utf8).write(
                to: target.library.layout.meetingMetadata(corrupt.id),
                options: .atomic
            )
            let failures = Mutex(1)
            let reader = MeetingTransferArchiveReader(cleanupAction: { _ in
                try failures.withLock { remaining in
                    guard remaining > 0 else { return }
                    remaining -= 1
                    throw ImportServiceTestError.injected
                }
            })
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                testingReader: reader
            )

            let sessionID: UUID
            do {
                _ = try await service.prepareImport(at: package.url)
                Issue.record("expected preparation cleanup requirement")
                return
            } catch let error as MeetingTransferImportError {
                guard case .preparationCleanupRequired(let pendingSessionID) = error else {
                    Issue.record("unexpected import error: \(error)")
                    return
                }
                sessionID = pendingSessionID
            }
            #expect(try !validationSessions(in: target.library.layout).isEmpty)

            try await service.discardPrepared(sessionID: sessionID)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("initial validation cleanup failure remains addressable without restarting service")
    func failedInitialValidationCleanupIsAddressable() async throws {
        try await withTemporaryDirectory { root in
            let invalid = root.appending(path: "invalid.stenomeeting")
            try writeImportTestRawArchive(
                [("broken", Data("not-a-manifest".utf8))],
                to: invalid
            )
            let valid = try await makeImportPackage(at: root, notes: "next")
            let target = try await makeImportTarget(at: root)
            let failCleanup = Mutex(true)
            let reader = MeetingTransferArchiveReader(cleanupAction: { _ in
                if failCleanup.withLock({ $0 }) {
                    throw ImportServiceTestError.injected
                }
            })
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                testingReader: reader
            )
            var cleanupSessionID: UUID?

            do {
                _ = try await service.prepareImport(at: invalid)
                Issue.record("expected an addressable preparation cleanup failure")
            } catch let error as MeetingTransferImportError {
                guard case .preparationCleanupRequired(let sessionID) = error else {
                    Issue.record("unexpected import error: \(error)")
                    return
                }
                cleanupSessionID = sessionID
            }

            #expect(try validationSessions(in: target.library.layout).count == 1)
            failCleanup.withLock { $0 = false }
            try await service.discardPrepared(sessionID: try #require(cleanupSessionID))
            #expect(try validationSessions(in: target.library.layout).isEmpty)

            let next = try await service.prepareImport(at: valid.url)
            try await service.discardPrepared(sessionID: next.sessionID)
        }
    }

    @Test("cleanup failure after a successful commit remains explicitly discardable")
    func postCommitCleanupFailureIsRetryable() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, notes: "committed")
            let target = try await makeImportTarget(at: root)
            let failures = Mutex(1)
            let reader = MeetingTransferArchiveReader(cleanupAction: { _ in
                try failures.withLock { remaining in
                    guard remaining > 0 else { return }
                    remaining -= 1
                    throw ImportServiceTestError.injected
                }
            })
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                testingReader: reader
            )
            let prepared = try await service.prepareImport(at: package.url)

            do {
                _ = try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                )
                Issue.record("expected cleanup-required result")
            } catch let error as MeetingTransferImportError {
                #expect(error == .cleanupRequired(
                    sessionID: prepared.sessionID,
                    committedResult: .imported(package.meetingID)
                ))
            }
            #expect(try await target.library.loadMeeting(package.meetingID).status == .ready)
            #expect(try !validationSessions(in: target.library.layout).isEmpty)

            try await service.discardPrepared(sessionID: prepared.sessionID)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("import materializes editable notes transcript labels audio provenance and ready state")
    func materializesPortableContent() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(
                at: root,
                notes: "[00:00:02] editierbar",
                localeIdentifier: "de-DE",
                localeOrigin: .explicit,
                includeAudio: true
            )
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)

            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .importOnly
            ) == .imported(package.meetingID))

            let meeting = try await target.library.loadMeeting(package.meetingID)
            let revision = try await target.library.loadCurrentRevision(
                meetingID: package.meetingID
            )
            let asset = try #require(
                try await target.library.listMediaAssets(meetingID: package.meetingID).only
            )
            #expect(meeting.status == .ready)
            #expect(meeting.participantIDs.isEmpty)
            #expect(meeting.additionalParticipantIDs.isEmpty)
            #expect(meeting.folderID == nil)
            #expect(meeting.metadata?.transferReceipt?.sourcePackageContentDigest
                == prepared.preview.contentDigest)
            #expect(try await MeetingNotesStore(layout: target.library.layout)
                .notes(package.meetingID) == "[00:00:02] editierbar")
            #expect(revision.origin == .meetingTransfer(
                sourceMeetingID: package.meetingID,
                sourceRevisionID: package.sourceRevisionID
            ))
            guard case .importedTextLabel(let label) = revision.turns.first?.speaker else {
                Issue.record("expected imported text label")
                return
            }
            #expect(label.text == "Ada")
            #expect(label.wasConfirmedAtSource)
            #expect(asset.kind == .micTrack)
            #expect(asset.provenanceKey
                == "transfer:\(package.meetingID):track-1:\(package.audioSHA256!)")
            #expect(asset.fileName == "\(asset.id).caf")
            #expect(asset.sampleRate == 8_000)
            #expect(asset.duration > 0)
            #expect(try Data(contentsOf: target.library.layout.mediaFile(
                package.meetingID,
                fileName: asset.fileName
            )) == package.audioBytes)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("reordered manifest audio pairs import by canonical track number")
    func reorderedManifestAudioPairsImportCanonically() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeReorderedAudioImportPackage(at: root)
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )

            let prepared = try await service.prepareImport(at: package.url)
            #expect(prepared.preview.audioTracks.map(\.byteCount) == [
                Int64(package.firstBytes.count),
                Int64(package.secondBytes.count),
            ])
            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .importOnly
            ) == .imported(package.meetingID))

            let assets = try await target.library.listMediaAssets(meetingID: package.meetingID)
            let first = try #require(assets.first { $0.kind == .micTrack })
            let second = try #require(assets.first { $0.kind == .systemTrack })
            #expect(try Data(contentsOf: target.library.layout.mediaFile(
                package.meetingID,
                fileName: first.fileName
            )) == package.firstBytes)
            #expect(try Data(contentsOf: target.library.layout.mediaFile(
                package.meetingID,
                fileName: second.fileName
            )) == package.secondBytes)
        }
    }

    @Test("local media provenance ignores untrusted logical track identifiers")
    func mediaProvenanceUsesCanonicalTrackIdentity() async throws {
        try await withTemporaryDirectory { root in
            let privateToken = "private-token-\(UUID().uuidString)"
            let package = try await makeImportPackage(
                at: root,
                includeAudio: true,
                logicalTrackID: "track-1\n\(privateToken)"
            )
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)

            _ = try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .importOnly
            )

            let asset = try #require(
                try await target.library.listMediaAssets(meetingID: package.meetingID).only
            )
            #expect(asset.provenanceKey
                == "transfer:\(package.meetingID):track-1:\(try #require(package.audioSHA256))")
            #expect(!asset.provenanceKey.contains(privateToken))
            #expect(!asset.provenanceKey.contains("\n"))
        }
    }

    @Test("audio-only import can append the first ASR revision and current pointer")
    func audioOnlyImportCanAppendFirstASRRevision() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(
                at: root,
                notes: nil,
                localeIdentifier: "de-DE",
                localeOrigin: .explicit,
                includeAudio: true,
                includeTranscript: false
            )
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)

            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .process(
                    localeIdentifier: "de-DE",
                    languageConfirmed: true,
                    modelsReady: true
                )
            ) == .imported(package.meetingID))

            let provider = FakeTranscriptionProvider(behavior: .succeed)
            let coordinator = PipelineCoordinator(
                library: target.library,
                jobStore: target.jobStore,
                providers: providers(using: provider),
                diarizationProvider: FakeDiarizationProvider(behavior: .fail),
                locale: Locale(identifier: "en-US")
            )
            await coordinator.start()
            try await coordinator.waitUntilIdle()

            let pointer = try await target.library.loadCurrentRevisionPointer(
                meetingID: package.meetingID
            )
            let revision = try await target.library.loadCurrentRevision(
                meetingID: package.meetingID
            )
            let receiptGeneration = try #require(
                try await target.library.loadMeeting(package.meetingID)
                    .metadata?.transferReceipt?.importGenerationID
            )
            let importedJobs = try await target.jobStore.list().filter {
                $0.meetingID == package.meetingID
            }
            #expect(pointer.currentRevisionID == revision.id)
            #expect(revision.origin == .finalRun(
                try #require(processingRuns(
                    library: target.library,
                    meetingID: package.meetingID
                ).first { $0.kind == .finalASR }).id
            ))
            #expect(await provider.requestedLocales() == ["de-DE"])
            #expect(importedJobs.allSatisfy {
                $0.importGenerationID == receiptGeneration
            })
            #expect(importedJobs.first { $0.kind == .finalASR }?.localeIdentifier == "de-DE")
            await coordinator.stop()
        }
    }

    @Test("processing a text-only package imports it ready but reports no local audio")
    func textOnlyProcessKeepsUsefulImportWithoutJob() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(
                at: root,
                notes: "Bleibt lesbar",
                localeIdentifier: "de-DE",
                localeOrigin: .explicit,
                includeAudio: false
            )
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)

            await #expect(
                throws: MeetingTransferImportError.noAudioForProcessing(package.meetingID)
            ) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
            }

            #expect(try await target.library.loadMeeting(package.meetingID).status == .ready)
            #expect(try await MeetingNotesStore(layout: target.library.layout)
                .notes(package.meetingID) == "Bleibt lesbar")
            #expect(try await target.library.loadCurrentRevision(
                meetingID: package.meetingID
            ).meetingID == package.meetingID)
            #expect(try await MeetingTransferStateStore(layout: target.library.layout)
                .load(package.meetingID) == .importedOnly)
            #expect(try await target.jobStore.list().isEmpty)
        }
    }

    @Test("import-only state distinguishes explicit from unconfirmed locale provenance")
    func importOnlyPersistsLanguageState() async throws {
        for origin in [MeetingTransferLocaleOrigin.explicit, .estimated, .absent] {
            try await withTemporaryDirectory { root in
                let locale = origin == .absent ? nil : "de-DE"
                let package = try await makeImportPackage(
                    at: root,
                    localeIdentifier: locale,
                    localeOrigin: origin
                )
                let target = try await makeImportTarget(at: root)
                let service = MeetingTransferImportService(
                    library: target.library,
                    jobStore: target.jobStore
                )
                let prepared = try await service.prepareImport(at: package.url)
                _ = try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                )

                let state = try await MeetingTransferStateStore(layout: target.library.layout)
                    .load(package.meetingID)
                #expect(state == (origin == .explicit
                    ? .importedOnly
                    : .awaitingLanguageConfirmation))
                #expect(try await target.jobStore.list().isEmpty)
            }
        }
    }

    @Test("estimated locale cannot enqueue without explicit confirmation")
    func estimatedLocaleNeedsConfirmation() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(
                at: root,
                localeIdentifier: "de-DE",
                localeOrigin: .estimated,
                includeAudio: true
            )
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)

            await #expect(throws: MeetingTransferImportError.languageConfirmationRequired) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: false,
                        modelsReady: true
                    )
                )
            }
            #expect(try await target.jobStore.list().isEmpty)
            #expect(try await target.library.listMeetings().isEmpty)
        }
    }

    @Test("missing model imports safely without creating a job")
    func missingModelAwaitsInstallation() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)

            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .process(
                    localeIdentifier: "de-DE",
                    languageConfirmed: true,
                    modelsReady: false
                )
            ) == .imported(package.meetingID))
            #expect(try await MeetingTransferStateStore(layout: target.library.layout)
                .load(package.meetingID) == .awaitingModel(localeIdentifier: "de-DE"))
            #expect(try await target.jobStore.list().isEmpty)
        }
    }

    @Test("processing request and job identities are persisted before reconciliation")
    func processingRequestUsesStableIdentifiers() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)
            _ = try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .process(
                    localeIdentifier: "de-DE",
                    languageConfirmed: true,
                    modelsReady: true
                )
            )

            let job = try #require(try await target.jobStore.list().only)
            #expect(job.meetingID == package.meetingID)
            #expect(job.kind == .finalASR)
            #expect(job.localeIdentifier == "de-DE")
            #expect(try await MeetingTransferStateStore(layout: target.library.layout)
                .load(package.meetingID) == .jobEnqueued(
                    jobID: job.id,
                    localeIdentifier: "de-DE"
                ))
        }
    }

    @Test("uncertain commit is pending recovery and never enqueues")
    func uncertainCommitNeverEnqueues() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                commitPrepared: { prepared in
                    .commitOutcomeUncertain(
                        prepared.meeting.id,
                        importGenerationID: prepared.meeting.metadata?
                            .transferReceipt?.importGenerationID
                    )
                }
            )
            let prepared = try await service.prepareImport(at: package.url)

            let result = try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .process(
                    localeIdentifier: "de-DE",
                    languageConfirmed: true,
                    modelsReady: true
                )
            )

            #expect(result == .pendingRecovery(package.meetingID))
            #expect(try await target.jobStore.list().isEmpty)
        }
    }

    @Test("uncertain commit remains explicit when validation cleanup must be retried")
    func uncertainCommitWithCleanupFailurePreservesOutcome() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let failures = Mutex(1)
            let reader = MeetingTransferArchiveReader(cleanupAction: { _ in
                try failures.withLock { remaining in
                    guard remaining > 0 else { return }
                    remaining -= 1
                    throw ImportServiceTestError.injected
                }
            })
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                testingReader: reader,
                commitPrepared: { prepared in
                    .commitOutcomeUncertain(
                        prepared.meeting.id,
                        importGenerationID: prepared.meeting.metadata?
                            .transferReceipt?.importGenerationID
                    )
                }
            )
            let prepared = try await service.prepareImport(at: package.url)

            do {
                _ = try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
                Issue.record("expected cleanup-required result")
            } catch let error as MeetingTransferImportError {
                #expect(error == .cleanupRequired(
                    sessionID: prepared.sessionID,
                    committedResult: .pendingRecovery(package.meetingID)
                ))
            }
            #expect(try await target.jobStore.list().isEmpty)
            #expect(try !validationSessions(in: target.library.layout).isEmpty)

            try await service.discardPrepared(sessionID: prepared.sessionID)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("a commit without a recorded service result cannot process before a fresh import retry")
    func unacknowledgedCommitRequiresFreshImportRetry() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let interrupted = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                commitPrepared: { prepared in
                    _ = try await target.library.commitPreparedMeeting(prepared)
                    throw ImportServiceTestError.injected
                }
            )
            let prepared = try await interrupted.prepareImport(at: package.url)

            await #expect(throws: ImportServiceTestError.injected) {
                try await interrupted.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
            }
            let stateStore = MeetingTransferStateStore(layout: target.library.layout)
            #expect(try await stateStore.requiresFreshImportRetry(package.meetingID))
            let persistedRequest = try #require(try await stateStore.load(package.meetingID))
            guard case .processingRequested(let pendingRequest) = persistedRequest,
                  let pendingGenerationID = pendingRequest.importGenerationID else {
                Issue.record("expected persisted processing request")
                return
            }

            let reconciler = ImportedMeetingProcessingReconciler(
                library: target.library,
                stateStore: stateStore,
                jobStore: target.jobStore
            )
            try await reconciler.reconcileAll()
            #expect(try await target.jobStore.list().isEmpty)
            await #expect(
                throws: ImportedMeetingProcessingReconcilerError.commitRecoveryRequired(
                    package.meetingID
                )
            ) {
                try await reconciler.requestManualRetry(
                    meetingID: package.meetingID,
                    expectedImportGenerationID: pendingGenerationID,
                    localeIdentifier: "de-DE",
                    modelsReady: true
                )
            }

            let retry = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let retryPrepared = try await retry.prepareImport(at: package.url)
            #expect(try await retry.importPrepared(
                sessionID: retryPrepared.sessionID,
                choice: .importOnly
            ) == .alreadyPresent(package.meetingID))
            #expect(try await stateStore.load(package.meetingID) == .importedOnly)
            #expect(try await !stateStore.requiresFreshImportRetry(package.meetingID))
            #expect(try await target.jobStore.list().isEmpty)
        }
    }

    @Test("a prepared fresh retry cannot resolve a replacement generation with identical content")
    func freshRetryRejectsGenerationABA() async throws {
        try await withBlockingTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let firstInterrupted = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                commitPrepared: { prepared in
                    _ = try await target.library.commitPreparedMeeting(prepared)
                    throw ImportServiceTestError.injected
                }
            )
            let firstPrepared = try await firstInterrupted.prepareImport(at: package.url)
            do {
                _ = try await firstInterrupted.importPrepared(
                    sessionID: firstPrepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
                Issue.record("expected first interrupted commit")
            } catch ImportServiceTestError.injected {
                // Expected crash window.
            } catch {
                Issue.record("unexpected first import error: \(error)")
                return
            }
            let firstGeneration = try #require(
                try await target.library.loadMeeting(package.meetingID)
                    .metadata?.transferReceipt?.importGenerationID
            )

            let replacementInterrupted = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                commitPrepared: { prepared in
                    _ = try await target.library.commitPreparedMeeting(prepared)
                    throw ImportServiceTestError.injected
                }
            )
            let warmup = try await replacementInterrupted.prepareImport(at: package.url)
            try await replacementInterrupted.discardPrepared(sessionID: warmup.sessionID)

            let pause = BlockingTestPause(name: "prepared fresh import retry")
            let staleRetry = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                importCheckpoint: { checkpoint in
                    guard checkpoint == .beforeLibraryCommit else { return }
                    pause.arriveAndWait()
                }
            )
            let stalePrepared = try await staleRetry.prepareImport(at: package.url)
            let staleAttempt = blockingTestTask {
                try await staleRetry.importPrepared(
                    sessionID: stalePrepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
            }
            try await eventually { pause.hasArrived }

            _ = try await target.library.trashMeeting(package.meetingID)
            let replacementPrepared = try await replacementInterrupted.prepareImport(
                at: package.url
            )
            do {
                _ = try await replacementInterrupted.importPrepared(
                    sessionID: replacementPrepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
                Issue.record("expected replacement interrupted commit")
            } catch ImportServiceTestError.injected {
                // Expected crash window.
            } catch {
                Issue.record("unexpected replacement import error: \(error)")
                return
            }
            let replacementGeneration = try #require(
                try await target.library.loadMeeting(package.meetingID)
                    .metadata?.transferReceipt?.importGenerationID
            )
            #expect(replacementGeneration != firstGeneration)

            pause.release()
            do {
                _ = try await staleAttempt.value
                Issue.record("expected generation conflict")
            } catch let error as MeetingTransferImportError {
                #expect(error == .generationConflict(package.meetingID))
            } catch {
                Issue.record("unexpected stale retry error: \(error)")
            }

            let stateStore = MeetingTransferStateStore(layout: target.library.layout)
            guard case .processingRequested(let replacementRequest) = try await
                stateStore.load(package.meetingID)
            else {
                Issue.record("expected replacement processing request")
                return
            }
            #expect(replacementRequest.importGenerationID == replacementGeneration)
            #expect(try await stateStore.requiresFreshImportRetry(package.meetingID))
            #expect(try await target.jobStore.list().isEmpty)
        }
    }

    @Test("crash before meeting commit leaves no visible meeting or job")
    func crashBeforeCommitLeavesNothingVisible() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                importCheckpoint: { checkpoint in
                    guard checkpoint == .beforeLibraryCommit else { return }
                    throw ImportServiceTestError.injected
                }
            )
            let prepared = try await service.prepareImport(at: package.url)

            await #expect(throws: ImportServiceTestError.injected) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
            }
            #expect(try await target.library.listMeetings().isEmpty)
            #expect(try await target.jobStore.list().isEmpty)
            #expect(try validationSessions(in: target.library.layout).isEmpty)
        }
    }

    @Test("crash after meeting commit is recovered from the persisted request")
    func crashAfterCommitBeforeEnqueueRecovers() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                importCheckpoint: { checkpoint in
                    guard checkpoint == .afterLibraryCommitBeforeReconcile else { return }
                    throw ImportServiceTestError.injected
                }
            )
            let prepared = try await service.prepareImport(at: package.url)

            await #expect(throws: ImportServiceTestError.injected) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
            }
            guard case .processingRequested(let request) = try await
                MeetingTransferStateStore(layout: target.library.layout).load(package.meetingID)
            else {
                Issue.record("expected persisted processing request")
                return
            }
            #expect(try await target.jobStore.list().isEmpty)

            try await ImportedMeetingProcessingReconciler(
                library: target.library,
                stateStore: MeetingTransferStateStore(layout: target.library.layout),
                jobStore: target.jobStore
            ).reconcileAll()

            #expect(try await target.jobStore.list().map(\.id) == [request.jobID])
        }
    }

    @Test("processing import reconciles only its own meeting")
    func processingImportIgnoresAnotherBrokenMeeting() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let brokenMeetingID = MeetingID()
            let brokenGenerationID = MeetingTransferGenerationID()
            let brokenReceipt = MeetingTransferReceipt(
                sourceMeetingID: brokenMeetingID,
                sourceRevisionID: nil,
                sourcePackageContentDigest: String(repeating: "c", count: 64),
                importedAt: Date(timeIntervalSinceReferenceDate: 11),
                sourceAppVersion: nil,
                includedCapabilities: [.notes],
                sourceLocaleIdentifier: "de-DE",
                sourceLocaleOrigin: .explicit,
                importGenerationID: brokenGenerationID
            )
            let brokenRequest = ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: brokenMeetingID,
                localeIdentifier: "de-DE",
                createdAt: Date(timeIntervalSinceReferenceDate: 12),
                importGenerationID: brokenGenerationID
            )
            _ = try await target.library.commitPreparedMeeting(PreparedMeetingImport(
                meeting: Meeting(
                    id: brokenMeetingID,
                    title: "Broken",
                    status: .ready,
                    metadata: MeetingMetadata(transferReceipt: brokenReceipt)
                ),
                media: [],
                revision: nil,
                transferState: .processingRequested(brokenRequest)
            ))
            let brokenStateURL = target.library.layout.transferState(brokenMeetingID)
            let brokenStateBeforeImport = try Data(contentsOf: brokenStateURL)
            let meetingWithoutReceipt = Meeting(
                id: brokenMeetingID,
                title: "Broken",
                status: .ready
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFile.write(
                encoder.encode(meetingWithoutReceipt),
                to: target.library.layout.meetingMetadata(brokenMeetingID)
            )
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let prepared = try await service.prepareImport(at: package.url)

            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .process(
                    localeIdentifier: "de-DE",
                    languageConfirmed: true,
                    modelsReady: true
                )
            ) == .imported(package.meetingID))

            #expect(try await target.jobStore.list().count == 1)
            #expect(try Data(contentsOf: brokenStateURL) == brokenStateBeforeImport)
        }
    }

    @Test("processing import does not report success when its fixed job identity conflicts")
    func processingImportPropagatesItsJobIdentityConflict() async throws {
        try await withTemporaryDirectory { root in
            let package = try await makeImportPackage(at: root, includeAudio: true)
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore,
                commitPrepared: { prepared in
                    guard case .processingRequested(let request) = prepared.transferState else {
                        throw ImportServiceTestError.injected
                    }
                    let result = try await target.library.commitPreparedMeeting(prepared)
                    try await target.jobStore.enqueue(Job(
                        id: request.jobID,
                        kind: .finalASR,
                        meetingID: MeetingID(),
                        localeIdentifier: request.localeIdentifier,
                        importGenerationID: request.importGenerationID,
                        status: .finished,
                        createdAt: request.createdAt
                    ))
                    return result
                }
            )
            let prepared = try await service.prepareImport(at: package.url)

            do {
                _ = try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .process(
                        localeIdentifier: "de-DE",
                        languageConfirmed: true,
                        modelsReady: true
                    )
                )
                Issue.record("expected the current meeting's job identity conflict")
            } catch let error as LibraryError {
                guard case .jobIdentityConflict = error else {
                    Issue.record("unexpected library error: \(error)")
                    return
                }
            }

            guard case .processingRequested(let request) = try await
                MeetingTransferStateStore(layout: target.library.layout).load(package.meetingID)
            else {
                Issue.record("expected the processing request to remain pending")
                return
            }
            #expect(try await target.jobStore.list().map(\.id) == [request.jobID])
        }
    }

    @Test("same receipt digest is already present while different content conflicts")
    func receiptDispositionUsesImmutableContentDigest() async throws {
        try await withTemporaryDirectory { root in
            let meetingID = MeetingID()
            let original = try await makeImportPackage(
                at: root,
                meetingID: meetingID,
                notes: "original"
            )
            let conflicting = try await makeImportPackage(
                at: root,
                meetingID: meetingID,
                notes: "different"
            )
            let target = try await makeImportTarget(at: root)
            let service = MeetingTransferImportService(
                library: target.library,
                jobStore: target.jobStore
            )
            let first = try await service.prepareImport(at: original.url)
            _ = try await service.importPrepared(
                sessionID: first.sessionID,
                choice: .importOnly
            )

            let duplicate = try await service.prepareImport(at: original.url)
            #expect(duplicate.preview.disposition == .alreadyPresent(meetingID))
            #expect(try await service.importPrepared(
                sessionID: duplicate.sessionID,
                choice: .importOnly
            ) == .alreadyPresent(meetingID))

            let conflict = try await service.prepareImport(at: conflicting.url)
            #expect(conflict.preview.disposition == .conflict(meetingID))
            await #expect(throws: MeetingTransferImportError.conflict(meetingID)) {
                try await service.importPrepared(
                    sessionID: conflict.sessionID,
                    choice: .importOnly
                )
            }
        }
    }

    @Test("native identical package is a no-op only while the commit-bound snapshot stays current")
    func nativeNoOpIsBoundToFreshLibraryState() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "NativeLibrary"))
            let meeting = try await library.createMeeting(title: "Native", status: .ready)
            try await MeetingNotesStore(layout: library.layout).setNotes(
                meeting.id,
                to: "same"
            )
            let export = try await MeetingTransferExportService(library: library).export(
                meetingID: meeting.id,
                selectedAudioAssetIDs: [],
                temporaryRoot: root.appending(path: "NativeExport"),
                sourceAppVersion: nil
            )
            let jobStore = try JobStore(layout: library.layout)
            let service = MeetingTransferImportService(library: library, jobStore: jobStore)
            let prepared = try await service.prepareImport(at: export.packageURL)
            #expect(prepared.preview.disposition == .alreadyPresent(meeting.id))

            #expect(try await service.importPrepared(
                sessionID: prepared.sessionID,
                choice: .importOnly
            ) == .alreadyPresent(meeting.id))
            #expect(try await jobStore.list().isEmpty)
            #expect(try await MeetingTransferStateStore(layout: library.layout)
                .load(meeting.id) == nil)
        }
    }

    @Test("native no-op reconstructs canonical export track identifiers")
    func nativeNoOpUsesCanonicalTrackIdentifiers() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "NativeLibrary"))
            let meeting = try await library.createMeeting(title: "Native", status: .ready)
            let source = root.appending(path: "native.caf")
            try makePipelineTestCAF(at: source)
            let asset = try await library.registerMediaAsset(
                for: meeting.id,
                sourceURL: source,
                kind: .micTrack,
                sampleRate: 8_000,
                duration: 0.01
            )
            let registered = library.layout.mediaFile(
                meeting.id,
                fileName: asset.fileName
            )
            let inspection = try MeetingTransferAudioInspector().inspectCAFSource(
                at: registered
            )
            let digest = try await MeetingTransferDigest.sha256(of: registered)
            let noncanonicalID = "source-track"
            let content = try MeetingTransferPackageContent(
                meeting: try MeetingTransferMeetingDocument(
                    sourceMeetingID: meeting.id,
                    title: meeting.title,
                    createdAt: meeting.createdAt,
                    sourceStatus: meeting.status
                ),
                notes: nil,
                transcript: nil,
                audio: [try MeetingTransferAudioDocument(
                    logicalTrackID: noncanonicalID,
                    kind: asset.kind,
                    byteCount: inspection.byteCount,
                    sha256: digest,
                    sampleRate: inspection.sampleRate,
                    channelCount: inspection.channelCount,
                    duration: inspection.duration
                )]
            )
            let packageURL = try await MeetingTransferArchiveWriter().write(
                content,
                audioSources: [.init(
                    logicalTrackID: noncanonicalID,
                    sourceURL: registered
                )],
                sourceRevisionID: nil,
                sourceAppVersion: nil,
                to: root.appending(path: "NoncanonicalExport")
            )
            let service = MeetingTransferImportService(
                library: library,
                jobStore: try JobStore(layout: library.layout)
            )

            let prepared = try await service.prepareImport(at: packageURL)

            #expect(prepared.preview.disposition == .conflict(meeting.id))
            await #expect(throws: MeetingTransferImportError.conflict(meeting.id)) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                )
            }
        }
    }

    @Test("native state changed after fresh digest materialization cannot become a no-op")
    func nativeNoOpRejectsCommitRace() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root.appending(path: "NativeLibrary"))
            let meeting = try await library.createMeeting(title: "Native", status: .ready)
            try await MeetingNotesStore(layout: library.layout).setNotes(meeting.id, to: "same")
            let export = try await MeetingTransferExportService(library: library).export(
                meetingID: meeting.id,
                selectedAudioAssetIDs: [],
                temporaryRoot: root.appending(path: "NativeExport"),
                sourceAppVersion: nil
            )
            let jobStore = try JobStore(layout: library.layout)
            let didMutate = Mutex(false)
            let service = MeetingTransferImportService(
                library: library,
                jobStore: jobStore,
                importCheckpoint: { checkpoint in
                    guard checkpoint == .afterNativeMatchMaterialized else { return }
                    try didMutate.withLock { mutated in
                        guard !mutated else { return }
                        try Data("changed".utf8).write(
                            to: library.layout.userNotes(meeting.id),
                            options: .atomic
                        )
                        mutated = true
                    }
                }
            )
            let prepared = try await service.prepareImport(at: export.packageURL)

            await #expect(throws: LibraryError.self) {
                try await service.importPrepared(
                    sessionID: prepared.sessionID,
                    choice: .importOnly
                )
            }
            #expect(didMutate.withLock { $0 })
            #expect(try await MeetingNotesStore(layout: library.layout)
                .notes(meeting.id) == "changed")
            #expect(try await jobStore.list().isEmpty)
        }
    }
}

private struct ImportPackageFixture: Sendable {
    let url: URL
    let meetingID: MeetingID
    let sourceRevisionID: RevisionID?
    let audioSHA256: String?
    let audioBytes: Data?
}

private struct ReorderedAudioImportPackage: Sendable {
    let url: URL
    let meetingID: MeetingID
    let firstBytes: Data
    let secondBytes: Data
}

private struct ImportTarget: Sendable {
    let library: Library
    let jobStore: JobStore
}

private enum ImportServiceTestError: Error {
    case injected
}

private func makeImportTarget(at root: URL) async throws -> ImportTarget {
    let library = try Library.open(at: root.appending(path: "TargetLibrary"))
    return ImportTarget(
        library: library,
        jobStore: try JobStore(layout: library.layout)
    )
}

private func makeImportPackage(
    at root: URL,
    meetingID: MeetingID = MeetingID(),
    title: String = "Transfer",
    notes: String? = "Notiz",
    localeIdentifier: String? = "de-DE",
    localeOrigin: MeetingTransferLocaleOrigin = .explicit,
    includeAudio: Bool = false,
    includeTranscript: Bool = true,
    logicalTrackID: String = "track-1"
) async throws -> ImportPackageFixture {
    let sourceRevisionID = includeTranscript ? RevisionID() : nil
    let transcript: MeetingTransferTranscriptSnapshot? = if includeTranscript {
        try MeetingTransferTranscriptSnapshot(
            localeIdentifier: localeIdentifier,
            localeOrigin: localeOrigin,
            speakers: [
                try .init(id: "speaker-1", label: "Ada", kind: .confirmedDisplayName),
            ],
            turns: [
                .init(
                    speakerID: "speaker-1",
                    start: 0,
                    end: 1,
                    segments: [
                        .init(
                            text: "Hallo",
                            start: 0,
                            end: 1,
                            words: [.init(text: "Hallo", start: 0, end: 1)]
                        ),
                    ]
                ),
            ]
        )
    } else {
        nil
    }
    var audioDocuments: [MeetingTransferAudioDocument] = []
    var bindings: [MeetingTransferAudioSourceBinding] = []
    var audioBytes: Data?
    var audioSHA256: String?
    if includeAudio {
        let audioURL = root.appending(path: "audio-\(UUID().uuidString).caf")
        try makePipelineTestCAF(at: audioURL)
        let inspection = try MeetingTransferAudioInspector().inspectCAFSource(at: audioURL)
        let digest = try await MeetingTransferDigest.sha256(of: audioURL)
        audioDocuments = [try MeetingTransferAudioDocument(
            logicalTrackID: logicalTrackID,
            kind: .micTrack,
            byteCount: inspection.byteCount,
            sha256: digest,
            sampleRate: inspection.sampleRate,
            channelCount: inspection.channelCount,
            duration: inspection.duration
        )]
        bindings = [.init(logicalTrackID: logicalTrackID, sourceURL: audioURL)]
        audioBytes = try Data(contentsOf: audioURL)
        audioSHA256 = digest
    }
    let content = try MeetingTransferPackageContent(
        meeting: try MeetingTransferMeetingDocument(
            sourceMeetingID: meetingID,
            title: title,
            createdAt: Date(timeIntervalSinceReferenceDate: 123),
            sourceStatus: .ready
        ),
        notes: notes,
        transcript: transcript,
        audio: audioDocuments
    )
    let packageRoot = root.appending(path: "Package-\(UUID().uuidString)")
    let url = try await MeetingTransferArchiveWriter().write(
        content,
        audioSources: bindings,
        sourceRevisionID: sourceRevisionID,
        sourceAppVersion: "Steno/Test",
        to: packageRoot
    )
    return ImportPackageFixture(
        url: url,
        meetingID: meetingID,
        sourceRevisionID: sourceRevisionID,
        audioSHA256: audioSHA256,
        audioBytes: audioBytes
    )
}

private func makeReorderedAudioImportPackage(
    at root: URL
) async throws -> ReorderedAudioImportPackage {
    let meetingID = MeetingID()
    let firstURL = root.appending(path: "ordered-first.caf")
    let secondURL = root.appending(path: "ordered-second.caf")
    try makePipelineTestCAF(at: firstURL, frameCount: 80, sampleOffset: 1)
    try makePipelineTestCAF(at: secondURL, frameCount: 240, sampleOffset: 3)
    let firstBytes = try Data(contentsOf: firstURL)
    let secondBytes = try Data(contentsOf: secondURL)
    let firstInspection = try MeetingTransferAudioInspector().inspectCAFSource(at: firstURL)
    let secondInspection = try MeetingTransferAudioInspector().inspectCAFSource(at: secondURL)
    let firstDocument = try MeetingTransferAudioDocument(
        logicalTrackID: "logical-first",
        kind: .micTrack,
        byteCount: Int64(firstBytes.count),
        sha256: importTestSHA256(firstBytes),
        sampleRate: firstInspection.sampleRate,
        channelCount: firstInspection.channelCount,
        duration: firstInspection.duration
    )
    let secondDocument = try MeetingTransferAudioDocument(
        logicalTrackID: "logical-second",
        kind: .systemTrack,
        byteCount: Int64(secondBytes.count),
        sha256: importTestSHA256(secondBytes),
        sampleRate: secondInspection.sampleRate,
        channelCount: secondInspection.channelCount,
        duration: secondInspection.duration
    )
    let payload: [(path: String, data: Data, mediaType: String)] = [
        (
            "meeting.json",
            try MeetingTransferMeetingDocument(
                sourceMeetingID: meetingID,
                title: "Reordered",
                createdAt: Date(timeIntervalSinceReferenceDate: 456),
                sourceStatus: .ready
            ).encodedData(),
            "application/json"
        ),
        ("audio/track-2.json", try secondDocument.encodedData(), "application/json"),
        ("audio/track-2.caf", secondBytes, "audio/x-caf"),
        ("audio/track-1.json", try firstDocument.encodedData(), "application/json"),
        ("audio/track-1.caf", firstBytes, "audio/x-caf"),
    ]
    let manifestEntries = payload.map {
        MeetingTransferManifest.Entry(
            path: $0.path,
            byteCount: Int64($0.data.count),
            mediaType: $0.mediaType,
            sha256: importTestSHA256($0.data)
        )
    }
    let manifest = try MeetingTransferManifest(
        sourceMeetingID: meetingID,
        sourceRevisionID: nil,
        exportedAt: Date(timeIntervalSinceReferenceDate: 789),
        sourceAppVersion: "Steno/Test",
        capabilities: [.audio],
        localeIdentifier: nil,
        localeOrigin: .absent,
        entries: manifestEntries,
        contentDigest: try MeetingTransferDigest.contentDigest(for: manifestEntries)
    )
    let url = root.appending(path: "reordered.stenomeeting")
    try writeImportTestRawArchive(
        [("manifest.json", try manifest.encodedData())]
            + payload.map { ($0.path, $0.data) },
        to: url
    )
    return ReorderedAudioImportPackage(
        url: url,
        meetingID: meetingID,
        firstBytes: firstBytes,
        secondBytes: secondBytes
    )
}

private func writeImportTestRawArchive(
    _ entries: [(path: String, data: Data)],
    to url: URL
) throws {
    var archive = Data()
    for entry in entries {
        let header = ArchiveHeader()
        header.append(.uint(
            key: ArchiveHeader.FieldKey("TYP"),
            value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)
        ))
        header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: entry.path))
        header.append(.uint(
            key: ArchiveHeader.FieldKey("SIZ"),
            value: UInt64(entry.data.count)
        ))
        header.append(.blob(
            key: ArchiveHeader.FieldKey("DAT"),
            size: UInt64(entry.data.count)
        ))
        header.withAAEncodedData { archive.append(contentsOf: $0) }
        archive.append(entry.data)
    }
    try archive.write(to: url)
    guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func importTestSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func validationSessions(in layout: LibraryLayout) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: layout.transferValidationRoot.path) else {
        return []
    }
    return try FileManager.default.contentsOfDirectory(
        at: layout.transferValidationRoot,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".stenomeeting-validation-") }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
