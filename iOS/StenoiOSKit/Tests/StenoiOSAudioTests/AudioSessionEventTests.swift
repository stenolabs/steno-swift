@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import StenoiOSAudio

@Suite("Audio session events")
struct AudioSessionEventTests {

    // MARK: - Interruption decoding

    @Test("A begun interruption without a reason still decodes")
    func interruptionBeganWithoutReason() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        #expect(
            AudioSessionController.interruptionEvent(from: notification)
                == .interruptionBegan(.other)
        )
    }

    @Test("A muted built-in microphone is reported as its own reason")
    func interruptionBeganMutedMic() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionReasonKey:
                    AVAudioSession.InterruptionReason.builtInMicMuted.rawValue,
            ]
        )

        #expect(
            AudioSessionController.interruptionEvent(from: notification)
                == .interruptionBegan(.builtInMicMuted)
        )
    }

    @Test("An ended interruption carries the resume hint")
    func interruptionEndedWithResume() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )

        #expect(
            AudioSessionController.interruptionEvent(from: notification)
                == .interruptionEnded(shouldResume: true)
        )
    }

    @Test("An ended interruption without options must not claim resumability")
    func interruptionEndedWithoutOptions() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue
            ]
        )

        #expect(
            AudioSessionController.interruptionEvent(from: notification)
                == .interruptionEnded(shouldResume: false)
        )
    }

    @Test("A notification without a type is ignored rather than guessed")
    func interruptionWithoutTypeIsIgnored() {
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [:]
        )

        #expect(AudioSessionController.interruptionEvent(from: notification) == nil)
    }

    // MARK: - Route change decoding

    @Test("A route change reports the system reason")
    func routeChangeReason() {
        let notification = Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )

        #expect(
            AudioSessionController.routeChangeReason(from: notification)
                == .oldDeviceUnavailable
        )
    }

    @Test("A route change without a reason falls back to unknown")
    func routeChangeWithoutReason() {
        let notification = Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [:]
        )

        #expect(
            AudioSessionController.routeChangeReason(from: notification) == .unknown
        )
    }

    // MARK: - Capture consequences

    @Test(
        "Losing the input device ends the capture",
        arguments: [
            AudioRouteChangeReason.oldDeviceUnavailable,
            .noSuitableRouteForCategory,
            .categoryChange,
        ]
    )
    func reasonsThatEndCapture(reason: AudioRouteChangeReason) {
        #expect(reason.endsCurrentCapture)
    }

    @Test(
        "Additive or cosmetic route changes let the capture continue",
        arguments: [
            AudioRouteChangeReason.newDeviceAvailable,
            .override,
            .wakeFromSleep,
            .routeConfigurationChange,
            .unknown,
        ]
    )
    func reasonsThatContinueCapture(reason: AudioRouteChangeReason) {
        #expect(!reason.endsCurrentCapture)
    }

    // MARK: - Permission mapping

    @Test("Permission states map one to one")
    func permissionMapping() {
        #expect(RecordPermission.status(from: .undetermined) == .notDetermined)
        #expect(RecordPermission.status(from: .denied) == .denied)
        #expect(RecordPermission.status(from: .granted) == .authorized)
    }
}
