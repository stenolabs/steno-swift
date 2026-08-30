import Darwin
import Dispatch
import Foundation
import Security
import StenoGemmaIPC
import XPC

public enum GemmaRawXPCTransportError: Error, Equatable, Sendable {
    case invalidConfiguration
    case helperCodeInvalid
    case helperRequirementUnavailable
    case connectionCreationFailed
    case peerRequirementRejected
    case connectionInvalidated
    case duplicateRequestID
    case invalidOuterFrame
    case unauthenticatedPeer
    case unexpectedPeerProcess
    case invalidLifecycle
    case invalidControlResponse
    case remoteFailure(GemmaIPCErrorCode)
    case exitObservationRegistrationFailed
    case exitObservationInvalidated
}

/// Creates one single-use raw XPC connection for an embedded Gemma helper.
public struct GemmaRawXPCTransportFactory: GemmaClientTransportFactory, Sendable {
    private let expectedHelperIdentity: GemmaExpectedHelperIdentity

    /// Validates the embedded helper and derives its Mach service name before this factory is
    /// passed into `GemmaClientController`.
    ///
    /// Keeping code-signature and bundle inspection out of `makeTransport()` ensures the
    /// controller's actor-isolated admission path only reserves and activates one connection.
    public init(helperBundleURL: URL) throws {
        expectedHelperIdentity = try GemmaExpectedHelperIdentity(bundleURL: helperBundleURL)
    }

    public func makeTransport() throws -> any GemmaClientTransport {
        try GemmaRawXPCTransport(expectedHelperIdentity: expectedHelperIdentity)
    }
}

/// A mutually authenticated, no-reconnect raw XPC transport.
///
/// The transport validates the embedded helper before connection activation, installs its exact
/// designated requirement as the peer requirement, and validates the dynamic peer and canonical
/// code path before accepting replies. It never decodes model frames before returning their bytes
/// to `GemmaClientController`.
public final class GemmaRawXPCTransport: GemmaClientTransport, @unchecked Sendable {
    private enum Lifecycle: Equatable {
        case open
        case prepared(GemmaIPCPreparedHelperExit)
        case arming(GemmaIPCPreparedHelperExit)
        case exitSent(GemmaIPCPreparedHelperExit)
        case invalidated
    }

    private let connection: xpc_connection_t
    private let callbackQueue: DispatchQueue
    private let expectedHelperURL: URL
    private let expectedRequirement: SecRequirement
    private let lock = NSLock()

    private var lifecycle: Lifecycle = .open
    private var authenticatedPeerPID: pid_t?
    private var pendingReplies: [UUID: CheckedContinuation<Data, any Error>] = [:]

    fileprivate init(expectedHelperIdentity: GemmaExpectedHelperIdentity) throws {
        expectedHelperURL = expectedHelperIdentity.bundleURL
        expectedRequirement = expectedHelperIdentity.requirement
        callbackQueue = DispatchQueue(
            label: "org.stenolabs.steno.gemma-xpc-client.\(UUID().uuidString)"
        )

        let connection = xpc_connection_create(
            expectedHelperIdentity.serviceName,
            callbackQueue
        )
        self.connection = connection

        guard xpc_connection_set_peer_code_signing_requirement(
            connection,
            expectedHelperIdentity.requirementString
        ) == 0 else {
            xpc_connection_set_event_handler(connection) { _ in }
            xpc_connection_activate(connection)
            xpc_connection_cancel(connection)
            throw GemmaRawXPCTransportError.peerRequirementRejected
        }

        xpc_connection_set_event_handler(connection) { [weak self] event in
            self?.receiveConnectionEvent(event)
        }
        xpc_connection_activate(connection)
    }

    deinit {
        invalidate()
    }

    public func send(_ encodedRequest: Data, requestID: UUID) async throws -> Data {
        guard encodedRequest.count <= GemmaIPCProtocol.maximumEncodedMessageBytes else {
            throw GemmaRawXPCTransportError.invalidOuterFrame
        }
        return try await sendFrame(
            encodedRequest,
            requestID: requestID,
            channel: .model
        )
    }

