struct BoundedAsyncBuffer<Element: Sendable>: Sendable {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init(capacity: Int) {
        precondition(capacity > 0)
        let pair = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: .bufferingOldest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    @discardableResult
    func yield(_ element: sending Element) -> Bool {
        switch continuation.yield(element) {
        case .enqueued:
            true
        case .dropped, .terminated:
            false
        @unknown default:
            false
        }
    }

    func finish() {
        continuation.finish()
    }
}
