import CryptoKit
import Darwin
import Foundation
import StenoDomain

struct DemoResourceDataSource: @unchecked Sendable {
    let url: URL
    fileprivate let descriptor: Int32
    fileprivate let byteCount: Int64

    func read() throws -> Data {
        guard byteCount >= 0, byteCount <= Int64(Int.max) else {
            throw DemoDescriptorReadError.invalidSize
        }
        var result = Data()
        result.reserveCapacity(Int(byteCount))
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < byteCount {
            let wanted = Int(min(Int64(buffer.count), byteCount - offset))
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, wanted, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw DemoDescriptorReadError.readFailed }
            result.append(contentsOf: buffer[..<count])
            offset += Int64(count)
        }
        var trailing: UInt8 = 0
        guard pread(descriptor, &trailing, 1, off_t(byteCount)) == 0 else {
            throw DemoDescriptorReadError.sizeChanged
        }
        return result
    }
}

typealias DemoDataReader = @Sendable (DemoResourceDataSource) throws -> Data

package enum DemoResourceBundleCheckpoint: Equatable, Sendable {
    case afterComponentMetadata(
        resourceID: String,
        relativePath: String,
        componentIndex: Int
    )
}

package typealias DemoResourceBundleAction = @Sendable (
    DemoResourceBundleCheckpoint
) throws -> Void

/// Vollständig geprüfte, einmal gelesene Ressourcenschnappschüsse.
public struct VerifiedDemoDataset: Sendable {
    public let manifest: DemoDatasetManifest
    public let resources: [String: Data]

    init(manifest: DemoDatasetManifest, resources: [String: Data]) {
        self.manifest = manifest
        self.resources = resources
    }
}

public struct DemoResourceBundle: Sendable {
    public let rootURL: URL
    private let dataReader: DemoDataReader
    private let checkpoint: DemoResourceBundleAction

    public init(rootURL: URL) {
        self.init(
            rootURL: rootURL,
            dataReader: { try $0.read() },
            checkpoint: { _ in }
        )
    }

    init(
        rootURL: URL,
        dataReader: @escaping DemoDataReader,
        checkpoint: @escaping DemoResourceBundleAction = { _ in }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.dataReader = dataReader
        self.checkpoint = checkpoint
    }

    init(rootURL: URL, checkpoint: @escaping DemoResourceBundleAction) {
        self.init(
            rootURL: rootURL,
            dataReader: { try $0.read() },
            checkpoint: checkpoint
        )
    }

    public static func bundled() throws -> Self {
        guard let rootURL = Bundle.module.url(
            forResource: "DemoDataset",
            withExtension: nil
        ) else {
            throw DemoLibraryError.bundledDatasetMissing
        }
        return Self(rootURL: rootURL)
    }

    /// Returns resource URLs only after the entire manifest and every resource
    /// have passed structural, containment, symlink, byte-count, and digest checks.
    public func verifiedResources(
        for manifest: DemoDatasetManifest
    ) throws -> [String: URL] {
        try manifest.validate()
        let session = try DemoBundleDescriptorSession(
            rootURL: rootURL,
            checkpoint: checkpoint
        )

        var verified: [String: URL] = [:]
        var snapshots: [String: Data] = [:]
        for descriptor in manifest.resources {
            let url = try resourceURL(descriptor.relativePath)
            let data = try session.readFile(
                relativePath: descriptor.relativePath,
                resourceID: descriptor.id,
                reader: dataReader,
                failure: .resourceReadFailed(
                    id: descriptor.id,
                    path: descriptor.relativePath
                )
            )
            let actualByteCount = Int64(data.count)
            guard actualByteCount == descriptor.byteCount else {
                throw DemoLibraryError.wrongByteCount(
                    id: descriptor.id,
                    expected: descriptor.byteCount,
                    actual: actualByteCount
                )
            }
            guard sha256(of: data) == descriptor.sha256 else {
                throw DemoLibraryError.wrongSHA256(id: descriptor.id)
            }
            verified[descriptor.id] = url
            snapshots[descriptor.id] = data
        }
        try session.validateSnapshot(failure: .resourceReadFailed(
            id: "bundle",
            path: rootURL.path
        ))

        for meeting in manifest.meetings {
            guard let transcriptData = snapshots[meeting.transcript.resourceID] else {
                throw DemoLibraryError.unknownResourceID(meeting.transcript.resourceID)
            }
            try validateTranscript(
                transcriptData,
                resourceID: meeting.transcript.resourceID,
                meeting: meeting,
                datasetID: manifest.datasetID,
                datasetVersion: manifest.datasetVersion
            )
        }
        try validateTextSnapshots(manifest: manifest, snapshots: snapshots)
        return verified
    }

