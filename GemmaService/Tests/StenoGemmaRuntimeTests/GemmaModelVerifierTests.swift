import CryptoKit
import Foundation
import Testing
@testable import StenoGemmaRuntime

@Suite("Gemma model verifier")
struct GemmaModelVerifierTests {
    @Test("a complete pinned local snapshot verifies and revalidates")
    func completePinnedSnapshotVerifiesAndRevalidates() throws {
        let fixture = try Fixture.make()

        let verified = try fixture.verifier.verify(directory: fixture.root)
        let root = try verified.revalidate()

        #expect(root == fixture.root.standardizedFileURL)
        #expect(verified.modelIdentifier == Fixture.modelIdentifier)
    }

    @Test("the pinned manifest bytes reject a changed manifest")
    func changedManifestDigestIsRejected() throws {
        let fixture = try Fixture.make()
        try Fixture.write("{}", to: fixture.manifestURL)

        #expect(throws: GemmaModelVerificationError.manifestDigestMismatch(
            expected: fixture.manifestDigest,
            actual: Fixture.sha256(Data("{}".utf8))
        )) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("a manifest format version must match exactly")
    func unsupportedFormatVersionIsRejected() throws {
        let fixture = try Fixture.make(formatVersion: 99)

        #expect(throws: GemmaModelVerificationError.unsupportedFormatVersion(expected: 1, actual: 99)) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("model identity revisions must match the pinned requirements")
    func identityMismatchIsRejected() throws {
        let fixture = try Fixture.make(checkpointRevision: "different-revision")

        #expect(throws: GemmaModelVerificationError.checkpointRevisionMismatch(
            expected: Fixture.checkpointRevision,
            actual: "different-revision"
        )) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("a license identifier must be present and match the pinned requirements")
    func licenseIdentifierMustBePresentAndPinned() throws {
        let emptyFixture = try Fixture.make(licenseIdentifier: "")

        #expect(throws: GemmaModelVerificationError.emptyLicenseIdentifier) {
            _ = try emptyFixture.verifier.verify(directory: emptyFixture.root)
        }

        let mismatchedFixture = try Fixture.make(licenseIdentifier: "other-license")

        #expect(throws: GemmaModelVerificationError.licenseIdentifierMismatch(
            expected: Fixture.licenseIdentifier,
            actual: "other-license"
        )) {
            _ = try mismatchedFixture.verifier.verify(directory: mismatchedFixture.root)
        }

        #expect(throws: GemmaModelVerificationError.invalidRequirement(
            "licenseIdentifier must not be empty"
        )) {
            _ = try GemmaModelRequirements(
                modelIdentifier: Fixture.modelIdentifier,
                checkpointRevision: Fixture.checkpointRevision,
                adapterRevision: Fixture.adapterRevision,
                licenseIdentifier: "",
                expectedManifestSHA256: String(repeating: "0", count: 64)
            )
        }
    }

    @Test("model identifier and adapter revision must match the pinned requirements")
    func modelIdentifierAndAdapterRevisionMismatchAreRejected() throws {
        let modelFixture = try Fixture.make(modelIdentifier: "mlx-community/other-model")

        #expect(throws: GemmaModelVerificationError.modelIdentifierMismatch(
            expected: Fixture.modelIdentifier,
            actual: "mlx-community/other-model"
        )) {
            _ = try modelFixture.verifier.verify(directory: modelFixture.root)
        }

        let adapterFixture = try Fixture.make(adapterRevision: "different-adapter")

        #expect(throws: GemmaModelVerificationError.adapterRevisionMismatch(
            expected: Fixture.adapterRevision,
            actual: "different-adapter"
        )) {
            _ = try adapterFixture.verifier.verify(directory: adapterFixture.root)
        }
    }

    @Test("manifest paths must be plain relative paths")
    func unsafeRelativePathIsRejected() throws {
        let fixture = try Fixture.make(filePath: "../weights.bin")

        #expect(throws: GemmaModelVerificationError.invalidRelativePath("../weights.bin")) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("the manifest cannot list its own reserved filename")
    func manifestFileNameIsReserved() throws {
        let fixture = try Fixture.make(filePath: "gemma-model-manifest.json")

        #expect(throws: GemmaModelVerificationError.manifestPathReserved("gemma-model-manifest.json")) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("manifest input is capped before decoding")
    func oversizedManifestIsRejected() throws {
        let fixture = try Fixture.make()
        let oversizedData = Data(repeating: 0x20, count: GemmaModelManifest.maximumManifestByteCount + 1)
        try oversizedData.write(to: fixture.manifestURL)

        #expect(throws: GemmaModelVerificationError.manifestTooLarge(
            limit: GemmaModelManifest.maximumManifestByteCount,
            actualAtLeast: GemmaModelManifest.maximumManifestByteCount + 1
        )) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("symbolic links are rejected")
    func symbolicLinkIsRejected() throws {
        let fixture = try Fixture.make()
        let linked = fixture.root.appendingPathComponent("linked.bin")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.weightsURL)

        #expect(throws: GemmaModelVerificationError.symbolicLinkNotAllowed("linked.bin")) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("a manifest cannot omit an installed file")
    func extraFileIsRejected() throws {
        let fixture = try Fixture.make()
        try Fixture.write("extra", to: fixture.root.appendingPathComponent("extra.bin"))

        #expect(throws: GemmaModelVerificationError.unexpectedFile("extra.bin")) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("a safetensors index cannot escape the verified snapshot")
    func safetensorsIndexCannotEscapeSnapshot() throws {
        let index = Data("{\"weight_map\":{\"layer\":\"../outside.safetensors\"}}".utf8)
        let fixture = try Fixture.make(
            filePath: "model-00001-of-00001.safetensors",
            actualFilePath: "model-00001-of-00001.safetensors",
            additionalFiles: ["model.safetensors.index.json": index]
        )

        #expect(throws: GemmaModelVerificationError.unsafeSafetensorsIndexPath(
            "../outside.safetensors"
        )) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("a safetensors index can reference only manifested shards")
    func safetensorsIndexRequiresManifestedShards() throws {
        let index = Data("{\"weight_map\":{\"layer\":\"other.safetensors\"}}".utf8)
        let fixture = try Fixture.make(
            filePath: "model-00001-of-00001.safetensors",
            actualFilePath: "model-00001-of-00001.safetensors",
            additionalFiles: ["model.safetensors.index.json": index]
        )

        #expect(throws: GemmaModelVerificationError.unmanifestedSafetensorsFile(
            "other.safetensors"
        )) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("a listed file must be present")
    func missingFileIsRejected() throws {
        let fixture = try Fixture.make()
        try FileManager.default.removeItem(at: fixture.weightsURL)

        #expect(throws: GemmaModelVerificationError.missingFile("weights.bin")) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("a listed file must preserve its size and checksum")
    func changedFileIsRejectedBySizeThenHash() throws {
        let sizeFixture = try Fixture.make()
        try Fixture.write("changed length", to: sizeFixture.weightsURL)

        #expect(throws: GemmaModelVerificationError.fileSizeMismatch(
            path: "weights.bin",
            expected: 7,
            actual: 14
        )) {
            _ = try sizeFixture.verifier.verify(directory: sizeFixture.root)
        }

        let hashFixture = try Fixture.make()
        try Fixture.write("payloae", to: hashFixture.weightsURL)

        #expect(throws: GemmaModelVerificationError.fileHashMismatch(
            path: "weights.bin",
            expected: Fixture.sha256(Data("payload".utf8)),
            actual: Fixture.sha256(Data("payloae".utf8))
        )) {
            _ = try hashFixture.verifier.verify(directory: hashFixture.root)
        }
    }

    @Test("revalidation rejects a snapshot changed after initial verification")
    func revalidationRejectsPostVerificationTampering() throws {
        let fixture = try Fixture.make()
        let verified = try fixture.verifier.verify(directory: fixture.root)
        try Fixture.write("payloae", to: fixture.weightsURL)

        #expect(throws: GemmaModelVerificationError.fileHashMismatch(
            path: "weights.bin",
            expected: Fixture.sha256(Data("payload".utf8)),
            actual: Fixture.sha256(Data("payloae".utf8))
        )) {
            _ = try verified.revalidate()
        }
    }
}

