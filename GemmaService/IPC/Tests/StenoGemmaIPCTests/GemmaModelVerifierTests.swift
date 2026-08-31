import CryptoKit
import Darwin
import Foundation
import Testing
@_spi(StenoGemmaRuntime) @testable import StenoGemmaModelStore

@Suite("Installed Gemma model verifier")
struct GemmaModelVerifierTests {
    @Test("activation assets bind child files, are one-shot, and copy non-weight assets")
    func activationAssetsAreBoundOneShotAndCopySmallFiles() throws {
        let fixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["tokenizer.json": Data("tokenizer".utf8)]
        )
        let assets = try activatedAssets(from: fixture)
        let expectedRootIdentity = try fixture.rootIdentity()

        let received = try assets.consume { borrowed in
            #expect(borrowed.modelIdentifier == Fixture.modelIdentifier)
            #expect(borrowed.rootIdentity == expectedRootIdentity)
            #expect(borrowed.data(forRelativePath: "tokenizer.json") == Data("tokenizer".utf8))
            var paths: [String] = []
            try borrowed.consumeSafetensorsFiles { shard in
                paths.append(shard.relativePath)
                #expect(shard.size == 7)
                #expect(shard.data == Data("payload".utf8))
            }
            #expect(paths == ["model-00001-of-00001.safetensors"])
            return "used"
        }
        #expect(received == "used")

