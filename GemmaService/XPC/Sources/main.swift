import Darwin
import StenoGemmaIPC
import XPC

private nonisolated func acceptPeer(_ peer: xpc_connection_t) {
    guard let service = StenoGemmaXPCService(connection: peer) else {
        _exit(EXIT_FAILURE)
    }
    service.activate()
}

xpc_main(acceptPeer)
