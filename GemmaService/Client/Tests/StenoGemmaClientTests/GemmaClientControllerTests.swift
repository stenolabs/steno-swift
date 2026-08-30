import Darwin
import Foundation
@testable import StenoGemmaClient
import StenoGemmaIPC
import Testing

@Suite("Gemma client recording barrier")
struct GemmaClientControllerTests {
    @Test("the controller connects lazily and release never reconnects eagerly")
    func lazyConnectionAndReleaseSemantics() async throws {
        let events = EventLog()
        let transport = TestTransport(events: events)
        let factory = TestTransportFactory(transport: transport, events: events)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: factory,
            exitProver: TestExitProver(events: events),
            deadline: ManualDeadline()
        )

        #expect(await controller.lifecycleState() == .idle)
        #expect(factory.creationCount == 0)

        let lease = try await controller.acquireRecordingLease(GemmaRecordingLease())
        #expect(await controller.lifecycleState() == .recording)
        #expect(factory.creationCount == 0)

        await #expect(throws: GemmaClientControllerError.recordingActive) {
            try await controller.send(try generationBody(prompt: "during recording"))
        }
        #expect(factory.creationCount == 0)

        try await controller.releaseRecordingLease(lease)
        #expect(await controller.lifecycleState() == .idle)
        #expect(factory.creationCount == 0)

        let response = try await controller.send(try generationBody(prompt: "after recording"))
        #expect(response == .generate(GemmaIPCGenerateResponse(text: "generated")))
        #expect(factory.creationCount == 1)
        #expect(await controller.lifecycleState() == .connected)
    }

    @Test("recording closes admission before cancelling a hanging active request")
    func teardownOrderingWithHangingActiveRequest() async throws {
        let events = EventLog()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let prepareGate = AsyncGate<Void>()
        let transport = TestTransport(
            events: events,
            applicationGate: applicationGate,
            prepareGate: prepareGate
        )
        let reconnectTransport = TestTransport(events: events)
        let factory = TestTransportFactory(
            transports: [transport, reconnectTransport],
            events: events
        )
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: factory,
            exitProver: TestExitProver(events: events),
            deadline: ManualDeadline()
        )

        let requestTask = Task {
            try await controller.send(try generationBody(prompt: "still running"))
        }
        await events.waitUntilPresent("send:generate")
        #expect(await controller.inFlightRequestCount() == 1)

        let leaseToken = GemmaRecordingLease()
        let leaseTask = Task { try await controller.acquireRecordingLease(leaseToken) }
        await events.waitUntilPresent("prepareForExit")
        applicationGate.resolve(.generate(GemmaIPCGenerateResponse(text: "late")))
        prepareGate.resolve(())
        await events.waitUntilPresent("waitForExit")

        await #expect(throws: GemmaClientControllerError.cancelledForRecording) {
            try await requestTask.value
        }
        let lease = try await leaseTask.value
        #expect(await controller.lifecycleState() == .recording)

        let orderedEvents = events.snapshot()
        #expect(orderedEvents.firstIndex(of: "factory")! < orderedEvents.firstIndex(of: "send:generate")!)
        #expect(orderedEvents.firstIndex(of: "send:generate")! < orderedEvents.firstIndex(of: "prepareForExit")!)
        #expect(orderedEvents.firstIndex(of: "prepareForExit")! < orderedEvents.firstIndex(of: "registerExitObservation")!)
        #expect(orderedEvents.firstIndex(of: "registerExitObservation")! < orderedEvents.firstIndex(of: "send:cancel")!)
        #expect(orderedEvents.firstIndex(of: "registerExitObservation")! < orderedEvents.firstIndex(of: "send:shutdown")!)
        #expect(orderedEvents.firstIndex(of: "send:cancel")! < orderedEvents.firstIndex(of: "armAndExit")!)
        #expect(orderedEvents.firstIndex(of: "send:shutdown")! < orderedEvents.firstIndex(of: "armAndExit")!)
        #expect(Array(orderedEvents.suffix(3)) == [
            "armAndExit",
            "waitForExit",
            "invalidate",
        ])

        await #expect(throws: GemmaClientControllerError.recordingActive) {
            try await controller.send(try generationBody(prompt: "blocked"))
        }
        #expect(factory.creationCount == 1)

        try await controller.releaseRecordingLease(lease)
        #expect(factory.creationCount == 1)

        let postRecordingResponse = try await controller.send(
            try generationBody(prompt: "explicit reconnect")
        )
        #expect(postRecordingResponse == .generate(GemmaIPCGenerateResponse(text: "generated")))
        #expect(factory.creationCount == 2)
    }

    @Test("a hanging shutdown still permits recording after exact process exit proof")
    func hangingShutdownFallsBackToProvenProcessExit() async throws {
        let events = EventLog()
        let shutdownGate = AsyncGate<GemmaIPCResponseBody>()
        let deadline = ManualDeadline()
        let transport = TestTransport(
            events: events,
            shutdownGate: shutdownGate
        )
        let factory = TestTransportFactory(transport: transport, events: events)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: factory,
            exitProver: TestExitProver(events: events),
            deadline: deadline
        )

        _ = try await controller.send(try generationBody(prompt: "connect"))
        let leaseToken = GemmaRecordingLease()
        let leaseTask = Task { try await controller.acquireRecordingLease(leaseToken) }
        await events.waitUntilPresent("send:shutdown")
        await deadline.waitUntilRegistered(.quiescentShutdown)
        deadline.expire(.quiescentShutdown)

        await events.waitUntilPresent("waitForExit")
        let lease = try await leaseTask.value
        #expect(await controller.lifecycleState() == .recording)
        #expect(events.snapshot().suffix(3) == [
            "armAndExit",
            "waitForExit",
            "invalidate",
        ])
        #expect(factory.creationCount == 1)

        try await controller.releaseRecordingLease(lease)

        shutdownGate.resolve(
            .acknowledgement(
                GemmaIPCAcknowledgement(kind: .shutdown, didChangeState: true)
            )
        )
    }

    @Test("all hanging cancellations and shutdown share one bounded quiescence deadline")
    func hangingQuiescenceUsesOneSharedDeadline() async throws {
        let events = EventLog()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let quiescenceGate = AsyncGate<Void>()
        let deadline = ManualDeadline()
        let transport = TestTransport(
            events: events,
            applicationGate: applicationGate,
            quiescenceGate: quiescenceGate
        )
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: TestTransportFactory(transport: transport, events: events),
            exitProver: TestExitProver(events: events),
            deadline: deadline
        )

        let firstRequest = Task {
            try await controller.send(try generationBody(prompt: "first hanging request"))
        }
        let secondRequest = Task {
            try await controller.send(try generationBody(prompt: "second hanging request"))
        }
        await events.waitUntilCount("send:generate", reaches: 2)

        let leaseTask = Task {
            try await controller.acquireRecordingLease(GemmaRecordingLease())
        }
        await events.waitUntilCount("send:cancel", reaches: 2)
        await events.waitUntilPresent("send:shutdown")
        await deadline.waitUntilRegistered(.quiescentShutdown)
        #expect(deadline.waiterCount(for: .quiescentShutdown) == 1)

        deadline.expire(.quiescentShutdown)

        let lease = try await leaseTask.value
        #expect(await controller.lifecycleState() == .recording)
        await #expect(throws: GemmaClientControllerError.cancelledForRecording) {
            try await firstRequest.value
        }
        await #expect(throws: GemmaClientControllerError.cancelledForRecording) {
            try await secondRequest.value
        }
        #expect(events.snapshot().contains("armAndExit"))
        #expect(deadline.waiterCount(for: .quiescentShutdown) == 0)

        try await controller.releaseRecordingLease(lease)
        quiescenceGate.resolve(())
        applicationGate.resolve(.failure(GemmaIPCFailure(code: .cancelled)))
    }

    @Test("an unproven helper exit faults permanently without reconnect")
    func hangingExitProofFaultsWithoutReconnect() async throws {
        let events = EventLog()
        let deadline = ManualDeadline()
        let exitGate = AsyncGate<Void>()
        let transport = TestTransport(events: events)
        let factory = TestTransportFactory(transport: transport, events: events)
        let exitProver = TestExitProver(events: events, exitGate: exitGate)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: factory,
            exitProver: exitProver,
            deadline: deadline
        )

        _ = try await controller.send(try generationBody(prompt: "connect"))
        let leaseToken = GemmaRecordingLease()
        let leaseTask = Task { try await controller.acquireRecordingLease(leaseToken) }
        await events.waitUntilPresent("waitForExit")
        await deadline.waitUntilRegistered(.authenticatedHelperExit)
        deadline.expire(.authenticatedHelperExit)

        await #expect(throws: GemmaClientControllerError.timedOut(.authenticatedHelperExit)) {
            try await leaseTask.value
        }
        #expect(await controller.lifecycleState() == .faulted)
        #expect(events.snapshot().suffix(2) == ["waitForExit", "invalidate"])

        await #expect(throws: GemmaClientControllerError.faulted) {
            try await controller.send(try generationBody(prompt: "must not reconnect"))
        }
        await #expect(throws: GemmaClientControllerError.faulted) {
            try await controller.acquireRecordingLease(GemmaRecordingLease())
        }
        #expect(factory.creationCount == 1)

        exitGate.resolve(())
    }

    @Test("an arm-and-exit echo for another helper faults before self-exit")
    func mismatchedArmAndExitEchoFaultsBeforeSelfExit() async throws {
        let events = EventLog()
        let transport = TestTransport(events: events, armReturnsMismatch: true)
        let factory = TestTransportFactory(transport: transport, events: events)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: factory,
            exitProver: TestExitProver(events: events),
            deadline: ManualDeadline()
        )

        _ = try await controller.send(try generationBody(prompt: "connect"))
        await #expect(throws: GemmaClientControllerError.exitArmMismatch) {
            try await controller.acquireRecordingLease(GemmaRecordingLease())
        }

        #expect(await controller.lifecycleState() == .faulted)
        #expect(events.snapshot().suffix(2) == ["armAndExit", "invalidate"])
    }

    @Test("the in-flight limit returns busy without creating another transport")
    func boundedInFlightRequests() async throws {
        let events = EventLog()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let transport = TestTransport(
            events: events,
            applicationGate: applicationGate
        )
        let factory = TestTransportFactory(transport: transport, events: events)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: factory,
            exitProver: TestExitProver(events: events),
            deadline: ManualDeadline()
        )

        let firstRequest = Task {
            try await controller.send(try generationBody(prompt: "first"))
        }
        await events.waitUntilPresent("send:generate")

        await #expect(throws: GemmaClientControllerError.busy(limit: 1)) {
            try await controller.send(try generationBody(prompt: "second"))
        }
        #expect(factory.creationCount == 1)

        _ = try await controller.acquireRecordingLease(GemmaRecordingLease())
        await #expect(throws: GemmaClientControllerError.cancelledForRecording) {
            try await firstRequest.value
        }
        applicationGate.resolve(.generate(GemmaIPCGenerateResponse(text: "late")))
    }

    @Test("caller cancellation keeps a possibly running helper request tracked")
    func callerCancellationKeepsRequestTrackedForRecordingBarrier() async throws {
        let events = EventLog()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let transport = TestTransport(
            events: events,
            applicationGate: applicationGate
        )
        let factory = TestTransportFactory(transport: transport, events: events)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: factory,
            exitProver: TestExitProver(events: events),
            deadline: ManualDeadline()
        )

        let requestTask = Task {
            try await controller.send(try generationBody(prompt: "cancel locally"))
        }
        await events.waitUntilPresent("send:generate")
        requestTask.cancel()

        await #expect(throws: GemmaClientControllerError.requestCancelled) {
            try await requestTask.value
        }
        #expect(await controller.inFlightRequestCount() == 1)

        _ = try await controller.acquireRecordingLease(GemmaRecordingLease())
        #expect(events.snapshot().contains("send:cancel"))
        #expect(factory.creationCount == 1)
        applicationGate.resolve(.generate(GemmaIPCGenerateResponse(text: "late")))
    }

    @Test("an exit proof for another helper faults the controller")
    func mismatchedAuthenticatedExitProofFaults() async throws {
        let events = EventLog()
        let helper = UUID()
        let transport = TestTransport(events: events, helperInstance: helper)
        let factory = TestTransportFactory(transport: transport, events: events)
        let exitProver = TestExitProver(events: events, returnMismatchedProof: true)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: factory,
            exitProver: exitProver,
            deadline: ManualDeadline()
        )

        _ = try await controller.send(try generationBody(prompt: "connect"))
        await #expect(throws: GemmaClientControllerError.authenticatedExitProofMismatch) {
            try await controller.acquireRecordingLease(GemmaRecordingLease())
        }
        #expect(await controller.lifecycleState() == .faulted)
        #expect(factory.creationCount == 1)
    }

    @Test("an infrastructure failure resolves its caller before faulting permanently")
    func infrastructureFailureDoesNotLoseCurrentCompletion() async throws {
        let events = EventLog()
        let transport = TestTransport(events: events, applicationShouldFail: true)
        let factory = TestTransportFactory(transport: transport, events: events)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: factory,
            exitProver: TestExitProver(events: events),
            deadline: ManualDeadline()
        )

        await #expect(throws: GemmaClientControllerError.operationFailed(.request)) {
            try await controller.send(try generationBody(prompt: "transport failure"))
        }
        #expect(await controller.lifecycleState() == .faulted)
        #expect(events.snapshot().contains("invalidate"))
    }

    @Test("process-exit waits cancel and unblock without waiting for process death")
    func processExitWaitCancellationCleansUp() async throws {
        let prepared = GemmaIPCPreparedHelperExit(
            helperInstanceID: UUID(),
            processIdentifier: getpid()
        )
        let observation = GemmaDispatchSourceExitObservation(
            preparedHelper: prepared,
            queue: DispatchQueue(label: "org.stenolabs.steno.exit-observer-test")
        )
        try await observation.register()

        let waitTask = Task { try await observation.waitForExit() }
        waitTask.cancel()
        await #expect(throws: GemmaRawXPCTransportError.exitObservationInvalidated) {
            try await waitTask.value
        }
    }

    @Test("helper security profile requires sandbox and forbids network entitlements")
    func helperSecurityProfileValidation() {
        #expect(GemmaRawXPCSecurityProfile.isSafe(entitlements: [
            "com.apple.security.app-sandbox": true,
        ]))
        #expect(!GemmaRawXPCSecurityProfile.isSafe(entitlements: nil))
        #expect(!GemmaRawXPCSecurityProfile.isSafe(entitlements: [
            "com.apple.security.app-sandbox": false,
        ]))
        #expect(!GemmaRawXPCSecurityProfile.isSafe(entitlements: [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.network.client": true,
        ]))
        #expect(!GemmaRawXPCSecurityProfile.isSafe(entitlements: [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.network.server": true,
        ]))
    }
}

