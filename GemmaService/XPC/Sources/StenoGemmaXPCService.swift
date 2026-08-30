import Darwin
import Dispatch
import Foundation
import Security
import StenoGemmaIPC
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

    private let connection: xpc_connection_t
    private let expectedAppURL: URL
    private let expectedAppRequirement: String
    private let lifetimeID = UUID()
    private let lock = NSLock()
    private var authenticationState: AuthenticationState = .unbound
    private var authenticationTimeout: DispatchWorkItem?

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
            xpc_connection_cancel(connection)
            return
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
            let wasBound = finishConnection()
            StenoGemmaXPCServiceLifetime.release(lifetimeID)
            if wasBound {
                _exit(StenoGemmaXPCProcessLifecycle.boundPeerDisconnected(lifetimeID))
            }
            return
        }
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
            return
        }
        guard authenticatePeerIfNeeded(message: event) else {
            return
        }
        guard let outer = GemmaXPCOuterFrame.decode(event) else {
            xpc_connection_cancel(connection)
            return
        }

        switch outer.channel {
        case .control:
            let control: GemmaXPCControlRequestEnvelope
            do {
                control = try GemmaXPCControlCodec.decodeRequest(outer.frame)
            } catch let error as GemmaIPCCodecError {
                sendControlFailure(Self.failureCode(for: error), for: outer.requestID, replyTo: event)
                return
            } catch {
                sendControlFailure(.invalidRequest, for: outer.requestID, replyTo: event)
                return
            }
            guard control.requestID == outer.requestID else {
                sendControlFailure(.invalidRequest, for: outer.requestID, replyTo: event)
                return
            }
            handle(control: control, outerRequestID: outer.requestID, replyTo: event)
        case .model:
            handleModelFrame(outer, replyTo: event)
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
            xpc_connection_cancel(connection)
            return false
        }
        guard StenoGemmaXPCProcessLifecycle.claimPeer(lifetimeID) else {
            lock.withLock { authenticationState = .terminal }
            xpc_connection_cancel(connection)
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
            xpc_connection_cancel(connection)
        }
    }

    private func finishConnection() -> Bool {
        lock.withLock {
            authenticationTimeout?.cancel()
            authenticationTimeout = nil
            let wasBound = authenticationState == .bound
            authenticationState = .terminal
            return wasBound
        }
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

    private func sendControlFailure(
        _ code: GemmaIPCErrorCode,
        for requestID: UUID,
        replyTo message: xpc_object_t
    ) {
        sendControl(.failure(.init(code: code)), for: requestID, replyTo: message)
    }

    private func sendControl(
        _ body: GemmaXPCControlResponseBody,
        for requestID: UUID,
        replyTo message: xpc_object_t
    ) {
        let response = GemmaXPCControlResponseEnvelope(requestID: requestID, body: body)
        guard let data = try? GemmaXPCControlCodec.encode(response) else { return }
        send(data, requestID: requestID, channel: .control, replyTo: message)
    }

    private func send(
        _ data: Data,
        requestID: UUID,
        channel: GemmaXPCChannel,
        replyTo message: xpc_object_t
    ) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        GemmaXPCOuterFrame.write(
            data,
            requestID: requestID,
            channel: channel,
            to: reply
        )
        xpc_connection_send_message(connection, reply)
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
        return StenoGemmaXPCProcessRuntime.registry.markTerminatingAndReturnWasArmed()
            ? EXIT_SUCCESS
            : EXIT_FAILURE
    }
}

/// The model execution actor is created only after an authenticated peer submits model work.
private enum StenoGemmaXPCProcessRuntime {
    static let registry = GemmaServiceRequestRegistry(
        helperIdentity: GemmaIPCPreparedHelperExit(
            helperInstanceID: UUID(),
            processIdentifier: getpid()
        )
    )
    static let core = GemmaServiceCore(buildInfo: .current)
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

    private static let channelKey = "channel"
    private static let frameKey = "frame"
    private static let requestIDKey = "requestID"

    static func decode(_ message: xpc_object_t) -> GemmaXPCOuterFrame? {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
              hasExactKeys(message),
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
            requestID: UUID(uuid: uuid)
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

    private static func hasExactKeys(_ dictionary: xpc_object_t) -> Bool {
        var keys = Set<String>()
        let accepted = xpc_dictionary_apply(dictionary) { key, _ in
            keys.insert(String(cString: key))
            return true
        }
        return accepted && keys == Set([channelKey, frameKey, requestIDKey])
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
