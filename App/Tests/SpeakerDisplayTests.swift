import Foundation
import StenoDomain
import StenoIdentity
import StenoPipeline
import Testing
@testable import steno_macos

@Suite("Imported speaker display")
struct SpeakerDisplayTests {
    @Test("identity review errors have complete user-facing messages")
    @MainActor
    func identityReviewErrorsHaveCompleteMessages() {
        let personID = PersonID()
        let cases: [(IdentityReviewError, LocalizedStringResource)] = [
            (
                .clusterNotFound(channel: "system", clusterID: "speaker-1"),
                "This speaker belongs to a superseded run. Please reload the view."
            ),
            (
                .ambiguousClusterAlias(channel: "system", clusterID: "speaker-1"),
                "This speaker cannot be changed because its cluster provenance is ambiguous."
            ),
            (.personNotFound(personID), "The selected person no longer exists."),
            (
                .mixedClusterCannotBeNamed,
                "This section is marked as “multiple people” and cannot be assigned to one person."
            ),
            (.selfClusterCannotBeNamed, "Your own microphone track is not named as a person."),
            (
                .noAssignmentToReassign,
                "There is no assignment here that could be changed."
            ),
            (
                .voiceEvidenceForbidden,
                "Demo meetings cannot create or change real voice profiles."
            ),
        ]

        for (error, expectedResource) in cases {
            let expected = String(localized: expectedResource)
            #expect(AppModel.reviewMessage(for: error) == expected)
        }
    }

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

    @Test("ambiguous transcript playback reports through the window notice")
    @MainActor
    func ambiguousPlaybackUsesCentralNotice() {
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
        let model = AppModel()
        model.reviewError = "existing review error"

        let resolved = model.resolvePlaybackAsset(
            from: [microphone, system],
            channel: ""
        )

        #expect(resolved == nil)
        #expect(model.notice?.text == "No original track found for the voice sample.")
        #expect(model.notice?.isError == true)
        #expect(model.reviewError == "existing review error")
    }

    @Test("a failed temporary-file operation removes the sensitive clip")
    func failedTemporaryOperationRemovesClip() throws {
        let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "steno-sample-test-\(UUID().uuidString).caf"
        )
        defer { try? FileManager.default.removeItem(at: clipURL) }

        #expect(throws: SamplePlaybackTestError.self) {
            try TemporaryPlaybackFile.retainingOnSuccess(at: clipURL) {
                try Data("sensitive speech".utf8).write(to: clipURL)
                throw SamplePlaybackTestError.failed
            }
        }

        #expect(!FileManager.default.fileExists(atPath: clipURL.path))
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

    @Test("fixed speaker vocabulary localizes without changing names")
    func fixedSpeakerVocabularyLocalizesWithoutChangingNames() {
        let german = Locale(identifier: "de")
        let unknown = SpeakerPresentationResolver.presentation(
            for: .importedTextLabel(
                ImportedSpeakerTextLabel(
                    id: UUID(),
                    text: "Ada",
                    wasConfirmedAtSource: false
                )
            ),
            review: nil
        )
        let named = SpeakerPresentation(
            label: "Ada",
            marker: nil,
            channel: nil
        )

        #expect(
            SpeakerDisplayLocalization.label(unknown, locale: german)
                == "Unbekannter Sprecher"
        )
        #expect(
            SpeakerDisplayLocalization.originCue(unknown, locale: german)
                == "Importierte Textbezeichnung - keine lokal bestätigte Identität"
        )
        #expect(SpeakerDisplayLocalization.label(named, locale: german) == "Ada")
    }

    @Test("speaker-looking user data stays verbatim and opaque clusters localize only their source")
    func speakerLookingUserDataStaysVerbatim() {
        let german = Locale(identifier: "de")
        let importedName = SpeakerPresentationResolver.presentation(
            for: .importedTextLabel(ImportedSpeakerTextLabel(
                id: UUID(),
                text: "Me",
                wasConfirmedAtSource: true
            )),
            review: nil
        )
        let opaqueCluster = SpeakerPresentation(
            label: "spk_a (microphone)",
            labelKind: .generic(
                number: nil,
                identifier: "spk_a",
                source: .microphone
            ),
            marker: nil,
            channel: MediaAsset.Kind.micTrack.rawValue
        )

        #expect(SpeakerDisplayLocalization.label(importedName, locale: german) == "Me")
        #expect(SpeakerDisplayLocalization.label(opaqueCluster, locale: german) == "spk_a (Mikrofon)")
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

private enum SamplePlaybackTestError: Error {
    case failed
}
