import CryptoKit
import Darwin
import Foundation
import StenoGemmaModelStore
import Testing
@testable import StenoGemmaRuntime

@Suite("Gemma language model factory")
struct GemmaLanguageModelFactoryTests {
    @Test("a verified Gemma 4 directory constructs the Foundation Models adapter without loading")
    func verifiedGemmaDirectoryConstructsAdapter() throws {
        let fixture = try FactoryFixture.make(modelType: "gemma4")
        let verified = try fixture.verifiedModel()

        let model = try GemmaLanguageModelFactory.makePrototypePathBackedLanguageModel(
            from: verified
        )

        #expect(model.modelID == "steno-local/\(fixture.manifestDigest)")
    }

    @Test("a non-Gemma model type is rejected before MLX loading")
    func nonGemmaModelTypeIsRejected() throws {
        let fixture = try FactoryFixture.make(modelType: "qwen3")
        let verified = try fixture.verifiedModel()

        #expect(throws: GemmaLanguageModelFactoryError.unsupportedModelType("qwen3")) {
            _ = try GemmaLanguageModelFactory.makePrototypePathBackedLanguageModel(from: verified)
        }
    }

    @Test("a missing model configuration is rejected before MLX loading")
    func missingConfigurationIsRejected() throws {
        let fixture = try FactoryFixture.make(modelType: nil)
        let verified = try fixture.verifiedModel()

        #expect(throws: GemmaLanguageModelFactoryError.configurationMissing) {
            _ = try GemmaLanguageModelFactory.makePrototypePathBackedLanguageModel(from: verified)
        }
    }

    @Test("the verified adapter revision must equal the compiled dependency revision")
    func adapterRevisionMustMatchCompiledDependency() throws {
        let fixture = try FactoryFixture.make(
            modelType: "gemma4",
            adapterRevision: "0000000000000000000000000000000000000000"
        )
        let verified = try fixture.verifiedModel()

        #expect(throws: GemmaLanguageModelFactoryError.adapterRevisionMismatch(
            expected: GemmaServiceBuildInfo.adapterRevision,
            actual: "0000000000000000000000000000000000000000"
        )) {
            _ = try GemmaLanguageModelFactory.makePrototypePathBackedLanguageModel(from: verified)
        }
    }
}

private final class FactoryFixture {
    private static let modelIdentifier = "test/gemma-4-e4b-it-4bit"
    private static let checkpointRevision = "1111111111111111111111111111111111111111"
    private static let licenseIdentifier = "Apache-2.0"

    let root: URL
    let adapterRevision: String
    let manifestDigest: String

    private init(root: URL, adapterRevision: String, manifestDigest: String) {
        self.root = root
        self.adapterRevision = adapterRevision
        self.manifestDigest = manifestDigest
    }

    deinit {
        _ = Darwin.chmod(root.path, 0o700)
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    _ = Darwin.chmod(url.path, isDirectory.boolValue ? 0o700 : 0o600)
                }
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    static func make(
        modelType: String?,
        adapterRevision: String = GemmaServiceBuildInfo.adapterRevision
    ) throws -> FactoryFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var files: [GemmaModelManifest.GemmaModelFile] = []
        if let modelType {
            let configuration = Data("{\"model_type\":\"\(modelType)\"}".utf8)
            let configurationURL = root.appendingPathComponent("config.json")
            try configuration.write(to: configurationURL)
            files.append(manifestFile(path: "config.json", data: configuration))
        }

        let weights = Data("synthetic weights".utf8)
        try weights.write(to: root.appendingPathComponent("model.safetensors"))
        files.append(manifestFile(path: "model.safetensors", data: weights))

        let manifest = GemmaModelManifest(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: files
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(
            to: root.appendingPathComponent("gemma-model-manifest.json")
        )
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  Darwin.chmod(url.path, isDirectory.boolValue ? 0o500 : 0o400) == 0
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard Darwin.chmod(root.path, 0o500) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        return FactoryFixture(
            root: root,
            adapterRevision: adapterRevision,
            manifestDigest: sha256(manifestData)
        )
    }

    func verifiedModel() throws -> VerifiedGemmaModel {
        let requirements = try GemmaModelRequirements(
            modelIdentifier: Self.modelIdentifier,
            checkpointRevision: Self.checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: Self.licenseIdentifier,
            expectedManifestSHA256: manifestDigest
        )
        return try GemmaModelVerifier(requirements: requirements).verify(directory: root)
    }

    private static func manifestFile(
        path: String,
        data: Data
    ) -> GemmaModelManifest.GemmaModelFile {
        GemmaModelManifest.GemmaModelFile(
            relativePath: path,
            size: Int64(data.count),
            sha256: sha256(data)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
