import Foundation
import StenoDomain
import Testing
@testable import steno_macos

/// F11 mid-recording language switch: the final ASR job must pin the LAST
/// language decision of the recording (manual RecordingStrip pick or decisive
/// automatic detection), while still carrying the detection provenance pin.
@Suite("Mid-recording language switch")
struct RecordingLanguageSwitchTests {
    @Test("a manual mid-recording pick outranks the detected estimate")
    @MainActor
    func manualPickOutranksDetection() {
        let meeting = meeting(
            sourceLocaleIdentifier: nil,
            origin: nil,
            planFinalProviderID: .apple
        )
        let pin = TranscriptionLanguageDetectionPin(
            startLocaleIdentifier: "en-US",
            detectedLocaleIdentifier: "de-DE"
        )

        let job = AppModel.finalASRJob(
            for: meeting,
            languageDetection: pin,
            lastSelectedLocaleIdentifier: "fr-FR"
        )

        #expect(job.localeIdentifier == "fr-FR")
        // Provenance survives: the earlier estimate stays documented even
        // though the user overrode it.
        #expect(job.languageDetection == pin)
    }

    @Test("without a manual pick, a decisive detection still pins its locale")
    @MainActor
    func detectionPinAlonePinsDetectedLocale() {
        let meeting = meeting(
            sourceLocaleIdentifier: nil,
            origin: nil,
            planFinalProviderID: .apple
        )
        let pin = TranscriptionLanguageDetectionPin(
            startLocaleIdentifier: "en-US",
            detectedLocaleIdentifier: "de-DE"
        )

        let job = AppModel.finalASRJob(
            for: meeting,
            languageDetection: pin,
            lastSelectedLocaleIdentifier: nil
        )

        #expect(job.localeIdentifier == "de-DE")
        #expect(job.languageDetection == pin)
    }

    @Test("without any mid-recording decision only an explicit source locale pins")
    @MainActor
    func explicitSourceLocaleFallbackUnchanged() {
        let explicit = meeting(
            sourceLocaleIdentifier: "it-IT",
            origin: .explicit,
            planFinalProviderID: nil
        )
        let estimated = meeting(
            sourceLocaleIdentifier: "it-IT",
            origin: .estimated,
            planFinalProviderID: nil
        )
        let absent = meeting(
            sourceLocaleIdentifier: nil,
            origin: nil,
            planFinalProviderID: nil
        )

        for meeting in [explicit, estimated, absent] {
            let job = AppModel.finalASRJob(
                for: meeting,
                languageDetection: nil,
                lastSelectedLocaleIdentifier: nil
            )
            if meeting.sourceLocale?.origin == .explicit {
                #expect(job.localeIdentifier == "it-IT")
            } else {
                #expect(job.localeIdentifier == nil)
            }
            #expect(job.languageDetection == nil)
        }
    }

    private func meeting(
        sourceLocaleIdentifier: String?,
        origin: MeetingTransferLocaleOrigin?,
        planFinalProviderID: TranscriptionProviderID?
    ) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: UUID()),
            title: "Language switch",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .processing,
            sourceLocale: sourceLocaleIdentifier.map {
                try! MeetingSourceLocale(
                    localeIdentifier: $0,
                    origin: origin ?? .explicit
                )
            },
            transcriptionPlan: planFinalProviderID.map {
                TranscriptionPlan(
                    liveProviderID: $0,
                    finalProviderID: $0
                )
            }
        )
    }
}
