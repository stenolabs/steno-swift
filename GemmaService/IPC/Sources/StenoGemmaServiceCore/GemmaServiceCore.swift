import Foundation
import StenoGemmaIPC

/// Build identity injected by the executable target instead of being inferred from a model.
public struct GemmaServiceCoreBuildInfo: Sendable, Equatable {
    public let serviceIdentifier: String
    public let adapterRevision: String

    public init(serviceIdentifier: String, adapterRevision: String) {
        self.serviceIdentifier = serviceIdentifier
        self.adapterRevision = adapterRevision
    }

    public static let current = GemmaServiceCoreBuildInfo(
        serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
        adapterRevision: GemmaIPCBuildInfo.adapterRevision
    )
}

/// Model-free, fail-closed dispatcher for the sandboxed Gemma XPC service.
///
/// This core never accesses the network, filesystem, model weights, audio, or app state.
public actor GemmaServiceCore {
    private let buildInfo: GemmaServiceCoreBuildInfo

    public init(buildInfo: GemmaServiceCoreBuildInfo) {
        self.buildInfo = buildInfo
    }

    /// Handles exactly one size-bounded request frame and always rejects unsupported work.
    public func handle(
        encodedRequest: Data,
        expectedRequestID: UUID
    ) -> Data {
        let request: GemmaIPCRequestEnvelope
        do {
            request = try GemmaIPCCodec.decodeRequest(encodedRequest)
        } catch let error as GemmaIPCCodecError {
            let code: GemmaIPCErrorCode = switch error {
            case .malformedMessage:
                .invalidRequest
            case .oversizedMessage:
                .requestTooLarge
            case .protocolMismatch:
                .protocolMismatch
            }
            return encodedFailure(
                requestID: expectedRequestID,
                code: code
            )
        } catch {
            return encodedFailure(requestID: expectedRequestID, code: .invalidRequest)
        }

        if request.requestID != expectedRequestID {
            return encodedFailure(requestID: expectedRequestID, code: .invalidRequest)
        }

        switch request.body {
        case .cancel, .shutdown:
            // The process-wide registry owns lifecycle work so these operations never queue
            // behind a future model actor through the production XPC path.
            return encodedFailure(requestID: request.requestID, code: .invalidRequest)
        case .handshake(let handshake):
            guard handshake.model.adapterRevision == buildInfo.adapterRevision else {
                return encodedFailure(requestID: request.requestID, code: .adapterMismatch)
            }
            return encodedResponse(
                requestID: request.requestID,
                body: .handshake(
                    GemmaIPCHandshakeResponse(
                        serviceIdentifier: buildInfo.serviceIdentifier,
                        adapterRevision: buildInfo.adapterRevision,
                        supportedOperations: [.handshake, .cancel, .shutdown]
                    )
                )
            )
        case .countTokens, .generate:
            return encodedFailure(requestID: request.requestID, code: .modelUnavailable)
        }
    }

    private func encodedResponse(
        requestID: UUID,
        body: GemmaIPCResponseBody
    ) -> Data {
        let response = GemmaIPCResponseEnvelope(requestID: requestID, body: body)
        do {
            return try GemmaIPCCodec.encode(response)
        } catch {
            return Data()
        }
    }

    private func encodedFailure(requestID: UUID, code: GemmaIPCErrorCode) -> Data {
        encodedResponse(requestID: requestID, body: .failure(GemmaIPCFailure(code: code)))
    }
}
