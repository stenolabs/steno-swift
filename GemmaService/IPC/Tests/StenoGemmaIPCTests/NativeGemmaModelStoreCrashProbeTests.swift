import Darwin
import Foundation
import Testing
@_spi(StenoApp) @_spi(StenoTesting) import StenoGemmaModelStore

@Suite("Native Gemma model-store crash probe", .serialized)
struct NativeGemmaModelStoreCrashProbeTests {
    @Test("SIGKILL before publication removes the prepared transaction")
    func sigkillAtPreparedPayloadRecoversStaging() async throws {
        let report = try await crashAndRecover(at: .preparedPayload)

        #expect(report.recoveredStagingCount == 1)
        #expect(report.synchronizedPublishedTargetCount == 0)
        #expect(report.issues.isEmpty)
    }

    @Test("SIGKILL after publication retains and synchronizes the target")
    func sigkillAfterNamespaceRenameRecoversPublication() async throws {
        let report = try await crashAndRecover(at: .namespaceRenamed)

        #expect(report.recoveredStagingCount == 0)
        #expect(report.synchronizedPublishedTargetCount == 1)
        #expect(report.issues.isEmpty)
    }
}

private enum ModelStoreProbePausePoint: String {
    case preparedPayload = "prepared-payload"
    case namespaceRenamed = "namespace-renamed"

    var expectedPublishedTargetCount: Int {
        switch self {
        case .preparedPayload:
            0
        case .namespaceRenamed:
            1
        }
    }
}

private func crashAndRecover(
    at pausePoint: ModelStoreProbePausePoint
) async throws -> NativeGemmaModelStoreRecoveryReport {
    let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "steno-gemma-model-store-crash-probe-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: baseURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer {
        makeTreeWritable(baseURL)
        try? FileManager.default.removeItem(at: baseURL)
    }

    let process = try launchModelStoreProbe(pausePoint: pausePoint, baseURL: baseURL)
    defer {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
    try expectModelStoreProbeReady(process)
    #expect(process.isRunning)
    #expect(Darwin.kill(process.processIdentifier, SIGKILL) == 0)
    process.waitUntilExit()

    let storeURL = baseURL.appendingPathComponent("Store", isDirectory: true)
    let recovery = NativeGemmaModelStoreRecovery(
        configuration: try NativeGemmaModelStoreConfiguration(testRootDirectory: storeURL)
    )
    let report = try await recovery.recoverInterruptedImports()
    let storeEntries = try modelStoreEntries(in: storeURL)
    #expect(!storeEntries.contains(where: { $0.hasPrefix(".native-gemma-import-v2-") }))
    #expect(publishedTargetNames(in: storeEntries).count == pausePoint.expectedPublishedTargetCount)
    return report
}

private func launchModelStoreProbe(
    pausePoint: ModelStoreProbePausePoint,
    baseURL: URL
) throws -> Process {
    let process = Process()
    let packageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildDirectory = packageURL.appendingPathComponent(".build/out", isDirectory: true)
    let platformProbeURLs = (try? FileManager.default.contentsOfDirectory(
        at: buildDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ))?.filter {
        $0.lastPathComponent.hasSuffix("-apple-macosx")
    }.map {
        $0.appendingPathComponent("debug/steno-gemma-model-store-probe")
    } ?? []
    let swiftPMProbeURL = buildDirectory
        .appendingPathComponent("Products/Debug/steno-gemma-model-store-probe")
    let bundleProbeURL = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("steno-gemma-model-store-probe")
    guard let probeURL = (platformProbeURLs + [bundleProbeURL, swiftPMProbeURL]).first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }) else {
        throw NativeGemmaModelStoreRecoveryError.unsafeStore
    }
    process.executableURL = probeURL
    process.arguments = [pausePoint.rawValue, baseURL.path]
    process.standardInput = Pipe()
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
}

private func expectModelStoreProbeReady(_ process: Process) throws {
    guard let output = process.standardOutput as? Pipe,
          output.fileHandleForReading.availableData == Data("ready\n".utf8) else {
        throw NativeGemmaModelStoreRecoveryError.unsafeStore
    }
}

private func modelStoreEntries(in storeURL: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        atPath: storeURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .path
    ).sorted()
}

private func publishedTargetNames(in entries: [String]) -> [String] {
    entries.filter {
        !$0.hasPrefix(".") && $0.utf8.count == 64 && $0.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

private func makeTreeWritable(_ rootURL: URL) {
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: []
    ) else { return }
    var directories = [rootURL]
    while let url = enumerator.nextObject() as? URL {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else { continue }
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            directories.append(url)
            _ = Darwin.chmod(url.path, mode_t(0o700))
        case S_IFREG:
            _ = Darwin.chmod(url.path, mode_t(0o600))
        default:
            break
        }
    }
    for directory in directories {
        _ = Darwin.chmod(directory.path, mode_t(0o700))
    }
}
