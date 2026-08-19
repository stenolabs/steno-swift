import StenoDomain
import Testing
@testable import Steno

@Suite("Audio readiness presentation")
struct AudioReadinessPresentationTests {
    @Test("an inferred language offers confirmation of the visible value")
    func inferredLanguageCanBeConfirmed() {
        #expect(
            AudioReadinessPresentation.confirmationTitle(
                languageName: "German (Germany)",
                wasChosenExplicitly: false,
                canChangeLanguage: true
            ) == "Use German (Germany)"
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
            DiarizationModelPresentation.downloadDisclosure(description)
                == "huggingface.co, 509,902,848 bytes (about 509.9 MB)"
        )
        #expect(
            DiarizationModelPresentation.explanation
                == "Separates voices into speaker labels on this device. It does not recognize people or assign names. Installation runs only while Steno is open."
        )
    }

    @Test("recording lock is specific and does not imply transcription is blocked")
    func diarizationRecordingLockText() {
        #expect(
            DiarizationModelPresentation.installLockMessage(recordingIsActive: true)
                == "Stop the recording before installing speaker separation models. Recording and transcription work without them."
        )
        #expect(
            DiarizationModelPresentation.installLockMessage(recordingIsActive: false) == nil
        )
    }
}
