import AppleArchive
import CryptoKit
import Darwin
import Foundation
import StenoDomain
import System

public enum MeetingTransferStorageStage: String, Equatable, Sendable {
    case snapshot
    case entries
}

enum MeetingTransferWriteStage: Equatable, Sendable {
    case snapshot
    case entries
}

enum MeetingTransferValidationCheckpoint: Equatable, Sendable {
    case afterRawPreflight(Int32)
    case beforePayloadDecode
    case beforeAudio(Int)
    case beforeReturn
}

public enum MeetingTransferValidationError: Error, Equatable, Sendable {
    case privateRootCreationFailed
    case privateRootIsSymbolicLink
    case privateRootIsNotDirectory
    case privateRootHasWrongOwner
    case insecurePrivateRootPermissions
    case privateSessionCreationFailed
    case archiveOpenFailed
    case archiveIsSymbolicLink
    case archiveIsNotRegularFile
    case transportFileExceedsLimit
    case insufficientCapacity(MeetingTransferStorageStage)
    case storageWriteFailed
    case sourceChangedDuringSnapshot
    case stagedFileIdentityMismatch(String)
    case sessionInUse
    case cleanupFailed(String)
    case cleanupIdentityMismatch(String)
    case notRawAppleArchive
    case missingManifest
    case trailingGarbage
    case parserDifferential(Int)
    case unsupportedEntryType(String)
    case unsupportedHeaderField(String)
    case duplicateHeaderField(String)
    case invalidHeaderFieldType(String)
    case missingHeaderField(String)
    case invalidDataOffset(String)
    case sizeMismatch(String)
    case integerOverflow(String)
    case invalidEntryPath(String)
    case casePathCollision(String)
    case unicodePathCollision(String)
    case duplicateArchiveEntryPath(String)
    case fileCountExceedsLimit
    case entryTooLarge(String)
    case totalBytesExceedLimit
    case truncatedData(String)
    case extraFile(String)
    case missingFile(String)
    case invalidManifest
    case unsupportedFormatMajor(Int)
    case hashMismatch(String)
    case contentDigestMismatch
    case invalidPayload(String)
    case unsupportedAudio(String)
    case emptyAudio(String)
    case audioMetadataMismatch(String)
}

public final class MeetingTransferCleanupHandle: @unchecked Sendable {
    public let sessionIdentity: String

    private let session: MeetingTransferPrivateSession

    fileprivate init(session: MeetingTransferPrivateSession) {
        sessionIdentity = session.name
        self.session = session
    }

    public func close() throws {
        try session.cleanup()
    }
}

public struct MeetingTransferCleanupRequired: Error, @unchecked Sendable {
    public let originalError: any Error
    public let cleanupHandle: MeetingTransferCleanupHandle

    fileprivate init(
        originalError: any Error,
        session: MeetingTransferPrivateSession
    ) {
        self.originalError = originalError
        cleanupHandle = MeetingTransferCleanupHandle(session: session)
    }
}

public final class ValidatedMeetingTransferPackage: @unchecked Sendable {
    public let manifest: MeetingTransferManifest
    public let meeting: MeetingTransferMeetingDocument
    public let notes: String?
    public let transcript: MeetingTransferTranscriptSnapshot?
    public let audio: [ValidatedMeetingTransferAudio]
    public let entryPaths: [String]
    public let transportDigest: String
    package let snapshotURL: URL
    let sessionDirectoryURL: URL

    private let session: MeetingTransferPrivateSession
    fileprivate let revalidationSource: MeetingTransferPackageRevalidationSource?

    fileprivate init(
        manifest: MeetingTransferManifest,
        meeting: MeetingTransferMeetingDocument,
        notes: String?,
        transcript: MeetingTransferTranscriptSnapshot?,
        audio: [ValidatedMeetingTransferAudio],
        entryPaths: [String],
        transportDigest: String,
        snapshotURL: URL,
        session: MeetingTransferPrivateSession,
        revalidationSource: MeetingTransferPackageRevalidationSource?
    ) {
        self.manifest = manifest
        self.meeting = meeting
        self.notes = notes
        self.transcript = transcript
        self.audio = audio
        self.entryPaths = entryPaths
        self.transportDigest = transportDigest
        self.snapshotURL = snapshotURL
        self.sessionDirectoryURL = session.url
        self.session = session
        self.revalidationSource = revalidationSource
    }

    public func close() throws {
        try session.cleanup {
            for audio in self.audio {
                audio.closeSource()
            }
        }
    }
}

fileprivate struct MeetingTransferPackageRevalidationSource: Sendable {
    let session: MeetingTransferPrivateSession
    let fileName: String
    let identity: MeetingTransferFileIdentity
    let byteCount: Int64
}

public struct MeetingTransferArchiveReader: Sendable {
    typealias CapacityCheck = @Sendable (MeetingTransferStorageStage, Int64) throws -> Void
    typealias SnapshotDidCopy = @Sendable (Int64) throws -> Void
    typealias BeforeWrite = @Sendable (MeetingTransferWriteStage, Int) throws -> Void
    typealias ValidationCheckpoint = @Sendable (MeetingTransferValidationCheckpoint) throws -> Void

    private let injectedCapacityCheck: CapacityCheck?
    private let snapshotDidCopy: SnapshotDidCopy
    private let beforeWrite: BeforeWrite
    private let validationCheckpoint: ValidationCheckpoint
    private let cleanupAction: MeetingTransferCleanupAction
    private let namespaceAction: MeetingTransferNamespaceAction

    public init() {
        injectedCapacityCheck = nil
        snapshotDidCopy = { _ in }
        beforeWrite = { _, _ in }
        validationCheckpoint = { _ in }
        cleanupAction = { _ in }
        namespaceAction = { _ in }
    }

