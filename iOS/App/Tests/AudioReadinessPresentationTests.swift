import Foundation
import StenoDomain
import Testing
@testable import Steno

@Suite("Audio readiness presentation")
struct AudioReadinessPresentationTests {
    @Test("opening readiness during a recording does not reconfigure audio")
    func activeRecordingSkipsAudioConfiguration() {
        #expect(
            AudioReadinessLifecycle.startAction(recordingIsActive: true)
                == .observeWithoutConfiguration
        )
        #expect(
            AudioReadinessLifecycle.startAction(recordingIsActive: false)
                == .configureAndObserve
        )
    }

    @Test("an inferred language offers confirmation of the visible value")
    func inferredLanguageCanBeConfirmed() {
        #expect(
            AudioReadinessPresentation.confirmationTitle(
                languageName: "German (Germany)",
                wasChosenExplicitly: false,
                canChangeLanguage: true
            ).map(english) == "Use German (Germany)"
        )
    }

    @Test("an explicitly chosen language offers no confirmation")
    func explicitLanguageNeedsNoConfirmation() {
        #expect(
            AudioReadinessPresentation.confirmationTitle(
                languageName: "German (Germany)",
                wasChosenExplicitly: true,
                canChangeLanguage: true
            ) == nil
        )
    }

    @Test("a locked language offers no second action")
    func lockedLanguageCannotBeConfirmed() {
        #expect(
            AudioReadinessPresentation.confirmationTitle(
                languageName: "German (Germany)",
                wasChosenExplicitly: false,
                canChangeLanguage: false
            ) == nil
        )
    }

    @Test("speaker separation disclosure names source size and product boundary")
    func diarizationDisclosureIsExact() {
        let description = ModelBundleDescription(
            title: "Speaker separation",
            source: .huggingFace,
            approximateBytes: 509_902_848
        )

        #expect(
            english(DiarizationModelPresentation.downloadDisclosure(description))
                == "huggingface.co, 509,902,848 bytes (about 509.9 MB)"
        )
        #expect(
            english(DiarizationModelPresentation.explanation)
                == "Separates voices into speaker labels on this device. It does not recognize people or assign names. Installation runs only while Steno is open."
        )
    }

    @Test("recording lock is specific and does not imply transcription is blocked")
    func diarizationRecordingLockText() {
        #expect(
            DiarizationModelPresentation.installLockMessage(recordingIsActive: true)
                .map(english)
                == "Stop the recording before installing speaker separation models. Recording and transcription work without them."
        )
        #expect(
            DiarizationModelPresentation.installLockMessage(recordingIsActive: false) == nil
        )
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }
}
