import Foundation
import StenoGemmaIPC

/// Sends one response at most once, even when cancellation races task completion.
public final class GemmaServiceReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let reply: @Sendable (Data) -> Void
    private var didReply = false

    public init(_ reply: @escaping @Sendable (Data) -> Void) {
        self.reply = reply
    }

    @discardableResult
    public func send(_ response: Data) -> Bool {
        let shouldReply = lock.withLock {
            guard !didReply else { return false }
            didReply = true
            return true
        }
        guard shouldReply else { return false }
        reply(response)
        return true
    }
}

/// Process-wide admission, cancellation, reply, and exit-drain state for the Gemma helper.
///
/// The registry never executes model work while holding its lock. Lifecycle methods therefore
/// remain available even if a future model executor is blocked in synchronous MLX code.
public final class GemmaServiceRequestRegistry: @unchecked Sendable {
    public struct Ticket: Sendable, Hashable {
        public let requestID: UUID
        fileprivate let reservationToken: UUID
    }

    public enum Reservation: Sendable, Equatable {
        case admitted(Ticket)
        case duplicateRequestID
        case busy
        case shuttingDown
    }

    public enum PrepareResult: Sendable, Equatable {
        case accepted(GemmaIPCPreparedHelperExit)
        case rejected
    }

    private enum ExitState: Equatable {
        case running
        case preparing
        case prepared
        case arming(UUID)
        case armed
        case terminating
    }

    private enum Role {
        case work(inferenceLike: Bool)
        case lifecycle

        var isWork: Bool {
            if case .work = self { return true }
            return false
        }

        var isInferenceLike: Bool {
            if case .work(let inferenceLike) = self { return inferenceLike }
            return false
        }
    }

    private enum ReplyState {
        case pending
        case sending
        case sent
    }

    private struct Entry {
        let ticket: Ticket
        let role: Role
        let reply: GemmaServiceReplyOnce
        let cancellationResponse: Data?
        var task: Task<Void, Never>?
        var operationStarted = false
        var taskFinished = false
        var cancellationRequested = false
        var replyState: ReplyState = .pending
    }

    private enum WaitScope {
        case work
        case allExcept(UUID)
    }

    private struct Waiter {
        let scope: WaitScope
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct ReplyAction {
        let ticket: Ticket
        let reply: GemmaServiceReplyOnce
        let response: Data
    }

    private struct Actions {
        var tasksToCancel: [Task<Void, Never>] = []
        var replies: [ReplyAction] = []
        var continuations: [CheckedContinuation<Void, Never>] = []
    }

    public static let maximumActiveWorkRequests = 32
    public static let maximumActiveLifecycleRequests = 64

    private let lock = NSLock()
    private let helperIdentity: GemmaIPCPreparedHelperExit
    private var entries: [UUID: Entry] = [:]
    private var activeWorkRequests = 0
    private var activeLifecycleRequests = 0
    private var activeInferenceRequestID: UUID?
    private var workAdmissionOpen = true
    private var shutdownRequested = false
    private var exitState: ExitState = .running
    private var waiters: [Waiter] = []

    public init(helperIdentity: GemmaIPCPreparedHelperExit) {
        self.helperIdentity = helperIdentity
    }

    /// Reserves a model-channel request. Completed IDs may be reused, but an active ID is unique
    /// across both model and lifecycle requests. The opaque ticket protects against stale finishes.
    public func reserveWork(
        requestID: UUID,
        inferenceLike: Bool,
        cancellationResponse: Data,
        reply: GemmaServiceReplyOnce
    ) -> Reservation {
        lock.withLock {
            guard entries[requestID] == nil else { return .duplicateRequestID }
            guard workAdmissionOpen, exitState == .running else { return .shuttingDown }
            guard activeWorkRequests < Self.maximumActiveWorkRequests else { return .busy }
            if inferenceLike, activeInferenceRequestID != nil {
                return .busy
            }

            let ticket = Ticket(requestID: requestID, reservationToken: UUID())
            entries[requestID] = Entry(
                ticket: ticket,
                role: .work(inferenceLike: inferenceLike),
                reply: reply,
                cancellationResponse: cancellationResponse
            )
            activeWorkRequests += 1
            if inferenceLike {
                activeInferenceRequestID = requestID
            }
            return .admitted(ticket)
        }
    }

