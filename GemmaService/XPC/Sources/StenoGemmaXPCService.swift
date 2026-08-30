import Foundation
import StenoGemmaIPC
import StenoGemmaServiceCore

/// Model-free XPC shell for the native Gemma boundary.
///
/// The service can currently handshake, cancel, and shut down. Token counting and
/// generation stay unavailable until the verified model runtime is connected.
final class StenoGemmaXPCService: NSObject, StenoGemmaXPCProtocol, @unchecked Sendable {
    private let core: GemmaServiceCore

    init(core: GemmaServiceCore = GemmaServiceCore(buildInfo: .current)) {
        self.core = core
    }

    func sendRequest(
        _ requestData: NSData,
        requestID: NSUUID,
        withReply reply: @escaping @Sendable (NSData) -> Void
    ) {
        let encodedRequest = requestData as Data
        let expectedRequestID = requestID as UUID
        Task { [core] in
            let response = await core.handle(
                encodedRequest: encodedRequest,
                expectedRequestID: expectedRequestID
            )
            reply(response as NSData)
        }
    }
}

/// Accepts one client connection at a time.
///
/// This shell carries no meeting text yet and rejects inference. A production
/// connection requirement must be added before enabling the provider in the app.
final class StenoGemmaXPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let service = StenoGemmaXPCService()
    private var acceptedConnection: NSXPCConnection?

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        lock.lock()
        guard acceptedConnection == nil else {
            lock.unlock()
            newConnection.invalidate()
            return false
        }
        acceptedConnection = newConnection
        lock.unlock()

        newConnection.exportedInterface = NSXPCInterface(
            with: (any StenoGemmaXPCProtocol).self
        )
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.clearConnection(newConnection)
        }
        newConnection.resume()
        return true
    }

    private func clearConnection(_ connection: NSXPCConnection) {
        lock.lock()
        if acceptedConnection === connection {
            acceptedConnection = nil
        }
        lock.unlock()
    }
}
