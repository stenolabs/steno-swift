import Foundation
import Testing
@testable import StenoiOSAudio

@Suite("Silence monitor")
struct SilenceMonitorTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func loud() -> AudioLevel {
        AudioLevel(peak: -6, average: -12)
    }

    private func quiet() -> AudioLevel {
        AudioLevel(peak: -75, average: -78)
    }

    @Test("Before it starts, nothing is reported")
    func notRunning() {
        let monitor = SilenceMonitor()

        #expect(monitor.silentSeconds(at: start) == nil)
        #expect(!monitor.isAlarming(at: start))
    }

    @Test("Silence shorter than the grace period stays quiet")
    func withinGrace() {
        var monitor = SilenceMonitor(grace: 20)
        monitor.begin(at: start)

        monitor.update(quiet(), at: start.addingTimeInterval(10))

        #expect(!monitor.isAlarming(at: start.addingTimeInterval(19)))
    }

    @Test("Silence past the grace period raises the alarm")
    func pastGrace() {
        var monitor = SilenceMonitor(grace: 20)
        monitor.begin(at: start)

        monitor.update(quiet(), at: start.addingTimeInterval(10))

        #expect(monitor.isAlarming(at: start.addingTimeInterval(20)))
        #expect(monitor.silentSeconds(at: start.addingTimeInterval(25)) == 25)
    }

    @Test("Any audible sample resets the clock")
    func signalResets() {
        var monitor = SilenceMonitor(grace: 20)
        monitor.begin(at: start)

        monitor.update(quiet(), at: start.addingTimeInterval(15))
        monitor.update(loud(), at: start.addingTimeInterval(18))

        #expect(!monitor.isAlarming(at: start.addingTimeInterval(30)))
        #expect(monitor.silentSeconds(at: start.addingTimeInterval(20)) == 2)
    }

    @Test("A level exactly at the threshold still counts as silence")
    func thresholdIsExclusive() {
        var monitor = SilenceMonitor(threshold: -60, grace: 10)
        monitor.begin(at: start)

        monitor.update(
            AudioLevel(peak: -60, average: -70),
            at: start.addingTimeInterval(5)
        )

        #expect(monitor.isAlarming(at: start.addingTimeInterval(10)))
    }

    @Test("A level just above the threshold counts as signal")
    func justAboveThreshold() {
        var monitor = SilenceMonitor(threshold: -60, grace: 10)
        monitor.begin(at: start)

        monitor.update(
            AudioLevel(peak: -59, average: -70),
            at: start.addingTimeInterval(5)
        )

        #expect(!monitor.isAlarming(at: start.addingTimeInterval(14)))
    }

    @Test("Updates before begin are ignored rather than starting the clock")
    func updateBeforeBegin() {
        var monitor = SilenceMonitor()

        monitor.update(loud(), at: start)

        #expect(monitor.silentSeconds(at: start) == nil)
    }

    @Test("Stopping ends the reporting")
    func stopping() {
        var monitor = SilenceMonitor()
        monitor.begin(at: start)
        monitor.stop()

        #expect(monitor.silentSeconds(at: start.addingTimeInterval(60)) == nil)
        #expect(!monitor.isAlarming(at: start.addingTimeInterval(60)))
    }
}
