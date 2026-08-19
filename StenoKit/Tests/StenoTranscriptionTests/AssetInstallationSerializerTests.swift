import Testing
import Foundation
@testable import StenoTranscription

@Suite("Asset installation serializer")
struct AssetInstallationSerializerTests {
    @Test("cancelling the caller stops the serialized work, not just the waiting")
    func cancellationReachesTheOperation() async throws {
        let probe = CancellationProbe()
        let caller = Task {
            try await AssetInstallationSerializer.shared.run(key: "test.cancel") {
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await probe.markCancelled()
                    throw error
                }
            }
        }
        // Erst abbrechen, wenn die Arbeit wirklich laeuft: sonst prueft der
        // Test einen Abbruch, der noch gar nichts erreichen konnte. Mit
        // Grenze, damit ein Fehler nicht als haengender Testlauf erscheint.
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while await !(probe.started), ContinuousClock().now < deadline {
            await Task.yield()
        }
        #expect(await probe.started)
        caller.cancel()
        _ = await caller.result
        // Ohne Weitergabe der Abbruchmarkierung liefe der unstrukturierte
        // Task hier 30 Sekunden weiter und niemand haette den Download
        // angehalten.
        #expect(await probe.cancelled)
    }

    @Test("a second caller shares the running installation")
    func secondCallerSharesTheRun() async throws {
        let counter = RunCounter()
        async let first: Void = AssetInstallationSerializer.shared.run(key: "test.share") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
        }
        async let second: Void = AssetInstallationSerializer.shared.run(key: "test.share") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await (first, second)
        #expect(await counter.count == 1)
    }
}

actor CancellationProbe {
    private(set) var started = false
    private(set) var cancelled = false

    func markStarted() { started = true }
    func markCancelled() { cancelled = true }
}

actor RunCounter {
    private(set) var count = 0

    func increment() { count += 1 }
}