private func generationBody(prompt: String) throws -> GemmaIPCRequestBody {
    let pin = try GemmaModelSnapshotPin(
        modelIdentifier: "google/gemma-4-1b-it",
        checkpointRevision: String(repeating: "a", count: 40),
        adapterRevision: GemmaIPCBuildInfo.adapterRevision,
        licenseIdentifier: "gemma",
        manifestSHA256: String(repeating: "b", count: 64)
    )
    return .generate(
        try GemmaIPCGenerateRequest(
            model: pin,
            prompt: prompt,
            maximumTokens: 32
        )
    )
}

private final class TestTransportFactory: GemmaClientTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let transports: [TestTransport]
    private let events: EventLog
    private var storedCreationCount = 0

    init(transport: TestTransport, events: EventLog) {
        self.transports = [transport]
        self.events = events
    }

    init(transports: [TestTransport], events: EventLog) {
        self.transports = transports
        self.events = events
    }

    var creationCount: Int {
        lock.withLock { storedCreationCount }
    }

    func makeTransport() throws -> any GemmaClientTransport {
        let transport: TestTransport = try lock.withLock {
            guard storedCreationCount < transports.count else {
                throw TestTransportError.noConfiguredTransport
            }
            let transport = transports[storedCreationCount]
            storedCreationCount += 1
            return transport
        }
        events.record("factory")
        return transport
    }
}

