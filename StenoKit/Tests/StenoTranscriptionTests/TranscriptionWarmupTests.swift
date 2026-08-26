import Testing
import Foundation
@testable import StenoTranscription
import StenoDomain

@Suite("Transcription warmup")
struct TranscriptionWarmupTests {
    private static let firstID = TranscriptionProviderID(rawValue: "warmup-first")
    private static let secondID = TranscriptionProviderID(rawValue: "warmup-second")

    private enum FakeError: Error { case unimplemented }

    /// Registry factories are synchronous, so this records with a plain
    /// lock instead of actor hops.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var kinds: [MediaAsset.Kind] = []
        private var preWarms = 0

        func recordResolution(_ kind: MediaAsset.Kind) {
            lock.lock()
            defer { lock.unlock() }
            kinds.append(kind)
        }

        func recordPreWarm() {
            lock.lock()
            defer { lock.unlock() }
            preWarms += 1
        }

        var resolvedKinds: [MediaAsset.Kind] {
            lock.lock()
            defer { lock.unlock() }
            return kinds
        }

        var preWarmCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return preWarms
        }
    }

    /// Stands in for a real provider: cheap to construct, records what the
    /// warmup did to it, and never touches models or assets on disk.
    private struct WarmableFake: WarmupParticipatingProvider {
        let recorder: Recorder

        var descriptor: EngineDescriptor {
            EngineDescriptor(name: "warmup fake", version: "0", modelVersion: nil)
        }

        func liveSession(
            format: AudioFormat,
            locale: Locale
        ) async throws -> any LiveTranscriptionSession {
            throw FakeError.unimplemented
        }

        func transcribeFile(
            _ url: URL,
            locale: Locale
        ) async throws -> TranscriptOutput {
            throw FakeError.unimplemented
        }

        func preWarm(locale: Locale) async throws {
            recorder.recordPreWarm()
        }
    }

    private func makeRegistry(
        _ ids: [TranscriptionProviderID],
        recorder: Recorder
    ) -> TranscriptionProviderRegistry {
        TranscriptionProviderRegistry(factories: Dictionary(
            uniqueKeysWithValues: ids.map { id in
                (
                    id,
                    { (kind: MediaAsset.Kind) -> any TranscriptionProvider in
                        recorder.recordResolution(kind)
                        return WarmableFake(recorder: recorder)
                    } as TranscriptionProviderFactory
                )
            }
        ))
    }

    @Test("both planned provider IDs are resolved for the mic track")
    func resolvesBothPlannedIDsForMicTrack() async {
        let recorder = Recorder()
        let registry = makeRegistry([Self.firstID, Self.secondID], recorder: recorder)
        let plan = TranscriptionPlan(
            liveProviderID: Self.firstID,
            finalProviderID: Self.secondID
        )

        await TranscriptionWarmup.preTouch(
            plan: plan,
            registry: registry,
            locale: Locale(identifier: "de-DE")
        )

        #expect(recorder.resolvedKinds == [.micTrack, .micTrack])
        #expect(recorder.preWarmCount == 2)
    }

    @Test("the same provider in both roles is warmed once")
    func duplicateRolesWarmOnce() async {
        let recorder = Recorder()
        let registry = makeRegistry([Self.firstID], recorder: recorder)
        let plan = TranscriptionPlan(
            liveProviderID: Self.firstID,
            finalProviderID: Self.firstID
        )

        await TranscriptionWarmup.preTouch(
            plan: plan,
            registry: registry,
            locale: Locale(identifier: "de-DE")
        )

        #expect(recorder.resolvedKinds == [.micTrack])
        #expect(recorder.preWarmCount == 1)
    }

    @Test("unregistered IDs are a no-op without throwing")
    func unregisteredIDsAreNoOp() async {
        let recorder = Recorder()
        let registry = makeRegistry([Self.firstID], recorder: recorder)
        let unregistered = TranscriptionProviderID(rawValue: "not-in-registry")
        let plan = TranscriptionPlan(
            liveProviderID: unregistered,
            finalProviderID: unregistered
        )

        await TranscriptionWarmup.preTouch(
            plan: plan,
            registry: registry,
            locale: Locale(identifier: "de-DE")
        )

        #expect(recorder.resolvedKinds.isEmpty)
        #expect(recorder.preWarmCount == 0)
    }

    @Test("a second call is safe")
    func doubleCallIsSafe() async {
        let recorder = Recorder()
        let registry = makeRegistry([Self.firstID], recorder: recorder)
        let plan = TranscriptionPlan(
            liveProviderID: Self.firstID,
            finalProviderID: Self.firstID
        )

        await TranscriptionWarmup.preTouch(
            plan: plan,
            registry: registry,
            locale: Locale(identifier: "de-DE")
        )
        await TranscriptionWarmup.preTouch(
            plan: plan,
            registry: registry,
            locale: Locale(identifier: "de-DE")
        )

        #expect(recorder.preWarmCount == 2)
    }
}
