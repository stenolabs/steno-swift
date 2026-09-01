import Foundation
import StenoGemmaClient
import StenoGemmaIPC
import StenoGemmaProcessGate
import XCTest

final class StenoGemmaXPCIntegrationTests: XCTestCase {
    func testRawSignedHelperRefusesInferenceAndExitsBeforeRecordingLease() async throws {
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

        let results: XPCProtocolResults
        do {
            results = try await Task.detached {
                try await Self.exerciseProtocol(
                    helperBundleURL: helperBundleURL,
                    processGate: processGate
                )
            }.value
        } catch {
            XCTFail("Raw XPC protocol exercise failed: \(String(reflecting: error))")
            return
        }

        XCTAssertEqual(
            results.handshake,
            .handshake(.init(
                serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
                adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                supportedOperations: [.handshake, .cancel, .shutdown]
            )))
        XCTAssertEqual(results.countTokens, .failure(.init(code: .modelUnavailable)))
        XCTAssertEqual(results.generate, .failure(.init(code: .modelUnavailable)))
        XCTAssertEqual(results.stateDuringLease, .recording)
        XCTAssertEqual(results.stateAfterRelease, .idle)
        XCTAssertEqual(
            results.handshakeAfterRelease,
            .handshake(.init(
                serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
                adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                supportedOperations: [.handshake, .cancel, .shutdown]
            )))
    }

    private static func exerciseProtocol(
        helperBundleURL: URL,
        processGate: GemmaProcessGate
    ) async throws -> XPCProtocolResults {
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: try GemmaRawXPCTransportFactory(
                helperBundleURL: helperBundleURL,
                processGate: processGate
            ),
            exitProver: GemmaDispatchSourceExitProver(),
            deadline: GemmaContinuousClockDeadline(timeout: .seconds(20))
        )
        let pin = try GemmaModelSnapshotPin(
            modelIdentifier: "google/gemma-4-e4b-it-4bit",
            checkpointRevision: String(repeating: "1", count: 40),
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            licenseIdentifier: "Apache-2.0",
            manifestSHA256: String(repeating: "a", count: 64)
        )

        let modelResults = try await controller.withModelSession { session in
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
