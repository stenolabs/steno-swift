import CryptoKit
import Darwin
import Dispatch
import Foundation
import Testing
@_spi(StenoApp) @testable import StenoGemmaModelStore

@Suite("Native Gemma model importer", .serialized)
struct NativeGemmaModelImporterTests {
    @Test("an approved local snapshot publishes once with read-only modes")
    func happyPathPublishesImmutableSnapshot() async throws {
        let fixture = try ImportFixture.make()
        let importer = try fixture.importer()

        let verified = try await importer.importModel(
            from: fixture.sourceURL,
            expectedSourceIdentity: fixture.sourceIdentity,
            requirements: fixture.requirements
        )

        #expect(verified.modelIdentifier == ImportFixture.modelIdentifier)
        #expect(verified.manifestSHA256 == fixture.requirements.expectedManifestSHA256)
        #expect(try fixture.mode(of: fixture.targetURL) == 0o500)
        #expect(try fixture.mode(of: fixture.targetWeightsURL) == 0o400)
        #expect(try fixture.linkCount(of: fixture.targetWeightsURL) == 1)
        #expect(try fixture.stagingNames().isEmpty)
        _ = try verified.revalidate()
    }

    @Test("an existing valid target is idempotent and keeps its inode")
    func validTargetIsIdempotent() async throws {
        let fixture = try ImportFixture.make()
        let importer = try fixture.importer()
        _ = try await fixture.run(importer)
        let originalIdentity = try fixture.identity(of: fixture.targetURL)
        let originalListing = try fixture.storeListing()

        let second = try await fixture.run(importer)

        #expect(second.rootIdentity.deviceID == originalIdentity.deviceID)
        #expect(second.rootIdentity.fileID == originalIdentity.inode)
        #expect(try fixture.identity(of: fixture.targetURL) == originalIdentity)
        #expect(try fixture.storeListing() == originalListing)
    }

    @Test("a corrupt existing target is retained and never replaced")
    func corruptTargetFailsClosed() async throws {
        let fixture = try ImportFixture.make()
        let importer = try fixture.importer()
        _ = try await fixture.run(importer)
        let targetIdentity = try fixture.identity(of: fixture.targetURL)
        try fixture.overwriteFirstByte(of: fixture.targetWeightsURL, with: 0x7f)
        let corrupted = try Data(contentsOf: fixture.targetWeightsURL)

        await #expect(throws: NativeGemmaModelImportError.installedSnapshotCorrupt) {
            _ = try await fixture.run(importer)
        }

