import Foundation
import StenoGemmaProcessGate

#if canImport(StenoGemmaClient)
import StenoGemmaClient
import StenoGemmaIPC
#endif

/// Keeps the native Gemma helper absent for the entire audio-capture lifetime.
///
/// Implementations must fail closed: returning from `acquire()` proves through the shared kernel
/// gate that no Steno native Gemma helper can still execute, and `release()` must not create or
/// reconnect a helper. Every future native Gemma provider must use this same gate contract.
protocol NativeGemmaCoordinator: AnyObject, Sendable {
    func acquire() async throws
    func release() async throws

    #if canImport(StenoGemmaClient)
    func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody
    #endif
}

enum NativeGemmaRecordingBarrierFactory {
    private static let sharedLiveCoordinator: any NativeGemmaCoordinator = {
        #if canImport(StenoGemmaClient)
        NativeGemmaRecordingBarrierController(appBundleURL: Bundle.main.bundleURL)
        #else
        NativeGemmaGateOnlyRecordingBarrier()
        #endif
    }()

    /// Returns the sole production coordinator for this app process.
    ///
    /// Recording and every future native Gemma provider must share this exact instance so a
    /// second controller cannot bypass a lease held by another consumer.
    static func live() -> any NativeGemmaCoordinator {
        sharedLiveCoordinator
    }

    #if DEBUG
    static func testing(
        processGate: GemmaProcessGate,
        recordingGateTimeout: Duration = .seconds(2)
    ) -> any NativeGemmaCoordinator {
        NativeGemmaGateOnlyRecordingBarrier(
            processGate: processGate,
            recordingGateTimeout: recordingGateTimeout
        )
    }
    #endif

    #if DEBUG && canImport(StenoGemmaClient)
    static func testing(
        processGate: GemmaProcessGate,
        controllerInitializer: @escaping NativeGemmaClientInitializer
    ) -> any NativeGemmaCoordinator {
        NativeGemmaRecordingBarrierController(
            processGate: processGate,
            controllerInitializer: controllerInitializer
        )
    }
    #endif
}