        #expect(throws: GemmaModelVerificationError.activationAssetsUnavailable) {
            _ = try assets.consume { _ in "again" }
        }
    }

    @Test("borrowed activation data expires and shards can be consumed only once")
    func borrowedActivationDataExpiresAndShardsAreOneShot() throws {
        let fixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["tokenizer.json": Data("tokenizer".utf8)]
        )
        let assets = try activatedAssets(from: fixture)
        var escaped: BorrowedGemmaModelActivationAssets?

        try assets.consume { borrowed in
            escaped = borrowed
            try borrowed.consumeSafetensorsFiles { _ in }
            #expect(throws: GemmaModelVerificationError.activationAssetsUnavailable) {
                try borrowed.consumeSafetensorsFiles { _ in }
            }
        }

        let expired = try #require(escaped)
        #expect(expired.data(forRelativePath: "tokenizer.json") == nil)
        #expect(expired.safetensorsRelativePaths.isEmpty)
        #expect(throws: GemmaModelVerificationError.activationAssetsUnavailable) {
            try expired.consumeSafetensorsFiles { _ in }
        }
    }

    @Test("borrowed activation data expires before final revalidation")
    func borrowedActivationDataExpiresBeforeFinalRevalidation() throws {
        let fixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["tokenizer.json": Data("tokenizer".utf8)]
        )
        let assets = try activatedAssets(from: fixture)
        let probe = BorrowedExpirationProbe()

        try assets.consume(cancellationCheck: { probe.check() }) { borrowed in
            probe.store(borrowed)
        }

        #expect(probe.firstObservationAfterBorrow() == true)
    }

    @Test("activation assets reject a same-content child replacement after binding")
    func activationAssetsRejectChildReplacement() throws {
        let fixture = try Fixture.make(primaryPath: "model-00001-of-00001.safetensors")
        let assets = try activatedAssets(from: fixture)

        #expect(throws: GemmaModelVerificationError.entryChanged(
            "model-00001-of-00001.safetensors"
        )) {
            _ = try assets.consume { _ in
                try fixture.replaceWeightsAtomically(with: Data("payload".utf8))
                return ()
            }
        }
    }

    @Test("activation assets reject an in-place mutate and restore")
    func activationAssetsRejectInPlaceMutationEvenWhenBytesAreRestored() throws {
        let fixture = try Fixture.make(primaryPath: "model-00001-of-00001.safetensors")
        let assets = try activatedAssets(from: fixture)

        #expect(throws: GemmaModelVerificationError.entryChanged(
            "model-00001-of-00001.safetensors"
        )) {
            _ = try assets.consume { _ in
                try fixture.mutateWeightsAndRestore()
                return ()
            }
        }
    }

    @Test("activation assets enforce explicit small-data and shard-count limits")
    func activationAssetsEnforceLimits() throws {
        let smallFixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["tokenizer.json": Data(repeating: 0x74, count: 700)]
        )
        let smallDirectory = try adoptedDirectory(from: smallFixture)
        let smallLimits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 600,
            maximumTotalSmallFileByteCount: 4096,
            maximumSafetensorsFileCount: 2,
            maximumSafetensorsFileByteCount: 1024,
            maximumTotalSafetensorsByteCount: 4096
        )
        #expect(throws: GemmaModelVerificationError.activationSmallFileTooLarge(
            path: "tokenizer.json",
            limit: 600,
            actual: 700
        )) {
            _ = try smallDirectory.consumeActivationAssets(limits: smallLimits)
        }

        let shardFixture = try Fixture.make(
            primaryPath: "model-00001-of-00002.safetensors",
            additionalFiles: ["model-00002-of-00002.safetensors": Data("second".utf8)]
        )
        let shardDirectory = try adoptedDirectory(from: shardFixture)
        let shardLimits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 1024,
            maximumTotalSmallFileByteCount: 4096,
            maximumSafetensorsFileCount: 1,
            maximumSafetensorsFileByteCount: 1024,
            maximumTotalSafetensorsByteCount: 4096
        )
        #expect(throws: GemmaModelVerificationError.tooManyActivationSafetensorsFiles(
            limit: 1,
            actual: 2
        )) {
            _ = try shardDirectory.consumeActivationAssets(limits: shardLimits)
        }

        let totalSmallFixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["tokenizer.json": Data(repeating: 0x74, count: 200)]
        )
        let totalSmallDirectory = try adoptedDirectory(from: totalSmallFixture)
        let manifestSize = try Data(contentsOf: totalSmallFixture.manifestURL).count
        let totalSmallLimit = manifestSize + 199
        let totalSmallLimits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 1024 * 1024,
            maximumTotalSmallFileByteCount: totalSmallLimit,
            maximumSafetensorsFileCount: 2,
            maximumSafetensorsFileByteCount: 1024,
            maximumTotalSafetensorsByteCount: 4096
        )
        #expect(throws: GemmaModelVerificationError.activationSmallFilesTooLarge(
            limit: totalSmallLimit,
            actualAtLeast: manifestSize + 200
        )) {
            _ = try totalSmallDirectory.consumeActivationAssets(limits: totalSmallLimits)
        }
        #expect(throws: GemmaModelVerificationError.invalidRootDescriptor) {
            try totalSmallDirectory.revalidate()
        }

        let oversizedShardFixture = try Fixture.make(primaryPath: "model-00001-of-00001.safetensors")
        let oversizedShardDirectory = try adoptedDirectory(from: oversizedShardFixture)
        let oversizedShardLimits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 1024 * 1024,
            maximumTotalSmallFileByteCount: 4096,
            maximumSafetensorsFileCount: 2,
            maximumSafetensorsFileByteCount: 6,
            maximumTotalSafetensorsByteCount: 4096
        )
        #expect(throws: GemmaModelVerificationError.activationSafetensorsFileTooLarge(
            path: "model-00001-of-00001.safetensors",
            limit: 6,
            actual: 7
        )) {
            _ = try oversizedShardDirectory.consumeActivationAssets(limits: oversizedShardLimits)
        }

        let totalShardFixture = try Fixture.make(
            primaryPath: "model-00001-of-00002.safetensors",
            additionalFiles: ["model-00002-of-00002.safetensors": Data("second".utf8)]
        )
        let totalShardDirectory = try adoptedDirectory(from: totalShardFixture)
        let totalShardLimits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 1024 * 1024,
            maximumTotalSmallFileByteCount: 4096,
            maximumSafetensorsFileCount: 2,
            maximumSafetensorsFileByteCount: 1024,
            maximumTotalSafetensorsByteCount: 12
        )
        #expect(throws: GemmaModelVerificationError.activationSafetensorsFilesTooLarge(
            limit: 12,
            actualAtLeast: 13
        )) {
            _ = try totalShardDirectory.consumeActivationAssets(limits: totalShardLimits)
        }
    }

    @Test("activation limit validation and arithmetic fail closed")
    func activationLimitValidationAndArithmeticFailClosed() throws {
        #expect(throws: GemmaModelVerificationError.invalidActivationLimits) {
            _ = try VerifiedGemmaModelActivationLimits(
                maximumSmallFileByteCount: -1,
                maximumTotalSmallFileByteCount: 0,
                maximumSafetensorsFileCount: 0,
                maximumSafetensorsFileByteCount: 0,
                maximumTotalSafetensorsByteCount: 0
            )
        }

        let limits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: Int.max,
            maximumTotalSmallFileByteCount: Int.max,
            maximumSafetensorsFileCount: Int.max,
            maximumSafetensorsFileByteCount: Int64.max,
            maximumTotalSafetensorsByteCount: Int64.max
        )
        var smallTotal = Int.max
        #expect(throws: GemmaModelVerificationError.activationSmallFilesTooLarge(
            limit: Int.max,
            actualAtLeast: Int.max
        )) {
            try limits.recordSmallFile(path: "config.json", size: 1, total: &smallTotal)
        }

        var shardTotal = Int64.max
        #expect(throws: GemmaModelVerificationError.activationSafetensorsFilesTooLarge(
            limit: Int64.max,
            actualAtLeast: Int64.max
        )) {
            try limits.recordSafetensorsFile(
                path: "model.safetensors",
                size: 1,
                total: &shardTotal,
                count: 0
            )
        }

        var safeTotal: Int64 = 0
        #expect(throws: GemmaModelVerificationError.tooManyActivationSafetensorsFiles(
            limit: Int.max,
            actual: Int.max
        )) {
            try limits.recordSafetensorsFile(
                path: "model.safetensors",
                size: 1,
                total: &safeTotal,
                count: Int.max
            )
        }
    }

    @Test("a cancelled activation closes its descriptors and cannot be retried")
    func cancellationClosesActivationAssets() throws {
        let fixture = try Fixture.make(primaryPath: "model-00001-of-00001.safetensors")
        let assets = try activatedAssets(from: fixture)

        #expect(throws: CancellationError.self) {
            _ = try assets.consume(cancellationCheck: { throw CancellationError() }) { _ in
                ()
            }
        }
        #expect(throws: GemmaModelVerificationError.activationAssetsUnavailable) {
            _ = try assets.consume { _ in () }
        }
    }

    @Test("a concurrent close wins before activation result publication")
    func concurrentClosePreventsActivationResultPublication() async throws {
        let fixture = try Fixture.make(primaryPath: "model-00001-of-00001.safetensors")
        let assets = try activatedAssets(from: fixture)
        let release = DispatchSemaphore(value: 0)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let consumeTask = Task.detached { () -> Bool in
            defer { startedContinuation.finish() }
            do {
                _ = try assets.consume { _ in
                    startedContinuation.yield()
                    release.wait()
                    return "must not publish"
                }
                return false
            } catch GemmaModelVerificationError.activationAssetsUnavailable {
                return true
            } catch {
                return false
            }
        }

        for await _ in started {
            break
        }
        assets.close()
        release.signal()

        #expect(await consumeTask.value)
        #expect(throws: GemmaModelVerificationError.activationAssetsUnavailable) {
            _ = try assets.consume { _ in () }
        }
    }

    @Test("a shard-consumer error closes every owned descriptor")
    func shardConsumerErrorClosesActivationAssets() throws {
        let fixture = try Fixture.make(primaryPath: "model-00001-of-00001.safetensors")
        let closeRecorder = DescriptorCloseRecorder()
        let assets = try activatedAssets(from: fixture, closeRecorder: closeRecorder)
        let ownedDescriptors = assets.ownedDescriptorsForTesting()
        #expect(ownedDescriptors.count == 2)

        #expect(throws: CocoaError.self) {
            _ = try assets.consume { borrowed in
                try borrowed.consumeSafetensorsFiles { _ in
                    throw CocoaError(.fileWriteUnknown)
                }
                return ()
            }
        }
        #expect(throws: GemmaModelVerificationError.activationAssetsUnavailable) {
            _ = try assets.consume { _ in () }
        }
        #expect(closeRecorder.closedDescriptors() == Set(ownedDescriptors))
        #expect(closeRecorder.maximumCloseCount() == 1)
    }

    @Test("a mutation during a shard copy prevents its consumer from running")
    func mutationDuringShardCopyFailsBeforeShardConsumer() throws {
        let fixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            primaryContents: Data(repeating: 0x70, count: 2 * 1024 * 1024)
        )
        let assets = try activatedAssets(from: fixture, maximumSafetensorsFileByteCount: 4 * 1024 * 1024)
        let mutationHook = MutationDuringCopyHook(weightsURL: fixture.weightsURL)
        var consumerCalled = false

        #expect(throws: GemmaModelVerificationError.self) {
            _ = try assets.consume(cancellationCheck: {
                ()
            }) { borrowed in
                try borrowed.consumeSafetensorsFiles(cancellationCheck: {
                    try mutationHook.check()
                }) { _ in
                    consumerCalled = true
                }
                return ()
            }
        }
        #expect(!consumerCalled)
    }

    @Test("close during a shard copy aborts before the shard callback and defers descriptor closure")
    func closeDuringShardCopyIsObservedBeforeTheShardCallback() async throws {
        let fixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            primaryContents: Data(repeating: 0x70, count: 2 * 1024 * 1024)
        )
        let closeRecorder = DescriptorCloseRecorder()
        let assets = try activatedAssets(
            from: fixture,
            maximumSafetensorsFileByteCount: 4 * 1024 * 1024,
            closeRecorder: closeRecorder
        )
        let ownedDescriptors = assets.ownedDescriptorsForTesting()
        let checkpoint = ShardCopyCheckpoint()
        let consumeTask = Task.detached { () -> Bool in
            defer { checkpoint.finish() }
            do {
                _ = try assets.consume { borrowed in
                    try borrowed.consumeSafetensorsFiles(cancellationCheck: {
                        checkpoint.check()
                    }) { _ in
                        checkpoint.recordShardCallback()
                    }
                    return ()
                }
                return false
            } catch GemmaModelVerificationError.activationAssetsUnavailable {
                return true
            } catch {
                return false
            }
        }

        for await _ in checkpoint.enteredCopy {
            break
        }
        assets.close()
        #expect(closeRecorder.closedDescriptors().isEmpty)
        checkpoint.releaseCopy()

        #expect(await consumeTask.value)
        #expect(checkpoint.shardCallbackCount() == 0)
        #expect(closeRecorder.closedDescriptors() == Set(ownedDescriptors))
        #expect(closeRecorder.maximumCloseCount() == 1)
    }

    @Test("activation construction closes transferred descriptors through its owner")
    func activationConstructionFailureUsesOwnedDescriptorCloserExactlyOnce() throws {
        let fixture = try Fixture.make(
            primaryPath: "model-00001-of-00002.safetensors",
            additionalFiles: ["model-00002-of-00002.safetensors": Data("second".utf8)]
        )
        let directory = try adoptedDirectory(from: fixture)
        let closeRecorder = DescriptorCloseRecorder()
        let limits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 1024 * 1024,
            maximumTotalSmallFileByteCount: 4 * 1024 * 1024,
            maximumSafetensorsFileCount: 1,
            maximumSafetensorsFileByteCount: 1024 * 1024,
            maximumTotalSafetensorsByteCount: 4 * 1024 * 1024
        )

        #expect(throws: GemmaModelVerificationError.tooManyActivationSafetensorsFiles(
            limit: 1,
            actual: 2
        )) {
            _ = try directory.consumeActivationAssetsForTesting(
                limits: limits,
                ownedDescriptorCloser: { closeRecorder.close($0) }
            )
        }
        #expect(try closeRecorder.closeCount(for: fixture.root) == 1)
        #expect(try closeRecorder.closeCount(for: fixture.manifestURL) == 1)
        #expect(try closeRecorder.closeCount(for: fixture.weightsURL) == 1)
        #expect(try closeRecorder.closeCount(
            for: fixture.root.appendingPathComponent("model-00002-of-00002.safetensors")
        ) == 1)
        #expect(closeRecorder.closedDescriptors().count == 4)
        #expect(closeRecorder.maximumCloseCount() == 1)
    }

    @Test("activation construction cleans retained shards when stopped before the next open")
    func activationConstructionCleansRetainedShardsBeforeTheNextOpen() throws {
        let fixture = try Fixture.make(
            primaryPath: "model-00001-of-00002.safetensors",
            additionalFiles: ["model-00002-of-00002.safetensors": Data("second".utf8)]
        )
        let directory = try adoptedDirectory(from: fixture)
        let closeRecorder = DescriptorCloseRecorder()
        let limits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 1024 * 1024,
            maximumTotalSmallFileByteCount: 4 * 1024 * 1024,
            maximumSafetensorsFileCount: 2,
            maximumSafetensorsFileByteCount: 1024 * 1024,
            maximumTotalSafetensorsByteCount: 4 * 1024 * 1024
        )

        #expect(throws: CocoaError.self) {
            _ = try directory.consumeActivationAssetsForTesting(
                limits: limits,
                beforeOpeningModelFile: { path in
                    guard path == "model-00002-of-00002.safetensors" else { return }
                    throw CocoaError(.fileReadUnknown)
                },
                ownedDescriptorCloser: { closeRecorder.close($0) }
            )
        }
        #expect(try closeRecorder.closeCount(for: fixture.root) == 1)
        #expect(try closeRecorder.closeCount(for: fixture.manifestURL) == 1)
        #expect(try closeRecorder.closeCount(for: fixture.weightsURL) == 1)
        #expect(try closeRecorder.closeCount(
            for: fixture.root.appendingPathComponent("model-00002-of-00002.safetensors")
        ) == 0)
        #expect(closeRecorder.closedDescriptors().count == 3)
        #expect(closeRecorder.maximumCloseCount() == 1)
    }

    @Test("closing activation assets closes retained descriptors exactly once")
    func closingActivationAssetsPreventsUse() throws {
        let fixture = try Fixture.make(primaryPath: "model-00001-of-00001.safetensors")
        let closeRecorder = DescriptorCloseRecorder()
        let assets = try activatedAssets(from: fixture, closeRecorder: closeRecorder)
        let ownedDescriptors = assets.ownedDescriptorsForTesting()
        #expect(ownedDescriptors.count == 2)
        assets.close()
        #expect(closeRecorder.closedDescriptors() == Set(ownedDescriptors))
        #expect(closeRecorder.maximumCloseCount() == 1)
        assets.close()
        #expect(closeRecorder.closedDescriptors() == Set(ownedDescriptors))
        #expect(closeRecorder.maximumCloseCount() == 1)

        #expect(throws: GemmaModelVerificationError.activationAssetsUnavailable) {
            _ = try assets.consume { _ in () }
        }
    }

    @Test("activation open closes a child descriptor rejected after open")
    func activationOpenClosesRejectedChildDescriptor() throws {
        let fixture = try Fixture.make(primaryPath: "model-00001-of-00001.safetensors")
        try Fixture.chmod(fixture.weightsURL, 0o600)
        defer { _ = Darwin.chmod(fixture.weightsURL.path, 0o400) }
        let rootDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        try #require(rootDescriptor >= 0)
        defer { _ = Darwin.close(rootDescriptor) }
        let closeRecorder = DescriptorCloseRecorder()

        #expect(throws: GemmaModelVerificationError.unsafePermissions(
            path: "model-00001-of-00001.safetensors",
            expected: 0o400,
            actual: 0o600
        )) {
            try GemmaModelVerifier.probeActivationFileForTesting(
                from: rootDescriptor,
                relativePath: "model-00001-of-00001.safetensors",
                openedDescriptorCloser: { closeRecorder.close($0) }
            )
        }
        #expect(closeRecorder.closedDescriptors().count == 1)
        #expect(closeRecorder.maximumCloseCount() == 1)
    }

    private func adoptedDirectory(from fixture: Fixture) throws -> VerifiedGemmaModelDirectory {
        let descriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        try #require(descriptor >= 0)
        return try fixture.verifier.verify(
            adoptingDirectoryDescriptor: descriptor,
            expectedRootIdentity: fixture.rootIdentity()
        )
    }

    private func activatedAssets(
        from fixture: Fixture,
        maximumSafetensorsFileByteCount: Int64 = 1024 * 1024,
        closeRecorder: DescriptorCloseRecorder? = nil
    ) throws -> VerifiedGemmaModelActivationAssets {
        let directory = try adoptedDirectory(from: fixture)
        let limits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 1024 * 1024,
            maximumTotalSmallFileByteCount: 4 * 1024 * 1024,
            maximumSafetensorsFileCount: 8,
            maximumSafetensorsFileByteCount: maximumSafetensorsFileByteCount,
            maximumTotalSafetensorsByteCount: 8 * 1024 * 1024
        )
        if let closeRecorder {
            let assets = try directory.consumeActivationAssetsForTesting(
                limits: limits,
                ownedDescriptorCloser: { closeRecorder.close($0) }
            )
            closeRecorder.reset()
            return assets
        }
        return try directory.consumeActivationAssets(limits: limits)
    }

    @Test("a pinned read-only snapshot verifies and remains bound to its inode")
    func completeSnapshotVerifiesAndRevalidates() throws {
        let fixture = try Fixture.make()

        let verified = try fixture.verifier.verify(directory: fixture.root)
        let root = try verified.revalidate()
        let expectedIdentity = try fixture.rootIdentity()

        #expect(root == fixture.root.standardizedFileURL)
        #expect(verified.modelIdentifier == Fixture.modelIdentifier)
        #expect(verified.rootIdentity == expectedIdentity)
    }

    @Test("an adopted directory descriptor is owned, close-on-exec, and revalidates without a path")
    func adoptedDescriptorOwnershipAndRevalidation() throws {
        let fixture = try Fixture.make()
        let descriptor = Darwin.open(fixture.root.path, O_RDONLY | O_DIRECTORY)
        try #require(descriptor >= 0)
        let originalStatus = try descriptorStatus(descriptor)

        let verified = try fixture.verifier.verify(
            adoptingDirectoryDescriptor: descriptor,
            expectedRootIdentity: fixture.rootIdentity()
        )
        let borrowedFlags = try #require(verified.withBorrowedFileDescriptor {
            Darwin.fcntl($0, F_GETFD)
        })
        #expect(borrowedFlags & FD_CLOEXEC == FD_CLOEXEC)

        try verified.revalidate()
        verified.close()
        #expect(!self.descriptor(descriptor, stillRefersTo: originalStatus))
        #expect(throws: GemmaModelVerificationError.invalidRootDescriptor) {
            try verified.revalidate()
        }

        verified.close()
        let unrelated = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(unrelated >= 0)
        defer { _ = Darwin.close(unrelated) }
        #expect(Darwin.fcntl(unrelated, F_GETFD) >= 0)
    }

    @Test("descriptor-rooted revalidation survives visible root rename and replacement")
    func adoptedDescriptorDoesNotReopenVisiblePath() throws {
        let fixture = try Fixture.make()
        let originalRoot = fixture.root
        let movedRoot = originalRoot.deletingLastPathComponent()
            .appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        defer { Fixture.removeTreeIfPresent(at: movedRoot) }

        let descriptor = Darwin.open(
            originalRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        try #require(descriptor >= 0)
        let verified = try fixture.verifier.verify(
            adoptingDirectoryDescriptor: descriptor,
            expectedRootIdentity: fixture.rootIdentity()
        )

        try #require(Darwin.rename(originalRoot.path, movedRoot.path) == 0)
        try FileManager.default.createDirectory(
            at: originalRoot,
            withIntermediateDirectories: false
        )
        try Fixture.chmod(originalRoot, 0o500)

        try verified.revalidate()
        let movedIdentity = try Fixture.rootIdentity(at: movedRoot)
        #expect(verified.rootIdentity == movedIdentity)
        #expect(throws: GemmaModelVerificationError.manifestFileMissing(
            "gemma-model-manifest.json"
        )) {
            _ = try fixture.verifier.verify(directory: originalRoot)
        }
    }

    @Test("adoption rejects and closes wrong descriptor type, access, mode, and identity")
    func adoptedDescriptorValidationAndFailureOwnership() throws {
        let fixture = try Fixture.make()

        var pipeDescriptors: [Int32] = [-1, -1]
        try #require(Darwin.pipe(&pipeDescriptors) == 0)
        let pipeStatus = try descriptorStatus(pipeDescriptors[0])
        defer {
            if pipeDescriptors[1] >= 0 { _ = Darwin.close(pipeDescriptors[1]) }
        }
        #expect(throws: GemmaModelVerificationError.rootIsNotDirectory) {
            _ = try fixture.verifier.verify(
                adoptingDirectoryDescriptor: pipeDescriptors[0]
            )
        }
        #expect(!descriptor(pipeDescriptors[0], stillRefersTo: pipeStatus))
        pipeDescriptors[0] = -1

        let writableFile = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("writable-\(UUID().uuidString)")
        try Data().write(to: writableFile)
        defer { try? FileManager.default.removeItem(at: writableFile) }
        let writableDescriptor = Darwin.open(writableFile.path, O_RDWR | O_CLOEXEC)
        try #require(writableDescriptor >= 0)
        let writableStatus = try descriptorStatus(writableDescriptor)
        #expect(throws: GemmaModelVerificationError.rootDescriptorNotReadOnly) {
            _ = try fixture.verifier.verify(
                adoptingDirectoryDescriptor: writableDescriptor
            )
        }
        #expect(!descriptor(writableDescriptor, stillRefersTo: writableStatus))

        try Fixture.chmod(fixture.root, 0o700)
        let wrongModeDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        try #require(wrongModeDescriptor >= 0)
        let wrongModeStatus = try descriptorStatus(wrongModeDescriptor)
        #expect(throws: GemmaModelVerificationError.unsafePermissions(
            path: ".",
            expected: 0o500,
            actual: 0o700
        )) {
            _ = try fixture.verifier.verify(
                adoptingDirectoryDescriptor: wrongModeDescriptor
            )
        }
        #expect(!descriptor(wrongModeDescriptor, stillRefersTo: wrongModeStatus))
        try Fixture.chmod(fixture.root, 0o500)

        let wrongIdentityDescriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        try #require(wrongIdentityDescriptor >= 0)
        let wrongIdentityStatus = try descriptorStatus(wrongIdentityDescriptor)
        let identity = try fixture.rootIdentity()
        #expect(throws: GemmaModelVerificationError.rootIdentityMismatch) {
            _ = try fixture.verifier.verify(
                adoptingDirectoryDescriptor: wrongIdentityDescriptor,
                expectedRootIdentity: GemmaModelRootIdentity(
                    deviceID: identity.deviceID,
                    fileID: identity.fileID &+ 1
                )
            )
        }
        #expect(!descriptor(wrongIdentityDescriptor, stillRefersTo: wrongIdentityStatus))
    }

    private func descriptorStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return status
    }

    private func descriptor(_ descriptor: Int32, stillRefersTo expected: stat) -> Bool {
        var actual = stat()
        guard Darwin.fstat(descriptor, &actual) == 0 else { return false }
        return actual.st_dev == expected.st_dev
            && actual.st_ino == expected.st_ino
            && actual.st_mode & S_IFMT == expected.st_mode & S_IFMT
    }

    @Test("manifest bytes, format, model identity, revisions, and license remain pinned")
    func manifestAndIdentityPinsAreEnforced() throws {
        let changedFixture = try Fixture.make()
        try changedFixture.replaceManifest(with: Data("{}".utf8))
        #expect(throws: GemmaModelVerificationError.manifestDigestMismatch(
            expected: changedFixture.manifestDigest,
            actual: Fixture.sha256(Data("{}".utf8))
        )) {
            _ = try changedFixture.verifier.verify(directory: changedFixture.root)
        }

        let requirements = try Fixture.requirements()
        let checksum = String(repeating: "0", count: 64)
        func manifest(
            formatVersion: Int = GemmaModelManifest.currentFormatVersion,
            modelIdentifier: String = Fixture.modelIdentifier,
            checkpointRevision: String = Fixture.checkpointRevision,
            adapterRevision: String = Fixture.adapterRevision,
            licenseIdentifier: String = Fixture.licenseIdentifier
        ) -> GemmaModelManifest {
            GemmaModelManifest(
                formatVersion: formatVersion,
                modelIdentifier: modelIdentifier,
                checkpointRevision: checkpointRevision,
                adapterRevision: adapterRevision,
                licenseIdentifier: licenseIdentifier,
                files: [.init(relativePath: "weights.bin", size: 1, sha256: checksum)]
            )
        }

        #expect(throws: GemmaModelVerificationError.unsupportedFormatVersion(
            expected: 1,
            actual: 99
        )) {
            try manifest(formatVersion: 99).validate(against: requirements)
        }
        #expect(throws: GemmaModelVerificationError.modelIdentifierMismatch(
            expected: Fixture.modelIdentifier,
            actual: "mlx-community/other-gemma"
        )) {
            try manifest(modelIdentifier: "mlx-community/other-gemma")
                .validate(against: requirements)
        }
        let otherRevision = String(repeating: "f", count: 40)
        #expect(throws: GemmaModelVerificationError.checkpointRevisionMismatch(
            expected: Fixture.checkpointRevision,
            actual: otherRevision
        )) {
            try manifest(checkpointRevision: otherRevision).validate(against: requirements)
        }
        #expect(throws: GemmaModelVerificationError.adapterRevisionMismatch(
            expected: Fixture.adapterRevision,
            actual: otherRevision
        )) {
            try manifest(adapterRevision: otherRevision).validate(against: requirements)
        }
        #expect(throws: GemmaModelVerificationError.emptyLicenseIdentifier) {
            try manifest(licenseIdentifier: "").validate(against: requirements)
        }
        #expect(throws: GemmaModelVerificationError.licenseIdentifierMismatch(
            expected: Fixture.licenseIdentifier,
            actual: "Apache-2.0"
        )) {
            try manifest(licenseIdentifier: "Apache-2.0").validate(against: requirements)
        }
    }

    @Test("an importer can bind verification to its retained destination identity")
    func expectedRootIdentityMustMatch() throws {
        let fixture = try Fixture.make()
        let identity = try fixture.rootIdentity()

        _ = try fixture.verifier.verify(
            directory: fixture.root,
            expectedRootIdentity: identity
        )

        #expect(throws: GemmaModelVerificationError.rootIdentityMismatch) {
            _ = try fixture.verifier.verify(
                directory: fixture.root,
                expectedRootIdentity: GemmaModelRootIdentity(
                    deviceID: identity.deviceID,
                    fileID: identity.fileID &+ 1
                )
            )
        }
    }

    @Test("requirements accept only pinned revisions and safe identifiers")
    func requirementsGrammarIsStrict() {
        #expect(throws: GemmaModelVerificationError.invalidRequirement(
            "checkpointRevision must be exactly 40 lowercase hexadecimal characters"
        )) {
            _ = try Fixture.requirements(checkpointRevision: "main")
        }
        #expect(throws: GemmaModelVerificationError.invalidRequirement(
            "adapterRevision must be exactly 40 lowercase hexadecimal characters"
        )) {
            _ = try Fixture.requirements(adapterRevision: String(repeating: "A", count: 40))
        }
        #expect(throws: GemmaModelVerificationError.invalidRequirement("modelIdentifier is unsafe")) {
            _ = try Fixture.requirements(modelIdentifier: "../gemma")
        }
        #expect(throws: GemmaModelVerificationError.invalidRequirement("licenseIdentifier is unsafe")) {
            _ = try Fixture.requirements(licenseIdentifier: "Gemma terms")
        }
    }

    @Test("paths are printable ASCII, non-hidden, and no deeper than eight components")
    func pathGrammarIsStrict() throws {
        for path in [
            ".hidden",
            "directory/.hidden",
            "directory/../weights.bin",
            "directory/gewichte-ä.bin",
            "a/b/c/d/e/f/g/h/i.bin",
        ] {
            #expect(throws: GemmaModelVerificationError.invalidRelativePath(path)) {
                try GemmaModelManifest.validateRelativePath(path)
            }
        }
        try GemmaModelManifest.validateRelativePath("a/b/c/d/e/f/g/h.bin")
    }

    @Test("case-folded and manifest-path collisions are rejected")
    func normalizedPathCollisionsAreRejected() throws {
        let requirements = try Fixture.requirements()
        let checksum = String(repeating: "0", count: 64)

        let caseCollision = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(relativePath: "Weights.bin", size: 1, sha256: checksum),
                .init(relativePath: "weights.bin", size: 1, sha256: checksum),
            ]
        )
        #expect(throws: GemmaModelVerificationError.pathCollision(
            first: "Weights.bin",
            second: "weights.bin"
        )) {
            try caseCollision.validate(against: requirements)
        }

        let manifestCollision = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(
                    relativePath: "Gemma-model-manifest.json",
                    size: 1,
                    sha256: checksum
                ),
            ]
        )
        #expect(throws: GemmaModelVerificationError.pathCollision(
            first: "gemma-model-manifest.json",
            second: "Gemma-model-manifest.json"
        )) {
            try manifestCollision.validate(against: requirements)
        }

        let nestedRequirements = try GemmaModelRequirements(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            manifestFileName: "metadata/manifest.json",
            expectedManifestSHA256: checksum
        )
        let parentCollision = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(relativePath: "Metadata/weights.bin", size: 1, sha256: checksum),
            ]
        )
        #expect(throws: GemmaModelVerificationError.pathCollision(
            first: "metadata",
            second: "Metadata"
        )) {
            try parentCollision.validate(against: nestedRequirements)
        }

        let manifestAsParent = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(
                    relativePath: "metadata/manifest.json/weights.bin",
                    size: 1,
                    sha256: checksum
                ),
            ]
        )
        #expect(throws: GemmaModelVerificationError.pathCollision(
            first: "metadata/manifest.json",
            second: "metadata/manifest.json/weights.bin"
        )) {
            try manifestAsParent.validate(against: nestedRequirements)
        }
    }

    @Test("a manifest cannot exceed 4096 model files")
    func fileCountIsBounded() throws {
        let requirements = try Fixture.requirements()
        let checksum = String(repeating: "0", count: 64)
        let files = (0 ... GemmaModelManifest.maximumFileCount).map { index in
            GemmaModelManifest.GemmaModelFile(
                relativePath: "weights-\(index).bin",
                size: 1,
                sha256: checksum
            )
        }
        let manifest = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: files
        )

        #expect(throws: GemmaModelVerificationError.tooManyFiles(
            limit: GemmaModelManifest.maximumFileCount,
            actual: GemmaModelManifest.maximumFileCount + 1
        )) {
            try manifest.validate(against: requirements)
        }
    }

    @Test("manifest decoding bounds files before materializing the 4097th entry")
    func manifestDecodingBoundsFileCountIncrementally() throws {
        let checksum = String(repeating: "0", count: 64)
        let validFiles = (0 ..< GemmaModelManifest.maximumFileCount).map { index in
            "{\"relativePath\":\"weights-\(index).bin\",\"size\":1,\"sha256\":\"\(checksum)\"}"
        }
        func manifestData(files: [String]) -> Data {
            Data(
                """
                {"formatVersion":1,"modelIdentifier":"\(Fixture.modelIdentifier)","checkpointRevision":"\(Fixture.checkpointRevision)","adapterRevision":"\(Fixture.adapterRevision)","licenseIdentifier":"\(Fixture.licenseIdentifier)","files":[\(files.joined(separator: ","))]}
                """.utf8
            )
        }

        for invalidExtraFile in ["{}", "42"] {
            #expect(throws: GemmaModelVerificationError.tooManyFiles(
                limit: GemmaModelManifest.maximumFileCount,
                actual: GemmaModelManifest.maximumFileCount + 1
            )) {
                _ = try GemmaModelManifest.decode(
                    from: manifestData(files: validFiles + [invalidExtraFile])
                )
            }
            #expect(throws: GemmaModelVerificationError.malformedManifest) {
                _ = try GemmaModelManifest.decode(
                    from: manifestData(files: Array(validFiles.dropLast()) + [invalidExtraFile])
                )
            }
        }
    }

    @Test("version 1 manifest decoding round-trips every manifest and file field")
    func versionOneManifestDecodingRoundTripsSemantically() throws {
        let checksum = String(repeating: "0", count: 64)
        let data = Data(
            """
            {"formatVersion":1,"modelIdentifier":"\(Fixture.modelIdentifier)","checkpointRevision":"\(Fixture.checkpointRevision)","adapterRevision":"\(Fixture.adapterRevision)","licenseIdentifier":"\(Fixture.licenseIdentifier)","files":[{"relativePath":"weights.bin","size":7,"sha256":"\(checksum)"},{"relativePath":"tokenizer.json","size":13,"sha256":"\(String(repeating: "a", count: 64))"}]}
            """.utf8
        )

        let decoded = try GemmaModelManifest.decode(from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let redecoded = try GemmaModelManifest.decode(from: encoded)
        let inputJSON = try JSONSerialization.jsonObject(with: data)
        let outputJSON = try JSONSerialization.jsonObject(with: encoded)
        let canonicalInput = try JSONSerialization.data(
            withJSONObject: inputJSON,
            options: [.sortedKeys]
        )
        let canonicalOutput = try JSONSerialization.data(
            withJSONObject: outputJSON,
            options: [.sortedKeys]
        )

        #expect(redecoded == decoded)
        #expect(canonicalOutput == canonicalInput)
    }

    @Test("safetensors classification is exact and uppercase files remain activation small data")
    func safetensorsClassificationIsCaseSensitive() throws {
        #expect(GemmaModelManifest.isSafetensorsFile("model.safetensors"))
        #expect(!GemmaModelManifest.isSafetensorsFile("model.SAFETENSORS"))
        #expect(!GemmaModelManifest.isSafetensorsFile("model.Safetensors"))
        #expect(!GemmaModelManifest.isSafetensorsFile("model.safetensors.backup"))

        let fixture = try Fixture.make(primaryPath: "model.SAFETENSORS")
        let directory = try adoptedDirectory(from: fixture)
        let limits = try VerifiedGemmaModelActivationLimits(
            maximumSmallFileByteCount: 1024,
            maximumTotalSmallFileByteCount: 4096,
            maximumSafetensorsFileCount: 0,
            maximumSafetensorsFileByteCount: 0,
            maximumTotalSafetensorsByteCount: 0
        )
        let assets = try directory.consumeActivationAssets(limits: limits)
        defer { assets.close() }
        try assets.consume { borrowed in
            #expect(borrowed.safetensorsRelativePaths.isEmpty)
            #expect(borrowed.data(forRelativePath: "model.SAFETENSORS") != nil)
        }
    }

    @Test("a manifest cannot require more than 64 directories")
    func directoryCountIsBounded() throws {
        let requirements = try Fixture.requirements()
        let checksum = String(repeating: "0", count: 64)
        let files = (0 ... GemmaModelManifest.maximumDirectoryCount).map { index in
            GemmaModelManifest.GemmaModelFile(
                relativePath: "directory-\(index)/weights.bin",
                size: 1,
                sha256: checksum
            )
        }
        let manifest = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: files
        )

        #expect(throws: GemmaModelVerificationError.tooManyDirectories(
            limit: GemmaModelManifest.maximumDirectoryCount,
            actual: GemmaModelManifest.maximumDirectoryCount + 1
        )) {
            try manifest.validate(against: requirements)
        }
    }

    @Test("the manifest cannot list its reserved filename and input is size bounded")
    func manifestPathAndSizeAreBounded() throws {
        let requirements = try Fixture.requirements()
        let manifest = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(
                    relativePath: "gemma-model-manifest.json",
                    size: 1,
                    sha256: String(repeating: "0", count: 64)
                ),
            ]
        )
        #expect(throws: GemmaModelVerificationError.manifestPathReserved(
            "gemma-model-manifest.json"
        )) {
            try manifest.validate(against: requirements)
        }

        let fixture = try Fixture.make()
        let oversized = Data(
            repeating: 0x20,
            count: GemmaModelManifest.maximumManifestByteCount + 1
        )
        try fixture.replaceManifest(with: oversized)
        #expect(throws: GemmaModelVerificationError.manifestTooLarge(
            limit: GemmaModelManifest.maximumManifestByteCount,
            actualAtLeast: GemmaModelManifest.maximumManifestByteCount + 1
        )) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("root and files require exact read-only modes")
    func permissionsAreExact() throws {
        let rootFixture = try Fixture.make()
        try Fixture.chmod(rootFixture.root, 0o700)
        #expect(throws: GemmaModelVerificationError.unsafePermissions(
            path: ".",
            expected: 0o500,
            actual: 0o700
        )) {
            _ = try rootFixture.verifier.verify(directory: rootFixture.root)
        }

        let fileFixture = try Fixture.make()
        try Fixture.chmod(fileFixture.weightsURL, 0o600)
        #expect(throws: GemmaModelVerificationError.unsafePermissions(
            path: "weights.bin",
            expected: 0o400,
            actual: 0o600
        )) {
            _ = try fileFixture.verifier.verify(directory: fileFixture.root)
        }

        let directoryFixture = try Fixture.make(primaryPath: "weights/part.bin")
        let weightsDirectory = directoryFixture.root.appendingPathComponent(
            "weights",
            isDirectory: true
        )
        try Fixture.chmod(weightsDirectory, 0o700)
        #expect(throws: GemmaModelVerificationError.unsafePermissions(
            path: "weights",
            expected: 0o500,
            actual: 0o700
        )) {
            _ = try directoryFixture.verifier.verify(directory: directoryFixture.root)
        }
    }

    @Test("symbolic links and hard-linked files are rejected")
    func linksAreRejected() throws {
        let rootFixture = try Fixture.make()
        let alias = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: rootFixture.root)
        defer { try? FileManager.default.removeItem(at: alias) }
        #expect(throws: GemmaModelVerificationError.symbolicLinkNotAllowed(".")) {
            _ = try rootFixture.verifier.verify(directory: alias)
        }

        let symbolicFixture = try Fixture.make()
        try Fixture.chmod(symbolicFixture.root, 0o700)
        let linked = symbolicFixture.root.appendingPathComponent("linked.bin")
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: symbolicFixture.weightsURL
        )
        try Fixture.chmod(symbolicFixture.root, 0o500)
        #expect(throws: GemmaModelVerificationError.symbolicLinkNotAllowed("linked.bin")) {
            _ = try symbolicFixture.verifier.verify(directory: symbolicFixture.root)
        }

        let hardLinkFixture = try Fixture.make()
        try Fixture.chmod(hardLinkFixture.root, 0o700)
        let hardLinkAlias = hardLinkFixture.root.appendingPathComponent("alias.bin")
        guard Darwin.link(hardLinkFixture.weightsURL.path, hardLinkAlias.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try Fixture.chmod(hardLinkFixture.root, 0o500)
        do {
            _ = try hardLinkFixture.verifier.verify(directory: hardLinkFixture.root)
            Issue.record("Expected a hard-link rejection")
        } catch let error as GemmaModelVerificationError {
            guard case .hardLinkNotAllowed(let path) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(path == "weights.bin" || path == "alias.bin")
        }
    }

    @Test("size, hash, extra entries, and post-verification replacement fail closed")
    func treeChangesAreRejected() throws {
        let sizeFixture = try Fixture.make()
        try sizeFixture.replaceWeights(with: "changed length")
        #expect(throws: GemmaModelVerificationError.fileSizeMismatch(
            path: "weights.bin",
            expected: 7,
            actual: 14
        )) {
            _ = try sizeFixture.verifier.verify(directory: sizeFixture.root)
        }

        let hashFixture = try Fixture.make()
        let verified = try hashFixture.verifier.verify(directory: hashFixture.root)
        try hashFixture.replaceWeights(with: "payloae")
        #expect(throws: GemmaModelVerificationError.fileHashMismatch(
            path: "weights.bin",
            expected: Fixture.sha256(Data("payload".utf8)),
            actual: Fixture.sha256(Data("payloae".utf8))
        )) {
            _ = try verified.revalidate()
        }

        let extraFixture = try Fixture.make()
        try extraFixture.addReadOnlyFile(path: "extra.bin", contents: "extra")
        #expect(throws: GemmaModelVerificationError.unexpectedFile("extra.bin")) {
            _ = try extraFixture.verifier.verify(directory: extraFixture.root)
        }

        let missingFixture = try Fixture.make()
        try missingFixture.removeWeights()
        #expect(throws: GemmaModelVerificationError.missingFile("weights.bin")) {
            _ = try missingFixture.verifier.verify(directory: missingFixture.root)
        }
    }

    @Test("metadata preflight rejects unexpected and wrongly-sized files before model reads")
    func metadataPreflightPrecedesModelContentReads() throws {
        let unexpectedFixture = try Fixture.make()
        try unexpectedFixture.addSparseReadOnlyFile(
            path: "unexpected-large.bin",
            size: 8 * 1024 * 1024 * 1024
        )
        let unexpectedReads = VerificationReadRecorder()
        #expect(throws: GemmaModelVerificationError.unexpectedFile("unexpected-large.bin")) {
            _ = try unexpectedFixture.verifier.verify(
                directory: unexpectedFixture.root,
                hooks: GemmaModelVerificationHooks(
                    beforeReadingModelContent: { unexpectedReads.record($0) }
                )
            )
        }
        #expect(unexpectedReads.paths() == [])

        let wrongSizeFixture = try Fixture.make()
        try wrongSizeFixture.replaceWeights(with: "changed length")
        let wrongSizeReads = VerificationReadRecorder()
        #expect(throws: GemmaModelVerificationError.fileSizeMismatch(
            path: "weights.bin",
            expected: 7,
            actual: 14
        )) {
            _ = try wrongSizeFixture.verifier.verify(
                directory: wrongSizeFixture.root,
                hooks: GemmaModelVerificationHooks(
                    beforeReadingModelContent: { wrongSizeReads.record($0) }
                )
            )
        }
        #expect(wrongSizeReads.paths() == [])
    }

    @Test("metadata preflight never enters an unexpected directory")
    func metadataPreflightDoesNotEnterUnexpectedDirectories() throws {
        let fixture = try Fixture.make()
        try fixture.addUnexpectedDirectoryWithHiddenFile(path: "unexpected")

        #expect(throws: GemmaModelVerificationError.unexpectedDirectory("unexpected")) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("a file swap or symlink after metadata preflight fails closed")
    func postPreflightFileChangesFailClosed() throws {
        let swappedFixture = try Fixture.make()
        #expect(throws: GemmaModelVerificationError.entryChanged("weights.bin")) {
            _ = try swappedFixture.verifier.verify(
                directory: swappedFixture.root,
                hooks: GemmaModelVerificationHooks(
                    didCompleteMetadataPreflight: {
                        try swappedFixture.replaceWeightsAtomically(with: Data("payload".utf8))
                    }
                )
            )
        }

        let symlinkFixture = try Fixture.make()
        #expect(throws: GemmaModelVerificationError.symbolicLinkNotAllowed("weights.bin")) {
            _ = try symlinkFixture.verifier.verify(
                directory: symlinkFixture.root,
                hooks: GemmaModelVerificationHooks(
                    didCompleteMetadataPreflight: {
                        try symlinkFixture.replaceWeightsWithSymlink()
                    }
                )
            )
        }
    }

    @Test("the final metadata pass rejects additions and replacements after hashing")
    func finalMetadataPassRejectsPostHashChanges() throws {
        let addedFixture = try Fixture.make()
        #expect(throws: GemmaModelVerificationError.entryChanged(".")) {
            _ = try addedFixture.verifier.verify(
                directory: addedFixture.root,
                hooks: GemmaModelVerificationHooks(
                    beforeFinalMetadataPass: {
                        try addedFixture.addReadOnlyFile(path: "late.bin", contents: "late")
                    }
                )
            )
        }

        let replacedFixture = try Fixture.make()
        #expect(throws: GemmaModelVerificationError.entryChanged("weights.bin")) {
            _ = try replacedFixture.verifier.verify(
                directory: replacedFixture.root,
                hooks: GemmaModelVerificationHooks(
                    beforeFinalMetadataPass: {
                        try replacedFixture.replaceWeightsInPlace(with: Data("payloae".utf8))
                    }
                )
            )
        }
    }

    @Test("descriptor verification rechecks the root after the final traversal")
    func adoptedDescriptorRechecksRootAfterFinalTraversal() throws {
        let fixture = try Fixture.make()
        let descriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        try #require(descriptor >= 0)

        #expect(throws: GemmaModelVerificationError.unexpectedFile("late-root.bin")) {
            _ = try fixture.verifier.verify(
                adoptingDirectoryDescriptor: descriptor,
                expectedRootIdentity: fixture.rootIdentity(),
                hooks: GemmaModelVerificationHooks(
                    beforeCompletingFinalMetadataPass: {
                        try fixture.addReadOnlyFile(path: "late-root.bin", contents: "late")
                    }
                )
            )
        }
    }

    @Test("descriptor verification confirms nested entries after the final traversal")
    func adoptedDescriptorConfirmsNestedEntriesAfterFinalTraversal() throws {
        let addedFixture = try Fixture.make(
            additionalFiles: ["nested/expected.bin": Data("nested".utf8)]
        )
        let addedDescriptor = Darwin.open(
            addedFixture.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        try #require(addedDescriptor >= 0)

        #expect(throws: GemmaModelVerificationError.entryChanged("nested")) {
            _ = try addedFixture.verifier.verify(
                adoptingDirectoryDescriptor: addedDescriptor,
                expectedRootIdentity: addedFixture.rootIdentity(),
                hooks: GemmaModelVerificationHooks(
                    beforeCompletingFinalMetadataPass: {
                        try addedFixture.addReadOnlyFile(
                            inDirectory: "nested",
                            path: "late.bin",
                            contents: "late"
                        )
                    }
                )
            )
        }

        let replacedFixture = try Fixture.make(
            additionalFiles: ["nested/expected.bin": Data("nested".utf8)]
        )
        let replacedDescriptor = Darwin.open(
            replacedFixture.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        try #require(replacedDescriptor >= 0)

        #expect(throws: GemmaModelVerificationError.entryChanged("nested/expected.bin")) {
            _ = try replacedFixture.verifier.verify(
                adoptingDirectoryDescriptor: replacedDescriptor,
                expectedRootIdentity: replacedFixture.rootIdentity(),
                hooks: GemmaModelVerificationHooks(
                    beforeCompletingFinalMetadataPass: {
                        try replacedFixture.replaceReadOnlyFileInPlace(
                            path: "nested/expected.bin",
                            contents: Data("nestee".utf8)
                        )
                    }
                )
            )
        }
    }

    @Test("successful verification reads only manifest-listed model files once")
    func successfulVerificationReadsOnlyExpectedModelContent() throws {
        let index = Data(
            "{\"weight_map\":{\"layer\":\"model-00001-of-00001.safetensors\"}}".utf8
        )
        let fixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: [
                "model.safetensors.index.json": index,
                "tokenizer.json": Data("tokenizer".utf8),
            ]
        )
        let reads = VerificationReadRecorder()

        _ = try fixture.verifier.verify(
            directory: fixture.root,
            hooks: GemmaModelVerificationHooks(
                beforeReadingModelContent: { reads.record($0) }
            )
        )

        #expect(reads.paths() == [
            "model-00001-of-00001.safetensors",
            "model.safetensors.index.json",
            "tokenizer.json",
        ])
    }

    @Test("a safetensors index cannot escape or reference an unmanifested shard")
    func safetensorsIndexIsBoundToManifest() throws {
        let escaping = Data("{\"weight_map\":{\"layer\":\"../outside.safetensors\"}}".utf8)
        let escapingFixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["model.safetensors.index.json": escaping]
        )
        #expect(throws: GemmaModelVerificationError.unsafeSafetensorsIndexPath(
            "../outside.safetensors"
        )) {
            _ = try escapingFixture.verifier.verify(directory: escapingFixture.root)
        }

        let unlisted = Data("{\"weight_map\":{\"layer\":\"other.safetensors\"}}".utf8)
        let unlistedFixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["model.safetensors.index.json": unlisted]
        )
        #expect(throws: GemmaModelVerificationError.unmanifestedSafetensorsFile(
            "other.safetensors"
        )) {
            _ = try unlistedFixture.verifier.verify(directory: unlistedFixture.root)
        }

        let uppercase = Data(
            "{\"weight_map\":{\"layer\":\"model-00001-of-00001.SAFETENSORS\"}}".utf8
        )
        let uppercaseFixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["model.safetensors.index.json": uppercase]
        )
        #expect(throws: GemmaModelVerificationError.unmanifestedSafetensorsFile(
            "model-00001-of-00001.SAFETENSORS"
        )) {
            _ = try uppercaseFixture.verifier.verify(directory: uppercaseFixture.root)
        }
    }
}