private final class TestTransport: GemmaClientTransport, @unchecked Sendable {
    private let events: EventLog
    private let helperInstanceID: UUID
    private let applicationGate: AsyncGate<GemmaIPCResponseBody>?
    private let shutdownGate: AsyncGate<GemmaIPCResponseBody>?
    private let quiescenceGate: AsyncGate<Void>?
    private let prepareGate: AsyncGate<Void>?
    private let armReturnsMismatch: Bool
    private let applicationShouldFail: Bool

    init(
        events: EventLog,
        helperInstance: UUID = UUID(),
        applicationGate: AsyncGate<GemmaIPCResponseBody>? = nil,
        shutdownGate: AsyncGate<GemmaIPCResponseBody>? = nil,
        quiescenceGate: AsyncGate<Void>? = nil,
        prepareGate: AsyncGate<Void>? = nil,
        armReturnsMismatch: Bool = false,
        applicationShouldFail: Bool = false
    ) {
        self.events = events
        self.helperInstanceID = helperInstance
        self.applicationGate = applicationGate
        self.shutdownGate = shutdownGate
        self.quiescenceGate = quiescenceGate
        self.prepareGate = prepareGate
        self.armReturnsMismatch = armReturnsMismatch
        self.applicationShouldFail = applicationShouldFail
    }

