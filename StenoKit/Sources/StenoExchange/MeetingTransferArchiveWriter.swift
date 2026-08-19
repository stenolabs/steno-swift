import AppleArchive
import CryptoKit
import Darwin
import Foundation
import StenoDomain
import System

public struct MeetingTransferAudioSourceBinding: Sendable {
    public let logicalTrackID: String
    public let sourceURL: URL
    fileprivate let expectedSourceIdentity: MeetingTransferFileIdentity?

    public init(logicalTrackID: String, sourceURL: URL) {
        self.logicalTrackID = logicalTrackID
        self.sourceURL = sourceURL
        expectedSourceIdentity = nil
    }

    package init(
        logicalTrackID: String,
        sourceURL: URL,
        preparedSource: MeetingTransferPreparedCAFSource
    ) {
        self.logicalTrackID = logicalTrackID
        self.sourceURL = sourceURL
        expectedSourceIdentity = preparedSource.identity
    }
}

public enum MeetingTransferArchiveWriterError: Error, Equatable, Sendable {
    case missingAudioSource(String)
    case extraAudioSource(String)
    case duplicateAudioSource(String)
    case duplicateAudioDocument(String)
    case sourceOpenFailed(String)
    case sourceNotRegularFile(String)
    case sourceUnsupportedAudio(String)
    case sourceIdentityMismatch(String)
    case sourceByteCountMismatch(String)
    case sourceHashMismatch(String)
    case couldNotCreateArchiveStream
    case writeFailed
    case insufficientCapacity
    case destinationAlreadyExists
    case stagingIdentityMismatch
    case cleanupFailed
}

public struct MeetingTransferArchiveWriter: Sendable {
    typealias CapacityCheck = @Sendable (Int64) throws -> Void

    private let injectedCapacityCheck: CapacityCheck?
    private let namespaceAction: MeetingTransferNamespaceAction

    public init() {
        injectedCapacityCheck = nil
        namespaceAction = { _ in }
    }

    init(capacityCheck: @escaping CapacityCheck) {
        injectedCapacityCheck = capacityCheck
        namespaceAction = { _ in }
    }

    init(namespaceCheckpoint: @escaping MeetingTransferNamespaceAction) {
        injectedCapacityCheck = nil
        namespaceAction = namespaceCheckpoint
    }