    public func loadVerifiedDataset() throws -> VerifiedDemoDataset {
        let manifestPath = "manifest.json"
        let session = try DemoBundleDescriptorSession(
            rootURL: rootURL,
            checkpoint: checkpoint
        )
        let manifestData = try session.readFile(
            relativePath: manifestPath,
            resourceID: "manifest",
            reader: dataReader,
            failure: .manifestReadFailed(path: manifestPath)
        )
        let manifest: DemoDatasetManifest
        do { manifest = try JSONDecoder().decode(DemoDatasetManifest.self, from: manifestData) } catch {
            throw DemoLibraryError.invalidManifest(path: manifestPath)
        }
        try manifest.validate()
        var snapshots: [String: Data] = [:]
        for descriptor in manifest.resources {
            let data = try session.readFile(
                relativePath: descriptor.relativePath,
                resourceID: descriptor.id,
                reader: dataReader,
                failure: .resourceReadFailed(
                    id: descriptor.id,
                    path: descriptor.relativePath
                )
            )
            guard Int64(data.count) == descriptor.byteCount else {
                throw DemoLibraryError.wrongByteCount(id: descriptor.id, expected: descriptor.byteCount, actual: Int64(data.count))
            }
            guard sha256(of: data) == descriptor.sha256 else { throw DemoLibraryError.wrongSHA256(id: descriptor.id) }
            snapshots[descriptor.id] = data
        }
        try session.validateSnapshot(failure: .manifestReadFailed(path: manifestPath))
        for meeting in manifest.meetings {
            guard let transcript = snapshots[meeting.transcript.resourceID] else { throw DemoLibraryError.unknownResourceID(meeting.transcript.resourceID) }
            try validateTranscript(transcript, resourceID: meeting.transcript.resourceID, meeting: meeting, datasetID: manifest.datasetID, datasetVersion: manifest.datasetVersion)
        }
        try validateTextSnapshots(manifest: manifest, snapshots: snapshots)
        return VerifiedDemoDataset(manifest: manifest, resources: snapshots)
    }

    public func loadAndVerifyManifest() throws -> DemoDatasetManifest {
        try loadVerifiedDataset().manifest
    }

    private func validateTranscript(
        _ data: Data,
        resourceID: String,
        meeting: DemoMeetingManifest,
        datasetID: String,
        datasetVersion: String
    ) throws {
        let transcript: TranscriptRevision
        do {
            transcript = try JSONDecoder().decode(TranscriptRevision.self, from: data)
        } catch {
            throw DemoLibraryError.invalidTranscript(resourceID: resourceID)
        }
        guard transcript.schemaVersion == TranscriptRevision.currentSchemaVersion else {
            throw DemoLibraryError.unsupportedTranscriptSchemaVersion(
                resourceID: resourceID,
                actual: transcript.schemaVersion
            )
        }
        guard transcript.createdAt == fixedUTCDate(meeting.transcript.createdAtUTC) else {
            throw DemoLibraryError.unexpectedTranscriptCreatedAt(resourceID: resourceID)
        }
        guard transcript.meetingID == meeting.id else {
            throw DemoLibraryError.transcriptMismatch(resourceID: resourceID, field: "meetingID")
        }
        guard transcript.id == meeting.transcript.id else {
            throw DemoLibraryError.transcriptMismatch(resourceID: resourceID, field: "revisionID")
        }
        let expectedProvenance = DemoProvenance(
            datasetID: datasetID,
            datasetVersion: datasetVersion,
            itemID: meeting.itemID
        )
        guard case .demo(let provenance) = transcript.origin,
              provenance == expectedProvenance else {
            throw DemoLibraryError.transcriptMismatch(
                resourceID: resourceID,
                field: "demoProvenance"
            )
        }
        guard transcript.turns.allSatisfy({ turn in
            guard let speaker = turn.speaker else { return true }
            if case .importedTextLabel = speaker { return true }
            return false
        }) else {
            throw DemoLibraryError.invalidTranscript(resourceID: resourceID)
        }
    }

