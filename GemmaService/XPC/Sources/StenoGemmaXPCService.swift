import Darwin
import Dispatch
import Foundation
import Security
import StenoGemmaIPC
import StenoGemmaProcessGate
import StenoGemmaServiceCore
import XPC

/// Raw XPC service shell. It has no model, filesystem, network, or audio capability.
final class StenoGemmaXPCService: @unchecked Sendable {
    private enum AuthenticationState: Equatable {
        case unbound
        case authenticating
        case bound
        case terminal
    }

    private enum ExecutionGateState: Equatable {
        case awaitingBind
        case binding
        case bound
        case terminal
    }

    private let connection: xpc_connection_t
    private let expectedAppURL: URL
    private let expectedAppRequirement: String
    private let lifetimeID = UUID()
    private let lock = NSLock()
    private var authenticationState: AuthenticationState = .unbound
    private var executionGateState: ExecutionGateState = .awaitingBind
    private var authenticationTimeout: DispatchWorkItem?
    private var helperExecutionLease: GemmaModelExecutionLease?
    private var executionGateMonitor: GemmaHelperExecutionGateMonitor?

    init?(connection: xpc_connection_t) {
        guard let configuration = StenoGemmaXPCProcessConfiguration.current else { return nil }
        self.connection = connection
        expectedAppURL = configuration.expectedAppURL
        expectedAppRequirement = configuration.expectedAppRequirement
    }

