import AppKit
import StenoDomain
import StenoPipeline
import SwiftUI

enum MeetingTransferExportPresentation {
    static let initialAudioSelection: Set<MediaAssetID> = []
    static let airDropInstruction = "The system may open AirDrop directly or show the Share menu. If the menu appears, choose AirDrop."
    static let shareActionLabel = "Share meeting"
    static let sharingStatusText =
        "The system sharing interface is open. The temporary package stays available until the system reports that sharing finished or was cancelled."

    static func textContent(for preview: MeetingTransferExportPreview) -> [String] {
        var content: [String] = []
        if preview.includesNotes {
            content.append("Notes, including any time markers")
        }
        if preview.includesTranscript {
            content.append("Transcript")
        }
        if !preview.visibleSpeakerLabels.isEmpty {
            content.append("Speakers: \(preview.visibleSpeakerLabels.joined(separator: ", "))")
        }
        return content
    }

    static func audioRows(for preview: MeetingTransferExportPreview) -> [String] {
        preview.audioTracks.map { "\($0.label) - \(byteSize($0.byteCount))" }
    }

    static func audioSummary(
        for preview: MeetingTransferExportPreview,
        selectedAudioAssetIDs: Set<MediaAssetID>
    ) -> String {
        let tracks = selectedAudioTracks(
            for: preview,
            selectedAudioAssetIDs: selectedAudioAssetIDs
        )
        guard !tracks.isEmpty else {
            return "Audio off - 0 tracks selected"
        }
        let noun = tracks.count == 1 ? "track" : "tracks"
        let total = tracks.reduce(Int64(0)) { $0 + $1.byteCount }
        return "\(tracks.count) \(noun) selected, \(byteSize(total)) total"
    }

    static func audioWarning(
        for preview: MeetingTransferExportPreview,
        selectedAudioAssetIDs: Set<MediaAssetID>
    ) -> String? {
        let tracks = selectedAudioTracks(
            for: preview,
            selectedAudioAssetIDs: selectedAudioAssetIDs
        )
        guard !tracks.isEmpty else { return nil }
        let total = tracks.reduce(Int64(0)) { $0 + $1.byteCount }
        return "Adding \(byteSize(total)) sends an unencrypted raw recording. "
            + "Microphone tracks may contain other voices in the room. "
            + "The package may remain as a cleartext file on the receiving device."
    }

    static func canShare(
        preview: MeetingTransferExportPreview,
        selectedAudioAssetIDs: Set<MediaAssetID>
    ) -> Bool {
        if preview.textOnlyIsValid { return true }
        let offered = Set(preview.audioTracks.map(\.assetID))
        return !selectedAudioAssetIDs.intersection(offered).isEmpty
    }

    static func shareAccessibilityValue(isPreparing: Bool) -> String {
        isPreparing ? "Preparing package" : ""
    }

    static func shareAccessibilityHint(isPreparing: Bool) -> String {
        isPreparing
            ? "The meeting package is being created."
            : "Creates the package, then opens system sharing. If a Share menu appears, choose AirDrop."
    }

    static func cleanupActionLabel(
        for state: MeetingTransferSharingState?
    ) -> String? {
        guard case .cleanupRequired = state else { return nil }
        return "Retry cleanup"
    }

    static func errorMessage(_ error: Error) -> String {
        if let exportError = error as? MeetingTransferExportError {
            switch exportError {
            case .audioNotEligible:
                return "The selected recording is no longer eligible for export. Reload the preview and select it again."
            case .emptyPayload:
                return "This meeting currently has no notes, transcript or selected recording to share."
            case .invalidSourceLocale:
                return "The meeting contains inconsistent source-language information and cannot be shared."
            case .sourceChangedDuringNativeSnapshot:
                return "The meeting changed while Steno prepared it. Try sharing it again."
            }
        }
        return error.localizedDescription
    }

    private static func selectedAudioTracks(
        for preview: MeetingTransferExportPreview,
        selectedAudioAssetIDs: Set<MediaAssetID>
    ) -> [MeetingTransferExportPreview.AudioTrack] {
        preview.audioTracks.filter { selectedAudioAssetIDs.contains($0.assetID) }
    }

