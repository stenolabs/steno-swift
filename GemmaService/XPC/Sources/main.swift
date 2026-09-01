import StenoGemmaIPC
import XPC

private nonisolated func acceptPeer(_ peer: xpc_connection_t) {
    guard let service = StenoGemmaXPCService(connection: peer) else {
        xpc_connection_cancel(peer)
        return
    }
    service.activate()
}

xpc_main(acceptPeer)
