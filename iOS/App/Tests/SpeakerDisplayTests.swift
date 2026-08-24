import Foundation
import StenoDomain
import StenoPipeline
import Testing
@testable import Steno

@Suite("Imported speaker display")
struct SpeakerDisplayTests {
    @Test("unconfirmed imported text has no source name or person color")
    func unconfirmedImportedTextIsNeutral() {
        let reference = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000050")!,
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
    }

    @Test("confirmed imported text has no local person color")
    func confirmedImportedTextHasNoPersonColor() {
        let reference = SpeakerReference.importedTextLabel(
            ImportedSpeakerTextLabel(
                id: UUID(uuidString: "00000000-0000-7000-8000-000000000051")!,
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
    }

    @Test("imported text keeps its origin cue in speaker display details")
    func importedTextKeepsOriginCueInDisplayDetails() {
        let presentation = SpeakerPresentationResolver.presentation(
            for: .importedTextLabel(
                ImportedSpeakerTextLabel(
                    id: UUID(uuidString: "00000000-0000-7000-8000-000000000052")!,
                    text: "Ada",
                    wasConfirmedAtSource: true
                )
            ),
            review: nil
        )

        let details = SpeakerDisplayDetails(
            presentation: presentation,
            locale: Locale(identifier: "en")
        )

        #expect(details.label == "Ada")
        #expect(details.marker == nil)
        #expect(
            details.originCue
                == "Imported text label - not a locally confirmed identity"
        )

        let germanDetails = SpeakerDisplayDetails(
            presentation: SpeakerPresentationResolver.presentation(
                for: .importedTextLabel(
                    ImportedSpeakerTextLabel(
                        id: UUID(),
                        text: "Ada",
                        wasConfirmedAtSource: false
                    )
                ),
                review: nil
            ),
            locale: Locale(identifier: "de")
        )
        #expect(germanDetails.label == "Unbekannter Sprecher")
        #expect(
            germanDetails.originCue
                == "Importierte Textbezeichnung - keine lokal bestätigte Identität"
        )
    }
}
