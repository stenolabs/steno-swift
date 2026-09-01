import CryptoKit
import Darwin
import Foundation
import StenoGemmaClient
import StenoGemmaIPC
import StenoGemmaModelStore
import StenoGemmaProcessGate
import XCTest

final class StenoGemmaXPCIntegrationTests: XCTestCase {
    func testSignedHelperRejectsVerifiedButUnapprovedSnapshotBeforeRecordingLease() async throws {
        let fixture = try SyntheticModelFixture.make()
        let resolver = FreshModelDirectoryResolver(fixture: fixture)
        let helperBundleURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("StenoGemmaXPC.xpc", isDirectory: true)
        let gateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-gemma-xpc-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: gateDirectory) }
        let processGate = GemmaProcessGate(
            configuration: try GemmaProcessGateConfiguration(directoryURL: gateDirectory)
        )

        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: try GemmaRawXPCTransportFactory(
                helperBundleURL: helperBundleURL,
                processGate: processGate,
                resolveModelDirectory: resolver.resolve
            ),
            exitProver: GemmaDispatchSourceExitProver(),
            deadline: GemmaContinuousClockDeadline(timeout: .seconds(20))
        )

        do {
            _ = try await controller.send(.handshake(.init(model: fixture.pin)))
            XCTFail("a verified snapshot outside the reviewed production catalog must not bind")
        } catch {
            XCTAssertEqual(
                error as? GemmaClientControllerError,
                .operationFailed(.sessionActivation)
            )
        }

        let recordingLease = try await processGate.acquireRecordingLease(
            until: ContinuousClock().now.advanced(by: .seconds(2))
        )
        recordingLease.close()
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testSyntheticResolverRejectsWrongPinAndRootOrFileDescriptorVerificationFailsClosed() throws {
        let fixture = try SyntheticModelFixture.make()
        let wrongPin = try GemmaModelSnapshotPin(
            modelIdentifier: "google/other-model",
            checkpointRevision: fixture.pin.checkpointRevision,
            adapterRevision: fixture.pin.adapterRevision,
            licenseIdentifier: fixture.pin.licenseIdentifier,
            manifestSHA256: fixture.pin.manifestSHA256
        )
        XCTAssertThrowsError(try fixture.resolve(wrongPin))

        let descriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let identity = try fixture.rootIdentity()
        XCTAssertThrowsError(
            try fixture.verifier.verify(
                adoptingDirectoryDescriptor: descriptor,
                expectedRootIdentity: GemmaModelRootIdentity(
                    deviceID: identity.deviceID,
                    fileID: identity.fileID &+ 1
                )
            )
        )

        var pipeDescriptors: [Int32] = [-1, -1]
        XCTAssertEqual(Darwin.pipe(&pipeDescriptors), 0)
        defer {
            if pipeDescriptors[0] >= 0 { _ = Darwin.close(pipeDescriptors[0]) }
            if pipeDescriptors[1] >= 0 { _ = Darwin.close(pipeDescriptors[1]) }
        }
        let adoptedPipeDescriptor = pipeDescriptors[0]
        XCTAssertThrowsError(
            try fixture.verifier.verify(adoptingDirectoryDescriptor: pipeDescriptors[0])
        )
        errno = 0
        XCTAssertEqual(Darwin.fcntl(adoptedPipeDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        pipeDescriptors[0] = -1
    }

    func testResolverFailureLeavesExecutionGateUnacquiredWithoutLaunchingHelper() async throws {
        let fixture = try SyntheticModelFixture.make()
        let helperBundleURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("StenoGemmaXPC.xpc", isDirectory: true)
        let gateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-gemma-xpc-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: gateDirectory) }
        let processGate = GemmaProcessGate(
            configuration: try GemmaProcessGateConfiguration(directoryURL: gateDirectory)
        )
        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: try GemmaRawXPCTransportFactory(
                helperBundleURL: helperBundleURL,
                processGate: processGate,
                resolveModelDirectory: { _ in
                    throw CocoaError(.fileReadNoSuchFile)
                }
            ),
            exitProver: GemmaDispatchSourceExitProver(),
            deadline: GemmaContinuousClockDeadline(timeout: .seconds(2))
        )

        do {
            _ = try await controller.send(.handshake(.init(model: fixture.pin)))
            XCTFail("a failed resolver must not create a model session")
        } catch {
        XCTAssertEqual(
            error as? GemmaClientControllerError,
            .operationFailed(.sessionActivation)
        )
        }

        let recordingLease = try await processGate.acquireRecordingLease(
            until: ContinuousClock().now.advanced(by: .seconds(2))
        )
        recordingLease.close()
    }

    func testPreparedTransportAcquiresExecutionGateOnlyDuringActivation() async throws {
        let fixture = try SyntheticModelFixture.make()
        let helperBundleURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("StenoGemmaXPC.xpc", isDirectory: true)
        let gateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-gemma-xpc-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: gateDirectory) }
        let processGate = GemmaProcessGate(
            configuration: try GemmaProcessGateConfiguration(directoryURL: gateDirectory)
        )
        let factory = try GemmaRawXPCTransportFactory(
            helperBundleURL: helperBundleURL,
            processGate: processGate,
            resolveModelDirectory: fixture.resolve
        )

        let preparation = try await factory.prepareTransport(for: fixture.pin)
        defer { preparation.invalidate() }

        let recordingLease = try await processGate.acquireRecordingLease(
            until: ContinuousClock().now.advanced(by: .seconds(2))
        )
        defer { recordingLease.close() }

        XCTAssertThrowsError(try preparation.activate()) { error in
            XCTAssertEqual(
                error as? GemmaRawXPCTransportError,
                .executionGateBusy
            )
        }
    }

    private static func exerciseProtocol(
        helperBundleURL: URL,
        processGate: GemmaProcessGate,
        pin: GemmaModelSnapshotPin,
        resolver: FreshModelDirectoryResolver
    ) async throws -> XPCProtocolResults {
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: try GemmaRawXPCTransportFactory(
                helperBundleURL: helperBundleURL,
                processGate: processGate,
                resolveModelDirectory: resolver.resolve
            ),
            exitProver: GemmaDispatchSourceExitProver(),
            deadline: GemmaContinuousClockDeadline(timeout: .seconds(20))
        )

        let modelResults = try await controller.withModelSession(model: pin) { session in
            let handshake = try await session.send(.handshake(.init(model: pin)))
            let countTokens = try await session.send(
                .countTokens(try .init(model: pin, text: "Harmless fixture."))
            )
            let generate = try await session.send(
                .generate(try .init(
                    model: pin,
                    prompt: "Do not run a model.",
                    maximumTokens: 16
                ))
            )
            return XPCModelResults(
                handshake: handshake,
                countTokens: countTokens,
                generate: generate
            )
        }

        let leaseToken = GemmaRecordingLease()
        let lease = try await controller.acquireRecordingLease(leaseToken)
        let stateDuringLease = await controller.lifecycleState()
        try await controller.releaseRecordingLease(lease)
        let stateAfterRelease = await controller.lifecycleState()

        // Releasing does not reconnect eagerly. This explicit request creates a fresh helper.
        let handshakeAfterRelease = try await controller.send(.handshake(.init(model: pin)))

        return XPCProtocolResults(
            handshake: modelResults.handshake,
            countTokens: modelResults.countTokens,
            generate: modelResults.generate,
            stateDuringLease: stateDuringLease,
            stateAfterRelease: stateAfterRelease,
            handshakeAfterRelease: handshakeAfterRelease
        )
    }
}

