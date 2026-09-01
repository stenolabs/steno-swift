import Foundation
import FoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import StenoGemmaModelStore
import StenoGemmaRuntime
import StenoMLXFoundationModels
import Tokenizers

/// Command-line-only path-backed adapter construction.
///
/// This target is intentionally absent from the XPC helper dependency graph.
@available(macOS 27.0, *)
extension GemmaLanguageModelFactory {
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
        try validatePrototypeGemmaConfiguration(at: root)
        let configuration = ModelConfiguration(
            id: "steno-local/\(verifiedModel.manifestSHA256)",
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
                try validatePrototypeGemmaConfiguration(at: revalidatedRoot)

                return try await loadModelContainer(
                    from: revalidatedRoot,
                    using: #huggingFaceTokenizerLoader()
                )
            }
        )
    }

    private static func validatePrototypeGemmaConfiguration(at root: URL) throws {
        let configurationURL = root.appendingPathComponent("config.json", isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: configurationURL, options: [.mappedIfSafe])
        } catch {
            throw GemmaLanguageModelFactoryError.configurationMissing
        }

        let configuration: PrototypeBaseModelConfiguration
        do {
            configuration = try JSONDecoder().decode(
                PrototypeBaseModelConfiguration.self,
                from: data
            )
        } catch {
            throw GemmaLanguageModelFactoryError.configurationMalformed
        }

        guard configuration.modelType == "gemma4" else {
            throw GemmaLanguageModelFactoryError.unsupportedModelType(
                configuration.modelType
            )
        }
    }
}

private struct PrototypeBaseModelConfiguration: Decodable {
    let modelType: String

    private enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
    }
}