    func send(_ encodedRequest: Data, requestID: UUID) async throws -> Data {
        let request = try GemmaIPCCodec.decodeRequest(encodedRequest)
        guard request.requestID == requestID else {
            throw TestTransportError.requestIDMismatch
        }
        events.record("send:\(request.body.operation.rawValue)")

        let body: GemmaIPCResponseBody
        switch request.body {
        case .generate:
            if applicationShouldFail {
                throw TestTransportError.applicationFailed
            }
            if let applicationGate {
                body = await applicationGate.wait()
            } else {
                body = .generate(GemmaIPCGenerateResponse(text: "generated"))
            }
        case .countTokens:
            if let applicationGate {
                body = await applicationGate.wait()
            } else {
                body = .tokenCount(GemmaIPCTokenCountResponse(tokenCount: 1))
            }
        case .handshake:
            body = .handshake(
                GemmaIPCHandshakeResponse(
                    serviceIdentifier: GemmaIPCBuildInfo.serviceIdentifier,
                    adapterRevision: GemmaIPCBuildInfo.adapterRevision,
                    supportedOperations: [.handshake, .cancel, .shutdown]
                )
            )
        case .cancel:
            if let quiescenceGate {
                await quiescenceGate.wait()
            }
            body = .acknowledgement(
                GemmaIPCAcknowledgement(kind: .cancelled, didChangeState: false)
            )
        case .shutdown:
            if let quiescenceGate {
                await quiescenceGate.wait()
            }
            if let shutdownGate {
                body = await shutdownGate.wait()
            } else {
                body = .acknowledgement(
                    GemmaIPCAcknowledgement(kind: .shutdown, didChangeState: true)
                )
            }
        }
        return try GemmaIPCCodec.encode(
            GemmaIPCResponseEnvelope(requestID: request.requestID, body: body)
        )
    }