private final class FreshModelDirectoryResolver: @unchecked Sendable {
    private let fixture: SyntheticModelFixture
    private let lock = NSLock()
    private var resolutions = 0

    init(fixture: SyntheticModelFixture) {
        self.fixture = fixture
    }

    var callCount: Int {
        lock.withLock { resolutions }
    }

    func resolve(_ pin: GemmaModelSnapshotPin) throws -> VerifiedGemmaModelDirectory {
        lock.withLock { resolutions += 1 }
        return try fixture.resolve(pin)
    }
}

private final class SyntheticModelFixture: @unchecked Sendable {
    let root: URL
    let pin: GemmaModelSnapshotPin
    let verifier: GemmaModelVerifier

    static func make() throws -> SyntheticModelFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-gemma-xpc-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let modelIdentifier = "google/gemma4-test"
        let checkpointRevision = String(repeating: "1", count: 40)
        let adapterRevision = GemmaIPCBuildInfo.adapterRevision
        let licenseIdentifier = "Apache-2.0"
        let payload = Data("synthetic model payload".utf8)
        let manifest = GemmaModelManifest(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: [
                .init(
                    relativePath: "weights.bin",
                    size: Int64(payload.count),
                    sha256: sha256(payload)
                )
            ]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try payload.write(to: root.appendingPathComponent("weights.bin"), options: .withoutOverwriting)
        try manifestData.write(
            to: root.appendingPathComponent("gemma-model-manifest.json"),
            options: .withoutOverwriting
        )
        try chmodRecursively(root)

        let digest = sha256(manifestData)
        let requirements = try GemmaModelRequirements(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            expectedManifestSHA256: digest
        )
        let pin = try GemmaModelSnapshotPin(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            manifestSHA256: digest
        )
        let verifier = GemmaModelVerifier(requirements: requirements)
        return SyntheticModelFixture(root: root, pin: pin, verifier: verifier)
    }

    func resolve(_ requestedPin: GemmaModelSnapshotPin) throws -> VerifiedGemmaModelDirectory {
        guard requestedPin == pin else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return try verifier.verify(
            adoptingDirectoryDescriptor: descriptor,
            expectedRootIdentity: rootIdentity()
        )
    }

    func rootIdentity() throws -> GemmaModelRootIdentity {
        var status = stat()
        guard Darwin.lstat(root.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return GemmaModelRootIdentity(
            deviceID: UInt64(status.st_dev),
            fileID: UInt64(status.st_ino)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func chmodRecursively(_ root: URL) throws {
        guard Darwin.chmod(root.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var directories: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                directories.append(url)
            } else if Darwin.chmod(url.path, 0o400) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        for directory in directories.reversed() where Darwin.chmod(directory.path, 0o500) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.chmod(root.path, 0o500) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    init(root: URL, pin: GemmaModelSnapshotPin, verifier: GemmaModelVerifier) {
        self.root = root
        self.pin = pin
        self.verifier = verifier
    }

    deinit {
        _ = Darwin.chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct XPCModelResults: Sendable {
    let handshake: GemmaIPCResponseBody
    let countTokens: GemmaIPCResponseBody
    let generate: GemmaIPCResponseBody
}

private struct XPCProtocolResults: Sendable {
    let handshake: GemmaIPCResponseBody
    let countTokens: GemmaIPCResponseBody
    let generate: GemmaIPCResponseBody
    let stateDuringLease: GemmaClientControllerState
    let stateAfterRelease: GemmaClientControllerState
    let handshakeAfterRelease: GemmaIPCResponseBody
}
