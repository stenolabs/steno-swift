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

        switch StenoGemmaXPCProcessLifecycle.begin(request.body.operation) {
        case .shuttingDown:
            sendModelFailure(.shuttingDown, for: outer.requestID, replyTo: message)
            return
        case .busy:
            sendModelFailure(.busy, for: outer.requestID, replyTo: message)
            return
        case .admitted:
            break
        }

        guard let reply = xpc_dictionary_create_reply(message) else {
            StenoGemmaXPCProcessLifecycle.finish(request.body.operation)
            return
        }
        let frame = outer.frame
        let requestID = outer.requestID
        let operation = request.body.operation
        let replyHandle = GemmaXPCReplyHandle(
            connection: connection,
            reply: reply,
            channel: .model
        )
        Task { [replyHandle] in
            defer { StenoGemmaXPCProcessLifecycle.finish(operation) }
            let response = await StenoGemmaXPCProcessRuntime.core.handle(
                encodedRequest: frame,
                expectedRequestID: requestID
            )
            replyHandle.send(response, requestID: requestID)
        }
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
        switch control.body {
        case .prepareForExit:
            guard let identity = StenoGemmaXPCProcessLifecycle.prepareForExit() else {
                sendControlFailure(.shuttingDown, for: outerRequestID, replyTo: message)
                return
            }
            sendControl(.prepared(identity), for: outerRequestID, replyTo: message)

        case .armAndExit(let request):
            armAndExit(
                request.preparedHelper,
                requestID: outerRequestID,
                replyTo: message
            )
        }
    }

    private func armAndExit(
        _ identity: GemmaIPCPreparedHelperExit,
        requestID: UUID,
        replyTo message: xpc_object_t
    ) {
        // Allocate the reply before changing process state. A missing reply port must not leave
        // a prepared helper irreversibly armed without being able to authenticate that fact.
        guard let reply = xpc_dictionary_create_reply(message) else {
            return
        }
        guard StenoGemmaXPCProcessLifecycle.armAndExit(identity) else {
            sendControlFailure(.invalidRequest, for: requestID, replyTo: message)
            return
        }
        guard let data = try? GemmaXPCControlCodec.encode(
            GemmaXPCControlResponseEnvelope(requestID: requestID, body: .armed(identity))
        ) else {
            _exit(EXIT_FAILURE)
        }
        GemmaXPCOuterFrame.write(data, requestID: requestID, channel: .control, to: reply)
        xpc_connection_send_message(connection, reply)
        // Do not send or schedule anything else. After authenticating this echo, the client
        // cancels this exact connection. The resulting peer-disconnect event is the exit trigger.
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
    private enum AdmissionState {
        case open
        case prepared
        case armed
        case terminating
    }

    enum ModelAdmission {
        case admitted
        case busy
        case shuttingDown
    }

    private final class Storage: @unchecked Sendable {
        static let maximumModelRequests = 32
        static let maximumLifecycleRequests = 64

        let lock = NSLock()
        let identity = GemmaIPCPreparedHelperExit(
            helperInstanceID: UUID(),
            processIdentifier: getpid()
        )
        var admission: AdmissionState = .open
        var activePeer: UUID?
        var modelRequests = 0
        var lifecycleRequests = 0
    }

    private static let storage = Storage()

    static func claimPeer(_ peer: UUID) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard storage.admission != .terminating,
              storage.activePeer == nil || storage.activePeer == peer
        else { return false }
        storage.activePeer = peer
        return true
    }

    static func boundPeerDisconnected(_ peer: UUID) -> Int32 {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if storage.activePeer == peer {
            let exitCode = storage.admission == .armed ? EXIT_SUCCESS : EXIT_FAILURE
            storage.admission = .terminating
            storage.activePeer = nil
            return exitCode
        }
        return EXIT_FAILURE
    }

    static func begin(_ operation: GemmaIPCOperation) -> ModelAdmission {
        storage.lock.lock()
        defer { storage.lock.unlock() }

        let isLifecycleRequest = operation == .cancel || operation == .shutdown
        guard storage.admission == .open || isLifecycleRequest else {
            return .shuttingDown
        }
        if isLifecycleRequest {
            guard storage.lifecycleRequests < Storage.maximumLifecycleRequests else {
                return .busy
            }
            storage.lifecycleRequests += 1
        } else {
            guard storage.modelRequests < Storage.maximumModelRequests else {
                return .busy
            }
            storage.modelRequests += 1
        }
        return .admitted
    }

    static func finish(_ operation: GemmaIPCOperation) {
        storage.lock.lock()
        if operation == .cancel || operation == .shutdown {
            storage.lifecycleRequests = max(0, storage.lifecycleRequests - 1)
        } else {
            storage.modelRequests = max(0, storage.modelRequests - 1)
        }
        storage.lock.unlock()
    }

    static func prepareForExit() -> GemmaIPCPreparedHelperExit? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard storage.admission == .open else { return nil }
        storage.admission = .prepared
        return storage.identity
    }

    static func armAndExit(_ identity: GemmaIPCPreparedHelperExit) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard storage.admission == .prepared, identity == storage.identity else { return false }
        storage.admission = .armed
        return true
    }

}

/// The model execution actor is created only after an authenticated peer submits model work.
private enum StenoGemmaXPCProcessRuntime {
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