    func prepareForExit() async throws -> GemmaPreparedHelperExit {
        events.record("prepareForExit")
        if let prepareGate {
            await prepareGate.wait()
        }
        return GemmaPreparedHelperExit(
            helperInstanceID: helperInstanceID,
            processIdentifier: 4_242
        )
    }

    func armAndExit(_ preparedHelper: GemmaPreparedHelperExit) async throws -> GemmaArmedHelperExit {
        events.record("armAndExit")
        if armReturnsMismatch {
            return GemmaArmedHelperExit(
                preparedHelper: GemmaPreparedHelperExit(
                    helperInstanceID: UUID(),
                    processIdentifier: preparedHelper.processIdentifier
                )
            )
        }
        return GemmaArmedHelperExit(preparedHelper: preparedHelper)
    }

    func invalidate() {
        events.record("invalidate")
        applicationGate?.resolve(.failure(GemmaIPCFailure(code: .cancelled)))
        shutdownGate?.resolve(
            .acknowledgement(
                GemmaIPCAcknowledgement(kind: .shutdown, didChangeState: true)
            )
        )
        quiescenceGate?.resolve(())
        prepareGate?.resolve(())
    }
}

private final class TestExitProver: GemmaAuthenticatedHelperExitProving, @unchecked Sendable {
    private let events: EventLog
    private let returnMismatchedProof: Bool
    private let exitGate: AsyncGate<Void>?