private final class VerificationReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []

    func record(_ path: String) {
        lock.withLock { recordedPaths.append(path) }
    }

    func paths() -> [String] {
        lock.withLock { recordedPaths }
    }
}

private final class DescriptorCloseRecorder: @unchecked Sendable {
    private struct DescriptorIdentity: Hashable {
        let deviceID: UInt64
        let fileID: UInt64

        init(_ status: stat) {
            deviceID = UInt64(status.st_dev)
            fileID = UInt64(status.st_ino)
        }
    }

    private let lock = NSLock()
    private var closeCounts: [Int32: Int] = [:]
    private var closeCountsByIdentity: [DescriptorIdentity: Int] = [:]

    func close(_ descriptor: Int32) {
        var status = stat()
        let identity = Darwin.fstat(descriptor, &status) == 0 ? DescriptorIdentity(status) : nil
        lock.withLock {
            closeCounts[descriptor, default: 0] += 1
            if let identity {
                closeCountsByIdentity[identity, default: 0] += 1
            }
        }
        _ = Darwin.close(descriptor)
    }

    func closedDescriptors() -> Set<Int32> {
        lock.withLock { Set(closeCounts.keys) }
    }

    func maximumCloseCount() -> Int {
        lock.withLock { closeCounts.values.max() ?? 0 }
    }

