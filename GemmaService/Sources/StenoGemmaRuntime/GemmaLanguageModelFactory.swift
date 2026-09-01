import Foundation
import FoundationModels
import StenoMLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
@_spi(StenoGemmaRuntime) import StenoGemmaIPC
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
    case requiredActivationFileMissing(String)
    case malformedActivationFile(String)
    case unsupportedMediaConfiguration(String)
    case unsafeModelConfiguration(String)
    case tokenizerClassMissing
    case chatTemplateMissing
    case chatTemplateApplicationFailed
    case safetensorsIndexRequired
    case safetensorsIndexMismatch
    case safetensorsTensorMismatch(path: String, tensor: String)
    case modelWeightSetMismatch(missing: Int, unexpected: Int)
    case modelParameterDTypeMismatch(parameter: String, dtype: String)
    case unsupportedSafetensorsDType(path: String, tensor: String, dtype: String)
    case mediaWeightRejected(String)
    case mediaInputRejected
    case sanitizerTensorShapeMismatch(String)
    case sanitizedWeightNameCollision(String)
    case inconsistentSafetensorsMetadata(String)

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
        case .requiredActivationFileMissing(let path):
            "The verified activation is missing the required file \(path)."
        case .malformedActivationFile(let path):
            "The verified activation contains malformed data in \(path)."
        case .unsupportedMediaConfiguration(let key):
            "The verified checkpoint declares unsupported media configuration \(key)."
        case .unsafeModelConfiguration(let reason):
            "The verified checkpoint has an unsafe Gemma configuration: \(reason)."
        case .tokenizerClassMissing:
            "The verified tokenizer_config.json does not declare tokenizer_class."
        case .chatTemplateMissing:
            "The verified tokenizer does not contain a usable chat template."
        case .chatTemplateApplicationFailed:
            "The verified tokenizer could not apply its chat template."
        case .safetensorsIndexRequired:
            "A multi-shard checkpoint requires model.safetensors.index.json."
        case .safetensorsIndexMismatch:
            "The Safetensors index does not exactly describe the verified shards."
        case .safetensorsTensorMismatch(let path, let tensor):
            "MLX decoded tensor \(tensor) differently from the verified parser in \(path)."
        case .modelWeightSetMismatch(let missing, let unexpected):
            "The verified checkpoint does not exactly match the Gemma model parameter set "
                + "(missing: \(missing), unexpected: \(unexpected))."
        case .modelParameterDTypeMismatch(let parameter, let dtype):
            "Parameter \(parameter) uses the unsafe checkpoint dtype \(dtype)."
        case .unsupportedSafetensorsDType(let path, let tensor, let dtype):
            "Tensor \(tensor) in \(path) uses unsupported dtype \(dtype)."
        case .mediaWeightRejected(let name):
            "The text-only Gemma loader rejected media weight \(name)."
        case .mediaInputRejected:
            "The text-only Gemma loader rejected media input."
        case .sanitizerTensorShapeMismatch(let parameter):
            "Parameter \(parameter) has a shape unsafe for Gemma weight sanitization."
        case .sanitizedWeightNameCollision(let name):
            "Gemma weight sanitization would collide at \(name)."
        case .inconsistentSafetensorsMetadata(let path):
            "Safetensors metadata in \(path) differs from an earlier shard."
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
    package static func makePrototypePathBackedLanguageModel(
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

    private static let supportedModelTypes: Set<String> = ["gemma4"]

    private struct BaseModelConfiguration: Decodable {
        let modelType: String

        private enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
        }
    }
}
