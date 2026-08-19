import Testing
@testable import Steno

@Suite("Runtime change serialization")
struct RuntimeChangeSerializerTests {
    @Test("overlapping requests execute one after another")
    @MainActor
    func operationsDoNotOverlap() async {
        let serializer = RuntimeChangeSerializer()
        let probe = ConcurrencyProbe()

        async let first: Void = serializer.run {
            await probe.enter()
            await Task.yield()
            await probe.leave()
        }
        async let second: Void = serializer.run {
            await probe.enter()
            await Task.yield()
            await probe.leave()
        }
        _ = await (first, second)

        #expect(await probe.maximumConcurrent == 1)
        #expect(await probe.completed == 2)
        #expect(!serializer.isRunning)
    }
}

private actor ConcurrencyProbe {
    private var current = 0
    private(set) var maximumConcurrent = 0
    private(set) var completed = 0

    func enter() {
        current += 1
        maximumConcurrent = max(maximumConcurrent, current)
    }

    func leave() {
        current -= 1
        completed += 1
    }
}