    public func prepareForExit() async throws -> GemmaPreparedHelperExit {
        guard lock.withLock({ lifecycle == .open }) else {
            throw GemmaRawXPCTransportError.invalidLifecycle
        }

        let response = try await sendControl(.prepareForExit)
        guard case .prepared(let prepared) = response,
              prepared.processIdentifier > 0,
              peerProcessMatches(prepared.processIdentifier)
        else {
            throw GemmaRawXPCTransportError.invalidControlResponse
        }

        let accepted = lock.withLock {
            guard lifecycle == .open else { return false }
            lifecycle = .prepared(prepared)
            return true
        }
        guard accepted else {
            throw GemmaRawXPCTransportError.invalidLifecycle
        }
        return prepared
    }

    public func armAndExit(_ preparedHelper: GemmaPreparedHelperExit) async throws -> GemmaArmedHelperExit {
        let admitted = lock.withLock {
            guard lifecycle == .prepared(preparedHelper),
                  authenticatedPeerPID == preparedHelper.processIdentifier
            else { return false }
            // Close client admission before sending the arm request. The raw connection is named,
            // so no later message may be able to start a replacement helper after its reply.
            lifecycle = .arming(preparedHelper)
            return true
        }
        guard admitted, peerProcessMatches(preparedHelper.processIdentifier) else {
            throw GemmaRawXPCTransportError.invalidLifecycle
        }

        let response: GemmaXPCControlResponseBody
        do {
            response = try await sendControl(
                .armAndExit(GemmaIPCArmAndExitRequest(preparedHelper: preparedHelper))
            )
        } catch {
            invalidate(with: .invalidControlResponse)
            throw error
        }
        guard case .armed(let echoedHelper) = response,
              echoedHelper == preparedHelper
        else {
            throw GemmaRawXPCTransportError.invalidControlResponse
        }

        let accepted = lock.withLock {
            switch lifecycle {
            case .arming(let currentHelper) where currentHelper == preparedHelper:
                lifecycle = .exitSent(preparedHelper)
                return true
            case .invalidated:
                // The authenticated armed reply was already delivered. An immediate connection
                // interruption is the expected consequence of this exact helper self-exiting.
                return true
            case .open, .prepared, .arming, .exitSent:
                return false
            }
        }
        guard accepted else {
            throw GemmaRawXPCTransportError.invalidLifecycle
        }
        // Cancellation is terminal for this named connection and sends no message. The armed
        // helper owns the other endpoint and exits when that exact authenticated peer disconnects.
        xpc_connection_cancel(connection)
        return GemmaArmedHelperExit(preparedHelper: preparedHelper)
    }

    public func invalidate() {
        invalidate(with: .connectionInvalidated)
    }

    private func sendControl(
        _ body: GemmaXPCControlRequestBody
    ) async throws -> GemmaXPCControlResponseBody {
        let request = GemmaXPCControlRequestEnvelope(body: body)
        let encodedRequest = try GemmaXPCControlCodec.encode(request)
        let encodedResponse = try await sendFrame(
            encodedRequest,
            requestID: request.requestID,
            channel: .control
        )
        let response: GemmaXPCControlResponseEnvelope
        do {
            response = try GemmaXPCControlCodec.decodeResponse(
                encodedResponse,
                expectedRequestID: request.requestID,
                expectedOperation: body.operation
            )
        } catch {
            throw GemmaRawXPCTransportError.invalidControlResponse
        }
        if case .failure(let failure) = response.body {
            throw GemmaRawXPCTransportError.remoteFailure(failure.code)
        }
        return response.body
    }

