import Foundation
import Testing
@testable import StenoAudioCore

@Suite("SilenceAutoStop")
struct SilenceAutoStopTests {
    private let start = ContinuousClock.Instant.now

    private func loud() -> AudioLevels {
        AudioLevels(peak: 0.5, rms: 0.25)
    }

    private func quiet() -> AudioLevels {
        // 0.001 linear RMS is -60 dBFS, below the default -50 dBFS threshold.
        AudioLevels(peak: 0.002, rms: 0.001)
    }

    private func sample(_ levels: AudioLevels) -> [AudioTrack: AudioLevels] {
        [.microphone: levels]
    }

    @Test("config clamps interval to the ten second minimum")
    func clampsInterval() {
        #expect(
            SilenceAutoStopConfig(interval: 1).interval
                == SilenceAutoStopConfig.minimumInterval
        )
        #expect(SilenceAutoStopConfig(interval: 45).interval == 45)
    }

    @Test("fires exactly once after a full interval of silence")
    func firesOnceAfterInterval() async {
        let fired = InvocationCounter()
        let monitor = SilenceAutoStopMonitor(config: SilenceAutoStopConfig(isEnabled: true)) {
            fired.increment()
        }
        var instant = start
        // Silence for just under the default five minute interval:
        // samples land at t = 0 ..< 300 seconds, so nothing fires yet.
        for _ in 0..<300 {
            await monitor.ingest(sample(quiet()), at: instant)
            instant = instant.advanced(by: .seconds(1))
        }
        #expect(fired.value == 0)

        let didFire = await monitor.ingest(sample(quiet()), at: instant)
        #expect(didFire)
        #expect(fired.value == 1)

        // Continued silence must not fire again within the same episode.
        instant = instant.advanced(by: .seconds(600))
        await monitor.ingest(sample(quiet()), at: instant)
        #expect(fired.value == 1)
    }

    @Test("activity instantly resets the episode")
    func activityResets() async {
        let fired = InvocationCounter()
        let monitor = SilenceAutoStopMonitor(config: SilenceAutoStopConfig(isEnabled: true)) {
            fired.increment()
        }
        var instant = start

        // Nearly the whole interval of silence...
        for _ in 0..<299 {
            await monitor.ingest(sample(quiet()), at: instant)
            instant = instant.advanced(by: .seconds(1))
        }
        // ...then one loud sample wipes the accumulated silence.
        await monitor.ingest(sample(loud()), at: instant)

        // A full fresh interval of silence must elapse again: samples at
        // t = 299 ..< 598 stay below the threshold without firing...
        for _ in 0..<300 {
            await monitor.ingest(sample(quiet()), at: instant)
            instant = instant.advanced(by: .seconds(1))
        }
        #expect(fired.value == 0)

        // ...and the sample completing the fresh 300 second window fires.
        let didFire = await monitor.ingest(sample(quiet()), at: instant)
        #expect(didFire)
        #expect(fired.value == 1)
    }

    @Test("disabled configuration never fires")
    func disabledNeverFires() async {
        let fired = InvocationCounter()
        let config = SilenceAutoStopConfig(isEnabled: false)
        let monitor = SilenceAutoStopMonitor(config: config) { fired.increment() }
        var instant = start

        for _ in 0...600 {
            await monitor.ingest(sample(quiet()), at: instant)
            instant = instant.advanced(by: .seconds(1))
        }

        #expect(fired.value == 0)
    }

    @Test("a level exactly at the threshold counts as silence")
    func boundaryAtThreshold() async {
        let fired = InvocationCounter()
        let monitor = SilenceAutoStopMonitor(config: SilenceAutoStopConfig(isEnabled: true)) {
            fired.increment()
        }
        var instant = start

        // Exactly -50 dBFS linear RMS: 10^(-50/20).
        let atThreshold = Float(pow(10.0, -50.0 / 20.0))
        let levels = AudioLevels(peak: atThreshold * 2, rms: atThreshold)
        #expect(SilenceAutoStopConfig().isSilent(levels))

        for _ in 0...300 {
            await monitor.ingest(sample(levels), at: instant)
            instant = instant.advanced(by: .seconds(1))
        }

        #expect(fired.value == 1)
    }

    @Test("re-arms and fires again after activity ends an episode")
    func reArmsAfterReset() async {
        let fired = InvocationCounter()
        let monitor = SilenceAutoStopMonitor(config: SilenceAutoStopConfig(isEnabled: true)) {
            fired.increment()
        }
        var instant = start

        // First episode fires.
        for _ in 0...300 {
            await monitor.ingest(sample(quiet()), at: instant)
            instant = instant.advanced(by: .seconds(1))
        }
        #expect(fired.value == 1)

        // Activity ends the episode and re-arms.
        await monitor.ingest(sample(loud()), at: instant)
        instant = instant.advanced(by: .seconds(1))

        // Second full silence stretch fires again.
        for _ in 0..<300 {
            await monitor.ingest(sample(quiet()), at: instant)
            instant = instant.advanced(by: .seconds(1))
        }
        #expect(fired.value == 1)
        instant = instant.advanced(by: .seconds(1))
        await monitor.ingest(sample(quiet()), at: instant)
        #expect(fired.value == 2)
    }

    @Test("bilateral silence requires every track below threshold")
    func bilateralSilence() async {
        let fired = InvocationCounter()
        let monitor = SilenceAutoStopMonitor(config: SilenceAutoStopConfig(isEnabled: true)) {
            fired.increment()
        }
        var instant = start

        // Mic silent, system loud: recording stays alive.
        for _ in 0...400 {
            await monitor.ingest(
                [.microphone: quiet(), .system: loud()],
                at: instant
            )
            instant = instant.advanced(by: .seconds(1))
        }
        #expect(fired.value == 0)
    }
}

/// Thread-safe invocation counter for callbacks that arrive from the
/// monitor actor on arbitrary tasks.
private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
