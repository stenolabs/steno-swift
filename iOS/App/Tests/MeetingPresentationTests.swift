import StenoDomain
import StenoLibrary
import Testing
@testable import Steno

@Suite("Meeting empty presentation")
struct MeetingPresentationTests {
    @Test("detail snapshot reads status before transcript")
    @MainActor
    func diarizationSnapshotCannotPairCompletedWithAnOlderRevision() async {
        actor Probe {
            var statusWasRead = false

            func readStatus() -> MeetingDiarizationJobState {
                statusWasRead = true
                return .completed
            }

            func readRevision() -> String {
                statusWasRead ? "labels" : "old transcript"
            }
        }
        let probe = Probe()

        let snapshot = await MeetingDiarizationSnapshot.load(
            status: { await probe.readStatus() },
            revision: { await probe.readRevision() }
        )

        #expect(snapshot.state == .completed)
        #expect(snapshot.revision == "labels")
    }

    @Test("speaker separation action routes missing models to audio readiness")
    func speakerSeparationNeedsModels() {
        #expect(
            MeetingDiarizationPresentation.make(.modelsRequired)
                == MeetingDiarizationPresentation(
                    title: "Separate speakers",
                    message: "Install the optional speaker separation models under Audio readiness first.",
                    action: .openAudioReadiness
                )
        )
    }

    @Test("speaker separation action starts only when ready")
    func speakerSeparationIsReady() {
        #expect(
            MeetingDiarizationPresentation.make(.ready)
                == MeetingDiarizationPresentation(
                    title: "Separate speakers",
                    message: "Create speaker labels for this transcript. This does not identify people by name.",
                    action: .request
                )
        )
    }

    @Test("active and completed speaker separation are status only")
    func speakerSeparationStatus() {
        #expect(
            MeetingDiarizationPresentation.make(.queued)?.title
                == "Speaker separation queued"
        )
        #expect(
            MeetingDiarizationPresentation.make(.running)?.title
                == "Separating speakers"
        )
        #expect(
            MeetingDiarizationPresentation.make(.completed)?.title
                == "Speaker separation completed"
        )
        #expect(MeetingDiarizationPresentation.make(.completed)?.action == nil)
    }

    @Test("parked speaker labels require explicit adoption")
    func pendingDiarizationResultExplainsTheEditAndOffersAdoption() {
        let presentation = MeetingDiarizationPresentation.make(.resultsPending)

        #expect(presentation?.title == "Speaker labels ready")
        #expect(presentation?.message.contains("edited transcript") == true)
        #expect(presentation?.action == .adoptPending)
        #expect(presentation?.actionTitle == "Use speaker labels")
    }

    @Test("other diarization failures stay visible without an automatic retry")
    func otherSpeakerSeparationFailure() {
        let presentation = MeetingDiarizationPresentation.make(
            .failed("inference failed")
        )

        #expect(presentation?.title == "Speaker separation failed")
        #expect(presentation?.message == "inference failed")
        #expect(presentation?.action == nil)
        #expect(MeetingDiarizationPresentation.make(.unavailable) == nil)
    }

    @Test("notes editing starts after the active recording state")
    func notesEditingStartsAfterRecording() {
        #expect(!MeetingPresentation.canEditNotes(status: nil))
        #expect(!MeetingPresentation.canEditNotes(status: .recording))
        #expect(MeetingPresentation.canEditNotes(status: .interrupted))
        #expect(MeetingPresentation.canEditNotes(status: .processing))
        #expect(MeetingPresentation.canEditNotes(status: .ready))
        #expect(MeetingPresentation.canEditNotes(status: .draft))
    }

    @Test("saved audio is stated and gives the transcription recovery path")
    func savedAudioWithoutTranscript() {
        #expect(
            MeetingPresentation.emptyState(status: .ready, hasAudio: true)
                == MeetingEmptyState(
                    title: "No transcript yet",
                    systemImage: "text.quote",
                    description: "Audio saved. No transcript yet. If the speech model is missing, install it under Audio readiness. Steno retries automatically."
                )
        )
    }

    @Test("a meeting without media does not claim saved audio")
    func noMediaWithoutTranscript() {
        #expect(
            MeetingPresentation.emptyState(status: .ready, hasAudio: false)
                == MeetingEmptyState(
                    title: "No transcript yet",
                    systemImage: "text.quote",
                    description: "This meeting has no saved audio or transcript yet."
                )
        )
    }

    @Test("a draft keeps its existing explanation")
    func draftWithoutRecording() {
        #expect(
            MeetingPresentation.emptyState(status: .draft, hasAudio: false)
                == MeetingEmptyState(
                    title: "Draft",
                    systemImage: "square.and.pencil",
                    description: "This meeting holds a note and no recording yet."
                )
        )
    }
}
