import Foundation
import StenoGemmaIPC

/// Binds the helper-returned UUID to the observed process while that exact process is still alive.
///
/// The process identifier is observation-only and must never be used to signal or kill a process.
public typealias GemmaPreparedHelperExit = GemmaIPCPreparedHelperExit

/// An authenticated echo proving that the exact prepared process armed its exit path.
public struct GemmaArmedHelperExit: Equatable, Sendable {
    public let preparedHelper: GemmaPreparedHelperExit

    public init(preparedHelper: GemmaPreparedHelperExit) {
        self.preparedHelper = preparedHelper
    }
}

public enum GemmaAuthenticatedHelperExitEvent: Equatable, Sendable {
    case exit
}

/// Proof that the exact prepared and authenticated helper process has exited.
public struct GemmaAuthenticatedHelperExitProof: Equatable, Sendable {
    public let preparedHelper: GemmaPreparedHelperExit
    public let event: GemmaAuthenticatedHelperExitEvent

    public init(
        preparedHelper: GemmaPreparedHelperExit,
        event: GemmaAuthenticatedHelperExitEvent
    ) {
        self.preparedHelper = preparedHelper
        self.event = event
    }
}

/// A model-free transport with lifecycle controls that bypass the model execution actor.
public protocol GemmaClientTransport: Sendable {
    /// Transports one original encoded frame without decoding it first.
    func send(_ encodedRequest: Data, requestID: UUID) async throws -> Data

    /// Atomically closes helper admission and returns an authenticated helper-supplied instance
    /// UUID bound to the live connection process identifier and executable path.
    func prepareForExit() async throws -> GemmaPreparedHelperExit

    /// Atomically arms helper self-exit and returns its authenticated echo.
    ///
    /// The transport then closes this exact connection without sending another message. The
    /// helper exits on that authenticated peer disconnect, so a named connection cannot relaunch
    /// a replacement process between the echo and the observed exit.
    func armAndExit(_ preparedHelper: GemmaPreparedHelperExit) async throws -> GemmaArmedHelperExit

    /// Releases the client connection after exit has been proven or the controller has faulted.
    ///
    /// This is a terminal, synchronous operation. Before it returns, every outstanding call must
    /// be unblocked, and this transport must be permanently unable to reconnect or launch a helper.
    func invalidate()
}

/// Creates an unauthenticated transport reservation synchronously.
///
/// No helper identity is available at this boundary. The concrete transport authenticates a reply
/// before returning from `prepareForExit` and binds that helper-supplied identity to its connection.
/// Construction must be bounded and nonblocking so actor admission cannot be delayed indefinitely.
public protocol GemmaClientTransportFactory: Sendable {
    func makeTransport() throws -> any GemmaClientTransport
}

/// A registered observation for one prepared helper process.
public protocol GemmaAuthenticatedHelperExitObservation: Sendable {
    var preparedHelper: GemmaPreparedHelperExit { get }

    func waitForExit() async throws -> GemmaAuthenticatedHelperExitProof

    /// Permanently cancels observation and synchronously unblocks every outstanding wait.
    func invalidate()
}

/// Registers observation while the authenticated helper is still alive.
///
/// Returning from this method means the process observer's registration callback has completed.
public protocol GemmaAuthenticatedHelperExitProving: Sendable {
    func registerExitObservation(
        for preparedHelper: GemmaPreparedHelperExit
    ) async throws -> any GemmaAuthenticatedHelperExitObservation
}

public enum GemmaClientDeadlineOperation: String, Hashable, Sendable {
    case request
    case prepareForExit
    case exitObservationRegistration
    case cancelRequest
    case quiescentShutdown
    case armAndExit
    case authenticatedHelperExit
}

/// Supplies cancellable deadlines without coupling this core to a concrete clock.
///
/// Implementations must return from `waitUntilExpired` when their task is cancelled.
public protocol GemmaClientDeadline: Sendable {
    func waitUntilExpired(for operation: GemmaClientDeadlineOperation) async
}

