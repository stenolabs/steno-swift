import CryptoKit
import Darwin
import Foundation
import StenoGemmaProcessGate
import Testing
@_spi(StenoApp) @_spi(StenoTesting) @testable import StenoGemmaModelStore

@Suite("Native Gemma model-store recovery", .serialized)
struct NativeGemmaModelStoreRecoveryTests {
    @Test("a missing model namespace remains absent and clean")
    func missingNamespaceRemainsAbsent() async throws {
        let fixture = try RecoveryFixture.make()

        let report = try await fixture.recovery().recoverInterruptedImports()

        #expect(report == .init(
            recoveredStagingCount: 0,
            synchronizedPublishedTargetCount: 0,
            issues: []
        ))
        #expect(!FileManager.default.fileExists(atPath: fixture.modelsURL.path))
    }

    @Test("a prepared v2 staging tree is recovered exactly once")
    func preparedStagingIsRecoveredIdempotently() async throws {
        let fixture = try RecoveryFixture.make()
        let staging = try await fixture.leavePreparedStaging()
        #expect(FileManager.default.fileExists(atPath: staging.path))

        let first = try await fixture.recovery().recoverInterruptedImports()
        let second = try await fixture.recovery().recoverInterruptedImports()

        #expect(first.recoveredStagingCount == 1)
        #expect(first.synchronizedPublishedTargetCount == 0)
        #expect(first.issues.isEmpty)
        #expect(second == .init(
            recoveredStagingCount: 0,
            synchronizedPublishedTargetCount: 0,
            issues: []
        ))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try fixture.ownershipNames().isEmpty)
    }

    @Test("a valid published target synchronizes stale ownership documents and is retained")
    func publishedTargetIsSynchronizedAndRetained() async throws {
        let fixture = try RecoveryFixture.make()
        try await fixture.leavePublishedTarget()
        let identity = try fixture.identity(of: fixture.targetURL)
        let bytes = try Data(contentsOf: fixture.targetWeightsURL)

        let report = try await fixture.recovery().recoverInterruptedImports()

        #expect(report.recoveredStagingCount == 0)
        #expect(report.synchronizedPublishedTargetCount == 1)
        #expect(report.issues.isEmpty)
        #expect(try fixture.identity(of: fixture.targetURL) == identity)
        #expect(try Data(contentsOf: fixture.targetWeightsURL) == bytes)
        #expect(try fixture.ownershipNames().isEmpty)
    }

    @Test("a corrupt published target is retained byte-for-byte and reported")
    func corruptPublishedTargetIsRetainedAndReported() async throws {
        let fixture = try RecoveryFixture.make()
        try await fixture.leavePublishedTarget()
        try fixture.overwriteFirstByte(of: fixture.targetWeightsURL, with: 0x7f)
        let identity = try fixture.identity(of: fixture.targetURL)
        let bytes = try Data(contentsOf: fixture.targetWeightsURL)

        let report = try await fixture.recovery().recoverInterruptedImports()

        #expect(report.recoveredStagingCount == 0)
        #expect(report.synchronizedPublishedTargetCount == 0)
        #expect(report.issues == [
            .init(
                artifactName: fixture.requirements.expectedManifestSHA256,
                reason: .corruptPublishedTarget
            ),
        ])
        #expect(try fixture.identity(of: fixture.targetURL) == identity)
        #expect(try Data(contentsOf: fixture.targetWeightsURL) == bytes)
        #expect(try !fixture.ownershipNames().isEmpty)
    }

    @Test("unexpected prepared content is retained without deleting ownership evidence")
    func unexpectedPreparedContentIsRetained() async throws {
        let fixture = try RecoveryFixture.make()
        let staging = try await fixture.leavePreparedStaging()
        try Data("foreign".utf8).write(to: staging.appendingPathComponent("foreign"))
        let ownership = try fixture.ownershipNames()

        let report = try await fixture.recovery().recoverInterruptedImports()

        #expect(report.recoveredStagingCount == 0)
        #expect(report.issues.contains(
            .init(artifactName: staging.lastPathComponent, reason: .unexpectedContent)
        ))
        #expect(FileManager.default.fileExists(atPath: staging.path))
        #expect(try fixture.ownershipNames() == ownership)
    }

    @Test("an active recording excludes recovery")
    func activeRecordingExcludesRecovery() async throws {
        let fixture = try RecoveryFixture.make()
        let gate = GemmaProcessGate(configuration: try GemmaProcessGateConfiguration(
            directoryURL: fixture.storeRootURL
        ))

        let recording = try await gate.acquireRecordingLease(
            until: ContinuousClock().now.advanced(by: .seconds(1))
        )
        await #expect(throws: NativeGemmaModelStoreRecoveryError.storeMutationUnavailable) {
            _ = try await fixture.recovery().recoverInterruptedImports()
        }
        recording.close()
    }
}

private final class RecoveryFixture: @unchecked Sendable {
    static let modelIdentifier = "mlx-community/gemma-4-2b-it-4bit"
    static let checkpointRevision = "0123456789abcdef0123456789abcdef01234567"
    static let adapterRevision = "37688d2cf7d3906e08c74479c9d9949ce6b81136"
    static let licenseIdentifier = "Gemma"
    static let manifestFileName = "gemma-model-manifest.json"
    static let weightsPath = "weights/model.bin"

    struct FileIdentity: Equatable {
        let deviceID: UInt64
        let inode: UInt64
    }

    let baseURL: URL
    let sourceURL: URL
    let storeRootURL: URL
    let requirements: GemmaModelRequirements
    let sourceIdentity: GemmaModelSourceIdentity

    var modelsURL: URL {
        storeRootURL.appendingPathComponent("Models/v1", isDirectory: true)
    }