private actor NativeGemmaGateOnlyRecordingBarrier: NativeGemmaCoordinator {
    private enum State {
        case idle
        case acquiring(UUID)
        case held(UUID, GemmaRecordingGateLease)
        case releasing(UUID)
    }

    private let processGateResult: Result<GemmaProcessGate, NativeGemmaCoordinatorError>
    private let recordingGateTimeout: Duration
    private var state: State = .idle

    init(
        processGate: GemmaProcessGate? = nil,
        recordingGateTimeout: Duration = .seconds(30)
    ) {
        if let processGate {
            processGateResult = .success(processGate)
        } else {
            do {
                processGateResult = .success(
                    GemmaProcessGate(configuration: try .production())
                )
            } catch {
                processGateResult = .failure(.gateUnavailable)
            }
        }
        self.recordingGateTimeout = recordingGateTimeout
    }

    func acquire() async throws {
        guard case .idle = state else {
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        guard case .success(let processGate) = processGateResult else {
            throw NativeGemmaCoordinatorError.gateUnavailable
        }

        let id = UUID()
        state = .acquiring(id)
        let deadline = ContinuousClock().now.advanced(by: recordingGateTimeout)
        do {
            let lease = try await processGate.acquireRecordingLease(until: deadline)
            guard case .acquiring(let currentID) = state,
                  currentID == id,
                  !Task.isCancelled
            else {
                lease.close()
                state = .idle
                throw NativeGemmaCoordinatorError.invalidTransition
            }
            state = .held(id, lease)
        } catch {
            if case .acquiring(let currentID) = state, currentID == id {
                state = .idle
            }
            throw error
        }
    }

    func release() async throws {
        guard case .held(let id, let lease) = state else {
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        state = .releasing(id)
        lease.close()
        guard case .releasing(let currentID) = state, currentID == id else {
            state = .idle
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        state = .idle
    }
}

#if canImport(StenoGemmaClient)
extension NativeGemmaCoordinator {
    func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody {
        throw NativeGemmaCoordinatorError.unavailable
    }
}

protocol NativeGemmaClientControlling: Sendable {
    func acquireRecordingLease(_ lease: GemmaRecordingLease) async throws -> GemmaRecordingLease
    func releaseRecordingLease(_ lease: GemmaRecordingLease) async throws
    func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody
}

extension GemmaClientController: NativeGemmaClientControlling {}

typealias NativeGemmaClientInitializer = @Sendable () async throws -> any NativeGemmaClientControlling

private actor NativeGemmaRecordingBarrierController: NativeGemmaCoordinator {
    private struct HeldRecording {
        let identifier: UUID
        let globalLease: GemmaRecordingGateLease
        let localLease: GemmaRecordingLease?
        let localController: (any NativeGemmaClientControlling)?
    }

    private enum RecordingState {
        case idle
        case acquiring(UUID)
        case held(HeldRecording)
        case releasing(UUID)
    }

    private enum ModelState {
        case uninitialized
        case initializing(
            id: UUID,
            task: Task<
                Result<any NativeGemmaClientControlling, NativeGemmaCoordinatorError>,
                Never
            >
        )
        case disabled
        case available(any NativeGemmaClientControlling)
        case faulted
    }

    private let processGateResult: Result<GemmaProcessGate, NativeGemmaCoordinatorError>
    private let controllerInitializer: NativeGemmaClientInitializer
    private let recordingGateTimeout: Duration
    private var modelState = ModelState.uninitialized
    private var recordingState = RecordingState.idle

    init(appBundleURL: URL) {
        let processGateResult: Result<GemmaProcessGate, NativeGemmaCoordinatorError>
        do {
            processGateResult = .success(
                GemmaProcessGate(configuration: try .production())
            )
        } catch {
            processGateResult = .failure(.gateUnavailable)
        }
        self.processGateResult = processGateResult
        recordingGateTimeout = .seconds(30)
        let helperBundleURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("StenoGemmaXPC.xpc", isDirectory: true)
        controllerInitializer = {
            guard case .success(let processGate) = processGateResult else {
                throw NativeGemmaCoordinatorError.gateUnavailable
            }
            let transportFactory = try GemmaRawXPCTransportFactory(
                helperBundleURL: helperBundleURL,
                processGate: processGate
            )
            return try GemmaClientController(
                maximumInFlightRequests: 2,
                transportFactory: transportFactory,
                exitProver: GemmaDispatchSourceExitProver(),
                deadline: GemmaContinuousClockDeadline(timeout: .seconds(30))
            )
        }
    }

    init(
        processGate: GemmaProcessGate,
        recordingGateTimeout: Duration = .seconds(2),
        controllerInitializer: @escaping NativeGemmaClientInitializer
    ) {
        processGateResult = .success(processGate)
        self.recordingGateTimeout = recordingGateTimeout
        self.controllerInitializer = controllerInitializer
    }

    func acquire() async throws {
        guard case .idle = recordingState else {
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        guard case .success(let processGate) = processGateResult else {
            throw NativeGemmaCoordinatorError.gateUnavailable
        }

        let acquisitionID = UUID()
        recordingState = .acquiring(acquisitionID)
        let deadline = ContinuousClock().now.advanced(by: recordingGateTimeout)
        let transition: GemmaRecordingGateTransition
        do {
            // Holding byte 0 begins cross-process preemption before cooperative local retirement.
            transition = try await processGate.beginRecordingTransition(until: deadline)
        } catch {
            if case .acquiring(let currentID) = recordingState,
               currentID == acquisitionID {
                recordingState = .idle
            }
            throw error
        }

        let localController: (any NativeGemmaClientControlling)?
        switch modelState {
        case .available(let controller):
            localController = controller
        case .uninitialized, .initializing, .disabled, .faulted:
            localController = nil
        }

        var localLease: GemmaRecordingLease?
        if let localController {
            let requestedLease = GemmaRecordingLease()
            do {
                localLease = try await localController.acquireRecordingLease(requestedLease)
            } catch {
                // Cooperative teardown is availability-only. Byte 1 remains the fail-closed proof.
                if !Self.isCancellation(error) {
                    modelState = .faulted
                }
            }
        }

        let globalLease: GemmaRecordingGateLease
        do {
            globalLease = try await transition.acquireRecordingLease(until: deadline)
        } catch {
            if let localLease, let localController {
                do {
                    try await localController.releaseRecordingLease(localLease)
                } catch {
                    modelState = .faulted
                }
            }
            if case .acquiring(let currentID) = recordingState,
               currentID == acquisitionID {
                recordingState = .idle
            }
            discardFaultedModelController()
            throw error
        }

        guard case .acquiring(let currentID) = recordingState,
              currentID == acquisitionID,
              !Task.isCancelled
        else {
            if let localLease, let localController {
                do {
                    try await localController.releaseRecordingLease(localLease)
                } catch {
                    modelState = .faulted
                }
            }
            globalLease.close()
            recordingState = .idle
            discardFaultedModelController()
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        recordingState = .held(HeldRecording(
            identifier: acquisitionID,
            globalLease: globalLease,
            localLease: localLease,
            localController: localController
        ))
    }

    func release() async throws {
        guard case .held(let held) = recordingState else {
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        recordingState = .releasing(held.identifier)

        if let localLease = held.localLease,
           let localController = held.localController {
            do {
                try await localController.releaseRecordingLease(localLease)
            } catch {
                modelState = .faulted
            }
        }
        held.globalLease.close()

        guard case .releasing(let currentID) = recordingState,
              currentID == held.identifier
        else {
            recordingState = .idle
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        recordingState = .idle
        // A model-only teardown fault cannot make a completed recording-gate release fail.
        // Discard the old controller so a later explicit model session starts from a fresh gate.
        discardFaultedModelController()
    }

    func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody {
        guard case .idle = recordingState else {
            throw NativeGemmaCoordinatorError.unavailable
        }
        try await initializeIfNeeded()
        guard case .idle = recordingState,
              case .available(let controller) = modelState else {
            throw NativeGemmaCoordinatorError.unavailable
        }
        do {
            return try await controller.send(body)
        } catch {
            if Self.requiresFreshController(after: error) {
                modelState = .uninitialized
            }
            throw error
        }
    }

    private func initializeIfNeeded() async throws {
        let initializationID: UUID
        let initializationTask: Task<
            Result<any NativeGemmaClientControlling, NativeGemmaCoordinatorError>,
            Never
        >
        switch modelState {
        case .uninitialized:
            initializationID = UUID()
            let controllerInitializer = self.controllerInitializer
            initializationTask = Task.detached {
                do {
                    return .success(try await controllerInitializer())
                } catch {
                    return .failure(.unavailable)
                }
            }
            // Publish the one shared task before the first suspension point.
            modelState = .initializing(id: initializationID, task: initializationTask)
        case .initializing(let id, let task):
            initializationID = id
            initializationTask = task
        case .disabled, .available, .faulted:
            return
        }

        let result = await initializationTask.value
        switch modelState {
        case .initializing(let currentID, _) where currentID == initializationID:
            switch result {
            case .success(let initializedController):
                modelState = .available(initializedController)
            case .failure(let error):
                modelState = .disabled
                throw error
            }
        case .disabled:
            throw NativeGemmaCoordinatorError.unavailable
        case .uninitialized, .initializing, .available, .faulted:
            // Another waiter already installed this exact initialization result or advanced the
            // coordinator state. Never overwrite that newer state after actor reentrancy.
            return
        }
    }

    private func discardFaultedModelController() {
        if case .faulted = modelState {
            modelState = .uninitialized
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? GemmaClientControllerError) == .requestCancelled
    }

    private static func requiresFreshController(after error: any Error) -> Bool {
        guard let error = error as? GemmaClientControllerError else { return false }
        switch error {
        case .faulted, .connectionFailed, .invalidResponse, .timedOut, .operationFailed:
            return true
        case .invalidInFlightLimit, .busy, .recordingActive,
             .recordingTransitionInProgress, .controlOperationNotAllowed,
             .remoteFailure, .requestCancelled, .cancelledForRecording,
             .invalidExitPreparation, .exitObservationMismatch, .exitArmMismatch,
             .authenticatedExitProofMismatch, .invalidRecordingLease,
             .modelSessionActive, .modelSessionRetiring, .modelSessionInactive,
             .modelAdmissionBusy:
            return false
        }
    }
}
#endif

enum NativeGemmaCoordinatorError: Error, Sendable {
    case unavailable
    case gateUnavailable
    case invalidTransition
}
