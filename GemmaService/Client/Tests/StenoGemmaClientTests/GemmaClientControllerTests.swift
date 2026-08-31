import Darwin
import Foundation
@testable import StenoGemmaClient
import StenoGemmaIPC
import Testing

@Suite("Gemma client recording barrier")
struct GemmaClientControllerTests {
    @Test("one high-level session shares one transport and retires it on return")
    func sharedTransportAndAutomaticRetirement() async throws {
        let events = EventLog()
        let transport = TestTransport(events: events)
        let factory = TestTransportFactory(transport: transport, events: events)
        let controller = try makeController(factory: factory, events: events)

        try await controller.withModelSession(model: try modelPin()) { session in
            _ = try await session.send(try handshakeBody())
            _ = try await session.send(try tokenCountBody())
            _ = try await session.send(try generationBody(prompt: "one helper"))
            #expect(factory.creationCount == 1)
            #expect(await controller.lifecycleState() == .active)
            await #expect(throws: GemmaClientControllerError.modelSessionActive) {
                try await controller.withModelSession(model: try modelPin()) { _ in () }
            }
        }

        #expect(factory.creationCount == 1)
        #expect(events.count(of: "invalidate") == 1)
        #expect(await controller.lifecycleState() == .idle)
    }

    @Test("a retained session token cannot outlive its closure")
    func retainedTokenIsRejected() async throws {
        let events = EventLog()
        let controller = try makeController(
            factory: TestTransportFactory(transport: TestTransport(events: events), events: events),
            events: events
        )
        let retained = try await controller.withModelSession(model: try modelPin()) { session in session }
        await #expect(throws: GemmaClientControllerError.modelSessionInactive) {
            try await retained.send(try generationBody(prompt: "late"))
        }
    }

    @Test("a session rejects a different model pin before factory creation or transport send")
    func mixedModelPinsAreRejectedBeforeTransportUse() async throws {
        let events = EventLog()
        let transport = TestTransport(events: events)
        let factory = TestTransportFactory(transport: transport, events: events)
        let controller = try makeController(factory: factory, events: events)
        let sessionModel = try modelPin()
        let otherModel = try alternateModelPin()

        try await controller.withModelSession(model: sessionModel) { session in
            #expect(session.model == sessionModel)
            await #expect(throws: GemmaClientControllerError.modelPinMismatch) {
                try await session.send(try generationBody(model: otherModel, prompt: "wrong before factory"))
            }
            #expect(factory.creationCount == 0)
            #expect(events.count(of: "send:generate") == 0)

            _ = try await session.send(try generationBody(model: sessionModel, prompt: "right"))
            #expect(factory.creationCount == 1)
            #expect(factory.requestedModels == [sessionModel])
            #expect(events.count(of: "send:generate") == 1)

            await #expect(throws: GemmaClientControllerError.modelPinMismatch) {
                try await session.send(try generationBody(model: otherModel, prompt: "wrong after factory"))
            }
            #expect(factory.creationCount == 1)
            #expect(events.count(of: "send:generate") == 1)
        }
    }

    @Test("throwing and cancellation each retire the helper exactly once")
    func terminalClosurePathsRetireExactlyOnce() async throws {
        let throwingEvents = EventLog()
        let throwingTransport = TestTransport(events: throwingEvents)
        let throwingController = try makeController(
            factory: TestTransportFactory(transport: throwingTransport, events: throwingEvents),
            events: throwingEvents
        )
        await #expect(throws: SessionTestError.expected) {
            try await throwingController.withModelSession(model: try modelPin()) { session in
                _ = try await session.send(try generationBody(prompt: "then throw"))
                throw SessionTestError.expected
            }
        }
        #expect(throwingEvents.count(of: "invalidate") == 1)

        let cancellingEvents = EventLog()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let cancellingTransport = TestTransport(events: cancellingEvents, applicationGate: applicationGate)
        let cancellingController = try makeController(
            factory: TestTransportFactory(transport: cancellingTransport, events: cancellingEvents),
            events: cancellingEvents
        )
        let task = Task {
            try await cancellingController.withModelSession(model: try modelPin()) { session in
                _ = try await session.send(try generationBody(prompt: "cancel"))
            }
        }
        await cancellingEvents.waitUntilPresent("send:generate")
        task.cancel()
        await #expect(throws: GemmaClientControllerError.requestCancelled) { try await task.value }
        #expect(cancellingEvents.count(of: "invalidate") == 1)
        applicationGate.resolve(.generate(GemmaIPCGenerateResponse(text: "late")))
    }

    @Test("recording waits on automatic retirement without an idle admission gap")
    func recordingWaitsForRetirementWithoutIdleGap() async throws {
        let events = EventLog()
        let exitGate = AsyncGate<Void>()
        let controller = try makeController(
            factory: TestTransportFactory(transport: TestTransport(events: events), events: events),
            events: events,
            exitProver: TestExitProver(events: events, exitGate: exitGate)
        )
        let modelTask = Task {
            try await controller.withModelSession(model: try modelPin()) { session in
                _ = try await session.send(try generationBody(prompt: "retire"))
            }
        }
        await events.waitUntilPresent("waitForExit")
        #expect(await controller.lifecycleState() == .retiring)
        await #expect(throws: GemmaClientControllerError.modelSessionRetiring) {
            try await controller.withModelSession(model: try modelPin()) { _ in () }
        }

        let leaseToken = GemmaRecordingLease()
        let recordingTask = Task { try await controller.acquireRecordingLease(leaseToken) }
        await Task.yield()
        #expect(await controller.lifecycleState() == .retiring)
        exitGate.resolve(())
        _ = try await recordingTask.value
        try await modelTask.value
        #expect(await controller.lifecycleState() == .recording)
        try await controller.releaseRecordingLease(leaseToken)
    }

    @Test("recording preempts an active session and preserves request cancellation")
    func recordingPreemptsActiveSession() async throws {
        let events = EventLog()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let controller = try makeController(
            factory: TestTransportFactory(
                transport: TestTransport(events: events, applicationGate: applicationGate),
                events: events
            ),
            events: events
        )
        let modelTask = Task {
            try await controller.withModelSession(model: try modelPin()) { session in
                _ = try await session.send(try generationBody(prompt: "recording wins"))
            }
        }
        await events.waitUntilPresent("send:generate")
        let lease = try await controller.acquireRecordingLease(GemmaRecordingLease())
        await #expect(throws: GemmaClientControllerError.cancelledForRecording) {
            try await modelTask.value
        }
        #expect(events.count(of: "invalidate") == 1)
        #expect(await controller.lifecycleState() == .recording)
        try await controller.releaseRecordingLease(lease)
        applicationGate.resolve(.generate(GemmaIPCGenerateResponse(text: "late")))
    }

    @Test("recording preempts model preparation before gate acquisition or helper activation")
    func recordingPreemptsBlockedPreparation() async throws {
        let events = EventLog()
        let preparationGate = AsyncGate<Void>()
        let factory = TestTransportFactory(
            transport: TestTransport(events: events),
            events: events,
            preparationGate: preparationGate
        )
        let controller = try makeController(factory: factory, events: events)

        let modelTask = Task {
            try await controller.withModelSession(model: try modelPin()) { session in
                _ = try await session.send(try generationBody(prompt: "preparation"))
            }
        }
        await events.waitUntilPresent("prepareTransport")

        let lease = try await controller.acquireRecordingLease(GemmaRecordingLease())
        #expect(await controller.lifecycleState() == .recording)
        #expect(events.count(of: "activateTransport") == 0)
        await #expect(throws: GemmaClientControllerError.cancelledForRecording) {
            try await modelTask.value
        }

        preparationGate.resolve(())
        await events.waitUntilPresent("invalidatePreparation")
        #expect(events.count(of: "activateTransport") == 0)
        #expect(events.count(of: "invalidatePreparation") == 1)
        try await controller.releaseRecordingLease(lease)
    }

    @Test("concurrent first requests share one model preparation and transport activation")
    func concurrentFirstRequestsSharePreparation() async throws {
        let events = EventLog()
        let preparationGate = AsyncGate<Void>()
        let factory = TestTransportFactory(
            transport: TestTransport(events: events),
            events: events,
            preparationGate: preparationGate
        )
        let controller = try makeController(factory: factory, events: events)

        try await controller.withModelSession(model: try modelPin()) { session in
            let first = Task {
                try await session.send(try generationBody(prompt: "first preparation waiter"))
            }
            let second = Task {
                try await session.send(try generationBody(prompt: "second preparation waiter"))
            }
            await events.waitUntilPresent("prepareTransport")
            await Task.yield()
            preparationGate.resolve(())
            _ = try await first.value
            _ = try await second.value
        }

        #expect(events.count(of: "prepareTransport") == 1)
        #expect(events.count(of: "activateTransport") == 1)
        #expect(factory.creationCount == 1)
    }

    @Test("session activation has a distinct deadline before request execution begins")
    func activationUsesDistinctDeadline() async throws {
        let events = EventLog()
        let bindGate = AsyncGate<Void>()
        let requestDeadline = ManualDeadline()
        let activationDeadline = ManualDeadline()
        let controller = try makeController(
            factory: TestTransportFactory(
                transport: TestTransport(events: events, bindGate: bindGate),
                events: events
            ),
            events: events,
            deadline: requestDeadline,
            activationDeadline: activationDeadline
        )

        let task = Task {
            try await controller.send(try generationBody(prompt: "slow activation"))
        }
        await events.waitUntilPresent("bindSession")
        await activationDeadline.waitUntilRegistered(.sessionActivation)
        #expect(requestDeadline.waiterCount(for: .request) == 0)

        activationDeadline.expire(.sessionActivation)
        await #expect(throws: GemmaClientControllerError.timedOut(.sessionActivation)) {
            try await task.value
        }
        #expect(await controller.lifecycleState() == .faulted)
        #expect(events.count(of: "send:generate") == 0)
        #expect(events.count(of: "invalidate") == 1)
        bindGate.resolve(())
    }

    @Test("caller cancellation during activation retires without fault or relaunch")
    func activationCancellationRemainsARequestCancellation() async throws {
        let events = EventLog()
        let bindGate = AsyncGate<Void>()
        let firstTransport = TestTransport(events: events, bindGate: bindGate)
        let secondTransport = TestTransport(events: events)
        let factory = TestTransportFactory(
            transports: [firstTransport, secondTransport],
            events: events
        )
        let controller = try makeController(factory: factory, events: events)

        let task = Task {
            try await controller.send(try generationBody(prompt: "cancel activation"))
        }
        await events.waitUntilPresent("bindSession")
        task.cancel()

        await #expect(throws: GemmaClientControllerError.requestCancelled) {
            try await task.value
        }
        #expect(events.count(of: "invalidate") == 1)
        #expect(await controller.lifecycleState() == .idle)

        _ = try await controller.send(try generationBody(prompt: "new explicit session"))
        #expect(factory.creationCount == 2)
        #expect(events.count(of: "send:generate") == 1)
        #expect(events.count(of: "invalidate") == 2)
        #expect(await controller.lifecycleState() == .idle)
    }

    @Test("the ordinary request deadline starts only after activation succeeds")
    func requestDeadlineStartsAfterActivation() async throws {
        let events = EventLog()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let requestDeadline = ManualDeadline()
        let activationDeadline = ManualDeadline()
        let controller = try makeController(
            factory: TestTransportFactory(
                transport: TestTransport(events: events, applicationGate: applicationGate),
                events: events
            ),
            events: events,
            deadline: requestDeadline,
            activationDeadline: activationDeadline
        )

        let task = Task {
            try await controller.send(try generationBody(prompt: "request timeout"))
        }
        await events.waitUntilPresent("send:generate")
        await requestDeadline.waitUntilRegistered(.request)
        #expect(activationDeadline.waiterCount(for: .sessionActivation) == 0)

        requestDeadline.expire(.request)
        await #expect(throws: GemmaClientControllerError.timedOut(.request)) {
            try await task.value
        }
        applicationGate.resolve(.generate(.init(text: "late")))
    }

    @Test("process-gate contention is recoverable and does not start a helper")
    func gateBusyFactoryAdmissionIsRecoverable() async throws {
        let events = EventLog()
        let transport = TestTransport(events: events)
        let factory = TestTransportFactory(
            transport: transport,
            events: events,
            failFirstWithExecutionGateBusy: true
        )
        let controller = try makeController(factory: factory, events: events)

        await #expect(throws: GemmaClientControllerError.modelAdmissionBusy) {
            try await controller.send(try generationBody(prompt: "busy"))
        }
        #expect(factory.creationCount == 0)
        #expect(await controller.lifecycleState() == .idle)
        _ = try await controller.send(try generationBody(prompt: "recovered"))
        #expect(factory.creationCount == 1)
    }

    @Test("the in-flight limit remains strict inside one shared session")
    func inFlightLimitRemainsStrict() async throws {
        let events = EventLog()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let transport = TestTransport(events: events, applicationGate: applicationGate)
        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: TestTransportFactory(transport: transport, events: events),
            exitProver: TestExitProver(events: events),
            deadline: ManualDeadline()
        )

        try await controller.withModelSession(model: try modelPin()) { session in
            let first = Task { try await session.send(try generationBody(prompt: "first")) }
            await events.waitUntilPresent("send:generate")
            await #expect(throws: GemmaClientControllerError.busy(limit: 1)) {
                try await session.send(try generationBody(prompt: "second"))
            }
            applicationGate.resolve(.generate(GemmaIPCGenerateResponse(text: "first")))
            _ = try await first.value
        }
    }

    @Test("recording proceeds when automatic retirement faults the model side")
    func recordingSurvivesRetirementFailure() async throws {
        let events = EventLog()
        let controller = try makeController(
            factory: TestTransportFactory(
                transport: TestTransport(events: events, armReturnsMismatch: true),
                events: events
            ),
            events: events
        )
        let modelTask = Task {
            try await controller.withModelSession(model: try modelPin()) { session in
                _ = try await session.send(try generationBody(prompt: "fail retirement"))
            }
        }
        await events.waitUntilPresent("armAndExit")
        let lease = try await controller.acquireRecordingLease(GemmaRecordingLease())
        await #expect(throws: GemmaClientControllerError.exitArmMismatch) {
            try await modelTask.value
        }
        #expect(await controller.lifecycleState() == .recording)
        await #expect(throws: GemmaClientControllerError.faulted) {
            try await controller.releaseRecordingLease(lease)
        }
        #expect(await controller.lifecycleState() == .faulted)
    }

    @Test("a bounded hanging shutdown still retires after the exact exit proof")
    func hangingShutdownUsesExitProof() async throws {
        let events = EventLog()
        let deadline = ManualDeadline()
        let shutdownGate = AsyncGate<GemmaIPCResponseBody>()
        let hold = AsyncGate<Void>()
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: TestTransportFactory(
                transport: TestTransport(events: events, shutdownGate: shutdownGate),
                events: events
            ),
            exitProver: TestExitProver(events: events),
            deadline: deadline
        )
        let modelTask = Task {
            try await controller.withModelSession(model: try modelPin()) { session in
                _ = try await session.send(try generationBody(prompt: "connect"))
                events.record("connected")
                await hold.wait()
            }
        }
        await events.waitUntilPresent("connected")
        let leaseTask = Task { try await controller.acquireRecordingLease(GemmaRecordingLease()) }
        await events.waitUntilPresent("send:shutdown")
        await deadline.waitUntilRegistered(.quiescentShutdown)
        deadline.expire(.quiescentShutdown)
        let lease = try await leaseTask.value
        #expect(events.count(of: "invalidate") == 1)
        hold.resolve(())
        try await modelTask.value
        try await controller.releaseRecordingLease(lease)
        shutdownGate.resolve(.acknowledgement(.init(kind: .shutdown, didChangeState: true)))
    }

    @Test("all cancellation and shutdown traffic shares one quiescence deadline")
    func quiescenceUsesOneSharedDeadline() async throws {
        let events = EventLog()
        let deadline = ManualDeadline()
        let applicationGate = AsyncGate<GemmaIPCResponseBody>()
        let quiescenceGate = AsyncGate<Void>()
        let hold = AsyncGate<Void>()
        let controller = try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: TestTransportFactory(
                transport: TestTransport(
                    events: events,
                    applicationGate: applicationGate,
                    quiescenceGate: quiescenceGate
                ),
                events: events
            ),
            exitProver: TestExitProver(events: events),
            deadline: deadline
        )
        let modelTask = Task {
            try await controller.withModelSession(model: try modelPin()) { session in
                let first = Task { try await session.send(try generationBody(prompt: "first")) }
                let second = Task { try await session.send(try generationBody(prompt: "second")) }
                await events.waitUntilCount("send:generate", reaches: 2)
                await hold.wait()
                _ = try await first.value
                _ = try await second.value
            }
        }
        await events.waitUntilCount("send:generate", reaches: 2)
        let leaseTask = Task { try await controller.acquireRecordingLease(GemmaRecordingLease()) }
        await events.waitUntilCount("send:cancel", reaches: 2)
        await events.waitUntilPresent("send:shutdown")
        await deadline.waitUntilRegistered(.quiescentShutdown)
        #expect(deadline.waiterCount(for: .quiescentShutdown) == 1)
        deadline.expire(.quiescentShutdown)
        let lease = try await leaseTask.value
        hold.resolve(())
        await #expect(throws: GemmaClientControllerError.cancelledForRecording) {
            try await modelTask.value
        }
        try await controller.releaseRecordingLease(lease)
        quiescenceGate.resolve(())
        applicationGate.resolve(.generate(.init(text: "late")))
    }

    @Test("an unproven exit faults the model side without stranding recording")
    func unprovenExitFaultsAfterRecordingAdmission() async throws {
        let events = EventLog()
        let deadline = ManualDeadline()
        let exitGate = AsyncGate<Void>()
        let hold = AsyncGate<Void>()
        let controller = try GemmaClientController(
            maximumInFlightRequests: 1,
            transportFactory: TestTransportFactory(transport: TestTransport(events: events), events: events),
            exitProver: TestExitProver(events: events, exitGate: exitGate),
            deadline: deadline
        )
        let modelTask = Task {
            try await controller.withModelSession(model: try modelPin()) { session in
                _ = try await session.send(try generationBody(prompt: "connect"))
                events.record("modelClosureHolding")
                await hold.wait()
            }
        }
        await events.waitUntilPresent("modelClosureHolding")
        let leaseTask = Task { try await controller.acquireRecordingLease(GemmaRecordingLease()) }
        await events.waitUntilPresent("waitForExit")
        await deadline.waitUntilRegistered(.authenticatedHelperExit)
        deadline.expire(.authenticatedHelperExit)
        let lease = try await leaseTask.value
        hold.resolve(())
        await #expect(throws: GemmaClientControllerError.timedOut(.authenticatedHelperExit)) {
            try await modelTask.value
        }
        await #expect(throws: GemmaClientControllerError.faulted) {
            try await controller.releaseRecordingLease(lease)
        }
        #expect(await controller.lifecycleState() == .faulted)
        exitGate.resolve(())
    }

    @Test("mismatched arm and authenticated proof fault the originating session")
    func authenticatedRetirementIdentityMismatchesFault() async throws {
        let armEvents = EventLog()
        let armController = try makeController(
            factory: TestTransportFactory(
                transport: TestTransport(events: armEvents, armReturnsMismatch: true),
                events: armEvents
            ),
            events: armEvents
        )
        await #expect(throws: GemmaClientControllerError.exitArmMismatch) {
            try await armController.send(try generationBody(prompt: "arm mismatch"))
        }
        #expect(await armController.lifecycleState() == .faulted)

        let proofEvents = EventLog()
        let proofController = try makeController(
            factory: TestTransportFactory(transport: TestTransport(events: proofEvents), events: proofEvents),
            events: proofEvents,
            exitProver: TestExitProver(events: proofEvents, returnMismatchedProof: true)
        )
        await #expect(throws: GemmaClientControllerError.authenticatedExitProofMismatch) {
            try await proofController.send(try generationBody(prompt: "proof mismatch"))
        }
        #expect(await proofController.lifecycleState() == .faulted)
    }

    @Test("an infrastructure request failure resolves its caller before faulting")
    func infrastructureFailureResolvesCurrentCaller() async throws {
        let events = EventLog()
        let controller = try makeController(
            factory: TestTransportFactory(
                transport: TestTransport(events: events, applicationShouldFail: true),
                events: events
            ),
            events: events
        )
        await #expect(throws: GemmaClientControllerError.operationFailed(.request)) {
            try await controller.send(try generationBody(prompt: "infrastructure"))
        }
        #expect(await controller.lifecycleState() == .faulted)
        #expect(events.count(of: "invalidate") == 1)
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

    private func makeController(
        factory: TestTransportFactory,
        events: EventLog,
        exitProver: TestExitProver? = nil,
        deadline: (any GemmaClientDeadline)? = nil,
        activationDeadline: (any GemmaClientDeadline)? = nil
    ) throws -> GemmaClientController {
        let requestDeadline = deadline ?? ManualDeadline()
        return try GemmaClientController(
            maximumInFlightRequests: 2,
            transportFactory: factory,
            exitProver: exitProver ?? TestExitProver(events: events),
            deadline: requestDeadline,
            activationDeadline: activationDeadline ?? requestDeadline
        )
    }
}