    /// Reserves a short lifecycle request. These requests have a separate active bound and remain
    /// admissible while model admission is closed so cancellation and exit cannot queue behind MLX.
    public func reserveLifecycle(
        requestID: UUID,
        reply: GemmaServiceReplyOnce
    ) -> Reservation {
        lock.withLock {
            guard entries[requestID] == nil else { return .duplicateRequestID }
            switch exitState {
            case .running, .preparing, .prepared:
                break
            case .arming, .armed, .terminating:
                return .shuttingDown
            }
            guard activeLifecycleRequests < Self.maximumActiveLifecycleRequests else {
                return .busy
            }

            let ticket = Ticket(requestID: requestID, reservationToken: UUID())
            entries[requestID] = Entry(
                ticket: ticket,
                role: .lifecycle,
                reply: reply,
                cancellationResponse: nil
            )
            activeLifecycleRequests += 1
            return .admitted(ticket)
        }
    }

    /// Starts a previously reserved request. Cancellation can win between reservation and start;
    /// in that case the operation is never invoked.
    @discardableResult
    public func start(
        _ ticket: Ticket,
        operation: @escaping @Sendable () async -> Data
    ) -> Bool {
        lock.lock()
        guard var entry = matchingEntryLocked(ticket),
              entry.task == nil,
              !entry.operationStarted,
              !entry.taskFinished,
              !entry.cancellationRequested
        else {
            lock.unlock()
            return false
        }

        let task = Task { [weak self] in
            guard let self else { return }
            if Task.isCancelled {
                _ = self.cancel(ticket.requestID)
            }
            // This lock-protected claim is the operation-start linearization point. A cancel that
            // records its state first prevents the operation even before Task.cancel is delivered.
            guard self.claimOperationStart(ticket) else { return }
            let response = await operation()
            self.taskReturned(ticket, response: response)
        }
        entry.task = task
        entries[ticket.requestID] = entry
        lock.unlock()
        return true
    }

    /// Completes a short lifecycle request without scheduling it on the model executor.
    @discardableResult
    public func complete(_ ticket: Ticket, response: Data) -> Bool {
        finish(ticket, response: response)
    }

    /// Cancels one exact active work request. The cancellation response wins against any later
    /// normal result, but a running entry remains admitted until its task actually returns.
    @discardableResult
    public func cancel(_ requestID: UUID) -> Bool {
        var actions = Actions()
        let changed: Bool = lock.withLock {
            guard var entry = entries[requestID],
                  entry.role.isWork,
                  !entry.cancellationRequested,
                  !entry.taskFinished,
                  let cancellationResponse = entry.cancellationResponse
            else { return false }

            entry.cancellationRequested = true
            if let task = entry.task {
                actions.tasksToCancel.append(task)
            } else {
                entry.taskFinished = true
            }
            if entry.replyState == .pending {
                entry.replyState = .sending
                actions.replies.append(ReplyAction(
                    ticket: entry.ticket,
                    reply: entry.reply,
                    response: cancellationResponse
                ))
            }
            entries[requestID] = entry
            actions.continuations.append(contentsOf: removeFinishedEntriesAndReadyWaitersLocked())
            return true
        }
        perform(actions)
        return changed
    }

    /// Closes work admission and cancels every admitted work request. It does not claim
    /// quiescence until all running tasks have actually returned and their replies have completed.
    @discardableResult
    public func closeForShutdown() -> Bool {
        var actions = Actions()
        let changed: Bool = lock.withLock {
            let changed = !shutdownRequested
            shutdownRequested = true
            workAdmissionOpen = false
            appendCancellationActionsForAllWorkLocked(to: &actions)
            return changed
        }
        perform(actions)
        return changed
    }

