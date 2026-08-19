import StenoMacAudio
import Testing
@testable import steno_macos

@Suite("Onboarding permission presentation")
struct OnboardingPermissionPresentationTests {
    @Test("authorized access is the only positive permission state")
    func highlightsOnlyAuthorizedAccessAsSuccessful() {
        let authorized = RecordingPermissionPresentation(
            status: .authorized
        )

        #expect(authorized.tone == .success)
        #expect(authorized.symbolName == "checkmark.circle.fill")
        #expect(authorized.text == "Allowed")

        for status in [
            AudioPermissionStatus.notDetermined,
            .restricted,
            .denied,
        ] {
            #expect(
                RecordingPermissionPresentation(status: status).tone
                    != .success
            )
        }
    }
}
