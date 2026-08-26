import StenoDomain
import StenoIntelligence
import SwiftUI

/// "Suggest title" affordance for meetings that still carry their automatic
/// default title once processing has finished.
///
/// One suggestion at a time is generated on demand from the current
/// transcript revision plus participants and user notes. Apple's on-device
/// Foundation Models are the only transport by design: configured external
/// endpoints are never consulted for titles, so a mere rename suggestion can
/// never push meeting content to a remote service.
///
/// Dismissing persists per transcript revision under a steno.* defaults key;
/// the same revision is never offered again, while a later transcription run
/// (new revision) may offer once more.
struct TitleSuggestionSection: View {
    @Environment(AppModel.self) private var model
    let meetingID: MeetingID
    let revision: TranscriptRevision
    let meeting: Meeting?

    private enum Phase: Equatable {
        case hidden
        case idle
        case loading
        case suggested(String)
        /// Fixed, content-free failure wording; transcript or answer text
        /// must never leak into the UI.
        case failed
    }

    @State private var phase: Phase = .hidden
    @State private var dismissals: any TitleDismissalPersisting

    init(meetingID: MeetingID, revision: TranscriptRevision, meeting: Meeting?) {
        self.meetingID = meetingID
        self.revision = revision
        self.meeting = meeting
        _dismissals = State(initialValue: UserDefaultsTitleDismissalStore())
    }

    var body: some View {
        content
            .task(id: revision.id) { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .idle:
            HStack(spacing: Steno.Space.s) {
                Button {
                    suggest()
                } label: {
                    Label("Suggest Title", systemImage: "wand.and.stars")
                }
                Text("This recording still has its automatic title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: Steno.Space.s) {
                ProgressView().controlSize(.small)
                Text("Proposing a title…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .suggested(let title):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Label("Suggested title", systemImage: "wand.and.stars")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: Steno.Space.s) {
                    Text(title)
                        .font(.headline)
                        .textSelection(.enabled)
                    Button("Use It") { apply(title) }
                        .controlSize(.small)
                    Button("Not Now", role: .cancel) { dismiss() }
                        .controlSize(.small)
                }
            }
        case .failed:
            HStack(spacing: Steno.Space.s) {
                Label(
                    "The title suggestion is currently unavailable.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Button("Try Again") { suggest() }
                    .controlSize(.small)
                Button("Not Now", role: .cancel) { dismiss() }
                    .controlSize(.small)
            }
        }
    }

    /// Re-evaluates whenever the meeting or the transcript revision changes:
    /// a new revision clears nothing, but a persisted dismissal for it keeps
    /// the affordance hidden.
    private func refresh() async {
        guard let meeting,
              TitleSuggestionEligibility.isEligible(
                  status: meeting.status,
                  hasActiveJobs: await hasActiveJobs()
              ),
              !meeting.isDemo
        else {
            phase = .hidden
            return
        }
        switch FoundationModelsTitleSuggester().availability {
        case .available:
            break
        case .unavailable:
            phase = .hidden
            return
        }
        let dismissed = (try? dismissals.dismissedRevisionIDs()) ?? []
        guard TitleSuggestionOffering.shouldOffer(
            meetingTitle: meeting.title,
            revisionID: revision.id.description,
            dismissedRevisionIDs: dismissed
        ) else {
            phase = .hidden
            return
        }
        if phase == .hidden || phase == .idle {
            phase = .idle
        }
    }

    private func hasActiveJobs() async -> Bool {
        await model.jobs(for: meetingID).contains {
            $0.status == .queued || $0.status == .running
        }
    }

    private func suggest() {
        guard let meeting else { return }
        phase = .loading
        Task {
            do {
                let persons = await model.allPersons()
                let namesByID = Dictionary(uniqueKeysWithValues: persons.map {
                    ($0.id, $0.displayName)
                })
                let participants = (meeting.participantIDs
                    + meeting.additionalParticipantIDs)
                    .compactMap { namesByID[$0] }
                let notes = await model.notes(for: meetingID)
                let prompt = try TitlePromptAssembler().assemble(
                    currentTitle: meeting.title,
                    participants: participants,
                    notes: notes.isEmpty ? nil : notes,
                    transcriptText: Self.transcriptText(revision)
                )
                let title = try await FoundationModelsTitleSuggester()
                    .suggest(from: prompt)
                phase = .suggested(title)
            } catch is CancellationError {
                // The view went away mid-request; nothing to surface.
            } catch {
                phase = .failed
            }
        }
    }

    private func apply(_ title: String) {
        Task {
            await model.renameMeeting(meetingID, to: title)
            phase = .hidden
        }
    }

    private func dismiss() {
        try? dismissals.dismiss(revisionID: revision.id.description)
        phase = .hidden
    }

    /// Plain text of the current revision, one line per turn. Uses the same
    /// segment joining the transcript rows display, so the model reads what
    /// the user reads.
    static func transcriptText(_ revision: TranscriptRevision) -> String {
        revision.turns
            .map { TranscriptTurnRow.turnText($0) }
            .joined(separator: "\n")
    }
}