    private func validateTextSnapshots(
        manifest: DemoDatasetManifest,
        snapshots: [String: Data]
    ) throws {
        for descriptor in manifest.resources {
            switch descriptor.kind {
            case .note, .report, .referenceTranscript, .referenceTimeline, .attribution:
                guard let data = snapshots[descriptor.id],
                      String(data: data, encoding: .utf8) != nil else {
                    throw DemoLibraryError.invalidUTF8(resourceID: descriptor.id)
                }
            case .audio, .transcript:
                break
            }
        }
    }

    private func resourceURL(_ relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !NSString(string: relativePath).isAbsolutePath,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DemoLibraryError.invalidResourcePath(relativePath)
        }

        let candidate = components.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw DemoLibraryError.resourceEscapesBundle(relativePath)
        }
        return candidate
    }

    private func fixedUTCDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum DemoDescriptorReadError: Error {
    case invalidSize
    case readFailed
    case sizeChanged
}

private struct DemoBundleEntryMetadata: Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let mode: mode_t
    let linkCount: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ status: stat) {
        deviceID = UInt64(status.st_dev)
        fileID = UInt64(status.st_ino)
        mode = status.st_mode
        linkCount = UInt64(status.st_nlink)
        byteCount = Int64(status.st_size)
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
    }
}

private struct DemoBundleOpenDirectory {
    let descriptor: Int32
    let metadata: DemoBundleEntryMetadata
    let parentPath: String?
    let name: String?
}

private final class DemoBundleDescriptorSession {
    private let rootURL: URL
    private let checkpoint: DemoResourceBundleAction
    private var directories: [String: DemoBundleOpenDirectory] = [:]