    func activate() {
        guard xpc_connection_set_peer_code_signing_requirement(
            connection,
            expectedAppRequirement
        ) == 0 else {
            _exit(EXIT_FAILURE)
        }
        StenoGemmaXPCServiceLifetime.retain(self, for: lifetimeID)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            self?.receive(event)
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.expireUnauthenticatedPeer()
        }
        lock.withLock {
            authenticationTimeout = timeout
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(5),
            execute: timeout
        )
        xpc_connection_activate(connection)
    }

    private func receive(_ event: xpc_object_t) {
        if xpc_get_type(event) == XPC_TYPE_ERROR {
            let wasExecutionBound = finishConnection()
            StenoGemmaXPCServiceLifetime.release(lifetimeID)
            if wasExecutionBound {
                _exit(StenoGemmaXPCProcessLifecycle.boundPeerDisconnected(lifetimeID))
            }
            _exit(EXIT_FAILURE)
        }
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
            terminateInvalidPeer()
        }
        guard authenticatePeerIfNeeded(message: event) else {
            terminateInvalidPeer()
        }
        guard let outer = GemmaXPCOuterFrame.decode(event) else {
            terminateInvalidPeer()
        }

        routeAuthenticated(outer, replyTo: event)
    }

    private func routeAuthenticated(
        _ outer: GemmaXPCOuterFrame,
        replyTo event: xpc_object_t
    ) {
        let state = lock.withLock { executionGateState }
        switch state {
        case .awaitingBind:
            handleInitialBind(outer, replyTo: event)
        case .binding, .terminal:
            terminateInvalidPeer()
        case .bound:
            guard outer.executionGateDescriptor == nil else {
                terminateInvalidPeer()
            }
            handleBoundFrame(outer, replyTo: event)
        }
    }

    private func handleBoundFrame(
        _ outer: GemmaXPCOuterFrame,
        replyTo event: xpc_object_t
    ) {

        switch outer.channel {
        case .control:
            let control: GemmaXPCControlRequestEnvelope
            do {
                control = try GemmaXPCControlCodec.decodeRequest(outer.frame)
            } catch {
                terminateInvalidPeer()
            }
            guard control.requestID == outer.requestID else {
                terminateInvalidPeer()
            }
            if case .bindExecutionGate = control.body {
                terminateInvalidPeer()
            }
            handle(control: control, outerRequestID: outer.requestID, replyTo: event)
        case .model:
            handleModelFrame(outer, replyTo: event)
        }
    }

    private func handleInitialBind(
        _ outer: GemmaXPCOuterFrame,
        replyTo message: xpc_object_t
    ) {
        guard outer.channel == .control,
              let descriptorObject = outer.executionGateDescriptor,
              let control = try? GemmaXPCControlCodec.decodeRequest(outer.frame),
              control.requestID == outer.requestID,
              control.body == .bindExecutionGate
        else {
            terminateInvalidPeer()
        }
        let admitted = lock.withLock {
            guard executionGateState == .awaitingBind else { return false }
            executionGateState = .binding
            return true
        }
        guard admitted else {
            terminateInvalidPeer()
        }

        let duplicate = xpc_fd_dup(descriptorObject)
        guard duplicate >= 0 else {
            terminateInvalidPeer()
        }
        let lease: GemmaModelExecutionLease
        do {
            lease = try GemmaProcessGate.adoptHelperExecutionDescriptor(duplicate)
        } catch {
            terminateInvalidPeer()
        }
        do {
            if try GemmaProcessGate.helperObservesRecordingIntent(for: lease) {
                terminateForRecordingIntent()
            }
        } catch {
            terminateInvalidPeer()
        }

        let monitor = GemmaHelperExecutionGateMonitor(lease: lease)
        guard monitor.start() else {
            terminateInvalidPeer()
        }
        let identity = StenoGemmaXPCProcessRuntime.boundHelperIdentity
        let didBind = lock.withLock {
            guard executionGateState == .binding else { return false }
            helperExecutionLease = lease
            executionGateMonitor = monitor
            executionGateState = .bound
            return true
        }
        guard didBind else {
            terminateInvalidPeer()
        }
        guard sendControl(
            .executionGateBound(identity),
            for: outer.requestID,
            replyTo: message
        ) else {
            terminateInvalidPeer()
        }
    }

    private func authenticatePeerIfNeeded(message: xpc_object_t) -> Bool {
        let shouldAuthenticate: Bool = lock.withLock {
            switch authenticationState {
            case .bound:
                return false
            case .unbound:
                authenticationState = .authenticating
                authenticationTimeout?.cancel()
                authenticationTimeout = nil
                return true
            case .authenticating, .terminal:
                return false
            }
        }
        if !shouldAuthenticate {
            return lock.withLock { authenticationState == .bound }
        }

        guard GemmaXPCCodeIdentity.matchesCodeInXPCMessage(
            message,
            expectedBundleURL: expectedAppURL
        ) else {
            lock.withLock { authenticationState = .terminal }
            return false
        }
        guard StenoGemmaXPCProcessLifecycle.claimPeer(lifetimeID) else {
            lock.withLock { authenticationState = .terminal }
            return false
        }
        lock.withLock { authenticationState = .bound }
        return true
    }

    private func expireUnauthenticatedPeer() {
        let shouldCancel = lock.withLock {
            guard authenticationState == .unbound else { return false }
            authenticationState = .terminal
            authenticationTimeout = nil
            return true
        }
        if shouldCancel {
            _exit(EXIT_FAILURE)
        }
    }

    private func finishConnection() -> Bool {
        lock.withLock {
            authenticationTimeout?.cancel()
            authenticationTimeout = nil
            let wasBound = executionGateState == .bound
            authenticationState = .terminal
            executionGateState = .terminal
            return wasBound
        }
    }

    private func terminateInvalidPeer() -> Never {
        lock.withLock {
            authenticationTimeout?.cancel()
            authenticationTimeout = nil
            authenticationState = .terminal
            executionGateState = .terminal
        }
        StenoGemmaXPCProcessRuntime.closeAdmissionIfCreated()
        _exit(EXIT_FAILURE)
    }

    private func terminateForRecordingIntent() -> Never {
        lock.withLock {
            authenticationState = .terminal
            executionGateState = .terminal
        }
        StenoGemmaXPCProcessRuntime.closeAdmissionIfCreated()
        _exit(EXIT_SUCCESS)
    }

    private func handleModelFrame(_ outer: GemmaXPCOuterFrame, replyTo message: xpc_object_t) {
        let request: GemmaIPCRequestEnvelope
        do {
            request = try GemmaIPCCodec.decodeRequest(outer.frame)
        } catch let error as GemmaIPCCodecError {
            sendModelFailure(Self.failureCode(for: error), for: outer.requestID, replyTo: message)
            return
        } catch {
            sendModelFailure(.invalidRequest, for: outer.requestID, replyTo: message)
            return
        }
        guard request.requestID == outer.requestID else {
            sendModelFailure(.invalidRequest, for: outer.requestID, replyTo: message)
            return
        }
        guard let reply = xpc_dictionary_create_reply(message) else {
            return
        }
        let frame = outer.frame
        let requestID = outer.requestID
        let replyHandle = GemmaXPCReplyHandle(
            connection: connection,
            reply: reply,
            channel: .model
        )
        let replyOnce = GemmaServiceReplyOnce { [replyHandle] response in
            replyHandle.send(response, requestID: requestID)
        }

        switch request.body {
        case .cancel(let cancellation):
            guard let ticket = admitLifecycle(
                requestID: requestID,
                reply: replyOnce
            ) else { return }
            let changed = StenoGemmaXPCProcessRuntime.registry.cancel(
                cancellation.targetRequestID
            )
            completeModelLifecycle(
                ticket,
                requestID: requestID,
                body: .acknowledgement(.init(kind: .cancelled, didChangeState: changed))
            )

        case .shutdown:
            guard let ticket = admitLifecycle(
                requestID: requestID,
                reply: replyOnce
            ) else { return }
            let changed = StenoGemmaXPCProcessRuntime.registry.closeForShutdown()
            completeModelLifecycle(
                ticket,
                requestID: requestID,
                body: .acknowledgement(.init(kind: .shutdown, didChangeState: changed))
            )

        case .handshake, .countTokens, .generate:
            guard let cancellationResponse = Self.encodedModelResponse(
                requestID: requestID,
                body: .failure(.init(code: .cancelled))
            ) else {
                xpc_connection_cancel(connection)
                return
            }
            let inferenceLike = request.body.operation == .countTokens
                || request.body.operation == .generate
            let reservation = StenoGemmaXPCProcessRuntime.registry.reserveWork(
                requestID: requestID,
                inferenceLike: inferenceLike,
                cancellationResponse: cancellationResponse,
                reply: replyOnce
            )
            guard let ticket = admit(reservation, requestID: requestID, reply: replyOnce) else {
                return
            }
            _ = StenoGemmaXPCProcessRuntime.registry.start(ticket) {
                await StenoGemmaXPCProcessRuntime.core.handle(
                    encodedRequest: frame,
                    expectedRequestID: requestID
                )
            }
        }
    }

    private func admitLifecycle(
        requestID: UUID,
        reply: GemmaServiceReplyOnce
    ) -> GemmaServiceRequestRegistry.Ticket? {
        admit(
            StenoGemmaXPCProcessRuntime.registry.reserveLifecycle(
                requestID: requestID,
                reply: reply
            ),
            requestID: requestID,
            reply: reply
        )
    }

    private func admit(
        _ reservation: GemmaServiceRequestRegistry.Reservation,
        requestID: UUID,
        reply: GemmaServiceReplyOnce
    ) -> GemmaServiceRequestRegistry.Ticket? {
        switch reservation {
        case .admitted(let ticket):
            return ticket
        case .duplicateRequestID:
            replyModelFailure(.invalidRequest, for: requestID, reply: reply)
        case .busy:
            replyModelFailure(.busy, for: requestID, reply: reply)
        case .shuttingDown:
            replyModelFailure(.shuttingDown, for: requestID, reply: reply)
        }
        return nil
    }

    private func completeModelLifecycle(
        _ ticket: GemmaServiceRequestRegistry.Ticket,
        requestID: UUID,
        body: GemmaIPCResponseBody
    ) {
        guard let response = Self.encodedModelResponse(requestID: requestID, body: body) else {
            _exit(EXIT_FAILURE)
        }
        _ = StenoGemmaXPCProcessRuntime.registry.complete(ticket, response: response)
    }

    private func replyModelFailure(
        _ code: GemmaIPCErrorCode,
        for requestID: UUID,
        reply: GemmaServiceReplyOnce
    ) {
        guard let response = Self.encodedModelResponse(
            requestID: requestID,
            body: .failure(.init(code: code))
        ) else {
            _exit(EXIT_FAILURE)
        }
        _ = reply.send(response)
    }

    private static func encodedModelResponse(
        requestID: UUID,
        body: GemmaIPCResponseBody
    ) -> Data? {
        try? GemmaIPCCodec.encode(
            GemmaIPCResponseEnvelope(requestID: requestID, body: body)
        )
    }

    private static func failureCode(for error: GemmaIPCCodecError) -> GemmaIPCErrorCode {
        switch error {
        case .malformedMessage:
            .invalidRequest
        case .oversizedMessage:
            .requestTooLarge
        case .protocolMismatch:
            .protocolMismatch
        }
    }

    private func handle(
        control: GemmaXPCControlRequestEnvelope,
        outerRequestID: UUID,
        replyTo message: xpc_object_t
    ) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        let replyHandle = GemmaXPCReplyHandle(
            connection: connection,
            reply: reply,
            channel: .control
        )
        let replyOnce = GemmaServiceReplyOnce { [replyHandle] response in
            replyHandle.send(response, requestID: outerRequestID)
        }
        guard let ticket = admitControlLifecycle(
            requestID: outerRequestID,
            reply: replyOnce
        ) else { return }

        switch control.body {
        case .bindExecutionGate:
            terminateInvalidPeer()

        case .prepareForExit:
            guard case .accepted = StenoGemmaXPCProcessRuntime.registry.beginPrepareForExit() else {
                completeControl(
                    ticket,
                    requestID: outerRequestID,
                    body: .failure(.init(code: .shuttingDown))
                )
                return
            }
            let started = StenoGemmaXPCProcessRuntime.registry.start(ticket) {
                await StenoGemmaXPCProcessRuntime.registry.waitForWorkQuiescence()
                guard let identity = StenoGemmaXPCProcessRuntime.registry.finishPrepareForExit(),
                      let response = Self.encodedControlResponse(
                          requestID: outerRequestID,
                          body: .prepared(identity)
                      )
                else {
                    _exit(EXIT_FAILURE)
                }
                return response
            }
            if !started {
                _exit(EXIT_FAILURE)
            }

        case .armAndExit(let request):
            let started = StenoGemmaXPCProcessRuntime.registry.start(ticket) {
                guard StenoGemmaXPCProcessRuntime.registry.beginArmAndExit(
                    request.preparedHelper,
                    armRequest: ticket
                ) else {
                    guard let response = Self.encodedControlResponse(
                        requestID: outerRequestID,
                        body: .failure(.init(code: .invalidRequest))
                    ) else {
                        _exit(EXIT_FAILURE)
                    }
                    return response
                }
                await StenoGemmaXPCProcessRuntime.registry.waitUntilReadyToArm(
                    excluding: ticket
                )
                let body: GemmaXPCControlResponseBody
                if StenoGemmaXPCProcessRuntime.registry.finishArmAndExit(
                    request.preparedHelper,
                    armRequest: ticket
                ) {
                    body = .armed(request.preparedHelper)
                } else {
                    body = .failure(.init(code: .invalidRequest))
                }
                guard let response = Self.encodedControlResponse(
                    requestID: outerRequestID,
                    body: body
                ) else {
                    _exit(EXIT_FAILURE)
                }
                return response
            }
            if !started {
                _exit(EXIT_FAILURE)
            }
        }
    }

    private func admitControlLifecycle(
        requestID: UUID,
        reply: GemmaServiceReplyOnce
    ) -> GemmaServiceRequestRegistry.Ticket? {
        let reservation = StenoGemmaXPCProcessRuntime.registry.reserveLifecycle(
            requestID: requestID,
            reply: reply
        )
        switch reservation {
        case .admitted(let ticket):
            return ticket
        case .duplicateRequestID:
            replyControlFailure(.invalidRequest, for: requestID, reply: reply)
        case .busy:
            replyControlFailure(.busy, for: requestID, reply: reply)
        case .shuttingDown:
            replyControlFailure(.shuttingDown, for: requestID, reply: reply)
        }
        return nil
    }

    private func completeControl(
        _ ticket: GemmaServiceRequestRegistry.Ticket,
        requestID: UUID,
        body: GemmaXPCControlResponseBody
    ) {
        guard let response = Self.encodedControlResponse(requestID: requestID, body: body) else {
            _exit(EXIT_FAILURE)
        }
        _ = StenoGemmaXPCProcessRuntime.registry.complete(ticket, response: response)
    }

    private func replyControlFailure(
        _ code: GemmaIPCErrorCode,
        for requestID: UUID,
        reply: GemmaServiceReplyOnce
    ) {
        guard let response = Self.encodedControlResponse(
            requestID: requestID,
            body: .failure(.init(code: code))
        ) else {
            _exit(EXIT_FAILURE)
        }
        _ = reply.send(response)
    }

    private static func encodedControlResponse(
        requestID: UUID,
        body: GemmaXPCControlResponseBody
    ) -> Data? {
        try? GemmaXPCControlCodec.encode(
            GemmaXPCControlResponseEnvelope(requestID: requestID, body: body)
        )
    }

    private func sendModelFailure(
        _ code: GemmaIPCErrorCode,
        for requestID: UUID,
        replyTo message: xpc_object_t
    ) {
        let response = GemmaIPCResponseEnvelope(
            requestID: requestID,
            body: .failure(.init(code: code))
        )
        guard let data = try? GemmaIPCCodec.encode(response) else { return }
        send(data, requestID: requestID, channel: .model, replyTo: message)
    }

    @discardableResult
    private func sendControl(
        _ body: GemmaXPCControlResponseBody,
        for requestID: UUID,
        replyTo message: xpc_object_t
    ) -> Bool {
        let response = GemmaXPCControlResponseEnvelope(requestID: requestID, body: body)
        guard let data = try? GemmaXPCControlCodec.encode(response) else { return false }
        return send(data, requestID: requestID, channel: .control, replyTo: message)
    }

    @discardableResult
    private func send(
        _ data: Data,
        requestID: UUID,
        channel: GemmaXPCChannel,
        replyTo message: xpc_object_t
    ) -> Bool {
        guard let reply = xpc_dictionary_create_reply(message) else { return false }
        GemmaXPCOuterFrame.write(
            data,
            requestID: requestID,
            channel: channel,
            to: reply
        )
        xpc_connection_send_message(connection, reply)
        return true
    }
}

