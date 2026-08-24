import AppKit
import Darwin
import Foundation
import Observation
import StenoDomain
import StenoExchange
import StenoPipeline

enum MeetingTransferExportCleanupError: LocalizedError, Equatable {
    case runtimeUnavailable
    case invalidTemporaryExport
    case notOwned
    case unexpectedEntry
    case cleanupFailed

    var errorDescription: String? {
        message()
    }

    func message(locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = switch self {
        case .runtimeUnavailable:
            "Steno is not ready to share this meeting."
        case .invalidTemporaryExport:
            "Steno could not create a private temporary export."
        case .notOwned:
            "Steno refused to remove a temporary location it no longer owns."
        case .unexpectedEntry:
            "Steno found an unexpected item in its temporary export. Remove it, then retry cleanup."
        case .cleanupFailed:
            "Steno could not remove its temporary meeting export. Retry cleanup."
        }
        var localizedResource = resource
        localizedResource.locale = locale
        return String(localized: localizedResource)
    }

}

struct MeetingTransferExportSelection: Codable, Equatable, Sendable {
    let meetingID: MeetingID
    let selectedAudioAssetIDs: Set<MediaAssetID>
}

enum MeetingTransferExportNamespaceEvent {
    case beforePackageRemoval(URL)
    case beforeRootRemoval(URL)
}

typealias MeetingTransferExportNamespaceCheckpoint = @MainActor (
    MeetingTransferExportNamespaceEvent
) throws -> Void

typealias MeetingTransferExportParentSync = @MainActor (Int32) throws -> Void
typealias MeetingTransferValidationSessionRecovery = @MainActor (URL) throws -> Void

private let meetingTransferDefaultParentSync: MeetingTransferExportParentSync = {
    descriptor in
    guard fsync(descriptor) == 0 else {
        throw MeetingTransferExportCleanupError.cleanupFailed
    }
}

private let meetingTransferDefaultValidationSessionRecovery:
    MeetingTransferValidationSessionRecovery = { root in
        try MeetingTransferArchiveReader().recoverAbandonedSessions(
            validationRoot: root
        )
    }

private struct MeetingTransferTemporaryIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: uid_t
    let mode: mode_t
    let kind: mode_t

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        owner = status.st_uid
        mode = status.st_mode & mode_t(0o7777)
        kind = status.st_mode & S_IFMT
    }

    static func read(descriptor: Int32) throws -> Self {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        return Self(status)
    }

    static func read(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> Self? {
        var status = stat()
        if fstatat(directoryDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            return Self(status)
        }
        guard errno == ENOENT else {
            throw MeetingTransferExportCleanupError.notOwned
        }
        return nil
    }
}

private final class MeetingTransferOwnedDescriptor {
    private(set) var rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    func close() {
        guard rawValue >= 0 else { return }
        Darwin.close(rawValue)
        rawValue = -1
    }

    deinit {
        close()
    }
}

private enum MeetingTransferExportPackagePolicy: String, Codable {
    case singleDirectStenoMeeting
}

private struct MeetingTransferExportOwnershipMarker: Codable {
    static let schema = 2
    static let legacySchema = 1

    let schema: Int
    let token: UUID
    let rootName: String
    let rootIdentifier: UUID?
    let rootIdentity: MeetingTransferTemporaryIdentity
    let packagePolicy: MeetingTransferExportPackagePolicy?
    let packageName: String?
    let packageIdentity: MeetingTransferTemporaryIdentity?
    let meetingID: MeetingID
    let selectedAudioAssetIDs: Set<MediaAssetID>
    let contentDigest: String?
    let capabilities: Set<MeetingTransferCapability>?
    let totalByteCount: Int64?

    static func preparing(
        token: UUID,
        rootName: String,
        rootIdentifier: UUID,
        rootIdentity: MeetingTransferTemporaryIdentity,
        selection: MeetingTransferExportSelection
    ) -> Self {
        Self(
            schema: schema,
            token: token,
            rootName: rootName,
            rootIdentifier: rootIdentifier,
            rootIdentity: rootIdentity,
            packagePolicy: .singleDirectStenoMeeting,
            packageName: nil,
            packageIdentity: nil,
            meetingID: selection.meetingID,
            selectedAudioAssetIDs: selection.selectedAudioAssetIDs,
            contentDigest: nil,
            capabilities: nil,
            totalByteCount: nil
        )
    }

    var isSupported: Bool {
        schema == Self.schema || schema == Self.legacySchema
    }

    var selection: MeetingTransferExportSelection {
        MeetingTransferExportSelection(
            meetingID: meetingID,
            selectedAudioAssetIDs: selectedAudioAssetIDs
        )
    }
}

private enum MeetingTransferOwnedEntryKind: Equatable {
    case regularFile
    case directory

    var mode: mode_t {
        switch self {
        case .regularFile: S_IFREG
        case .directory: S_IFDIR
        }
    }

    var unlinkFlags: Int32 {
        let resolution = AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
        switch self {
        case .regularFile: return resolution | AT_UNIQUE
        case .directory: return resolution | AT_REMOVEDIR
        }
    }
}

