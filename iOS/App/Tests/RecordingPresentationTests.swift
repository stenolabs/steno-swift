import Foundation
import Testing
@testable import Steno

@Suite("Recording model presentation")
struct RecordingPresentationTests {
    @Test("an unchanged explicit language remains explicit for recording")
    func exactExplicitLanguageRemainsExplicit() {
        let selection = TranscriptionLanguageSelection(
            selectedIdentifier: "de-DE",
            wasChosenExplicitly: true,
            resolvedFallback: nil
        )

        #expect(selection.locale.identifier == "de-DE")
        #expect(selection.effectiveLocaleWasChosenExplicitly)
    }

    @Test("an equivalent supported identifier keeps the explicit choice")
    func equivalentResolvedLocaleRemainsExplicit() {
        let selection = TranscriptionLanguageSelection(
            selectedIdentifier: "de-DE",
            wasChosenExplicitly: true,
            resolvedFallback: Locale(identifier: "DE_de")
        )

        #expect(selection.locale.identifier == "de_DE")
        #expect(selection.effectiveLocaleWasChosenExplicitly)
    }

    @Test("a different fallback is not explicit after an earlier explicit choice")
    func differentResolvedFallbackIsNotExplicit() {
        let selection = TranscriptionLanguageSelection(
            selectedIdentifier: "de-DE",
            wasChosenExplicitly: true,
            resolvedFallback: Locale(identifier: "de_AT")
        )

        #expect(selection.locale.identifier == "de_AT")
        #expect(!selection.effectiveLocaleWasChosenExplicitly)
    }

    @Test("an inferred language is not explicit")
    func inferredLanguageIsNotExplicit() {
        let selection = TranscriptionLanguageSelection(
            selectedIdentifier: "auto",
            wasChosenExplicitly: false,
            resolvedFallback: Locale(identifier: "de_DE")
        )

        #expect(!selection.effectiveLocaleWasChosenExplicitly)
    }

    @Test("missing model says recording continues without transcription")
    func missingModelMessage() {
        #expect(
            RecordingPresentation.modelMessage(
                isRecording: true,
                transcriptionFailure: nil,
                modelReady: false
            ) == "Recording without transcription. The speech model is not installed."
        )
    }

    @Test("a concrete transcription failure outranks generic model readiness")
    func concreteFailureWins() {
        #expect(
            RecordingPresentation.modelMessage(
                isRecording: true,
                transcriptionFailure: "SpeechAnalyzer failed",
                modelReady: false
            ) == "Recording. No live transcript: SpeechAnalyzer failed"
        )
    }

    @Test("model state is silent before readiness is known")
    func unknownReadinessIsSilent() {
        #expect(
            RecordingPresentation.modelMessage(
                isRecording: false,
                transcriptionFailure: nil,
                modelReady: nil
            ) == nil
        )
    }

    @Test("persisted annotations do not show a loss warning")
    func savedAnnotationsDoNotShowTheLossWarning() {
        #expect(
            RecordingPresentation.annotationMessage(
                hasContent: true,
                isSaving: false,
                failure: nil
            ) == nil
        )
    }

    @Test("an annotation failure is separate from recording failure")
    func annotationFailureIsSeparateFromRecordingFailure() {
        #expect(
            RecordingPresentation.annotationMessage(
                hasContent: true,
                isSaving: false,
                failure: "Disk full"
            ) == "Notes could not be saved: Disk full"
        )
    }

    @Test("an active annotation save is visible")
    func annotationSaveIsVisible() {
        #expect(
            RecordingPresentation.annotationMessage(
                hasContent: true,
                isSaving: true,
                failure: nil
            ) == "Saving notes…"
        )
    }
}
