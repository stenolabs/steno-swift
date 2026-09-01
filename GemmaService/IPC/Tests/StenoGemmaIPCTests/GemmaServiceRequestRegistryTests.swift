import Foundation
import Testing
import StenoGemmaIPC
@testable import StenoGemmaServiceCore

@Suite("Gemma service request registry")
struct GemmaServiceRequestRegistryTests {
    private let cancelled = Data("cancelled".utf8)
    private let normal = Data("normal".utf8)

    @Test("active request IDs are unique and stale tickets cannot finish a replacement")
    func activeRequestIDsAreUnique() throws {
        let registry = makeRegistry()
        let requestID = UUID()
        let firstReplies = LockedResponses()
        let first = try admitted(registry.reserveWork(
            requestID: requestID,
            inferenceLike: false,
            cancellationResponse: cancelled,
            reply: firstReplies.replyOnce
        ))

        #expect(registry.reserveLifecycle(
            requestID: requestID,
            reply: LockedResponses().replyOnce
        ) == .duplicateRequestID)
        #expect(registry.complete(first, response: normal))
        #expect(firstReplies.values == [normal])

        let secondReplies = LockedResponses()
        let second = try admitted(registry.reserveWork(
            requestID: requestID,
            inferenceLike: false,
            cancellationResponse: cancelled,
            reply: secondReplies.replyOnce
        ))
        #expect(!registry.complete(first, response: Data("stale".utf8)))
        #expect(registry.activeRequestCount == 1)
        #expect(registry.complete(second, response: normal))
        #expect(secondReplies.values == [normal])
    }

    @Test("only one inference-like request is admitted at a time")
    func oneInferenceAtATime() throws {
        let registry = makeRegistry()
        let first = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ))

        #expect(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ) == .busy)

        let metadata = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: false,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ))
        #expect(registry.cancel(first.requestID))

        let replacement = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ))
        #expect(registry.complete(metadata, response: normal))
        #expect(registry.complete(replacement, response: normal))
        #expect(registry.isWorkQuiescent)
    }

    @Test("active work and lifecycle request bounds are enforced independently")
    func activeRequestBoundsAreEnforced() throws {
        let registry = makeRegistry()
        var workTickets: [GemmaServiceRequestRegistry.Ticket] = []
        for _ in 0 ..< GemmaServiceRequestRegistry.maximumActiveWorkRequests {
            workTickets.append(try admitted(registry.reserveWork(
                requestID: UUID(),
                inferenceLike: false,
                cancellationResponse: cancelled,
                reply: LockedResponses().replyOnce
            )))
        }
        #expect(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: false,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ) == .busy)

        var lifecycleTickets: [GemmaServiceRequestRegistry.Ticket] = []
        for _ in 0 ..< GemmaServiceRequestRegistry.maximumActiveLifecycleRequests {
            lifecycleTickets.append(try admitted(registry.reserveLifecycle(
                requestID: UUID(),
                reply: LockedResponses().replyOnce
            )))
        }
        #expect(registry.reserveLifecycle(
            requestID: UUID(),
            reply: LockedResponses().replyOnce
        ) == .busy)

        for ticket in workTickets + lifecycleTickets {
            #expect(registry.complete(ticket, response: normal))
        }
        #expect(registry.activeRequestCount == 0)
    }

    @Test("cancel before start prevents execution and replies once")
    func cancelBeforeStart() throws {
        let registry = makeRegistry()
        let replies = LockedResponses()
        let execution = ManualExecution(resumeOnCancellation: true)
        let ticket = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: replies.replyOnce
        ))

        #expect(registry.cancel(ticket.requestID))
        #expect(!registry.start(ticket) { await execution.run(output: self.normal) })
        #expect(execution.invocationCount == 0)
        #expect(replies.values == [cancelled])
        #expect(registry.isWorkQuiescent)
    }

    @Test("cancel while running wins exactly once and waits for task return")
    func cancelWhileRunning() async throws {
        let registry = makeRegistry()
        let replies = LockedResponses()
        let execution = ManualExecution(resumeOnCancellation: true)
        let ticket = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: replies.replyOnce
        ))
        #expect(registry.start(ticket) { await execution.run(output: self.normal) })
        await execution.waitUntilStarted()

        #expect(registry.cancel(ticket.requestID))
        #expect(!registry.cancel(ticket.requestID))
        await registry.waitForWorkQuiescence()

        #expect(execution.invocationCount == 1)
        #expect(replies.values == [cancelled])
        #expect(registry.activeRequestCount == 0)
    }

    @Test("cancelled inference keeps its exclusive slot until the task returns")
    func cancelledInferenceRetainsSlotUntilReturn() async throws {
        let registry = makeRegistry()
        let execution = ManualExecution(resumeOnCancellation: false)
        let ticket = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ))
        #expect(registry.start(ticket) { await execution.run(output: self.normal) })
        await execution.waitUntilStarted()

        #expect(registry.cancel(ticket.requestID))
        #expect(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ) == .busy)

        execution.finish()
        await registry.waitForWorkQuiescence()

        let replacement = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ))
        #expect(registry.complete(replacement, response: normal))
    }

    @Test("normal completion wins a later cancel and replies once")
    func completionWinsCancelRace() async throws {
        let registry = makeRegistry()
        let replies = LockedResponses()
        let execution = ManualExecution(resumeOnCancellation: false)
        let ticket = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: replies.replyOnce
        ))
        #expect(registry.start(ticket) { await execution.run(output: self.normal) })
        await execution.waitUntilStarted()

        execution.finish()
        await registry.waitForWorkQuiescence()

        #expect(!registry.cancel(ticket.requestID))
        #expect(replies.values == [normal])
    }

    @Test("prepare closes admission and cannot finish or arm before true quiescence")
    func prepareWaitsForTrueQuiescence() async throws {
        let identity = helperIdentity()
        let registry = GemmaServiceRequestRegistry(helperIdentity: identity)
        let replies = LockedResponses()
        let execution = ManualExecution(resumeOnCancellation: false)
        let ticket = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: replies.replyOnce
        ))
        #expect(registry.start(ticket) { await execution.run(output: self.normal) })
        await execution.waitUntilStarted()

        #expect(registry.beginPrepareForExit() == .accepted(identity))
        #expect(replies.values == [cancelled])
        #expect(!registry.isWorkQuiescent)
        #expect(registry.finishPrepareForExit() == nil)
        #expect(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: false,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ) == .shuttingDown)

        let prematureArm = try admitted(registry.reserveLifecycle(
            requestID: UUID(),
            reply: LockedResponses().replyOnce
        ))
        #expect(!registry.beginArmAndExit(identity, armRequest: prematureArm))
        #expect(registry.complete(prematureArm, response: normal))

        let drain = Task { await registry.waitForWorkQuiescence() }
        execution.finish()
        await drain.value
        #expect(registry.finishPrepareForExit() == identity)

        let arm = try admitted(registry.reserveLifecycle(
            requestID: UUID(),
            reply: LockedResponses().replyOnce
        ))
        #expect(registry.beginArmAndExit(identity, armRequest: arm))
        await registry.waitUntilReadyToArm(excluding: arm)
        #expect(registry.finishArmAndExit(identity, armRequest: arm))
        #expect(registry.complete(arm, response: normal))
        #expect(registry.markTerminatingAndReturnWasArmed())
    }

    @Test("lifecycle control completes while model work remains blocked")
    func lifecycleControlBypassesModelWork() async throws {
        let registry = makeRegistry()
        let modelReplies = LockedResponses()
        let execution = ManualExecution(resumeOnCancellation: false)
        let model = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: modelReplies.replyOnce
        ))
        #expect(registry.start(model) { await execution.run(output: self.normal) })
        await execution.waitUntilStarted()

        let controlReplies = LockedResponses()
        let control = try admitted(registry.reserveLifecycle(
            requestID: UUID(),
            reply: controlReplies.replyOnce
        ))
        #expect(registry.cancel(model.requestID))
        #expect(registry.complete(control, response: Data("ack".utf8)))

        #expect(controlReplies.values == [Data("ack".utf8)])
        #expect(modelReplies.values == [cancelled])
        #expect(!registry.isWorkQuiescent)

        execution.finish()
        await registry.waitForWorkQuiescence()
    }

    @Test("shutdown closes admission and acknowledges without waiting on model work")
    func shutdownBypassesModelWork() async throws {
        let registry = makeRegistry()
        let execution = ManualExecution(resumeOnCancellation: false)
        let model = try admitted(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: true,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ))
        #expect(registry.start(model) { await execution.run(output: self.normal) })
        await execution.waitUntilStarted()

        let firstReplies = LockedResponses()
        let first = try admitted(registry.reserveLifecycle(
            requestID: UUID(),
            reply: firstReplies.replyOnce
        ))
        #expect(registry.closeForShutdown())
        #expect(registry.complete(first, response: Data("shutdown".utf8)))

        #expect(firstReplies.values == [Data("shutdown".utf8)])
        #expect(!registry.isWorkQuiescent)
        #expect(registry.reserveWork(
            requestID: UUID(),
            inferenceLike: false,
            cancellationResponse: cancelled,
            reply: LockedResponses().replyOnce
        ) == .shuttingDown)

        let second = try admitted(registry.reserveLifecycle(
            requestID: UUID(),
            reply: LockedResponses().replyOnce
        ))
        #expect(!registry.closeForShutdown())
        #expect(registry.complete(second, response: Data("shutdown".utf8)))

        execution.finish()
        await registry.waitForWorkQuiescence()
    }

    @Test("reply guard accepts exactly one concurrent sender")
    func replyOnceIsConcurrent() async {
        let replies = LockedResponses()
        let reply = replies.replyOnce

        await withTaskGroup(of: Void.self) { group in
            for value in 0 ..< 32 {
                group.addTask {
                    _ = reply.send(Data(String(value).utf8))
                }
            }
        }

        #expect(replies.values.count == 1)
    }

    private func makeRegistry() -> GemmaServiceRequestRegistry {
        GemmaServiceRequestRegistry(helperIdentity: helperIdentity())
    }

    private func helperIdentity() -> GemmaIPCPreparedHelperExit {
        GemmaIPCPreparedHelperExit(helperInstanceID: UUID(), processIdentifier: 42)
    }

    private func admitted(
        _ reservation: GemmaServiceRequestRegistry.Reservation
    ) throws -> GemmaServiceRequestRegistry.Ticket {
        guard case .admitted(let ticket) = reservation else {
            throw RegistryTestError.notAdmitted(reservation)
        }
        return ticket
    }
}

