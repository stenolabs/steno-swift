import Darwin
import Foundation
import StenoDomain

public struct PreparedMediaImport: Sendable {
    public let asset: MediaAsset
    public let sourceDisposition: PreparedMediaSourceDisposition

    public init(asset: MediaAsset, sourceURL: URL) {
        self.asset = asset
        sourceDisposition = .copy(sourceURL)
    }

    public init(asset: MediaAsset, data: Data) {
        self.asset = asset
        sourceDisposition = .data(data)
    }

    public init(
        asset: MediaAsset,
        sourceDisposition: PreparedMediaSourceDisposition
    ) {
        self.asset = asset
        self.sourceDisposition = sourceDisposition
    }
}

public struct PreparedRunImport: Sendable {
    public let run: ProcessingRun
    public let artifactFileName: String
    public let artifactData: Data

    public init(
        run: ProcessingRun,
        artifactFileName: String,
        artifactData: Data
    ) {
        self.run = run
        self.artifactFileName = artifactFileName
        self.artifactData = artifactData
    }
}

public struct PreparedTemplateResultImport: Sendable {
    public let runID: RunID
    public let result: TemplateResult

    public init(runID: RunID, result: TemplateResult) {
        self.runID = runID
        self.result = result
    }
}

public struct PreparedMeetingNoteImport: Sendable {
    public let fileName: String
    public let data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

public struct PreparedMeetingImport: Sendable {
    public let meeting: Meeting
    public let media: [PreparedMediaImport]
    public let revision: TranscriptRevision?
    public let transferState: ImportedMeetingProcessingState?
    public let nativeMeetingMatch: NativeMeetingTransferMatch?
    public let runs: [PreparedRunImport]
    public let templateResults: [PreparedTemplateResultImport]
    public let notes: [PreparedMeetingNoteImport]
    public let reviewData: Data?

    public init(
        meeting: Meeting,
        media: [PreparedMediaImport],
        revision: TranscriptRevision?,
        transferState: ImportedMeetingProcessingState? = nil,
        nativeMeetingMatch: NativeMeetingTransferMatch? = nil,
        runs: [PreparedRunImport] = [],
        templateResults: [PreparedTemplateResultImport] = [],
        notes: [PreparedMeetingNoteImport] = [],
        reviewData: Data? = nil
    ) {
        self.meeting = meeting
        self.media = media
        self.revision = revision
        self.transferState = transferState
        self.nativeMeetingMatch = nativeMeetingMatch
        self.runs = runs
        self.templateResults = templateResults
        self.notes = notes
        self.reviewData = reviewData
    }
}

public extension Library {
    func meetingID(forProvenanceKey provenanceKey: String) throws -> MeetingID? {
        for meeting in try listMeetings() {
            if meeting.metadata?.legacyProvenanceKey == provenanceKey {
                return meeting.id
            }
            if try listMediaAssets(meetingID: meeting.id).contains(where: {
                $0.provenanceKey == provenanceKey
            }) {
                return meeting.id
            }
        }
        return nil
    }

    /// Schreibt ein vollständig vorbereitetes Meeting in ein verborgenes
    /// Staging-Verzeichnis und macht es erst durch einen atomaren Rename
    /// sichtbar. Ein zufälliges Geschwister-Token bindet das Verzeichnis vor
    /// dem ersten Nutzdaten-Write an seine Geräte- und Inode-Identität.
    @discardableResult
    func commitPreparedMeeting(
        _ prepared: PreparedMeetingImport
    ) throws -> PreparedMeetingCommitResult {
        try commitPreparedMeeting(prepared, checkpoint: { _, _ in })
    }