    /// Atomically closes work admission and begins the authenticated exit drain.
    public func beginPrepareForExit() -> PrepareResult {
        var actions = Actions()
        let result: PrepareResult = lock.withLock {
            guard exitState == .running else { return .rejected }
            exitState = .preparing
            workAdmissionOpen = false
            appendCancellationActionsForAllWorkLocked(to: &actions)
            return .accepted(helperIdentity)
        }
        perform(actions)
        return result
    }

    public func waitForWorkQuiescence() async {
        await wait(for: .work)
    }

    /// Marks prepare complete only after every admitted work task and reply has drained.
    public func finishPrepareForExit() -> GemmaIPCPreparedHelperExit? {
        lock.withLock {
            guard exitState == .preparing, isWorkQuiescentLocked else { return nil }
            exitState = .prepared
            return helperIdentity
        }
    }

    /// Waits until no request except the supplied arm request remains in the registry.
    public func waitUntilReadyToArm(excluding ticket: Ticket) async {
        await wait(for: .allExcept(ticket.reservationToken))
    }

    /// Authenticates and exclusively reserves the arm transition before waiting. This prevents an
    /// invalid or second arm request from waiting forever while occupying a lifecycle slot.
    public func beginArmAndExit(
        _ identity: GemmaIPCPreparedHelperExit,
        armRequest ticket: Ticket
    ) -> Bool {
        lock.withLock {
            guard exitState == .prepared,
                  identity == helperIdentity,
                  matchingEntryLocked(ticket)?.role.isWork == false
            else { return false }
            exitState = .arming(ticket.reservationToken)
            return true
        }
    }

    /// Performs the final server-side quiescence check immediately before the armed reply.
    public func finishArmAndExit(
        _ identity: GemmaIPCPreparedHelperExit,
        armRequest ticket: Ticket
    ) -> Bool {
        lock.withLock {
            guard case .arming(let reservationToken) = exitState,
                  reservationToken == ticket.reservationToken,
                  identity == helperIdentity,
                  matchingEntryLocked(ticket)?.role.isWork == false,
                  entries.values.allSatisfy({ $0.ticket.reservationToken == ticket.reservationToken }),
                  activeInferenceRequestID == nil,
                  waiters.isEmpty
            else { return false }
            exitState = .armed
            return true
        }
    }

    /// Consumes the armed state exactly once when the authenticated peer disconnects.
    public func markTerminatingAndReturnWasArmed() -> Bool {
        lock.withLock {
            let wasArmed = exitState == .armed
            exitState = .terminating
            workAdmissionOpen = false
            return wasArmed
        }
    }

    public var isWorkQuiescent: Bool {
        lock.withLock { isWorkQuiescentLocked }
    }

    public var activeRequestCount: Int {
        lock.withLock { entries.count }
    }

    private var isWorkQuiescentLocked: Bool {
        !entries.values.contains(where: { $0.role.isWork })
            && activeInferenceRequestID == nil
    }

    private func matchingEntryLocked(_ ticket: Ticket) -> Entry? {
        guard let entry = entries[ticket.requestID],
              entry.ticket.reservationToken == ticket.reservationToken
        else { return nil }
        return entry
    }

    private func claimOperationStart(_ ticket: Ticket) -> Bool {
        var continuations: [CheckedContinuation<Void, Never>] = []
        let shouldRun: Bool = lock.withLock {
            guard var entry = matchingEntryLocked(ticket),
                  !entry.operationStarted,
                  !entry.taskFinished
            else {
                return false
            }
            guard !entry.cancellationRequested else {
                entry.taskFinished = true
                entries[ticket.requestID] = entry
                continuations = removeFinishedEntriesAndReadyWaitersLocked()
                return false
            }
            entry.operationStarted = true
            entries[ticket.requestID] = entry
            return true
        }
        continuations.forEach { $0.resume() }
        return shouldRun
    }

