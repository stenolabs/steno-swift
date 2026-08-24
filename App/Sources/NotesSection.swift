import Foundation
import StenoDomain
import StenoLibrary
import SwiftUI

/// Isolates the asynchronous boundary between the view and AppModel's one
/// canonical notes session.
@MainActor
struct MacNotesSessionLoader {
    private let load: @MainActor () async -> MeetingNotesEditingSession?

    init(load: @escaping @MainActor () async -> MeetingNotesEditingSession?) {
        self.load = load
    }

    func session() async -> MeetingNotesEditingSession? {
        await load()
    }

    func state() async -> MacNotesSessionPresentation.State {
        guard let session = await load() else { return .unavailable }
        return .loaded(session)
    }
}

/// Separates a completed unavailable result from an in-flight load. A retry
/// changes SwiftUI's task identity and still asks AppModel for its canonical
/// session instead of constructing a competing editor.
@MainActor
struct MacNotesSessionPresentation {
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

    static let title: LocalizedStringResource = "Notes"
    static let loadingLabel: LocalizedStringResource = "Loading notes…"
    static let unavailableTitle: LocalizedStringResource = "Notes unavailable"
    static let unavailableDescription: LocalizedStringResource =
        "Steno could not open this meeting's notes."
    static let retryLabel: LocalizedStringResource = "Try Again"
    static let savingLabel: LocalizedStringResource = "Saving…"
    static let editorLabel: LocalizedStringResource = "Meeting notes"
    static let placeholder: LocalizedStringResource =
        "Names, companies, agenda - anything that helps you later."

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

    static func errorMessage(
        for session: MeetingNotesEditingSession
    ) -> LocalizedStringResource? {
        guard let error = session.errorMessage else { return nil }
        if session.loadFailed {
            return "Notes could not be opened: \(error)"
        }
        return "Notes could not be saved: \(error)"
    }
}

/// Keeps leaving a meeting responsive while retaining the flush task long
/// enough for the old canonical session to persist its pending edit.
@MainActor
final class MacNotesSessionTransitionCoordinator {
    private struct PendingFlush {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var pendingFlushes: [MeetingID: PendingFlush] = [:]

    func leave(_ session: MeetingNotesEditingSession, for meetingID: MeetingID) {
        let token = UUID()
        let task = Task { await NotesSection.flush(session) }
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

/// Notizen zum Meeting: Kontext vor dem Termin, Mitschrieb waehrend der
/// Aufnahme, Nachtraege danach.
///
/// Editor und Zeitmarken verwenden dieselbe Bearbeitungssitzung. Dadurch kann
/// ein verzoegerter Autosave keinen gerade gesetzten Marker ueberschreiben.
struct NotesSection: View {
    @Environment(AppModel.self) private var model
    let meetingID: MeetingID

    @State private var sessionPresentation = MacNotesSessionPresentation()
    @State private var sessionMeetingID: MeetingID?
    @State private var transitions = MacNotesSessionTransitionCoordinator()

    var body: some View {
        Group {
            if let session = sessionPresentation.state.session {
                editor(for: session)
            } else if sessionPresentation.state.isUnavailable {
                unavailableView
            } else {
                loadingView
            }
        }
        .task(id: sessionPresentation.loadID(for: meetingID)) {
            guard !Task.isCancelled else { return }

            if sessionMeetingID != meetingID {
                if let oldSession = sessionPresentation.state.session,
                   let sessionMeetingID {
                    transitions.leave(oldSession, for: sessionMeetingID)
                }
                sessionPresentation.present(.loading)
                sessionMeetingID = nil
            }

            let loadedState = await MacNotesSessionLoader {
                await model.notesSession(for: meetingID)
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

    @ViewBuilder
    private func editor(for session: MeetingNotesEditingSession) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            HStack {
                Text(MacNotesSessionPresentation.title)
                    .font(.headline)
                Spacer()
                if session.isSaving {
                    HStack(spacing: Steno.Space.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text(MacNotesSessionPresentation.savingLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }

            if let error = MacNotesSessionPresentation.errorMessage(for: session) {
                HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if session.loadFailed {
                        Button {
                            sessionPresentation.retry()
                        } label: {
                            Text(MacNotesSessionPresentation.retryLabel)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            TextEditor(
                text: Binding(
                    get: { session.text },
                    set: { session.update($0) }
                )
            )
            .font(Steno.readingBody)
            .scrollContentBackground(.hidden)
            // macOS zeigt am TextEditor sonst dauerhaft einen Scroller,
            // auch im leeren Feld.
            .scrollIndicators(.never)
            .padding(Steno.Space.s)
            .frame(minHeight: 120)
            .background(
                .background.secondary,
                in: RoundedRectangle(cornerRadius: Steno.cardRadius)
            )
            .overlay(alignment: .topLeading) {
                if session.canEdit, session.text.isEmpty {
                    Text(MacNotesSessionPresentation.placeholder)
                        .font(Steno.readingBody)
                        .foregroundStyle(.tertiary)
                        .padding(Steno.Space.m)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(Text(MacNotesSessionPresentation.editorLabel))
            .disabled(!session.canEdit)
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label {
                Text(MacNotesSessionPresentation.unavailableTitle)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
        } description: {
            Text(MacNotesSessionPresentation.unavailableDescription)
        } actions: {
            Button {
                sessionPresentation.retry()
            } label: {
                Text(MacNotesSessionPresentation.retryLabel)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var loadingView: some View {
        HStack(spacing: Steno.Space.s) {
            ProgressView()
            Text(MacNotesSessionPresentation.loadingLabel)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    static func flush(_ session: MeetingNotesEditingSession) async {
        await session.flush()
    }
}
