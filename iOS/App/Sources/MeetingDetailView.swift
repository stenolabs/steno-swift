import StenoDomain
import StenoLibrary
import StenoPipeline
import SwiftUI

/// A meeting, for reading and continuing its notes after recording.
///
/// Transcript and speaker review remain read-only. Notes use the same shared
/// editing session as the recording surface, so autosave, markers and later
/// edits cannot overwrite one another.
///
/// Follows `steno-macos/App/Sources/MeetingDetailView.swift` in the parts that
/// carry meaning: timestamp left, speaker above the line, colour only ever as
/// a marker beside a name, and a guess visibly marked as a guess.
struct MeetingDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let meetingID: MeetingID
    var showAudioReadiness: () -> Void = {}

    @State private var meeting: Meeting?
    @State private var revision: TranscriptRevision?
    @State private var review: MeetingReviewData?
    @State private var speakerPresentationContext = SpeakerPresentationContext.empty
    @State private var duration: TimeInterval?
    @State private var didLoad = false
    @State private var query = ""
    @State private var isShowingNotes = false
    @State private var isShowingMeetingTransfer = false
    @State private var diarizationState: MeetingDiarizationJobState = .unavailable
    @State private var isRequestingDiarization = false
    @State private var identity = ViewIdentityGeneration<MeetingID>()

    private static let readableWidth: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            if let receipt = currentMeeting?.metadata?.transferReceipt {
                importedMeetingSummary(MeetingTransferDetailPresentation(receipt: receipt))
            }
            if hasCurrentIdentity, let presentation = MeetingDiarizationPresentation.make(
                diarizationState
            ) {
                diarizationStatus(presentation)
            }
            Group {
                if didLoad, hasCurrentIdentity {
                    List {
                        MeetingReportsSection(
                            meetingID: meetingID,
                            review: review,
                            hasTranscript: revision?.turns.isEmpty == false
                        )
                        transcriptSection()
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 0)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(currentMeeting?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if MeetingPresentation.canEditNotes(status: currentMeeting?.status) {
                    Button {
                        isShowingNotes = true
                    } label: {
                        Label("Notes", systemImage: "square.and.pencil")
                    }
                }
                if MeetingPresentation.canShareMeeting(status: currentMeeting?.status) {
                    Button {
                        isShowingMeetingTransfer = true
                    } label: {
                        Label("Share meeting", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Find in transcript"
        )
        .sheet(isPresented: $isShowingNotes) {
            MeetingNotesEditor(
                meetingID: meetingID,
                meetingTitle: currentMeeting?.title ?? "Meeting"
            )
        }
        .sheet(isPresented: $isShowingMeetingTransfer) {
            MeetingTransferExportSheet(meetingID: meetingID)
        }
        .task(id: meetingID) { await observeMeeting() }
    }

    // MARK: - Transcript

    @ViewBuilder
    private func transcriptSection() -> some View {
        Section("Transcript") {
            if let revision, !revision.turns.isEmpty {
                let turns = matching(revision.turns)
                if turns.isEmpty {
                    Text("Nothing in this transcript matches “\(query)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        TranscriptTurnRow(
                            turn: turn,
                            review: review,
                            presentationContext: speakerPresentationContext,
                            query: query
                        )
                        .frame(maxWidth: Self.readableWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                    }
                }
            } else {
                let state = MeetingPresentation.emptyState(
                    status: meeting?.status,
                    hasAudio: duration != nil
                )
                Label {
                    VStack(alignment: .leading, spacing: Steno.Space.xs) {
                        Text(state.title)
                            .font(.headline)
                        Text(state.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: state.systemImage)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Steno.Space.s)
            }
        }
    }

    /// Filters whole turns, not single segments: a hit whose surrounding
    /// sentence is cut away answers nothing.
    private func matching(_ turns: [TranscriptTurn]) -> [TranscriptTurn] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return turns }
        return turns.filter {
            TranscriptTurnRow.text(of: $0).localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: - Header data

    private var hasCurrentIdentity: Bool {
        identity.token(for: meetingID) != nil
    }

    private var currentMeeting: Meeting? {
        hasCurrentIdentity ? meeting : nil
    }

    private var subtitle: String? {
        guard hasCurrentIdentity else { return nil }
        var parts: [String] = []
        if let duration { parts.append(durationText(duration)) }
        if let count = revision?.turns.count, count > 0 {
            parts.append("\(count) turns")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load(
        _ token: ViewIdentityGeneration<MeetingID>.Token
    ) async {
        let loadedMeeting = await app.meeting(token.value)
        let loadedSpeakerContext = await app.speakerPresentationContext(
            for: token.value
        )
        let loadedDiarization = await MeetingDiarizationSnapshot.load(
            status: { await app.meetingDiarizationState(for: token.value) },
            revision: { await app.transcript(for: token.value) }
        )
        let loadedReview = await app.reviewData(for: token.value)
        let loadedDuration = await app.duration(for: token.value)
        guard !Task.isCancelled,
              identity.accepts(token, currentValue: meetingID)
        else { return }
        meeting = loadedMeeting
        speakerPresentationContext = loadedSpeakerContext
        diarizationState = loadedDiarization.state
        revision = loadedDiarization.revision
        review = loadedReview
        duration = loadedDuration
        didLoad = true
    }

    private func observeMeeting() async {
        let token = identity.begin(meetingID)
        resetMeetingState()
        await load(token)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            let updated = await app.meetingDiarizationState(for: token.value)
            guard !Task.isCancelled,
                  identity.accepts(token, currentValue: meetingID)
            else { return }
            guard updated != diarizationState else { continue }
            diarizationState = updated
            if updated == .completed {
                await load(token)
            }
        }
    }

    private func resetMeetingState() {
        meeting = nil
        revision = nil
        review = nil
        speakerPresentationContext = .empty
        duration = nil
        didLoad = false
        query = ""
        isShowingNotes = false
        isShowingMeetingTransfer = false
        diarizationState = .unavailable
        isRequestingDiarization = false
    }

    private func requestDiarization() {
        guard !isRequestingDiarization,
              let token = identity.token(for: meetingID)
        else { return }
        isRequestingDiarization = true
        Task {
            let updated = await app.requestMeetingDiarization(for: token.value)
            guard identity.accepts(token, currentValue: meetingID) else { return }
            diarizationState = updated
            await load(token)
            guard identity.accepts(token, currentValue: meetingID) else { return }
            isRequestingDiarization = false
        }
    }

    private func adoptPendingDiarization() {
        guard !isRequestingDiarization,
              let expectedCurrentRevisionID = revision?.id,
              let token = identity.token(for: meetingID)
        else { return }
        isRequestingDiarization = true
        Task {
            let updated = await app.adoptPendingMeetingDiarization(
                for: token.value,
                expectedCurrentRevisionID: expectedCurrentRevisionID
            )
            guard identity.accepts(token, currentValue: meetingID) else { return }
            diarizationState = updated
            await load(token)
            guard identity.accepts(token, currentValue: meetingID) else { return }
            isRequestingDiarization = false
        }
    }

    private func diarizationStatus(
        _ presentation: MeetingDiarizationPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(presentation.title, systemImage: "person.2.wave.2")
                .font(.subheadline.weight(.semibold))
            Text(presentation.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let action = presentation.action {
                Button(presentation.actionTitle) {
                    switch action {
                    case .openAudioReadiness:
                        showAudioReadiness()
                    case .request:
                        requestDiarization()
                    case .adoptPending:
                        adoptPendingDiarization()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequestingDiarization)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func importedMeetingSummary(
        _ presentation: MeetingTransferDetailPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(presentation.originLabel, systemImage: "airdrop")
                .font(.subheadline.weight(.semibold))
            Text("Contents: \(presentation.contentLabel)")
            Text("Source language: \(presentation.sourceLanguageLabel)")
            Label(presentation.externalFileWarning, systemImage: "folder")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

/// Loads the status before the transcript. Once a job reports completed, its
/// exact revision pointer has therefore already been observed by the shared
/// status boundary and the following transcript read cannot return the older
/// pre-commit revision from the same pipeline transition.
@MainActor
struct MeetingDiarizationSnapshot<Revision> {
    let state: MeetingDiarizationJobState
    let revision: Revision

    static func load(
        status: () async -> MeetingDiarizationJobState,
        revision: () async -> Revision
    ) async -> Self {
        let state = await status()
        let revision = await revision()
        return Self(state: state, revision: revision)
    }
}

struct MeetingEmptyState: Equatable {
    let title: String
    let systemImage: String
    let description: String
}

enum MeetingPresentation {
    static func canEditNotes(status: Meeting.Status?) -> Bool {
        guard let status else { return false }
        return status != .recording
    }

    static func canShareMeeting(status: Meeting.Status?) -> Bool {
        guard let status else { return false }
        return status != .recording && status != .interrupted
    }

    static func emptyState(
        status: Meeting.Status?,
        hasAudio: Bool
    ) -> MeetingEmptyState {
        if status == .draft {
            return MeetingEmptyState(
                title: "Draft",
                systemImage: "square.and.pencil",
                description: "This meeting holds a note and no recording yet."
            )
        }
        if hasAudio {
            return MeetingEmptyState(
                title: "No transcript yet",
                systemImage: "text.quote",
                description: "Audio saved. No transcript yet. "
                    + "If the speech model is missing, install it under Audio readiness. "
                    + "Steno retries automatically."
            )
        }
        return MeetingEmptyState(
            title: "No transcript yet",
            systemImage: "text.quote",
            description: "This meeting has no saved audio or transcript yet."
        )
    }
}

struct MeetingDiarizationPresentation: Equatable {
    enum Action: Equatable {
        case openAudioReadiness
        case request
        case adoptPending
    }

    let title: String
    let message: String
    let action: Action?

    var actionTitle: String {
        switch action {
        case .adoptPending:
            "Use speaker labels"
        case .openAudioReadiness, .request, nil:
            "Separate speakers"
        }
    }

    static func make(
        _ state: MeetingDiarizationJobState
    ) -> MeetingDiarizationPresentation? {
        switch state {
        case .unavailable:
            nil
        case .modelsRequired:
            MeetingDiarizationPresentation(
                title: "Separate speakers",
                message: "Install the optional speaker separation models under Audio readiness first.",
                action: .openAudioReadiness
            )
        case .ready:
            MeetingDiarizationPresentation(
                title: "Separate speakers",
                message: "Create speaker labels for this transcript. This does not identify people by name.",
                action: .request
            )
        case .queued:
            MeetingDiarizationPresentation(
                title: "Speaker separation queued",
                message: "Steno will create speaker labels for this transcript.",
                action: nil
            )
        case .running:
            MeetingDiarizationPresentation(
                title: "Separating speakers",
                message: "Steno is creating speaker labels on this device.",
                action: nil
            )
        case .resultsPending:
            MeetingDiarizationPresentation(
                title: "Speaker labels ready",
                message: "Your edited transcript is still shown. Use the speaker labels to switch to the separated version; your edit remains saved as an earlier revision.",
                action: .adoptPending
            )
        case .completed:
            MeetingDiarizationPresentation(
                title: "Speaker separation completed",
                message: "Speaker labels are available in the transcript.",
                action: nil
            )
        case .failed(let message):
            MeetingDiarizationPresentation(
                title: "Speaker separation failed",
                message: message ?? "The speaker labels could not be created.",
                action: nil
            )
        }
    }
}

struct SpeakerDisplayDetails: Equatable {
    let label: String?
    let marker: SpeakerMarker?
    let originCue: String?

    init(presentation: SpeakerPresentation) {
        label = presentation.label
        marker = presentation.marker
        originCue = presentation.originCue
    }
}

/// One turn: timestamp, speaker, text.
struct TranscriptTurnRow: View {
    let turn: TranscriptTurn
    let review: MeetingReviewData?
    var presentationContext: SpeakerPresentationContext = .empty
    var query: String = ""

    var body: some View {
        let presentation = SpeakerPresentationResolver.presentation(
            for: turn.speaker,
            review: review,
            context: presentationContext
        )
        let speaker = SpeakerDisplayDetails(presentation: presentation)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timestamp(turn.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                if let label = speaker.label {
                    HStack(spacing: 5) {
                        // The marker is an addition to the name, never its
                        // replacement: colour carries no information alone.
                        if let color = Steno.Colors.speaker(speaker.marker) {
                            Circle()
                                .fill(color)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let originCue = speaker.originCue {
                    Text(originCue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(highlighted)
                    .font(Steno.readingBody)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }

    /// Marks the search term inside the line instead of only filtering to it,
    /// so a hit is findable in a long turn.
    private var highlighted: AttributedString {
        var text = AttributedString(Self.text(of: turn))
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        var search = text.startIndex..<text.endIndex
        while let found = text[search].range(
            of: needle,
            options: .caseInsensitive
        ) {
            text[found].backgroundColor = .yellow.opacity(0.35)
            guard found.upperBound < text.endIndex else { break }
            search = found.upperBound..<text.endIndex
        }
        return text
    }

    static func text(of turn: TranscriptTurn) -> String {
        turn.segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        // Past an hour "1:12:45" is readable, "72:45" is not.
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