    public func recoverAbandonedSessions(validationRoot: URL) throws {
        try MeetingTransferPrivateRoot.prepareAndVerify(
            at: validationRoot,
            cleanupAction: cleanupAction,
            namespaceCheckpoint: namespaceAction
        ).recoverAbandonedSessions()
    }

    init(
        capacityCheck: CapacityCheck? = nil,
        snapshotDidCopy: @escaping SnapshotDidCopy = { _ in },
        beforeWrite: @escaping BeforeWrite = { _, _ in },
        validationCheckpoint: @escaping ValidationCheckpoint = { _ in },
        cleanupAction: @escaping MeetingTransferCleanupAction = { _ in },
        namespaceCheckpoint: @escaping MeetingTransferNamespaceAction = { _ in }
    ) {
        injectedCapacityCheck = capacityCheck
        self.snapshotDidCopy = snapshotDidCopy
        self.beforeWrite = beforeWrite
        self.validationCheckpoint = validationCheckpoint
        self.cleanupAction = cleanupAction
        namespaceAction = namespaceCheckpoint
    }

    public func validate(
        at packageURL: URL,
        validationRoot: URL,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void = { _ in }
    ) async throws -> ValidatedMeetingTransferPackage {
        try Task.checkCancellation()
        let root = try MeetingTransferPrivateRoot.prepareAndVerify(
            at: validationRoot,
            cleanupAction: cleanupAction,
            namespaceCheckpoint: namespaceAction
        )
        let session = try root.createSession()

        do {
            let externalDescriptor = try Self.openExternalArchive(at: packageURL)
            defer { externalDescriptor.close() }

            var status = stat()
            guard fstat(externalDescriptor.rawValue, &status) == 0 else {
                throw MeetingTransferValidationError.archiveOpenFailed
            }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw MeetingTransferValidationError.archiveIsNotRegularFile
            }
            guard status.st_size >= 0 else {
                throw MeetingTransferValidationError.archiveIsNotRegularFile
            }
            let outerSize = Int64(status.st_size)
            guard outerSize <= MeetingTransferLimits.maximumTransportFileBytes else {
                throw MeetingTransferValidationError.transportFileExceedsLimit
            }

            try checkCapacity(.snapshot, payloadBytes: outerSize, directoryFD: session.directoryFileDescriptor)
            let snapshotName = "snapshot.stenomeeting"
            let snapshotDescriptor = try session.createFile(named: snapshotName)
            defer { snapshotDescriptor.close() }
            let transportDigest = try copyAndHashSnapshot(
                sourceFD: externalDescriptor.rawValue,
                expectedSize: outerSize,
                destinationFD: snapshotDescriptor.rawValue,
                progress: progress
            )
            guard fsync(snapshotDescriptor.rawValue) == 0 else {
                throw MeetingTransferValidationError.storageWriteFailed
            }
            guard lseek(snapshotDescriptor.rawValue, 0, SEEK_SET) == 0 else {
                throw MeetingTransferValidationError.storageWriteFailed
            }
            var snapshotStatus = stat()
            guard fstat(snapshotDescriptor.rawValue, &snapshotStatus) == 0 else {
                throw MeetingTransferValidationError.storageWriteFailed
            }
            let snapshotIdentity = MeetingTransferFileIdentity(snapshotStatus)

            return try parseOwnedArchive(
                archiveFD: snapshotDescriptor.rawValue,
                snapshotURL: session.url.appendingPathComponent(snapshotName),
                transportDigest: transportDigest,
                session: session,
                revalidationSource: MeetingTransferPackageRevalidationSource(
                    session: session,
                    fileName: snapshotName,
                    identity: snapshotIdentity,
                    byteCount: outerSize
                ),
                progress: progress
            )
        } catch {
            let validationError = error
            do {
                try session.cleanup()
            } catch {
                throw MeetingTransferCleanupRequired(
                    originalError: validationError,
                    session: session
                )
            }
            throw validationError
        }
    }

    /// Revalidates the private snapshot retained by a prepared preview. The
    /// external package path is never opened again. Parsing uses a fresh
    /// private entry session while the original snapshot session is leased,
    /// so snapshot and audio hashes are checked again without another full
    /// snapshot copy.
    public func revalidate(
        _ package: ValidatedMeetingTransferPackage,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void = { _ in }
    ) async throws -> ValidatedMeetingTransferPackage {
        guard let source = package.revalidationSource else {
            throw MeetingTransferValidationError.archiveOpenFailed
        }
        try Task.checkCancellation()
        let sourceLease = try source.session.acquireLease()
        defer { sourceLease.close() }
        let descriptor = try source.session.openVerifiedReadDescriptor(
            named: source.fileName,
            identity: source.identity
        )
        defer { descriptor.close() }
        let root = try MeetingTransferPrivateRoot.prepareAndVerify(
            at: source.session.root.url,
            cleanupAction: cleanupAction,
            namespaceCheckpoint: namespaceAction
        )
        let revalidationSession = try root.createSession()
        do {
            let transportDigest = try Self.hashDescriptor(
                descriptor.rawValue,
                expectedSize: source.byteCount,
                progress: progress
            )
            guard lseek(descriptor.rawValue, 0, SEEK_SET) == 0 else {
                throw MeetingTransferValidationError.archiveOpenFailed
            }
            return try parseOwnedArchive(
                archiveFD: descriptor.rawValue,
                snapshotURL: package.snapshotURL,
                transportDigest: transportDigest,
                session: revalidationSession,
                revalidationSource: source,
                progress: progress
            )
        } catch {
            let validationError = error
            do {
                try revalidationSession.cleanup()
            } catch {
                throw MeetingTransferCleanupRequired(
                    originalError: validationError,
                    session: revalidationSession
                )
            }
            throw validationError
        }
    }

    func validateOwnedSnapshot(
        fileDescriptor: Int32,
        archiveURL: URL,
        within root: MeetingTransferPrivateRoot,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void = { _ in }
    ) async throws -> ValidatedMeetingTransferPackage {
        try Task.checkCancellation()
        let standardized = archiveURL.standardizedFileURL
        guard standardized.deletingLastPathComponent() == root.url,
              MeetingTransferPrivateRoot.isOwnedName(standardized.lastPathComponent)
        else {
            throw MeetingTransferValidationError.archiveOpenFailed
        }

        var status = stat()
        guard fstat(fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o600,
              status.st_size >= 0
        else {
            throw MeetingTransferValidationError.archiveIsNotRegularFile
        }
        let byteCount = Int64(status.st_size)
        guard byteCount <= MeetingTransferLimits.maximumTransportFileBytes else {
            throw MeetingTransferValidationError.transportFileExceedsLimit
        }

        let session = try root.createSession()
        do {
            let digest = try Self.hashDescriptor(
                fileDescriptor,
                expectedSize: byteCount,
                progress: progress
            )
            guard lseek(fileDescriptor, 0, SEEK_SET) == 0 else {
                throw MeetingTransferValidationError.archiveOpenFailed
            }
            return try parseOwnedArchive(
                archiveFD: fileDescriptor,
                snapshotURL: standardized,
                transportDigest: digest,
                session: session,
                revalidationSource: nil,
                progress: progress
            )
        } catch {
            let validationError = error
            do {
                try session.cleanup()
            } catch {
                throw MeetingTransferCleanupRequired(
                    originalError: validationError,
                    session: session
                )
            }
            throw validationError
        }
    }

    private static func openExternalArchive(at url: URL) throws -> MeetingTransferOwnedDescriptor {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw MeetingTransferValidationError.archiveIsSymbolicLink
            }
            throw MeetingTransferValidationError.archiveOpenFailed
        }
        return MeetingTransferOwnedDescriptor(descriptor)
    }

    private func copyAndHashSnapshot(
        sourceFD: Int32,
        expectedSize: Int64,
        destinationFD: Int32,
        progress: @Sendable (MeetingTransferProgress) -> Void
    ) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: MeetingTransferDigest.fileReadChunkSize)
        var total: Int64 = 0

        while true {
            try Task.checkCancellation()
            let count = try Self.readSome(sourceFD, into: &buffer)
            guard count > 0 else { break }
            let (nextTotal, overflow) = total.addingReportingOverflow(Int64(count))
            guard !overflow, nextTotal <= MeetingTransferLimits.maximumTransportFileBytes else {
                throw MeetingTransferValidationError.transportFileExceedsLimit
            }
            guard nextTotal <= expectedSize else {
                throw MeetingTransferValidationError.sourceChangedDuringSnapshot
            }
            try beforeWrite(.snapshot, count)
            try Self.writeAll(destinationFD, bytes: buffer, count: count)
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
            }
            total = nextTotal
            try snapshotDidCopy(total)
            progress(.init(phase: .hashing, processedBytes: total, totalBytes: expectedSize))
        }

        guard total == expectedSize else {
            throw MeetingTransferValidationError.sourceChangedDuringSnapshot
        }
        try Task.checkCancellation()
        return Self.hex(hasher.finalize())
    }

    private static func hashDescriptor(
        _ fileDescriptor: Int32,
        expectedSize: Int64,
        progress: @Sendable (MeetingTransferProgress) -> Void
    ) throws -> String {
        guard lseek(fileDescriptor, 0, SEEK_SET) == 0 else {
            throw MeetingTransferValidationError.archiveOpenFailed
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: MeetingTransferDigest.fileReadChunkSize)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = try readSome(fileDescriptor, into: &buffer)
            guard count > 0 else { break }
            let (next, overflow) = total.addingReportingOverflow(Int64(count))
            guard !overflow, next <= MeetingTransferLimits.maximumTransportFileBytes else {
                throw MeetingTransferValidationError.transportFileExceedsLimit
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
            }
            total = next
            progress(.init(phase: .hashing, processedBytes: total, totalBytes: expectedSize))
        }
        guard total == expectedSize else {
            throw MeetingTransferValidationError.sourceChangedDuringSnapshot
        }
        try Task.checkCancellation()
        return hex(hasher.finalize())
    }

    private func parseOwnedArchive(
        archiveFD: Int32,
        snapshotURL: URL,
        transportDigest: String,
        session: MeetingTransferPrivateSession,
        revalidationSource: MeetingTransferPackageRevalidationSource?,
        progress: @Sendable (MeetingTransferProgress) -> Void
    ) throws -> ValidatedMeetingTransferPackage {
        try Self.requireRawArchiveMagic(archiveFD)
        let rawPreflight = try Self.preflightRawHeaders(archiveFD)
        try validationCheckpoint(.afterRawPreflight(archiveFD))
        guard lseek(archiveFD, 0, SEEK_SET) == 0 else {
            throw MeetingTransferValidationError.notRawAppleArchive
        }
        guard let byteStream = ArchiveByteStream.fileStream(
            fd: FileDescriptor(rawValue: archiveFD),
            automaticClose: false
        ), let archive = ArchiveStream.decodeStream(readingFrom: byteStream) else {
            throw MeetingTransferValidationError.notRawAppleArchive
        }
        defer {
            try? archive.close()
            try? byteStream.close()
        }

        var entryPaths: [String] = []
        var rawPaths: Set<String> = []
        var normalizedPaths: [String: String] = [:]
        var foldedPaths: [String: String] = [:]
        var staged: [String: StagedEntry] = [:]
        var manifest: MeetingTransferManifest?
        var expectedEntries: [String: MeetingTransferManifest.Entry] = [:]
        var totalBytes: Int64 = 0
        var completedHeaderCount = 0
        var decodedRawOffset: Int64 = 0

        while true {
            try Task.checkCancellation()
            let header: ArchiveHeader?
            do {
                header = try archive.readHeader()
            } catch {
                if completedHeaderCount == 0 {
                    throw MeetingTransferValidationError.notRawAppleArchive
                }
                throw MeetingTransferValidationError.trailingGarbage
            }
            guard let header else { break }

            let entryNumber = completedHeaderCount + 1
            guard entryNumber <= MeetingTransferLimits.maximumFileCount else {
                throw MeetingTransferValidationError.fileCountExceedsLimit
            }
            guard completedHeaderCount < rawPreflight.headers.count else {
                throw MeetingTransferValidationError.parserDifferential(entryNumber)
            }

            let decodedSummary: DecodedHeaderSummary
            do {
                decodedSummary = try Self.summarizeDecodedHeader(header)
            } catch {
                throw MeetingTransferValidationError.parserDifferential(entryNumber)
            }
            let expectedSummary = rawPreflight.headers[completedHeaderCount]
            let (decodedDataOffset, headerOverflow) = decodedRawOffset.addingReportingOverflow(
                Int64(decodedSummary.encodedHeader.count)
            )
            let (decodedDataEnd, dataOverflow) = decodedDataOffset.addingReportingOverflow(
                Int64(decodedSummary.parsed.size)
            )
            guard !headerOverflow,
                  !dataOverflow,
                  expectedSummary.encodedHeader == decodedSummary.encodedHeader,
                  expectedSummary.content == decodedSummary.content,
                  expectedSummary.headerOffset == decodedRawOffset,
                  expectedSummary.headerByteCount == decodedSummary.encodedHeader.count,
                  expectedSummary.dataOffset == decodedDataOffset,
                  expectedSummary.dataEnd == decodedDataEnd
            else {
                throw MeetingTransferValidationError.parserDifferential(entryNumber)
            }
            completedHeaderCount = entryNumber
            decodedRawOffset = decodedDataEnd

            let parsed = decodedSummary.parsed
            let path = parsed.path
            if completedHeaderCount == 1, path != "manifest.json" {
                throw MeetingTransferValidationError.missingManifest
            }
            try Self.validatePath(
                path,
                rawPaths: &rawPaths,
                normalizedPaths: &normalizedPaths,
                foldedPaths: &foldedPaths
            )
            guard Self.isPotentiallyAllowedPath(path) else {
                throw MeetingTransferValidationError.invalidEntryPath(path)
            }
            guard parsed.size <= UInt64(Int64.max) else {
                throw MeetingTransferValidationError.integerOverflow(path)
            }
            let byteCount = Int64(parsed.size)
            guard byteCount <= Self.maximumBytes(for: path) else {
                throw MeetingTransferValidationError.entryTooLarge(path)
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !overflow, nextTotal <= MeetingTransferLimits.maximumTotalBytes else {
                throw MeetingTransferValidationError.totalBytesExceedLimit
            }
            totalBytes = nextTotal

            if path != "manifest.json" {
                guard manifest != nil else {
                    throw MeetingTransferValidationError.missingManifest
                }
                guard let expected = expectedEntries[path] else {
                    throw MeetingTransferValidationError.extraFile(path)
                }
                guard expected.byteCount == byteCount else {
                    throw MeetingTransferValidationError.sizeMismatch(path)
                }
            }

            let fileName = String(format: "entry-%04d", completedHeaderCount)
            let entryDescriptor = try session.createFile(named: fileName)
            let readResult: ReadEntryResult
            do {
                readResult = try readEntry(
                    archive: archive,
                    key: parsed.dataKey,
                    byteCount: byteCount,
                    path: path,
                    destinationFD: entryDescriptor.rawValue,
                    progress: progress
                )
                guard fsync(entryDescriptor.rawValue) == 0 else {
                    throw MeetingTransferValidationError.storageWriteFailed
                }
            } catch {
                entryDescriptor.close()
                throw error
            }
            let audioSource: MeetingTransferValidatedAudioSource?
            if path.hasSuffix(".caf") {
                do {
                    let (readDescriptor, identity) = try session.openVerifiedReadDescriptor(
                        named: fileName,
                        matching: entryDescriptor.rawValue
                    )
                    try session.detachFile(
                        named: fileName,
                        matchingDescriptor: readDescriptor.rawValue
                    )
                    audioSource = MeetingTransferValidatedAudioSource(
                        descriptor: readDescriptor,
                        identity: identity,
                        byteCount: byteCount,
                        path: path,
                        expectedSHA256: readResult.sha256,
                        session: session
                    )
                } catch {
                    entryDescriptor.close()
                    throw error
                }
            } else {
                audioSource = nil
            }
            entryDescriptor.close()

            let value = StagedEntry(
                byteCount: byteCount,
                sha256: readResult.sha256,
                decodedBytes: readResult.decodedBytes,
                audioSource: audioSource
            )
            staged[path] = value
            entryPaths.append(path)

            if path == "manifest.json" {
                guard let manifestBytes = readResult.decodedBytes else {
                    throw MeetingTransferValidationError.invalidManifest
                }
                let decoded = try Self.decodeManifest(manifestBytes)
                manifest = decoded
                expectedEntries = Dictionary(uniqueKeysWithValues: decoded.entries.map { ($0.path, $0) })
                let declaredBytes = try Self.declaredPayloadBytes(in: decoded)
                try checkCapacity(
                    .entries,
                    payloadBytes: declaredBytes,
                    directoryFD: session.directoryFileDescriptor
                )
            } else if let expected = expectedEntries[path], expected.sha256 != readResult.sha256 {
                throw MeetingTransferValidationError.hashMismatch(path)
            }
        }

        guard completedHeaderCount == rawPreflight.headers.count,
              decodedRawOffset == rawPreflight.byteCount
        else {
            throw MeetingTransferValidationError.parserDifferential(completedHeaderCount + 1)
        }

        guard let manifest else {
            throw MeetingTransferValidationError.missingManifest
        }
        for entry in manifest.entries where staged[entry.path] == nil {
            throw MeetingTransferValidationError.missingFile(entry.path)
        }
        let actualDigest: String
        do {
            actualDigest = try MeetingTransferDigest.contentDigest(for: manifest.entries)
        } catch {
            throw MeetingTransferValidationError.invalidManifest
        }
        guard actualDigest == manifest.contentDigest else {
            throw MeetingTransferValidationError.contentDigestMismatch
        }

        try Task.checkCancellation()
        try validationCheckpoint(.beforePayloadDecode)
        try Task.checkCancellation()
        let payload = try Self.decodePayload(
            manifest: manifest,
            staged: staged,
            progress: progress,
            validationCheckpoint: validationCheckpoint
        )
        let result = ValidatedMeetingTransferPackage(
            manifest: manifest,
            meeting: payload.meeting,
            notes: payload.notes,
            transcript: payload.transcript,
            audio: payload.audio,
            entryPaths: entryPaths,
            transportDigest: transportDigest,
            snapshotURL: snapshotURL,
            session: session,
            revalidationSource: revalidationSource
        )
        try validationCheckpoint(.beforeReturn)
        for audio in result.audio {
            try audio.revalidateSource()
        }
        try Task.checkCancellation()
        return result
    }

    private func readEntry(
        archive: ArchiveStream,
        key: ArchiveHeader.FieldKey,
        byteCount: Int64,
        path: String,
        destinationFD: Int32,
        progress: @Sendable (MeetingTransferProgress) -> Void
    ) throws -> ReadEntryResult {
        var hasher = SHA256()
        var decodedBytes: Data? = path.hasSuffix(".caf") ? nil : Data()
        decodedBytes?.reserveCapacity(Int(byteCount))
        var remaining = byteCount
        var processed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: MeetingTransferDigest.fileReadChunkSize)

        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(Int64(buffer.count), remaining))
            do {
                try buffer.withUnsafeMutableBytes { raw in
                    try archive.readBlob(
                        key: key,
                        into: UnsafeMutableRawBufferPointer(rebasing: raw[..<count])
                    )
                }
            } catch {
                throw MeetingTransferValidationError.truncatedData(path)
            }
            try beforeWrite(.entries, count)
            try Self.writeAll(destinationFD, bytes: buffer, count: count)
            buffer.withUnsafeBytes { bytes in
                let chunk = UnsafeRawBufferPointer(rebasing: bytes[..<count])
                hasher.update(bufferPointer: chunk)
                decodedBytes?.append(chunk.bindMemory(to: UInt8.self))
            }
            remaining -= Int64(count)
            processed += Int64(count)
            progress(.init(phase: .readingArchive, processedBytes: processed, totalBytes: byteCount))
        }
        return ReadEntryResult(
            sha256: Self.hex(hasher.finalize()),
            decodedBytes: decodedBytes
        )
    }

    private func checkCapacity(
        _ stage: MeetingTransferStorageStage,
        payloadBytes: Int64,
        directoryFD: Int32
    ) throws {
        if let injectedCapacityCheck {
            try injectedCapacityCheck(stage, payloadBytes)
            return
        }
        let (required, overflow) = payloadBytes.addingReportingOverflow(
            MeetingTransferLimits.minimumFreeSpaceReserveBytes
        )
        guard payloadBytes >= 0, !overflow else {
            throw MeetingTransferValidationError.insufficientCapacity(stage)
        }
        var fileSystem = statfs()
        guard fstatfs(directoryFD, &fileSystem) == 0 else {
            throw MeetingTransferValidationError.insufficientCapacity(stage)
        }
        let available = UInt64(fileSystem.f_bavail).multipliedReportingOverflow(
            by: UInt64(fileSystem.f_bsize)
        )
        guard !available.overflow, available.partialValue >= UInt64(required) else {
            throw MeetingTransferValidationError.insufficientCapacity(stage)
        }
    }

    private static func parseHeader(_ header: ArchiveHeader) throws -> ParsedHeader {
        let allowed = Set(["TYP", "PAT", "SIZ", "DAT"])
        let expectedTypes: [String: ArchiveHeader.FieldType] = [
            "TYP": .uint,
            "PAT": .string,
            "SIZ": .uint,
            "DAT": .blob,
        ]
        var fields: [String: [ArchiveHeader.Field]] = [:]
        for field in header {
            let key = field.key.description
            guard allowed.contains(key) else {
                throw MeetingTransferValidationError.unsupportedHeaderField(key)
            }
            guard field.type == expectedTypes[key] else {
                throw MeetingTransferValidationError.invalidHeaderFieldType(key)
            }
            fields[key, default: []].append(field)
        }
        for key in ["TYP", "PAT", "SIZ", "DAT"] where fields[key] == nil {
            throw MeetingTransferValidationError.missingHeaderField(key)
        }

        let path: String
        if case let .string(_, value) = fields["PAT"]!.first! {
            path = value
        } else {
            throw MeetingTransferValidationError.invalidHeaderFieldType("PAT")
        }
        for field in fields["DAT"]! {
            if case let .blob(_, _, offset) = field, offset != 0 {
                throw MeetingTransferValidationError.invalidDataOffset(path)
            }
        }
        for key in ["TYP", "PAT", "SIZ", "DAT"] where fields[key]!.count != 1 {
            throw MeetingTransferValidationError.duplicateHeaderField(key)
        }

        let typeValue: UInt64
        if case let .uint(_, value) = fields["TYP"]![0] {
            typeValue = value
        } else {
            throw MeetingTransferValidationError.invalidHeaderFieldType("TYP")
        }
        guard typeValue == UInt64(ArchiveHeader.EntryType.regularFile.rawValue),
              header.entryType == .regularFile
        else {
            throw MeetingTransferValidationError.unsupportedEntryType(path)
        }

        let size: UInt64
        if case let .uint(_, value) = fields["SIZ"]![0] {
            size = value
        } else {
            throw MeetingTransferValidationError.invalidHeaderFieldType("SIZ")
        }
        let dataSize: UInt64
        let dataKey: ArchiveHeader.FieldKey
        if case let .blob(key, value, _) = fields["DAT"]![0] {
            dataKey = key
            dataSize = value
        } else {
            throw MeetingTransferValidationError.invalidHeaderFieldType("DAT")
        }
        guard size == dataSize else {
            throw MeetingTransferValidationError.sizeMismatch(path)
        }
        return ParsedHeader(path: path, size: size, dataKey: dataKey)
    }

    private static func validatePath(
        _ path: String,
        rawPaths: inout Set<String>,
        normalizedPaths: inout [String: String],
        foldedPaths: inout [String: String]
    ) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\"),
              parts.count <= MeetingTransferLimits.maximumDirectoryDepth,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw MeetingTransferValidationError.invalidEntryPath(path)
        }

        let normalized = path.precomposedStringWithCompatibilityMapping
        if let prior = normalizedPaths[normalized], prior != path {
            throw MeetingTransferValidationError.unicodePathCollision(path)
        }
        if normalized != path {
            throw MeetingTransferValidationError.unicodePathCollision(path)
        }
        let folded = normalized.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if let prior = foldedPaths[folded], prior != path {
            throw MeetingTransferValidationError.casePathCollision(path)
        }
        guard rawPaths.insert(path).inserted else {
            throw MeetingTransferValidationError.duplicateArchiveEntryPath(path)
        }
        normalizedPaths[normalized] = path
        foldedPaths[folded] = path
    }

    private static func isPotentiallyAllowedPath(_ path: String) -> Bool {
        switch path {
        case "manifest.json", "meeting.json", "notes.md", "transcript.json":
            return true
        default:
            guard path.hasPrefix("audio/track-") else { return false }
            let name = String(path.dropFirst("audio/track-".count))
            let components = name.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 2,
                  !components[0].isEmpty,
                  components[0].first != "0",
                  components[0].allSatisfy({ $0.isASCII && $0.isNumber }),
                  Int(components[0]) != nil
            else {
                return false
            }
            return components[1] == "caf" || components[1] == "json"
        }
    }

    private static func maximumBytes(for path: String) -> Int64 {
        switch path {
        case "manifest.json":
            return Int64(MeetingTransferLimits.maximumManifestBytes)
        case "meeting.json":
            return Int64(MeetingTransferLimits.maximumMeetingDocumentBytes)
        case "notes.md":
            return Int64(MeetingTransferLimits.maximumNotesBytes)
        case "transcript.json":
            return Int64(MeetingTransferLimits.maximumTranscriptBytes)
        default:
            return path.hasSuffix(".caf")
                ? MeetingTransferLimits.maximumAudioBytes
                : Int64(MeetingTransferLimits.maximumAudioMetadataBytes)
        }
    }

    private static func decodeManifest(_ data: Data) throws -> MeetingTransferManifest {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let major = object["formatMajor"] as? NSNumber,
           major.intValue != MeetingTransferManifest.currentMajor
        {
            throw MeetingTransferValidationError.unsupportedFormatMajor(major.intValue)
        }
        do {
            return try JSONDecoder().decode(MeetingTransferManifest.self, from: data)
        } catch let error as MeetingTransferContractError {
            if case let .unsupportedFormatMajor(major) = error {
                throw MeetingTransferValidationError.unsupportedFormatMajor(major)
            }
            throw MeetingTransferValidationError.invalidManifest
        } catch {
            throw MeetingTransferValidationError.invalidManifest
        }
    }

    private static func declaredPayloadBytes(in manifest: MeetingTransferManifest) throws -> Int64 {
        var result: Int64 = 0
        for entry in manifest.entries {
            let (next, overflow) = result.addingReportingOverflow(entry.byteCount)
            guard entry.byteCount >= 0, !overflow,
                  next <= MeetingTransferLimits.maximumTotalBytes
            else {
                throw MeetingTransferValidationError.totalBytesExceedLimit
            }
            result = next
        }
        return result
    }

    private static func decodePayload(
        manifest: MeetingTransferManifest,
        staged: [String: StagedEntry],
        progress: @Sendable (MeetingTransferProgress) -> Void,
        validationCheckpoint: ValidationCheckpoint
    ) throws -> DecodedPayload {
        guard let meetingEntry = staged["meeting.json"] else {
            throw MeetingTransferValidationError.missingFile("meeting.json")
        }
        let meeting: MeetingTransferMeetingDocument = try decodeJSON(
            MeetingTransferMeetingDocument.self,
            from: meetingEntry,
            path: "meeting.json"
        )
        let notes: String?
        if let noteEntry = staged["notes.md"] {
            guard let bytes = noteEntry.decodedBytes,
                  let value = String(data: bytes, encoding: .utf8)
            else {
                throw MeetingTransferValidationError.invalidPayload("notes.md")
            }
            notes = value
        } else {
            notes = nil
        }
        let transcript: MeetingTransferTranscriptSnapshot?
        if let transcriptEntry = staged["transcript.json"] {
            transcript = try decodeJSON(
                MeetingTransferTranscriptSnapshot.self,
                from: transcriptEntry,
                path: "transcript.json"
            )
        } else {
            transcript = nil
        }

        let cafPaths = manifest.entries.compactMap { entry -> (number: Int, path: String)? in
            guard entry.path.hasPrefix("audio/track-"),
                  entry.path.hasSuffix(".caf") else { return nil }
            let numberStart = entry.path.index(
                entry.path.startIndex,
                offsetBy: "audio/track-".count
            )
            let numberEnd = entry.path.index(entry.path.endIndex, offsetBy: -".caf".count)
            guard let number = Int(entry.path[numberStart..<numberEnd]) else { return nil }
            return (number, entry.path)
        }.sorted { $0.number < $1.number }.map(\.path)
        var documents: [MeetingTransferAudioDocument] = []
        var validatedAudio: [ValidatedMeetingTransferAudio] = []
        var logicalIDs: Set<String> = []
        for (offset, cafPath) in cafPaths.enumerated() {
            try Task.checkCancellation()
            try validationCheckpoint(.beforeAudio(offset))
            try Task.checkCancellation()
            let metadataPath = String(cafPath.dropLast(4)) + ".json"
            guard let caf = staged[cafPath],
                  let audioSource = caf.audioSource,
                  let metadata = staged[metadataPath]
            else {
                throw MeetingTransferValidationError.invalidPayload(cafPath)
            }
            let document: MeetingTransferAudioDocument = try decodeJSON(
                MeetingTransferAudioDocument.self,
                from: metadata,
                path: metadataPath
            )
            guard logicalIDs.insert(document.logicalTrackID).inserted,
                  document.byteCount == caf.byteCount,
                  document.sha256 == caf.sha256
            else {
                throw MeetingTransferValidationError.invalidPayload(metadataPath)
            }
            documents.append(document)
            progress(.init(
                phase: .validatingAudio,
                processedBytes: Int64(offset),
                totalBytes: Int64(cafPaths.count)
            ))
            validatedAudio.append(try MeetingTransferAudioInspector().inspect(
                source: audioSource,
                document: document,
                byteSHA256: caf.sha256
            ))
        }

        let content: MeetingTransferPackageContent
        do {
            content = try MeetingTransferPackageContent(
                meeting: meeting,
                notes: notes,
                transcript: transcript,
                audio: documents,
                sourceLocale: manifest.sourceLocale
            )
        } catch {
            throw MeetingTransferValidationError.invalidPayload("package")
        }
        guard meeting.sourceMeetingID == manifest.sourceMeetingID,
              content.capabilities == manifest.capabilities,
              content.sourceLocale == manifest.sourceLocale
        else {
            throw MeetingTransferValidationError.invalidPayload("manifest")
        }
        return DecodedPayload(
            meeting: meeting,
            notes: notes,
            transcript: transcript,
            audio: validatedAudio
        )
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from entry: StagedEntry,
        path: String
    ) throws -> T {
        guard let data = entry.decodedBytes else {
            throw MeetingTransferValidationError.invalidPayload(path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as MeetingTransferValidationError {
            throw error
        } catch {
            throw MeetingTransferValidationError.invalidPayload(path)
        }
    }

    private static func requireRawArchiveMagic(_ fileDescriptor: Int32) throws {
        var magic = [UInt8](repeating: 0, count: 4)
        let count = magic.withUnsafeMutableBytes { pread(fileDescriptor, $0.baseAddress, 4, 0) }
        guard count == 4, magic == Array("AA01".utf8) else {
            throw MeetingTransferValidationError.notRawAppleArchive
        }
    }

    private static func preflightRawHeaders(_ fileDescriptor: Int32) throws -> RawArchivePreflight {
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0, status.st_size >= 0 else {
            throw MeetingTransferValidationError.notRawAppleArchive
        }
        let fileSize = Int64(status.st_size)
        var offset: Int64 = 0
        var headerCount = 0
        var totalBytes: Int64 = 0
        var rawPaths: Set<String> = []
        var normalizedPaths: [String: String] = [:]
        var foldedPaths: [String: String] = [:]
        var summaries: [RawHeaderSummary] = []

        while offset < fileSize {
            let prefix = try preadExactly(
                fileDescriptor,
                byteCount: 6,
                offset: offset,
                error: .trailingGarbage
            )
            guard prefix[0...3].elementsEqual("AA01".utf8) else {
                if headerCount == 0 {
                    throw MeetingTransferValidationError.notRawAppleArchive
                }
                throw MeetingTransferValidationError.trailingGarbage
            }
            let headerByteCount = Int(prefix[4]) | (Int(prefix[5]) << 8)
            guard headerByteCount >= 6 else {
                throw MeetingTransferValidationError.trailingGarbage
            }
            let headerBytes = try preadExactly(
                fileDescriptor,
                byteCount: headerByteCount,
                offset: offset,
                error: .trailingGarbage
            )
            guard let header = headerBytes.withUnsafeBufferPointer({
                ArchiveHeader(withAAEncodedData: $0)
            }) else {
                throw MeetingTransferValidationError.trailingGarbage
            }

            headerCount += 1
            guard headerCount <= MeetingTransferLimits.maximumFileCount else {
                throw MeetingTransferValidationError.fileCountExceedsLimit
            }
            let parsed = try parseHeader(header)
            if headerCount == 1, parsed.path != "manifest.json" {
                throw MeetingTransferValidationError.missingManifest
            }
            try validatePath(
                parsed.path,
                rawPaths: &rawPaths,
                normalizedPaths: &normalizedPaths,
                foldedPaths: &foldedPaths
            )
            guard isPotentiallyAllowedPath(parsed.path) else {
                throw MeetingTransferValidationError.invalidEntryPath(parsed.path)
            }
            guard parsed.size <= UInt64(Int64.max) else {
                throw MeetingTransferValidationError.integerOverflow(parsed.path)
            }
            let byteCount = Int64(parsed.size)
            guard byteCount <= maximumBytes(for: parsed.path) else {
                throw MeetingTransferValidationError.entryTooLarge(parsed.path)
            }
            let (nextTotal, totalOverflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !totalOverflow, nextTotal <= MeetingTransferLimits.maximumTotalBytes else {
                throw MeetingTransferValidationError.totalBytesExceedLimit
            }
            totalBytes = nextTotal

            let (dataOffset, headerOverflow) = offset.addingReportingOverflow(
                Int64(headerByteCount)
            )
            let (nextOffset, dataOverflow) = dataOffset.addingReportingOverflow(byteCount)
            guard !headerOverflow, !dataOverflow, nextOffset <= fileSize else {
                throw MeetingTransferValidationError.truncatedData(parsed.path)
            }
            summaries.append(RawHeaderSummary(
                encodedHeader: Data(headerBytes),
                content: summarizeHeaderContent(header, parsed: parsed),
                headerOffset: offset,
                headerByteCount: headerByteCount,
                dataOffset: dataOffset,
                dataEnd: nextOffset
            ))
            offset = nextOffset
        }
        return RawArchivePreflight(headers: summaries, byteCount: fileSize)
    }

    private static func summarizeDecodedHeader(
        _ header: ArchiveHeader
    ) throws -> DecodedHeaderSummary {
        let parsed = try parseHeader(header)
        let encodedHeader = header.withAAEncodedData { Data($0) }
        return DecodedHeaderSummary(
            encodedHeader: encodedHeader,
            content: summarizeHeaderContent(header, parsed: parsed),
            parsed: parsed
        )
    }

    private static func summarizeHeaderContent(
        _ header: ArchiveHeader,
        parsed: ParsedHeader
    ) -> HeaderContentSummary {
        HeaderContentSummary(
            entryType: header.entryType?.rawValue,
            fields: header.map { field in
                switch field {
                case let .flag(key):
                    return .flag(key.description)
                case let .uint(key, value):
                    return .uint(key.description, value)
                case let .string(key, value):
                    return .string(key.description, value)
                case let .hash(key, hashFunction, value):
                    return .hash(key.description, hashFunction.rawValue, Array(value))
                case let .timespec(key, value):
                    return .timespec(
                        key.description,
                        Int64(value.tv_sec),
                        Int64(value.tv_nsec)
                    )
                case let .blob(key, size, offset):
                    return .blob(key.description, size, offset)
                @unknown default:
                    return .unknown(field.key.description, field.type.rawValue)
                }
            },
            path: parsed.path,
            size: parsed.size,
            dataKey: parsed.dataKey.description
        )
    }

    private static func preadExactly(
        _ fileDescriptor: Int32,
        byteCount: Int,
        offset: Int64,
        error validationError: MeetingTransferValidationError
    ) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: byteCount)
        var completed = 0
        while completed < byteCount {
            let count = result.withUnsafeMutableBytes { bytes in
                pread(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    byteCount - completed,
                    off_t(offset + Int64(completed))
                )
            }
            if count > 0 {
                completed += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw validationError
            }
        }
        return result
    }

    private static func readSome(_ fileDescriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw MeetingTransferValidationError.storageWriteFailed
        }
    }

    static func writeAll(_ fileDescriptor: Int32, bytes: [UInt8], count: Int) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < count {
                let written = Darwin.write(
                    fileDescriptor,
                    raw.baseAddress!.advanced(by: offset),
                    count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw MeetingTransferValidationError.storageWriteFailed
                }
            }
        }
    }

    static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct ParsedHeader {
    let path: String
    let size: UInt64
    let dataKey: ArchiveHeader.FieldKey
}