private enum MeetingTransferNamespaceRemoval {
    static func remove(
        directoryDescriptor: Int32,
        directoryURL: URL,
        currentName: inout String,
        identity: MeetingTransferTemporaryIdentity,
        kind: MeetingTransferOwnedEntryKind,
        matchingDescriptor: Int32?,
        quarantinePrefix: String,
        checkpoint: ((URL) throws -> Void)?
    ) throws {
        let originalName = currentName
        let first = try moveToFreshQuarantine(
            directoryDescriptor: directoryDescriptor,
            sourceName: originalName,
            prefix: quarantinePrefix
        )
        currentName = first
        guard try entryMatches(
            directoryDescriptor: directoryDescriptor,
            name: first,
            identity: identity,
            kind: kind
        ) else {
            try restorePreservedEntry(
                directoryDescriptor: directoryDescriptor,
                sourceName: first,
                preferredName: originalName
            )
            currentName = originalName
            throw MeetingTransferExportCleanupError.notOwned
        }

        if let checkpoint {
            do {
                try checkpoint(directoryURL.appending(path: first))
            } catch {
                try restorePreservedEntry(
                    directoryDescriptor: directoryDescriptor,
                    sourceName: first,
                    preferredName: originalName
                )
                currentName = originalName
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
        }

        let second = try moveToFreshQuarantine(
            directoryDescriptor: directoryDescriptor,
            sourceName: first,
            prefix: quarantinePrefix
        )
        currentName = second
        guard try entryMatches(
            directoryDescriptor: directoryDescriptor,
            name: second,
            identity: identity,
            kind: kind
        ) else {
            try restorePreservedEntry(
                directoryDescriptor: directoryDescriptor,
                sourceName: second,
                preferredName: first
            )
            currentName = first
            throw MeetingTransferExportCleanupError.notOwned
        }

        guard unlinkat(directoryDescriptor, second, kind.unlinkFlags) == 0 else {
            try restorePreservedEntry(
                directoryDescriptor: directoryDescriptor,
                sourceName: second,
                preferredName: originalName
            )
            currentName = originalName
            throw MeetingTransferExportCleanupError.cleanupFailed
        }
        if let matchingDescriptor {
            var status = stat()
            guard fstat(matchingDescriptor, &status) == 0,
                  MeetingTransferTemporaryIdentity(status) == identity,
                  kind != .regularFile || status.st_nlink == 0 else {
                throw MeetingTransferExportCleanupError.notOwned
            }
        }
        currentName = ""
    }

    private static func moveToFreshQuarantine(
        directoryDescriptor: Int32,
        sourceName: String,
        prefix: String
    ) throws -> String {
        let flags = UInt32(
            RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
        )
        for _ in 0..<8 {
            let quarantine = "\(prefix)\(UUID().uuidString)"
            if renameatx_np(
                directoryDescriptor,
                sourceName,
                directoryDescriptor,
                quarantine,
                flags
            ) == 0 {
                return quarantine
            }
            if errno == EEXIST { continue }
            if errno == ENOENT {
                throw MeetingTransferExportCleanupError.notOwned
            }
            throw MeetingTransferExportCleanupError.cleanupFailed
        }
        throw MeetingTransferExportCleanupError.cleanupFailed
    }

    private static func entryMatches(
        directoryDescriptor: Int32,
        name: String,
        identity: MeetingTransferTemporaryIdentity,
        kind: MeetingTransferOwnedEntryKind
    ) throws -> Bool {
        guard let current = try MeetingTransferTemporaryIdentity.read(
            named: name,
            in: directoryDescriptor
        ) else { return false }
        return current == identity && current.kind == kind.mode
    }

    private static func restorePreservedEntry(
        directoryDescriptor: Int32,
        sourceName: String,
        preferredName: String
    ) throws {
        if renameatx_np(
            directoryDescriptor,
            sourceName,
            directoryDescriptor,
            preferredName,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
        ) == 0 || errno == EEXIST {
            return
        }
        throw MeetingTransferExportCleanupError.cleanupFailed
    }
}

@MainActor
final class MeetingTransferOwnedExport {
    private enum CleanupPhase {
        case removingEntries
        case rootRemovedAwaitingParentSync
        case complete
    }

    let result: MeetingTransferExportResult
    let selection: MeetingTransferExportSelection

    private let parentURL: URL
    private let parentDescriptor: MeetingTransferOwnedDescriptor
    private let parentIdentity: MeetingTransferTemporaryIdentity
    private let rootDescriptor: MeetingTransferOwnedDescriptor
    private let rootIdentity: MeetingTransferTemporaryIdentity
    private var rootName: String?
    private let packageDescriptor: MeetingTransferOwnedDescriptor?
    private let packageIdentity: MeetingTransferTemporaryIdentity?
    private var packageName: String?
    private let markerDescriptor: MeetingTransferOwnedDescriptor
    private let markerIdentity: MeetingTransferTemporaryIdentity
    private var markerName: String?
    private let namespaceCheckpoint: MeetingTransferExportNamespaceCheckpoint
    private let cleanupParentSync: MeetingTransferExportParentSync
    private let validationSessionRecovery: MeetingTransferValidationSessionRecovery
    private var cleanupPhase = CleanupPhase.removingEntries

    fileprivate init(
        result: MeetingTransferExportResult,
        selection: MeetingTransferExportSelection,
        parentURL: URL,
        parentDescriptor: MeetingTransferOwnedDescriptor,
        parentIdentity: MeetingTransferTemporaryIdentity,
        rootDescriptor: MeetingTransferOwnedDescriptor,
        rootIdentity: MeetingTransferTemporaryIdentity,
        rootName: String,
        packageDescriptor: MeetingTransferOwnedDescriptor?,
        packageIdentity: MeetingTransferTemporaryIdentity?,
        packageName: String?,
        markerDescriptor: MeetingTransferOwnedDescriptor,
        markerIdentity: MeetingTransferTemporaryIdentity,
        markerName: String,
        namespaceCheckpoint: @escaping MeetingTransferExportNamespaceCheckpoint,
        cleanupParentSync: @escaping MeetingTransferExportParentSync,
        validationSessionRecovery: @escaping MeetingTransferValidationSessionRecovery
    ) {
        self.result = result
        self.selection = selection
        self.parentURL = parentURL
        self.parentDescriptor = parentDescriptor
        self.parentIdentity = parentIdentity
        self.rootDescriptor = rootDescriptor
        self.rootIdentity = rootIdentity
        self.rootName = rootName
        self.packageDescriptor = packageDescriptor
        self.packageIdentity = packageIdentity
        self.packageName = packageName
        self.markerDescriptor = markerDescriptor
        self.markerIdentity = markerIdentity
        self.markerName = markerName
        self.namespaceCheckpoint = namespaceCheckpoint
        self.cleanupParentSync = cleanupParentSync
        self.validationSessionRecovery = validationSessionRecovery
    }

