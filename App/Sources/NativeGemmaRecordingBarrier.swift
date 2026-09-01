import Foundation
#if STENO_NATIVE_GEMMA_MODEL_STORE
import StenoDomain
#endif
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

    #if STENO_NATIVE_GEMMA_MODEL_STORE
    func performModelImport(
        _ operation: @escaping @Sendable () async throws -> NativeGemmaModelSnapshot
    ) async throws -> NativeGemmaModelSnapshot
    #endif

    #if canImport(StenoGemmaClient)
    func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody
    #endif
}

#if STENO_NATIVE_GEMMA_MODEL_STORE
/// Serializes native Gemma imports with recording without coupling the model store to audio.
///
/// Recording intent is published before cancellation begins. A new import therefore cannot enter
/// the gap between cancellation and the process-level recording lease. Import cancellation is only
/// a request: recording admission waits for the exact task to finish, including any intentionally
/// non-cancellable post-publication synchronization and verification.
private actor NativeGemmaImportRecordingGate {
    struct RecordingLease: Hashable, Sendable {
        fileprivate let identifier: UUID
    }

    private enum State {
        case idle
        case importing(
            id: UUID,
            task: Task<NativeGemmaModelSnapshot, any Error>
        )
        case drainingForRecording(
            recordingID: UUID,
            importID: UUID,
            task: Task<NativeGemmaModelSnapshot, any Error>
        )
        case recording(UUID)
    }

    private var state: State = .idle

    func performImport(
        _ operation: @escaping @Sendable () async throws -> NativeGemmaModelSnapshot
    ) async throws -> NativeGemmaModelSnapshot {
        guard case .idle = state else {
            throw NativeGemmaCoordinatorError.unavailable
        }

        let importID = UUID()
        let task = Task.detached {
            try await operation()
        }
        state = .importing(id: importID, task: task)

        return try await withTaskCancellationHandler {
            let result = await task.result
            clearImportIfCurrent(importID)
            return try result.get()
        } onCancel: {
            task.cancel()
        }
    }

    func acquireRecordingLease() async throws -> RecordingLease {
        let recordingID = UUID()
        switch state {
        case .idle:
            state = .recording(recordingID)
            return RecordingLease(identifier: recordingID)

        case .importing(let importID, let task):
            state = .drainingForRecording(
                recordingID: recordingID,
                importID: importID,
                task: task
            )
            task.cancel()
            _ = await task.result

            guard case .drainingForRecording(
                let currentRecordingID,
                let currentImportID,
                _
            ) = state,
                currentRecordingID == recordingID,
                currentImportID == importID
            else {
                await recoverToIdle()
                throw NativeGemmaCoordinatorError.invalidTransition
            }
            guard !Task.isCancelled else {
                state = .idle
                throw CancellationError()
            }
            state = .recording(recordingID)
            return RecordingLease(identifier: recordingID)

        case .drainingForRecording, .recording:
            throw NativeGemmaCoordinatorError.invalidTransition
        }
    }

    func releaseRecordingLease(_ lease: RecordingLease) async {
        guard case .recording(let identifier) = state,
              identifier == lease.identifier
        else {
            await recoverToIdle()
            return
        }
        state = .idle
    }

    /// Recovers bookkeeping without ever abandoning a still-running import.
    private func recoverToIdle() async {
        switch state {
        case .idle:
            return

        case .recording:
            state = .idle

        case .importing(let importID, let task):
            state = .drainingForRecording(
                recordingID: UUID(),
                importID: importID,
                task: task
            )
            task.cancel()
            _ = await task.result
            state = .idle

        case .drainingForRecording(_, _, let task):
            task.cancel()
            _ = await task.result
            state = .idle
        }
    }

    private func clearImportIfCurrent(_ importID: UUID) {
        guard case .importing(let currentID, _) = state,
              currentID == importID
        else { return }
        state = .idle
    }
}
#endif

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
        #if STENO_NATIVE_GEMMA_MODEL_STORE
        case held(
            UUID,
            GemmaRecordingGateLease,
            NativeGemmaImportRecordingGate.RecordingLease
        )
        #else
        case held(UUID, GemmaRecordingGateLease)
        #endif
        case releasing(UUID)
    }

    private let processGateResult: Result<GemmaProcessGate, NativeGemmaCoordinatorError>
    private let recordingGateTimeout: Duration
    #if STENO_NATIVE_GEMMA_MODEL_STORE
    private let importRecordingGate = NativeGemmaImportRecordingGate()
    #endif
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
        let id = UUID()
        state = .acquiring(id)

        #if STENO_NATIVE_GEMMA_MODEL_STORE
        let importRecordingLease: NativeGemmaImportRecordingGate.RecordingLease
        do {
            importRecordingLease = try await importRecordingGate.acquireRecordingLease()
        } catch {
            if case .acquiring(let currentID) = state, currentID == id {
                state = .idle
            }
            throw error
        }
        guard case .acquiring(let currentID) = state,
              currentID == id,
              !Task.isCancelled
        else {
            await importRecordingGate.releaseRecordingLease(importRecordingLease)
            state = .idle
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        #endif

        guard case .success(let processGate) = processGateResult else {
            #if STENO_NATIVE_GEMMA_MODEL_STORE
            await importRecordingGate.releaseRecordingLease(importRecordingLease)
            #endif
            state = .idle
            throw NativeGemmaCoordinatorError.gateUnavailable
        }

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
            #if STENO_NATIVE_GEMMA_MODEL_STORE
            state = .held(id, lease, importRecordingLease)
            #else
            state = .held(id, lease)
            #endif
        } catch {
            #if STENO_NATIVE_GEMMA_MODEL_STORE
            await importRecordingGate.releaseRecordingLease(importRecordingLease)
            #endif
            if case .acquiring(let currentID) = state, currentID == id {
                state = .idle
            }
            throw error
        }
    }

    func release() async throws {
        #if STENO_NATIVE_GEMMA_MODEL_STORE
        guard case .held(let id, let lease, let importRecordingLease) = state else {
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        #else
        guard case .held(let id, let lease) = state else {
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        #endif
        state = .releasing(id)
        lease.close()
        #if STENO_NATIVE_GEMMA_MODEL_STORE
        await importRecordingGate.releaseRecordingLease(importRecordingLease)
        #endif
        guard case .releasing(let currentID) = state, currentID == id else {
            state = .idle
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        state = .idle
    }

    #if STENO_NATIVE_GEMMA_MODEL_STORE
    func performModelImport(
        _ operation: @escaping @Sendable () async throws -> NativeGemmaModelSnapshot
    ) async throws -> NativeGemmaModelSnapshot {
        guard case .idle = state else {
            throw NativeGemmaCoordinatorError.unavailable
        }
        return try await importRecordingGate.performImport(operation)
    }
    #endif
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
        #if STENO_NATIVE_GEMMA_MODEL_STORE
        let importRecordingLease: NativeGemmaImportRecordingGate.RecordingLease
        #endif
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
    #if STENO_NATIVE_GEMMA_MODEL_STORE
    private let importRecordingGate = NativeGemmaImportRecordingGate()
    #endif
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
                processGate: processGate,
                resolveModelDirectory: { _ in
                    // Activation remains fail closed until the installed-model store can vend a
                    // fresh descriptor-rooted capability for the exact requested snapshot.
                    throw NativeGemmaCoordinatorError.unavailable
                }
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
        let acquisitionID = UUID()
        recordingState = .acquiring(acquisitionID)

        #if STENO_NATIVE_GEMMA_MODEL_STORE
        let importRecordingLease: NativeGemmaImportRecordingGate.RecordingLease
        do {
            importRecordingLease = try await importRecordingGate.acquireRecordingLease()
        } catch {
            if case .acquiring(let currentID) = recordingState,
               currentID == acquisitionID {
                recordingState = .idle
            }
            throw error
        }
        guard case .acquiring(let currentID) = recordingState,
              currentID == acquisitionID,
              !Task.isCancelled
        else {
            await importRecordingGate.releaseRecordingLease(importRecordingLease)
            recordingState = .idle
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        #endif

        guard case .success(let processGate) = processGateResult else {
            #if STENO_NATIVE_GEMMA_MODEL_STORE
            await importRecordingGate.releaseRecordingLease(importRecordingLease)
            #endif
            recordingState = .idle
            throw NativeGemmaCoordinatorError.gateUnavailable
        }

        let deadline = ContinuousClock().now.advanced(by: recordingGateTimeout)
        let transition: GemmaRecordingGateTransition
        do {
            // Holding byte 0 begins cross-process preemption before cooperative local retirement.
            transition = try await processGate.beginRecordingTransition(until: deadline)
        } catch {
            #if STENO_NATIVE_GEMMA_MODEL_STORE
            await importRecordingGate.releaseRecordingLease(importRecordingLease)
            #endif
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
            #if STENO_NATIVE_GEMMA_MODEL_STORE
            await importRecordingGate.releaseRecordingLease(importRecordingLease)
            #endif
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
            discardFaultedModelController()
            #if STENO_NATIVE_GEMMA_MODEL_STORE
            await importRecordingGate.releaseRecordingLease(importRecordingLease)
            #endif
            recordingState = .idle
            throw NativeGemmaCoordinatorError.invalidTransition
        }

        #if STENO_NATIVE_GEMMA_MODEL_STORE
        recordingState = .held(HeldRecording(
            identifier: acquisitionID,
            globalLease: globalLease,
            importRecordingLease: importRecordingLease,
            localLease: localLease,
            localController: localController
        ))
        #else
        recordingState = .held(HeldRecording(
            identifier: acquisitionID,
            globalLease: globalLease,
            localLease: localLease,
            localController: localController
        ))
        #endif
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
        #if STENO_NATIVE_GEMMA_MODEL_STORE
        await importRecordingGate.releaseRecordingLease(held.importRecordingLease)
        #endif

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

    #if STENO_NATIVE_GEMMA_MODEL_STORE
    func performModelImport(
        _ operation: @escaping @Sendable () async throws -> NativeGemmaModelSnapshot
    ) async throws -> NativeGemmaModelSnapshot {
        guard case .idle = recordingState else {
            throw NativeGemmaCoordinatorError.unavailable
        }
        return try await importRecordingGate.performImport(operation)
    }
    #endif

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
             .modelPinMismatch, .modelAdmissionBusy:
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
