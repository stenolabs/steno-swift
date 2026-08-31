import CryptoKit
import Darwin
import Dispatch
import Foundation
import StenoGemmaProcessGate

private let nativeGemmaOwnershipFormat = "steno-native-gemma-import-v2"
private let nativeGemmaOwnershipSchemaVersion = 1
private let nativeGemmaOwnershipDocumentLimit = 4 * 1024
private let nativeGemmaPreparedDocumentLimit = 256 * 1024
private let nativeGemmaRecoveryRootEntryLimit = 16_384
private let nativeGemmaRecoveryTreeEntryLimit = GemmaModelManifest.maximumFileCount
    + GemmaModelManifest.maximumDirectoryCount + 1

struct NativeGemmaStagingOwnershipPair: Hashable, Sendable {
    let importID: UUID
    let nonce: UUID
}

struct NativeGemmaStagingRoot: Sendable {
    let name: String
    let identity: EntryIdentity
    let descriptor: Int32
}

struct NativeGemmaPreparedIdentityLedger: Equatable, Sendable {
    let layoutSHA256: String
    let directoryInodes: [UInt64]
    let fileInodes: [UInt64]
}

private struct NativeGemmaOwnershipIdentity: Codable, Equatable, Sendable {
    let deviceID: UInt64
    let inode: UInt64

    init(_ identity: EntryIdentity) {
        deviceID = identity.deviceID
        inode = identity.inode
    }

    var entryIdentity: EntryIdentity {
        EntryIdentity(deviceID: deviceID, inode: inode)
    }
}

private struct NativeGemmaOwnerDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let format: String
    let importID: UUID
    let nonce: UUID
    let manifestFileName: String
    let manifestSHA256: String

    init(pair: NativeGemmaStagingOwnershipPair, requirements: GemmaModelRequirements) {
        schemaVersion = nativeGemmaOwnershipSchemaVersion
        format = nativeGemmaOwnershipFormat
        importID = pair.importID
        nonce = pair.nonce
        manifestFileName = requirements.manifestFileName
        manifestSHA256 = requirements.expectedManifestSHA256
    }

    var pair: NativeGemmaStagingOwnershipPair {
        NativeGemmaStagingOwnershipPair(importID: importID, nonce: nonce)
    }

    var isCurrent: Bool {
        schemaVersion == nativeGemmaOwnershipSchemaVersion
            && format == nativeGemmaOwnershipFormat
            && GemmaModelRequirements.isSHA256(manifestSHA256)
            && (try? GemmaModelManifest.validateRelativePath(manifestFileName)) != nil
    }
}

private struct NativeGemmaBoundDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let format: String
    let importID: UUID
    let nonce: UUID
    let rootIdentity: NativeGemmaOwnershipIdentity

    init(pair: NativeGemmaStagingOwnershipPair, rootIdentity: EntryIdentity) {
        schemaVersion = nativeGemmaOwnershipSchemaVersion
        format = nativeGemmaOwnershipFormat
        importID = pair.importID
        nonce = pair.nonce
        self.rootIdentity = NativeGemmaOwnershipIdentity(rootIdentity)
    }

    var pair: NativeGemmaStagingOwnershipPair {
        NativeGemmaStagingOwnershipPair(importID: importID, nonce: nonce)
    }

    var isCurrent: Bool {
        schemaVersion == nativeGemmaOwnershipSchemaVersion && format == nativeGemmaOwnershipFormat
    }
}

private struct NativeGemmaPreparedDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let format: String
    let importID: UUID
    let nonce: UUID
    let layoutSHA256: String
    let directoryInodes: [UInt64]
    let fileInodes: [UInt64]

    init(pair: NativeGemmaStagingOwnershipPair, ledger: NativeGemmaPreparedIdentityLedger) {
        schemaVersion = nativeGemmaOwnershipSchemaVersion
        format = nativeGemmaOwnershipFormat
        importID = pair.importID
        nonce = pair.nonce
        layoutSHA256 = ledger.layoutSHA256
        directoryInodes = ledger.directoryInodes
        fileInodes = ledger.fileInodes
    }

    var pair: NativeGemmaStagingOwnershipPair {
        NativeGemmaStagingOwnershipPair(importID: importID, nonce: nonce)
    }

    var ledger: NativeGemmaPreparedIdentityLedger {
        NativeGemmaPreparedIdentityLedger(
            layoutSHA256: layoutSHA256,
            directoryInodes: directoryInodes,
            fileInodes: fileInodes
        )
    }

    var isCurrent: Bool {
        schemaVersion == nativeGemmaOwnershipSchemaVersion
            && format == nativeGemmaOwnershipFormat
            && GemmaModelRequirements.isSHA256(layoutSHA256)
            && directoryInodes.count <= GemmaModelManifest.maximumDirectoryCount
            && fileInodes.count <= GemmaModelManifest.maximumFileCount + 1
    }
}

private enum NativeGemmaOwnershipArtifact: String, CaseIterable, Sendable {
    case owner
    case bound
    case prepared
    case staging
    case cleanup
}

private enum NativeGemmaOwnershipNames {
    static let prefix = ".native-gemma-import-v2-"

    static func name(
        pair: NativeGemmaStagingOwnershipPair,
        artifact: NativeGemmaOwnershipArtifact
    ) -> String {
        "\(prefix)\(pair.importID.uuidString.lowercased())-"
            + "\(pair.nonce.uuidString.lowercased()).\(artifact.rawValue)"
    }

    static func parse(_ name: String) -> (NativeGemmaStagingOwnershipPair, NativeGemmaOwnershipArtifact)? {
        guard name.hasPrefix(prefix), name.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        for artifact in NativeGemmaOwnershipArtifact.allCases {
            let suffix = ".\(artifact.rawValue)"
            guard name.hasSuffix(suffix) else { continue }
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -suffix.count)
            let body = String(name[start ..< end])
            guard body.utf8.count == 73 else { return nil }
            let separator = body.index(body.startIndex, offsetBy: 36)
            guard body[separator] == "-" else { return nil }
            let first = String(body[..<separator])
            let second = String(body[body.index(after: separator)...])
            guard let importID = UUID(uuidString: first),
                  let nonce = UUID(uuidString: second),
                  importID.uuidString.lowercased() == first,
                  nonce.uuidString.lowercased() == second else {
                return nil
            }
            return (NativeGemmaStagingOwnershipPair(importID: importID, nonce: nonce), artifact)
        }
        return nil
    }
}