/// Process-wide state prevents a second XPC peer from bypassing a recording teardown.
private enum StenoGemmaXPCProcessLifecycle {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var activePeer: UUID?
    }

    private static let storage = Storage()

    static func claimPeer(_ peer: UUID) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard storage.activePeer == nil || storage.activePeer == peer
        else { return false }
        storage.activePeer = peer
        return true
    }

    static func boundPeerDisconnected(_ peer: UUID) -> Int32 {
        let wasActivePeer = storage.lock.withLock {
            storage.activePeer == peer
        }
        guard wasActivePeer else { return EXIT_FAILURE }
        // Keep the peer claimed until the caller immediately exits the process. Clearing it here
        // would leave a small window in which a new connection could bind after termination began.
        return StenoGemmaXPCProcessRuntime.markTerminatingAndReturnWasArmedIfCreated()
            ? EXIT_SUCCESS
            : EXIT_FAILURE
    }
}

/// Model state is created lazily only after an authenticated peer has bound its execution gate.
private enum StenoGemmaXPCProcessRuntime {
    final class Runtime: @unchecked Sendable {
        let registry: GemmaServiceRequestRegistry
        let core: GemmaServiceCore

        init(identity: GemmaIPCBoundHelperIdentity) {
            registry = GemmaServiceRequestRegistry(
                helperIdentity: GemmaIPCPreparedHelperExit(
                    helperInstanceID: identity.helperInstanceID,
                    processIdentifier: identity.processIdentifier
                )
            )
            core = GemmaServiceCore(buildInfo: .current)
        }
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var runtime: Runtime?
    }