    func reset() {
        lock.withLock {
            closeCounts.removeAll()
            closeCountsByIdentity.removeAll()
        }
    }

    func closeCount(for url: URL) throws -> Int {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return lock.withLock { closeCountsByIdentity[DescriptorIdentity(status), default: 0] }
    }
}

private final class BorrowedExpirationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var borrowed: BorrowedGemmaModelActivationAssets?
    private var firstObservation: Bool?

    func store(_ borrowed: BorrowedGemmaModelActivationAssets) {
        lock.withLock { self.borrowed = borrowed }
    }

    func check() {
        lock.withLock {
            guard firstObservation == nil, let borrowed else { return }
            firstObservation = borrowed.data(forRelativePath: "tokenizer.json") == nil
                && borrowed.safetensorsRelativePaths.isEmpty
        }
    }

    func firstObservationAfterBorrow() -> Bool? {
        lock.withLock { firstObservation }
    }
}

private final class MutationDuringCopyHook: @unchecked Sendable {
    private let lock = NSLock()
    private let weightsURL: URL
    private var checks = 0

    init(weightsURL: URL) {
        self.weightsURL = weightsURL
    }

    func check() throws {
        let shouldMutate = lock.withLock {
            checks += 1
            return checks == 3
        }
        guard shouldMutate else { return }
        guard Darwin.chmod(weightsURL.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { _ = Darwin.chmod(weightsURL.path, 0o400) }
        try Data(repeating: 0x71, count: 2 * 1024 * 1024).write(to: weightsURL)
    }
}

private final class ShardCopyCheckpoint: @unchecked Sendable {
    let enteredCopy: AsyncStream<Void>

    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private var checkCount = 0
    private var copyWasBlocked = false
    private var callbacks = 0

