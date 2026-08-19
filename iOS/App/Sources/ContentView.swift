import StenoDomain
import SwiftUI

/// The app's frame.
///
/// `NavigationSplitView` on purpose, not a stack: in compact width it collapses
/// to a stack by itself, so iPhone and iPad are two states of one hierarchy
/// rather than two view trees to maintain.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var meetingTransferSceneID = MeetingTransferSceneID()
    @State private var sidebarRevealEvents = IOSSidebarRevealEventState()

    /// Starts on the recording screen, and says so in the sidebar.
    ///
    /// A `nil` selection also lands on recording, so leaving it nil showed the
    /// recording screen on iPad while no sidebar row looked selected. The app's
    /// first purpose is to record; the selection just has to agree with that.
    @State private var router = NavigationRouter()

    var body: some View {
        VStack(spacing: 0) {
            // Only when the user is somewhere else. On the recording screen
            // itself the strip would repeat what fills the screen already.
            if model.recording.isActive, router.selection != .recording {
                RecordingStrip { router.selection = .recording }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let warning = model.startupWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            splitView
        }
        .animation(.default, value: model.recording.isActive)
        .onAppear {
            model.registerMeetingTransferScene(meetingTransferSceneID)
        }
        .onDisappear {
            model.unregisterMeetingTransferScene(meetingTransferSceneID)
        }
        .onOpenURL { url in
            guard url.pathExtension.caseInsensitiveCompare("stenomeeting") == .orderedSame else {
                return
            }
            model.previewMeetingPackage(at: url, sceneID: meetingTransferSceneID)
        }
        .onChange(of: model.selectedMeetingID) { _, _ in
            consumeSelectedMeetingIfAvailable()
        }
        .onChange(of: model.meetings.map(\.id)) { _, _ in
            consumeSelectedMeetingIfAvailable()
        }
        .task {
            consumeSelectedMeetingIfAvailable()
        }
        .sheet(
            isPresented: Binding(
                get: { model.isPresentingMeetingTransfer(in: meetingTransferSceneID) },
                set: { if !$0 { model.dismissMeetingTransferSheet(for: meetingTransferSceneID) } }
            )
        ) {
            MeetingTransferImportSheet(sceneID: meetingTransferSceneID)
                .environment(model)
        }
    }

    private func consumeSelectedMeetingIfAvailable() {
        guard let meetingID = model.consumeSelectedMeetingIDIfAvailable(
            for: meetingTransferSceneID
        ) else {
            return
        }
        sidebarRevealEvents.request(meetingID)
    }

    private func completeSidebarReveal(
        _ request: IOSSidebarRevealRequest,
        selection: SidebarItem
    ) {
        guard selection == .meeting(request.meetingID),
              sidebarRevealEvents.consume(request)
        else { return }
        router.selection = sizeClass == .compact
            ? MeetingTransferNavigation.compactSelection(for: request.meetingID)
            : MeetingTransferNavigation.splitSelection(for: request.meetingID)
    }

    private var splitView: some View {
        NavigationSplitView {
            MeetingSidebarView(
                selection: $router.selection,
                revealRequest: sidebarRevealEvents.pending,
                onRevealApplied: completeSidebarReveal
            )
        } detail: {
            switch router.selection {
            case .meeting(let id):
                if model.meetings.contains(where: { $0.id == id }) {
                    MeetingDetailView(
                        meetingID: id,
                        showAudioReadiness: { router.selection = .readiness }
                    )
                } else {
                    ContentUnavailableView(
                        "Meeting not found",
                        systemImage: "questionmark.folder"
                    )
                }
            case .readiness:
                AudioReadinessView(session: model.audioSession)
            case .languageModels:
                TextModelSettingsView()
            case .recording, .none:
                RecordingView(showReadiness: { router.selection = .readiness })
            }
        }
    }
}

/// One selection type for both widths.
///
/// `NavigationSplitView` only pushes in compact width when the sidebar row is
/// an actual selection; a button that quietly swaps the detail view works on
/// iPad and does nothing visible on iPhone. Routing meetings and tools through
/// the same selection keeps both widths on one mechanism.
enum SidebarItem: Hashable {
    case meeting(MeetingID)
    case recording
    case readiness
    case languageModels
}

/// Importe verwenden in beiden Breiten dieselbe vorhandene Navigation statt
/// eine Detail-Sonderroute zu praesentieren.
enum MeetingTransferNavigation {
    static func compactSelection(for meetingID: MeetingID) -> SidebarItem {
        .meeting(meetingID)
    }

    static func splitSelection(for meetingID: MeetingID) -> SidebarItem {
        .meeting(meetingID)
    }
}