    /// Variante für zusammengesetzte Bibliotheksoperationen. Der Aufrufer
    /// besitzt bereits die exklusive Transaktion; diese Methode nimmt keinen
    /// zweiten Lock und darf daher nur innerhalb derselben benutzt werden.
    @discardableResult
    package func commitPreparedMeeting(
        _ prepared: PreparedMeetingImport,
        transaction: LibraryMutationTransaction
    ) throws -> PreparedMeetingCommitResult {
        try transaction.validate(layout: layout)
        return try commitPreparedMeetingWithoutMutationLock(
            prepared,
            checkpoint: { _, _ in },
            nativeSnapshotCheckpoint: { _ in },
            parentDirectorySynchronizer: { descriptor in
                guard Darwin.fsync(descriptor) == 0 else {
                    throw POSIXFailure(operation: "fsync meetings directory after import", code: errno)
                }
            },
            rollbackDirectorySynchronizer: { descriptor in
                guard Darwin.fsync(descriptor) == 0 else {
                    throw POSIXFailure(operation: "fsync meetings directory after import rollback", code: errno)
                }
            }
        )
    }

    @discardableResult
    internal func commitPreparedMeeting(
        _ prepared: PreparedMeetingImport,
        checkpoint: (PreparedMeetingImportCheckpoint, URL) throws -> Void,
        nativeSnapshotCheckpoint: NativeMeetingTransferSnapshotAction = { _ in },
        parentDirectorySynchronizer: (Int32) throws -> Void = { descriptor in
            guard Darwin.fsync(descriptor) == 0 else {
                throw POSIXFailure(
                    operation: "fsync meetings directory after import",
                    code: errno
                )
            }
        },
        rollbackDirectorySynchronizer: (Int32) throws -> Void = { descriptor in
            guard Darwin.fsync(descriptor) == 0 else {
                throw POSIXFailure(
                    operation: "fsync meetings directory after import rollback",
                    code: errno
                )
            }
        }
    ) throws -> PreparedMeetingCommitResult {
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try commitPreparedMeetingWithoutMutationLock(
                prepared,
                checkpoint: checkpoint,
                nativeSnapshotCheckpoint: nativeSnapshotCheckpoint,
                parentDirectorySynchronizer: parentDirectorySynchronizer,
                rollbackDirectorySynchronizer: rollbackDirectorySynchronizer
            )
        }
    }

    private func commitPreparedMeetingWithoutMutationLock(
        _ prepared: PreparedMeetingImport,
        checkpoint: (PreparedMeetingImportCheckpoint, URL) throws -> Void,
        nativeSnapshotCheckpoint: NativeMeetingTransferSnapshotAction,
        parentDirectorySynchronizer: (Int32) throws -> Void,
        rollbackDirectorySynchronizer: (Int32) throws -> Void
    ) throws -> PreparedMeetingCommitResult {
        try validate(prepared)
        if let receipt = prepared.meeting.metadata?.transferReceipt {
            switch try transferDecision(
                for: receipt,
                nativeMeetingMatch: prepared.nativeMeetingMatch,
                nativeSnapshotCheckpoint: nativeSnapshotCheckpoint
            ) {
            case .alreadyPresent(let meetingID, let importGenerationID):
                return .alreadyPresent(
                    meetingID,
                    importGenerationID: importGenerationID
                )
            case .conflict(let meetingID):
                throw LibraryError.meetingTransferConflict(
                    existingMeetingID: meetingID
                )
            case .new:
                break
            }
        }
        if let provenanceKey = prepared.meeting.metadata?.legacyProvenanceKey,
           let existingMeetingID = try meetingID(forProvenanceKey: provenanceKey) {
            throw LibraryError.duplicateProvenance(
                key: provenanceKey,
                existingMeetingID: existingMeetingID
            )
        }
        for media in prepared.media {
            if let existingMeetingID = try meetingID(
                forProvenanceKey: media.asset.provenanceKey
            ) {
                throw LibraryError.duplicateProvenance(
                    key: media.asset.provenanceKey,
                    existingMeetingID: existingMeetingID
                )
            }
        }

        let destination = layout.meetingDirectory(prepared.meeting.id)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            if prepared.meeting.metadata?.transferReceipt != nil {
                throw LibraryError.meetingTransferConflict(
                    existingMeetingID: prepared.meeting.id
                )
            }
            throw LibraryError.documentAlreadyExists(destination)
        }

        let recovery = try PreparedMeetingImportRecovery.recover(
            in: layout.meetingsDirectory
        )
        guard recovery.requiresAttention.isEmpty else {
            throw LibraryError.abandonedMeetingImportsRequireAttention(
                recovery.requiresAttention
            )
        }