    public func write(
        _ content: MeetingTransferPackageContent,
        audioSources: [MeetingTransferAudioSourceBinding] = [],
        sourceRevisionID: RevisionID? = nil,
        sourceAppVersion: String? = nil,
        to parent: URL,
        progress: @escaping @Sendable (MeetingTransferProgress) -> Void = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let bindings = try Self.validateBindings(content: content, bindings: audioSources)
        let openedSources = try Self.openAndValidateSources(content: content, bindings: bindings)
        defer {
            for source in openedSources.values {
                source.descriptor.close()
            }
        }

        let payloadEntries = try Self.makePayloadEntries(content: content, sources: openedSources)
        let manifestEntries = payloadEntries.map {
            MeetingTransferManifest.Entry(
                path: $0.path,
                byteCount: $0.byteCount,
                mediaType: $0.mediaType,
                sha256: $0.sha256
            )
        }
        let manifest = try MeetingTransferManifest(
            sourceMeetingID: content.meeting.sourceMeetingID,
            sourceRevisionID: sourceRevisionID,
            exportedAt: Date(),
            sourceAppVersion: sourceAppVersion,
            capabilities: content.capabilities,
            localeIdentifier: content.sourceLocale?.localeIdentifier,
            localeOrigin: content.sourceLocale?.origin ?? .absent,
            entries: manifestEntries,
            contentDigest: try MeetingTransferDigest.contentDigest(for: manifestEntries)
        )
        let manifestData = try manifest.encodedData()
        let entries = [WriterEntry(
            path: "manifest.json",
            mediaType: "application/json",
            byteCount: Int64(manifestData.count),
            sha256: Self.sha256(manifestData),
            body: .data(manifestData)
        )] + payloadEntries

        let root = try MeetingTransferPrivateRoot.prepareAndVerify(
            at: parent,
            cleanupAction: { _ in },
            namespaceCheckpoint: namespaceAction
        )
        let expectedArchiveBytes = try Self.expectedArchiveByteCount(entries)
        try checkCapacity(
            archiveBytes: expectedArchiveBytes,
            directoryFD: root.directoryFileDescriptor
        )
        let stagingName = ".stenomeeting-staging-\(UUID().uuidString)"
        let stagingDescriptor: MeetingTransferOwnedDescriptor
        var stagingDetached = false
        do {
            stagingDescriptor = try root.createFile(named: stagingName)
        } catch {
            throw MeetingTransferArchiveWriterError.writeFailed
        }
        let stagingIdentity: MeetingTransferFileIdentity
        do {
            stagingIdentity = try root.identity(
                of: stagingDescriptor.rawValue,
                named: stagingName
            )
        } catch {
            stagingDescriptor.close()
            throw MeetingTransferArchiveWriterError.stagingIdentityMismatch
        }

        do {
            try Self.writeArchive(
                entries,
                to: stagingDescriptor.rawValue,
                progress: progress
            )
            guard fsync(stagingDescriptor.rawValue) == 0,
                  lseek(stagingDescriptor.rawValue, 0, SEEK_SET) == 0
            else {
                throw MeetingTransferArchiveWriterError.writeFailed
            }

            try Task.checkCancellation()
            do {
                try root.verifyFile(named: stagingName, identity: stagingIdentity)
            } catch {
                throw MeetingTransferArchiveWriterError.stagingIdentityMismatch
            }
            try namespaceAction(.beforeWriterPublish(stagingName))
            do {
                try root.detachFile(
                    named: stagingName,
                    identity: stagingIdentity,
                    matchingDescriptor: stagingDescriptor.rawValue
                )
                stagingDetached = true
            } catch MeetingTransferValidationError.cleanupIdentityMismatch {
                throw MeetingTransferArchiveWriterError.stagingIdentityMismatch
            } catch {
                throw MeetingTransferArchiveWriterError.cleanupFailed
            }

            let stagingURL = root.url.appendingPathComponent(stagingName)
            let validated = try await MeetingTransferArchiveReader().validateOwnedSnapshot(
                fileDescriptor: stagingDescriptor.rawValue,
                archiveURL: stagingURL,
                within: root,
                progress: progress
            )
            try validated.close()
            try Task.checkCancellation()

            let finalName = "Meeting-\(content.meeting.sourceMeetingID).stenomeeting"
            let cloneResult = fclonefileat(
                stagingDescriptor.rawValue,
                root.directoryFileDescriptor,
                finalName,
                UInt32(CLONE_NOOWNERCOPY)
            )
            guard cloneResult == 0 else {
                if errno == EEXIST {
                    throw MeetingTransferArchiveWriterError.destinationAlreadyExists
                }
                throw MeetingTransferArchiveWriterError.writeFailed
            }
            stagingDescriptor.close()
            guard fsync(root.directoryFileDescriptor) == 0 else {
                throw MeetingTransferArchiveWriterError.writeFailed
            }
            return root.url.appendingPathComponent(finalName)
        } catch {
            let operationError = error
            stagingDescriptor.close()
            if !stagingDetached {
                do {
                    try root.removeFile(named: stagingName, identity: stagingIdentity)
                } catch MeetingTransferValidationError.cleanupIdentityMismatch {
                    throw MeetingTransferArchiveWriterError.stagingIdentityMismatch
                } catch {
                    throw MeetingTransferArchiveWriterError.cleanupFailed
                }
            }
            throw operationError
        }
    }