/// A cancellable production deadline backed by Swift's monotonic continuous clock.
public struct GemmaContinuousClockDeadline: GemmaClientDeadline, Sendable {
    public let timeout: Duration

    public init(timeout: Duration) {
        self.timeout = timeout
    }

    public func waitUntilExpired(for operation: GemmaClientDeadlineOperation) async {
        do {
            try await ContinuousClock().sleep(for: timeout)
        } catch {
            // Cancellation ends the deadline task without expiring its operation.
        }
    }
}

public enum GemmaClientControllerState: Equatable, Sendable {
    case idle
    /// Retained for source compatibility. A closure-scoped controller never exposes this state.
    case connected
    case active
    case retiring
    case drainingForRecording
    case recording
    case faulted
}

public enum GemmaClientControllerError: Error, Equatable, Sendable {
    case invalidInFlightLimit
    case busy(limit: Int)
    case recordingActive
    case recordingTransitionInProgress
    case faulted
    case controlOperationNotAllowed
    case connectionFailed
    case invalidResponse
    case remoteFailure(GemmaIPCErrorCode)
    case requestCancelled
    case cancelledForRecording
    case timedOut(GemmaClientDeadlineOperation)
    case operationFailed(GemmaClientDeadlineOperation)
    case invalidExitPreparation
    case exitObservationMismatch
    case exitArmMismatch
    case authenticatedExitProofMismatch
    case invalidRecordingLease
    case modelSessionActive
    case modelSessionRetiring
    case modelSessionInactive
    case modelAdmissionBusy
}

/// A closure-scoped capability for one native Gemma helper session.
///
/// The capability is valid only while the controller owns the exact active session identifier.
/// Retaining it after `GemmaClientController.withModelSession` returns cannot reopen or reuse the
/// helper.
public struct GemmaClientModelSession: Sendable {
    fileprivate let identifier: UUID
    private let controller: GemmaClientController

    fileprivate init(identifier: UUID, controller: GemmaClientController) {
        self.identifier = identifier
        self.controller = controller
    }

    /// Sends one application request through this exact high-level session.
    public func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody {
        try await controller.send(body, in: self)
    }
}

/// An opaque capability proving that the helper teardown barrier completed successfully.
public struct GemmaRecordingLease: Hashable, Sendable {
    fileprivate let identifier: UUID

    /// Creates a reservation token before asynchronous acquisition begins.
    ///
    /// Keeping this token lets a cancelled caller release an ambiguously returned acquisition.
    public init() {
        identifier = UUID()
    }
}