private func generationBody(
    model: GemmaModelSnapshotPin,
    prompt: String
) throws -> GemmaIPCRequestBody {
    return .generate(
        try GemmaIPCGenerateRequest(
            model: model,
            prompt: prompt,
            maximumTokens: 32
        )
    )
}

private func generationBody(prompt: String) throws -> GemmaIPCRequestBody {
    try generationBody(model: modelPin(), prompt: prompt)
}

private func handshakeBody() throws -> GemmaIPCRequestBody {
    .handshake(.init(model: try modelPin()))
}

private func tokenCountBody() throws -> GemmaIPCRequestBody {
    .countTokens(try .init(model: modelPin(), text: "count this"))
}

private func modelPin() throws -> GemmaModelSnapshotPin {
    try GemmaModelSnapshotPin(
        modelIdentifier: "google/gemma-4-1b-it",
        checkpointRevision: String(repeating: "a", count: 40),
        adapterRevision: GemmaIPCBuildInfo.adapterRevision,
        licenseIdentifier: "gemma",
        manifestSHA256: String(repeating: "b", count: 64)
    )
}

private func alternateModelPin() throws -> GemmaModelSnapshotPin {
    try GemmaModelSnapshotPin(
        modelIdentifier: "google/gemma-4-2b-it",
        checkpointRevision: String(repeating: "c", count: 40),
        adapterRevision: GemmaIPCBuildInfo.adapterRevision,
        licenseIdentifier: "gemma",
        manifestSHA256: String(repeating: "d", count: 64)
    )
}

