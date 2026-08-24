@preconcurrency import CoreML
import FluidAudio
import Foundation
import StenoDomain

/// Loads the explicitly installed Parakeet bundle without giving FluidAudio
/// an opportunity to repair or download files during inference.
enum LocalParakeetModelLoader {
    static func load(from directory: URL) async throws -> AsrModels {
        let manifest = try ParakeetModelInstaller.bundledManifest()
        try manifest.verify(directory: directory)

        let configuration = AsrModels.defaultConfiguration()
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly
        preprocessorConfiguration.allowLowPrecisionAccumulationOnGPU = true

        let preprocessor = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(ModelNames.ASR.preprocessorFile),
            configuration: preprocessorConfiguration
        )
        let encoder = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(
                ParakeetEncoderPrecision.int8.encoderFileName
            ),
            configuration: configuration
        )
        let decoder = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(ModelNames.ASR.decoderFile),
            configuration: configuration
        )
        let joint = try await MLModel.load(
            contentsOf: directory.appendingPathComponent(ModelNames.ASR.jointV3File),
            configuration: configuration
        )

        return AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: try vocabulary(from: directory),
            version: .v3
        )
    }

    static func vocabulary(from directory: URL) throws -> [Int: String] {
        let url = directory.appendingPathComponent("parakeet_v3_vocab.json")
        let encoded = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: url)
        )
        var vocabulary: [Int: String] = [:]
        vocabulary.reserveCapacity(encoded.count)
        for (key, value) in encoded {
            guard let tokenID = Int(key) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            vocabulary[tokenID] = value
        }
        return vocabulary
    }
}
