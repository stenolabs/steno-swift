import Darwin
import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary

public enum MeetingTransferImportDisposition: Equatable, Sendable {
    case new
    case alreadyPresent(MeetingID)
    case conflict(MeetingID)
}

public enum MeetingTransferProcessingChoice: Equatable, Sendable {
    case importOnly
    case process(
        localeIdentifier: String,
        languageConfirmed: Bool,
        modelsReady: Bool
    )
}

public struct MeetingTransferImportPreview: Sendable {
    public let sourceMeetingID: MeetingID
    public let transportDigest: String
    public let contentDigest: String
    public let title: String
    public let createdAt: Date
    public let capabilities: Set<MeetingTransferCapability>
    public let visibleSpeakerLabels: [String]
    public let audioTracks: [AudioTrack]
    public let localeIdentifier: String?
    public let localeOrigin: MeetingTransferLocaleOrigin
    public let disposition: MeetingTransferImportDisposition

    public struct AudioTrack: Sendable {
        public let label: String
        public let byteCount: Int64

        public init(label: String, byteCount: Int64) {
            self.label = label
            self.byteCount = byteCount
        }
    }
}

public struct MeetingTransferPreparedImport: Sendable {
    public let sessionID: UUID
    public let preview: MeetingTransferImportPreview

    public init(sessionID: UUID, preview: MeetingTransferImportPreview) {
        self.sessionID = sessionID
        self.preview = preview
    }
}

public enum MeetingTransferImportResult: Equatable, Sendable {
    case imported(MeetingID)
    case alreadyPresent(MeetingID)
    case pendingRecovery(MeetingID)
}

public enum MeetingTransferImportError: Error, Equatable, Sendable {
    case sessionNotFound(UUID)
    case sessionInUse(UUID)
    case transportDigestChanged
    case conflict(MeetingID)
    case generationConflict(MeetingID)
    case languageConfirmationRequired
    case invalidLocaleIdentifier
    case noAudioForProcessing(MeetingID)
    case validationRootIsOnDifferentVolume
    case preparationCleanupRequired(UUID)
    case cleanupRequired(
        sessionID: UUID,
        committedResult: MeetingTransferImportResult
    )
}

enum MeetingTransferImportCheckpoint: Equatable, Sendable {
    case beforeSecondValidation(URL)
    case afterNativeMatchMaterialized
    case beforeLibraryCommit
    case afterLibraryCommitBeforeReconcile
}

typealias MeetingTransferImportAction = @Sendable (
    MeetingTransferImportCheckpoint
) throws -> Void
typealias MeetingTransferCommitAction = @Sendable (
    PreparedMeetingImport
) async throws -> PreparedMeetingCommitResult

