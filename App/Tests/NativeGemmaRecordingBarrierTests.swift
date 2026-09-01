import Foundation
import StenoLibrary
import StenoMacAudio
import Testing
@testable import steno_macos

#if canImport(StenoGemmaClient)
import StenoGemmaClient
import StenoGemmaIPC
#endif

@Suite("Native Gemma recording barrier", .serialized)
@MainActor
struct NativeGemmaRecordingBarrierTests {
    @Test("a barrier failure prevents permission UI and recording startup")
    func barrierFailureStopsBeforeFirstRecordingAwait() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        let events = NativeGemmaRecordingEventLog()
        let barrier = NativeGemmaRecordingBarrierProbe(
            events: events,
            acquireError: NativeGemmaRecordingTestError.expectedFailure
        )
        var model: AppModel? = AppModel(
            recordingPermissionClient: permissionClient(
                status: .authorized,
                events: events
            ),
            nativeGemmaRecordingBarrier: barrier,
            libraryURL: fixture.libraryURL
        )
        await model?.bootstrap()

        await model?.startRecording()

        #expect(await events.snapshot() == ["barrier.acquire"])
        #expect(model?.isRecording == false)
        #expect(model?.notice?.isError == true)
        await model?.runtime?.coordinator.stop()
        await model?.stopBackgroundLibraryTasksForTesting()
        model = nil
        fixture.cleanUp()
    }

    @Test("a denied microphone request releases the acquired barrier")
    func permissionDenialReleasesBarrier() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        let events = NativeGemmaRecordingEventLog()
        let barrier = NativeGemmaRecordingBarrierProbe(events: events)
        var model: AppModel? = AppModel(
            recordingPermissionClient: permissionClient(
                status: .denied,
                events: events
            ),
            nativeGemmaRecordingBarrier: barrier,
            libraryURL: fixture.libraryURL
        )
        await model?.bootstrap()

        await model?.startRecording()

        #expect(await events.snapshot() == [
            "barrier.acquire",
            "permission.requestMicrophone",
            "barrier.release",
        ])
        #expect(model?.isRecording == false)
        await model?.runtime?.coordinator.stop()
        await model?.stopBackgroundLibraryTasksForTesting()
        model = nil
        fixture.cleanUp()
    }

    #if canImport(StenoGemmaClient)
    @Test("the live factory returns one process-wide coordinator")
    func liveFactoryReturnsProcessWideCoordinator() {
        let first = NativeGemmaRecordingBarrierFactory.live()
        let second = NativeGemmaRecordingBarrierFactory.live()

        #expect(first === second)
    }

    @Test("concurrent first use shares one controller and cannot overwrite a held barrier")
    func concurrentFirstSendAndAcquireShareInitialization() async throws {
        let client = NativeGemmaClientProbe()
        let initializer = NativeGemmaClientInitializationProbe(client: client)
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            controllerInitializer: {
                try await initializer.initialize()
            }
        )
        let request = GemmaIPCRequestBody.handshake(.init(model: try testModelPin()))
        let expectedResponse = GemmaIPCResponseBody.handshake(
            .init(
                serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
                adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                supportedOperations: [.handshake, .cancel, .shutdown]
            )
        )

        let sendTask = Task { () -> NativeGemmaInitialSendOutcome in
            do {
                return .admitted(try await coordinator.send(request))
            } catch NativeGemmaCoordinatorError.unavailable {
                return .blocked
            } catch NativeGemmaRecordingTestError.recordingActive {
                return .blocked
            } catch {
                return .unexpectedFailure
            }
        }
        await initializer.waitUntilInitializationStarted()
        let acquireTask = Task {
            try await coordinator.acquire()
        }
        await Task.yield()
        await initializer.resumeInitialization()

        let initialSendOutcome = await sendTask.value
        try await acquireTask.value

        #expect(await initializer.initializationCount() == 1)
        #expect(await client.acquireCount() == 1)
        #expect(
            initialSendOutcome == .admitted(expectedResponse)
                || initialSendOutcome == .blocked
        )
        do {
            _ = try await coordinator.send(request)
            Issue.record("Native Gemma work was admitted while the recording barrier was held")
        } catch {
            // Expected: the shared coordinator fails closed while capture owns the lease.
        }

        try await coordinator.release()
        #expect(await client.releaseCount() == 1)
        #expect(try await coordinator.send(request) == expectedResponse)
    }

    private func testModelPin() throws -> GemmaModelSnapshotPin {
        try GemmaModelSnapshotPin(
            modelIdentifier: "google/gemma-4-test",
            checkpointRevision: String(repeating: "a", count: 40),
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            licenseIdentifier: "gemma",
            manifestSHA256: String(repeating: "b", count: 64)
        )
    }
    #endif

    private func permissionClient(
        status: AudioPermissionStatus,
        events: NativeGemmaRecordingEventLog
    ) -> MacRecordingPermissionClient {
        MacRecordingPermissionClient(
            microphoneStatus: { status },
            requestMicrophone: {
                await events.record("permission.requestMicrophone")
                return status
            },
            requestRecordingAccess: {
                RecordingAudioPermissionState(
                    microphone: status,
                    systemAudio: .notDetermined
                )
            }
        )
    }
}