    func cleanup() throws {
        switch cleanupPhase {
        case .complete:
            return
        case .rootRemovedAwaitingParentSync:
            try finishParentSync()
            return
        case .removingEntries:
            break
        }
        guard parentDescriptor.rawValue >= 0,
              rootDescriptor.rawValue >= 0,
              try MeetingTransferTemporaryIdentity.read(
                  descriptor: parentDescriptor.rawValue
              ) == parentIdentity,
              try MeetingTransferTemporaryIdentity.read(
                  descriptor: rootDescriptor.rawValue
              ) == rootIdentity,
              rootIdentity.kind == S_IFDIR,
              rootIdentity.owner == geteuid(),
              rootIdentity.mode == 0o700,
              rootName.flatMap({ try? MeetingTransferTemporaryIdentity.read(
                named: $0,
                in: parentDescriptor.rawValue
              ) }) == rootIdentity,
              flock(rootDescriptor.rawValue, LOCK_EX | LOCK_NB) == 0
        else {
            throw MeetingTransferExportCleanupError.notOwned
        }

        try recoverMeetingTransferValidationSessions(
            parentDescriptor: parentDescriptor.rawValue,
            rootDescriptor: rootDescriptor.rawValue,
            rootIdentity: rootIdentity,
            rootName: try currentRootName(),
            rootURL: currentRootURL,
            recovery: validationSessionRecovery
        )

        let expectedEntries = Set([packageName, markerName].compactMap { $0 })
        guard Set(try directoryEntries(rootDescriptor.rawValue)) == expectedEntries else {
            throw MeetingTransferExportCleanupError.unexpectedEntry
        }

        if var currentPackageName = packageName,
           let packageIdentity {
            try MeetingTransferNamespaceRemoval.remove(
                directoryDescriptor: rootDescriptor.rawValue,
                directoryURL: currentRootURL,
                currentName: &currentPackageName,
                identity: packageIdentity,
                kind: .regularFile,
                matchingDescriptor: packageDescriptor?.rawValue,
                quarantinePrefix: ".Steno-MeetingTransferPackage-Quarantine-",
                checkpoint: { url in
                    try self.namespaceCheckpoint(.beforePackageRemoval(url))
                }
            )
            packageName = currentPackageName.isEmpty ? nil : currentPackageName
            guard fsync(rootDescriptor.rawValue) == 0 else {
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
        }

        if var currentMarkerName = markerName {
            try MeetingTransferNamespaceRemoval.remove(
                directoryDescriptor: rootDescriptor.rawValue,
                directoryURL: currentRootURL,
                currentName: &currentMarkerName,
                identity: markerIdentity,
                kind: .regularFile,
                matchingDescriptor: markerDescriptor.rawValue,
                quarantinePrefix: ".Steno-MeetingTransferMarker-Quarantine-",
                checkpoint: nil
            )
            markerName = currentMarkerName.isEmpty ? nil : currentMarkerName
            guard fsync(rootDescriptor.rawValue) == 0 else {
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
        }

        guard try directoryEntries(rootDescriptor.rawValue).isEmpty,
              var currentRootName = rootName else {
            throw MeetingTransferExportCleanupError.unexpectedEntry
        }
        try MeetingTransferNamespaceRemoval.remove(
            directoryDescriptor: parentDescriptor.rawValue,
            directoryURL: parentURL,
            currentName: &currentRootName,
            identity: rootIdentity,
            kind: .directory,
            matchingDescriptor: rootDescriptor.rawValue,
            quarantinePrefix: ".Steno-MeetingTransferExport-Quarantine-",
            checkpoint: { url in
                try self.namespaceCheckpoint(.beforeRootRemoval(url))
            }
        )
        rootName = currentRootName.isEmpty ? nil : currentRootName
        cleanupPhase = .rootRemovedAwaitingParentSync
        try finishParentSync()
    }

    private func finishParentSync() throws {
        guard parentDescriptor.rawValue >= 0,
              try MeetingTransferTemporaryIdentity.read(
                descriptor: parentDescriptor.rawValue
              ) == parentIdentity else {
            throw MeetingTransferExportCleanupError.notOwned
        }
        try cleanupParentSync(parentDescriptor.rawValue)
        cleanupPhase = .complete
        _ = flock(rootDescriptor.rawValue, LOCK_UN)
        packageDescriptor?.close()
        markerDescriptor.close()
        rootDescriptor.close()
        parentDescriptor.close()
    }

    private var currentRootURL: URL {
        parentURL.appending(path: rootName ?? result.cleanupRoot.lastPathComponent)
    }

    private func currentRootName() throws -> String {
        guard let rootName else {
            throw MeetingTransferExportCleanupError.notOwned
        }
        return rootName
    }
}

@MainActor
struct MeetingTransferExportWorkspace {
    fileprivate static let rootPrefix = "Steno-MeetingTransferExport-"
    fileprivate static let markerName = ".steno-export-owner"

    let rootURL: URL
    private let parentDirectory: URL
    private let identifier: UUID
    private let selection: MeetingTransferExportSelection
    private let namespaceCheckpoint: MeetingTransferExportNamespaceCheckpoint
    private let cleanupParentSync: MeetingTransferExportParentSync
    private let validationSessionRecovery: MeetingTransferValidationSessionRecovery

    init(
        parentDirectory: URL,
        identifier: UUID = UUID(),
        selection: MeetingTransferExportSelection = .init(
            meetingID: MeetingID(),
            selectedAudioAssetIDs: []
        ),
        namespaceCheckpoint: @escaping MeetingTransferExportNamespaceCheckpoint = { _ in },
        cleanupParentSync: @escaping MeetingTransferExportParentSync =
            meetingTransferDefaultParentSync,
        validationSessionRecovery: @escaping MeetingTransferValidationSessionRecovery =
            meetingTransferDefaultValidationSessionRecovery
    ) {
        self.parentDirectory = parentDirectory.standardizedFileURL
        self.identifier = identifier
        self.selection = selection
        self.namespaceCheckpoint = namespaceCheckpoint
        self.cleanupParentSync = cleanupParentSync
        self.validationSessionRecovery = validationSessionRecovery
        rootURL = parentDirectory.standardizedFileURL.appending(
            path: "\(Self.rootPrefix)\(identifier.uuidString)",
            directoryHint: .isDirectory
        )
    }

    func perform(
        _ operation: @escaping (URL) async throws -> MeetingTransferExportResult
    ) async throws -> MeetingTransferOwnedExport {
        let parentRaw = open(
            parentDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentRaw >= 0 else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        let parentDescriptor = MeetingTransferOwnedDescriptor(parentRaw)
        let parentIdentity = try MeetingTransferTemporaryIdentity.read(
            descriptor: parentRaw
        )
        guard parentIdentity.kind == S_IFDIR,
              parentIdentity.owner == geteuid(),
              mkdirat(parentRaw, rootURL.lastPathComponent, S_IRWXU) == 0 else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }

        let rootRaw = openat(
            parentRaw,
            rootURL.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootRaw >= 0 else {
            _ = unlinkat(parentRaw, rootURL.lastPathComponent, AT_REMOVEDIR)
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        let rootDescriptor = MeetingTransferOwnedDescriptor(rootRaw)
        let initialRootIdentity = try MeetingTransferTemporaryIdentity.read(
            descriptor: rootRaw
        )

        do {
            guard initialRootIdentity.kind == S_IFDIR,
                  initialRootIdentity.owner == geteuid(),
                  initialRootIdentity.mode == 0o700,
                  try MeetingTransferTemporaryIdentity.read(
                      named: rootURL.lastPathComponent,
                      in: parentRaw
                  ) == initialRootIdentity,
                  flock(rootRaw, LOCK_SH | LOCK_NB) == 0 else {
                throw MeetingTransferExportCleanupError.invalidTemporaryExport
            }
            try excludeFromBackup(rootURL)
            let marker = MeetingTransferExportOwnershipMarker.preparing(
                token: UUID(),
                rootName: rootURL.lastPathComponent,
                rootIdentifier: identifier,
                rootIdentity: initialRootIdentity,
                selection: selection
            )
            let markerDescriptor = try createMarker(marker, in: rootRaw)
            let markerIdentity = try MeetingTransferTemporaryIdentity.read(
                descriptor: markerDescriptor.rawValue
            )
            guard markerIdentity.kind == S_IFREG,
                  markerIdentity.owner == geteuid(),
                  markerIdentity.mode == 0o600,
                  Set(try directoryEntries(rootRaw)) == [Self.markerName],
                  fsync(rootRaw) == 0,
                  fsync(parentRaw) == 0 else {
                throw MeetingTransferExportCleanupError.invalidTemporaryExport
            }
            try Task.checkCancellation()
            let result = try await operation(rootURL)
            let packageName = try validateResult(result)
            let initialEntries = try directoryEntries(rootRaw)
            guard Set(initialEntries) == [packageName, Self.markerName] else {
                throw MeetingTransferExportCleanupError.invalidTemporaryExport
            }
            let packageRaw = openat(
                rootRaw,
                packageName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard packageRaw >= 0 else {
                throw MeetingTransferExportCleanupError.invalidTemporaryExport
            }
            let packageDescriptor = MeetingTransferOwnedDescriptor(packageRaw)
            let packageIdentity = try MeetingTransferTemporaryIdentity.read(
                descriptor: packageRaw
            )
            guard packageIdentity.kind == S_IFREG,
                  packageIdentity.owner == geteuid(),
                  try MeetingTransferTemporaryIdentity.read(
                      named: packageName,
                      in: rootRaw
                  ) == packageIdentity else {
                throw MeetingTransferExportCleanupError.invalidTemporaryExport
            }
            try excludeFromBackup(result.packageURL)
            let finalEntries = try directoryEntries(rootRaw)
            guard Set(finalEntries) == [packageName, Self.markerName],
                  fsync(rootRaw) == 0,
                  fsync(parentRaw) == 0 else {
                throw MeetingTransferExportCleanupError.invalidTemporaryExport
            }
            return MeetingTransferOwnedExport(
                result: result,
                selection: selection,
                parentURL: parentDirectory,
                parentDescriptor: parentDescriptor,
                parentIdentity: parentIdentity,
                rootDescriptor: rootDescriptor,
                rootIdentity: initialRootIdentity,
                rootName: rootURL.lastPathComponent,
                packageDescriptor: packageDescriptor,
                packageIdentity: packageIdentity,
                packageName: packageName,
                markerDescriptor: markerDescriptor,
                markerIdentity: markerIdentity,
                markerName: Self.markerName,
                namespaceCheckpoint: namespaceCheckpoint,
                cleanupParentSync: cleanupParentSync,
                validationSessionRecovery: validationSessionRecovery
            )
        } catch {
            let operationError = error
            _ = flock(rootRaw, LOCK_EX | LOCK_NB)
            do {
                try removeUnpublishedRoot(
                    parentDescriptor: parentRaw,
                    rootDescriptor: rootRaw,
                    rootIdentity: initialRootIdentity
                )
            } catch {
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
            throw operationError
        }
    }

    private func validateResult(_ result: MeetingTransferExportResult) throws -> String {
        let cleanupRoot = result.cleanupRoot.standardizedFileURL
        let packageURL = result.packageURL.standardizedFileURL
        guard cleanupRoot == rootURL,
              packageURL.deletingLastPathComponent() == rootURL,
              packageURL.pathExtension.caseInsensitiveCompare("stenomeeting") == .orderedSame,
              isSafeName(packageURL.lastPathComponent)
        else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        return packageURL.lastPathComponent
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        let verified = try mutableURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        guard verified.isExcludedFromBackup == true else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
    }

    private func createMarker(
        _ marker: MeetingTransferExportOwnershipMarker,
        in rootDescriptor: Int32
    ) throws -> MeetingTransferOwnedDescriptor {
        let raw = openat(
            rootDescriptor,
            Self.markerName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard raw >= 0 else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        let descriptor = MeetingTransferOwnedDescriptor(raw)
        let data = try JSONEncoder().encode(marker)
        try writeAll(data, to: raw)
        guard fsync(raw) == 0 else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        return descriptor
    }

    private func removeUnpublishedRoot(
        parentDescriptor: Int32,
        rootDescriptor: Int32,
        rootIdentity: MeetingTransferTemporaryIdentity
    ) throws {
        guard try MeetingTransferTemporaryIdentity.read(
            named: rootURL.lastPathComponent,
            in: parentDescriptor
        ) == rootIdentity else {
            throw MeetingTransferExportCleanupError.notOwned
        }
        if let markerIdentity = try MeetingTransferTemporaryIdentity.read(
            named: Self.markerName,
            in: rootDescriptor
        ),
           markerIdentity.kind == S_IFREG,
           markerIdentity.owner == geteuid(),
           markerIdentity.mode == 0o600 {
            try recoverMeetingTransferValidationSessions(
                parentDescriptor: parentDescriptor,
                rootDescriptor: rootDescriptor,
                rootIdentity: rootIdentity,
                rootName: rootURL.lastPathComponent,
                rootURL: rootURL,
                recovery: validationSessionRecovery
            )
            guard try MeetingTransferTemporaryIdentity.read(
                named: Self.markerName,
                in: rootDescriptor
            ) == markerIdentity else {
                throw MeetingTransferExportCleanupError.notOwned
            }
        }
        let entries = try directoryEntries(rootDescriptor).sorted { left, right in
            if left == Self.markerName { return false }
            if right == Self.markerName { return true }
            return left < right
        }
        let payloadEntries = entries.filter { $0 != Self.markerName }
        guard entries.contains(Self.markerName),
              payloadEntries.count <= 1,
              payloadEntries.allSatisfy(isAllowedUnpublishedPayloadName) else {
            throw MeetingTransferExportCleanupError.unexpectedEntry
        }
        for name in entries {
            guard isSafeName(name) else {
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
            let raw = openat(
                rootDescriptor,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard raw >= 0 else {
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
            let descriptor = MeetingTransferOwnedDescriptor(raw)
            let identity = try MeetingTransferTemporaryIdentity.read(
                descriptor: raw
            )
            guard identity.kind == S_IFREG, identity.owner == geteuid() else {
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
            var currentName = name
            try MeetingTransferNamespaceRemoval.remove(
                directoryDescriptor: rootDescriptor,
                directoryURL: rootURL,
                currentName: &currentName,
                identity: identity,
                kind: .regularFile,
                matchingDescriptor: raw,
                quarantinePrefix: ".Steno-MeetingTransferUnpublished-Quarantine-",
                checkpoint: nil
            )
            descriptor.close()
        }
        guard fsync(rootDescriptor) == 0 else {
            throw MeetingTransferExportCleanupError.cleanupFailed
        }
        var currentRootName = rootURL.lastPathComponent
        try MeetingTransferNamespaceRemoval.remove(
            directoryDescriptor: parentDescriptor,
            directoryURL: parentDirectory,
            currentName: &currentRootName,
            identity: rootIdentity,
            kind: .directory,
            matchingDescriptor: rootDescriptor,
            quarantinePrefix: ".Steno-MeetingTransferExport-Quarantine-",
            checkpoint: nil
        )
        guard fsync(parentDescriptor) == 0 else {
            throw MeetingTransferExportCleanupError.cleanupFailed
        }
    }
}

@MainActor
private func recoverMeetingTransferValidationSessions(
    parentDescriptor: Int32,
    rootDescriptor: Int32,
    rootIdentity: MeetingTransferTemporaryIdentity,
    rootName: String,
    rootURL: URL,
    recovery: MeetingTransferValidationSessionRecovery
) throws {
    guard try MeetingTransferTemporaryIdentity.read(
        descriptor: rootDescriptor
    ) == rootIdentity,
        try MeetingTransferTemporaryIdentity.read(
            named: rootName,
            in: parentDescriptor
        ) == rootIdentity else {
        throw MeetingTransferExportCleanupError.notOwned
    }

    _ = flock(rootDescriptor, LOCK_UN)
    let recoveryError: (any Error)?
    do {
        try recovery(rootURL)
        recoveryError = nil
    } catch {
        recoveryError = error
    }

    guard flock(rootDescriptor, LOCK_EX | LOCK_NB) == 0,
          try MeetingTransferTemporaryIdentity.read(
            descriptor: rootDescriptor
          ) == rootIdentity,
          try MeetingTransferTemporaryIdentity.read(
            named: rootName,
            in: parentDescriptor
          ) == rootIdentity else {
        throw MeetingTransferExportCleanupError.notOwned
    }
    if let recoveryError {
        throw recoveryError
    }
}

private func isSafeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
}

private func isAllowedUnpublishedPayloadName(_ name: String) -> Bool {
    guard isSafeName(name) else { return false }
    if name.hasSuffix(".stenomeeting") { return true }
    let prefixes = [
        ".stenomeeting-staging-",
        ".stenomeeting-quarantine-",
        ".Steno-MeetingTransferPackage-Quarantine-",
        ".Steno-MeetingTransferUnpublished-Quarantine-",
    ]
    return prefixes.contains { prefix in
        name.hasPrefix(prefix)
            && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
}

private func directoryEntries(_ descriptor: Int32) throws -> [String] {
    let duplicate = dup(descriptor)
    guard duplicate >= 0,
          lseek(duplicate, 0, SEEK_SET) >= 0,
          let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { Darwin.close(duplicate) }
        throw MeetingTransferExportCleanupError.cleanupFailed
    }
    defer { closedir(directory) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if name != "." && name != ".." { names.append(name) }
        errno = 0
    }
    guard errno == 0 else {
        throw MeetingTransferExportCleanupError.cleanupFailed
    }
    return names.sorted()
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                data.count - offset
            )
        }
        guard written > 0 else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        offset += written
    }
}

private func readAll(from descriptor: Int32) throws -> Data {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_size > 0,
          status.st_size <= 64 * 1024 else {
        throw MeetingTransferExportCleanupError.invalidTemporaryExport
    }
    var data = Data(count: Int(status.st_size))
    let count = data.count
    let readCount = data.withUnsafeMutableBytes { bytes in
        pread(descriptor, bytes.baseAddress, count, 0)
    }
    guard readCount == count else {
        throw MeetingTransferExportCleanupError.invalidTemporaryExport
    }
    return data
}

enum MeetingTransferShareOutcome: Equatable {
    case shared
    case cancelled
    case failed(String)
}

enum MeetingTransferSharingError: LocalizedError, Equatable {
    case serviceUnavailable
    case sharingStillActive
    case selectionChanged
    case cleanupRequired

    var errorDescription: String? {
        message()
    }

    func message(locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = switch self {
        case .serviceUnavailable:
            "AirDrop could not be opened directly. Activate Share meeting again to open the system Share menu, then choose AirDrop."
        case .sharingStillActive:
            "Another meeting share is still active or needs cleanup. Finish or clean it before sharing another meeting."
        case .selectionChanged:
            "The meeting selection changed. Steno removed the old package; activate Share meeting again to create the current selection."
        case .cleanupRequired:
            "An earlier temporary meeting export needs cleanup before another meeting can be shared."
        }
        var localizedResource = resource
        localizedResource.locale = locale
        return String(localized: localizedResource)
    }
}

enum MeetingTransferSharingState: Equatable {
    case prepared
    case sharing
    case completed
    case cancelled
    case failed(String)
    case cleanupRequired(String)
}

@MainActor
protocol MeetingTransferSharePerforming: AnyObject {
    func start() throws
    func cancelIfPossible() -> Bool
}

typealias MeetingTransferSharePerformerFactory = @MainActor (
    _ packageURL: URL,
    _ anchor: NSView?,
    _ completion: @escaping (MeetingTransferShareOutcome) -> Void
) throws -> any MeetingTransferSharePerforming

@MainActor
@Observable
final class MeetingTransferSharingRegistry {
    static let process = MeetingTransferSharingRegistry()

    fileprivate var currentSession: MeetingTransferSharingSession?
    fileprivate var isPreparingExport = false

    fileprivate func release(_ id: UUID) {
        guard currentSession?.id == id else { return }
        currentSession = nil
    }

#if DEBUG
    func simulateProcessExitForTesting() {
        currentSession = nil
        isPreparingExport = false
    }
#endif
}

@MainActor
@Observable
final class MeetingTransferSharing {
    static let shared = MeetingTransferSharing()

    private let performerFactory: MeetingTransferSharePerformerFactory
    private let registry: MeetingTransferSharingRegistry
    private let cleanupParentSync: MeetingTransferExportParentSync
    private let validationSessionRecovery: MeetingTransferValidationSessionRecovery
    var currentSession: MeetingTransferSharingSession? {
        registry.currentSession
    }
    var pendingCleanupSession: MeetingTransferSharingSession? {
        guard case .cleanupRequired = currentSession?.state else { return nil }
        return currentSession
    }

    init(
        performerFactory: @escaping MeetingTransferSharePerformerFactory = {
            packageURL,
            anchor,
            completion in
            MeetingTransferSystemSharePerformer(
                packageURL: packageURL,
                anchor: anchor,
                completion: completion
            )
        },
        registry: MeetingTransferSharingRegistry = .process,
        cleanupParentSync: @escaping MeetingTransferExportParentSync =
            meetingTransferDefaultParentSync,
        validationSessionRecovery: @escaping MeetingTransferValidationSessionRecovery =
            meetingTransferDefaultValidationSessionRecovery
    ) {
        self.performerFactory = performerFactory
        self.registry = registry
        self.cleanupParentSync = cleanupParentSync
        self.validationSessionRecovery = validationSessionRecovery
    }

    func prepareExport(
        parentDirectory: URL,
        selection: MeetingTransferExportSelection,
        operation: @escaping (URL) async throws -> MeetingTransferExportResult
    ) async throws -> MeetingTransferSharingSession {
        guard currentSession == nil, !registry.isPreparingExport else {
            throw MeetingTransferSharingError.sharingStillActive
        }
        _ = try recoverAbandonedExports(parentDirectory: parentDirectory)
        guard currentSession == nil else {
            throw MeetingTransferSharingError.cleanupRequired
        }
        registry.isPreparingExport = true
        defer { registry.isPreparingExport = false }
        let workspace = MeetingTransferExportWorkspace(
            parentDirectory: parentDirectory,
            selection: selection,
            cleanupParentSync: cleanupParentSync,
            validationSessionRecovery: validationSessionRecovery
        )
        let ownedExport = try await workspace.perform(operation)
        let session = register(ownedExport, selection: selection)
        do {
            try Task.checkCancellation()
        } catch {
            try session.cleanupPrepared()
            throw error
        }
        return session
    }

    @discardableResult
    func recoverAbandonedExports(parentDirectory: URL) throws -> [String] {
        guard currentSession == nil, !registry.isPreparingExport else {
            throw MeetingTransferSharingError.sharingStillActive
        }
        let scan = try recoverableExports(parentDirectory: parentDirectory)
        for ownedExport in scan.exports {
            do {
                try ownedExport.cleanup()
            } catch {
                let session = MeetingTransferSharingSession(
                    ownedExport: ownedExport,
                    selection: ownedExport.selection,
                    performerFactory: performerFactory,
                    registry: registry,
                    initialState: .cleanupRequired(error.localizedDescription)
                )
                registry.currentSession = session
                throw MeetingTransferSharingError.cleanupRequired
            }
        }
        return scan.warnings
    }

    private func register(
        _ ownedExport: MeetingTransferOwnedExport,
        selection: MeetingTransferExportSelection
    ) -> MeetingTransferSharingSession {
        precondition(
            registry.isPreparingExport && currentSession == nil,
            "export registration must remain inside its process-wide reservation"
        )
        let session = MeetingTransferSharingSession(
            ownedExport: ownedExport,
            selection: selection,
            performerFactory: performerFactory,
            registry: registry,
            initialState: .prepared
        )
        registry.currentSession = session
        return session
    }

    private func recoverableExports(
        parentDirectory: URL
    ) throws -> (exports: [MeetingTransferOwnedExport], warnings: [String]) {
        let parentURL = parentDirectory.standardizedFileURL
        let parentRaw = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentRaw >= 0 else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }
        defer { Darwin.close(parentRaw) }
        let parentIdentity = try MeetingTransferTemporaryIdentity.read(
            descriptor: parentRaw
        )
        guard parentIdentity.kind == S_IFDIR, parentIdentity.owner == geteuid() else {
            throw MeetingTransferExportCleanupError.invalidTemporaryExport
        }

        var recovered: [MeetingTransferOwnedExport] = []
        var warnings: [String] = []
        for rootName in try directoryEntries(parentRaw) where isExportRootName(rootName) {
            let rootRaw = openat(
                parentRaw,
                rootName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rootRaw >= 0 else {
                warnings.append(Self.manualCleanupWarning)
                continue
            }
            var shouldCloseRoot = true
            defer { if shouldCloseRoot { Darwin.close(rootRaw) } }
            guard let rootIdentity = try? MeetingTransferTemporaryIdentity.read(
                descriptor: rootRaw
            ),
                rootIdentity.kind == S_IFDIR,
                rootIdentity.owner == geteuid(),
                rootIdentity.mode == 0o700 else {
                warnings.append(Self.manualCleanupWarning)
                continue
            }
            guard flock(rootRaw, LOCK_EX | LOCK_NB) == 0 else { continue }

            let markerRaw = openat(
                rootRaw,
                MeetingTransferExportWorkspace.markerName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard markerRaw >= 0 else {
                if !((try? directoryEntries(rootRaw)) ?? []).isEmpty {
                    warnings.append(Self.manualCleanupWarning)
                }
                _ = flock(rootRaw, LOCK_UN)
                continue
            }
            var shouldCloseMarker = true
            defer { if shouldCloseMarker { Darwin.close(markerRaw) } }
            guard let markerIdentity = try? MeetingTransferTemporaryIdentity.read(
                descriptor: markerRaw
            ),
                markerIdentity.kind == S_IFREG,
                markerIdentity.owner == geteuid(),
                markerIdentity.mode == 0o600,
                let markerData = try? readAll(from: markerRaw),
                let marker = try? JSONDecoder().decode(
                    MeetingTransferExportOwnershipMarker.self,
                    from: markerData
                ),
                marker.isSupported,
                marker.rootIdentity == rootIdentity,
                markerRootMatches(marker, currentRootName: rootName) else {
                warnings.append(Self.manualCleanupWarning)
                _ = flock(rootRaw, LOCK_UN)
                continue
            }

            let entries = (try? directoryEntries(rootRaw)) ?? []
            let payloadEntries = entries.filter {
                $0 != MeetingTransferExportWorkspace.markerName
            }
            var currentPackageName: String?
            var currentPackageIdentity: MeetingTransferTemporaryIdentity?
            var packageDescriptor: MeetingTransferOwnedDescriptor?
            let matchedPackages = payloadEntries.compactMap { name
                -> (String, MeetingTransferTemporaryIdentity)? in
                guard isAllowedOwnedPackageName(name, marker: marker),
                      let identity = try? MeetingTransferTemporaryIdentity.read(
                        named: name,
                        in: rootRaw
                      ),
                      identity.kind == S_IFREG,
                      identity.owner == geteuid(),
                      marker.schema
                        != MeetingTransferExportOwnershipMarker.legacySchema
                        || identity == marker.packageIdentity else {
                    return nil
                }
                return (name, identity)
            }
            if matchedPackages.count == 1,
               let (matchedName, identity) = matchedPackages.first {
                let packageRaw = openat(
                    rootRaw,
                    matchedName,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                if packageRaw >= 0 {
                    let descriptor = MeetingTransferOwnedDescriptor(packageRaw)
                    if (try? MeetingTransferTemporaryIdentity.read(
                        descriptor: packageRaw
                    )) == identity {
                        currentPackageName = matchedName
                        currentPackageIdentity = identity
                        packageDescriptor = descriptor
                    } else {
                        descriptor.close()
                    }
                }
            }

            let ownedParentRaw = dup(parentRaw)
            guard ownedParentRaw >= 0 else {
                _ = flock(rootRaw, LOCK_UN)
                throw MeetingTransferExportCleanupError.cleanupFailed
            }
            let resultPackageName = currentPackageName
                ?? marker.packageName
                ?? "Abandoned.stenomeeting"
            let result = MeetingTransferExportResult(
                packageURL: parentURL
                    .appending(path: rootName, directoryHint: .isDirectory)
                    .appending(path: resultPackageName),
                cleanupRoot: parentURL.appending(
                    path: rootName,
                    directoryHint: .isDirectory
                ),
                contentDigest: marker.contentDigest ?? "",
                capabilities: marker.capabilities ?? [],
                totalByteCount: marker.totalByteCount ?? 0
            )
            let owned = MeetingTransferOwnedExport(
                result: result,
                selection: marker.selection,
                parentURL: parentURL,
                parentDescriptor: MeetingTransferOwnedDescriptor(ownedParentRaw),
                parentIdentity: parentIdentity,
                rootDescriptor: MeetingTransferOwnedDescriptor(rootRaw),
                rootIdentity: rootIdentity,
                rootName: rootName,
                packageDescriptor: packageDescriptor,
                packageIdentity: currentPackageIdentity,
                packageName: currentPackageName,
                markerDescriptor: MeetingTransferOwnedDescriptor(markerRaw),
                markerIdentity: markerIdentity,
                markerName: MeetingTransferExportWorkspace.markerName,
                namespaceCheckpoint: { _ in },
                cleanupParentSync: cleanupParentSync,
                validationSessionRecovery: validationSessionRecovery
            )
            shouldCloseRoot = false
            shouldCloseMarker = false
            recovered.append(owned)
        }
        return (recovered, Array(Set(warnings)))
    }

    static let manualCleanupWarning = String(localized: "A temporary meeting export could not be verified and was preserved for manual cleanup.")

    private func markerRootMatches(
        _ marker: MeetingTransferExportOwnershipMarker,
        currentRootName: String
    ) -> Bool {
        guard isSafeName(marker.rootName),
              marker.rootName.hasPrefix(MeetingTransferExportWorkspace.rootPrefix),
              let identifier = UUID(uuidString: String(
                marker.rootName.dropFirst(MeetingTransferExportWorkspace.rootPrefix.count)
              )) else { return false }
        if marker.schema == MeetingTransferExportOwnershipMarker.schema {
            guard marker.rootIdentifier == identifier,
                  marker.packagePolicy == .singleDirectStenoMeeting else {
                return false
            }
        }
        return currentRootName == marker.rootName
            || currentRootName.hasPrefix(".Steno-MeetingTransferExport-Quarantine-")
    }

    private func isAllowedOwnedPackageName(
        _ name: String,
        marker: MeetingTransferExportOwnershipMarker
    ) -> Bool {
        guard isSafeName(name) else { return false }
        if marker.schema == MeetingTransferExportOwnershipMarker.legacySchema {
            return marker.packageName != nil
        }
        if name.hasSuffix(".stenomeeting") { return true }
        let prefixes = [
            ".stenomeeting-staging-",
            ".stenomeeting-quarantine-",
            ".Steno-MeetingTransferPackage-Quarantine-",
            ".Steno-MeetingTransferUnpublished-Quarantine-",
        ]
        return prefixes.contains { prefix in
            name.hasPrefix(prefix)
                && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
    }

    private func isExportRootName(_ name: String) -> Bool {
        let prefixes = [
            MeetingTransferExportWorkspace.rootPrefix,
            ".Steno-MeetingTransferExport-Quarantine-",
        ]
        for prefix in prefixes where name.hasPrefix(prefix) {
            if UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
                return true
            }
        }
        return false
    }
}

@MainActor
@Observable
final class MeetingTransferSharingSession {
    let id = UUID()
    let result: MeetingTransferExportResult
    let selection: MeetingTransferExportSelection
    private(set) var state: MeetingTransferSharingState

    private let ownedExport: MeetingTransferOwnedExport
    private let performerFactory: MeetingTransferSharePerformerFactory
    private let registry: MeetingTransferSharingRegistry
    private var performer: (any MeetingTransferSharePerforming)?
    private var operationID: UUID?
    private var completedOutcome: MeetingTransferShareOutcome?

    fileprivate init(
        ownedExport: MeetingTransferOwnedExport,
        selection: MeetingTransferExportSelection,
        performerFactory: @escaping MeetingTransferSharePerformerFactory,
        registry: MeetingTransferSharingRegistry,
        initialState: MeetingTransferSharingState
    ) {
        self.ownedExport = ownedExport
        result = ownedExport.result
        self.selection = selection
        self.performerFactory = performerFactory
        self.registry = registry
        state = initialState
    }

    func start(anchor: NSView?) throws {
        try start(anchor: anchor, selection: selection)
    }

    func start(
        anchor: NSView?,
        selection requestedSelection: MeetingTransferExportSelection
    ) throws {
        guard state == .prepared, performer == nil else { return }
        guard requestedSelection == selection else {
            try cleanupPrepared()
            throw MeetingTransferSharingError.selectionChanged
        }
        let newOperationID = UUID()
        do {
            let created = try performerFactory(
                result.packageURL,
                anchor
            ) { [weak self] outcome in
                self?.complete(outcome, operationID: newOperationID)
            }
            operationID = newOperationID
            performer = created
            state = .sharing
            try created.start()
        } catch {
            let startError = error
            performer = nil
            operationID = nil
            completedOutcome = .failed(startError.localizedDescription)
            state = .cleanupRequired(startError.localizedDescription)
            do {
                try ownedExport.cleanup()
                state = .failed(startError.localizedDescription)
                registry.release(id)
            } catch {
                state = .cleanupRequired(error.localizedDescription)
            }
            throw startError
        }
    }

    func presentationDidClose() {
        switch state {
        case .prepared:
            do {
                try cleanupPrepared()
            } catch {
                state = .cleanupRequired(error.localizedDescription)
            }
        case .sharing:
            // Der direkte AirDrop-Service bietet keine belastbare Cancel-API.
            // Ohne Abschluss-Callback bleibt das Paket bestehen, statt während
            // eines möglicherweise noch laufenden Reads gelöscht zu werden.
            _ = performer?.cancelIfPossible()
        case .completed, .cancelled, .failed, .cleanupRequired:
            break
        }
    }

    func cleanupPrepared() throws {
        guard state == .prepared else { return }
        do {
            try ownedExport.cleanup()
            state = .cancelled
            registry.release(id)
        } catch {
            state = .cleanupRequired(error.localizedDescription)
            throw error
        }
    }

    func retryCleanup() throws {
        guard case .cleanupRequired = state else { return }
        do {
            try ownedExport.cleanup()
            applyTerminalState(completedOutcome ?? .cancelled)
            registry.release(id)
        } catch {
            state = .cleanupRequired(error.localizedDescription)
            throw error
        }
    }

    private func complete(
        _ outcome: MeetingTransferShareOutcome,
        operationID callbackOperationID: UUID
    ) {
        guard operationID == callbackOperationID, state == .sharing else { return }
        operationID = nil
        performer = nil
        completedOutcome = outcome
        do {
            try ownedExport.cleanup()
            applyTerminalState(outcome)
            registry.release(id)
        } catch {
            state = .cleanupRequired(error.localizedDescription)
        }
    }

    private func applyTerminalState(_ outcome: MeetingTransferShareOutcome) {
        switch outcome {
        case .shared:
            state = .completed
        case .cancelled:
            state = .cancelled
        case .failed(let message):
            state = .failed(message)
        }
    }
}

@MainActor
final class MeetingTransferSystemSharePerformer: NSObject,
    MeetingTransferSharePerforming,
    NSSharingServiceDelegate,
    @preconcurrency NSSharingServicePickerDelegate
{
    private let packageURL: URL
    private weak var anchor: NSView?
    private var completion: ((MeetingTransferShareOutcome) -> Void)?
    private var service: NSSharingService?
    private var picker: NSSharingServicePicker?
    private var pickerMenu: NSMenu?

    init(
        packageURL: URL,
        anchor: NSView?,
        completion: @escaping (MeetingTransferShareOutcome) -> Void
    ) {
        self.packageURL = packageURL
        self.anchor = anchor
        self.completion = completion
    }

    static func activityItems(packageURL: URL) -> [Any] {
        [packageURL]
    }

    func start() throws {
        let items = Self.activityItems(packageURL: packageURL)
        if let airDrop = NSSharingService(named: .sendViaAirDrop),
           airDrop.canPerform(withItems: items) {
            service = airDrop
            airDrop.delegate = self
            airDrop.perform(withItems: items)
            return
        }

        guard let anchor, let event = NSApp.currentEvent else {
            throw MeetingTransferSharingError.serviceUnavailable
        }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        // `show(relativeTo:)` muss laut AppKit aus mouseDown heraus laufen.
        // Der Standard-Menüeintrag bleibt am auslösenden Event und lässt die
        // Auswahl weiterhin vollständig beim System.
        let menu = NSMenu()
        menu.addItem(picker.standardShareMenuItem)
        pickerMenu = menu
        NSMenu.popUpContextMenu(menu, with: event, for: anchor)
    }

    func cancelIfPossible() -> Bool {
        guard let picker else { return false }
        pickerMenu?.cancelTracking()
        picker.close()
        return true
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didShareItems items: [Any]
    ) {
        guard hasExactPackage(items) else {
            finish(.failed("The sharing service used an unexpected item."))
            return
        }
        finish(.shared)
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        guard hasExactPackage(items) else {
            finish(.failed("The sharing service used an unexpected item."))
            return
        }
        if (error as? CocoaError)?.code == .userCancelled {
            finish(.cancelled)
        } else {
            finish(.failed(error.localizedDescription))
        }
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        service = sharingService
        return self
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose sharingService: NSSharingService?
    ) {
        if sharingService == nil {
            finish(.cancelled)
        }
    }

    private func hasExactPackage(_ items: [Any]) -> Bool {
        items.count == 1 && items.first as? URL == packageURL
    }

    private func finish(_ outcome: MeetingTransferShareOutcome) {
        guard let completion else { return }
        self.completion = nil
        service?.delegate = nil
        picker?.delegate = nil
        service = nil
        picker = nil
        pickerMenu = nil
        completion(outcome)
    }
}
