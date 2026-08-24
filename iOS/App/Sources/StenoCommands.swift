import StenoDomain
import SwiftUI

/// Pure gate logic for the window-scoped recording and drafting commands.
///
/// `canStartRecording` deliberately reuses `AppModel.canStartRecording`
/// instead of re-deriving the runtime/transition-barrier gates here: those
/// gates already live in one place, and a second copy would drift the moment
/// either side changed.
struct StenoCommandState {
    let libraryReady: Bool
    let recordingState: RecordingModel.State
    let recordingReadyForNewRecording: Bool
    let canEditAnnotations: Bool
    let hasSelectedMeeting: Bool

    init(
        libraryReady: Bool,
        recordingState: RecordingModel.State,
        recordingReadyForNewRecording: Bool,
        canEditAnnotations: Bool,
        hasSelectedMeeting: Bool
    ) {
        self.libraryReady = libraryReady
        self.recordingState = recordingState
        self.recordingReadyForNewRecording = recordingReadyForNewRecording
        self.canEditAnnotations = canEditAnnotations
        self.hasSelectedMeeting = hasSelectedMeeting
    }

    @MainActor
    init(model: AppModel, router: NavigationRouter?) {
        self.init(
            libraryReady: model.isReady,
            recordingState: model.recording.state,
            recordingReadyForNewRecording: model.canStartRecording,
            canEditAnnotations: model.recording.canEditAnnotations,
            hasSelectedMeeting: router?.selectedMeetingID != nil
        )
    }

    var canStartRecording: Bool {
        libraryReady && recordingReadyForNewRecording
    }

    var canStopRecording: Bool {
        switch recordingState {
        case .preparing, .recording:
            return true
        case .idle, .interrupted, .failed:
            return false
        }
    }

    var canMark: Bool {
        recordingState == .recording && canEditAnnotations
    }

    var canCreateDraft: Bool {
        libraryReady
    }

    var canFindInTranscript: Bool {
        hasSelectedMeeting
    }
}

@MainActor
struct StenoCommandActions {
    private let startAction: () async -> Void
    private let stopAction: () async -> Void
    private let markAction: () async -> Void
    private let createDraftAction: () async -> MeetingID?
    private let reloadMeetingsAction: () async -> Void

    init(
        start: @escaping () async -> Void,
        stop: @escaping () async -> Void,
        mark: @escaping () async -> Void,
        createDraft: @escaping () async -> MeetingID?,
        reloadMeetings: @escaping () async -> Void
    ) {
        startAction = start
        stopAction = stop
        markAction = mark
        createDraftAction = createDraft
        reloadMeetingsAction = reloadMeetings
    }

    init(model: AppModel) {
        self.init(
            start: { await model.startRecording() },
            stop: { await model.stopRecording() },
            mark: { await model.recording.mark() },
            createDraft: { await model.createDraftMeeting() },
            reloadMeetings: { await model.reloadMeetings() }
        )
    }

    /// A new recording creates its meeting immediately; the sidebar needs an
    /// explicit reload to show it, unlike `AppModel.stopRecording()`, which
    /// already reloads on its own.
    func start() async {
        await startAction()
        await reloadMeetingsAction()
    }

    func stop() async {
        await stopAction()
    }

    func mark() async {
        await markAction()
    }

    /// The router comes from `@FocusedValue`, so the request stays inside the
    /// iPad window whose command menu received Cmd-F.
    func focusTranscriptSearch(in router: NavigationRouter?) {
        router?.requestTranscriptSearchFocus()
    }

    /// Captures the focused router before the first suspension point: focus
    /// can move to another window while the draft is being created, and the
    /// meeting must open in the window that asked for it, not whichever
    /// window happens to be focused once creation finishes.
    func createDraft(in router: NavigationRouter?) async {
        guard let router, let meetingID = await createDraftAction() else { return }
        // MeetingDetailView opens a draft's inspector only after its initial
        // load has published. Presenting it during compact-width navigation
        // cancels that load on iPhone and leaves the detail on its spinner.
        router.select(.meeting(meetingID))
    }
}

struct StenoCommands: Commands {
    @FocusedValue(NavigationRouter.self) private var router
    let model: AppModel

    private var state: StenoCommandState {
        StenoCommandState(model: model, router: router)
    }

    private var actions: StenoCommandActions {
        StenoCommandActions(model: model)
    }

    var body: some Commands {
        CommandMenu("Recording") {
            Button("Start Recording") {
                Task { await actions.start() }
            }
            .keyboardShortcut("r")
            .disabled(!state.canStartRecording)

            Button("Stop Recording") {
                Task { await actions.stop() }
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!state.canStopRecording)

            Button("Mark This Moment") {
                Task { await actions.mark() }
            }
            .keyboardShortcut("m")
            .disabled(!state.canMark)
        }

        CommandGroup(after: .newItem) {
            Button("New Meeting Notes") {
                let destinationRouter = router
                Task { await actions.createDraft(in: destinationRouter) }
            }
            .keyboardShortcut("n")
            .disabled(!state.canCreateDraft)
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Transcript") {
                actions.focusTranscriptSearch(in: router)
            }
            // `.searchable` owns the native Cmd-F command on iPadOS. Adding
            // a second SwiftUI shortcut here makes UIKit report duplicate
            // `find:` commands and leaves dispatch undefined.
            .disabled(!state.canFindInTranscript)
        }
    }
}
