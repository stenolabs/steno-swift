import Foundation
import Security
import StenoGemmaIPC
import XCTest

final class StenoGemmaXPCIntegrationTests: XCTestCase {
    func testSignedEmbeddedHelperHandshakesAndKeepsInferenceUnavailable() async throws {
        let hostIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let results = try await Task.detached {
            try await Self.exerciseProtocol(hostIdentifier: hostIdentifier)
        }.value

        XCTAssertEqual(results.handshake, .handshake(.init(
            serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            supportedOperations: [.handshake, .cancel, .shutdown]
        )))
        XCTAssertEqual(
            results.countTokens,
            .failure(.init(code: .modelUnavailable))
        )
        XCTAssertEqual(
            results.generate,
            .failure(.init(code: .modelUnavailable))
        )
        XCTAssertEqual(
            results.mismatchedOuterRequestID,
            .failure(.init(code: .invalidRequest))
        )
        XCTAssertEqual(
            results.shutdown,
            .acknowledgement(.init(kind: .shutdown, didChangeState: true))
        )
    }

    private static func exerciseProtocol(
        hostIdentifier: String
    ) async throws -> XPCProtocolResults {
        let helperIdentifier = hostIdentifier + ".GemmaXPC"
        let connection = NSXPCConnection(serviceName: helperIdentifier)
        connection.remoteObjectInterface = NSXPCInterface(
            with: (any StenoGemmaXPCProtocol).self
        )
        connection.setCodeSigningRequirement(
            try helperRequirement(bundleIdentifier: helperIdentifier)
        )
        connection.resume()
        defer { connection.invalidate() }

        let pin = try GemmaModelSnapshotPin(
            modelIdentifier: "google/gemma-4-e4b-it-4bit",
            checkpointRevision: String(repeating: "1", count: 40),
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            licenseIdentifier: "Apache-2.0",
            manifestSHA256: String(repeating: "a", count: 64)
        )

        let handshake = try GemmaIPCRequestEnvelope(
            body: .handshake(.init(model: pin))
        )
        let handshakeResponse = try await send(handshake, over: connection)

        let countTokens = try GemmaIPCRequestEnvelope(
            body: .countTokens(try .init(model: pin, text: "Harmless fixture."))
        )
        let countTokensResponse = try await send(countTokens, over: connection)

        let generate = try GemmaIPCRequestEnvelope(
            body: .generate(try .init(
                model: pin,
                prompt: "Do not run a model.",
                maximumTokens: 16
            ))
        )
        let generateResponse = try await send(generate, over: connection)

        let mismatchedOuterRequestIDResponse = try await send(
            generate,
            outerRequestID: UUID(),
            over: connection
        )

        let shutdown = try GemmaIPCRequestEnvelope(body: .shutdown)
        let shutdownResponse = try await send(shutdown, over: connection)

        return XPCProtocolResults(
            handshake: handshakeResponse.body,
            countTokens: countTokensResponse.body,
            generate: generateResponse.body,
            mismatchedOuterRequestID: mismatchedOuterRequestIDResponse.body,
            shutdown: shutdownResponse.body
        )
    }

    private static func send(
        _ request: GemmaIPCRequestEnvelope,
        outerRequestID: UUID? = nil,
        over connection: NSXPCConnection
    ) async throws -> GemmaIPCResponseEnvelope {
        let encodedRequest = try GemmaIPCCodec.encode(request)
        let correlatedRequestID = outerRequestID ?? request.requestID
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReply(continuation: continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                reply.finish(.failure(error))
            }
            guard let service = proxy as? StenoGemmaXPCProtocol else {
                reply.finish(.failure(StenoGemmaXPCTestError.missingProxy))
                return
            }
            service.sendRequest(
                encodedRequest as NSData,
                requestID: correlatedRequestID as NSUUID
            ) { response in
                reply.finish(.success(response as Data))
            }
        }
        return try GemmaIPCCodec.decodeResponse(
            data,
            expectedRequestID: correlatedRequestID,
            expectedOperation: request.body.operation
        )
    }

    private static func helperRequirement(bundleIdentifier: String) throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code
        else {
            throw StenoGemmaXPCTestError.signingInformationUnavailable
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw StenoGemmaXPCTestError.signingInformationUnavailable
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [CFString: Any],
              let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier] as? String,
              isRequirementAtom(bundleIdentifier),
              isRequirementAtom(teamIdentifier)
        else {
            throw StenoGemmaXPCTestError.signingInformationUnavailable
        }

        return "anchor apple generic and identifier \"\(bundleIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    private static func isRequirementAtom(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }
}

private struct XPCProtocolResults: Sendable {
    let handshake: GemmaIPCResponseBody
    let countTokens: GemmaIPCResponseBody
    let generate: GemmaIPCResponseBody
    let mismatchedOuterRequestID: GemmaIPCResponseBody
    let shutdown: GemmaIPCResponseBody
}

private final class XPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            self.finish(.failure(StenoGemmaXPCTestError.timeout))
        }
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private enum StenoGemmaXPCTestError: Error {
    case missingProxy
    case signingInformationUnavailable
    case timeout
}