    private func sendFrame(
        _ frame: Data,
        requestID: UUID,
        channel: GemmaXPCChannel
    ) async throws -> Data {
        guard frame.count <= GemmaIPCProtocol.maximumEncodedMessageBytes,
              let message = GemmaRawXPCOuterFrame.make(
                  frame: frame,
                  requestID: requestID,
                  channel: channel
              )
        else {
            throw GemmaRawXPCTransportError.invalidOuterFrame
        }

        return try await withCheckedThrowingContinuation { continuation in
            let registrationError: GemmaRawXPCTransportError? = lock.withLock {
                guard lifecycle != .invalidated else {
                    return .connectionInvalidated
                }
                switch channel {
                case .model:
                    guard lifecycle == .open || isPreparedLifecycle(lifecycle) else {
                        return .invalidLifecycle
                    }
                case .control:
                    break
                }
                guard pendingReplies[requestID] == nil else {
                    return .duplicateRequestID
                }
                pendingReplies[requestID] = continuation
                // Arm admission uses this same lock. Once it returns an armed reply, no model
                // message can still be queued on this named connection to start a replacement.
                xpc_connection_send_message_with_reply(
                    connection,
                    message,
                    callbackQueue
                ) { [self] reply in
                    receiveReply(
                        reply,
                        expectedRequestID: requestID,
                        expectedChannel: channel
                    )
                }
                return nil
            }
            if let registrationError {
                continuation.resume(throwing: registrationError)
            }
        }
    }

    private func isPreparedLifecycle(_ lifecycle: Lifecycle) -> Bool {
        if case .prepared = lifecycle {
            return true
        }
        return false
    }

