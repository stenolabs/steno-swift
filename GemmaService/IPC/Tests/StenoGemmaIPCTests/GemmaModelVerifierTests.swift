import CryptoKit
import Darwin
import Foundation
import Testing
@testable import StenoGemmaModelStore

@Suite("Installed Gemma model verifier")
struct GemmaModelVerifierTests {
    @Test("a pinned read-only snapshot verifies and remains bound to its inode")
    func completeSnapshotVerifiesAndRevalidates() throws {
        let fixture = try Fixture.make()

        let verified = try fixture.verifier.verify(directory: fixture.root)
        let root = try verified.revalidate()
        let expectedIdentity = try fixture.rootIdentity()

        #expect(root == fixture.root.standardizedFileURL)
        #expect(verified.modelIdentifier == Fixture.modelIdentifier)
        #expect(verified.rootIdentity == expectedIdentity)
    }

    @Test("manifest bytes, format, model identity, revisions, and license remain pinned")
    func manifestAndIdentityPinsAreEnforced() throws {
        let changedFixture = try Fixture.make()
        try changedFixture.replaceManifest(with: Data("{}".utf8))
        #expect(throws: GemmaModelVerificationError.manifestDigestMismatch(
            expected: changedFixture.manifestDigest,
            actual: Fixture.sha256(Data("{}".utf8))
        )) {
            _ = try changedFixture.verifier.verify(directory: changedFixture.root)
        }

        let requirements = try Fixture.requirements()
        let checksum = String(repeating: "0", count: 64)
        func manifest(
            formatVersion: Int = GemmaModelManifest.currentFormatVersion,
            modelIdentifier: String = Fixture.modelIdentifier,
            checkpointRevision: String = Fixture.checkpointRevision,
            adapterRevision: String = Fixture.adapterRevision,
            licenseIdentifier: String = Fixture.licenseIdentifier
        ) -> GemmaModelManifest {
            GemmaModelManifest(
                formatVersion: formatVersion,
                modelIdentifier: modelIdentifier,
                checkpointRevision: checkpointRevision,
                adapterRevision: adapterRevision,
                licenseIdentifier: licenseIdentifier,
                files: [.init(relativePath: "weights.bin", size: 1, sha256: checksum)]
            )
        }

        #expect(throws: GemmaModelVerificationError.unsupportedFormatVersion(
            expected: 1,
            actual: 99
        )) {
            try manifest(formatVersion: 99).validate(against: requirements)
        }
        #expect(throws: GemmaModelVerificationError.modelIdentifierMismatch(
            expected: Fixture.modelIdentifier,
            actual: "mlx-community/other-gemma"
        )) {
            try manifest(modelIdentifier: "mlx-community/other-gemma")
                .validate(against: requirements)
        }
        let otherRevision = String(repeating: "f", count: 40)
        #expect(throws: GemmaModelVerificationError.checkpointRevisionMismatch(
            expected: Fixture.checkpointRevision,
            actual: otherRevision
        )) {
            try manifest(checkpointRevision: otherRevision).validate(against: requirements)
        }
        #expect(throws: GemmaModelVerificationError.adapterRevisionMismatch(
            expected: Fixture.adapterRevision,
            actual: otherRevision
        )) {
            try manifest(adapterRevision: otherRevision).validate(against: requirements)
        }
        #expect(throws: GemmaModelVerificationError.emptyLicenseIdentifier) {
            try manifest(licenseIdentifier: "").validate(against: requirements)
        }
        #expect(throws: GemmaModelVerificationError.licenseIdentifierMismatch(
            expected: Fixture.licenseIdentifier,
            actual: "Apache-2.0"
        )) {
            try manifest(licenseIdentifier: "Apache-2.0").validate(against: requirements)
        }
    }

    @Test("an importer can bind verification to its retained destination identity")
    func expectedRootIdentityMustMatch() throws {
        let fixture = try Fixture.make()
        let identity = try fixture.rootIdentity()

        _ = try fixture.verifier.verify(
            directory: fixture.root,
            expectedRootIdentity: identity
        )

        #expect(throws: GemmaModelVerificationError.rootIdentityMismatch) {
            _ = try fixture.verifier.verify(
                directory: fixture.root,
                expectedRootIdentity: GemmaModelRootIdentity(
                    deviceID: identity.deviceID,
                    fileID: identity.fileID &+ 1
                )
            )
        }
    }

    @Test("requirements accept only pinned revisions and safe identifiers")
    func requirementsGrammarIsStrict() {
        #expect(throws: GemmaModelVerificationError.invalidRequirement(
            "checkpointRevision must be exactly 40 lowercase hexadecimal characters"
        )) {
            _ = try Fixture.requirements(checkpointRevision: "main")
        }
        #expect(throws: GemmaModelVerificationError.invalidRequirement(
            "adapterRevision must be exactly 40 lowercase hexadecimal characters"
        )) {
            _ = try Fixture.requirements(adapterRevision: String(repeating: "A", count: 40))
        }
        #expect(throws: GemmaModelVerificationError.invalidRequirement("modelIdentifier is unsafe")) {
            _ = try Fixture.requirements(modelIdentifier: "../gemma")
        }
        #expect(throws: GemmaModelVerificationError.invalidRequirement("licenseIdentifier is unsafe")) {
            _ = try Fixture.requirements(licenseIdentifier: "Gemma terms")
        }
    }

    @Test("paths are printable ASCII, non-hidden, and no deeper than eight components")
    func pathGrammarIsStrict() throws {
        for path in [
            ".hidden",
            "directory/.hidden",
            "directory/../weights.bin",
            "directory/gewichte-ä.bin",
            "a/b/c/d/e/f/g/h/i.bin",
        ] {
            #expect(throws: GemmaModelVerificationError.invalidRelativePath(path)) {
                try GemmaModelManifest.validateRelativePath(path)
            }
        }
        try GemmaModelManifest.validateRelativePath("a/b/c/d/e/f/g/h.bin")
    }

    @Test("case-folded and manifest-path collisions are rejected")
    func normalizedPathCollisionsAreRejected() throws {
        let requirements = try Fixture.requirements()
        let checksum = String(repeating: "0", count: 64)

        let caseCollision = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(relativePath: "Weights.bin", size: 1, sha256: checksum),
                .init(relativePath: "weights.bin", size: 1, sha256: checksum),
            ]
        )
        #expect(throws: GemmaModelVerificationError.pathCollision(
            first: "Weights.bin",
            second: "weights.bin"
        )) {
            try caseCollision.validate(against: requirements)
        }

        let manifestCollision = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(
                    relativePath: "Gemma-model-manifest.json",
                    size: 1,
                    sha256: checksum
                ),
            ]
        )
        #expect(throws: GemmaModelVerificationError.pathCollision(
            first: "gemma-model-manifest.json",
            second: "Gemma-model-manifest.json"
        )) {
            try manifestCollision.validate(against: requirements)
        }

        let nestedRequirements = try GemmaModelRequirements(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            manifestFileName: "metadata/manifest.json",
            expectedManifestSHA256: checksum
        )
        let parentCollision = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(relativePath: "Metadata/weights.bin", size: 1, sha256: checksum),
            ]
        )
        #expect(throws: GemmaModelVerificationError.pathCollision(
            first: "metadata",
            second: "Metadata"
        )) {
            try parentCollision.validate(against: nestedRequirements)
        }

        let manifestAsParent = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(
                    relativePath: "metadata/manifest.json/weights.bin",
                    size: 1,
                    sha256: checksum
                ),
            ]
        )
        #expect(throws: GemmaModelVerificationError.pathCollision(
            first: "metadata/manifest.json",
            second: "metadata/manifest.json/weights.bin"
        )) {
            try manifestAsParent.validate(against: nestedRequirements)
        }
    }

    @Test("a manifest cannot exceed 4096 model files")
    func fileCountIsBounded() throws {
        let requirements = try Fixture.requirements()
        let checksum = String(repeating: "0", count: 64)
        let files = (0 ... GemmaModelManifest.maximumFileCount).map { index in
            GemmaModelManifest.GemmaModelFile(
                relativePath: "weights-\(index).bin",
                size: 1,
                sha256: checksum
            )
        }
        let manifest = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: files
        )

        #expect(throws: GemmaModelVerificationError.tooManyFiles(
            limit: GemmaModelManifest.maximumFileCount,
            actual: GemmaModelManifest.maximumFileCount + 1
        )) {
            try manifest.validate(against: requirements)
        }
    }

    @Test("a manifest cannot require more than 64 directories")
    func directoryCountIsBounded() throws {
        let requirements = try Fixture.requirements()
        let checksum = String(repeating: "0", count: 64)
        let files = (0 ... GemmaModelManifest.maximumDirectoryCount).map { index in
            GemmaModelManifest.GemmaModelFile(
                relativePath: "directory-\(index)/weights.bin",
                size: 1,
                sha256: checksum
            )
        }
        let manifest = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: files
        )

        #expect(throws: GemmaModelVerificationError.tooManyDirectories(
            limit: GemmaModelManifest.maximumDirectoryCount,
            actual: GemmaModelManifest.maximumDirectoryCount + 1
        )) {
            try manifest.validate(against: requirements)
        }
    }

    @Test("the manifest cannot list its reserved filename and input is size bounded")
    func manifestPathAndSizeAreBounded() throws {
        let requirements = try Fixture.requirements()
        let manifest = GemmaModelManifest(
            modelIdentifier: Fixture.modelIdentifier,
            checkpointRevision: Fixture.checkpointRevision,
            adapterRevision: Fixture.adapterRevision,
            licenseIdentifier: Fixture.licenseIdentifier,
            files: [
                .init(
                    relativePath: "gemma-model-manifest.json",
                    size: 1,
                    sha256: String(repeating: "0", count: 64)
                ),
            ]
        )
        #expect(throws: GemmaModelVerificationError.manifestPathReserved(
            "gemma-model-manifest.json"
        )) {
            try manifest.validate(against: requirements)
        }

        let fixture = try Fixture.make()
        let oversized = Data(
            repeating: 0x20,
            count: GemmaModelManifest.maximumManifestByteCount + 1
        )
        try fixture.replaceManifest(with: oversized)
        #expect(throws: GemmaModelVerificationError.manifestTooLarge(
            limit: GemmaModelManifest.maximumManifestByteCount,
            actualAtLeast: GemmaModelManifest.maximumManifestByteCount + 1
        )) {
            _ = try fixture.verifier.verify(directory: fixture.root)
        }
    }

    @Test("root and files require exact read-only modes")
    func permissionsAreExact() throws {
        let rootFixture = try Fixture.make()
        try Fixture.chmod(rootFixture.root, 0o700)
        #expect(throws: GemmaModelVerificationError.unsafePermissions(
            path: ".",
            expected: 0o500,
            actual: 0o700
        )) {
            _ = try rootFixture.verifier.verify(directory: rootFixture.root)
        }

        let fileFixture = try Fixture.make()
        try Fixture.chmod(fileFixture.weightsURL, 0o600)
        #expect(throws: GemmaModelVerificationError.unsafePermissions(
            path: "weights.bin",
            expected: 0o400,
            actual: 0o600
        )) {
            _ = try fileFixture.verifier.verify(directory: fileFixture.root)
        }

        let directoryFixture = try Fixture.make(primaryPath: "weights/part.bin")
        let weightsDirectory = directoryFixture.root.appendingPathComponent(
            "weights",
            isDirectory: true
        )
        try Fixture.chmod(weightsDirectory, 0o700)
        #expect(throws: GemmaModelVerificationError.unsafePermissions(
            path: "weights",
            expected: 0o500,
            actual: 0o700
        )) {
            _ = try directoryFixture.verifier.verify(directory: directoryFixture.root)
        }
    }

    @Test("symbolic links and hard-linked files are rejected")
    func linksAreRejected() throws {
        let rootFixture = try Fixture.make()
        let alias = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: rootFixture.root)
        defer { try? FileManager.default.removeItem(at: alias) }
        #expect(throws: GemmaModelVerificationError.symbolicLinkNotAllowed(".")) {
            _ = try rootFixture.verifier.verify(directory: alias)
        }

        let symbolicFixture = try Fixture.make()
        try Fixture.chmod(symbolicFixture.root, 0o700)
        let linked = symbolicFixture.root.appendingPathComponent("linked.bin")
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: symbolicFixture.weightsURL
        )
        try Fixture.chmod(symbolicFixture.root, 0o500)
        #expect(throws: GemmaModelVerificationError.symbolicLinkNotAllowed("linked.bin")) {
            _ = try symbolicFixture.verifier.verify(directory: symbolicFixture.root)
        }

        let hardLinkFixture = try Fixture.make()
        try Fixture.chmod(hardLinkFixture.root, 0o700)
        let hardLinkAlias = hardLinkFixture.root.appendingPathComponent("alias.bin")
        guard Darwin.link(hardLinkFixture.weightsURL.path, hardLinkAlias.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try Fixture.chmod(hardLinkFixture.root, 0o500)
        do {
            _ = try hardLinkFixture.verifier.verify(directory: hardLinkFixture.root)
            Issue.record("Expected a hard-link rejection")
        } catch let error as GemmaModelVerificationError {
            guard case .hardLinkNotAllowed(let path) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(path == "weights.bin" || path == "alias.bin")
        }
    }

    @Test("size, hash, extra entries, and post-verification replacement fail closed")
    func treeChangesAreRejected() throws {
        let sizeFixture = try Fixture.make()
        try sizeFixture.replaceWeights(with: "changed length")
        #expect(throws: GemmaModelVerificationError.fileSizeMismatch(
            path: "weights.bin",
            expected: 7,
            actual: 14
        )) {
            _ = try sizeFixture.verifier.verify(directory: sizeFixture.root)
        }

        let hashFixture = try Fixture.make()
        let verified = try hashFixture.verifier.verify(directory: hashFixture.root)
        try hashFixture.replaceWeights(with: "payloae")
        #expect(throws: GemmaModelVerificationError.fileHashMismatch(
            path: "weights.bin",
            expected: Fixture.sha256(Data("payload".utf8)),
            actual: Fixture.sha256(Data("payloae".utf8))
        )) {
            _ = try verified.revalidate()
        }

        let extraFixture = try Fixture.make()
        try extraFixture.addReadOnlyFile(path: "extra.bin", contents: "extra")
        #expect(throws: GemmaModelVerificationError.unexpectedFile("extra.bin")) {
            _ = try extraFixture.verifier.verify(directory: extraFixture.root)
        }

        let missingFixture = try Fixture.make()
        try missingFixture.removeWeights()
        #expect(throws: GemmaModelVerificationError.missingFile("weights.bin")) {
            _ = try missingFixture.verifier.verify(directory: missingFixture.root)
        }
    }

    @Test("a safetensors index cannot escape or reference an unmanifested shard")
    func safetensorsIndexIsBoundToManifest() throws {
        let escaping = Data("{\"weight_map\":{\"layer\":\"../outside.safetensors\"}}".utf8)
        let escapingFixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["model.safetensors.index.json": escaping]
        )
        #expect(throws: GemmaModelVerificationError.unsafeSafetensorsIndexPath(
            "../outside.safetensors"
        )) {
            _ = try escapingFixture.verifier.verify(directory: escapingFixture.root)
        }

        let unlisted = Data("{\"weight_map\":{\"layer\":\"other.safetensors\"}}".utf8)
        let unlistedFixture = try Fixture.make(
            primaryPath: "model-00001-of-00001.safetensors",
            additionalFiles: ["model.safetensors.index.json": unlisted]
        )
        #expect(throws: GemmaModelVerificationError.unmanifestedSafetensorsFile(
            "other.safetensors"
        )) {
            _ = try unlistedFixture.verifier.verify(directory: unlistedFixture.root)
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

    private init(
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
        Self.makeWritableRecursively(root)
        try? FileManager.default.removeItem(at: root)
    }

    static func make(
        primaryPath: String = "weights.bin",
        additionalFiles: [String: Data] = [:]
    ) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let weightsURL = root.appendingPathComponent(primaryPath)
        let weights = Data("payload".utf8)
        try writeFile(weights, to: weightsURL)
        for (path, data) in additionalFiles {
            try writeFile(data, to: root.appendingPathComponent(path))
        }

        let manifest = GemmaModelManifest(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: [manifestFile(path: primaryPath, data: weights)]
                + additionalFiles.sorted(by: { $0.key < $1.key }).map {
                    manifestFile(path: $0.key, data: $0.value)
                }
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestURL = root.appendingPathComponent("gemma-model-manifest.json")
        try writeFile(manifestData, to: manifestURL)
        try freezeRecursively(root)

        let manifestDigest = sha256(manifestData)
        let requirements = try requirements(expectedManifestSHA256: manifestDigest)
        return Fixture(
            root: root,
            weightsURL: weightsURL,
            manifestURL: manifestURL,
            manifestDigest: manifestDigest,
            verifier: GemmaModelVerifier(requirements: requirements)
        )
    }

    static func requirements(
        modelIdentifier: String = modelIdentifier,
        checkpointRevision: String = checkpointRevision,
        adapterRevision: String = adapterRevision,
        licenseIdentifier: String = licenseIdentifier,
        expectedManifestSHA256: String = String(repeating: "0", count: 64)
    ) throws -> GemmaModelRequirements {
        try GemmaModelRequirements(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            expectedManifestSHA256: expectedManifestSHA256
        )
    }

    func rootIdentity() throws -> GemmaModelRootIdentity {
        var status = stat()
        guard Darwin.lstat(root.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return GemmaModelRootIdentity(
            deviceID: UInt64(status.st_dev),
            fileID: UInt64(status.st_ino)
        )
    }

    func replaceWeights(with contents: String) throws {
        try Self.chmod(weightsURL, 0o600)
        try Data(contents.utf8).write(to: weightsURL)
        try Self.chmod(weightsURL, 0o400)
    }

    func replaceManifest(with data: Data) throws {
        try Self.chmod(manifestURL, 0o600)
        try data.write(to: manifestURL)
        try Self.chmod(manifestURL, 0o400)
    }

    func removeWeights() throws {
        try Self.chmod(root, 0o700)
        try FileManager.default.removeItem(at: weightsURL)
        try Self.chmod(root, 0o500)
    }

    func addReadOnlyFile(path: String, contents: String) throws {
        try Self.chmod(root, 0o700)
        let url = root.appendingPathComponent(path)
        try Data(contents.utf8).write(to: url)
        try Self.chmod(url, 0o400)
        try Self.chmod(root, 0o500)
    }

    static func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func manifestFile(
        path: String,
        data: Data
    ) -> GemmaModelManifest.GemmaModelFile {
        .init(relativePath: path, size: Int64(data.count), sha256: sha256(data))
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private static func freezeRecursively(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        var directories: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CocoaError(.fileReadUnknown)
            }
            if isDirectory.boolValue {
                directories.append(url)
            } else {
                try chmod(url, 0o400)
            }
        }
        for directory in directories.reversed() {
            try chmod(directory, 0o500)
        }
        try chmod(root, 0o500)
    }

    private static func makeWritableRecursively(_ root: URL) {
        _ = Darwin.chmod(root.path, 0o700)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                _ = Darwin.chmod(url.path, isDirectory.boolValue ? 0o700 : 0o600)
            }
        }
    }
}
