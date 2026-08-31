import Foundation
import StenoGemmaIPC

/// Owns the lazily created request registry and immutable model binding for one helper process.
///
/// Binding succeeds exactly once and only before any caller has forced model-free runtime
/// creation. Shutdown inspection never creates the runtime.
public final class GemmaServiceProcessRuntime: @unchecked Sendable {
    private final class Runtime: @unchecked Sendable {
        let registry: GemmaServiceRequestRegistry
        let core: GemmaServiceCore

        init(
            identity: GemmaIPCBoundHelperIdentity,
            boundModelExecutor: GemmaBoundModelExecutor?
        ) {
            registry = GemmaServiceRequestRegistry(
                helperIdentity: GemmaIPCPreparedHelperExit(
                    helperInstanceID: identity.helperInstanceID,
                    processIdentifier: identity.processIdentifier
                )
            )
            core = GemmaServiceCore(
                buildInfo: .current,
                boundModelExecutor: boundModelExecutor
            )
        }
    }

    public let boundHelperIdentity: GemmaIPCBoundHelperIdentity

    private let lock = NSLock()
    private var storedRuntime: Runtime?

    public init(boundHelperIdentity: GemmaIPCBoundHelperIdentity) {
        self.boundHelperIdentity = boundHelperIdentity
    }

    public var registry: GemmaServiceRequestRegistry {
        runtime().registry
    }

    public var core: GemmaServiceCore {
        runtime().core
    }

    /// Publishes one exact executor and creates the process runtime atomically.
    public func bindModelExecutor(_ executor: GemmaBoundModelExecutor) -> Bool {
        lock.withLock {
            guard storedRuntime == nil else { return false }
            storedRuntime = Runtime(
                identity: boundHelperIdentity,
                boundModelExecutor: executor
            )
            return true
        }
    }

    public func closeAdmissionIfCreated() {
        let runtime = lock.withLock { storedRuntime }
        _ = runtime?.registry.closeForShutdown()
    }

    public func markTerminatingAndReturnWasArmedIfCreated() -> Bool {
        let runtime = lock.withLock { storedRuntime }
        return runtime?.registry.markTerminatingAndReturnWasArmed() ?? false
    }

    private func runtime() -> Runtime {
        lock.withLock {
            if let storedRuntime {
                return storedRuntime
            }
            let runtime = Runtime(
                identity: boundHelperIdentity,
                boundModelExecutor: nil
            )
            storedRuntime = runtime
            return runtime
        }
    }
}