    static let boundHelperIdentity = GemmaIPCBoundHelperIdentity(
        helperInstanceID: UUID(),
        processIdentifier: getpid()
    )
    private static let storage = Storage()

    static var registry: GemmaServiceRequestRegistry {
        runtime().registry
    }

    static var core: GemmaServiceCore {
        runtime().core
    }

    static func closeAdmissionIfCreated() {
        let runtime = storage.lock.withLock { storage.runtime }
        _ = runtime?.registry.closeForShutdown()
    }

    static func markTerminatingAndReturnWasArmedIfCreated() -> Bool {
        let runtime = storage.lock.withLock { storage.runtime }
        return runtime?.registry.markTerminatingAndReturnWasArmed() ?? false
    }

    private static func runtime() -> Runtime {
        storage.lock.withLock {
            if let runtime = storage.runtime {
                return runtime
            }
            let runtime = Runtime(identity: boundHelperIdentity)
            storage.runtime = runtime
            return runtime
        }
    }
}

/// Expensive static-code validation is performed at most once per helper process.
private struct StenoGemmaXPCProcessConfiguration {
    let expectedAppURL: URL
    let expectedAppRequirement: String

    static let current: StenoGemmaXPCProcessConfiguration? = {
        let helper = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let contents = helper.deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard app.pathExtension == "app",
              GemmaXPCCodeIdentity.helperSecurityProfileIsSafe(helperBundleURL: helper),
              let requirement = try? GemmaXPCCodeIdentity.designatedRequirement(
                  forBundleAt: app
              )
        else {
            return nil
        }
        return StenoGemmaXPCProcessConfiguration(
            expectedAppURL: app,
            expectedAppRequirement: requirement
        )
    }()
}