private struct NativeGemmaRecordingFixture {
    let root: URL
    let libraryURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-NativeGemmaRecordingBarrierTests-\(UUID().uuidString)",
            isDirectory: true
        )
        libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        _ = try Library.open(at: libraryURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor NativeGemmaRecordingBarrierProbe: NativeGemmaCoordinator {
    private let events: NativeGemmaRecordingEventLog
    private let acquireError: (any Error)?

    init(
        events: NativeGemmaRecordingEventLog,
        acquireError: (any Error)? = nil
    ) {
        self.events = events
        self.acquireError = acquireError
    }

    func acquire() async throws {
        await events.record("barrier.acquire")
        if let acquireError {
            throw acquireError
        }
    }

    func release() async throws {
        await events.record("barrier.release")
    }
}

private actor NativeGemmaRecordingEventLog {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private enum NativeGemmaRecordingTestError: Error {
    case expectedFailure
    case recordingActive
}

#if canImport(StenoGemmaClient)
private enum NativeGemmaInitialSendOutcome: Equatable, Sendable {
    case admitted(GemmaIPCResponseBody)
    case blocked
    case unexpectedFailure
}

private actor NativeGemmaClientInitializationProbe {
    private let client: any NativeGemmaClientControlling
    private var count = 0
    private var didResume = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var initializationWaiters: [CheckedContinuation<Void, Never>] = []

    init(client: any NativeGemmaClientControlling) {
        self.client = client
    }

    func initialize() async throws -> any NativeGemmaClientControlling {
        count += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !didResume {
            await withCheckedContinuation { continuation in
                if didResume {
                    continuation.resume()
                } else {
                    initializationWaiters.append(continuation)
                }
            }
        }
        return client
    }

    func waitUntilInitializationStarted() async {
        if count > 0 { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeInitialization() {
        didResume = true
        let waiters = initializationWaiters
        initializationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func initializationCount() -> Int {
        count
    }
}

private actor NativeGemmaClientProbe: NativeGemmaClientControlling {
    private var activeLease: GemmaRecordingLease?
    private var acquisitions = 0
    private var releases = 0

    func acquireRecordingLease(
        _ lease: GemmaRecordingLease
    ) -> GemmaRecordingLease {
        activeLease = lease
        acquisitions += 1
        return lease
    }

    func releaseRecordingLease(_ lease: GemmaRecordingLease) throws {
        guard activeLease == lease else {
            throw NativeGemmaRecordingTestError.expectedFailure
        }
        activeLease = nil
        releases += 1
    }

    func send(_ body: GemmaIPCRequestBody) throws -> GemmaIPCResponseBody {
        guard activeLease == nil else {
            throw NativeGemmaRecordingTestError.recordingActive
        }
        guard case .handshake = body else {
            throw NativeGemmaRecordingTestError.expectedFailure
        }
        return .handshake(
            .init(
                serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
                adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                supportedOperations: [.handshake, .cancel, .shutdown]
            )
        )
    }

    func acquireCount() -> Int {
        acquisitions
    }

    func releaseCount() -> Int {
        releases
    }
}
#endif