    private static func validateBindings(
        content: MeetingTransferPackageContent,
        bindings: [MeetingTransferAudioSourceBinding]
    ) throws -> [String: MeetingTransferAudioSourceBinding] {
        var documents: Set<String> = []
        for document in content.audio {
            guard documents.insert(document.logicalTrackID).inserted else {
                throw MeetingTransferArchiveWriterError.duplicateAudioDocument(
                    document.logicalTrackID
                )
            }
        }

        var result: [String: MeetingTransferAudioSourceBinding] = [:]
        for binding in bindings {
            guard result.updateValue(binding, forKey: binding.logicalTrackID) == nil else {
                throw MeetingTransferArchiveWriterError.duplicateAudioSource(binding.logicalTrackID)
            }
        }
        for document in content.audio where result[document.logicalTrackID] == nil {
            throw MeetingTransferArchiveWriterError.missingAudioSource(document.logicalTrackID)
        }
        for id in result.keys.sorted() where !documents.contains(id) {
            throw MeetingTransferArchiveWriterError.extraAudioSource(id)
        }
        return result
    }

    private static func openAndValidateSources(
        content: MeetingTransferPackageContent,
        bindings: [String: MeetingTransferAudioSourceBinding]
    ) throws -> [String: OpenedAudioSource] {
        var result: [String: OpenedAudioSource] = [:]
        do {
            for document in content.audio {
                try Task.checkCancellation()
                let id = document.logicalTrackID
                guard let binding = bindings[id] else {
                    throw MeetingTransferArchiveWriterError.missingAudioSource(id)
                }
                let rawDescriptor = open(
                    binding.sourceURL.path,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard rawDescriptor >= 0 else {
                    if errno == ELOOP {
                        throw MeetingTransferArchiveWriterError.sourceNotRegularFile(id)
                    }
                    throw MeetingTransferArchiveWriterError.sourceOpenFailed(id)
                }
                let descriptor = MeetingTransferOwnedDescriptor(rawDescriptor)
                var status = stat()
                guard fstat(rawDescriptor, &status) == 0,
                      status.st_mode & S_IFMT == S_IFREG,
                      status.st_size >= 0
                else {
                    descriptor.close()
                    throw MeetingTransferArchiveWriterError.sourceNotRegularFile(id)
                }
                if let expectedIdentity = binding.expectedSourceIdentity,
                   MeetingTransferFileIdentity(status) != expectedIdentity {
                    descriptor.close()
                    throw MeetingTransferArchiveWriterError.sourceIdentityMismatch(id)
                }
                guard MeetingTransferCAFContainer.hasSupportedHeader(
                    fileDescriptor: rawDescriptor
                ) else {
                    descriptor.close()
                    throw MeetingTransferArchiveWriterError.sourceUnsupportedAudio(id)
                }
                let byteCount = Int64(status.st_size)
                guard byteCount == document.byteCount else {
                    descriptor.close()
                    throw MeetingTransferArchiveWriterError.sourceByteCountMismatch(id)
                }
                let digest: String
                do {
                    digest = try MeetingTransferDigest.sha256(
                        fileDescriptor: rawDescriptor,
                        expectedByteCount: byteCount
                    )
                } catch is CancellationError {
                    descriptor.close()
                    throw CancellationError()
                } catch MeetingTransferFileDigestError.readFailed {
                    descriptor.close()
                    throw MeetingTransferArchiveWriterError.sourceOpenFailed(id)
                } catch MeetingTransferFileDigestError.byteCountMismatch {
                    descriptor.close()
                    throw MeetingTransferArchiveWriterError.sourceByteCountMismatch(id)
                } catch {
                    descriptor.close()
                    throw error
                }
                guard digest == document.sha256 else {
                    descriptor.close()
                    throw MeetingTransferArchiveWriterError.sourceHashMismatch(id)
                }
                result[id] = OpenedAudioSource(
                    descriptor: descriptor,
                    byteCount: byteCount,
                    sha256: digest
                )
            }
            return result
        } catch {
            for source in result.values {
                source.descriptor.close()
            }
            throw error
        }
    }

    private static func makePayloadEntries(
        content: MeetingTransferPackageContent,
        sources: [String: OpenedAudioSource]
    ) throws -> [WriterEntry] {
        var result: [WriterEntry] = []
        try result.append(dataEntry(
            path: "meeting.json",
            mediaType: "application/json",
            data: content.meeting.encodedData()
        ))
        if let notes = content.notes {
            try result.append(dataEntry(
                path: "notes.md",
                mediaType: "text/markdown",
                data: Data(notes.utf8)
            ))
        }
        if let transcript = content.transcript {
            try result.append(dataEntry(
                path: "transcript.json",
                mediaType: "application/json",
                data: transcript.encodedData()
            ))
        }
        for (offset, document) in content.audio.enumerated() {
            let number = offset + 1
            guard let source = sources[document.logicalTrackID] else {
                throw MeetingTransferArchiveWriterError.missingAudioSource(
                    document.logicalTrackID
                )
            }
            result.append(WriterEntry(
                path: "audio/track-\(number).caf",
                mediaType: "audio/x-caf",
                byteCount: source.byteCount,
                sha256: source.sha256,
                body: .file(source.descriptor)
            ))
            try result.append(dataEntry(
                path: "audio/track-\(number).json",
                mediaType: "application/json",
                data: document.encodedData()
            ))
        }
        return result
    }

    private static func dataEntry(path: String, mediaType: String, data: Data) throws -> WriterEntry {
        guard data.count <= Int64.max else {
            throw MeetingTransferArchiveWriterError.writeFailed
        }
        return WriterEntry(
            path: path,
            mediaType: mediaType,
            byteCount: Int64(data.count),
            sha256: sha256(data),
            body: .data(data)
        )
    }

    private static func writeArchive(
        _ entries: [WriterEntry],
        to fileDescriptor: Int32,
        progress: @Sendable (MeetingTransferProgress) -> Void
    ) throws {
        guard let byteStream = ArchiveByteStream.fileStream(
            fd: FileDescriptor(rawValue: fileDescriptor),
            automaticClose: false
        ), let archive = ArchiveStream.encodeStream(writingTo: byteStream) else {
            throw MeetingTransferArchiveWriterError.couldNotCreateArchiveStream
        }
        var archiveClosed = false
        var byteStreamClosed = false
        defer {
            if !archiveClosed { archive.cancel() }
            if !byteStreamClosed { byteStream.cancel() }
        }

        do {
            let totalBytes = entries.reduce(Int64(0)) { partial, entry in
                partial + entry.byteCount
            }
            var processed: Int64 = 0
            for entry in entries {
                try Task.checkCancellation()
                let header = makeHeader(for: entry)
                let dataKey = ArchiveHeader.FieldKey("DAT")
                try archive.writeHeader(header)

                switch entry.body {
                case let .data(data):
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            try Task.checkCancellation()
                            let count = min(MeetingTransferDigest.fileReadChunkSize, bytes.count - offset)
                            try archive.writeBlob(
                                key: dataKey,
                                from: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)])
                            )
                            offset += count
                            processed += Int64(count)
                            progress(.init(
                                phase: .writing,
                                processedBytes: processed,
                                totalBytes: totalBytes
                            ))
                        }
                    }
                case let .file(descriptor):
                    guard lseek(descriptor.rawValue, 0, SEEK_SET) == 0 else {
                        throw MeetingTransferArchiveWriterError.writeFailed
                    }
                    var remaining = entry.byteCount
                    var buffer = [UInt8](
                        repeating: 0,
                        count: MeetingTransferDigest.fileReadChunkSize
                    )
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let wanted = Int(min(Int64(buffer.count), remaining))
                        let count = try readSource(
                            descriptor.rawValue,
                            into: &buffer,
                            maximumCount: wanted,
                            logicalTrackID: entry.path
                        )
                        guard count > 0 else {
                            throw MeetingTransferArchiveWriterError.writeFailed
                        }
                        try buffer.withUnsafeBytes { bytes in
                            try archive.writeBlob(
                                key: dataKey,
                                from: UnsafeRawBufferPointer(rebasing: bytes[..<count])
                            )
                        }
                        remaining -= Int64(count)
                        processed += Int64(count)
                        progress(.init(
                            phase: .writing,
                            processedBytes: processed,
                            totalBytes: totalBytes
                        ))
                    }
                    var sentinel: UInt8 = 0
                    let extra = Darwin.read(descriptor.rawValue, &sentinel, 1)
                    guard extra == 0 else {
                        throw MeetingTransferArchiveWriterError.writeFailed
                    }
                }
            }
            try archive.close()
            archiveClosed = true
            try byteStream.close()
            byteStreamClosed = true
        } catch let error as MeetingTransferArchiveWriterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MeetingTransferArchiveWriterError.writeFailed
        }
    }

    private func checkCapacity(archiveBytes: Int64, directoryFD: Int32) throws {
        let (requiredBytes, overflow) = archiveBytes.addingReportingOverflow(
            MeetingTransferLimits.minimumFreeSpaceReserveBytes
        )
        guard archiveBytes >= 0, !overflow else {
            throw MeetingTransferArchiveWriterError.insufficientCapacity
        }
        if let injectedCapacityCheck {
            try injectedCapacityCheck(requiredBytes)
            return
        }
        var fileSystem = statfs()
        guard fstatfs(directoryFD, &fileSystem) == 0 else {
            throw MeetingTransferArchiveWriterError.insufficientCapacity
        }
        let available = UInt64(fileSystem.f_bavail).multipliedReportingOverflow(
            by: UInt64(fileSystem.f_bsize)
        )
        guard !available.overflow, available.partialValue >= UInt64(requiredBytes) else {
            throw MeetingTransferArchiveWriterError.insufficientCapacity
        }
    }

    private static func expectedArchiveByteCount(_ entries: [WriterEntry]) throws -> Int64 {
        var result: Int64 = 0
        for entry in entries {
            let headerByteCount = makeHeader(for: entry).withAAEncodedData { Int64($0.count) }
            let (withHeader, headerOverflow) = result.addingReportingOverflow(headerByteCount)
            let (withData, dataOverflow) = withHeader.addingReportingOverflow(entry.byteCount)
            guard !headerOverflow, !dataOverflow else {
                throw MeetingTransferArchiveWriterError.writeFailed
            }
            result = withData
        }
        return result
    }

    private static func makeHeader(for entry: WriterEntry) -> ArchiveHeader {
        let header = ArchiveHeader()
        header.append(.uint(
            key: ArchiveHeader.FieldKey("TYP"),
            value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)
        ))
        header.append(.string(
            key: ArchiveHeader.FieldKey("PAT"),
            value: entry.path
        ))
        header.append(.uint(
            key: ArchiveHeader.FieldKey("SIZ"),
            value: UInt64(entry.byteCount)
        ))
        header.append(.blob(
            key: ArchiveHeader.FieldKey("DAT"),
            size: UInt64(entry.byteCount)
        ))
        return header
    }

    private static func readSource(
        _ fileDescriptor: Int32,
        into buffer: inout [UInt8],
        maximumCount: Int,
        logicalTrackID: String
    ) throws -> Int {
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, maximumCount)
            }
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw MeetingTransferArchiveWriterError.sourceOpenFailed(logicalTrackID)
        }
    }

    private static func sha256(_ data: Data) -> String {
        MeetingTransferArchiveReader.hex(SHA256.hash(data: data))
    }
}

private struct OpenedAudioSource {
    let descriptor: MeetingTransferOwnedDescriptor
    let byteCount: Int64
    let sha256: String
}

private struct WriterEntry {
    enum Body {
        case data(Data)
        case file(MeetingTransferOwnedDescriptor)
    }

    let path: String
    let mediaType: String
    let byteCount: Int64
    let sha256: String
    let body: Body
}