private enum SessionTestError: Error {
    case expected
}

private final class TestTransportFactory: GemmaClientTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let transports: [TestTransport]
    private let events: EventLog
    private let failFirstWithExecutionGateBusy: Bool
    private let preparationGate: AsyncGate<Void>?
    private var storedCreationCount = 0
    private var storedRequestedModels: [GemmaModelSnapshotPin] = []
    private var didFailForExecutionGateBusy = false

    init(
        transport: TestTransport,
        events: EventLog,
        failFirstWithExecutionGateBusy: Bool = false,
        preparationGate: AsyncGate<Void>? = nil
    ) {
        self.transports = [transport]
        self.events = events
        self.failFirstWithExecutionGateBusy = failFirstWithExecutionGateBusy
        self.preparationGate = preparationGate
    }

    init(transports: [TestTransport], events: EventLog) {
        self.transports = transports
        self.events = events
        failFirstWithExecutionGateBusy = false
        preparationGate = nil
    }

    var creationCount: Int {
        lock.withLock { storedCreationCount }
    }

    var requestedModels: [GemmaModelSnapshotPin] {
        lock.withLock { storedRequestedModels }
    }

    func prepareTransport(
        for model: GemmaModelSnapshotPin
    ) async throws -> any GemmaClientTransportPreparation {
        events.record("prepareTransport")
        if let preparationGate {
            await preparationGate.wait()
        }
        let outcome: TestTransportPreparation.Outcome = try lock.withLock {
            if failFirstWithExecutionGateBusy, !didFailForExecutionGateBusy {
                didFailForExecutionGateBusy = true
                return .executionGateBusy
            }
            guard storedCreationCount < transports.count else {
                throw TestTransportError.noConfiguredTransport
            }
            let transport = transports[storedCreationCount]
            storedCreationCount += 1
            storedRequestedModels.append(model)
            return .transport(transport)
        }
        return TestTransportPreparation(model: model, outcome: outcome, events: events)
    }
}