        let parentDescriptor = try openValidatedMeetingsDirectory()
        defer { Darwin.close(parentDescriptor) }
        let ownership = try PreparedMeetingImportOwnership.reserve(
            in: layout.meetingsDirectory
        )
        let staging = ownership.stagingURL
        var stagingIdentity: PreparedMeetingImportDirectoryIdentity?
        do {
            try ownership.createStagingDirectory()
            let boundIdentity = try ownership.bindToStagingDirectory()
            stagingIdentity = boundIdentity
            try write(prepared, to: staging)
            try checkpoint(.beforeFileSynchronization, staging)
            try synchronizeStagedTree(at: staging)
            try checkpoint(.afterStagingSynchronization, staging)
            try checkpoint(.beforeVisibleRename, staging)
            try renameOwnedStaging(
                ownership,
                identity: boundIdentity,
                to: destination,
                parentDescriptor: parentDescriptor
            )
        } catch {
            do {
                try ownership.removeOwnedStagingDirectory(
                    expectedIdentity: stagingIdentity
                )
                try? ownership.removeOwnedToken()
            } catch {
                // Das Token bleibt absichtlich erhalten, solange das Staging
                // nicht identitätsgebunden entfernt werden konnte.
            }
            throw error
        }
        guard let stagingIdentity else {
            throw LibraryError.invalidPreparedMeetingImport(
                "missing staging identity after visible commit"
            )
        }

        do {
            try checkpoint(.afterVisibleRenameBeforeParentSynchronization, staging)
            try parentDirectorySynchronizer(parentDescriptor)
        } catch {
            switch rollbackVisibleImport(
                ownership,
                identity: stagingIdentity,
                destination: destination,
                parentDescriptor: parentDescriptor,
                rollbackDirectorySynchronizer: rollbackDirectorySynchronizer
            ) {
            case .rolledBack:
                do {
                    try ownership.removeOwnedStagingDirectory(
                        expectedIdentity: stagingIdentity
                    )
                    try? ownership.removeOwnedToken()
                } catch {
                    // Recovery benötigt das Token weiterhin für dieses Staging.
                }
                throw error
            case .committedOrVisibilityUnknown:
                try? ownership.removeOwnedToken()
                return .imported(
                    prepared.meeting.id,
                    importGenerationID: prepared.meeting.metadata?
                        .transferReceipt?.importGenerationID
                )
            case .rollbackDurabilityUnknown:
                // Im aktuellen Namespace liegt die exakte Identität wieder
                // im Staging. Ohne Parent-fsync bleibt nach einem Hard-Crash
                // aber offen, welche Rename-Seite dauerhaft ist. Das Token
                // bleibt für beide zulässigen Recovery-Ausgänge erhalten.
                return .commitOutcomeUncertain(
                    prepared.meeting.id,
                    importGenerationID: prepared.meeting.metadata?
                        .transferReceipt?.importGenerationID
                )
            case .originalNoLongerVisible:
                try? ownership.removeOwnedToken()
                throw error
            }
        }