final class NativeGemmaStagingOwnership {
    let pair: NativeGemmaStagingOwnershipPair
    let stagingName: String
    let cleanupName: String

    var manifestFileName: String { requirements.manifestFileName }

    private let store: ModelStoreParent
    private let requirements: GemmaModelRequirements
    private var ownerIdentity: RecoveryEntryIdentity
    private var boundIdentity: RecoveryEntryIdentity?
    private var preparedIdentity: RecoveryEntryIdentity?
    private var rootIdentity: EntryIdentity?

    private init(
        pair: NativeGemmaStagingOwnershipPair,
        store: ModelStoreParent,
        requirements: GemmaModelRequirements,
        ownerIdentity: RecoveryEntryIdentity
    ) {
        self.pair = pair
        self.store = store
        self.requirements = requirements
        self.ownerIdentity = ownerIdentity
        stagingName = NativeGemmaOwnershipNames.name(pair: pair, artifact: .staging)
        cleanupName = NativeGemmaOwnershipNames.name(pair: pair, artifact: .cleanup)
    }

    static func reserve(
        in store: ModelStoreParent,
        requirements: GemmaModelRequirements
    ) throws -> NativeGemmaStagingOwnership {
        try store.validatePathIdentity()
        for _ in 0 ..< 16 {
            let pair = NativeGemmaStagingOwnershipPair(importID: UUID(), nonce: UUID())
            let ownerName = NativeGemmaOwnershipNames.name(pair: pair, artifact: .owner)
            do {
                let identity = try RecoveryDocuments.create(
                    NativeGemmaOwnerDocument(pair: pair, requirements: requirements),
                    name: ownerName,
                    limit: nativeGemmaOwnershipDocumentLimit,
                    parentDescriptor: store.descriptor
                )
                try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma owner reservation")
                return NativeGemmaStagingOwnership(
                    pair: pair,
                    store: store,
                    requirements: requirements,
                    ownerIdentity: identity
                )
            } catch let error as NativeGemmaModelStoreRecoveryError where error.isCollision {
                continue
            }
        }
        throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
            operation: "reserve Gemma staging owner",
            code: EEXIST
        )
    }

    /// Creates an empty staging root and durably binds its inode before returning it.
    /// Ownership of the returned descriptor transfers to the caller.
    func createAndBindStagingDirectory() throws -> NativeGemmaStagingRoot {
        guard rootIdentity == nil, boundIdentity == nil, preparedIdentity == nil else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        try store.validatePathIdentity()
        guard stagingName.withCString({ Darwin.mkdirat(store.descriptor, $0, mode_t(0o700)) }) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "create Gemma staging directory",
                code: errno
            )
        }
        try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma staging creation")

        let descriptor = stagingName.withCString {
            Darwin.openat(store.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "open Gemma staging directory",
                code: errno
            )
        }
        do {
            let status = try RecoveryFileSystem.status(descriptor: descriptor)
            guard status.kind == S_IFDIR,
                  status.ownerID == geteuid(),
                  status.permissions == 0o700 else {
                throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
            }
            let bound = NativeGemmaBoundDocument(pair: pair, rootIdentity: status.identity)
            let identity = try RecoveryDocuments.create(
                bound,
                name: NativeGemmaOwnershipNames.name(pair: pair, artifact: .bound),
                limit: nativeGemmaOwnershipDocumentLimit,
                parentDescriptor: store.descriptor
            )
            try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma staging binding")
            guard try RecoveryFileSystem.identity(
                name: stagingName,
                parentDescriptor: store.descriptor
            ) == status.identity else {
                throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
            }
            boundIdentity = identity
            rootIdentity = status.identity
            return NativeGemmaStagingRoot(
                name: stagingName,
                identity: status.identity,
                descriptor: descriptor
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func makePreparedLedger(
        manifest: GemmaModelManifest,
        directoryIdentities: [String: EntryIdentity],
        fileIdentities: [String: EntryIdentity]
    ) throws -> NativeGemmaPreparedIdentityLedger {
        guard let rootIdentity else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let layout = try NativeGemmaRecoveryLayout(
            manifest: manifest,
            manifestFileName: requirements.manifestFileName
        )
        guard directoryIdentities[""] == rootIdentity,
              Set(directoryIdentities.keys.filter { !$0.isEmpty }) == Set(layout.directories),
              Set(fileIdentities.keys) == Set(layout.files) else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let directoryInodes = try layout.directories.map { path in
            try requireOwnedIdentity(directoryIdentities[path], rootDeviceID: rootIdentity.deviceID)
        }
        let fileInodes = try layout.files.map { path in
            try requireOwnedIdentity(fileIdentities[path], rootDeviceID: rootIdentity.deviceID)
        }
        return NativeGemmaPreparedIdentityLedger(
            layoutSHA256: layout.sha256,
            directoryInodes: directoryInodes,
            fileInodes: fileInodes
        )
    }

    func markPrepared(_ ledger: NativeGemmaPreparedIdentityLedger) throws {
        guard rootIdentity != nil, boundIdentity != nil, preparedIdentity == nil else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let document = NativeGemmaPreparedDocument(pair: pair, ledger: ledger)
        let identity = try RecoveryDocuments.create(
            document,
            name: NativeGemmaOwnershipNames.name(pair: pair, artifact: .prepared),
            limit: nativeGemmaPreparedDocumentLimit,
            parentDescriptor: store.descriptor
        )
        try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma prepared ledger")
        preparedIdentity = identity
    }

    func removeDocumentsAfterOwnedTreeRemoval() throws {
        guard try RecoveryFileSystem.optionalIdentity(
            name: stagingName,
            parentDescriptor: store.descriptor
        ) == nil,
        try RecoveryFileSystem.optionalIdentity(
            name: cleanupName,
            parentDescriptor: store.descriptor
        ) == nil else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        if let rootIdentity,
           try RecoveryFileSystem.optionalIdentity(
            name: requirements.expectedManifestSHA256,
            parentDescriptor: store.descriptor
           ) == rootIdentity {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        try removeDocumentsInReverseOrder()
    }

    func removeDocumentsAfterPublishedTargetSynchronization() throws {
        guard let rootIdentity,
              try RecoveryFileSystem.identity(
                name: requirements.expectedManifestSHA256,
                parentDescriptor: store.descriptor
              ) == rootIdentity else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        try store.synchronizeAfterPublish()
        try removeDocumentsInReverseOrder()
    }

    private func removeDocumentsInReverseOrder() throws {
        if let preparedIdentity {
            try RecoveryDocuments.remove(
                name: NativeGemmaOwnershipNames.name(pair: pair, artifact: .prepared),
                expectedIdentity: preparedIdentity,
                parentDescriptor: store.descriptor
            )
            try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma prepared cleanup")
            self.preparedIdentity = nil
        }
        if let boundIdentity {
            try RecoveryDocuments.remove(
                name: NativeGemmaOwnershipNames.name(pair: pair, artifact: .bound),
                expectedIdentity: boundIdentity,
                parentDescriptor: store.descriptor
            )
            try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma bound cleanup")
            self.boundIdentity = nil
        }
        try RecoveryDocuments.remove(
            name: NativeGemmaOwnershipNames.name(pair: pair, artifact: .owner),
            expectedIdentity: ownerIdentity,
            parentDescriptor: store.descriptor
        )
        try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma owner cleanup")
    }

    private func requireOwnedIdentity(
        _ identity: EntryIdentity?,
        rootDeviceID: UInt64
    ) throws -> UInt64 {
        guard let identity, identity.deviceID == rootDeviceID else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        return identity.inode
    }
}

@_spi(StenoApp)
public enum NativeGemmaModelStoreRecoveryIssueReason: String, Equatable, Sendable {
    case legacyOrUnownedArtifact
    case malformedArtifactName
    case malformedOwnershipDocument
    case missingOwnershipPhase
    case ambiguousOwnedTree
    case ownershipMismatch
    case unexpectedContent
    case corruptPublishedTarget
}

@_spi(StenoApp)
public struct NativeGemmaModelStoreRecoveryIssue: Equatable, Sendable {
    public let artifactName: String
    public let reason: NativeGemmaModelStoreRecoveryIssueReason
}

@_spi(StenoApp)
public struct NativeGemmaModelStoreRecoveryReport: Equatable, Sendable {
    public let recoveredStagingCount: Int
    public let synchronizedPublishedTargetCount: Int
    public let issues: [NativeGemmaModelStoreRecoveryIssue]
}

public enum NativeGemmaModelStoreRecoveryError: Error, Equatable, LocalizedError, Sendable {
    case invalidOwnershipState
    case storeMutationUnavailable
    case preemptedByRecording
    case unsafeStore
    case scanLimitExceeded(limit: Int)
    case filesystemFailure(operation: String, code: Int32)

    fileprivate var isCollision: Bool {
        if case .filesystemFailure(_, let code) = self { return code == EEXIST }
        return false
    }

    fileprivate var requiresRecoveryAbort: Bool {
        switch self {
        case .preemptedByRecording, .unsafeStore, .scanLimitExceeded, .filesystemFailure:
            true
        case .invalidOwnershipState, .storeMutationUnavailable:
            false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidOwnershipState:
            "The native Gemma staging ownership state is invalid."
        case .storeMutationUnavailable:
            "The native Gemma model store is currently in use."
        case .preemptedByRecording:
            "Native Gemma model-store recovery stopped because a recording is starting."
        case .unsafeStore:
            "Steno's native Gemma model store is unsafe."
        case .scanLimitExceeded(let limit):
            "Native Gemma recovery exceeded its \(limit)-entry scan limit."
        case .filesystemFailure(let operation, let code):
            "Native Gemma recovery failed during \(operation) with POSIX error \(code)."
        }
    }
}

@_spi(StenoApp)
public actor NativeGemmaModelStoreRecovery {
    private static let workerQueue = DispatchQueue(
        label: "org.stenolabs.steno.native-gemma-model-recovery",
        qos: .utility
    )

    private let configuration: NativeGemmaModelStoreConfiguration
    private var isRecovering = false

    public init(configuration: NativeGemmaModelStoreConfiguration) {
        self.configuration = configuration
    }

    public func recoverInterruptedImports() async throws -> NativeGemmaModelStoreRecoveryReport {
        guard !isRecovering else {
            throw NativeGemmaModelStoreRecoveryError.storeMutationUnavailable
        }
        isRecovering = true
        defer { isRecovering = false }
        let cancellation = NativeGemmaRecoveryCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = self.configuration
                Self.workerQueue.async {
                    do {
                        continuation.resume(returning: try Self.performRecovery(
                            configuration: configuration,
                            cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private nonisolated static func performRecovery(
        configuration: NativeGemmaModelStoreConfiguration,
        cancellation: NativeGemmaRecoveryCancellation
    ) throws -> NativeGemmaModelStoreRecoveryReport {
        try cancellation.check()
        let access = try configuration.prepareImportAccess()
        let lease: GemmaStoreMutationLease
        do {
            lease = try access.processGate.acquireStoreMutation()
        } catch GemmaProcessGateError.busy {
            throw NativeGemmaModelStoreRecoveryError.storeMutationUnavailable
        } catch {
            throw NativeGemmaModelStoreRecoveryError.unsafeStore
        }
        cancellation.observeRecordingIntent { try lease.recordingIntentIsPending() }
        defer {
            cancellation.stopObservingRecordingIntent()
            lease.close()
        }
        try cancellation.check()

        let store: ModelStoreParent
        do {
            store = try ModelStoreParent.openExisting(rootURL: access.rootURL)
        } catch NativeGemmaModelImportError.installedSnapshotMissing {
            return NativeGemmaModelStoreRecoveryReport(
                recoveredStagingCount: 0,
                synchronizedPublishedTargetCount: 0,
                issues: []
            )
        } catch {
            throw NativeGemmaModelStoreRecoveryError.unsafeStore
        }
        defer { store.close() }
        try store.validatePathIdentity()
        try cancellation.check()
        try store.synchronizeAfterPublish()

        let names = try RecoveryFileSystem.directoryNames(
            descriptor: store.descriptor,
            limit: nativeGemmaRecoveryRootEntryLimit
        )
        var artifacts: [NativeGemmaStagingOwnershipPair: [NativeGemmaOwnershipArtifact: String]] = [:]
        var issues: [NativeGemmaModelStoreRecoveryIssue] = []
        for name in names.sorted() {
            try cancellation.check()
            if let (pair, artifact) = NativeGemmaOwnershipNames.parse(name) {
                if artifacts[pair]?[artifact] != nil {
                    issues.append(.init(artifactName: name, reason: .ambiguousOwnedTree))
                } else {
                    artifacts[pair, default: [:]][artifact] = name
                }
            } else if name.hasPrefix(NativeGemmaOwnershipNames.prefix) {
                issues.append(.init(artifactName: name, reason: .malformedArtifactName))
            } else if name.contains(".staging-v1-") || name.hasPrefix(".cleanup-v1-") {
                issues.append(.init(artifactName: name, reason: .legacyOrUnownedArtifact))
            }
        }

        var recovered = 0
        var synchronized = 0
        for pair in artifacts.keys.sorted(by: RecoveryFileSystem.pairOrder) {
            try cancellation.check()
            let result = try recover(
                pair: pair,
                names: artifacts[pair, default: [:]],
                store: store,
                cancellation: cancellation
            )
            recovered += result.recovered
            synchronized += result.synchronized
            issues.append(contentsOf: result.issues)
        }
        return NativeGemmaModelStoreRecoveryReport(
            recoveredStagingCount: recovered,
            synchronizedPublishedTargetCount: synchronized,
            issues: issues.sorted {
                $0.artifactName == $1.artifactName
                    ? $0.reason.rawValue < $1.reason.rawValue
                    : $0.artifactName < $1.artifactName
            }
        )
    }

    private nonisolated static func recover(
        pair: NativeGemmaStagingOwnershipPair,
        names: [NativeGemmaOwnershipArtifact: String],
        store: ModelStoreParent,
        cancellation: NativeGemmaRecoveryCancellation
    ) throws -> (recovered: Int, synchronized: Int, issues: [NativeGemmaModelStoreRecoveryIssue]) {
        let allNames = names.values.sorted()
        guard let ownerName = names[.owner] else {
            return (0, 0, allNames.map {
                .init(artifactName: $0, reason: .missingOwnershipPhase)
            })
        }
        let ownerRecord: RecoveryDocumentRecord<NativeGemmaOwnerDocument>
        do {
            ownerRecord = try RecoveryDocuments.read(
                NativeGemmaOwnerDocument.self,
                name: ownerName,
                limit: nativeGemmaOwnershipDocumentLimit,
                parentDescriptor: store.descriptor
            )
            guard ownerRecord.document.isCurrent, ownerRecord.document.pair == pair else {
                throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
            }
        } catch {
            return (0, 0, allNames.map {
                .init(artifactName: $0, reason: .malformedOwnershipDocument)
            })
        }

        let boundRecord: RecoveryDocumentRecord<NativeGemmaBoundDocument>?
        if let boundName = names[.bound] {
            do {
                let record = try RecoveryDocuments.read(
                    NativeGemmaBoundDocument.self,
                    name: boundName,
                    limit: nativeGemmaOwnershipDocumentLimit,
                    parentDescriptor: store.descriptor
                )
                guard record.document.isCurrent, record.document.pair == pair else {
                    throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
                }
                boundRecord = record
            } catch {
                return (0, 0, allNames.map {
                    .init(artifactName: $0, reason: .malformedOwnershipDocument)
                })
            }
        } else {
            boundRecord = nil
        }

        let preparedRecord: RecoveryDocumentRecord<NativeGemmaPreparedDocument>?
        if let preparedName = names[.prepared] {
            guard boundRecord != nil else {
                return (0, 0, allNames.map {
                    .init(artifactName: $0, reason: .missingOwnershipPhase)
                })
            }
            do {
                let record = try RecoveryDocuments.read(
                    NativeGemmaPreparedDocument.self,
                    name: preparedName,
                    limit: nativeGemmaPreparedDocumentLimit,
                    parentDescriptor: store.descriptor
                )
                guard record.document.isCurrent, record.document.pair == pair else {
                    throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
                }
                preparedRecord = record
            } catch {
                return (0, 0, allNames.map {
                    .init(artifactName: $0, reason: .malformedOwnershipDocument)
                })
            }
        } else {
            preparedRecord = nil
        }

        let stagingName = names[.staging]
        let cleanupName = names[.cleanup]
        guard stagingName == nil || cleanupName == nil else {
            return (0, 0, allNames.map {
                .init(artifactName: $0, reason: .ambiguousOwnedTree)
            })
        }
        if let treeName = stagingName ?? cleanupName {
            return try recoverTree(
                treeName: treeName,
                isAlreadyQuarantined: cleanupName != nil,
                pair: pair,
                owner: ownerRecord,
                bound: boundRecord,
                prepared: preparedRecord,
                store: store,
                cancellation: cancellation
            )
        }

        guard let boundRecord else {
            try removeRecoveryDocuments(
                pair: pair,
                owner: ownerRecord,
                bound: nil,
                prepared: nil,
                store: store,
                cancellation: cancellation
            )
            return (0, 0, [])
        }
        let targetName = ownerRecord.document.manifestSHA256
        guard let targetIdentity = try RecoveryFileSystem.optionalIdentity(
            name: targetName,
            parentDescriptor: store.descriptor
        ) else {
            try removeRecoveryDocuments(
                pair: pair,
                owner: ownerRecord,
                bound: boundRecord,
                prepared: preparedRecord,
                store: store,
                cancellation: cancellation
            )
            return (0, 0, [])
        }
        let targetIsPublishedOwnedRoot = targetIdentity
            == boundRecord.document.rootIdentity.entryIdentity

        do {
            let requirements = try requirements(
                owner: ownerRecord.document,
                rootName: targetName,
                store: store,
                cancellation: cancellation
            )
            _ = try GemmaModelVerifier(requirements: requirements).verify(
                directory: store.url.appendingPathComponent(targetName, isDirectory: true),
                expectedRootIdentity: GemmaModelRootIdentity(
                    deviceID: targetIdentity.deviceID,
                    fileID: targetIdentity.inode
                ),
                cancellationCheck: cancellation.check
            )
            try cancellation.check()
            try store.synchronizeAfterPublish()
            try removeRecoveryDocuments(
                pair: pair,
                owner: ownerRecord,
                bound: boundRecord,
                prepared: preparedRecord,
                store: store,
                cancellation: cancellation
            )
            return (0, targetIsPublishedOwnedRoot ? 1 : 0, [])
        } catch let error as NativeGemmaModelStoreRecoveryError {
            if error.requiresRecoveryAbort { throw error }
            return (0, 0, [.init(artifactName: targetName, reason: .corruptPublishedTarget)])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (0, 0, [.init(artifactName: targetName, reason: .corruptPublishedTarget)])
        }
    }

    private nonisolated static func recoverTree(
        treeName: String,
        isAlreadyQuarantined: Bool,
        pair: NativeGemmaStagingOwnershipPair,
        owner: RecoveryDocumentRecord<NativeGemmaOwnerDocument>,
        bound: RecoveryDocumentRecord<NativeGemmaBoundDocument>?,
        prepared: RecoveryDocumentRecord<NativeGemmaPreparedDocument>?,
        store: ModelStoreParent,
        cancellation: NativeGemmaRecoveryCancellation
    ) throws -> (recovered: Int, synchronized: Int, issues: [NativeGemmaModelStoreRecoveryIssue]) {
        let rootDescriptor = treeName.withCString {
            Darwin.openat(store.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            return (0, 0, [.init(artifactName: treeName, reason: .ownershipMismatch)])
        }
        let tree: RecoveryTreeSnapshot
        do {
            tree = try RecoveryTreeSnapshot(
                adoptingRootDescriptor: rootDescriptor,
                cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeGemmaModelStoreRecoveryError {
            if error.requiresRecoveryAbort { throw error }
            return (0, 0, [.init(artifactName: treeName, reason: .unexpectedContent)])
        } catch {
            return (0, 0, [.init(artifactName: treeName, reason: .unexpectedContent)])
        }

        let valid: Bool
        if let bound {
            guard tree.root.identity == bound.document.rootIdentity.entryIdentity else {
                return (0, 0, [.init(artifactName: treeName, reason: .ownershipMismatch)])
            }
            valid = try validateBoundTree(
                tree,
                owner: owner.document,
                prepared: prepared?.document,
                allowMissingPreparedEntries: isAlreadyQuarantined,
                cancellation: cancellation
            )
        } else {
            valid = prepared == nil && tree.isRootEmpty
        }
        guard valid else {
            return (0, 0, [.init(artifactName: treeName, reason: .unexpectedContent)])
        }
        try cancellation.check()
        guard try RecoveryFileSystem.identity(
            name: treeName,
            parentDescriptor: store.descriptor
        ) == tree.root.identity else {
            return (0, 0, [.init(artifactName: treeName, reason: .ownershipMismatch)])
        }

        let cleanupName = NativeGemmaOwnershipNames.name(pair: pair, artifact: .cleanup)
        if !isAlreadyQuarantined {
            let renameResult = treeName.withCString { source in
                cleanupName.withCString { destination in
                    Darwin.renameatx_np(
                        store.descriptor,
                        source,
                        store.descriptor,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                    )
                }
            }
            guard renameResult == 0,
                  try RecoveryFileSystem.identity(
                    name: cleanupName,
                    parentDescriptor: store.descriptor
                  ) == tree.root.identity else {
                return (0, 0, [.init(artifactName: treeName, reason: .ownershipMismatch)])
            }
            try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma recovery quarantine")
        }

        try tree.remove(
            rootName: cleanupName,
            parentDescriptor: store.descriptor,
            manifestFileName: owner.document.manifestFileName
        )
        try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma recovered staging cleanup")
        try removeRecoveryDocuments(
            pair: pair,
            owner: owner,
            bound: bound,
            prepared: prepared,
            store: store,
            cancellation: nil
        )
        return (1, 0, [])
    }

    private nonisolated static func validateBoundTree(
        _ tree: RecoveryTreeSnapshot,
        owner: NativeGemmaOwnerDocument,
        prepared: NativeGemmaPreparedDocument?,
        allowMissingPreparedEntries: Bool,
        cancellation: NativeGemmaRecoveryCancellation
    ) throws -> Bool {
        do {
            let manifestData = try tree.readFile(
                relativePath: owner.manifestFileName,
                maximumByteCount: GemmaModelManifest.maximumManifestByteCount
            )
            guard RecoveryFileSystem.sha256(manifestData) == owner.manifestSHA256 else {
                return tree.containsOnlyManifestPrefix(owner.manifestFileName)
            }
            let manifest = try GemmaModelManifest.decode(from: manifestData)
            let requirements = try GemmaModelRequirements(
                modelIdentifier: manifest.modelIdentifier,
                checkpointRevision: manifest.checkpointRevision,
                adapterRevision: manifest.adapterRevision,
                licenseIdentifier: manifest.licenseIdentifier,
                manifestFileName: owner.manifestFileName,
                expectedManifestSHA256: owner.manifestSHA256
            )
            try manifest.validate(against: requirements)
            let layout = try NativeGemmaRecoveryLayout(
                manifest: manifest,
                manifestFileName: owner.manifestFileName
            )
            return try tree.matches(
                layout: layout,
                prepared: prepared?.ledger,
                allowMissingPreparedEntries: allowMissingPreparedEntries,
                cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeGemmaModelStoreRecoveryError {
            if error.requiresRecoveryAbort { throw error }
            return tree.containsOnlyManifestPrefix(owner.manifestFileName)
        } catch {
            return tree.containsOnlyManifestPrefix(owner.manifestFileName)
        }
    }

    private nonisolated static func requirements(
        owner: NativeGemmaOwnerDocument,
        rootName: String,
        store: ModelStoreParent,
        cancellation: NativeGemmaRecoveryCancellation
    ) throws -> GemmaModelRequirements {
        let descriptor = rootName.withCString {
            Darwin.openat(store.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let tree = try RecoveryTreeSnapshot(
            adoptingRootDescriptor: descriptor,
            cancellation: cancellation
        )
        let data = try tree.readFile(
            relativePath: owner.manifestFileName,
            maximumByteCount: GemmaModelManifest.maximumManifestByteCount
        )
        guard RecoveryFileSystem.sha256(data) == owner.manifestSHA256 else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let manifest = try GemmaModelManifest.decode(from: data)
        let requirements = try GemmaModelRequirements(
            modelIdentifier: manifest.modelIdentifier,
            checkpointRevision: manifest.checkpointRevision,
            adapterRevision: manifest.adapterRevision,
            licenseIdentifier: manifest.licenseIdentifier,
            manifestFileName: owner.manifestFileName,
            expectedManifestSHA256: owner.manifestSHA256
        )
        try manifest.validate(against: requirements)
        return requirements
    }

    private nonisolated static func removeRecoveryDocuments(
        pair: NativeGemmaStagingOwnershipPair,
        owner: RecoveryDocumentRecord<NativeGemmaOwnerDocument>,
        bound: RecoveryDocumentRecord<NativeGemmaBoundDocument>?,
        prepared: RecoveryDocumentRecord<NativeGemmaPreparedDocument>?,
        store: ModelStoreParent,
        cancellation: NativeGemmaRecoveryCancellation?
    ) throws {
        if let prepared {
            try cancellation?.check()
            try RecoveryDocuments.remove(
                name: NativeGemmaOwnershipNames.name(pair: pair, artifact: .prepared),
                expectedIdentity: prepared.identity,
                parentDescriptor: store.descriptor
            )
            try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma recovered prepared cleanup")
        }
        if let bound {
            try cancellation?.check()
            try RecoveryDocuments.remove(
                name: NativeGemmaOwnershipNames.name(pair: pair, artifact: .bound),
                expectedIdentity: bound.identity,
                parentDescriptor: store.descriptor
            )
            try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma recovered bound cleanup")
        }
        try cancellation?.check()
        try RecoveryDocuments.remove(
            name: NativeGemmaOwnershipNames.name(pair: pair, artifact: .owner),
            expectedIdentity: owner.identity,
            parentDescriptor: store.descriptor
        )
        try RecoveryFileSystem.synchronize(store.descriptor, operation: "Gemma recovered owner cleanup")
    }
}

private final class NativeGemmaRecoveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var recordingIntentObserver: (@Sendable () throws -> Bool)?

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func observeRecordingIntent(_ observer: @escaping @Sendable () throws -> Bool) {
        lock.withLock { recordingIntentObserver = observer }
    }

    func stopObservingRecordingIntent() {
        lock.withLock { recordingIntentObserver = nil }
    }

    func check() throws {
        let state = lock.withLock { (cancelled, recordingIntentObserver) }
        if state.0 { throw CancellationError() }
        if let observer = state.1 {
            do {
                if try observer() { throw NativeGemmaModelStoreRecoveryError.preemptedByRecording }
            } catch let error as NativeGemmaModelStoreRecoveryError {
                throw error
            } catch {
                throw NativeGemmaModelStoreRecoveryError.unsafeStore
            }
        }
    }
}

private struct RecoveryEntryIdentity: Equatable, Sendable {
    let identity: EntryIdentity
    let kind: mode_t
    let permissions: mode_t
    let ownerID: uid_t
    let linkCount: UInt64
    let byteCount: Int64
}

private struct RecoveryDocumentRecord<Document: Sendable>: Sendable {
    let document: Document
    let identity: RecoveryEntryIdentity
}

private enum RecoveryDocuments {
    static func create<Document: Encodable>(
        _ document: Document,
        name: String,
        limit: Int,
        parentDescriptor: Int32
    ) throws -> RecoveryEntryIdentity {
        let data = try encode(document)
        guard !data.isEmpty, data.count <= limit else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "create Gemma ownership document",
                code: errno
            )
        }
        do {
            try RecoveryFileSystem.writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                    operation: "fsync Gemma ownership document",
                    code: errno
                )
            }
            guard Darwin.fchmod(descriptor, mode_t(0o400)) == 0 else {
                throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                    operation: "secure Gemma ownership document",
                    code: errno
                )
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                    operation: "fsync secured Gemma ownership document",
                    code: errno
                )
            }
            let status = try RecoveryFileSystem.status(descriptor: descriptor)
            guard status.kind == S_IFREG,
                  status.permissions == 0o400,
                  status.ownerID == geteuid(),
                  status.linkCount == 1,
                  status.byteCount == data.count else {
                throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
            }
            guard Darwin.close(descriptor) == 0 else {
                throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                    operation: "close Gemma ownership document",
                    code: errno
                )
            }
            return status
        } catch {
            _ = Darwin.close(descriptor)
            _ = name.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
            throw error
        }
    }

    static func read<Document: Codable & Equatable & Sendable>(
        _ type: Document.Type,
        name: String,
        limit: Int,
        parentDescriptor: Int32
    ) throws -> RecoveryDocumentRecord<Document> {
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "open Gemma ownership document",
                code: errno
            )
        }
        defer { _ = Darwin.close(descriptor) }
        let before = try RecoveryFileSystem.status(descriptor: descriptor)
        guard before.kind == S_IFREG,
              before.permissions == 0o400,
              before.ownerID == geteuid(),
              before.linkCount == 1,
              before.byteCount > 0,
              before.byteCount <= limit else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let data = try RecoveryFileSystem.readExact(
            descriptor: descriptor,
            byteCount: before.byteCount
        )
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard try encode(document) == data,
              try RecoveryFileSystem.status(descriptor: descriptor) == before else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        return RecoveryDocumentRecord(document: document, identity: before)
    }

    static func remove(
        name: String,
        expectedIdentity: RecoveryEntryIdentity,
        parentDescriptor: Int32
    ) throws {
        guard try RecoveryFileSystem.metadata(
            name: name,
            parentDescriptor: parentDescriptor
        ) == expectedIdentity,
        name.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
    }

    private static func encode<Document: Encodable>(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}

private struct NativeGemmaRecoveryLayout {
    let directories: [String]
    let files: [String]
    let sha256: String

    init(manifest: GemmaModelManifest, manifestFileName: String) throws {
        try GemmaModelManifest.validateRelativePath(manifestFileName)
        let directorySet = Set(
            manifest.files.flatMap { GemmaModelManifest.parentDirectories(of: $0.relativePath) }
                + GemmaModelManifest.parentDirectories(of: manifestFileName)
        )
        guard directorySet.count <= GemmaModelManifest.maximumDirectoryCount,
              manifest.files.count <= GemmaModelManifest.maximumFileCount else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        directories = directorySet.sorted(by: Self.directoryOrder)
        files = [manifestFileName] + manifest.files.map(\.relativePath).sorted(by: Self.utf8Order)

        var hasher = SHA256()
        hasher.update(data: Data("steno-native-gemma-layout-v1\0".utf8))
        for path in directories {
            Self.hash(path: path, kind: 0x44, into: &hasher)
        }
        for path in files {
            Self.hash(path: path, kind: 0x46, into: &hasher)
        }
        sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(path: String, kind: UInt8, into hasher: inout SHA256) {
        hasher.update(data: Data([kind]))
        let data = Data(path.utf8)
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private static func directoryOrder(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.split(separator: "/").count
        let rightDepth = rhs.split(separator: "/").count
        return leftDepth == rightDepth ? utf8Order(lhs, rhs) : leftDepth < rightDepth
    }

    private static func utf8Order(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private final class RecoveryTreeSnapshot {
    struct DirectoryRecord {
        let descriptor: Int32
        let metadata: RecoveryEntryIdentity
        let parentPath: String?
        let name: String?
    }

    struct EntryRecord {
        let metadata: RecoveryEntryIdentity
        let parentPath: String
        let name: String
    }

    let root: RecoveryEntryIdentity
    private(set) var directories: [String: DirectoryRecord] = [:]
    private(set) var entries: [String: EntryRecord] = [:]

    var isRootEmpty: Bool { directories.count == 1 && entries.isEmpty }

    init(
        adoptingRootDescriptor descriptor: Int32,
        cancellation: NativeGemmaRecoveryCancellation
    ) throws {
        let metadata: RecoveryEntryIdentity
        do {
            metadata = try RecoveryFileSystem.status(descriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        guard metadata.kind == S_IFDIR,
              metadata.ownerID == geteuid(),
              [mode_t(0o700), mode_t(0o500)].contains(metadata.permissions) else {
            _ = Darwin.close(descriptor)
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        root = metadata
        directories[""] = DirectoryRecord(
            descriptor: descriptor,
            metadata: metadata,
            parentPath: nil,
            name: nil
        )
        do {
            try enumerate(path: "", cancellation: cancellation)
        } catch {
            closeDescriptors()
            throw error
        }
    }

    deinit {
        closeDescriptors()
    }

    func readFile(relativePath: String, maximumByteCount: Int) throws -> Data {
        guard let record = entries[relativePath],
              record.metadata.kind == S_IFREG,
              record.metadata.byteCount <= maximumByteCount,
              let parent = directories[record.parentPath] else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let descriptor = record.name.withCString {
            Darwin.openat(parent.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState }
        defer { _ = Darwin.close(descriptor) }
        guard try RecoveryFileSystem.status(descriptor: descriptor) == record.metadata else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let data = try RecoveryFileSystem.readExact(
            descriptor: descriptor,
            byteCount: record.metadata.byteCount
        )
        guard try RecoveryFileSystem.status(descriptor: descriptor) == record.metadata else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        return data
    }

    func containsOnlyManifestPrefix(_ manifestFileName: String) -> Bool {
        guard root.permissions == 0o700 else { return false }
        let parents = Set(GemmaModelManifest.parentDirectories(of: manifestFileName))
        for (path, directory) in directories where !path.isEmpty {
            guard parents.contains(path),
                  directory.metadata.ownerID == geteuid(),
                  directory.metadata.permissions == 0o700 else { return false }
        }
        for (path, entry) in entries {
            guard path == manifestFileName,
                  entry.metadata.kind == S_IFREG,
                  entry.metadata.ownerID == geteuid(),
                  entry.metadata.linkCount == 1,
                  [mode_t(0o600), mode_t(0o400)].contains(entry.metadata.permissions) else {
                return false
            }
        }
        return true
    }

    func matches(
        layout: NativeGemmaRecoveryLayout,
        prepared: NativeGemmaPreparedIdentityLedger?,
        allowMissingPreparedEntries: Bool,
        cancellation: NativeGemmaRecoveryCancellation
    ) throws -> Bool {
        guard prepared != nil || root.permissions == 0o700 else { return false }
        let actualDirectories = Set(directories.keys.filter { !$0.isEmpty })
        let expectedDirectories = Set(layout.directories)
        let actualFiles = Set(entries.keys)
        let expectedFiles = Set(layout.files)
        guard actualDirectories.isSubset(of: expectedDirectories),
              actualFiles.isSubset(of: expectedFiles),
              prepared == nil || allowMissingPreparedEntries
                || (actualDirectories == expectedDirectories && actualFiles == expectedFiles) else {
            return false
        }
        let directoryInodes: [String: UInt64]
        let fileInodes: [String: UInt64]
        if let prepared {
            guard prepared.layoutSHA256 == layout.sha256,
                  prepared.directoryInodes.count == layout.directories.count,
                  prepared.fileInodes.count == layout.files.count else { return false }
            directoryInodes = Dictionary(uniqueKeysWithValues: zip(layout.directories, prepared.directoryInodes))
            fileInodes = Dictionary(uniqueKeysWithValues: zip(layout.files, prepared.fileInodes))
        } else {
            directoryInodes = [:]
            fileInodes = [:]
        }
        for (path, directory) in directories where !path.isEmpty {
            try cancellation.check()
            guard directory.metadata.ownerID == geteuid(),
                  directory.metadata.identity.deviceID == root.identity.deviceID,
                  prepared == nil
                    ? directory.metadata.permissions == 0o700
                    : [mode_t(0o700), mode_t(0o500)].contains(directory.metadata.permissions),
                  prepared == nil || directoryInodes[path] == directory.metadata.identity.inode else {
                return false
            }
        }
        for (path, entry) in entries {
            try cancellation.check()
            guard entry.metadata.kind == S_IFREG,
                  entry.metadata.ownerID == geteuid(),
                  entry.metadata.identity.deviceID == root.identity.deviceID,
                  entry.metadata.linkCount == 1,
                  prepared != nil
                    ? [mode_t(0o600), mode_t(0o400)].contains(entry.metadata.permissions)
                    : path == layout.files[0]
                        ? entry.metadata.permissions == 0o400
                        : entry.metadata.permissions == 0o600 && entry.metadata.byteCount == 0,
                  prepared == nil || fileInodes[path] == entry.metadata.identity.inode else {
                return false
            }
        }
        return true
    }

    func remove(
        rootName: String,
        parentDescriptor: Int32,
        manifestFileName: String
    ) throws {
        for directory in directories.values {
            guard try RecoveryFileSystem.status(descriptor: directory.descriptor) == directory.metadata,
                  Darwin.fchmod(directory.descriptor, mode_t(0o700)) == 0 else {
                throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
            }
        }
        for path in entries.keys.filter({ $0 != manifestFileName }).sorted() {
            try removeFile(path)
        }
        let manifestParents = Set(GemmaModelManifest.parentDirectories(of: manifestFileName))
        for path in directories.keys.filter({
            !$0.isEmpty && !manifestParents.contains($0)
        }).sorted(by: Self.deepestPathFirst) {
            try removeDirectory(path)
        }
        if entries[manifestFileName] != nil {
            try removeFile(manifestFileName)
        }
        for path in manifestParents.sorted(by: Self.deepestPathFirst) {
            try removeDirectory(path)
        }
        guard try RecoveryFileSystem.identity(
            name: rootName,
            parentDescriptor: parentDescriptor
        ) == root.identity,
        rootName.withCString({ Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
    }

    private func removeFile(_ path: String) throws {
        guard let entry = entries[path], let parent = directories[entry.parentPath],
              try RecoveryFileSystem.metadata(
                name: entry.name,
                parentDescriptor: parent.descriptor
              ) == entry.metadata,
              entry.name.withCString({ Darwin.unlinkat(parent.descriptor, $0, 0) }) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
    }

    private func removeDirectory(_ path: String) throws {
        guard let directory = directories[path],
              let parentPath = directory.parentPath,
              let name = directory.name,
              let parent = directories[parentPath],
              try RecoveryFileSystem.metadata(
                name: name,
                parentDescriptor: parent.descriptor
              ).identity == directory.metadata.identity,
              name.withCString({ Darwin.unlinkat(parent.descriptor, $0, AT_REMOVEDIR) }) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
    }

    private static func deepestPathFirst(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/").count
        let right = rhs.split(separator: "/").count
        return left == right ? lhs > rhs : left > right
    }

    private func enumerate(path: String, cancellation: NativeGemmaRecoveryCancellation) throws {
        try cancellation.check()
        guard let directory = directories[path] else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        let names = try RecoveryFileSystem.directoryNames(
            descriptor: directory.descriptor,
            limit: nativeGemmaRecoveryTreeEntryLimit + 1
        )
        for name in names.sorted() {
            try cancellation.check()
            let relativePath = path.isEmpty ? name : "\(path)/\(name)"
            guard relativePath.utf8.count <= GemmaModelManifest.maximumPathByteCount,
                  relativePath.split(separator: "/").count <= GemmaModelManifest.maximumPathDepth,
                  entries.count + directories.count - 1 < nativeGemmaRecoveryTreeEntryLimit else {
                throw NativeGemmaModelStoreRecoveryError.scanLimitExceeded(
                    limit: nativeGemmaRecoveryTreeEntryLimit
                )
            }
            let metadata = try RecoveryFileSystem.metadata(
                name: name,
                parentDescriptor: directory.descriptor
            )
            if metadata.kind == S_IFDIR {
                let descriptor = name.withCString {
                    Darwin.openat(
                        directory.descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard descriptor >= 0,
                      try RecoveryFileSystem.status(descriptor: descriptor) == metadata else {
                    if descriptor >= 0 { _ = Darwin.close(descriptor) }
                    throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
                }
                directories[relativePath] = DirectoryRecord(
                    descriptor: descriptor,
                    metadata: metadata,
                    parentPath: path,
                    name: name
                )
                try enumerate(path: relativePath, cancellation: cancellation)
            } else {
                entries[relativePath] = EntryRecord(
                    metadata: metadata,
                    parentPath: path,
                    name: name
                )
            }
        }
    }

    private func closeDescriptors() {
        for directory in directories.values {
            _ = Darwin.close(directory.descriptor)
        }
        directories.removeAll()
    }
}

private enum RecoveryFileSystem {
    static func status(descriptor: Int32) throws -> RecoveryEntryIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "stat Gemma recovery descriptor",
                code: errno
            )
        }
        return metadata(status)
    }

    static func metadata(name: String, parentDescriptor: Int32) throws -> RecoveryEntryIdentity {
        var status = stat()
        guard name.withCString({
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "stat Gemma recovery entry",
                code: errno
            )
        }
        return metadata(status)
    }

    static func identity(name: String, parentDescriptor: Int32) throws -> EntryIdentity {
        try metadata(name: name, parentDescriptor: parentDescriptor).identity
    }

    static func optionalIdentity(name: String, parentDescriptor: Int32) throws -> EntryIdentity? {
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "stat optional Gemma recovery entry",
                code: errno
            )
        }
        return EntryIdentity(status)
    }

    static func directoryNames(descriptor: Int32, limit: Int) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw NativeGemmaModelStoreRecoveryError.unsafeStore
        }
        defer { _ = Darwin.closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            var bytes = entry.pointee.d_name
            guard let name = withUnsafeBytes(of: &bytes, { raw -> String? in
                String(bytes: raw.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }) else {
                throw NativeGemmaModelStoreRecoveryError.unsafeStore
            }
            if name == "." || name == ".." { continue }
            guard result.count < limit else {
                throw NativeGemmaModelStoreRecoveryError.scanLimitExceeded(limit: limit)
            }
            result.append(name)
        }
        guard errno == 0 else {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "enumerate Gemma recovery directory",
                code: errno
            )
        }
        return result
    }

    static func readExact(descriptor: Int32, byteCount: Int64) throws -> Data {
        guard byteCount >= 0, byteCount <= Int64(Int.max) else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        var data = Data(count: Int(byteCount))
        try data.withUnsafeMutableBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.read(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                        operation: "read Gemma recovery file",
                        code: count == 0 ? EIO : errno
                    )
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.invalidOwnershipState
        }
        return data
    }

    static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                        operation: "write Gemma ownership document",
                        code: count == 0 ? EIO : errno
                    )
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }

    static func synchronize(_ descriptor: Int32, operation: String) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "fsync \(operation)",
                code: errno
            )
        }
        if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0,
           errno != EINVAL,
           errno != ENOTSUP {
            throw NativeGemmaModelStoreRecoveryError.filesystemFailure(
                operation: "full fsync \(operation)",
                code: errno
            )
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func pairOrder(
        _ lhs: NativeGemmaStagingOwnershipPair,
        _ rhs: NativeGemmaStagingOwnershipPair
    ) -> Bool {
        let left = lhs.importID.uuidString + lhs.nonce.uuidString
        let right = rhs.importID.uuidString + rhs.nonce.uuidString
        return left < right
    }

    private static func metadata(_ status: stat) -> RecoveryEntryIdentity {
        RecoveryEntryIdentity(
            identity: EntryIdentity(status),
            kind: status.st_mode & S_IFMT,
            permissions: status.st_mode & 0o777,
            ownerID: status.st_uid,
            linkCount: UInt64(status.st_nlink),
            byteCount: Int64(status.st_size)
        )
    }
}