private final class TestTransportPreparation:
    GemmaClientTransportPreparation,
    @unchecked Sendable
{
    enum Outcome {
        case transport(TestTransport)
        case executionGateBusy
    }

    let model: GemmaModelSnapshotPin

    private let lock = NSLock()
    private let outcome: Outcome
    private let events: EventLog
    private var consumed = false

    init(model: GemmaModelSnapshotPin, outcome: Outcome, events: EventLog) {
        self.model = model
        self.outcome = outcome
        self.events = events
    }

    func activate() throws -> any GemmaClientTransport {
        let canActivate = lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
        guard canActivate else {
            throw TestTransportError.noConfiguredTransport
        }
        events.record("activateTransport")
        switch outcome {
        case .transport(let transport):
            return transport
        case .executionGateBusy:
            throw GemmaRawXPCTransportError.executionGateBusy
        }
    }

    func invalidate() {
        let didInvalidate = lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
        if didInvalidate {
            events.record("invalidatePreparation")
        }
    }
}

private final class TestTransport: GemmaClientTransport, @unchecked Sendable {
    private let events: EventLog
    private let helperInstanceID: UUID
    private let bindGate: AsyncGate<Void>?
    private let applicationGate: AsyncGate<GemmaIPCResponseBody>?
    private let shutdownGate: AsyncGate<GemmaIPCResponseBody>?
    private let quiescenceGate: AsyncGate<Void>?
    private let prepareGate: AsyncGate<Void>?
    private let armReturnsMismatch: Bool
    private let applicationShouldFail: Bool

    init(
        events: EventLog,
        helperInstance: UUID = UUID(),
        bindGate: AsyncGate<Void>? = nil,
        applicationGate: AsyncGate<GemmaIPCResponseBody>? = nil,
        shutdownGate: AsyncGate<GemmaIPCResponseBody>? = nil,
        quiescenceGate: AsyncGate<Void>? = nil,
        prepareGate: AsyncGate<Void>? = nil,
        armReturnsMismatch: Bool = false,
        applicationShouldFail: Bool = false
    ) {
        self.events = events
        self.helperInstanceID = helperInstance
        self.bindGate = bindGate
        self.applicationGate = applicationGate
        self.shutdownGate = shutdownGate
        self.quiescenceGate = quiescenceGate
        self.prepareGate = prepareGate
        self.armReturnsMismatch = armReturnsMismatch
        self.applicationShouldFail = applicationShouldFail
    }

    func bindSession() async throws {
        events.record("bindSession")
        if let bindGate {
            await bindGate.wait()
        }
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
        bindGate?.resolve(())
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

    func count(of event: String) -> Int {
        lock.withLock { events.lazy.filter { $0 == event }.count }
    }
}