    private func taskReturned(_ ticket: Ticket, response: Data) {
        _ = finish(ticket, response: response)
    }

    @discardableResult
    private func finish(_ ticket: Ticket, response: Data) -> Bool {
        var action: ReplyAction?
        var continuations: [CheckedContinuation<Void, Never>] = []
        let found: Bool = lock.withLock {
            guard var entry = matchingEntryLocked(ticket), !entry.taskFinished else {
                return false
            }
            entry.taskFinished = true
            if entry.replyState == .pending {
                entry.replyState = .sending
                action = ReplyAction(ticket: ticket, reply: entry.reply, response: response)
            }
            entries[ticket.requestID] = entry
            continuations = removeFinishedEntriesAndReadyWaitersLocked()
            return true
        }
        continuations.forEach { $0.resume() }
        if let action {
            performReply(action)
        }
        return found
    }

    private func appendCancellationActionsForAllWorkLocked(to actions: inout Actions) {
        for requestID in entries.keys {
            guard var entry = entries[requestID],
                  entry.role.isWork,
                  !entry.cancellationRequested,
                  !entry.taskFinished,
                  let cancellationResponse = entry.cancellationResponse
            else { continue }

            entry.cancellationRequested = true
            if let task = entry.task {
                actions.tasksToCancel.append(task)
            } else {
                entry.taskFinished = true
            }
            if entry.replyState == .pending {
                entry.replyState = .sending
                actions.replies.append(ReplyAction(
                    ticket: entry.ticket,
                    reply: entry.reply,
                    response: cancellationResponse
                ))
            }
            entries[requestID] = entry
        }
        actions.continuations.append(contentsOf: removeFinishedEntriesAndReadyWaitersLocked())
    }

    private func perform(_ actions: Actions) {
        // A cancellation handler is third-party executor code and must not delay the protocol
        // acknowledgement. Quiescence still waits for every cancelled task to return.
        actions.replies.forEach(performReply)
        actions.tasksToCancel.forEach { $0.cancel() }
        actions.continuations.forEach { $0.resume() }
    }

    private func performReply(_ action: ReplyAction) {
        _ = action.reply.send(action.response)
        var continuations: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            guard var entry = matchingEntryLocked(action.ticket),
                  entry.replyState == .sending
            else { return }
            entry.replyState = .sent
            entries[action.ticket.requestID] = entry
            continuations = removeFinishedEntriesAndReadyWaitersLocked()
        }
        continuations.forEach { $0.resume() }
    }

    private func wait(for scope: WaitScope) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if isSatisfiedLocked(scope) {
                    return true
                }
                waiters.append(Waiter(scope: scope, continuation: continuation))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func removeFinishedEntriesAndReadyWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        let finishedIDs = entries.compactMap { requestID, entry in
            entry.taskFinished && entry.replyState == .sent ? requestID : nil
        }
        for requestID in finishedIDs {
            guard let entry = entries.removeValue(forKey: requestID) else { continue }
            switch entry.role {
            case .work(let inferenceLike):
                activeWorkRequests = max(0, activeWorkRequests - 1)
                if inferenceLike,
                   activeInferenceRequestID == requestID
                {
                    activeInferenceRequestID = nil
                }
            case .lifecycle:
                activeLifecycleRequests = max(0, activeLifecycleRequests - 1)
            }
        }

        var ready: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            if isSatisfiedLocked(waiter.scope) {
                ready.append(waiter.continuation)
                return true
            }
            return false
        }
        return ready
    }

    private func isSatisfiedLocked(_ scope: WaitScope) -> Bool {
        switch scope {
        case .work:
            return isWorkQuiescentLocked
        case .allExcept(let reservationToken):
            return entries.values.allSatisfy {
                $0.ticket.reservationToken == reservationToken
            }
        }
    }
}