    private static func byteSize(_ bytes: Int64) -> String {
        let units: [(size: Double, label: String)] = [
            (1_073_741_824, "GB"),
            (1_048_576, "MB"),
            (1_024, "KB"),
        ]
        let count = max(0, bytes)
        for unit in units where Double(count) >= unit.size {
            let value = Double(count) / unit.size
            if value.rounded() == value {
                return "\(Int(value)) \(unit.label)"
            }
            return String(
                format: "%.1f %@",
                locale: Locale(identifier: "en_US_POSIX"),
                value,
                unit.label
            )
        }
        return "\(count) bytes"
    }
}

enum MeetingPresentation {
    static func canShareMeeting(status: Meeting.Status?) -> Bool {
        guard let status else { return false }
        return status != .recording && status != .interrupted
    }
}

struct MeetingTransferExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let meetingID: MeetingID

    @State private var preview: MeetingTransferExportPreview?
    @State private var selectedAudioAssetIDs =
        MeetingTransferExportPresentation.initialAudioSelection
    @State private var sharingSession: MeetingTransferSharingSession?
    @State private var exportTask: Task<Void, Never>?
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var shareAnchor: NSView?

    var body: some View {
        @Bindable var sharing = model.meetingTransferSharing
        VStack(spacing: 0) {
            HStack {
                Text("Share meeting")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Group {
                if let preview {
                    exportForm(preview)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Meeting cannot be shared",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Preparing preview")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 500, idealHeight: 600)
        .task(id: meetingID) {
            adoptPendingCleanup(sharing.pendingCleanupSession)
            do {
                preview = try await model.meetingTransferPreview(meetingID)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = MeetingTransferExportPresentation.errorMessage(error)
            }
        }
        .onChange(of: sharingSession?.state) { _, newState in
            handleSharingState(newState)
        }
        .onChange(of: sharing.pendingCleanupSession?.id) { _, _ in
            adoptPendingCleanup(sharing.pendingCleanupSession)
        }
        .alert(
            "Meeting cannot be shared",
            isPresented: Binding(
                get: { errorMessage != nil && preview != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            if case .cleanupRequired = sharingSession?.state {
                Button("Retry cleanup") { retryCleanup() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(
            isPreparing || sharingSession?.state.isCleanupRequired == true
        )
        .onDisappear {
            exportTask?.cancel()
            sharingSession?.presentationDidClose()
        }
    }

    private func exportForm(_ preview: MeetingTransferExportPreview) -> some View {
        Form {
            Section("Meeting") {
                Text(preview.title)
                    .font(.headline)
                Text(preview.createdAt, format: .dateTime.day().month().year())
                    .foregroundStyle(.secondary)
            }

            Section("Text content") {
                let content = MeetingTransferExportPresentation.textContent(for: preview)
                if content.isEmpty {
                    Text("No notes or transcript")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(content, id: \.self) { label in
                        Label(label, systemImage: "checkmark.circle")
                    }
                }
            }

            if !preview.audioTracks.isEmpty {
                Section("Audio") {
                    Text(MeetingTransferExportPresentation.audioSummary(
                        for: preview,
                        selectedAudioAssetIDs: selectedAudioAssetIDs
                    ))
                    .font(.subheadline.weight(.semibold))

                    ForEach(
                        Array(zip(
                            preview.audioTracks,
                            MeetingTransferExportPresentation.audioRows(for: preview)
                        )),
                        id: \.0.assetID
                    ) { track, label in
                        Toggle(
                            label,
                            isOn: Binding(
                                get: { selectedAudioAssetIDs.contains(track.assetID) },
                                set: { selected in
                                    if selected {
                                        selectedAudioAssetIDs.insert(track.assetID)
                                    } else {
                                        selectedAudioAssetIDs.remove(track.assetID)
                                    }
                                    selectionDidChange()
                                }
                            )
                        )
                    }

                    if let warning = MeetingTransferExportPresentation.audioWarning(
                        for: preview,
                        selectedAudioAssetIDs: selectedAudioAssetIDs
                    ) {
                        Label(warning, systemImage: "exclamationmark.shield")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Text(MeetingTransferExportPresentation.airDropInstruction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button {
                        prepareShare()
                    } label: {
                        if isPreparing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(
                                MeetingTransferExportPresentation.shareActionLabel,
                                systemImage: "airplayaudio"
                            )
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(MeetingTransferExportPresentation.shareActionLabel)
                    .accessibilityValue(
                        MeetingTransferExportPresentation.shareAccessibilityValue(
                            isPreparing: isPreparing
                        )
                    )
                    .accessibilityHint(
                        MeetingTransferExportPresentation.shareAccessibilityHint(
                            isPreparing: isPreparing
                        )
                    )
                    .disabled(
                        isPreparing
                            || sharingSession?.state == .sharing
                            || sharingSession?.state.isCleanupRequired == true
                            || !MeetingTransferExportPresentation.canShare(
                                preview: preview,
                                selectedAudioAssetIDs: selectedAudioAssetIDs
                            )
                    )
                    .background(
                        MeetingTransferShareAnchor(view: $shareAnchor)
                            .frame(width: 1, height: 1)
                    )
                    Spacer()
                }

                if sharingSession?.state == .sharing {
                    Label(
                        MeetingTransferExportPresentation.sharingStatusText,
                        systemImage: "airplayaudio"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if case .cleanupRequired(let message) = sharingSession?.state,
                   let actionLabel = MeetingTransferExportPresentation.cleanupActionLabel(
                    for: sharingSession?.state
                   ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(actionLabel) { retryCleanup() }
                            .accessibilityHint(
                                "Retries removal of Steno's temporary meeting package."
                            )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func prepareShare() {
        guard exportTask == nil else { return }
        errorMessage = nil

        if let sharingSession, sharingSession.state == .prepared {
            if sharingSession.selection == currentSelection {
                start(sharingSession)
                return
            }
            do {
                try sharingSession.cleanupPrepared()
                self.sharingSession = nil
            } catch {
                errorMessage = MeetingTransferExportPresentation.errorMessage(error)
                return
            }
        }

        isPreparing = true
        exportTask = Task { @MainActor in
            var preparedSession: MeetingTransferSharingSession?
            defer {
                isPreparing = false
                exportTask = nil
            }
            do {
                let session = try await model.prepareMeetingTransferExport(
                    meetingID: meetingID,
                    selectedAudioAssetIDs: selectedAudioAssetIDs
                )
                preparedSession = session
                sharingSession = session
                try Task.checkCancellation()
                try session.start(anchor: shareAnchor, selection: currentSelection)
            } catch is CancellationError {
                if let preparedSession {
                    try? preparedSession.cleanupPrepared()
                }
            } catch {
                errorMessage = MeetingTransferExportPresentation.errorMessage(error)
            }
        }
    }

    private func start(_ session: MeetingTransferSharingSession) {
        do {
            try session.start(anchor: shareAnchor, selection: currentSelection)
        } catch {
            errorMessage = MeetingTransferExportPresentation.errorMessage(error)
        }
    }

    private var currentSelection: MeetingTransferExportSelection {
        MeetingTransferExportSelection(
            meetingID: meetingID,
            selectedAudioAssetIDs: selectedAudioAssetIDs
        )
    }

    private func selectionDidChange() {
        guard let sharingSession,
              sharingSession.state == .prepared,
              sharingSession.selection != currentSelection else { return }
        do {
            try sharingSession.cleanupPrepared()
            self.sharingSession = nil
        } catch {
            errorMessage = MeetingTransferExportPresentation.errorMessage(error)
        }
    }

    private func retryCleanup() {
        do {
            try sharingSession?.retryCleanup()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleSharingState(_ state: MeetingTransferSharingState?) {
        switch state {
        case .completed, .cancelled:
            dismiss()
        case .failed(let message), .cleanupRequired(let message):
            errorMessage = message
        case .prepared, .sharing, nil:
            break
        }
    }

    private func adoptPendingCleanup(_ session: MeetingTransferSharingSession?) {
        guard let session else { return }
        sharingSession = session
        if case .cleanupRequired(let message) = session.state {
            errorMessage = message
        }
    }
}

private extension MeetingTransferSharingState {
    var isCleanupRequired: Bool {
        if case .cleanupRequired = self { return true }
        return false
    }
}

private struct MeetingTransferShareAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if view !== nsView {
            DispatchQueue.main.async { self.view = nsView }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Void) {}
}