    private func receiveReply(
        _ reply: xpc_object_t,
        expectedRequestID: UUID,
        expectedChannel: GemmaXPCChannel
    ) {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
            invalidate(with: .connectionInvalidated)
            return
        }
        guard authenticatePeer(message: reply),
              let outer = GemmaRawXPCOuterFrame.decode(reply),
              outer.requestID == expectedRequestID,
              outer.channel == expectedChannel
        else {
            invalidate(with: .unauthenticatedPeer)
            return
        }
        finishPending(expectedRequestID, result: .success(outer.frame))
    }

    private func authenticatePeer(message: xpc_object_t) -> Bool {
        var dynamicCode: SecCode?
        guard SecCodeCreateWithXPCMessage(message, SecCSFlags(), &dynamicCode) == errSecSuccess,
              let dynamicCode,
              SecCodeCheckValidity(
                  dynamicCode,
                  GemmaExpectedHelperIdentity.dynamicValidationFlags,
                  expectedRequirement
              ) == errSecSuccess
        else {
            return false
        }

        var staticCode: SecStaticCode?
        var peerURL: CFURL?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopyPath(staticCode, SecCSFlags(), &peerURL) == errSecSuccess,
              let peerURL,
              GemmaRawXPCSecurityProfile.isSafe(staticCode: staticCode),
              Self.canonical(peerURL as URL) == expectedHelperURL
        else {
            return false
        }

        let peerPID = xpc_connection_get_pid(connection)
        guard peerPID > 0 else { return false }
        return lock.withLock {
            if let authenticatedPeerPID {
                return authenticatedPeerPID == peerPID
            }
            authenticatedPeerPID = peerPID
            return true
        }
    }

    private func peerProcessMatches(_ processIdentifier: Int32) -> Bool {
        let currentPID = xpc_connection_get_pid(connection)
        return lock.withLock {
            processIdentifier > 0
                && authenticatedPeerPID == processIdentifier
                && currentPID == processIdentifier
        }
    }

    private func receiveConnectionEvent(_ event: xpc_object_t) {
        guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
        invalidate(with: .connectionInvalidated)
    }

    private func finishPending(
        _ requestID: UUID,
        result: Result<Data, any Error>
    ) {
        let continuation = lock.withLock {
            pendingReplies.removeValue(forKey: requestID)
        }
        continuation?.resume(with: result)
    }

    private func invalidate(with error: GemmaRawXPCTransportError) {
        let continuations: [CheckedContinuation<Data, any Error>] = lock.withLock {
            guard lifecycle != .invalidated else { return [] }
            lifecycle = .invalidated
            let continuations = Array(pendingReplies.values)
            pendingReplies.removeAll()
            return continuations
        }
        xpc_connection_cancel(connection)
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// Registers a process-exit source before the helper is armed for self-exit.
public struct GemmaDispatchSourceExitProver: GemmaAuthenticatedHelperExitProving, Sendable {
    private let queue: DispatchQueue

    public init() {
        queue = DispatchQueue(label: "org.stenolabs.steno.gemma-exit-observer")
    }

    public func registerExitObservation(
        for preparedHelper: GemmaPreparedHelperExit
    ) async throws -> any GemmaAuthenticatedHelperExitObservation {
        guard preparedHelper.processIdentifier > 0 else {
            throw GemmaRawXPCTransportError.exitObservationRegistrationFailed
        }
        let observation = GemmaDispatchSourceExitObservation(
            preparedHelper: preparedHelper,
            queue: queue
        )
        try await withTaskCancellationHandler {
            try await observation.register()
        } onCancel: {
            observation.invalidate()
        }
        return observation
    }
}

final class GemmaDispatchSourceExitObservation:
    GemmaAuthenticatedHelperExitObservation,
    @unchecked Sendable
{
    let preparedHelper: GemmaPreparedHelperExit

    private let source: any DispatchSourceProcess
    private let registration = GemmaRawOneShot<Void>()
    private let exit = GemmaRawOneShot<GemmaAuthenticatedHelperExitProof>()
    private let lock = NSLock()
    private var invalidated = false

    init(preparedHelper: GemmaPreparedHelperExit, queue: DispatchQueue) {
        self.preparedHelper = preparedHelper
        source = DispatchSource.makeProcessSource(
            identifier: preparedHelper.processIdentifier,
            eventMask: .exit,
            queue: queue
        )
        source.setRegistrationHandler { [registration] in
            registration.resolve(.success(()))
        }
        source.setEventHandler { [exit, preparedHelper] in
            exit.resolve(
                .success(
                    GemmaAuthenticatedHelperExitProof(
                        preparedHelper: preparedHelper,
                        event: .exit
                    )
                )
            )
        }
        source.setCancelHandler { [registration, exit] in
            registration.resolve(.failure(.exitObservationInvalidated))
            exit.resolve(.failure(.exitObservationInvalidated))
        }
        source.activate()
    }

    func register() async throws {
        let canRegister = lock.withLock {
            !invalidated
        }
        guard canRegister else {
            throw GemmaRawXPCTransportError.exitObservationRegistrationFailed
        }
        try await registration.wait().get()
    }

    func waitForExit() async throws -> GemmaAuthenticatedHelperExitProof {
        try await withTaskCancellationHandler {
            try await exit.wait().get()
        } onCancel: {
            invalidate()
        }
    }

    func invalidate() {
        let shouldCancel = lock.withLock {
            guard !invalidated else { return false }
            invalidated = true
            return true
        }
        registration.resolve(.failure(.exitObservationInvalidated))
        exit.resolve(.failure(.exitObservationInvalidated))
        if shouldCancel {
            source.cancel()
        }
    }

    deinit {
        invalidate()
    }
}

private struct GemmaExpectedHelperIdentity: @unchecked Sendable {
    static let staticValidationFlags = SecCSFlags(
        rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
    )
    static let dynamicValidationFlags = SecCSFlags(rawValue: kSecCSStrictValidate)

    let bundleURL: URL
    let serviceName: String
    let requirement: SecRequirement
    let requirementString: String

    init(bundleURL: URL) throws {
        let canonicalURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalURL.pathExtension == "xpc",
              let serviceName = Bundle(url: canonicalURL)?.bundleIdentifier,
              !serviceName.isEmpty
        else {
            throw GemmaRawXPCTransportError.invalidConfiguration
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            canonicalURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode,
        SecStaticCodeCheckValidity(
            staticCode,
            Self.staticValidationFlags,
            nil
        ) == errSecSuccess,
        GemmaRawXPCSecurityProfile.isSafe(staticCode: staticCode)
        else {
            throw GemmaRawXPCTransportError.helperCodeInvalid
        }

        var designatedRequirement: SecRequirement?
        var requirementText: CFString?
        guard SecCodeCopyDesignatedRequirement(
            staticCode,
            SecCSFlags(),
            &designatedRequirement
        ) == errSecSuccess,
        let designatedRequirement,
        SecRequirementCopyString(
            designatedRequirement,
            SecCSFlags(),
            &requirementText
        ) == errSecSuccess,
        let requirementText
        else {
            throw GemmaRawXPCTransportError.helperRequirementUnavailable
        }

        self.bundleURL = canonicalURL
        self.serviceName = serviceName
        requirement = designatedRequirement
        requirementString = requirementText as String
    }
}

enum GemmaRawXPCSecurityProfile {
    static func isSafe(entitlements: [String: Any]?) -> Bool {
        guard let entitlements,
              (entitlements["com.apple.security.app-sandbox"] as? Bool) == true,
              (entitlements["com.apple.security.network.client"] as? Bool) != true,
              (entitlements["com.apple.security.network.server"] as? Bool) != true
        else {
            return false
        }
        return true
    }

    static func isSafe(staticCode: SecStaticCode) -> Bool {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [CFString: Any]
        else {
            return false
        }
        return isSafe(
            entitlements: dictionary[kSecCodeInfoEntitlementsDict] as? [String: Any]
        )
    }
}

private struct GemmaRawXPCOuterFrame {
    let frame: Data
    let requestID: UUID
    let channel: GemmaXPCChannel

    private static let channelKey = "channel"
    private static let frameKey = "frame"
    private static let requestIDKey = "requestID"

    static func make(
        frame: Data,
        requestID: UUID,
        channel: GemmaXPCChannel
    ) -> xpc_object_t? {
        guard frame.count <= GemmaIPCProtocol.maximumEncodedMessageBytes else { return nil }
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(dictionary, channelKey, channel.rawValue)
        var uuid = requestID.uuid
        withUnsafePointer(to: &uuid) { pointer in
            xpc_dictionary_set_uuid(dictionary, requestIDKey, pointer)
        }
        frame.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(
                dictionary,
                frameKey,
                bytes.baseAddress,
                frame.count
            )
        }
        return dictionary
    }

    static func decode(_ dictionary: xpc_object_t) -> GemmaRawXPCOuterFrame? {
        guard xpc_get_type(dictionary) == XPC_TYPE_DICTIONARY,
              hasExactKeys(dictionary),
              let channelBytes = xpc_dictionary_get_string(dictionary, channelKey),
              let channel = GemmaXPCChannel(rawValue: String(cString: channelBytes)),
              let requestIDBytes = xpc_dictionary_get_uuid(dictionary, requestIDKey)
        else {
            return nil
        }
        var length = 0
        guard let frameBytes = xpc_dictionary_get_data(dictionary, frameKey, &length),
              length <= GemmaIPCProtocol.maximumEncodedMessageBytes
        else {
            return nil
        }
        let uuid = UnsafeRawPointer(requestIDBytes)
            .assumingMemoryBound(to: uuid_t.self)
            .pointee
        return GemmaRawXPCOuterFrame(
            frame: Data(bytes: frameBytes, count: length),
            requestID: UUID(uuid: uuid),
            channel: channel
        )
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

private final class GemmaRawOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, GemmaRawXPCTransportError>?
    private var continuations: [
        CheckedContinuation<Result<Value, GemmaRawXPCTransportError>, Never>
    ] = []

    func wait() async -> Result<Value, GemmaRawXPCTransportError> {
        await withCheckedContinuation { continuation in
            let resolved: Result<Value, GemmaRawXPCTransportError>? = lock.withLock {
                if let result {
                    return result
                }
                continuations.append(continuation)
                return nil
            }
            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
    }

    func resolve(_ result: Result<Value, GemmaRawXPCTransportError>) {
        let pending: [
            CheckedContinuation<Result<Value, GemmaRawXPCTransportError>, Never>
        ] = lock.withLock {
            guard self.result == nil else { return [] }
            self.result = result
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume(returning: result)
        }
    }
}
