import Foundation
import StenoDomain
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Imported speaker display")
struct SpeakerDisplayTests {
    @Test("ambiguous playback never falls back to an arbitrary original track")
    func ambiguousPlaybackFailsClosed() {
        let meetingID = MeetingID()
        let microphone = asset(
            meetingID: meetingID,
            kind: .micTrack,
            fileName: "microphone.caf"
        )
        let system = asset(
            meetingID: meetingID,
            kind: .systemTrack,
            fileName: "system.caf"
        )

        #expect(SpeakerPlaybackAssetSelection.asset(
            from: [microphone, system],
            channel: ""
        ) == nil)
        #expect(SpeakerPlaybackAssetSelection.asset(
            from: [microphone],
            channel: ""
        ) == microphone)
        #expect(SpeakerPlaybackAssetSelection.asset(
            from: [microphone, system],
            channel: MediaAsset.Kind.systemTrack.rawValue
        ) == system)
    }

    @Test("unconfirmed imported text has no source name or person color")
    func unconfirmedImportedTextIsNeutral() {
        let reference = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000040")!,
                text: "Ada",
                wasConfirmedAtSource: false
            )
        )

        let presentation = SpeakerPresentationResolver.presentation(
            for: reference,
            review: nil
        )
        #expect(presentation.label == "Unknown speaker")
        #expect(presentation.marker == nil)
        #expect(presentation.originCue != nil)
    }

    @Test("confirmed imported text has no local person color")
    func confirmedImportedTextHasNoPersonColor() {
        let reference = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000041")!,
                text: "Ada",
                wasConfirmedAtSource: true
            )
        )

        let presentation = SpeakerPresentationResolver.presentation(
            for: reference,
            review: nil
        )
        #expect(presentation.label == "Ada")
        #expect(presentation.marker == nil)
        #expect(
            presentation.originCue
                == "Imported text label - not a locally confirmed identity"
        )
    }

    @Test("local speaker references do not receive an imported-label cue")
    func localReferencesHaveNoImportedOriginCue() {
        #expect(SpeakerPresentationResolver.presentation(
            for: .channel("Ich"),
            review: nil
        ).originCue == nil)
        #expect(SpeakerPresentationResolver.presentation(
            for: .person(PersonID()),
            review: nil
        ).originCue == nil)
        #expect(SpeakerPresentationResolver.presentation(
            for: nil,
            review: nil
        ).originCue == nil)
    }

    private func asset(
        meetingID: MeetingID,
        kind: MediaAsset.Kind,
        fileName: String
    ) -> MediaAsset {
        MediaAsset(
            meetingID: meetingID,
            kind: kind,
            sampleRate: 48_000,
            duration: 10,
            provenanceKey: fileName,
            fileName: fileName
        )
    }
}
