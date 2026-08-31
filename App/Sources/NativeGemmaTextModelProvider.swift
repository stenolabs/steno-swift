#if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
import Foundation
import StenoDomain
import StenoGemmaClient
import StenoGemmaIPC
import StenoIntelligence

enum NativeGemmaTextModelProviderError: Error, Equatable, LocalizedError, Sendable {
    case modelNotApproved
    case invalidResourceProfile
    case unexpectedHelperResponse
    case invalidStructuredOutput
    case helperUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotApproved:
            "This native Gemma checkpoint is not approved by this Steno build."
        case .invalidResourceProfile:
            "The native Gemma resource profile is invalid."
        case .unexpectedHelperResponse:
            "The native Gemma helper returned an unexpected response."
        case .invalidStructuredOutput:
            "Native Gemma returned an incomplete structured result."
        case .helperUnavailable:
            "Native Gemma is unavailable. The recording and transcript are unaffected."
        }
    }
}

/// App-side prompt and response budget for one exact immutable checkpoint.
///
/// This catalogue is intentionally independent from model import consent. A release must add the
/// same pin and compatible limits to the app import catalogue and the helper activation catalogue.
struct NativeGemmaProviderProfile: Equatable, Sendable {
    let snapshot: NativeGemmaModelSnapshot
    let maximumPromptTokens: Int
    let maximumResponseTokens: Int
    let safetyTokens: Int

    init(
        snapshot: NativeGemmaModelSnapshot,
        maximumPromptTokens: Int,
        maximumResponseTokens: Int,
        safetyTokens: Int = 128
    ) throws {
        guard snapshot.isWellFormed,
              maximumPromptTokens > 0,
              (1 ... GemmaIPCProtocol.maximumGenerationTokens)
                .contains(maximumResponseTokens),
              safetyTokens >= 0,
              maximumPromptTokens <= Int.max - maximumResponseTokens - safetyTokens
        else {
            throw NativeGemmaTextModelProviderError.invalidResourceProfile
        }
        self.snapshot = snapshot
        self.maximumPromptTokens = maximumPromptTokens
        self.maximumResponseTokens = maximumResponseTokens
        self.safetyTokens = safetyTokens
    }

    var contextWindow: TextModelContextWindow {
        TextModelContextWindow(
            maximumTokens: maximumPromptTokens + maximumResponseTokens + safetyTokens,
            reservedResponseTokens: maximumResponseTokens,
            safetyTokens: safetyTokens
        )
    }

    var modelPin: GemmaModelSnapshotPin {
        get throws {
            try GemmaModelSnapshotPin(
                modelIdentifier: snapshot.modelIdentifier,
                checkpointRevision: snapshot.checkpointRevision,
                adapterRevision: snapshot.adapterRevision,
                licenseIdentifier: snapshot.licenseIdentifier,
                manifestSHA256: snapshot.manifestSHA256
            )
        }
    }
}

struct NativeGemmaProviderCatalog: Sendable {
    static let gemma4E2BSnapshot = NativeGemmaModelSnapshot(
        modelIdentifier: "mlx-community/gemma-4-e2b-it-4bit",
        checkpointRevision: "238767527555cb75a05732a84dff5d6ba0dd6809",
        adapterRevision: GemmaIPCBuildInfo.adapterRevision,
        licenseIdentifier: "gemma",
        manifestSHA256: "dab4d380ff03b1e6ac34fa47a0db672e540ee399b9d04dc765ba832a6f59cca5"
    )

    private let profiles: [NativeGemmaProviderProfile]

    init(profiles: [NativeGemmaProviderProfile]) {
        self.profiles = profiles
    }

    func profile(for snapshot: NativeGemmaModelSnapshot) -> NativeGemmaProviderProfile? {
        var match: NativeGemmaProviderProfile?
        for profile in profiles where profile.snapshot == snapshot {
            guard match == nil else { return nil }
            match = profile
        }
        return match
    }

    /// Exactly one local checkpoint is available, with a deliberately small prompt and response
    /// budget for the first measured macOS 27 integration.
    static let production = NativeGemmaProviderCatalog(profiles: [
        try? NativeGemmaProviderProfile(
            snapshot: gemma4E2BSnapshot,
            maximumPromptTokens: 4_096,
            maximumResponseTokens: 256
        ),
    ].compactMap { $0 })
}

/// A native, local-only text-model provider backed by one closure-scoped helper session.
///
/// One complete render keeps one exact model session alive for all token counts, map calls, and
/// reduce calls. The session is retired before `render` returns or throws. There is no Ollama,
/// network, or `SystemLanguageModel` fallback at any point in this provider.
struct NativeGemmaTextModelProvider: TextModelProvider {
    let descriptor: EngineDescriptor
    let availability: TextModelAvailability = .available

    private let profile: NativeGemmaProviderProfile
    private let coordinator: any NativeGemmaCoordinator

    init(
        snapshot: NativeGemmaModelSnapshot,
        catalog: NativeGemmaProviderCatalog = .production,
        coordinator: any NativeGemmaCoordinator = NativeGemmaRecordingBarrierFactory.live()
    ) throws {
        guard let profile = catalog.profile(for: snapshot) else {
            throw NativeGemmaTextModelProviderError.modelNotApproved
        }
        self.profile = profile
        self.coordinator = coordinator
        descriptor = .mlxGemma(snapshot: snapshot)
    }