/// `xpc_main` gives the peer handler only a transient connection reference.
/// Keep its service strongly reachable until XPC reports that peer invalidation.
private enum StenoGemmaXPCServiceLifetime {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var services: [UUID: StenoGemmaXPCService] = [:]
    }

    private static let storage = Storage()

    static func retain(_ service: StenoGemmaXPCService, for identifier: UUID) {
        storage.lock.lock()
        storage.services[identifier] = service
        storage.lock.unlock()
    }

    static func release(_ identifier: UUID) {
        storage.lock.lock()
        storage.services.removeValue(forKey: identifier)
        storage.lock.unlock()
    }
}

private struct GemmaXPCOuterFrame {
    let channel: GemmaXPCChannel
    let frame: Data
    let requestID: UUID
    let executionGateDescriptor: xpc_object_t?

    private static let channelKey = "channel"
    private static let frameKey = "frame"
    private static let requestIDKey = "requestID"
    private static let executionGateFDKey = "executionGateFD"

    static func decode(_ message: xpc_object_t) -> GemmaXPCOuterFrame? {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
              let executionGateDescriptor = validatedExecutionGateDescriptor(message),
              let channelValue = xpc_dictionary_get_string(message, channelKey),
              let channel = GemmaXPCChannel(rawValue: String(cString: channelValue)),
              let requestIDBytes = xpc_dictionary_get_uuid(message, requestIDKey)
        else {
            return nil
        }
        var length = 0
        guard let dataBytes = xpc_dictionary_get_data(message, frameKey, &length),
              length <= GemmaIPCProtocol.maximumEncodedMessageBytes
        else {
            return nil
        }
        let uuid = UnsafeRawPointer(requestIDBytes)
            .assumingMemoryBound(to: uuid_t.self)
            .pointee
        return GemmaXPCOuterFrame(
            channel: channel,
            frame: Data(bytes: dataBytes, count: length),
            requestID: UUID(uuid: uuid),
            executionGateDescriptor: executionGateDescriptor.value
        )
    }