/// Model-free admission and teardown controller for the native Gemma helper.
///
/// The controller never accesses models, files, network resources, audio, or application state.
/// It creates a transport only for an explicit request. Before granting a recording lease, it
/// closes admission, prepares and registers exact-process exit observation, attempts cancellation
/// and quiescence, atomically arms and exits the helper, verifies the exact exit event, and only then
/// invalidates the transport.
public actor GemmaClientController {
    public static let hardMaximumInFlightRequests = 32

    private enum Phase: Equatable {
        case available
        case active(UUID)
        case retiring(UUID)
        case drainingForRecording
        case recording(UUID)
        case faulted
    }

    private struct InFlightRequest: Sendable {
        let sessionID: UUID
        let requestID: UUID
        let actionTask: Task<Void, Never>
        let deadlineTask: Task<Void, Never>
        let completion: GemmaOneShot<GemmaIPCResponseBody>
    }

    private struct Retirement: Sendable {
        let identifier: UUID
        let sessionID: UUID
        let transport: (any GemmaClientTransport)?
        let requestIDs: [UUID]
        let completion: GemmaOneShot<Void>
    }

    private let transportFactory: any GemmaClientTransportFactory
    private let exitProver: any GemmaAuthenticatedHelperExitProving
    private let deadline: any GemmaClientDeadline
    private let maximumInFlightRequests: Int

    private var phase: Phase = .available
    private var transport: (any GemmaClientTransport)?
    private var inFlightRequests: [UUID: InFlightRequest] = [:]
    private var retirement: Retirement?
    private var pendingRecordingLease: GemmaRecordingLease?
    private var modelFaulted = false
    private var lastCompletedRetirement: (sessionID: UUID, result: Result<Void, GemmaClientControllerError>)?

    public init(
        maximumInFlightRequests: Int,
        transportFactory: any GemmaClientTransportFactory,
        exitProver: any GemmaAuthenticatedHelperExitProving,
        deadline: any GemmaClientDeadline
    ) throws {
        guard (1 ... Self.hardMaximumInFlightRequests).contains(maximumInFlightRequests) else {
            throw GemmaClientControllerError.invalidInFlightLimit
        }

        self.maximumInFlightRequests = maximumInFlightRequests
        self.transportFactory = transportFactory
        self.exitProver = exitProver
        self.deadline = deadline
    }

    public func lifecycleState() -> GemmaClientControllerState {
        switch phase {
        case .available:
            .idle
        case .active:
            .active
        case .retiring:
            .retiring
        case .drainingForRecording:
            .drainingForRecording
        case .recording:
            .recording
        case .faulted:
            .faulted
        }
    }

    public func inFlightRequestCount() -> Int {
        inFlightRequests.count
    }

    /// Compatibility convenience that creates and retires one high-level model session.
    public func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody {
        try await withModelSession { session in
            try await session.send(body)
        }
    }

    /// Creates one closure-scoped model session and retires its helper before returning or
    /// throwing. A second session is never admitted while this session is active or retiring.
    public func withModelSession<Value: Sendable>(
        _ operation: @Sendable (GemmaClientModelSession) async throws -> Value
    ) async throws -> Value {
        guard !Task.isCancelled else {
            throw GemmaClientControllerError.requestCancelled
        }
        let sessionID = try beginModelSession()
        let session = GemmaClientModelSession(identifier: sessionID, controller: self)

        do {
            let value = try await operation(session)
            let retirementResult = await finishModelSession(sessionID)
            try retirementResult.get()
            return value
        } catch {
            // The caller's error remains authoritative, but helper retirement is still terminal
            // and completes before this method throws.
            _ = await finishModelSession(sessionID)
            throw error
        }
    }

    /// Sends one application request after the exact session has been admitted.
    fileprivate func send(
        _ body: GemmaIPCRequestBody,
        in session: GemmaClientModelSession
    ) async throws -> GemmaIPCResponseBody {
        guard Self.isApplicationRequest(body) else {
            throw GemmaClientControllerError.controlOperationNotAllowed
        }
        guard case .active(let activeSessionID) = phase,
              activeSessionID == session.identifier
        else {
            throw GemmaClientControllerError.modelSessionInactive
        }
        guard inFlightRequests.count < maximumInFlightRequests else {
            throw GemmaClientControllerError.busy(limit: maximumInFlightRequests)
        }

        let activeTransport: any GemmaClientTransport
        if let transport {
            activeTransport = transport
        } else {
            do {
                let createdTransport = try transportFactory.makeTransport()
                transport = createdTransport
                activeTransport = createdTransport
            } catch GemmaRawXPCTransportError.executionGateBusy {
                throw GemmaClientControllerError.modelAdmissionBusy
            } catch {
                phase = .faulted
                modelFaulted = true
                throw GemmaClientControllerError.connectionFailed
            }
        }

        let request: GemmaIPCRequestEnvelope
        let encodedRequest: Data
        do {
            request = try GemmaIPCRequestEnvelope(body: body)
            encodedRequest = try GemmaIPCCodec.encode(request)
        } catch {
            throw GemmaClientControllerError.invalidResponse
        }

        let completion = GemmaOneShot<GemmaIPCResponseBody>()
        let deadline = self.deadline
        let requestID = request.requestID
        let actionTask = Task { [weak self] in
            let result: Result<GemmaIPCResponseBody, GemmaClientControllerError>
            do {
                let encodedResponse = try await activeTransport.send(
                    encodedRequest,
                    requestID: request.requestID
                )
                result = .success(try Self.validatedBody(encodedResponse, for: request))
            } catch is CancellationError {
                result = .failure(.requestCancelled)
            } catch let error as GemmaClientControllerError {
                result = .failure(error)
            } catch {
                result = .failure(.operationFailed(.request))
            }
            await self?.requestActionFinished(requestID: requestID, result: result)
        }
        let deadlineTask = Task { [weak self] in
            await deadline.waitUntilExpired(for: .request)
            guard !Task.isCancelled else { return }
            await self?.requestDeadlineExpired(requestID: requestID)
        }
        inFlightRequests[request.requestID] = InFlightRequest(
            sessionID: session.identifier,
            requestID: request.requestID,
            actionTask: actionTask,
            deadlineTask: deadlineTask,
            completion: completion
        )

        let result = await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequestFromCaller(requestID: requestID)
            }
        }
        return try result.get()
    }

    private func requestActionFinished(
        requestID: UUID,
        result: Result<GemmaIPCResponseBody, GemmaClientControllerError>
    ) {
        guard let request = inFlightRequests.removeValue(forKey: requestID) else { return }
        request.deadlineTask.cancel()

        if case .failure(let error) = result,
           Self.isInfrastructureFailure(error),
           case .active(let activeSessionID) = phase,
           activeSessionID == request.sessionID
        {
            faultOutstandingRequests(current: request, error: error)
            return
        }
        request.completion.resolve(result)
    }

    private func requestDeadlineExpired(requestID: UUID) {
        guard let request = inFlightRequests[requestID],
              case .active(let activeSessionID) = phase,
              activeSessionID == request.sessionID
        else { return }
        request.actionTask.cancel()
        faultOutstandingRequests(
            current: request,
            error: .timedOut(.request)
        )
    }

    private func cancelRequestFromCaller(requestID: UUID) {
        guard let request = inFlightRequests[requestID] else { return }
        request.actionTask.cancel()
        request.completion.resolve(.failure(.requestCancelled))
    }

    private func faultOutstandingRequests(
        current: InFlightRequest,
        error: GemmaClientControllerError
    ) {
        let outstandingRequests = Array(inFlightRequests.values)
        inFlightRequests.removeAll(keepingCapacity: true)
        transport?.invalidate()
        transport = nil
        phase = .faulted
        modelFaulted = true

        current.completion.resolve(.failure(error))
        for request in outstandingRequests where request.requestID != current.requestID {
            request.actionTask.cancel()
            request.deadlineTask.cancel()
            request.completion.resolve(.failure(.faulted))
        }
    }

    /// Closes model admission and returns a lease only after an already-active retirement reaches
    /// its terminal state. A failed cooperative retirement faults model use but never strands the
    /// recording path, whose outer process gate remains the authoritative exclusion boundary.
    public func acquireRecordingLease(
        _ lease: GemmaRecordingLease
    ) async throws -> GemmaRecordingLease {
        guard !Task.isCancelled else {
            throw GemmaClientControllerError.requestCancelled
        }
        switch phase {
        case .available:
            phase = .drainingForRecording
            phase = .recording(lease.identifier)
            return lease
        case .active:
            break
        case .retiring:
            break
        case .drainingForRecording:
            throw GemmaClientControllerError.recordingTransitionInProgress
        case .recording:
            throw GemmaClientControllerError.recordingActive
        case .faulted:
            // A previous model-side fault cannot veto recording. The process gate is still the
            // fail-closed authority for byte 1.
            phase = .drainingForRecording
            phase = .recording(lease.identifier)
            return lease
        }

        let completion: GemmaOneShot<Void>
        switch phase {
        case .active:
            completion = beginRetirement(requestError: .cancelledForRecording)
        case .retiring:
            guard let retirement else {
                throw GemmaClientControllerError.faulted
            }
            completion = retirement.completion
        case .available, .drainingForRecording, .recording, .faulted:
            preconditionFailure("recording admission was handled before retirement")
        }
        guard pendingRecordingLease == nil else {
            throw GemmaClientControllerError.recordingTransitionInProgress
        }
        pendingRecordingLease = lease
        _ = await completion.wait()

        guard case .recording(let activeIdentifier) = phase,
              activeIdentifier == lease.identifier,
              !Task.isCancelled
        else {
            if case .recording(let activeIdentifier) = phase,
               activeIdentifier == lease.identifier {
                phase = modelFaulted ? .faulted : .available
            }
            throw GemmaClientControllerError.requestCancelled
        }
        return lease
    }

    /// Releases the exact active lease without creating a replacement transport.
    public func releaseRecordingLease(_ lease: GemmaRecordingLease) throws {
        guard case .recording(let activeIdentifier) = phase,
              activeIdentifier == lease.identifier
        else {
            throw GemmaClientControllerError.invalidRecordingLease
        }
        if modelFaulted {
            phase = .faulted
            throw GemmaClientControllerError.faulted
        }
        phase = .available
    }

    private func beginModelSession() throws -> UUID {
        switch phase {
        case .available:
            guard !modelFaulted else {
                throw GemmaClientControllerError.faulted
            }
            let identifier = UUID()
            phase = .active(identifier)
            return identifier
        case .active:
            throw GemmaClientControllerError.modelSessionActive
        case .retiring:
            throw GemmaClientControllerError.modelSessionRetiring
        case .drainingForRecording:
            throw GemmaClientControllerError.recordingTransitionInProgress
        case .recording:
            throw GemmaClientControllerError.recordingActive
        case .faulted:
            throw GemmaClientControllerError.faulted
        }
    }

    private func finishModelSession(
        _ sessionID: UUID
    ) async -> Result<Void, GemmaClientControllerError> {
        switch phase {
        case .active(let activeSessionID) where activeSessionID == sessionID:
            return await beginRetirement(requestError: .requestCancelled).wait()
        case .retiring:
            guard let retirement, retirement.sessionID == sessionID else {
                return .failure(.modelSessionInactive)
            }
            return await retirement.completion.wait()
        case .available, .drainingForRecording, .recording:
            // Recording preemption may have completed the same session's retirement before the
            // closure unwound. Its token has already become invalid and nothing remains bound.
            guard let lastCompletedRetirement,
                  lastCompletedRetirement.sessionID == sessionID
            else {
                return .failure(.modelSessionInactive)
            }
            return lastCompletedRetirement.result
        case .active, .faulted:
            return .failure(.modelSessionInactive)
        }
    }

    /// Publishes a distinct retirement identity before the first suspension point. The unstructured
    /// worker is intentionally independent of a cancelled client closure, so cancellation still
    /// waits for terminal helper retirement rather than abandoning a bound model lease.
    private func beginRetirement(
        requestError: GemmaClientControllerError
    ) -> GemmaOneShot<Void> {
        guard case .active(let sessionID) = phase else {
            preconditionFailure("retirement requires an active model session")
        }
        let identifier = UUID()
        let completion = GemmaOneShot<Void>()
        let trackedRequests = Array(inFlightRequests.values)
        inFlightRequests.removeAll(keepingCapacity: true)
        for request in trackedRequests {
            request.completion.resolve(.failure(requestError))
            request.actionTask.cancel()
            request.deadlineTask.cancel()
        }

        let retiringTransport = transport
        transport = nil
        retirement = Retirement(
            identifier: identifier,
            sessionID: sessionID,
            transport: retiringTransport,
            requestIDs: trackedRequests.map(\.requestID),
            completion: completion
        )
        phase = .retiring(identifier)
        Task.detached { [weak self] in
            await self?.performRetirement(identifier)
        }
        return completion
    }

    private func performRetirement(_ identifier: UUID) async {
        guard let retirement,
              retirement.identifier == identifier,
              case .retiring(let currentIdentifier) = phase,
              currentIdentifier == identifier
        else {
            return
        }
        guard let activeTransport = retirement.transport else {
            completeRetirement(identifier, result: .success(()))
            return
        }

        var exitObservationToInvalidate: (any GemmaAuthenticatedHelperExitObservation)?
        defer {
            exitObservationToInvalidate?.invalidate()
            activeTransport.invalidate()
        }

        let preparedHelper: GemmaPreparedHelperExit
        do {
            preparedHelper = try await GemmaDeadlineRace.run(
                operation: .prepareForExit,
                deadline: deadline
            ) {
                try await activeTransport.prepareForExit()
            }.get()
            guard preparedHelper.processIdentifier > 0 else {
                throw GemmaClientControllerError.invalidExitPreparation
            }
        } catch {
            completeRetirement(identifier, result: .failure(Self.sanitized(error, for: .prepareForExit)))
            return
        }

        let exitObservation: any GemmaAuthenticatedHelperExitObservation
        do {
            let exitProver = self.exitProver
            exitObservation = try await GemmaDeadlineRace.run(
                operation: .exitObservationRegistration,
                deadline: deadline
            ) {
                try await exitProver.registerExitObservation(for: preparedHelper)
            }.get()
            guard exitObservation.preparedHelper == preparedHelper else {
                throw GemmaClientControllerError.exitObservationMismatch
            }
            exitObservationToInvalidate = exitObservation
        } catch {
            completeRetirement(
                identifier,
                result: .failure(Self.sanitized(error, for: .exitObservationRegistration))
            )
            return
        }

        await attemptBestEffortQuiescence(
            requestIDs: retirement.requestIDs,
            using: activeTransport
        )

        let armedExit: GemmaArmedHelperExit
        do {
            armedExit = try await GemmaDeadlineRace.run(
                operation: .armAndExit,
                deadline: deadline
            ) {
                try await activeTransport.armAndExit(preparedHelper)
            }.get()
            guard armedExit.preparedHelper == preparedHelper else {
                throw GemmaClientControllerError.exitArmMismatch
            }
        } catch {
            completeRetirement(identifier, result: .failure(Self.sanitized(error, for: .armAndExit)))
            return
        }

        do {
            let proof = try await GemmaDeadlineRace.run(
                operation: .authenticatedHelperExit,
                deadline: deadline
            ) {
                try await exitObservation.waitForExit()
            }.get()
            guard proof.preparedHelper == preparedHelper,
                  proof.event == .exit
            else {
                throw GemmaClientControllerError.authenticatedExitProofMismatch
            }
        } catch {
            completeRetirement(
                identifier,
                result: .failure(Self.sanitized(error, for: .authenticatedHelperExit))
            )
            return
        }

        completeRetirement(identifier, result: .success(()))
    }

    private func completeRetirement(
        _ identifier: UUID,
        result: Result<Void, GemmaClientControllerError>
    ) {
        guard let retirement,
              retirement.identifier == identifier,
              case .retiring(let currentIdentifier) = phase,
              currentIdentifier == identifier
        else {
            return
        }
        self.retirement = nil
        if case .failure = result {
            modelFaulted = true
        }
        if let recordingLease = pendingRecordingLease {
            pendingRecordingLease = nil
            // This direct transition deliberately has no available state between retirement and
            // recording admission, so another model session cannot slip through the gap.
            phase = .recording(recordingLease.identifier)
        } else {
            phase = modelFaulted ? .faulted : .available
        }
        lastCompletedRetirement = (sessionID: retirement.sessionID, result: result)
        retirement.completion.resolve(result)
    }

    private func attemptBestEffortQuiescence(
        requestIDs: [UUID],
        using transport: any GemmaClientTransport
    ) async {
        let requestBodies: [GemmaIPCRequestBody] = requestIDs.map {
            GemmaIPCRequestBody.cancel(GemmaIPCCancelRequest(targetRequestID: $0))
        } + [.shutdown]
        _ = await GemmaDeadlineRace.run(
            operation: .quiescentShutdown,
            deadline: deadline
        ) {
            await withTaskGroup(of: Void.self) { group in
                for body in requestBodies {
                    group.addTask {
                        try? await Self.sendControlRequest(body, using: transport)
                    }
                }
            }
        }
    }

    private static func sendControlRequest(
        _ body: GemmaIPCRequestBody,
        using transport: any GemmaClientTransport
    ) async throws {
        let request = try GemmaIPCRequestEnvelope(body: body)
        let encodedRequest = try GemmaIPCCodec.encode(request)
        let encodedResponse = try await transport.send(
            encodedRequest,
            requestID: request.requestID
        )
        let responseBody = try Self.validatedBody(encodedResponse, for: request)

        if case .failure(let failure) = responseBody {
            throw GemmaClientControllerError.remoteFailure(failure.code)
        }
        switch (body, responseBody) {
        case (.cancel, .acknowledgement(let acknowledgement))
            where acknowledgement.kind == .cancelled:
            return
        case (.shutdown, .acknowledgement(let acknowledgement))
            where acknowledgement.kind == .shutdown:
            return
        default:
            throw GemmaClientControllerError.invalidResponse
        }
    }

    private static func validatedBody(
        _ encodedResponse: Data,
        for request: GemmaIPCRequestEnvelope
    ) throws -> GemmaIPCResponseBody {
        do {
            return try GemmaIPCCodec.decodeResponse(
                encodedResponse,
                expectedRequestID: request.requestID,
                expectedOperation: request.body.operation
            ).body
        } catch {
            throw GemmaClientControllerError.invalidResponse
        }
    }

    private static func isApplicationRequest(_ body: GemmaIPCRequestBody) -> Bool {
        switch body {
        case .handshake, .countTokens, .generate:
            true
        case .cancel, .shutdown:
            false
        }
    }

    private static func isInfrastructureFailure(_ error: GemmaClientControllerError) -> Bool {
        switch error {
        case .timedOut(.request), .operationFailed(.request), .invalidResponse:
            true
        default:
            false
        }
    }

    private static func sanitized(
        _ error: any Error,
        for operation: GemmaClientDeadlineOperation
    ) -> GemmaClientControllerError {
        if let error = error as? GemmaClientControllerError {
            return error
        }
        if error is CancellationError {
            return .operationFailed(operation)
        }
        return .operationFailed(operation)
    }
}