    init() {
        let stream = AsyncStream<Void>.makeStream()
        enteredCopy = stream.stream
        enteredContinuation = stream.continuation
    }

    func check() {
        let shouldBlock = lock.withLock {
            checkCount += 1
            guard !copyWasBlocked, checkCount == 3 else { return false }
            copyWasBlocked = true
            return true
        }
        guard shouldBlock else { return }
        enteredContinuation.yield()
        release.wait()
    }

    func releaseCopy() {
        release.signal()
        finish()
    }

    func finish() {
        enteredContinuation.finish()
    }

    func recordShardCallback() {
        lock.withLock { callbacks += 1 }
    }

    func shardCallbackCount() -> Int {
        lock.withLock { callbacks }
    }
}

private final class Fixture: @unchecked Sendable {
    static let modelIdentifier = "mlx-community/gemma-4-2b-it-4bit"
    static let checkpointRevision = "0123456789abcdef0123456789abcdef01234567"
    static let adapterRevision = "37688d2cf7d3906e08c74479c9d9949ce6b81136"
    static let licenseIdentifier = "Gemma"

    let root: URL
    let weightsURL: URL
    let manifestURL: URL
    let manifestDigest: String
    let verifier: GemmaModelVerifier

    private init(
        root: URL,
        weightsURL: URL,
        manifestURL: URL,
        manifestDigest: String,
        verifier: GemmaModelVerifier
    ) {
        self.root = root
        self.weightsURL = weightsURL
        self.manifestURL = manifestURL
        self.manifestDigest = manifestDigest
        self.verifier = verifier
    }

