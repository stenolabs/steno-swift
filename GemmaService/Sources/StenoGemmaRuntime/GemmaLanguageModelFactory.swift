import Foundation
import FoundationModels
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import StenoGemmaIPC
import StenoGemmaModelStore
import Tokenizers

public enum GemmaServiceBuildInfo {
    /// Compatibility alias for command-line self-check output.
    /// The IPC module owns the canonical service protocol version.
    public static let protocolVersion = GemmaIPCProtocol.currentVersion
    public static let adapterRevision = GemmaIPCBuildInfo.adapterRevision
}

public enum GemmaLanguageModelFactoryError: Error, Equatable, LocalizedError, Sendable {
    case adapterRevisionMismatch(expected: String, actual: String)
    case configurationMissing
    case configurationMalformed
    case unsupportedModelType(String)
    case localModelSourceChanged

    public var errorDescription: String? {
        switch self {
        case .adapterRevisionMismatch:
            "The verified model targets a different MLX Foundation Models adapter revision."
        case .configurationMissing:
            "The verified model does not contain config.json."
        case .configurationMalformed:
            "The verified model contains a malformed config.json."
        case .unsupportedModelType(let modelType):
            "The verified checkpoint uses the unsupported model type \(modelType)."
        case .localModelSourceChanged:
            "The local model source changed after verification."
        }
    }
}

/// Constructs the Foundation Models adapter only from a fully verified local Gemma 4 snapshot.
///
/// This factory contains no Hub identifier, downloader, cache lookup, or remote fallback.
/// Prototype-only path-backed loader.
///
/// Revalidation narrows accidental mutation races but does not freeze child files against another
/// same-user process between verification and MLX opens. The XPC provider must not activate this
/// factory until an immutable child-file activation boundary replaces the directory-URL handoff.
@available(macOS 27.0, *)
public enum GemmaLanguageModelFactory {
    public static func makeLanguageModel(
        from verifiedModel: VerifiedGemmaModel
    ) throws -> MLXLanguageModel {
        guard verifiedModel.adapterRevision == GemmaServiceBuildInfo.adapterRevision else {
            throw GemmaLanguageModelFactoryError.adapterRevisionMismatch(
                expected: GemmaServiceBuildInfo.adapterRevision,
                actual: verifiedModel.adapterRevision
            )
        }

        let root = try verifiedModel.revalidate()
        try validateGemmaConfiguration(at: root)
        let cacheIdentity = "steno-local/\(verifiedModel.manifestSHA256)"
        let configuration = ModelConfiguration(
            id: cacheIdentity,
            revision: verifiedModel.checkpointRevision
        )

        return MLXLanguageModel(
            configuration: configuration,
            capabilities: [.guidedGeneration],
            weightsLocation: { _ in root },
            load: { requestedConfiguration, _ in
                guard requestedConfiguration.id == configuration.id else {
                    throw GemmaLanguageModelFactoryError.localModelSourceChanged
                }

                let revalidatedRoot = try verifiedModel.revalidate()
                guard revalidatedRoot.standardizedFileURL == root.standardizedFileURL else {
                    throw GemmaLanguageModelFactoryError.localModelSourceChanged
                }
                try validateGemmaConfiguration(at: revalidatedRoot)

                return try await loadModelContainer(
                    from: revalidatedRoot,
                    using: #huggingFaceTokenizerLoader()
                )
            }
        )
    }

    private static func validateGemmaConfiguration(at root: URL) throws {
        let configurationURL = root.appendingPathComponent("config.json", isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: configurationURL, options: [.mappedIfSafe])
        } catch {
            throw GemmaLanguageModelFactoryError.configurationMissing
        }

        let configuration: BaseModelConfiguration
        do {
            configuration = try JSONDecoder().decode(BaseModelConfiguration.self, from: data)
        } catch {
            throw GemmaLanguageModelFactoryError.configurationMalformed
        }

        guard supportedModelTypes.contains(configuration.modelType) else {
            throw GemmaLanguageModelFactoryError.unsupportedModelType(configuration.modelType)
        }
    }

    private static let supportedModelTypes: Set<String> = [
        "gemma4",
        "gemma4_unified",
    ]

    private struct BaseModelConfiguration: Decodable {
        let modelType: String

        private enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
        }
    }
}
