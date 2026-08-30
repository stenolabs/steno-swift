import Foundation

let delegate = StenoGemmaXPCListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
