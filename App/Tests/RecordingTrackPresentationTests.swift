import StenoAudioCore
import Testing
@testable import steno_macos

@Suite("Recording microphone presentation")
struct RecordingTrackPresentationTests {
    @Test("healthy microphone offers pause without a warning")
    func healthy() {
        let presentation = RecordingTrackPresentation(
            status: RecordingTrackStatus(deviceName: "AirPods")
        )

        #expect(presentation.actionTitle == "Pause microphone")
        #expect(presentation.warning == nil)
    }

    @Test("manual pause offers an explicit resume")
    func manuallyPaused() {
        let presentation = RecordingTrackPresentation(
            status: RecordingTrackStatus(
                userPaused: true,
                deviceName: "AirPods"
            )
        )

        #expect(presentation.actionTitle == "Resume microphone")
        #expect(
            presentation.warning
                == "Microphone paused. System audio continues."
        )
    }

    @Test("a missing device cannot be resumed manually")
    func missingDevice() {
        let presentation = RecordingTrackPresentation(
            status: RecordingTrackStatus(
                deviceAvailable: false,
                deviceName: "AirPods"
            )
        )

        #expect(presentation.actionTitle == nil)
        #expect(
            presentation.warning
                == "AirPods disconnected. The microphone track is paused; system audio continues."
        )
    }

    @Test("a returned device remains paused when the user paused it")
    func returnedWhilePaused() {
        let presentation = RecordingTrackPresentation(
            status: RecordingTrackStatus(
                deviceAvailable: true,
                userPaused: true,
                deviceName: "AirPods"
            )
        )

        #expect(presentation.actionTitle == "Resume microphone")
        #expect(presentation.isPaused)
    }
}