private struct RawArchivePreflight {
    let headers: [RawHeaderSummary]
    let byteCount: Int64
}

private struct RawHeaderSummary {
    let encodedHeader: Data
    let content: HeaderContentSummary
    let headerOffset: Int64
    let headerByteCount: Int
    let dataOffset: Int64
    let dataEnd: Int64
}

private struct DecodedHeaderSummary {
    let encodedHeader: Data
    let content: HeaderContentSummary
    let parsed: ParsedHeader
}

private struct HeaderContentSummary: Equatable {
    let entryType: UInt32?
    let fields: [HeaderFieldSummary]
    let path: String
    let size: UInt64
    let dataKey: String
}

private enum HeaderFieldSummary: Equatable {
    case flag(String)
    case uint(String, UInt64)
    case string(String, String)
    case hash(String, UInt32, [UInt8])
    case timespec(String, Int64, Int64)
    case blob(String, UInt64, UInt64)
    case unknown(String, UInt32)
}

private struct StagedEntry {
    let byteCount: Int64
    let sha256: String
    let decodedBytes: Data?
    let audioSource: MeetingTransferValidatedAudioSource?
}

private struct ReadEntryResult {
    let sha256: String
    let decodedBytes: Data?
}

private struct DecodedPayload {
    let meeting: MeetingTransferMeetingDocument
    let notes: String?
    let transcript: MeetingTransferTranscriptSnapshot?
    let audio: [ValidatedMeetingTransferAudio]
}