    static func write(
        _ frame: Data,
        requestID: UUID,
        channel: GemmaXPCChannel,
        to dictionary: xpc_object_t
    ) {
        xpc_dictionary_set_string(dictionary, channelKey, channel.rawValue)
        var uuid = requestID.uuid
        withUnsafePointer(to: &uuid) { pointer in
            xpc_dictionary_set_uuid(dictionary, requestIDKey, pointer)
        }
        frame.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(dictionary, frameKey, bytes.baseAddress, frame.count)
        }
    }

    private struct OptionalDescriptor {
        let value: xpc_object_t?
    }

    private static func validatedExecutionGateDescriptor(
        _ dictionary: xpc_object_t
    ) -> OptionalDescriptor? {
        var keys = Set<String>()
        let accepted = xpc_dictionary_apply(dictionary) { key, _ in
            keys.insert(String(cString: key))
            return true
        }
        guard accepted else { return nil }
        let ordinaryKeys = Set([channelKey, frameKey, requestIDKey])
        if keys == ordinaryKeys {
            return OptionalDescriptor(value: nil)
        }
        guard keys == ordinaryKeys.union([executionGateFDKey]),
              let descriptor = xpc_dictionary_get_value(dictionary, executionGateFDKey),
              xpc_get_type(descriptor) == XPC_TYPE_FD
        else {
            return nil
        }
        return OptionalDescriptor(value: descriptor)
    }
}