private enum GemmaDeadlineRace {
    static func run<Value: Sendable>(
        operation: GemmaClientDeadlineOperation,
        deadline: any GemmaClientDeadline,
        action: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, GemmaClientControllerError> {
        let completion = GemmaOneShot<Value>()
        let actionTask = Task {
            do {
                completion.resolve(.success(try await action()))
            } catch is CancellationError {
                completion.resolve(.failure(.operationFailed(operation)))
            } catch let error as GemmaClientControllerError {
                completion.resolve(.failure(error))
            } catch {
                completion.resolve(.failure(.operationFailed(operation)))
            }
        }
        let deadlineTask = Task {
            await deadline.waitUntilExpired(for: operation)
            guard !Task.isCancelled else { return }
            completion.resolve(.failure(.timedOut(operation)))
        }

        let result = await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            completion.resolve(.failure(.operationFailed(operation)))
        }
        actionTask.cancel()
        deadlineTask.cancel()
        return result
    }
}

private final class GemmaOneShot<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending([CheckedContinuation<Result<Value, GemmaClientControllerError>, Never>])
        case resolved(Result<Value, GemmaClientControllerError>)
    }

    private let lock = NSLock()
    private var state: State = .pending([])

    func wait() async -> Result<Value, GemmaClientControllerError> {
        await withCheckedContinuation { continuation in
            let result: Result<Value, GemmaClientControllerError>? = lock.withLock {
                switch state {
                case .pending(var continuations):
                    continuations.append(continuation)
                    state = .pending(continuations)
                    return nil
                case .resolved(let result):
                    return result
                }
            }
            if let result {
                continuation.resume(returning: result)
            }
        }
    }

    func resolve(_ result: Result<Value, GemmaClientControllerError>) {
        let continuations: [CheckedContinuation<Result<Value, GemmaClientControllerError>, Never>] =
            lock.withLock {
                guard case .pending(let continuations) = state else { return [] }
                state = .resolved(result)
                return continuations
            }
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}