private final class Fixture {
    static let modelIdentifier = "mlx-community/gemma-4-2b-it-4bit"
    static let checkpointRevision = "0123456789abcdef0123456789abcdef01234567"
    static let adapterRevision = "37688d2cf7d3906e08c74479c9d9949ce6b81136"
    static let licenseIdentifier = "Gemma"

    let root: URL
    let weightsURL: URL
    let manifestURL: URL
    let manifestDigest: String
    let verifier: GemmaModelVerifier

    init(
        root: URL,
        weightsURL: URL,
        manifestURL: URL,
        manifestDigest: String,
        verifier: GemmaModelVerifier
    ) {
        self.root = root
        self.weightsURL = weightsURL
        self.manifestURL = manifestURL
        self.manifestDigest = manifestDigest
        self.verifier = verifier
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    static func make(
        formatVersion: Int = GemmaModelManifest.currentFormatVersion,
        modelIdentifier: String = Fixture.modelIdentifier,
        checkpointRevision: String = Fixture.checkpointRevision,
        adapterRevision: String = Fixture.adapterRevision,
        licenseIdentifier: String = Fixture.licenseIdentifier,
        filePath: String = "weights.bin",
        actualFilePath: String = "weights.bin",
        additionalFiles: [String: Data] = [:]
    ) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let weightsURL = root.appendingPathComponent(actualFilePath)
        try write("payload", to: weightsURL)

        for (path, data) in additionalFiles {
            try data.write(to: root.appendingPathComponent(path))
        }

        let manifest = GemmaModelManifest(
            formatVersion: formatVersion,
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: [
                .init(
                    relativePath: filePath,
                    size: 7,
                    sha256: sha256(Data("payload".utf8))
                ),
            ] + additionalFiles.sorted(by: { $0.key < $1.key }).map { path, data in
                .init(
                    relativePath: path,
                    size: Int64(data.count),
                    sha256: sha256(data)
                )
            }
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestURL = root.appendingPathComponent("gemma-model-manifest.json")
        try manifestData.write(to: manifestURL)
        let manifestDigest = sha256(manifestData)
        let requirements = try GemmaModelRequirements(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            expectedManifestSHA256: manifestDigest
        )

        return Fixture(
            root: root,
            weightsURL: weightsURL,
            manifestURL: manifestURL,
            manifestDigest: manifestDigest,
            verifier: GemmaModelVerifier(requirements: requirements)
        )
    }

    static func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
