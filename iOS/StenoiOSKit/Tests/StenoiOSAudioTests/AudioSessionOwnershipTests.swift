import Foundation
import Testing
@testable import StenoiOSAudio

@Suite("Audio session ownership")
struct AudioSessionOwnershipTests {
    @Test("recording takes the metering lease and blocks readiness configuration")
    func recordingTakesMeteringLease() {
        var ownership = AudioSessionOwnership()
        let meter = UUID()
        let recording = UUID()

        let beganMetering = ownership.beginMetering(meter)
        let displacedMetering = ownership.beginRecording(recording)

        #expect(beganMetering)
        #expect(displacedMetering == meter)
        #expect(!ownership.allowsReadinessConfiguration)
    }

    @Test("stale metering cleanup cannot deactivate a recording")
    func staleMeteringCleanupPreservesRecording() {
        var ownership = AudioSessionOwnership()
        let meter = UUID()
        let recording = UUID()
        let beganMetering = ownership.beginMetering(meter)
        _ = ownership.beginRecording(recording)
        let mayDeactivate = ownership.endMetering(meter)

        #expect(beganMetering)
        #expect(!mayDeactivate)
        #expect(ownership.isRecording)
    }

    @Test("ordinary metering cleanup may deactivate an otherwise idle session")
    func idleMeteringCleanupMayDeactivate() {
        var ownership = AudioSessionOwnership()
        let meter = UUID()
        let beganMetering = ownership.beginMetering(meter)
        let mayDeactivate = ownership.endMetering(meter)

        #expect(beganMetering)
        #expect(mayDeactivate)
        #expect(ownership.allowsReadinessConfiguration)
    }
}