        #expect(try fixture.identity(of: fixture.targetURL) == targetIdentity)
        #expect(try Data(contentsOf: fixture.targetWeightsURL) == corrupted)
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("a mismatched approved source identity touches no model store")
    func sourceIdentityMismatchPrecedesStoreCreation() async throws {
        let fixture = try ImportFixture.make()
        let importer = try fixture.importer()
        let wrongIdentity = GemmaModelSourceIdentity(
            deviceID: fixture.sourceIdentity.deviceID,
            inode: fixture.sourceIdentity.inode &+ 1
        )

        await #expect(throws: NativeGemmaModelImportError.sourceIdentityMismatch) {
            _ = try await importer.importModel(
                from: fixture.sourceURL,
                expectedSourceIdentity: wrongIdentity,
                requirements: fixture.requirements
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.modelsURL.path))
    }

    @Test("source symlinks and extra files fail before store creation")
    func unsafeSourceTreeIsRejected() async throws {
        let linkedFixture = try ImportFixture.make()
        let outside = linkedFixture.baseURL.appendingPathComponent("outside.bin")
        try linkedFixture.weightsData.write(to: outside)
        try FileManager.default.removeItem(at: linkedFixture.sourceWeightsURL)
        try FileManager.default.createSymbolicLink(
            at: linkedFixture.sourceWeightsURL,
            withDestinationURL: outside
        )
        let linkedImporter = try linkedFixture.importer()
        await #expect(throws: NativeGemmaModelImportError.self) {
            _ = try await linkedFixture.run(linkedImporter)
        }
        #expect(!FileManager.default.fileExists(atPath: linkedFixture.modelsURL.path))

        let extraFixture = try ImportFixture.make()
        try Data("extra".utf8).write(
            to: extraFixture.sourceURL.appendingPathComponent("extra.bin")
        )
        let extraImporter = try extraFixture.importer()
        await #expect(throws: NativeGemmaModelImportError.self) {
            _ = try await extraFixture.run(extraImporter)
        }
        #expect(!FileManager.default.fileExists(atPath: extraFixture.modelsURL.path))
    }

    @Test("source hard links outside the selected tree are accepted but not preserved")
    func sourceHardLinkDoesNotLeakIntoStore() async throws {
        let fixture = try ImportFixture.make()
        let externalLink = fixture.baseURL.appendingPathComponent("external-hard-link.bin")
        guard Darwin.link(fixture.sourceWeightsURL.path, externalLink.path) == 0 else {
            throw ImportFixtureError.posix(errno)
        }
        #expect(try fixture.linkCount(of: fixture.sourceWeightsURL) == 2)

        _ = try await fixture.run(try fixture.importer())

        #expect(try fixture.linkCount(of: fixture.targetWeightsURL) == 1)
    }

    @Test("cancellation during a chunk removes only owned staging")
    func cancellationCleansStaging() async throws {
        let fixture = try ImportFixture.make(weightsData: Data(repeating: 0x5a, count: 2 << 20))
        let importer = try fixture.importer { checkpoint in
            if case .copiedChunk = checkpoint {
                throw CancellationError()
            }
        }

        await #expect(throws: CancellationError.self) {
            _ = try await fixture.run(importer)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("cancelling the caller stops the worker and removes owned staging")
    func callerTaskCancellationStopsWorker() async throws {
        let fixture = try ImportFixture.make(weightsData: Data(repeating: 0x5a, count: 3 << 20))
        let reachedFirstChunk = LockedValue(false)
        let blockedOnce = LockedValue(false)
        let releaseWorker = DispatchSemaphore(value: 0)
        let importer = try fixture.importer { checkpoint in
            guard case .copiedChunk = checkpoint else { return }
            let shouldBlock = blockedOnce.withLock { blocked -> Bool in
                if blocked { return false }
                blocked = true
                return true
            }
            guard shouldBlock else { return }
            reachedFirstChunk.withLock { $0 = true }
            releaseWorker.wait()
        }
        let run = Task {
            try await fixture.run(importer)
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !reachedFirstChunk.withLock({ $0 }), ContinuousClock().now < deadline {
            await Task.yield()
        }
        #expect(reachedFirstChunk.withLock { $0 })

        run.cancel()
        releaseWorker.signal()
        let result = await run.result

        switch result {
        case .success:
            Issue.record("The cancelled import unexpectedly completed")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("cancellation after atomic publication returns the committed snapshot")
    func cancellationAfterPublishReturnsCommittedSnapshot() async throws {
        let fixture = try ImportFixture.make(weightsData: Data(repeating: 0x5a, count: 2 << 20))
        let reachedCommit = LockedValue(false)
        let releaseWorker = DispatchSemaphore(value: 0)
        let importer = try fixture.importer { checkpoint in
            guard checkpoint == .afterPublish else { return }
            reachedCommit.withLock { $0 = true }
            releaseWorker.wait()
        }
        let run = Task {
            try await fixture.run(importer)
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !reachedCommit.withLock({ $0 }), ContinuousClock().now < deadline {
            await Task.yield()
        }
        #expect(reachedCommit.withLock { $0 })

        run.cancel()
        releaseWorker.signal()
        let result = await run.result

        switch result {
        case .success(let verified):
            #expect(verified.manifestSHA256 == fixture.requirements.expectedManifestSHA256)
        case .failure(let error):
            Issue.record("Committed import reported cancellation: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("source metadata mutation during copy fails closed")
    func sourceMutationDuringCopyIsRejected() async throws {
        let fixture = try ImportFixture.make(weightsData: Data(repeating: 0x41, count: 2 << 20))
        let mutated = LockedValue(false)
        let importer = try fixture.importer { checkpoint in
            guard case .sourceFileOpened(ImportFixture.weightsPath) = checkpoint else { return }
            let shouldMutate = mutated.withLock { value -> Bool in
                if value { return false }
                value = true
                return true
            }
            if shouldMutate {
                try fixture.toggleOwnerExecuteBit(of: fixture.sourceWeightsURL)
            }
        }

        await #expect(throws: NativeGemmaModelImportError.self) {
            _ = try await fixture.run(importer)
        }

        #expect(mutated.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("replacing a source file after binding fails even when bytes still match")
    func sourceReplacementAfterBindingIsRejected() async throws {
        let fixture = try ImportFixture.make()
        let replaced = LockedValue(false)
        let importer = try fixture.importer { checkpoint in
            guard checkpoint == .sourceReady else { return }
            let shouldReplace = replaced.withLock { value -> Bool in
                if value { return false }
                value = true
                return true
            }
            if shouldReplace {
                try fixture.replaceSourceWeightsWithSameContents()
            }
        }

        await #expect(throws: NativeGemmaModelImportError.sourceRejected(
            ImportFixture.weightsPath
        )) {
            _ = try await fixture.run(importer)
        }

        #expect(replaced.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("one importer rejects a concurrent second import explicitly")
    func concurrentImportIsRejectedExplicitly() async throws {
        let fixture = try ImportFixture.make()
        let reachedSourceReady = LockedValue(false)
        let releaseWorker = DispatchSemaphore(value: 0)
        let importer = try fixture.importer { checkpoint in
            guard checkpoint == .sourceReady else { return }
            reachedSourceReady.withLock { $0 = true }
            releaseWorker.wait()
        }
        let first = Task {
            try await fixture.run(importer)
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !reachedSourceReady.withLock({ $0 }), ContinuousClock().now < deadline {
            await Task.yield()
        }
        guard reachedSourceReady.withLock({ $0 }) else {
            releaseWorker.signal()
            _ = await first.result
            Issue.record("The first import did not reach its source-ready checkpoint")
            return
        }

        await #expect(throws: NativeGemmaModelImportError.importAlreadyInProgress) {
            _ = try await fixture.run(importer)
        }

        releaseWorker.signal()
        _ = try await first.value
        #expect(FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("insufficient capacity fails before staging")
    func insufficientCapacityFailsBeforeStaging() async throws {
        let fixture = try ImportFixture.make()
        let importer = try fixture.importer(availableByteCount: 0)

        await #expect(throws: NativeGemmaModelImportError.self) {
            _ = try await fixture.run(importer)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("a valid no-replace race returns the winner and removes owned staging")
    func validPublishRaceIsIdempotent() async throws {
        let fixture = try ImportFixture.make()
        let winnerIdentity = LockedValue<ImportFixture.FileIdentity?>(nil)
        let importer = try fixture.importer { checkpoint in
            guard checkpoint == .beforePublish else { return }
            try fixture.installCompetingTarget(valid: true)
            winnerIdentity.withLock { value in
                value = try? fixture.identity(of: fixture.targetURL)
            }
        }

        let result = try await fixture.run(importer)

        let expectedWinner = winnerIdentity.withLock { $0 }
        #expect(expectedWinner != nil)
        #expect(try fixture.identity(of: fixture.targetURL) == expectedWinner)
        #expect(result.rootIdentity.fileID == expectedWinner?.inode)
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("a corrupt no-replace race is retained and fails closed")
    func corruptPublishRaceIsRetained() async throws {
        let fixture = try ImportFixture.make()
        let winnerIdentity = LockedValue<ImportFixture.FileIdentity?>(nil)
        let importer = try fixture.importer { checkpoint in
            guard checkpoint == .beforePublish else { return }
            try fixture.installCompetingTarget(valid: false)
            winnerIdentity.withLock { value in
                value = try? fixture.identity(of: fixture.targetURL)
            }
        }

        await #expect(throws: NativeGemmaModelImportError.installedSnapshotCorrupt) {
            _ = try await fixture.run(importer)
        }

        let expectedWinner = try #require(winnerIdentity.withLock { $0 })
        #expect(try fixture.identity(of: fixture.targetURL) == expectedWinner)
        #expect(try Data(contentsOf: fixture.targetWeightsURL) == Data("corrupt".utf8))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test("a replaced model-store parent blocks publication")
    func parentReplacementFailsClosed() async throws {
        let fixture = try ImportFixture.make()
        let movedURL = fixture.modelsURL
            .deletingLastPathComponent()
            .appendingPathComponent("v1-moved", isDirectory: true)
        let importer = try fixture.importer { checkpoint in
            guard checkpoint == .beforePublish else { return }
            try FileManager.default.moveItem(at: fixture.modelsURL, to: movedURL)
            try FileManager.default.createDirectory(
                at: fixture.modelsURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        await #expect(throws: NativeGemmaModelImportError.storeParentChanged) {
            _ = try await fixture.run(importer)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.modelsURL.path)) == [])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: movedURL.path)) == [])
    }

    @Test("foreign staging content is retained instead of recursively deleted")
    func unexpectedStagingEntryIsRetained() async throws {
        let fixture = try ImportFixture.make()
        let importer = try fixture.importer { checkpoint in
            guard case .sourceFileOpened = checkpoint else { return }
            guard let staging = try fixture.stagingURLs().first else {
                throw ImportFixtureError.missingStaging
            }
            try Data("foreign".utf8).write(
                to: staging.appendingPathComponent("foreign-entry")
            )
            throw ImportFixtureError.injected
        }

        await #expect(throws: NativeGemmaModelImportError.orphanedStaging) {
            _ = try await fixture.run(importer)
        }

        #expect(try fixture.stagingURLs().count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.targetURL.path))
    }
}

private final class ImportFixture: @unchecked Sendable {
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
    let sourceWeightsURL: URL
    let manifestData: Data
    let weightsData: Data
    let requirements: GemmaModelRequirements
    let sourceIdentity: GemmaModelSourceIdentity

    var modelsURL: URL {
        storeRootURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
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
        sourceWeightsURL: URL,
        manifestData: Data,
        weightsData: Data,
        requirements: GemmaModelRequirements,
        sourceIdentity: GemmaModelSourceIdentity
    ) {
        self.baseURL = baseURL
        self.sourceURL = sourceURL
        self.storeRootURL = storeRootURL
        self.sourceWeightsURL = sourceWeightsURL
        self.manifestData = manifestData
        self.weightsData = weightsData
        self.requirements = requirements
        self.sourceIdentity = sourceIdentity
    }

    deinit {
        Self.makeTreeWritable(baseURL)
        try? FileManager.default.removeItem(at: baseURL)
    }

    static func make(weightsData: Data = Data("model-payload".utf8)) throws -> ImportFixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-gemma-import-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let sourceWeights = source.appendingPathComponent(weightsPath)
        let store = base.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceWeights.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: store,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try weightsData.write(to: sourceWeights)

        let manifest = GemmaModelManifest(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: [
                .init(
                    relativePath: weightsPath,
                    size: Int64(weightsData.count),
                    sha256: sha256(weightsData)
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: source.appendingPathComponent(manifestFileName)
        )
        let requirements = try GemmaModelRequirements(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            expectedManifestSHA256: sha256(manifestData)
        )
        let identity = try sourceIdentity(of: source)
        return ImportFixture(
            baseURL: base,
            sourceURL: source,
            storeRootURL: store,
            sourceWeightsURL: sourceWeights,
            manifestData: manifestData,
            weightsData: weightsData,
            requirements: requirements,
            sourceIdentity: identity
        )
    }

    func importer(
        availableByteCount: UInt64? = nil,
        checkpoint: @escaping NativeGemmaModelImportAction = { _ in }
    ) throws -> NativeGemmaModelImporter {
        NativeGemmaModelImporter(
            configuration: try NativeGemmaModelStoreConfiguration(
                testRootDirectory: storeRootURL,
                availableByteCountOverride: availableByteCount
            ),
            checkpoint: checkpoint
        )
    }

    func run(_ importer: NativeGemmaModelImporter) async throws -> VerifiedGemmaModel {
        try await importer.importModel(
            from: sourceURL,
            expectedSourceIdentity: sourceIdentity,
            requirements: requirements
        )
    }

    func installCompetingTarget(valid: Bool) throws {
        try FileManager.default.createDirectory(
            at: targetWeightsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try (valid ? weightsData : Data("corrupt".utf8)).write(to: targetWeightsURL)
        try manifestData.write(
            to: targetURL.appendingPathComponent(Self.manifestFileName)
        )
        try Self.chmod(targetWeightsURL, 0o400)
        try Self.chmod(targetURL.appendingPathComponent(Self.manifestFileName), 0o400)
        try Self.chmod(targetWeightsURL.deletingLastPathComponent(), 0o500)
        try Self.chmod(targetURL, 0o500)
    }

    func overwriteFirstByte(of url: URL, with byte: UInt8) throws {
        try Self.chmod(url, 0o600)
        let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw ImportFixtureError.posix(errno) }
        defer {
            Darwin.close(descriptor)
            try? Self.chmod(url, 0o400)
        }
        var value = byte
        guard Darwin.pwrite(descriptor, &value, 1, 0) == 1,
              Darwin.fsync(descriptor) == 0 else {
            throw ImportFixtureError.posix(errno)
        }
    }

    func toggleOwnerExecuteBit(of url: URL) throws {
        let currentMode = try mode(of: url)
        try Self.chmod(url, currentMode ^ 0o100)
    }

    func replaceSourceWeightsWithSameContents() throws {
        let replacement = sourceWeightsURL
            .deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString)")
        try weightsData.write(to: replacement)
        guard Darwin.rename(replacement.path, sourceWeightsURL.path) == 0 else {
            try? FileManager.default.removeItem(at: replacement)
            throw ImportFixtureError.posix(errno)
        }
    }

    func stagingNames() throws -> [String] {
        try stagingURLs().map(\.lastPathComponent).sorted()
    }

    func stagingURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: modelsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: modelsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".staging-v1-") }
    }

    func storeListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: modelsURL.path).sorted()
    }

    func identity(of url: URL) throws -> FileIdentity {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw ImportFixtureError.posix(errno)
        }
        return FileIdentity(deviceID: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    func mode(of url: URL) throws -> mode_t {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw ImportFixtureError.posix(errno)
        }
        return status.st_mode & 0o777
    }

    func linkCount(of url: URL) throws -> UInt64 {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw ImportFixtureError.posix(errno)
        }
        return UInt64(status.st_nlink)
    }

    private static func sourceIdentity(of url: URL) throws -> GemmaModelSourceIdentity {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ImportFixtureError.posix(errno) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw ImportFixtureError.posix(errno)
        }
        return GemmaModelSourceIdentity(
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw ImportFixtureError.posix(errno)
        }
    }

    private static func makeTreeWritable(_ root: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
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

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}

private enum ImportFixtureError: Error {
    case injected
    case missingStaging
    case posix(Int32)
}