    func render(
        template: Template,
        transcript: TranscriptRevision
    ) async throws -> TemplateResult {
        try await render(
            template: template,
            transcript: transcript,
            participants: nil,
            context: .empty
        )
    }

    func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String]
    ) async throws -> TemplateResult {
        try await render(
            template: template,
            transcript: transcript,
            participants: participants,
            context: .empty
        )
    }

    func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String],
        context: RenderContext
    ) async throws -> TemplateResult {
        try await render(
            template: template,
            transcript: transcript,
            participants: Optional(participants),
            context: context
        )
    }

    private func render(
        template: Template,
        transcript: TranscriptRevision,
        participants: [String]?,
        context: RenderContext
    ) async throws -> TemplateResult {
        let model = try profile.modelPin
        return try await coordinator.withNativeModelSession(model: model) { session in
            let provider = NativeGemmaSessionStructuredProvider(
                descriptor: descriptor,
                profile: profile,
                session: session
            )
            return try await TemplateRenderer(provider: provider).render(
                template: template,
                transcript: transcript,
                participants: participants,
                context: context
            )
        }
    }
}

private struct NativeGemmaSessionStructuredProvider: StructuredTextModelProvider {
    let descriptor: EngineDescriptor
    let contextWindow: TextModelContextWindow
    let availability: TextModelAvailability = .available

    private let model: GemmaModelSnapshotPin
    private let maximumResponseTokens: Int
    private let session: NativeGemmaClientModelSession

    init(
        descriptor: EngineDescriptor,
        profile: NativeGemmaProviderProfile,
        session: NativeGemmaClientModelSession
    ) {
        self.descriptor = descriptor
        contextWindow = profile.contextWindow
        model = session.model
        maximumResponseTokens = profile.maximumResponseTokens
        self.session = session
    }

    func inputTokenCount(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> Int {
        let prompt = StructuredTextModelJSONContract.prompt(
            template: template,
            request: request,
            context: context
        )
        let body: GemmaIPCRequestBody
        do {
            body = .countTokens(try GemmaIPCTokenCountRequest(model: model, text: prompt))
        } catch GemmaIPCValidationError.textTooLarge {
            throw TextModelProviderError.contextWindowExceeded
        } catch {
            throw NativeGemmaTextModelProviderError.helperUnavailable
        }
        let response = try await mappedSend(body)
        guard case .tokenCount(let tokenCount) = response,
              tokenCount.tokenCount >= 0 else {
            throw NativeGemmaTextModelProviderError.unexpectedHelperResponse
        }
        return tokenCount.tokenCount
    }

    func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        let prompt = StructuredTextModelJSONContract.prompt(
            template: template,
            request: request,
            context: context
        )
        let body: GemmaIPCRequestBody
        do {
            body = .generate(try GemmaIPCGenerateRequest(
                model: model,
                prompt: prompt,
                maximumTokens: maximumResponseTokens
            ))
        } catch GemmaIPCValidationError.textTooLarge {
            throw TextModelProviderError.contextWindowExceeded
        } catch {
            throw NativeGemmaTextModelProviderError.helperUnavailable
        }
        let response = try await mappedSend(body)
        guard case .generate(let generated) = response else {
            throw NativeGemmaTextModelProviderError.unexpectedHelperResponse
        }
        do {
            return try StructuredTextModelJSONContract.decode(
                generated.text,
                template: template
            )
        } catch {
            throw NativeGemmaTextModelProviderError.invalidStructuredOutput
        }
    }

    private func mappedSend(
        _ body: GemmaIPCRequestBody
    ) async throws -> GemmaIPCResponseBody {
        do {
            let response = try await session.send(body)
            if case .failure(let failure) = response {
                throw Self.mappedRemoteFailure(failure.code)
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch GemmaClientControllerError.requestCancelled,
                GemmaClientControllerError.cancelledForRecording {
            throw CancellationError()
        } catch GemmaClientControllerError.remoteFailure(let code) {
            throw Self.mappedRemoteFailure(code)
        } catch let error as TextModelProviderError {
            throw error
        } catch let error as NativeGemmaTextModelProviderError {
            throw error
        } catch {
            throw NativeGemmaTextModelProviderError.helperUnavailable
        }
    }

    private static func mappedRemoteFailure(
        _ code: GemmaIPCErrorCode
    ) -> any Error {
        switch code {
        case .contextWindowExceeded:
            TextModelProviderError.contextWindowExceeded
        case .responseTruncated:
            TextModelProviderError.responseTruncated
        case .cancelled:
            CancellationError()
        case .invalidRequest, .requestTooLarge, .protocolMismatch,
             .modelUnavailable, .modelIntegrityFailure, .adapterMismatch,
             .unsupportedModel, .busy, .shuttingDown, .generationFailed,
             .internalFailure:
            NativeGemmaTextModelProviderError.helperUnavailable
        }
    }
}
#endif
