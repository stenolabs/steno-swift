import CryptoKit
import Darwin
import Foundation
@_spi(StenoApp) @_spi(StenoTesting) import StenoGemmaModelStore

/// UI-less crash probe for the Native Gemma model-store recovery transaction.
///
/// The probe creates a synthetic one-byte source and pauses only after the selected durable
/// checkpoint. Its parent owns the input pipe and terminates it with SIGKILL, so no timing sleep
/// is needed to model a process crash.
@main
struct StenoGemmaModelStoreProbe {
    private enum PausePoint: String, Sendable {
        case preparedPayload = "prepared-payload"
        case namespaceRenamed = "namespace-renamed"
    }

    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              let pausePoint = PausePoint(rawValue: arguments[1]) else {
            fputs(
                "usage: steno-gemma-model-store-probe <prepared-payload|namespace-renamed> <base-directory>\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }

        do {
            let baseURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
                .standardizedFileURL
            let fixture = try Fixture.make(in: baseURL)
            let configuration = try NativeGemmaModelStoreConfiguration(
                testRootDirectory: fixture.storeURL
            )
            let importer = NativeGemmaModelImporter(configuration: configuration) { checkpoint in
                switch (pausePoint, checkpoint) {
                case (.preparedPayload, .stagingPrepared),
                    (.namespaceRenamed, .namespaceCommitted):
                    FileHandle.standardOutput.write(Data("ready\n".utf8))
                    _ = readLine()
                default:
                    break
                }
            }
            _ = try await importer.importModel(
                from: fixture.sourceURL,
                expectedSourceIdentity: fixture.sourceIdentity,
                requirements: fixture.requirements
            )
            fputs("model-store probe completed before its crash checkpoint\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("model-store probe failed before its crash checkpoint\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

private struct Fixture {
    private static let modelIdentifier = "steno-test/tiny"
    private static let checkpointRevision = "0123456789abcdef0123456789abcdef01234567"
    private static let adapterRevision = "37688d2cf7d3906e08c74479c9d9949ce6b81136"
    private static let licenseIdentifier = "Gemma"
    private static let manifestFileName = "gemma-model-manifest.json"
    private static let weightsPath = "weights/tiny.bin"
    private static let weightsData = Data([0x47])

    let sourceURL: URL
    let storeURL: URL
    let sourceIdentity: GemmaModelSourceIdentity
    let requirements: GemmaModelRequirements

    static func make(in baseURL: URL) throws -> Self {
        let sourceURL = baseURL.appendingPathComponent("Source", isDirectory: true)
        let storeURL = baseURL.appendingPathComponent("Store", isDirectory: true)
        let weightsURL = sourceURL.appendingPathComponent(weightsPath)
        try FileManager.default.createDirectory(
            at: weightsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try weightsData.write(to: weightsURL)

        let manifest = GemmaModelManifest(
            modelIdentifier: modelIdentifier,
            checkpointRevision: checkpointRevision,
            adapterRevision: adapterRevision,
            licenseIdentifier: licenseIdentifier,
            files: [
                .init(
                    relativePath: weightsPath,
                    size: Int64(weightsData.count),
                    sha256: sha256(weightsData)
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: sourceURL.appendingPathComponent(manifestFileName))

        return try Self(
            sourceURL: sourceURL,
            storeURL: storeURL,
            sourceIdentity: sourceIdentity(of: sourceURL),
            requirements: GemmaModelRequirements(
                modelIdentifier: modelIdentifier,
                checkpointRevision: checkpointRevision,
                adapterRevision: adapterRevision,
                licenseIdentifier: licenseIdentifier,
                expectedManifestSHA256: sha256(manifestData)
            )
        )
    }

    private static func sourceIdentity(of sourceURL: URL) throws -> GemmaModelSourceIdentity {
        let descriptor = sourceURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ProbeError.failed }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw ProbeError.failed }
        return GemmaModelSourceIdentity(
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum ProbeError: Error {
        case failed
    }
}
