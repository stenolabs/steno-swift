import Foundation

#if canImport(StenoGemmaClient)
import StenoGemmaClient
import StenoGemmaIPC
#endif

/// Keeps the native Gemma helper absent for the entire audio-capture lifetime.
///
/// Implementations must fail closed: returning from `acquire()` proves that no helper owned by
/// this coordinator can still execute, and `release()` must not create or reconnect a helper.
/// Every future native Gemma provider must send through this same coordinator.
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
        NativeGemmaUnavailableRecordingBarrier()
        #endif
    }()

    /// Returns the sole production coordinator for this app process.
    ///
    /// Recording and every future native Gemma provider must share this exact instance so a
    /// second controller cannot bypass a lease held by another consumer.
    static func live() -> any NativeGemmaCoordinator {
        sharedLiveCoordinator
    }

    #if DEBUG && canImport(StenoGemmaClient)
    static func testing(
        controllerInitializer: @escaping NativeGemmaClientInitializer
    ) -> any NativeGemmaCoordinator {
        NativeGemmaRecordingBarrierController(
            controllerInitializer: controllerInitializer
        )
    }
    #endif
}

private actor NativeGemmaUnavailableRecordingBarrier: NativeGemmaCoordinator {
    func acquire() {}
    func release() {}
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
    private enum State {
        case uninitialized
        case initializing(
            id: UUID,
            task: Task<
                Result<any NativeGemmaClientControlling, NativeGemmaCoordinatorError>,
                Never
            >
        )
        case disabled
        case available
        case acquiring(GemmaRecordingLease)
        case held(GemmaRecordingLease)
        case faulted
    }

    private let controllerInitializer: NativeGemmaClientInitializer
    private var controller: (any NativeGemmaClientControlling)?
    private var state = State.uninitialized

    init(appBundleURL: URL) {
        let helperBundleURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("StenoGemmaXPC.xpc", isDirectory: true)
        controllerInitializer = {
            let transportFactory = try GemmaRawXPCTransportFactory(
                helperBundleURL: helperBundleURL
            )
            return try GemmaClientController(
                maximumInFlightRequests: 2,
                transportFactory: transportFactory,
                exitProver: GemmaDispatchSourceExitProver(),
                deadline: GemmaContinuousClockDeadline(timeout: .seconds(30))
            )
        }
    }

    init(controllerInitializer: @escaping NativeGemmaClientInitializer) {
        self.controllerInitializer = controllerInitializer
    }

    func acquire() async throws {
        do {
            try await initializeIfNeeded()
        } catch {
            // A helper that failed static validation was never connected or launched.
            // Native Gemma remains unavailable while recording itself stays usable.
            state = .disabled
        }
        if case .disabled = state {
            return
        }
        guard case .available = state else {
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        guard let controller else {
            state = .faulted
            throw NativeGemmaCoordinatorError.invalidTransition
        }

        // Create and retain the capability before awaiting so cancellation cannot lose an
        // ambiguously returned lease.
        let requestedLease = GemmaRecordingLease()
        state = .acquiring(requestedLease)
        do {
            let lease = try await controller.acquireRecordingLease(requestedLease)
            guard case .acquiring(let expectedLease) = state,
                  expectedLease == lease
            else {
                state = .faulted
                throw NativeGemmaCoordinatorError.invalidTransition
            }
            state = .held(lease)
        } catch {
            state = .faulted
            throw error
        }
    }

    func release() async throws {
        if case .disabled = state {
            return
        }
        guard case .held(let lease) = state else {
            state = .faulted
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        guard let controller else {
            state = .faulted
            throw NativeGemmaCoordinatorError.invalidTransition
        }
        do {
            try await controller.releaseRecordingLease(lease)
            state = .available
        } catch {
            state = .faulted
            throw error
        }
    }

    func send(_ body: GemmaIPCRequestBody) async throws -> GemmaIPCResponseBody {
        try await initializeIfNeeded()
        guard case .available = state,
              let controller
        else {
            throw NativeGemmaCoordinatorError.unavailable
        }
        return try await controller.send(body)
    }

    private func initializeIfNeeded() async throws {
        let initializationID: UUID
        let initializationTask: Task<
            Result<any NativeGemmaClientControlling, NativeGemmaCoordinatorError>,
            Never
        >
        switch state {
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
            state = .initializing(id: initializationID, task: initializationTask)
        case .initializing(let id, let task):
            initializationID = id
            initializationTask = task
        case .disabled, .available, .acquiring, .held, .faulted:
            return
        }

        let result = await initializationTask.value
        switch state {
        case .initializing(let currentID, _) where currentID == initializationID:
            switch result {
            case .success(let initializedController):
                controller = initializedController
                state = .available
            case .failure(let error):
                state = .disabled
                throw error
            }
        case .disabled:
            throw NativeGemmaCoordinatorError.unavailable
        case .uninitialized, .initializing, .available, .acquiring, .held, .faulted:
            // Another waiter already installed this exact initialization result or advanced the
            // coordinator state. Never overwrite that newer state after actor reentrancy.
            return
        }
    }
}
#endif

enum NativeGemmaCoordinatorError: Error, Sendable {
    case unavailable
    case invalidTransition
}
