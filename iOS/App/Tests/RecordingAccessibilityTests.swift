import Foundation
import StenoiOSAudio
import Testing
@testable import Steno

@Suite("Recording accessibility presentation")
struct RecordingAccessibilityTests {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    @Test("durations use complete spoken units")
    func durationsUseCompleteSpokenUnits() {
        #expect(
            RecordingAccessibilityPresentation.durationValue(for: 0, locale: english)
                == "0 seconds"
        )
        #expect(
            RecordingAccessibilityPresentation.durationValue(for: 5, locale: english)
                == "5 seconds"
        )
        #expect(
            RecordingAccessibilityPresentation.durationValue(for: 65, locale: english)
                == "1 minute, 5 seconds"
        )
        #expect(
            RecordingAccessibilityPresentation.durationValue(for: 3_665, locale: english)
                == "1 hour, 1 minute, 5 seconds"
        )
    }

    @Test("durations use the caller's locale through Foundation's formatter")
    func durationsUseCallersLocale() {
        let expected = formattedDuration(3_665, locale: german)
        let actual = RecordingAccessibilityPresentation.durationValue(for: 3_665, locale: german)

        #expect(actual == expected)
        #expect(actual != "1 hour, 1 minute, 5 seconds")
    }

    @Test("microphone levels use stable categories")
    func microphoneLevelsUseStableCategories() {
        #expect(
            localized(RecordingAccessibilityPresentation.microphoneLevelValue(
                for: AudioLevel(peak: -12, average: -18),
                isActive: false
            )) == "idle"
        )
        #expect(
            localized(RecordingAccessibilityPresentation.microphoneLevelValue(
                for: .silence,
                isActive: true
            )) == "silent"
        )
        #expect(
            localized(RecordingAccessibilityPresentation.microphoneLevelValue(
                for: AudioLevel(peak: -50, average: -55),
                isActive: true
            )) == "low"
        )
        #expect(
            localized(RecordingAccessibilityPresentation.microphoneLevelValue(
                for: AudioLevel(peak: -24, average: -30),
                isActive: true
            )) == "normal"
        )
        #expect(
            localized(RecordingAccessibilityPresentation.microphoneLevelValue(
                for: AudioLevel(peak: -6, average: -12),
                isActive: true
            )) == "high"
        )
    }

    @Test("clipping takes priority over its otherwise high category")
    func clippingTakesPriority() {
        #expect(
            localized(RecordingAccessibilityPresentation.microphoneLevelValue(
                for: AudioLevel(peak: 0, average: -8),
                isActive: true
            )) == "clipping"
        )
    }

    @Test("visible microphone captions are localizable")
    func visibleMicrophoneCaptionsAreLocalizable() {
        #expect(
            localized(
                RecordingAccessibilityPresentation.microphoneLevelCaption(
                    for: .silence,
                    isActive: false
                ),
                locale: german
            ) == "inaktiv"
        )
        #expect(
            localized(
                RecordingAccessibilityPresentation.microphoneLevelCaption(
                    for: .silence,
                    isActive: true
                ),
                locale: german
            ) == "Stille"
        )
        #expect(
            localized(
                RecordingAccessibilityPresentation.microphoneLevelCaption(
                    for: AudioLevel(peak: -12, average: -18),
                    isActive: true
                ),
                locale: german
            ) == "-18 dBFS, Spitze -12"
        )
    }

    private func formattedDuration(_ seconds: Int, locale: Locale) -> String {
        Duration.UnitsFormatStyle(
            allowedUnits: [.hours, .minutes, .seconds],
            width: .wide,
            maximumUnitCount: 3,
            zeroValueUnits: .hide
        )
        .locale(locale)
        .format(.seconds(seconds))
    }

    private func localized(
        _ resource: LocalizedStringResource,
        locale: Locale = Locale(identifier: "en")
    ) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }
}