    init(
        events: EventLog,
        returnMismatchedProof: Bool = false,
        exitGate: AsyncGate<Void>? = nil
    ) {
        self.events = events
        self.returnMismatchedProof = returnMismatchedProof
        self.exitGate = exitGate
    }

    func registerExitObservation(
        for preparedHelper: GemmaPreparedHelperExit
    ) async throws -> any GemmaAuthenticatedHelperExitObservation {
        events.record("registerExitObservation")
        return TestExitObservation(
            events: events,
            preparedHelper: preparedHelper,
            returnMismatchedProof: returnMismatchedProof,
            exitGate: exitGate
        )
    }
}

private final class TestExitObservation: GemmaAuthenticatedHelperExitObservation, @unchecked Sendable {
    let preparedHelper: GemmaPreparedHelperExit

    private let events: EventLog
    private let returnMismatchedProof: Bool
    private let exitGate: AsyncGate<Void>?

    init(
        events: EventLog,
        preparedHelper: GemmaPreparedHelperExit,
        returnMismatchedProof: Bool,
        exitGate: AsyncGate<Void>?
    ) {
        self.events = events
        self.preparedHelper = preparedHelper
        self.returnMismatchedProof = returnMismatchedProof
        self.exitGate = exitGate
    }

    func waitForExit() async throws -> GemmaAuthenticatedHelperExitProof {
        events.record("waitForExit")
        if let exitGate {
            await exitGate.wait()
        }
        let proofHelper: GemmaPreparedHelperExit
        if returnMismatchedProof {
            proofHelper = GemmaPreparedHelperExit(
                helperInstanceID: UUID(),
                processIdentifier: preparedHelper.processIdentifier
            )
        } else {
            proofHelper = preparedHelper
        }
        return GemmaAuthenticatedHelperExitProof(
            preparedHelper: proofHelper,
            event: .exit
        )
    }

    func invalidate() {
        exitGate?.resolve(())
    }
}

private enum TestTransportError: Error {
    case applicationFailed
    case noConfiguredTransport
    case requestIDMismatch
}