    init(rootURL: URL, checkpoint: @escaping DemoResourceBundleAction) throws {
        self.rootURL = rootURL
        self.checkpoint = checkpoint
        var pathStatus = stat()
        guard lstat(rootURL.path, &pathStatus) == 0 else {
            throw DemoLibraryError.missingResource(id: "bundle", path: rootURL.path)
        }
        guard pathStatus.st_mode & S_IFMT != S_IFLNK else {
            throw DemoLibraryError.symbolicLink(rootURL.lastPathComponent)
        }
        guard pathStatus.st_mode & S_IFMT == S_IFDIR else {
            throw DemoLibraryError.invalidBundleRoot(path: rootURL.path)
        }
        let descriptor = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw DemoLibraryError.invalidBundleRoot(path: rootURL.path)
        }
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            Darwin.close(descriptor)
            throw DemoLibraryError.invalidBundleRoot(path: rootURL.path)
        }
        directories[""] = DemoBundleOpenDirectory(
            descriptor: descriptor,
            metadata: DemoBundleEntryMetadata(descriptorStatus),
            parentPath: nil,
            name: nil
        )
    }

    deinit {
        for directory in directories.values {
            Darwin.close(directory.descriptor)
        }
    }

    func readFile(
        relativePath: String,
        resourceID: String,
        reader: DemoDataReader,
        failure: DemoLibraryError
    ) throws -> Data {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !relativePath.isEmpty,
              !NSString(string: relativePath).isAbsolutePath,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DemoLibraryError.invalidResourcePath(relativePath)
        }

        var parentPath = ""
        for (index, name) in components.enumerated() {
            guard let parent = directories[parentPath] else { throw failure }
            try validateDirectory(parent, failure: failure)
            var entryStatus = stat()
            guard fstatat(
                parent.descriptor,
                name,
                &entryStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw DemoLibraryError.missingResource(
                    id: resourceID,
                    path: relativePath
                )
            }
            guard entryStatus.st_mode & S_IFMT != S_IFLNK else {
                throw DemoLibraryError.symbolicLink(relativePath)
            }
            let isFinal = index == components.count - 1
            if isFinal {
                guard entryStatus.st_mode & S_IFMT == S_IFREG else {
                    throw DemoLibraryError.invalidResourceFileType(
                        id: resourceID,
                        path: relativePath
                    )
                }
            } else {
                guard entryStatus.st_mode & S_IFMT == S_IFDIR else {
                    throw DemoLibraryError.invalidResourceDirectoryComponent(relativePath)
                }
            }
            let expected = DemoBundleEntryMetadata(entryStatus)
            try checkpoint(.afterComponentMetadata(
                resourceID: resourceID,
                relativePath: relativePath,
                componentIndex: index
            ))

            if isFinal {
                let descriptor = openat(
                    parent.descriptor,
                    name,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else { throw failure }
                defer { Darwin.close(descriptor) }
                var openedStatus = stat()
                guard fstat(descriptor, &openedStatus) == 0,
                      openedStatus.st_mode & S_IFMT == S_IFREG,
                      DemoBundleEntryMetadata(openedStatus) == expected else {
                    throw failure
                }
                let source = DemoResourceDataSource(
                    url: rootURL.appending(path: relativePath),
                    descriptor: descriptor,
                    byteCount: Int64(openedStatus.st_size)
                )
                let data: Data
                do {
                    data = try reader(source)
                } catch {
                    throw failure
                }
                var afterStatus = stat()
                var pathAfterStatus = stat()
                guard fstat(descriptor, &afterStatus) == 0,
                      DemoBundleEntryMetadata(afterStatus) == expected,
                      fstatat(
                        parent.descriptor,
                        name,
                        &pathAfterStatus,
                        AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      DemoBundleEntryMetadata(pathAfterStatus) == expected else {
                    throw failure
                }
                try validateSnapshot(failure: failure)
                return data
            }

            let childPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
            if let known = directories[childPath] {
                guard known.metadata == expected else { throw failure }
                parentPath = childPath
                continue
            }
            let descriptor = openat(
                parent.descriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { throw failure }
            var openedStatus = stat()
            guard fstat(descriptor, &openedStatus) == 0,
                  openedStatus.st_mode & S_IFMT == S_IFDIR,
                  DemoBundleEntryMetadata(openedStatus) == expected else {
                Darwin.close(descriptor)
                throw failure
            }
            directories[childPath] = DemoBundleOpenDirectory(
                descriptor: descriptor,
                metadata: expected,
                parentPath: parentPath,
                name: name
            )
            parentPath = childPath
        }
        throw failure
    }

    func validateSnapshot(failure: DemoLibraryError) throws {
        for directory in directories.values {
            try validateDirectory(directory, failure: failure)
            guard let parentPath = directory.parentPath,
                  let name = directory.name,
                  let parent = directories[parentPath] else {
                continue
            }
            var pathStatus = stat()
            guard fstatat(
                parent.descriptor,
                name,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
              DemoBundleEntryMetadata(pathStatus) == directory.metadata else {
                throw failure
            }
        }
        guard let root = directories[""] else { throw failure }
        var pathStatus = stat()
        guard lstat(rootURL.path, &pathStatus) == 0,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              UInt64(pathStatus.st_dev) == root.metadata.deviceID,
              UInt64(pathStatus.st_ino) == root.metadata.fileID else {
            throw failure
        }
    }

    private func validateDirectory(
        _ directory: DemoBundleOpenDirectory,
        failure: DemoLibraryError
    ) throws {
        var status = stat()
        guard fstat(directory.descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              DemoBundleEntryMetadata(status) == directory.metadata else {
            throw failure
        }
    }
}