        try? ownership.removeOwnedToken()
        return .imported(
            prepared.meeting.id,
            importGenerationID: prepared.meeting.metadata?
                .transferReceipt?.importGenerationID
        )
    }

    /// Ersetzt Datei und Metadaten eines bestehenden Assets unter derselben
    /// Asset-ID. Die neue Datei wird zuerst vollständig in das Media-Verzeichnis
    /// geschrieben. Der atomare Metadaten-Rename ist der Sichtbarkeitspunkt:
    /// Bis dahin verweist das Asset weiter auf die unveränderte alte Datei.
    func replaceMediaAssetAtomically(
        _ prepared: PreparedMediaImport
    ) throws -> MediaAsset {
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try replaceMediaAssetAtomicallyWithoutMutationLock(prepared)
        }
    }

    private func replaceMediaAssetAtomicallyWithoutMutationLock(
        _ prepared: PreparedMediaImport
    ) throws -> MediaAsset {
        let replacement = prepared.asset
        _ = try loadMeeting(replacement.meetingID)
        let existing = try loadMediaAsset(
            replacement.id,
            meetingID: replacement.meetingID
        )
        guard existing.meetingID == replacement.meetingID,
              existing.id == replacement.id,
              existing.kind == replacement.kind,
              existing.provenanceKey == replacement.provenanceKey else {
            throw LibraryError.invalidPreparedMeetingImport(
                "replacement media identity mismatch"
            )
        }
        try validateFileName(existing.fileName)
        try validateFileName(replacement.fileName)
        guard existing.fileName != replacement.fileName else {
            throw LibraryError.invalidPreparedMeetingImport(
                "replacement media must use a new file name"
            )
        }

        let mediaDirectory = layout.mediaDirectory(replacement.meetingID)
        let destination = layout.mediaFile(
            replacement.meetingID,
            fileName: replacement.fileName
        )
        let temporaryMedia = mediaDirectory.appendingPathComponent(
            ".media-replacement-\(replacement.id)-\(UUID().uuidString).tmp"
        )
        guard case .copy(let sourceURL) = prepared.sourceDisposition else {
            throw LibraryError.invalidPreparedMeetingImport(
                "media replacement requires a copy source"
            )
        }
        try FileManager.default.copyItem(
            at: sourceURL,
            to: temporaryMedia
        )

        let metadataWrite: AtomicFile.PreparedWrite
        do {
            try synchronizeFile(at: temporaryMedia)
            metadataWrite = try AtomicFile.prepare(
                try encodedMediaAsset(replacement),
                to: layout.mediaMetadata(
                    replacement.meetingID,
                    assetID: replacement.id
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryMedia)
            throw error
        }

        do {
            try renameFile(from: temporaryMedia, to: destination)
            try synchronizeDirectory(at: mediaDirectory)
        } catch {
            try? FileManager.default.removeItem(at: temporaryMedia)
            try? FileManager.default.removeItem(at: metadataWrite.temporaryURL)
            throw error
        }

        do {
            try metadataWrite.commit()
        } catch {
            // commit() kann erst nach dem Metadaten-Rename beim fsync werfen.
            // Deshalb bleiben ab hier alte und neue Audiodatei erhalten: Egal
            // welche Metadaten-Version sichtbar ist, ihr Ziel existiert.
            try? FileManager.default.removeItem(at: metadataWrite.temporaryURL)
            throw error
        }

        try? FileManager.default.removeItem(
            at: layout.mediaFile(
                existing.meetingID,
                fileName: existing.fileName
            )
        )
        return replacement
    }

    private func validate(_ prepared: PreparedMeetingImport) throws {
        if let revision = prepared.revision,
           revision.meetingID != prepared.meeting.id {
            throw LibraryError.invalidPreparedMeetingImport("revision meeting mismatch")
        }
        guard prepared.media.allSatisfy({ $0.asset.meetingID == prepared.meeting.id }) else {
            throw LibraryError.invalidPreparedMeetingImport("media meeting mismatch")
        }
        guard prepared.runs.allSatisfy({ $0.run.meetingID == prepared.meeting.id }) else {
            throw LibraryError.invalidPreparedMeetingImport("run meeting mismatch")
        }
        let provenanceKeys = prepared.media.map(\.asset.provenanceKey)
        guard Set(provenanceKeys).count == provenanceKeys.count else {
            throw LibraryError.invalidPreparedMeetingImport("duplicate media provenance")
        }
        for media in prepared.media {
            try validateFileName(media.asset.fileName)
            if case .cloneValidatedDescriptor(let source) = media.sourceDisposition {
                try source.validateExpectations()
            }
        }
        for run in prepared.runs {
            try validateFileName(run.artifactFileName)
        }
        for note in prepared.notes {
            try validateFileName(note.fileName)
        }

        if let receipt = prepared.meeting.metadata?.transferReceipt {
            guard receipt.sourceMeetingID == prepared.meeting.id else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "transfer source meeting mismatch"
                )
            }
            guard prepared.meeting.status == .ready,
                  prepared.meeting.participantIDs.isEmpty,
                  prepared.meeting.additionalParticipantIDs.isEmpty,
                  prepared.meeting.folderID == nil,
                  prepared.meeting.metadata?.legacyProvenanceKey == nil,
                  prepared.meeting.metadata?.legacyFolders.isEmpty == true else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "unsafe transfer meeting metadata"
                )
            }
            guard let transferState = prepared.transferState else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "transfer state is required"
                )
            }
            try MeetingTransferStateStore.validate(
                transferState,
                meetingID: prepared.meeting.id,
                receipt: receipt
            )
            if case .processingRequested(let request) = transferState {
                guard let receiptGenerationID = receipt.importGenerationID,
                      request.importGenerationID == receiptGenerationID else {
                    throw LibraryError.invalidPreparedMeetingImport(
                        "processing request requires the receipt generation"
                    )
                }
            }
            if let revision = prepared.revision {
                guard case .meetingTransfer(let sourceMeetingID, let sourceRevisionID)
                    = revision.origin,
                      sourceMeetingID == receipt.sourceMeetingID,
                      sourceRevisionID == receipt.sourceRevisionID else {
                    throw LibraryError.invalidPreparedMeetingImport(
                        "transfer revision provenance mismatch"
                    )
                }
            }
            if let nativeMeetingMatch = prepared.nativeMeetingMatch {
                guard nativeMeetingMatch.meetingID == receipt.sourceMeetingID,
                      nativeMeetingMatch.contentDigest
                        == receipt.sourcePackageContentDigest,
                      nativeMeetingMatch.snapshotToken.meetingID
                        == receipt.sourceMeetingID else {
                    throw LibraryError.invalidPreparedMeetingImport(
                        "native meeting match does not describe the transfer source"
                    )
                }
            }
        } else {
            guard prepared.transferState == nil else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "transfer state without receipt"
                )
            }
            guard prepared.nativeMeetingMatch == nil else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "native meeting match without transfer receipt"
                )
            }
            guard prepared.revision != nil else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "legacy import requires a revision"
                )
            }
            guard prepared.media.allSatisfy({
                if case .copy = $0.sourceDisposition { return true }
                if case .data = $0.sourceDisposition { return true }
                return false
            }) else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "descriptor media requires a transfer receipt"
                )
            }
        }
    }

    private func validateFileName(_ fileName: String) throws {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/") else {
            throw LibraryError.invalidPreparedMeetingImport("unsafe file name")
        }
    }

    private func write(
        _ prepared: PreparedMeetingImport,
        to staging: URL
    ) throws {
        let mediaDirectory = staging.appendingPathComponent("media", isDirectory: true)
        let runsDirectory = staging.appendingPathComponent("runs", isDirectory: true)
        let notesDirectory = staging.appendingPathComponent("notes", isDirectory: true)
        let reportsDirectory = staging.appendingPathComponent("reports", isDirectory: true)
        let transcriptDirectory = staging.appendingPathComponent(
            "transcript",
            isDirectory: true
        )
        let revisionsDirectory = transcriptDirectory.appendingPathComponent(
            "revisions",
            isDirectory: true
        )
        let directories = [
            mediaDirectory,
            runsDirectory,
            notesDirectory,
            reportsDirectory,
            revisionsDirectory,
        ]
        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        try JSONDocumentStore.write(
            prepared.meeting,
            to: staging.appendingPathComponent("meeting.json")
        )
        if case .processingRequested = prepared.transferState {
            guard let receipt = prepared.meeting.metadata?.transferReceipt else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "transfer commit guard requires a receipt"
                )
            }
            try MeetingTransferStateStore.writeCommitPendingGuard(
                meetingID: prepared.meeting.id,
                receipt: receipt,
                to: staging.appendingPathComponent(
                    layout.transferCommitPending(prepared.meeting.id).lastPathComponent
                )
            )
        }
        for media in prepared.media {
            switch media.sourceDisposition {
            case .copy(let sourceURL):
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: mediaDirectory.appendingPathComponent(media.asset.fileName)
                )
            case .data(let data):
                try AtomicFile.write(
                    data,
                    to: mediaDirectory.appendingPathComponent(media.asset.fileName)
                )
            case .cloneValidatedDescriptor(let source):
                try PreparedMediaDescriptorCloner.clone(
                    source,
                    to: mediaDirectory,
                    fileName: media.asset.fileName
                )
            }
            try JSONDocumentStore.write(
                media.asset,
                to: mediaDirectory.appendingPathComponent("\(media.asset.id).json")
            )
        }

        if let revision = prepared.revision {
            try JSONDocumentStore.write(
                revision,
                to: revisionsDirectory.appendingPathComponent("\(revision.id).json")
            )
            try JSONDocumentStore.write(
                CurrentRevisionPointer(currentRevisionID: revision.id),
                to: transcriptDirectory.appendingPathComponent("current.json")
            )
        }

        for runImport in prepared.runs {
            let directory = runsDirectory.appendingPathComponent(
                runImport.run.id.description,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try JSONDocumentStore.write(
                runImport.run,
                to: directory.appendingPathComponent("run.json")
            )
            try AtomicFile.write(
                runImport.artifactData,
                to: directory.appendingPathComponent(runImport.artifactFileName)
            )
        }
        for report in prepared.templateResults {
            try JSONDocumentStore.write(
                report.result,
                to: reportsDirectory.appendingPathComponent("\(report.runID).json")
            )
        }
        for note in prepared.notes {
            try AtomicFile.write(
                note.data,
                to: notesDirectory.appendingPathComponent(note.fileName)
            )
        }
        if let reviewData = prepared.reviewData {
            try AtomicFile.write(
                reviewData,
                to: staging.appendingPathComponent("review.json")
            )
        }
        if let transferState = prepared.transferState {
            guard let receipt = prepared.meeting.metadata?.transferReceipt else {
                throw LibraryError.invalidPreparedMeetingImport(
                    "transfer state without receipt"
                )
            }
            try MeetingTransferStateStore.write(
                transferState,
                meetingID: prepared.meeting.id,
                receipt: receipt,
                to: staging.appending(path: "transfer-state.json")
            )
        }
    }

    private func openValidatedMeetingsDirectory() throws -> Int32 {
        let descriptor = layout.meetingsDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open meetings directory", code: errno)
        }
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              layout.meetingsDirectory.path.withCString({
                  lstat($0, &pathStatus)
              }) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            Darwin.close(descriptor)
            throw LibraryError.invalidPreparedMeetingImport(
                "meetings directory identity mismatch"
            )
        }
        return descriptor
    }

    private func renameOwnedStaging(
        _ ownership: PreparedMeetingImportOwnership,
        identity: PreparedMeetingImportDirectoryIdentity,
        to destination: URL,
        parentDescriptor: Int32
    ) throws {
        try validateMeetingsDirectory(
            descriptor: parentDescriptor
        )
        guard entry(
            ownership.stagingURL.lastPathComponent,
            in: parentDescriptor,
            matches: identity
        ) else {
            throw LibraryError.invalidPreparedMeetingImport(
                "staging identity changed before commit"
            )
        }
        let result = renameatx_np(
            parentDescriptor,
            ownership.stagingURL.lastPathComponent,
            parentDescriptor,
            destination.lastPathComponent,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
        )
        guard result == 0 else {
            throw POSIXFailure(operation: "rename meeting import", code: errno)
        }
    }

    private func rollbackVisibleImport(
        _ ownership: PreparedMeetingImportOwnership,
        identity: PreparedMeetingImportDirectoryIdentity,
        destination: URL,
        parentDescriptor: Int32,
        rollbackDirectorySynchronizer: (Int32) throws -> Void
    ) -> VisibleImportRollbackOutcome {
        var destinationStatus = stat()
        guard fstatat(
            parentDescriptor,
            destination.lastPathComponent,
            &destinationStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return errno == ENOENT
                ? .originalNoLongerVisible
                : .committedOrVisibilityUnknown
        }
        guard destinationStatus.st_mode & S_IFMT == S_IFDIR,
              UInt64(destinationStatus.st_dev) == identity.deviceID,
              UInt64(destinationStatus.st_ino) == identity.fileID else {
            return .originalNoLongerVisible
        }
        let result = renameatx_np(
            parentDescriptor,
            destination.lastPathComponent,
            parentDescriptor,
            ownership.stagingURL.lastPathComponent,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
        )
        guard result == 0 else {
            return .committedOrVisibilityUnknown
        }
        do {
            try rollbackDirectorySynchronizer(parentDescriptor)
        } catch {
            return .rollbackDurabilityUnknown
        }
        return .rolledBack
    }

    private func validateMeetingsDirectory(descriptor: Int32) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              layout.meetingsDirectory.path.withCString({
                  lstat($0, &pathStatus)
              }) == 0,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              pathStatus.st_mode & S_IFMT == S_IFDIR else {
            throw LibraryError.invalidPreparedMeetingImport(
                "meetings directory changed before commit"
            )
        }
    }

    private func entry(
        _ name: String,
        in parentDescriptor: Int32,
        matches identity: PreparedMeetingImportDirectoryIdentity
    ) -> Bool {
        var status = stat()
        return fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0
            && status.st_mode & S_IFMT == S_IFDIR
            && UInt64(status.st_dev) == identity.deviceID
            && UInt64(status.st_ino) == identity.fileID
    }

    private func encodedMediaAsset(_ asset: MediaAsset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(asset)
    }

    private func synchronizeFile(at url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open replacement media", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXFailure(operation: "fsync replacement media", code: errno)
        }
    }

    private func renameFile(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXFailure(operation: "rename replacement media", code: errno)
        }
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXFailure(operation: "open media directory", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXFailure(operation: "fsync media directory", code: errno)
        }
    }

    private func synchronizeStagedTree(at staging: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw LibraryError.invalidPreparedMeetingImport("cannot enumerate staging")
        }
        var directories = [staging]
        while let entry = enumerator.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw LibraryError.invalidPreparedMeetingImport("symbolic link in staging")
            }
            if values.isDirectory == true {
                directories.append(entry)
            } else if values.isRegularFile == true {
                try synchronizeFile(at: entry)
            } else {
                throw LibraryError.invalidPreparedMeetingImport("special file in staging")
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            try synchronizeDirectory(at: directory)
        }
    }
}