private final class ManualDeadline: GemmaClientDeadline, @unchecked Sendable {
    private struct Waiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var waiters: [GemmaClientDeadlineOperation: [Waiter]] = [:]
    private var registrations: [
        GemmaClientDeadlineOperation: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []

    func waitUntilExpired(for operation: GemmaClientDeadlineOperation) async {
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let registrationResult: (
                    shouldResume: Bool,
                    waiters: [CheckedContinuation<Void, Never>]
                ) = lock.withLock {
                    if Task.isCancelled || cancelledBeforeRegistration.remove(identifier) != nil {
                        return (true, [])
                    }
                    waiters[operation, default: []].append(
                        Waiter(identifier: identifier, continuation: continuation)
                    )
                    let registrationWaiters = registrations.removeValue(forKey: operation) ?? []
                    return (false, registrationWaiters)
                }
                for registrationWaiter in registrationResult.waiters {
                    registrationWaiter.resume()
                }
                if registrationResult.shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            cancel(identifier: identifier, operation: operation)
        }
    }

    func waitUntilRegistered(_ operation: GemmaClientDeadlineOperation) async {
        await withCheckedContinuation { continuation in
            let alreadyRegistered = lock.withLock {
                if waiters[operation]?.isEmpty == false {
                    return true
                }
                registrations[operation, default: []].append(continuation)
                return false
            }
            if alreadyRegistered {
                continuation.resume()
            }
        }
    }

    func expire(_ operation: GemmaClientDeadlineOperation) {
        let continuations = lock.withLock {
            waiters.removeValue(forKey: operation)?.map(\.continuation) ?? []
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waiterCount(for operation: GemmaClientDeadlineOperation) -> Int {
        lock.withLock { waiters[operation]?.count ?? 0 }
    }

    private func cancel(identifier: UUID, operation: GemmaClientDeadlineOperation) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard var operationWaiters = waiters[operation],
                  let index = operationWaiters.firstIndex(where: { $0.identifier == identifier })
            else {
                cancelledBeforeRegistration.insert(identifier)
                return nil
            }
            let waiter = operationWaiters.remove(at: index)
            waiters[operation] = operationWaiters
            return waiter.continuation
        }
        continuation?.resume()
    }
}

private final class AsyncGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var continuations: [CheckedContinuation<Value, Never>] = []

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let resolvedValue: Value? = lock.withLock {
                if let value {
                    return value
                }
                continuations.append(continuation)
                return nil
            }
            if let resolvedValue {
                continuation.resume(returning: resolvedValue)
            }
        }
    }

    func resolve(_ value: Value) {
        let pendingContinuations: [CheckedContinuation<Value, Never>] = lock.withLock {
            guard self.value == nil else {
                return [] as [CheckedContinuation<Value, Never>]
            }
            self.value = value
            let pendingContinuations = continuations
            continuations.removeAll()
            return pendingContinuations
        }
        for continuation in pendingContinuations {
            continuation.resume(returning: value)
        }
    }
}

private final class EventLog: @unchecked Sendable {
    private struct Waiter {
        let event: String
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var events: [String] = []
    private var waiters: [Waiter] = []

    func record(_ event: String) {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            events.append(event)
            var matched: [CheckedContinuation<Void, Never>] = []
            waiters.removeAll { waiter in
                guard events.lazy.filter({ $0 == waiter.event }).count >= waiter.count else {
                    return false
                }
                matched.append(waiter.continuation)
                return true
            }
            return matched
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitUntilPresent(_ event: String) async {
        await withCheckedContinuation { continuation in
            let alreadyPresent = lock.withLock {
                if events.contains(event) {
                    return true
                }
                waiters.append(Waiter(event: event, count: 1, continuation: continuation))
                return false
            }
            if alreadyPresent {
                continuation.resume()
            }
        }
    }

    func waitUntilCount(_ event: String, reaches count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyPresent = lock.withLock {
                if events.lazy.filter({ $0 == event }).count >= count {
                    return true
                }
                waiters.append(Waiter(event: event, count: count, continuation: continuation))
                return false
            }
            if alreadyPresent {
                continuation.resume()
            }
        }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}