    deinit {
        Self.makeWritableRecursively(root)
        try? FileManager.default.removeItem(at: root)
    }

    static func make(
        primaryPath: String = "weights.bin",
        primaryContents: Data = Data("payload".utf8),
        additionalFiles: [String: Data] = [:]
    ) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let weightsURL = root.appendingPathComponent(primaryPath)
        let weights = primaryContents
        try writeFile(weights, to: weightsURL)
        for (path, data) in additionalFiles {
            try writeFile(data, to: root.appendingPathComponent(path))
        }

        let manifest = GemmaModelManifest(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: [manifestFile(path: primaryPath, data: weights)]
                + additionalFiles.sorted(by: { $0.key < $1.key }).map {
                    manifestFile(path: $0.key, data: $0.value)
                }
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestURL = root.appendingPathComponent("gemma-model-manifest.json")
        try writeFile(manifestData, to: manifestURL)
        try freezeRecursively(root)

        let manifestDigest = sha256(manifestData)
        let requirements = try requirements(expectedManifestSHA256: manifestDigest)
        return Fixture(
            root: root,
            weightsURL: weightsURL,
            manifestURL: manifestURL,
            manifestDigest: manifestDigest,
            verifier: GemmaModelVerifier(requirements: requirements)
        )
    }

    static func requirements(
        modelIdentifier: String = modelIdentifier,
        checkpointRevision: String = checkpointRevision,
        adapterRevision: String = adapterRevision,
        licenseIdentifier: String = licenseIdentifier,
        expectedManifestSHA256: String = String(repeating: "0", count: 64)
    ) throws -> GemmaModelRequirements {
        try GemmaModelRequirements(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            expectedManifestSHA256: expectedManifestSHA256
        )
    }