/// Polls admission byte 0 every 20 ms on a dedicated lightweight queue.
///
/// Registration and one synchronous intent check both complete before the bind acknowledgement.
/// The request registry remains the authority for closing admission and cancelling active work.
private final class GemmaHelperExecutionGateMonitor: @unchecked Sendable {
    private static let pollInterval = DispatchTimeInterval.milliseconds(20)

    private let lease: GemmaModelExecutionLease
    private let source: any DispatchSourceTimer
    private let registration = DispatchSemaphore(value: 0)

    init(lease: GemmaModelExecutionLease) {
        self.lease = lease
        let queue = DispatchQueue(
            label: "org.stenolabs.steno.gemma-xpc-gate-monitor",
            qos: .userInitiated
        )
        source = DispatchSource.makeTimerSource(queue: queue)
        source.setRegistrationHandler { [registration] in
            registration.signal()
        }
        source.setEventHandler { [lease] in
            do {
                guard try GemmaProcessGate.helperObservesRecordingIntent(for: lease) else {
                    return
                }
                StenoGemmaXPCProcessRuntime.closeAdmissionIfCreated()
                _exit(EXIT_SUCCESS)
            } catch {
                StenoGemmaXPCProcessRuntime.closeAdmissionIfCreated()
                _exit(EXIT_FAILURE)
            }
        }
        source.schedule(
            deadline: .now(),
            repeating: Self.pollInterval,
            leeway: .milliseconds(2)
        )
    }

    func start() -> Bool {
        source.activate()
        return registration.wait(timeout: .now() + .seconds(1)) == .success
    }
}

private final class GemmaXPCReplyHandle: @unchecked Sendable {
    private let connection: xpc_connection_t
    private let reply: xpc_object_t
    private let channel: GemmaXPCChannel

    init(
        connection: xpc_connection_t,
        reply: xpc_object_t,
        channel: GemmaXPCChannel
    ) {
        self.connection = connection
        self.reply = reply
        self.channel = channel
    }

    func send(_ frame: Data, requestID: UUID) {
        GemmaXPCOuterFrame.write(
            frame,
            requestID: requestID,
            channel: channel,
            to: reply
        )
        xpc_connection_send_message(connection, reply)
    }
}

private enum GemmaXPCCodeIdentity {
    private static let strictAppValidationFlags = SecCSFlags(
        rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
    )
    private static let strictHelperValidationFlags = SecCSFlags(
        rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
    )

    static func designatedRequirement(forBundleAt bundleURL: URL) throws -> String {
        let expectedURL = canonical(bundleURL)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(expectedURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, strictAppValidationFlags, nil) == errSecSuccess
        else {
            throw GemmaXPCSecurityError.untrustedCode
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement
        else {
            throw GemmaXPCSecurityError.untrustedCode
        }
        var requirementString: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &requirementString) == errSecSuccess,
              let requirementString
        else {
            throw GemmaXPCSecurityError.untrustedCode
        }
        return requirementString as String
    }

    static func matchesCodeInXPCMessage(
        _ message: xpc_object_t,
        expectedBundleURL: URL
    ) -> Bool {
        var dynamicCode: SecCode?
        guard SecCodeCreateWithXPCMessage(message, SecCSFlags(), &dynamicCode) == errSecSuccess,
              let dynamicCode,
              SecCodeCheckValidity(dynamicCode, SecCSFlags(), nil) == errSecSuccess
        else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return false
        }
        var peerURL: CFURL?
        guard SecCodeCopyPath(staticCode, SecCSFlags(), &peerURL) == errSecSuccess,
              let peerURL
        else {
            return false
        }
        return canonical(peerURL as URL) == canonical(expectedBundleURL)
    }

    static func helperSecurityProfileIsSafe(helperBundleURL: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            canonical(helperBundleURL) as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
        let code,
        SecStaticCodeCheckValidity(code, strictHelperValidationFlags, nil) == errSecSuccess
        else {
            return false
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [CFString: Any],
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict] as? [String: Any],
        (entitlements["com.apple.security.app-sandbox"] as? Bool) == true,
        (entitlements["com.apple.security.network.client"] as? Bool) != true,
        (entitlements["com.apple.security.network.server"] as? Bool) != true
        else {
            return false
        }
        return true
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private enum GemmaXPCSecurityError: Error {
    case untrustedCode
}