private enum RegistryTestError: Error {
    case notAdmitted(GemmaServiceRequestRegistry.Reservation)
}

private final class LockedResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var replyOnce: GemmaServiceReplyOnce {
        GemmaServiceReplyOnce { [self] response in
            lock.withLock { storage.append(response) }
        }
    }

    var values: [Data] {
        lock.withLock { storage }
    }
}

private final class ManualExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let resumeOnCancellation: Bool
    private var started = false
    private var released = false
    private var invocations = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var executionWaiter: CheckedContinuation<Void, Never>?

    init(resumeOnCancellation: Bool) {
        self.resumeOnCancellation = resumeOnCancellation
    }

    var invocationCount: Int {
        lock.withLock { invocations }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if started { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func run(output: Data) async -> Data {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var waiters: [CheckedContinuation<Void, Never>] = []
                let resumeImmediately = lock.withLock {
                    invocations += 1
                    started = true
                    waiters = startWaiters
                    startWaiters.removeAll()
                    if released {
                        return true
                    }
                    executionWaiter = continuation
                    return false
                }
                waiters.forEach { $0.resume() }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            guard self.resumeOnCancellation else { return }
            self.finish()
        }
        return output
    }

    func finish() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !released else { return nil }
            released = true
            defer { executionWaiter = nil }
            return executionWaiter
        }
        continuation?.resume()
    }
}