private enum VisibleImportRollbackOutcome {
    case rolledBack
    case rollbackDurabilityUnknown
    case committedOrVisibilityUnknown
    case originalNoLongerVisible
}

private enum MeetingTransferCommitDecision {
    case new
    case alreadyPresent(MeetingID, MeetingTransferGenerationID?)
    case conflict(MeetingID)
}

private extension Library {
    func transferDecision(
        for incoming: MeetingTransferReceipt,
        nativeMeetingMatch: NativeMeetingTransferMatch?,
        nativeSnapshotCheckpoint: NativeMeetingTransferSnapshotAction
    ) throws -> MeetingTransferCommitDecision {
        var identicalMeeting: (MeetingID, MeetingTransferGenerationID?)?
        for existing in try listMeetings() {
            if existing.id == incoming.sourceMeetingID {
                guard let receipt = existing.metadata?.transferReceipt else {
                    let currentSnapshot = try nativeMeetingTransferSnapshotTokenWithoutLock(
                        for: existing.id,
                        checkpoint: nativeSnapshotCheckpoint
                    )
                    guard let nativeMeetingMatch,
                          nativeMeetingMatch.meetingID == existing.id,
                          nativeMeetingMatch.contentDigest
                            == incoming.sourcePackageContentDigest,
                          nativeMeetingMatch.snapshotToken
                            == currentSnapshot
                    else {
                        return .conflict(existing.id)
                    }
                    return .alreadyPresent(existing.id, nil)
                }
                guard receipt.sourceMeetingID == incoming.sourceMeetingID else {
                    return .conflict(existing.id)
                }
            }
            guard let receipt = existing.metadata?.transferReceipt,
                  receipt.sourceMeetingID == incoming.sourceMeetingID else {
                continue
            }
            guard receipt.sourcePackageContentDigest
                    == incoming.sourcePackageContentDigest else {
                return .conflict(existing.id)
            }
            identicalMeeting = (existing.id, receipt.importGenerationID)
        }
        if let identicalMeeting {
            return .alreadyPresent(identicalMeeting.0, identicalMeeting.1)
        }
        return .new
    }
}
