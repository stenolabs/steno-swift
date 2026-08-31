import Foundation
#if STENO_NATIVE_GEMMA_MODEL_STORE
import StenoDomain
import StenoPipeline
#endif
import StenoLibrary
import StenoMacAudio
import StenoGemmaProcessGate
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

    @Test("a denied microphone request releases the real process gate")
    func permissionDenialReleasesProcessGate() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        let events = NativeGemmaRecordingEventLog()
        let processGate = try fixture.processGate()
        let barrier = NativeGemmaRecordingBarrierFactory.testing(processGate: processGate)
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

        #expect(model?.isRecording == false)
        let modelLease = try processGate.acquireModelExecution()
        modelLease.close()
        await model?.runtime?.coordinator.stop()
        await model?.stopBackgroundLibraryTasksForTesting()
        model = nil
        fixture.cleanUp()
    }

    @Test("gate-only recording lease excludes model admission until release")
    func gateOnlyRecordingLeaseExcludesModelAdmissionUntilRelease() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let processGate = try fixture.processGate()
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(processGate: processGate)

        try await coordinator.acquire()
        #expect(throws: GemmaProcessGateError.busy) {
            _ = try processGate.acquireModelExecution()
        }
        try await coordinator.release()

        let modelLease = try processGate.acquireModelExecution()
        modelLease.close()
        await #expect(throws: NativeGemmaCoordinatorError.self) {
            try await coordinator.release()
        }
    }

    @Test("gate-only acquisition cancellation leaves the gate reusable")
    func gateOnlyAcquisitionCancellationLeavesGateReusable() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let processGate = try fixture.processGate()
        let modelLease = try processGate.acquireModelExecution()
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: processGate,
            recordingGateTimeout: .seconds(10)
        )

        let acquisition = Task {
            do {
                try await coordinator.acquire()
                return false
            } catch {
                return true
            }
        }
        await Task.yield()
        acquisition.cancel()
        #expect(await acquisition.value)
        modelLease.close()

        try await coordinator.acquire()
        try await coordinator.release()
    }

    #if STENO_NATIVE_GEMMA_MODEL_STORE
    @Test("recording waits for exact import quiescence before requesting permission")
    func recordingWaitsForExactImportQuiescence() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        let events = NativeGemmaRecordingEventLog()
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate(),
            recordingGateTimeout: .seconds(10)
        )
        let importProbe = NativeGemmaImportDrainProbe(events: events)
        let snapshot = nativeGemmaTestSnapshot()
        var model: AppModel? = AppModel(
            recordingPermissionClient: permissionClient(
                status: .denied,
                events: events
            ),
            nativeGemmaRecordingBarrier: coordinator,
            libraryURL: fixture.libraryURL
        )
        await model?.bootstrap()

        let importTask = Task {
            try await coordinator.performModelImport {
                try await importProbe.run(outcome: .success(snapshot))
            }
        }
        await importProbe.waitUntilStarted()

        let app = model
        let recordingTask = Task {
            await app?.startRecording()
        }
        await importProbe.waitUntilCancellationWasObserved()

        #expect(await events.snapshot() == [
            "import.started",
            "import.cancelled",
        ])
        await #expect(throws: NativeGemmaCoordinatorError.unavailable) {
            _ = try await coordinator.performModelImport { snapshot }
        }

        await importProbe.finish()
        await recordingTask.value
        #expect(try await importTask.value == snapshot)
        #expect(await events.snapshot() == [
            "import.started",
            "import.cancelled",
            "import.finished",
            "permission.requestMicrophone",
        ])
        #expect(model?.isRecording == false)

        let retry = try await coordinator.performModelImport { snapshot }
        #expect(retry == snapshot)
        await model?.runtime?.coordinator.stop()
        await model?.stopBackgroundLibraryTasksForTesting()
        model = nil
        fixture.cleanUp()
    }

    @Test("a held recording lease rejects imports until release")
    func heldRecordingLeaseRejectsImports() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        #if canImport(StenoGemmaClient)
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate(),
            controllerInitializer: { NativeGemmaClientProbe() }
        )
        #else
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate()
        )
        #endif
        let snapshot = nativeGemmaTestSnapshot()

        try await coordinator.acquire()
        await #expect(throws: NativeGemmaCoordinatorError.unavailable) {
            _ = try await coordinator.performModelImport { snapshot }
        }
        try await coordinator.release()

        #expect(try await coordinator.performModelImport { snapshot } == snapshot)
    }

    @Test("an import failure after cancellation cannot block recording")
    func importFailureAfterCancellationCannotBlockRecording() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        let events = NativeGemmaRecordingEventLog()
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate(),
            recordingGateTimeout: .seconds(10)
        )
        let importProbe = NativeGemmaImportDrainProbe(events: events)
        var model: AppModel? = AppModel(
            recordingPermissionClient: permissionClient(
                status: .denied,
                events: events
            ),
            nativeGemmaRecordingBarrier: coordinator,
            libraryURL: fixture.libraryURL
        )
        await model?.bootstrap()

        let importTask = Task {
            try await coordinator.performModelImport {
                try await importProbe.run(outcome: .failure)
            }
        }
        await importProbe.waitUntilStarted()

        let app = model
        let recordingTask = Task {
            await app?.startRecording()
        }
        await importProbe.waitUntilCancellationWasObserved()
        await importProbe.finish()
        await recordingTask.value

        await #expect(throws: NativeGemmaRecordingTestError.expectedFailure) {
            _ = try await importTask.value
        }
        #expect(await events.snapshot() == [
            "import.started",
            "import.cancelled",
            "import.failed",
            "permission.requestMicrophone",
        ])
        #expect(model?.isRecording == false)

        let snapshot = nativeGemmaTestSnapshot()
        #expect(try await coordinator.performModelImport { snapshot } == snapshot)
        await model?.runtime?.coordinator.stop()
        await model?.stopBackgroundLibraryTasksForTesting()
        model = nil
        fixture.cleanUp()
    }

    @Test("cancelling recording admission still drains the exact import")
    func cancelledRecordingAdmissionStillDrainsExactImport() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let events = NativeGemmaRecordingEventLog()
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate(),
            recordingGateTimeout: .seconds(10)
        )
        let importProbe = NativeGemmaImportDrainProbe(events: events)
        let snapshot = nativeGemmaTestSnapshot()
        let importTask = Task {
            try await coordinator.performModelImport {
                try await importProbe.run(outcome: .success(snapshot))
            }
        }
        await importProbe.waitUntilStarted()

        let recordingAdmission = Task {
            try await coordinator.acquire()
        }
        await importProbe.waitUntilCancellationWasObserved()
        recordingAdmission.cancel()

        await #expect(throws: NativeGemmaCoordinatorError.unavailable) {
            _ = try await coordinator.performModelImport { snapshot }
        }
        await importProbe.finish()
        await #expect(throws: (any Error).self) {
            try await recordingAdmission.value
        }
        #expect(try await importTask.value == snapshot)

        try await coordinator.acquire()
        try await coordinator.release()
        #expect(try await coordinator.performModelImport { snapshot } == snapshot)
    }

    @Test("the app import facade releases admission when consent is missing")
    func appImportFacadeReleasesAdmissionWhenConsentIsMissing() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate()
        )
        let importer = NativeGemmaModelImportProbe()
        let facade = NativeGemmaModelImportFacade(
            installationCoordinator: ModelInstallationCoordinator(installers: []),
            safetyCoordinator: coordinator,
            importer: importer
        )
        let pin = try ApprovedNativeGemmaModelPin(
            modelIdentifier: "google/gemma-4-test",
            checkpointRevision: String(repeating: "a", count: 40),
            adapterRevision: String(repeating: "b", count: 40),
            licenseIdentifier: "Gemma-Terms",
            manifestSHA256: String(repeating: "c", count: 64)
        )

        await #expect(throws: ModelInstallationError.consentMissing) {
            _ = try await facade.importModel(
                pin: pin,
                sourceRoot: fixture.root,
                consentGranted: false
            )
        }
        #expect(await importer.invocationCount() == 0)

        try await coordinator.acquire()
        try await coordinator.release()
    }
    #endif

    #if canImport(StenoGemmaClient)
    @Test("the live factory returns one process-wide coordinator")
    func liveFactoryReturnsProcessWideCoordinator() {
        let first = NativeGemmaRecordingBarrierFactory.live()
        let second = NativeGemmaRecordingBarrierFactory.live()

        #expect(first === second)
    }

    @Test("concurrent first use shares one controller and cannot overwrite a held barrier")
    func concurrentFirstSendAndAcquireShareInitialization() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let client = NativeGemmaClientProbe()
        let initializer = NativeGemmaClientInitializationProbe(client: client)
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate(),
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
        let acquisitionCount = await client.acquireCount()
        let releaseCount = await client.releaseCount()
        #expect(acquisitionCount == releaseCount)
        #expect(try await coordinator.send(request) == expectedResponse)
    }

    @Test("disabled model initialization still acquires the process recording gate")
    func disabledModelStillAcquiresProcessGate() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let processGate = try fixture.processGate()
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: processGate,
            controllerInitializer: {
                throw NativeGemmaRecordingTestError.expectedFailure
            }
        )
        let request = GemmaIPCRequestBody.handshake(.init(model: try testModelPin()))

        await #expect(throws: NativeGemmaCoordinatorError.self) {
            _ = try await coordinator.send(request)
        }
        try await coordinator.acquire()
        #expect(throws: GemmaProcessGateError.busy) {
            _ = try processGate.acquireModelExecution()
        }
        try await coordinator.release()

        let modelLease = try processGate.acquireModelExecution()
        modelLease.close()
    }

    @Test("a failed cooperative retirement cannot bypass the gate or poison later model use")
    func failedLocalRetirementStillAcquiresProcessGate() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let processGate = try fixture.processGate()
        let client = NativeGemmaClientProbe(
            acquireError: NativeGemmaRecordingTestError.expectedFailure
        )
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: processGate,
            controllerInitializer: { client }
        )
        let request = GemmaIPCRequestBody.handshake(.init(model: try testModelPin()))

        _ = try await coordinator.send(request)
        try await coordinator.acquire()
        #expect(await client.acquireCount() == 1)
        #expect(throws: GemmaProcessGateError.busy) {
            _ = try processGate.acquireModelExecution()
        }
        try await coordinator.release()

        #expect(try await coordinator.send(request) == .handshake(.init(
            serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
            adapterRevision: GemmaIPCBuildInfo.adapterRevision,
            supportedOperations: [.handshake, .cancel, .shutdown]
        )))
        let modelLease = try processGate.acquireModelExecution()
        modelLease.close()
    }

    @Test("an activation fault does not relaunch until recording proves helper absence")
    func activationFaultRequiresRecordingCycleBeforeRetry() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let firstClient = NativeGemmaClientProbe(
            sendError: GemmaClientControllerError.operationFailed(.sessionActivation)
        )
        let replacementClient = NativeGemmaClientProbe()
        let initializer = NativeGemmaClientSequenceProbe(
            clients: [firstClient, replacementClient]
        )
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate(),
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

        await #expect(throws: GemmaClientControllerError.operationFailed(.sessionActivation)) {
            _ = try await coordinator.send(request)
        }
        await #expect(throws: NativeGemmaCoordinatorError.unavailable) {
            _ = try await coordinator.send(request)
        }
        #expect(await initializer.initializationCount() == 1)
        #expect(await firstClient.sendCount() == 1)

        try await coordinator.acquire()
        try await coordinator.release()

        #expect(try await coordinator.send(request) == expectedResponse)
        #expect(await initializer.initializationCount() == 2)
    }

    @Test("a release fault is discarded before the next model request")
    func releaseFaultCreatesFreshControllerBeforeNextModelRequest() async throws {
        let fixture = try NativeGemmaRecordingFixture()
        defer { fixture.cleanUp() }
        let firstClient = NativeGemmaClientProbe(
            releaseError: NativeGemmaRecordingTestError.expectedFailure
        )
        let replacementClient = NativeGemmaClientProbe()
        let initializer = NativeGemmaClientSequenceProbe(
            clients: [firstClient, replacementClient]
        )
        let coordinator = NativeGemmaRecordingBarrierFactory.testing(
            processGate: try fixture.processGate(),
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

        #expect(try await coordinator.send(request) == expectedResponse)
        try await coordinator.acquire()
        try await coordinator.release()

        #expect(await firstClient.acquireCount() == 1)
        #expect(await firstClient.releaseCount() == 1)
        #expect(try await coordinator.send(request) == expectedResponse)
        #expect(await initializer.initializationCount() == 2)
        #expect(await replacementClient.acquireCount() == 0)
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

#if STENO_NATIVE_GEMMA_MODEL_STORE
private func nativeGemmaTestSnapshot() -> NativeGemmaModelSnapshot {
    NativeGemmaModelSnapshot(
        modelIdentifier: "google/gemma-4-test",
        checkpointRevision: String(repeating: "a", count: 40),
        adapterRevision: String(repeating: "b", count: 40),
        licenseIdentifier: "Gemma-Terms",
        manifestSHA256: String(repeating: "c", count: 64)
    )
}
#endif

private struct NativeGemmaRecordingFixture {
    let root: URL
    let libraryURL: URL
    let gateDirectoryURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Steno-NativeGemmaRecordingBarrierTests-\(UUID().uuidString)",
            isDirectory: true
        )
        libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        gateDirectoryURL = root.appendingPathComponent("NativeGemmaGate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: gateDirectoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try Library.open(at: libraryURL)
    }

    func processGate() throws -> GemmaProcessGate {
        GemmaProcessGate(configuration: try GemmaProcessGateConfiguration(
            directoryURL: gateDirectoryURL
        ))
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

    #if STENO_NATIVE_GEMMA_MODEL_STORE
    func performModelImport(
        _ operation: @escaping @Sendable () async throws -> NativeGemmaModelSnapshot
    ) async throws -> NativeGemmaModelSnapshot {
        try await operation()
    }
    #endif
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

#if STENO_NATIVE_GEMMA_MODEL_STORE
private actor NativeGemmaImportDrainProbe {
    enum Outcome: Sendable {
        case success(NativeGemmaModelSnapshot)
        case failure
    }

    private let events: NativeGemmaRecordingEventLog
    private var didStart = false
    private var didObserveCancellation = false
    private var mayFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(events: NativeGemmaRecordingEventLog) {
        self.events = events
    }

    func run(outcome: Outcome) async throws -> NativeGemmaModelSnapshot {
        await events.record("import.started")
        didStart = true
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStartWaiters {
            waiter.resume()
        }

        return try await withTaskCancellationHandler {
            if !mayFinish {
                await withCheckedContinuation { continuation in
                    if mayFinish {
                        continuation.resume()
                    } else {
                        finishWaiters.append(continuation)
                    }
                }
            }
            switch outcome {
            case .success(let snapshot):
                await events.record("import.finished")
                return snapshot
            case .failure:
                await events.record("import.failed")
                throw NativeGemmaRecordingTestError.expectedFailure
            }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationWasObserved() async {
        if didObserveCancellation { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func finish() {
        mayFinish = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func observeCancellation() async {
        guard !didObserveCancellation else { return }
        await events.record("import.cancelled")
        didObserveCancellation = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor NativeGemmaModelImportProbe: NativeGemmaModelImporting {
    private var count = 0

    func importApprovedNativeGemmaModel(
        pin: ApprovedNativeGemmaModelPin,
        sourceRoot: URL,
        sourceIdentity: NativeGemmaSourceIdentity
    ) async throws -> NativeGemmaModelSnapshot {
        count += 1
        return pin.snapshot
    }

    func invocationCount() -> Int {
        count
    }
}
#endif

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
    private let acquireError: (any Error)?
    private let releaseError: (any Error)?
    private let sendError: (any Error)?
    private var activeLease: GemmaRecordingLease?
    private var acquisitions = 0
    private var releases = 0
    private var sends = 0

    init(
        acquireError: (any Error)? = nil,
        releaseError: (any Error)? = nil,
        sendError: (any Error)? = nil
    ) {
        self.acquireError = acquireError
        self.releaseError = releaseError
        self.sendError = sendError
    }

    func acquireRecordingLease(
        _ lease: GemmaRecordingLease
    ) throws -> GemmaRecordingLease {
        acquisitions += 1
        if let acquireError {
            throw acquireError
        }
        activeLease = lease
        return lease
    }

    func releaseRecordingLease(_ lease: GemmaRecordingLease) throws {
        guard activeLease == lease else {
            throw NativeGemmaRecordingTestError.expectedFailure
        }
        activeLease = nil
        releases += 1
        if let releaseError {
            throw releaseError
        }
    }

    func send(_ body: GemmaIPCRequestBody) throws -> GemmaIPCResponseBody {
        sends += 1
        if let sendError {
            throw sendError
        }
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

    func sendCount() -> Int {
        sends
    }
}

private actor NativeGemmaClientSequenceProbe {
    private let clients: [any NativeGemmaClientControlling]
    private var nextIndex = 0

    init(clients: [any NativeGemmaClientControlling]) {
        self.clients = clients
    }

    func initialize() throws -> any NativeGemmaClientControlling {
        guard nextIndex < clients.count else {
            throw NativeGemmaRecordingTestError.expectedFailure
        }
        defer { nextIndex += 1 }
        return clients[nextIndex]
    }

    func initializationCount() -> Int {
        nextIndex
    }
}
#endif
