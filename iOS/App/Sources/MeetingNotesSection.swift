import StenoDomain
import StenoLibrary
import SwiftUI

/// The inspector's editing surface for a meeting's notes.
///
/// It deliberately waits for the app-owned session. That lets the recording
/// screen obtain the same session immediately while preventing an empty
/// editor from appearing before the initial read has completed.
struct MeetingNotesSection: View {
    @Environment(AppModel.self) private var app
    let meetingID: MeetingID

    @State private var sessionPresentation = SessionPresentation()
    @State private var sessionMeetingID: MeetingID?
    @State private var transitions = SessionTransitionCoordinator()

    var body: some View {
        Group {
            if let session = sessionPresentation.state.session {
                VStack(alignment: .leading, spacing: Steno.Space.s) {
                    HStack(spacing: Steno.Space.s) {
                        Label("Notes", systemImage: "note.text")
                            .font(.headline)
                        Spacer()
                        if session.isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Saving notes")
                        }
                    }

                    TextEditor(
                        text: Binding(
                            get: { session.text },
                            set: { session.update($0) }
                        )
                    )
                    .font(Steno.readingBody)
                    .frame(minHeight: 180)
                    .accessibilityLabel("Notes")
                    .disabled(!session.canEdit)

                    if let errorMessage = session.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Steno.Colors.error)
                    }
                }
            } else if sessionPresentation.state.isUnavailable {
                ContentUnavailableView {
                    Label("Notes unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Steno could not open this meeting's notes.")
                } actions: {
                    Button("Try Again") {
                        sessionPresentation.retry()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: Steno.Space.s) {
                    ProgressView()
                    Text("Loading notes…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Steno.Space.l)
        .task(id: sessionPresentation.loadID(for: meetingID)) {
            guard !Task.isCancelled else { return }

            if sessionMeetingID != meetingID {
                if let session = sessionPresentation.state.session,
                   let sessionMeetingID {
                    transitions.leave(session, for: sessionMeetingID)
                }
                sessionPresentation.present(.loading)
                sessionMeetingID = nil
            }
            let loadedState = await SessionLoader {
                await app.notesSession(for: meetingID)
            }.state()
            guard !Task.isCancelled else { return }
            sessionPresentation.present(loadedState)
            sessionMeetingID = loadedState.session == nil ? nil : meetingID
        }
        .onDisappear {
            guard let session = sessionPresentation.state.session,
                  let sessionMeetingID else { return }
            transitions.leave(session, for: sessionMeetingID)
        }
    }

    static func flush(_ session: MeetingNotesEditingSession) async {
        await session.flush()
    }

    /// Isolates the await boundary so the inspector never constructs a second
    /// editing session and the loading contract remains directly testable.
    @MainActor
    struct SessionLoader {
        private let load: @MainActor () async -> MeetingNotesEditingSession?

        init(load: @escaping @MainActor () async -> MeetingNotesEditingSession?) {
            self.load = load
        }

        func session() async -> MeetingNotesEditingSession? {
            await load()
        }

        func state() async -> SessionPresentation.State {
            guard let session = await load() else { return .unavailable }
            return .loaded(session)
        }
    }

    /// Keeps a completed unavailable result separate from an in-flight load.
    /// Retrying changes the task identity but still asks AppModel for its one
    /// canonical session.
    @MainActor
    struct SessionPresentation {
        enum State {
            case loading
            case loaded(MeetingNotesEditingSession)
            case unavailable

            var session: MeetingNotesEditingSession? {
                guard case .loaded(let session) = self else { return nil }
                return session
            }

            var isLoading: Bool {
                if case .loading = self { return true }
                return false
            }

            var isUnavailable: Bool {
                if case .unavailable = self { return true }
                return false
            }
        }

        struct LoadID: Hashable {
            let meetingID: MeetingID
            let retryGeneration: UInt
        }

        private(set) var state: State = .loading
        private var retryGeneration: UInt = 0

        mutating func present(_ state: State) {
            self.state = state
        }

        mutating func retry() {
            state = .loading
            retryGeneration &+= 1
        }

        func loadID(for meetingID: MeetingID) -> LoadID {
            LoadID(meetingID: meetingID, retryGeneration: retryGeneration)
        }
    }

    /// Retains a transition flush without making the incoming inspector wait
    /// for a potentially slow previous write.
    @MainActor
    final class SessionTransitionCoordinator {
        private struct PendingFlush {
            let token: UUID
            let task: Task<Void, Never>
        }

        private var pendingFlushes: [MeetingID: PendingFlush] = [:]

        func leave(_ session: MeetingNotesEditingSession, for meetingID: MeetingID) {
            let token = UUID()
            let task = Task { await MeetingNotesSection.flush(session) }
            pendingFlushes[meetingID] = PendingFlush(token: token, task: task)

            Task { [weak self] in
                await task.value
                guard self?.pendingFlushes[meetingID]?.token == token else { return }
                self?.pendingFlushes.removeValue(forKey: meetingID)
            }
        }

        func hasPendingFlush(for meetingID: MeetingID) -> Bool {
            pendingFlushes[meetingID] != nil
        }

        func waitForPendingFlushes() async {
            let tasks = pendingFlushes.values.map(\.task)
            for task in tasks {
                await task.value
            }
        }
    }
}