    func rootIdentity() throws -> GemmaModelRootIdentity {
        try Self.rootIdentity(at: root)
    }

    static func rootIdentity(at root: URL) throws -> GemmaModelRootIdentity {
        var status = stat()
        guard Darwin.lstat(root.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return GemmaModelRootIdentity(
            deviceID: UInt64(status.st_dev),
            fileID: UInt64(status.st_ino)
        )
    }

    static func removeTreeIfPresent(at root: URL) {
        makeWritableRecursively(root)
        try? FileManager.default.removeItem(at: root)
    }

    func replaceWeights(with contents: String) throws {
        try Self.chmod(weightsURL, 0o600)
        try Data(contents.utf8).write(to: weightsURL)
        try Self.chmod(weightsURL, 0o400)
    }

    func replaceWeightsAtomically(with contents: Data) throws {
        let replacement = weightsURL.deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString)")
        try Self.chmod(root, 0o700)
        defer { _ = Darwin.chmod(root.path, 0o500) }
        try contents.write(to: replacement)
        try Self.chmod(replacement, 0o400)
        guard Darwin.rename(replacement.path, weightsURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func mutateWeightsAndRestore() throws {
        try Self.chmod(weightsURL, 0o600)
        defer { _ = Darwin.chmod(weightsURL.path, 0o400) }
        try Data("payloae".utf8).write(to: weightsURL)
        try Data("payload".utf8).write(to: weightsURL)
    }

    func replaceWeightsInPlace(with contents: Data) throws {
        try Self.chmod(weightsURL, 0o600)
        defer { _ = Darwin.chmod(weightsURL.path, 0o400) }
        try contents.write(to: weightsURL)
    }

    func replaceManifest(with data: Data) throws {
        try Self.chmod(manifestURL, 0o600)
        try data.write(to: manifestURL)
        try Self.chmod(manifestURL, 0o400)
    }

    func removeWeights() throws {
        try Self.chmod(root, 0o700)
        try FileManager.default.removeItem(at: weightsURL)
        try Self.chmod(root, 0o500)
    }

    func addReadOnlyFile(path: String, contents: String) throws {
        try Self.chmod(root, 0o700)
        let url = root.appendingPathComponent(path)
        try Data(contents.utf8).write(to: url)
        try Self.chmod(url, 0o400)
        try Self.chmod(root, 0o500)
    }

    func addReadOnlyFile(inDirectory directoryPath: String, path: String, contents: String) throws {
        let directory = root.appendingPathComponent(directoryPath, isDirectory: true)
        try Self.chmod(directory, 0o700)
        defer { _ = Darwin.chmod(directory.path, 0o500) }
        let url = directory.appendingPathComponent(path)
        try Data(contents.utf8).write(to: url)
        try Self.chmod(url, 0o400)
    }

    func replaceReadOnlyFileInPlace(path: String, contents: Data) throws {
        let url = root.appendingPathComponent(path)
        try Self.chmod(url, 0o600)
        defer { _ = Darwin.chmod(url.path, 0o400) }
        try contents.write(to: url)
    }

    func addSparseReadOnlyFile(path: String, size: Int64) throws {
        try Self.chmod(root, 0o700)
        defer { _ = Darwin.chmod(root.path, 0o500) }
        let url = root.appendingPathComponent(path)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.ftruncate(descriptor, off_t(size)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try Self.chmod(url, 0o400)
    }

    func addUnexpectedDirectoryWithHiddenFile(path: String) throws {
        try Self.chmod(root, 0o700)
        defer { _ = Darwin.chmod(root.path, 0o500) }
        let directory = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("hidden".utf8).write(to: directory.appendingPathComponent(".hidden"))
        try Self.chmod(directory.appendingPathComponent(".hidden"), 0o400)
        try Self.chmod(directory, 0o500)
    }

    func replaceWeightsWithSymlink() throws {
        try Self.chmod(root, 0o700)
        defer { _ = Darwin.chmod(root.path, 0o500) }
        try FileManager.default.removeItem(at: weightsURL)
        try FileManager.default.createSymbolicLink(at: weightsURL, withDestinationURL: manifestURL)
    }

    static func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func manifestFile(
        path: String,
        data: Data
    ) -> GemmaModelManifest.GemmaModelFile {
        .init(relativePath: path, size: Int64(data.count), sha256: sha256(data))
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private static func freezeRecursively(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        var directories: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CocoaError(.fileReadUnknown)
            }
            if isDirectory.boolValue {
                directories.append(url)
            } else {
                try chmod(url, 0o400)
            }
        }
        for directory in directories.reversed() {
            try chmod(directory, 0o500)
        }
        try chmod(root, 0o500)
    }

    private static func makeWritableRecursively(_ root: URL) {
        _ = Darwin.chmod(root.path, 0o700)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                _ = Darwin.chmod(url.path, isDirectory.boolValue ? 0o700 : 0o600)
            }
        }
    }
}