    var targetURL: URL {
        modelsURL.appendingPathComponent(requirements.expectedManifestSHA256, isDirectory: true)
    }

    var targetWeightsURL: URL {
        targetURL.appendingPathComponent(Self.weightsPath)
    }

    private init(
        baseURL: URL,
        sourceURL: URL,
        storeRootURL: URL,
        requirements: GemmaModelRequirements,
        sourceIdentity: GemmaModelSourceIdentity
    ) {
        self.baseURL = baseURL
        self.sourceURL = sourceURL
        self.storeRootURL = storeRootURL
        self.requirements = requirements
        self.sourceIdentity = sourceIdentity
    }

    deinit {
        Self.makeTreeWritable(baseURL)
        try? FileManager.default.removeItem(at: baseURL)
    }

    static func make() throws -> RecoveryFixture {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-gemma-recovery-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = baseURL.appendingPathComponent("Source", isDirectory: true)
        let sourceWeightsURL = sourceURL.appendingPathComponent(weightsPath)
        let storeRootURL = baseURL.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceWeightsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: storeRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let weights = Data("model-payload".utf8)
        try weights.write(to: sourceWeightsURL)
        let manifest = GemmaModelManifest(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: [.init(relativePath: weightsPath, size: Int64(weights.count), sha256: sha256(weights))]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: sourceURL.appendingPathComponent(manifestFileName))
        let requirements = try GemmaModelRequirements(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            expectedManifestSHA256: sha256(manifestData)
        )
        return RecoveryFixture(
            baseURL: baseURL,
            sourceURL: sourceURL,
            storeRootURL: storeRootURL,
            requirements: requirements,
            sourceIdentity: try sourceIdentity(of: sourceURL)
        )
    }

    func recovery() throws -> NativeGemmaModelStoreRecovery {
        NativeGemmaModelStoreRecovery(configuration: try configuration())
    }

    func leavePreparedStaging() async throws -> URL {
        let importer = try makeImporter { checkpoint in
            switch checkpoint {
            case .copiedChunk, .cleanupCommitted:
                throw RecoveryFixtureError.interrupted
            default:
                break
            }
        }
        await #expect(throws: RecoveryFixtureError.interrupted) {
            _ = try await self.run(importer)
        }
        guard let cleanup = try ownershipURLs().first(where: { $0.lastPathComponent.hasSuffix(".cleanup") }) else {
            throw RecoveryFixtureError.missingStaging
        }
        let staging = URL(fileURLWithPath: cleanup.path.replacingOccurrences(
            of: ".cleanup",
            with: ".staging"
        ))
        guard Darwin.rename(cleanup.path, staging.path) == 0 else {
            throw RecoveryFixtureError.posix(errno)
        }
        return staging
    }

    func leavePublishedTarget() async throws {
        let importer = try makeImporter { checkpoint in
            if checkpoint == .namespaceCommitted {
                throw RecoveryFixtureError.interrupted
            }
        }
        await #expect(throws: RecoveryFixtureError.interrupted) {
            _ = try await self.run(importer)
        }
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func ownershipNames() throws -> [String] {
        try ownershipURLs().map(\.lastPathComponent).sorted()
    }

    func identity(of url: URL) throws -> FileIdentity {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else { throw RecoveryFixtureError.posix(errno) }
        return FileIdentity(deviceID: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    func overwriteFirstByte(of url: URL, with byte: UInt8) throws {
        try chmod(url, 0o600)
        let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw RecoveryFixtureError.posix(errno) }
        defer {
            _ = Darwin.close(descriptor)
            try? chmod(url, 0o400)
        }
        var byte = byte
        guard Darwin.pwrite(descriptor, &byte, 1, 0) == 1, Darwin.fsync(descriptor) == 0 else {
            throw RecoveryFixtureError.posix(errno)
        }
    }

    func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else { throw RecoveryFixtureError.posix(errno) }
    }

    private func configuration() throws -> NativeGemmaModelStoreConfiguration {
        try NativeGemmaModelStoreConfiguration(testRootDirectory: storeRootURL)
    }

    private func makeImporter(
        checkpoint: @escaping NativeGemmaModelImportAction
    ) throws -> NativeGemmaModelImporter {
        NativeGemmaModelImporter(configuration: try configuration(), checkpoint: checkpoint)
    }

    private func run(_ importer: NativeGemmaModelImporter) async throws -> VerifiedGemmaModel {
        try await importer.importModel(
            from: sourceURL,
            expectedSourceIdentity: sourceIdentity,
            requirements: requirements
        )
    }

    private func ownershipURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: modelsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: modelsURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".native-gemma-import-v2-") }
    }

    private static func sourceIdentity(of url: URL) throws -> GemmaModelSourceIdentity {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw RecoveryFixtureError.posix(errno) }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw RecoveryFixtureError.posix(errno) }
        return GemmaModelSourceIdentity(deviceID: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeTreeWritable(_ root: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        var directories = [root]
        while let url = enumerator.nextObject() as? URL {
            var status = stat()
            guard Darwin.lstat(url.path, &status) == 0 else { continue }
            if status.st_mode & S_IFMT == S_IFDIR {
                directories.append(url)
                _ = Darwin.chmod(url.path, mode_t(0o700))
            } else if status.st_mode & S_IFMT == S_IFREG {
                _ = Darwin.chmod(url.path, mode_t(0o600))
            }
        }
        for directory in directories {
            _ = Darwin.chmod(directory.path, mode_t(0o700))
        }
    }
}

private enum RecoveryFixtureError: Error, Equatable {
    case interrupted
    case missingStaging
    case posix(Int32)
}
