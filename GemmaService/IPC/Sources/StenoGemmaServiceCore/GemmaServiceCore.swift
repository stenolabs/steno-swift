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

/// A path-free model executor injected only after a helper session has activated its exact pin.
///
/// The service core owns request validation and safe error mapping. Implementations must never
/// select another model or provider when work fails.
public protocol GemmaModelExecuting: Sendable {
    func countTokens(in text: String) async throws -> Int
    func generate(prompt: String, maximumTokens: Int) async throws -> String
}

/// Couples one executor to the exact immutable model pin activated for its helper session.
public struct GemmaBoundModelExecutor: Sendable {
    public let model: GemmaModelSnapshotPin
    fileprivate let executor: any GemmaModelExecuting

    public init(
        model: GemmaModelSnapshotPin,
        executor: any GemmaModelExecuting
    ) {
        self.model = model
        self.executor = executor
    }
}

/// Failures that a model executor may deliberately expose through the fixed IPC error vocabulary.
///
/// Session binding, helper lifecycle, and admission state belong to the service and registry, not
/// to an executor. Executors report only outcomes of work they were asked to perform.
public enum GemmaModelExecutionError: Error, Equatable, Sendable {
    case modelUnavailable
    case unsupportedModel
    case contextWindowExceeded
    case responseTruncated
    case cancelled
    case generationFailed
    case internalFailure

    fileprivate var ipcCode: GemmaIPCErrorCode {
        switch self {
        case .modelUnavailable:
            .modelUnavailable
        case .unsupportedModel:
            .unsupportedModel
        case .contextWindowExceeded:
            .contextWindowExceeded
        case .responseTruncated:
            .responseTruncated
        case .cancelled:
            .cancelled
        case .generationFailed:
            .generationFailed
        case .internalFailure:
            .internalFailure
        }
    }
}

/// Model-free, fail-closed dispatcher for the sandboxed Gemma XPC service.
///
/// This core never accesses the network, filesystem, model weights, audio, or app state.
public actor GemmaServiceCore {
    private let buildInfo: GemmaServiceCoreBuildInfo
    private let boundModelExecutor: GemmaBoundModelExecutor?
    private var inferenceInFlight = false

    public init(
        buildInfo: GemmaServiceCoreBuildInfo,
        boundModelExecutor: GemmaBoundModelExecutor? = nil
    ) {
        self.buildInfo = buildInfo
        self.boundModelExecutor = boundModelExecutor
    }

    /// Handles exactly one size-bounded request frame and always rejects unsupported work.
    public func handle(
        encodedRequest: Data,
        expectedRequestID: UUID
    ) async -> Data {
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
            if let boundModelExecutor, handshake.model != boundModelExecutor.model {
                return encodedFailure(requestID: request.requestID, code: .modelIntegrityFailure)
            }
            var supportedOperations: [GemmaIPCOperation] = [.handshake]
            if boundModelExecutor != nil {
                supportedOperations.append(contentsOf: [.countTokens, .generate])
            }
            supportedOperations.append(contentsOf: [.cancel, .shutdown])
            return encodedResponse(
                requestID: request.requestID,
                body: .handshake(
                    GemmaIPCHandshakeResponse(
                        serviceIdentifier: buildInfo.serviceIdentifier,
                        adapterRevision: buildInfo.adapterRevision,
                        supportedOperations: supportedOperations
                    )
                )
            )
        case .countTokens(let tokenRequest):
            guard let boundModelExecutor else {
                return encodedFailure(requestID: request.requestID, code: .modelUnavailable)
            }
            guard boundModelExecutor.model.adapterRevision == buildInfo.adapterRevision else {
                return encodedFailure(requestID: request.requestID, code: .adapterMismatch)
            }
            guard tokenRequest.model == boundModelExecutor.model else {
                return encodedFailure(requestID: request.requestID, code: .modelIntegrityFailure)
            }
            guard acquireInferenceSlot() else {
                return encodedFailure(requestID: request.requestID, code: .busy)
            }
            defer { releaseInferenceSlot() }
            do {
                try Task.checkCancellation()
                let tokenCount = try await boundModelExecutor.executor.countTokens(
                    in: tokenRequest.text
                )
                try Task.checkCancellation()
                guard tokenCount >= 0 else {
                    return encodedFailure(requestID: request.requestID, code: .internalFailure)
                }
                return encodedResponse(
                    requestID: request.requestID,
                    body: .tokenCount(.init(tokenCount: tokenCount))
                )
            } catch {
                return encodedExecutionFailure(requestID: request.requestID, error: error)
            }
        case .generate(let generationRequest):
            guard let boundModelExecutor else {
                return encodedFailure(requestID: request.requestID, code: .modelUnavailable)
            }
            guard boundModelExecutor.model.adapterRevision == buildInfo.adapterRevision else {
                return encodedFailure(requestID: request.requestID, code: .adapterMismatch)
            }
            guard generationRequest.model == boundModelExecutor.model else {
                return encodedFailure(requestID: request.requestID, code: .modelIntegrityFailure)
            }
            guard acquireInferenceSlot() else {
                return encodedFailure(requestID: request.requestID, code: .busy)
            }
            defer { releaseInferenceSlot() }
            do {
                try Task.checkCancellation()
                let text = try await boundModelExecutor.executor.generate(
                    prompt: generationRequest.prompt,
                    maximumTokens: generationRequest.maximumTokens
                )
                try Task.checkCancellation()
                guard text.utf8.count <= GemmaIPCProtocol.maximumTextBytes else {
                    return encodedFailure(requestID: request.requestID, code: .responseTruncated)
                }
                return encodedResponse(
                    requestID: request.requestID,
                    body: .generate(.init(text: text))
                )
            } catch {
                return encodedExecutionFailure(requestID: request.requestID, error: error)
            }
        }
    }

    /// Actors are reentrant at each executor await, so this guard must live in the core rather
    /// than relying on its actor isolation alone. It covers counting and generation together
    /// because a bound executor may not safely overlap either operation with the other.
    private func acquireInferenceSlot() -> Bool {
        guard !inferenceInFlight else {
            return false
        }
        inferenceInFlight = true
        return true
    }

    private func releaseInferenceSlot() {
        precondition(inferenceInFlight)
        inferenceInFlight = false
    }

    private func encodedExecutionFailure(requestID: UUID, error: any Error) -> Data {
        if error is CancellationError || Task.isCancelled {
            return encodedFailure(requestID: requestID, code: .cancelled)
        }
        if let executionError = error as? GemmaModelExecutionError {
            return encodedFailure(requestID: requestID, code: executionError.ipcCode)
        }
        return encodedFailure(requestID: requestID, code: .internalFailure)
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