public actor MeetingTransferImportService {
    private struct ActiveSession: Sendable {
        enum Phase: Equatable, Sendable {
            case prepared
            case importing
            case cleanupPending
        }

        let preview: MeetingTransferImportPreview?
        var packages: [ValidatedMeetingTransferPackage]
        var cleanupHandles: [MeetingTransferCleanupHandle]
        let freshRetryToken: MeetingTransferFreshImportRetryToken?
        var phase: Phase
    }

    private struct CurrentDisposition: Sendable {
        let value: MeetingTransferImportDisposition
        let nativeMatch: NativeMeetingTransferMatch?
    }

    private let library: Library
    private let jobStore: JobStore
    private let reader: MeetingTransferArchiveReader
    private let exportService: MeetingTransferExportService
    private let stateStore: MeetingTransferStateStore
    private let reconciler: ImportedMeetingProcessingReconciler
    private let importAction: MeetingTransferImportAction
    private let commitAction: MeetingTransferCommitAction
    private let now: @Sendable () -> Date
    private var sessions: [UUID: ActiveSession] = [:]
    private var didRunStartSweep = false

    public init(library: Library, jobStore: JobStore) {
        self.library = library
        self.jobStore = jobStore
        reader = MeetingTransferArchiveReader()
        exportService = MeetingTransferExportService(library: library)
        stateStore = MeetingTransferStateStore(layout: library.layout)
        reconciler = ImportedMeetingProcessingReconciler(
            library: library,
            stateStore: stateStore,
            jobStore: jobStore
        )
        importAction = { _ in }
        commitAction = { prepared in
            try await library.commitPreparedMeeting(prepared)
        }
        now = Date.init
    }

    init(
        library: Library,
        jobStore: JobStore,
        testingReader reader: MeetingTransferArchiveReader = MeetingTransferArchiveReader(),
        importCheckpoint: @escaping MeetingTransferImportAction = { _ in },
        commitPrepared: MeetingTransferCommitAction? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.library = library
        self.jobStore = jobStore
        self.reader = reader
        exportService = MeetingTransferExportService(library: library)
        stateStore = MeetingTransferStateStore(layout: library.layout)
        reconciler = ImportedMeetingProcessingReconciler(
            library: library,
            stateStore: stateStore,
            jobStore: jobStore
        )
        importAction = importCheckpoint
        commitAction = commitPrepared ?? { prepared in
            try await library.commitPreparedMeeting(prepared)
        }
        self.now = now
    }

    public func prepareImport(
        at externalURL: URL,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void = { _ in }
    ) async throws -> MeetingTransferPreparedImport {
        try prepareValidationRootIfNeeded()
        let package: ValidatedMeetingTransferPackage
        do {
            package = try await reader.validate(
                at: externalURL,
                validationRoot: library.layout.transferValidationRoot,
                progress: progress
            )
        } catch let error as MeetingTransferCleanupRequired {
            let sessionID = UUID()
            sessions[sessionID] = ActiveSession(
                preview: nil,
                packages: [],
                cleanupHandles: [error.cleanupHandle],
                freshRetryToken: nil,
                phase: .cleanupPending
            )
            throw MeetingTransferImportError.preparationCleanupRequired(sessionID)
        }
        do {
            let current = try await currentDisposition(for: package)
            let freshRetryToken = try await stateStore.freshImportRetryToken(
                package.manifest.sourceMeetingID
            )
            let preview = try Self.preview(package: package, disposition: current.value)
            let sessionID = UUID()
            sessions[sessionID] = ActiveSession(
                preview: preview,
                packages: [package],
                cleanupHandles: [],
                freshRetryToken: freshRetryToken,
                phase: .prepared
            )
            return MeetingTransferPreparedImport(
                sessionID: sessionID,
                preview: preview
            )
        } catch {
            let preparationError = error
            do {
                try package.close()
            } catch {
                let sessionID = UUID()
                sessions[sessionID] = ActiveSession(
                    preview: nil,
                    packages: [package],
                    cleanupHandles: [],
                    freshRetryToken: nil,
                    phase: .cleanupPending
                )
                throw MeetingTransferImportError.preparationCleanupRequired(sessionID)
            }
            throw preparationError
        }
    }

    public func importPrepared(
        sessionID: UUID,
        choice: MeetingTransferProcessingChoice,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void = { _ in }
    ) async throws -> MeetingTransferImportResult {
        guard var active = sessions[sessionID] else {
            throw MeetingTransferImportError.sessionNotFound(sessionID)
        }
        guard active.phase == .prepared else {
            throw MeetingTransferImportError.sessionInUse(sessionID)
        }
        guard let preview = active.preview else {
            throw MeetingTransferImportError.sessionInUse(sessionID)
        }
        active.phase = .importing
        sessions[sessionID] = active

        do {
            let original = active.packages[0]
            try importAction(.beforeSecondValidation(original.snapshotURL))
            let package: ValidatedMeetingTransferPackage
            do {
                package = try await reader.revalidate(original, progress: progress)
            } catch let error as MeetingTransferCleanupRequired {
                active.cleanupHandles.append(error.cleanupHandle)
                active.phase = .cleanupPending
                sessions[sessionID] = active
                throw error.originalError
            }
            active.packages.append(package)
            sessions[sessionID] = active
            guard package.transportDigest == preview.transportDigest else {
                throw MeetingTransferImportError.transportDigestChanged
            }

            let current = try await currentDisposition(for: package)
            if current.nativeMatch != nil {
                try importAction(.afterNativeMatchMaterialized)
            }
            if case .conflict(let meetingID) = current.value {
                throw MeetingTransferImportError.conflict(meetingID)
            }
            let processingWithoutAudio: Bool
            if case .process = choice, package.audio.isEmpty {
                processingWithoutAudio = true
            } else {
                processingWithoutAudio = false
            }
            let importGenerationID = active.freshRetryToken?.importGenerationID
                ?? MeetingTransferGenerationID()
            let transferState = processingWithoutAudio
                ? ImportedMeetingProcessingState.importedOnly
                : try processingState(
                    for: choice,
                    package: package,
                    importGenerationID: importGenerationID
                )
            let prepared = try Self.preparedMeeting(
                package: package,
                transferState: transferState,
                nativeMeetingMatch: current.nativeMatch,
                importedAt: now(),
                importGenerationID: importGenerationID
            )

            try importAction(.beforeLibraryCommit)
            let commitResult = try await commitAction(prepared)
            let result: MeetingTransferImportResult
            switch commitResult {
            case .imported(let meetingID, let committedGenerationID):
                guard committedGenerationID == importGenerationID else {
                    throw MeetingTransferImportError.generationConflict(meetingID)
                }
                if case .processingRequested = transferState {
                    do {
                        try await stateStore.clearFreshImportRetryRequirement(
                            meetingID,
                            expectedImportGenerationID: importGenerationID,
                            expectedSourcePackageContentDigest: package.manifest.contentDigest,
                            expectedState: transferState
                        )
                    } catch LibraryError.transferImportGenerationConflict {
                        throw MeetingTransferImportError.generationConflict(meetingID)
                    }
                }
                if case .processingRequested = transferState {
                    try importAction(.afterLibraryCommitBeforeReconcile)
                    try await reconciler.reconcile(meetingID: meetingID)
                }
                result = .imported(meetingID)
            case .alreadyPresent(let meetingID, let committedGenerationID):
                if let expected = active.freshRetryToken {
                    guard committedGenerationID == expected.importGenerationID,
                          expected.sourcePackageContentDigest
                            == package.manifest.contentDigest else {
                        throw MeetingTransferImportError.generationConflict(meetingID)
                    }
                    let resolved: Bool
                    do {
                        resolved = try await stateStore.resolveFreshImportRetry(
                            transferState,
                            for: meetingID,
                            expected: expected
                        )
                    } catch LibraryError.transferImportGenerationConflict {
                        throw MeetingTransferImportError.generationConflict(meetingID)
                    }
                    if resolved, case .processingRequested = transferState {
                        try importAction(.afterLibraryCommitBeforeReconcile)
                        try await reconciler.reconcile(meetingID: meetingID)
                    }
                }
                result = .alreadyPresent(meetingID)
            case .commitOutcomeUncertain(let meetingID, let committedGenerationID):
                guard committedGenerationID == importGenerationID else {
                    throw MeetingTransferImportError.generationConflict(meetingID)
                }
                // Recovery plus a fresh retry must resolve this namespace
                // outcome before any logical processing request is enqueued.
                result = .pendingRecovery(meetingID)
            }
            do {
                try cleanupSession(sessionID)
            } catch {
                throw MeetingTransferImportError.cleanupRequired(
                    sessionID: sessionID,
                    committedResult: result
                )
            }
            if processingWithoutAudio {
                throw MeetingTransferImportError.noAudioForProcessing(
                    package.manifest.sourceMeetingID
                )
            }
            return result
        } catch {
            let importError = error
            if let session = sessions[sessionID],
               case .cleanupPending = session.phase {
                throw importError
            }
            do {
                try cleanupSession(sessionID)
            } catch {
                throw error
            }
            throw importError
        }
    }

    public func discardPrepared(sessionID: UUID) throws {
        guard let session = sessions[sessionID] else {
            throw MeetingTransferImportError.sessionNotFound(sessionID)
        }
        guard session.phase == .prepared || session.phase == .cleanupPending else {
            throw MeetingTransferImportError.sessionInUse(sessionID)
        }
        try cleanupSession(sessionID)
    }

    private func prepareValidationRootIfNeeded() throws {
        guard !didRunStartSweep else { return }
        _ = try MeetingTransferPrivateRoot.prepareAndVerify(
            at: library.layout.transferValidationRoot
        )
        var validationStatus = stat()
        var meetingsStatus = stat()
        guard lstat(library.layout.transferValidationRoot.path, &validationStatus) == 0,
              lstat(library.layout.meetingsDirectory.path, &meetingsStatus) == 0,
              validationStatus.st_dev == meetingsStatus.st_dev else {
            throw MeetingTransferImportError.validationRootIsOnDifferentVolume
        }
        try reader.recoverAbandonedSessions(
            validationRoot: library.layout.transferValidationRoot
        )
        didRunStartSweep = true
    }

    private func cleanupSession(_ sessionID: UUID) throws {
        guard var session = sessions[sessionID] else { return }
        do {
            for handle in session.cleanupHandles.reversed() {
                try handle.close()
            }
            for package in session.packages.reversed() {
                try package.close()
            }
        } catch {
            session.phase = .cleanupPending
            sessions[sessionID] = session
            throw error
        }
        sessions.removeValue(forKey: sessionID)
    }

    private func currentDisposition(
        for package: ValidatedMeetingTransferPackage
    ) async throws -> CurrentDisposition {
        let meetingID = package.manifest.sourceMeetingID
        let digest = package.manifest.contentDigest
        for existing in try await library.listMeetings() {
            if let receipt = existing.metadata?.transferReceipt,
               receipt.sourceMeetingID == meetingID {
                let value: MeetingTransferImportDisposition =
                    receipt.sourcePackageContentDigest == digest
                    ? .alreadyPresent(existing.id)
                    : .conflict(existing.id)
                return CurrentDisposition(value: value, nativeMatch: nil)
            }
            guard existing.id == meetingID else { continue }
            guard existing.metadata?.transferReceipt == nil else {
                return CurrentDisposition(
                    value: .conflict(existing.id),
                    nativeMatch: nil
                )
            }
            let match = try await exportService.nativeMeetingTransferMatch(for: package)
            return CurrentDisposition(
                value: match.contentDigest == digest
                    ? .alreadyPresent(existing.id)
                    : .conflict(existing.id),
                nativeMatch: match
            )
        }
        return CurrentDisposition(value: .new, nativeMatch: nil)
    }

    private func processingState(
        for choice: MeetingTransferProcessingChoice,
        package: ValidatedMeetingTransferPackage,
        importGenerationID: MeetingTransferGenerationID
    ) throws -> ImportedMeetingProcessingState {
        switch choice {
        case .importOnly:
            return package.manifest.localeOrigin == .explicit
                ? .importedOnly
                : .awaitingLanguageConfirmation
        case .process(let localeIdentifier, let languageConfirmed, let modelsReady):
            let locale = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !locale.isEmpty,
                  locale == localeIdentifier,
                  !locale.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw MeetingTransferImportError.invalidLocaleIdentifier
            }
            guard languageConfirmed else {
                throw MeetingTransferImportError.languageConfirmationRequired
            }
            guard modelsReady else {
                return .awaitingModel(localeIdentifier: locale)
            }
            return .processingRequested(ImportedProcessingRequest(
                id: MeetingTransferRequestID(),
                jobID: JobID(),
                meetingID: package.manifest.sourceMeetingID,
                localeIdentifier: locale,
                createdAt: now(),
                importGenerationID: importGenerationID
            ))
        }
    }

    private static func preview(
        package: ValidatedMeetingTransferPackage,
        disposition: MeetingTransferImportDisposition
    ) throws -> MeetingTransferImportPreview {
        let audioTracks = try package.audio.enumerated().map { offset, audio in
            let path = "audio/track-\(offset + 1).caf"
            guard let entry = package.manifest.entries.first(where: { $0.path == path }) else {
                throw MeetingTransferValidationError.invalidManifest
            }
            return MeetingTransferImportPreview.AudioTrack(
                label: ChannelLabel.trackName(audio.kind.rawValue),
                byteCount: entry.byteCount
            )
        }
        return MeetingTransferImportPreview(
            sourceMeetingID: package.manifest.sourceMeetingID,
            transportDigest: package.transportDigest,
            contentDigest: package.manifest.contentDigest,
            title: package.meeting.title,
            createdAt: package.meeting.createdAt,
            capabilities: package.manifest.capabilities,
            visibleSpeakerLabels: package.transcript?.speakers.map(\.label) ?? [],
            audioTracks: audioTracks,
            localeIdentifier: package.manifest.localeIdentifier,
            localeOrigin: package.manifest.localeOrigin,
            disposition: disposition
        )
    }

    private static func preparedMeeting(
        package: ValidatedMeetingTransferPackage,
        transferState: ImportedMeetingProcessingState,
        nativeMeetingMatch: NativeMeetingTransferMatch?,
        importedAt: Date,
        importGenerationID: MeetingTransferGenerationID
    ) throws -> PreparedMeetingImport {
        let meetingID = package.manifest.sourceMeetingID
        let receipt = MeetingTransferReceipt(
            sourceMeetingID: meetingID,
            sourceRevisionID: package.manifest.sourceRevisionID,
            sourcePackageContentDigest: package.manifest.contentDigest,
            importedAt: importedAt,
            sourceAppVersion: package.manifest.sourceAppVersion,
            includedCapabilities: package.manifest.capabilities,
            sourceLocaleIdentifier: package.manifest.localeIdentifier,
            sourceLocaleOrigin: package.manifest.localeOrigin,
            importGenerationID: importGenerationID
        )
        let meeting = Meeting(
            id: meetingID,
            title: package.meeting.title,
            createdAt: package.meeting.createdAt,
            status: .ready,
            participantIDs: [],
            additionalParticipantIDs: [],
            folderID: nil,
            metadata: MeetingMetadata(transferReceipt: receipt),
            sourceLocale: package.manifest.sourceLocale
        )
        let media = try package.audio.enumerated().map { offset, audio in
            let number = offset + 1
            let path = "audio/track-\(number).caf"
            guard let entry = package.manifest.entries.first(where: { $0.path == path }) else {
                throw MeetingTransferValidationError.invalidManifest
            }
            let assetID = MediaAssetID()
            let asset = MediaAsset(
                id: assetID,
                meetingID: meetingID,
                kind: audio.kind,
                sampleRate: audio.sampleRate,
                duration: audio.duration,
                provenanceKey: "transfer:\(meetingID):track-\(number):\(audio.byteSHA256)",
                fileName: "\(assetID).caf"
            )
            let source = PreparedDescriptorBackedMediaSource(
                expectedByteCount: entry.byteCount,
                expectedSHA256: audio.byteSHA256,
                acquire: {
                    let exchangeLease = try audio.leaseSource()
                    return PreparedMediaDescriptorLease(
                        sourceURL: exchangeLease.sourceURL,
                        close: { exchangeLease.close() }
                    )
                }
            )
            return PreparedMediaImport(
                asset: asset,
                sourceDisposition: .cloneValidatedDescriptor(source)
            )
        }
        let notes = package.notes.map {
            [PreparedMeetingNoteImport(
                fileName: "user-notes.md",
                data: Data($0.utf8)
            )]
        } ?? []
        return PreparedMeetingImport(
            meeting: meeting,
            media: media,
            revision: try importedRevision(package: package),
            transferState: transferState,
            nativeMeetingMatch: nativeMeetingMatch,
            notes: notes
        )
    }

    private static func importedRevision(
        package: ValidatedMeetingTransferPackage
    ) throws -> TranscriptRevision? {
        guard let transcript = package.transcript else { return nil }
        var speakers: [String: SpeakerReference] = [:]
        for speaker in transcript.speakers {
            speakers[speaker.id] = .importedTextLabel(ImportedSpeakerTextLabel(
                id: UUID(),
                text: speaker.label,
                wasConfirmedAtSource: speaker.kind == .confirmedDisplayName
            ))
        }
        let turns = try transcript.turns.map { turn in
            let speaker: SpeakerReference?
            if let speakerID = turn.speakerID {
                guard let mapped = speakers[speakerID] else {
                    throw MeetingTransferValidationError.invalidPayload("transcript.json")
                }
                speaker = mapped
            } else {
                speaker = nil
            }
            return TranscriptTurn(
                speaker: speaker,
                start: turn.start,
                end: turn.end,
                segments: turn.segments.map { segment in
                    TranscriptSegment(
                        text: segment.text,
                        start: segment.start,
                        end: segment.end,
                        words: segment.words.map {
                            TranscriptWord(text: $0.text, start: $0.start, end: $0.end)
                        }
                    )
                }
            )
        }
        return TranscriptRevision(
            meetingID: package.manifest.sourceMeetingID,
            origin: .meetingTransfer(
                sourceMeetingID: package.manifest.sourceMeetingID,
                sourceRevisionID: package.manifest.sourceRevisionID
            ),
            turns: turns
        )
    }
}
