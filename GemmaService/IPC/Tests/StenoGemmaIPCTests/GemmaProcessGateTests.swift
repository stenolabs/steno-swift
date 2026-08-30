import Darwin
import Foundation
import StenoGemmaProcessGate
import Testing

@Suite("Native Gemma process gate")
struct GemmaProcessGateTests {
    @Test("a model lease excludes recording until its descriptor closes")
    func modelExcludesRecording() async throws {
        try await withGate { gate in
            let clock = ContinuousClock()
            let model = try gate.acquireModelExecution()
            await #expect(throws: GemmaProcessGateError.timedOut) {
                _ = try await gate.acquireRecordingLease(
                    until: clock.now.advanced(by: .milliseconds(40))
                )
            }
            model.close()
            let recording = try await gate.acquireRecordingLease(
                until: clock.now.advanced(by: .seconds(1))
            )
            recording.close()
        }
    }

    @Test("recording leases are compatible with each other and exclude model admission")
    func recordingsAreCompatibleAndExcludeModel() async throws {
        try await withGate { gate in
            let clock = ContinuousClock()
            let first = try await gate.acquireRecordingLease(
                until: clock.now.advanced(by: .seconds(1))
            )
            let second = try await gate.acquireRecordingLease(
                until: clock.now.advanced(by: .seconds(1))
            )
            #expect(throws: GemmaProcessGateError.busy) {
                _ = try gate.acquireModelExecution()
            }
            second.close()
            first.close()
        }
    }

    @Test("a duplicated helper descriptor retains the model lock after the sender closes")
    func helperDescriptorRetainsModelLock() async throws {
        try await withGate { gate in
            let clock = ContinuousClock()
            let clientLease = try gate.acquireModelExecution()
            let duplicate = try #require(clientLease.withBorrowedFileDescriptor { descriptor in
                Darwin.dup(descriptor)
            })
            let helperLease = try GemmaProcessGate.adoptHelperExecutionDescriptor(duplicate)
            clientLease.close()

            await #expect(throws: GemmaProcessGateError.timedOut) {
                _ = try await gate.acquireRecordingLease(
                    until: clock.now.advanced(by: .milliseconds(40))
                )
            }
            helperLease.close()
            let recording = try await gate.acquireRecordingLease(
                until: clock.now.advanced(by: .seconds(1))
            )
            recording.close()
        }
    }

    @Test("a descriptor transferred to another process retains the model lock")
    func transferredDescriptorRetainsModelLock() async throws {
        try await withGateDirectory { directory in
            let clock = ContinuousClock()
            let gate = GemmaProcessGate(configuration: try GemmaProcessGateConfiguration(
                directoryURL: directory
            ))
            let clientLease = try gate.acquireModelExecution()
            let inheritedDescriptor = try #require(
                clientLease.withBorrowedFileDescriptor(Darwin.dup)
            )
            guard inheritedDescriptor >= 0 else {
                throw GemmaProcessGateError.infrastructureFailure
            }
            let inheritedHandle = FileHandle(
                fileDescriptor: inheritedDescriptor,
                closeOnDealloc: true
            )
            let helper = try launchProbe(
                mode: "adopt-model-stdin",
                directory: directory,
                standardInput: inheritedHandle
            )
            defer {
                if helper.isRunning {
                    _ = Darwin.kill(helper.processIdentifier, SIGKILL)
                    helper.waitUntilExit()
                }
            }
            try inheritedHandle.close()
            try await expectReady(helper)
            clientLease.close()

            await #expect(throws: GemmaProcessGateError.timedOut) {
                _ = try await gate.acquireRecordingLease(
                    until: clock.now.advanced(by: .milliseconds(40))
                )
            }
            #expect(Darwin.kill(helper.processIdentifier, SIGKILL) == 0)
            helper.waitUntilExit()
            let recording = try await gate.acquireRecordingLease(
                until: clock.now.advanced(by: .seconds(1))
            )
            recording.close()
        }
    }

    @Test("a contended acquisition is cancellation-bounded and closes its temporary description")
    func cancellationClosesTemporaryDescription() async throws {
        try await withGate { gate in
            let clock = ContinuousClock()
            let model = try gate.acquireModelExecution()
            let transition = try await gate.beginRecordingTransition(
                until: clock.now.advanced(by: .seconds(1))
            )
            let waiting = Task {
                try await transition.acquireRecordingLease(
                    until: ContinuousClock().now.advanced(by: .seconds(5))
                )
            }
            waiting.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await waiting.value
            }
            model.close()
            let recording = try await gate.acquireRecordingLease(
                until: clock.now.advanced(by: .seconds(1))
            )
            recording.close()
        }
    }

    @Test("unsafe leafs fail closed")
    func unsafeLeafsFailClosed() async throws {
        try await withGateDirectory { directory in
            let leaf = directory.appendingPathComponent("gate-v1.lock")
            try FileManager.default.createSymbolicLink(
                at: leaf,
                withDestinationURL: directory.appendingPathComponent("elsewhere")
            )
            let configuration = try GemmaProcessGateConfiguration(directoryURL: directory)
            let gate = GemmaProcessGate(configuration: configuration)
            #expect(throws: GemmaProcessGateError.unsafeGateFile) {
                _ = try gate.acquireModelExecution()
            }
        }
    }

    @Test("unsafe permissions, hard links, and non-regular leafs fail closed")
    func unsafeGateMetadataFailsClosed() async throws {
        try await withGateDirectory { directory in
            let leaf = directory.appendingPathComponent("gate-v1.lock")
            FileManager.default.createFile(atPath: leaf.path, contents: Data())
            #expect(Darwin.chmod(leaf.path, 0o640) == 0)
            let gate = GemmaProcessGate(configuration: try GemmaProcessGateConfiguration(
                directoryURL: directory
            ))
            #expect(throws: GemmaProcessGateError.unsafeGateFile) {
                _ = try gate.acquireModelExecution()
            }
        }

        try await withGateDirectory { directory in
            let leaf = directory.appendingPathComponent("gate-v1.lock")
            FileManager.default.createFile(atPath: leaf.path, contents: Data())
            #expect(Darwin.chmod(leaf.path, 0o600) == 0)
            let extraLink = directory.appendingPathComponent("extra-link")
            #expect(Darwin.link(leaf.path, extraLink.path) == 0)
            let gate = GemmaProcessGate(configuration: try GemmaProcessGateConfiguration(
                directoryURL: directory
            ))
            #expect(throws: GemmaProcessGateError.unsafeGateFile) {
                _ = try gate.acquireModelExecution()
            }
        }

        try await withGateDirectory { directory in
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("gate-v1.lock"),
                withIntermediateDirectories: false
            )
            let gate = GemmaProcessGate(configuration: try GemmaProcessGateConfiguration(
                directoryURL: directory
            ))
            #expect(throws: GemmaProcessGateError.unsafeGateFile) {
                _ = try gate.acquireModelExecution()
            }
        }
    }

    @Test("a helper detects an exclusive recording turnstile on byte zero")
    func helperDetectsRecordingIntent() async throws {
        try await withGate { gate in
            let clock = ContinuousClock()
            let model = try gate.acquireModelExecution()
            let transition = try await gate.beginRecordingTransition(
                until: clock.now.advanced(by: .seconds(1))
            )
            #expect(try GemmaProcessGate.helperObservesRecordingIntent(for: model))
            transition.close()
            model.close()
        }
    }

    @Test("SIGKILL releases a recording owner after waitpid")
    func sigkillReleasesRecordingLease() async throws {
        try await withGateDirectory { directory in
            let owner = try launchProbe(mode: "recording", directory: directory)
            defer { owner.terminate() }
            try await expectReady(owner)
            #expect(Darwin.kill(owner.processIdentifier, SIGKILL) == 0)
            owner.waitUntilExit()

            let gate = GemmaProcessGate(configuration: try GemmaProcessGateConfiguration(
                directoryURL: directory
            ))
            let model = try gate.acquireModelExecution()
            model.close()
        }
    }

    @Test("two independent recording processes hold compatible shared execution locks")
    func independentRecordingProcessesAreCompatible() async throws {
        try await withGateDirectory { directory in
            let first = try launchProbe(mode: "recording", directory: directory)
            try await expectReady(first)
            let second = try launchProbe(mode: "recording", directory: directory)
            defer {
                releaseProbe(first)
                releaseProbe(second)
            }
            try await expectReady(second)
        }
    }
}

