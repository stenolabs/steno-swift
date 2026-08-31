import Foundation
import FoundationModels
import MLXLMCommon
import StenoGemmaServiceCore
@_spi(StenoGemmaRuntime) import StenoGemmaIPC
@_spi(StenoGemmaRuntime) import StenoGemmaModelStore

@_spi(StenoGemmaRuntime)
public enum NativeGemmaExecutorFactoryError: Error, Equatable, Sendable {
    case activationProvenanceMismatch
}

/// Builds the only executable model capability published by the native helper.
@available(macOS 27.0, *)
@_spi(StenoGemmaRuntime)
public enum NativeGemmaExecutorFactory {
    public static func makeBoundExecutor(
        consuming activationAssets: VerifiedGemmaModelActivationAssets,
        profile: NativeGemmaActivationProfile,
        cancellationCheck: @escaping @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws -> GemmaBoundModelExecutor {
        guard activationAssets.modelIdentifier == profile.pin.modelIdentifier,
              activationAssets.checkpointRevision == profile.pin.checkpointRevision,
              activationAssets.adapterRevision == profile.pin.adapterRevision,
              activationAssets.licenseIdentifier == profile.pin.licenseIdentifier,
              activationAssets.manifestSHA256 == profile.pin.manifestSHA256
        else {
            activationAssets.close()
            throw NativeGemmaExecutorFactoryError.activationProvenanceMismatch
        }

        let activated = try GemmaLanguageModelFactory.makeActivatedLanguageModel(
            consuming: activationAssets,
            modelLayout: profile.modelLayout,
            cancellationCheck: cancellationCheck
        )
        let executor = NativeGemmaModelExecutor(
            activatedModel: activated,
            maximumPromptTokens: profile.maximumPromptTokens
        )
        return GemmaBoundModelExecutor(model: profile.pin, executor: executor)
    }
}

@available(macOS 27.0, *)
actor NativeGemmaModelExecutor: GemmaModelExecuting {
    typealias TokenCounter = @Sendable (String) async throws -> Int
    typealias Generator = @Sendable (String, Int) async throws -> String

    static let responseCompletionMarker =
        "<|STENO_RESPONSE_COMPLETE_7F42D6B1|>"

    private let maximumPromptTokens: Int
    private let countPreparedTokens: TokenCounter
    private let generateResponse: Generator

    init(
        activatedModel: ActivatedGemmaLanguageModel,
        maximumPromptTokens: Int
    ) {
        let processor = activatedModel.processor
        let languageModel = activatedModel.languageModel
        self.maximumPromptTokens = maximumPromptTokens
        countPreparedTokens = { text in
            try Task.checkCancellation()
            let input = try await processor.prepare(input: UserInput(prompt: text))
            try Task.checkCancellation()
            return input.text.tokens.size
        }
        generateResponse = { prompt, maximumTokens in
            try Task.checkCancellation()
            let session = LanguageModelSession(
                model: languageModel,
                tools: [],
                instructions: Optional<Instructions>.none
            )
            let response = try await session.respond(
                to: Prompt(prompt),
                options: GenerationOptions(maximumResponseTokens: maximumTokens)
            )
            try Task.checkCancellation()
            return response.content
        }
    }

    init(
        maximumPromptTokens: Int,
        countPreparedTokens: @escaping TokenCounter,
        generateResponse: @escaping Generator
    ) {
        self.maximumPromptTokens = maximumPromptTokens
        self.countPreparedTokens = countPreparedTokens
        self.generateResponse = generateResponse
    }

    func countTokens(in text: String) async throws -> Int {
        try Task.checkCancellation()
        let count = try await countPreparedTokens(Self.completionMarkedPrompt(text))
        try Task.checkCancellation()
        guard count >= 0 else {
            throw GemmaModelExecutionError.internalFailure
        }
        return count
    }

    func generate(prompt: String, maximumTokens: Int) async throws -> String {
        let promptTokens = try await countTokens(in: prompt)
        guard promptTokens <= maximumPromptTokens else {
            throw GemmaModelExecutionError.contextWindowExceeded
        }
        do {
            let response = try await generateResponse(
                Self.completionMarkedPrompt(prompt),
                maximumTokens
            )
            guard let completed = Self.completedResponse(from: response) else {
                throw GemmaModelExecutionError.responseTruncated
            }
            return completed
        } catch {
            throw Self.mapGenerationError(error)
        }
    }

    static func completionMarkedPrompt(_ prompt: String) -> String {
        """
        \(prompt)

        Completion protocol:
        After the complete JSON object, append this exact marker on a new line:
        \(responseCompletionMarker)
        Do not emit the marker until the JSON object is complete.
        Do not emit any text after the marker.
        """
    }

    static func completedResponse(from response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(responseCompletionMarker) else { return nil }
        let markerStart = trimmed.index(
            trimmed.endIndex,
            offsetBy: -responseCompletionMarker.count
        )
        return String(trimmed[..<markerStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mapGenerationError(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled {
            return GemmaModelExecutionError.cancelled
        }
        if let executionError = error as? GemmaModelExecutionError {
            return executionError
        }
        if let modelError = error as? LanguageModelError,
           case .contextSizeExceeded = modelError
        {
            return GemmaModelExecutionError.contextWindowExceeded
        }
        return GemmaModelExecutionError.generationFailed
    }
}