private func withGate(
    _ body: @Sendable (GemmaProcessGate) async throws -> Void
) async throws {
    try await withGateDirectory { directory in
        try await body(GemmaProcessGate(configuration: try GemmaProcessGateConfiguration(
            directoryURL: directory
        )))
    }
}

private func withGateDirectory(
    _ body: @Sendable (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-gemma-gate-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func launchProbe(
    mode: String,
    directory: URL,
    standardInput: Any = Pipe()
) throws -> Process {
    let process = Process()
    let sourcePackageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("steno-gemma-gate-probe")
    let swiftPMProbeURL = sourcePackageURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/out/Products/Debug/steno-gemma-gate-probe")
    let bundleProbeURL = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("steno-gemma-gate-probe")
    let probeURL = [swiftPMProbeURL, bundleProbeURL].first {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }
    guard let probeURL else {
        throw GemmaProcessGateError.infrastructureFailure
    }
    process.executableURL = probeURL
    process.arguments = [mode, directory.path]
    process.standardInput = standardInput
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
}

private func expectReady(_ process: Process) async throws {
    guard let output = process.standardOutput as? Pipe else {
        throw GemmaProcessGateError.infrastructureFailure
    }
    let data = output.fileHandleForReading.availableData
    guard String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ready" else {
        throw GemmaProcessGateError.infrastructureFailure
    }
}

private func releaseProbe(_ process: Process) {
    guard process.isRunning else { return }
    if let input = process.standardInput as? Pipe {
        input.fileHandleForWriting.write(Data("release\n".utf8))
        try? input.fileHandleForWriting.close()
    }
    process.waitUntilExit()
}
