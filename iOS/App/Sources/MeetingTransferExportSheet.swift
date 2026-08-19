import StenoDomain
import StenoPipeline
import SwiftUI

enum MeetingTransferExportPresentation {
    static let initialAudioSelection: Set<MediaAssetID> = []
    static let airDropInstruction = "Choose AirDrop in the share sheet."
    static let shareActionLabel = "Share meeting"

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
        let count = tracks.count
        let noun = count == 1 ? "track" : "tracks"
        let total = tracks.reduce(Int64(0)) { $0 + $1.byteCount }
        return "\(count) \(noun) selected, \(byteSize(total)) total"
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
        let totalBytes = tracks.reduce(Int64(0)) { $0 + $1.byteCount }
        return "Adding \(byteSize(totalBytes)) sends an unencrypted raw recording. "
            + "Microphone tracks may contain other voices in the room. "
            + "The package may remain as a cleartext file on the receiving device."
    }

    static func shareAccessibilityValue(isPreparing: Bool) -> String {
        isPreparing ? "Preparing package" : ""
    }

    static func shareAccessibilityHint(isPreparing: Bool) -> String {
        if isPreparing {
            return "The meeting package is being created."
        }
        return "Creates the package, then opens the share sheet."
    }

    static func canShare(
        preview: MeetingTransferExportPreview,
        selectedAudioAssetIDs: Set<MediaAssetID>
    ) -> Bool {
        if preview.textOnlyIsValid { return true }
        let offered = Set(preview.audioTracks.map(\.assetID))
        return !selectedAudioAssetIDs.intersection(offered).isEmpty
    }

    static func byteSize(_ bytes: Int64) -> String {
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

    private static func selectedAudioTracks(
        for preview: MeetingTransferExportPreview,
        selectedAudioAssetIDs: Set<MediaAssetID>
    ) -> [MeetingTransferExportPreview.AudioTrack] {
        preview.audioTracks.filter { selectedAudioAssetIDs.contains($0.assetID) }
    }
}

struct MeetingTransferExportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let meetingID: MeetingID

    @State private var preview: MeetingTransferExportPreview?
    @State private var selectedAudioAssetIDs =
        MeetingTransferExportPresentation.initialAudioSelection
    @State private var pendingShare: PendingShare?
    @State private var exportTask: Task<Void, Never>?
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let preview {
                    Form {
                        Section("Meeting") {
                            Text(preview.title)
                                .font(.headline)
                            Text(preview.createdAt, format: .dateTime.day().month().year())
                                .foregroundStyle(.secondary)
                        }

                        Section("Text content") {
                            let content = MeetingTransferExportPresentation.textContent(
                                for: preview
                            )
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
                                            get: {
                                                selectedAudioAssetIDs.contains(track.assetID)
                                            },
                                            set: { selected in
                                                if selected {
                                                    selectedAudioAssetIDs.insert(track.assetID)
                                                } else {
                                                    selectedAudioAssetIDs.remove(track.assetID)
                                                }
                                            }
                                        )
                                    )
                                }
                                if let warning = MeetingTransferExportPresentation.audioWarning(
                                    for: preview,
                                    selectedAudioAssetIDs: selectedAudioAssetIDs
                                ) {
                                    Text(warning)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Section {
                            Text(MeetingTransferExportPresentation.airDropInstruction)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button {
                                prepareShare()
                            } label: {
                                if isPreparing {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Label(
                                        MeetingTransferExportPresentation.shareActionLabel,
                                        systemImage: "square.and.arrow.up"
                                    )
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .accessibilityLabel(
                                MeetingTransferExportPresentation.shareActionLabel
                            )
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
                                    || !MeetingTransferExportPresentation.canShare(
                                        preview: preview,
                                        selectedAudioAssetIDs: selectedAudioAssetIDs
                                    )
                            )
                        }
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Meeting cannot be shared",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Preparing preview")
                }
            }
            .navigationTitle("Share meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task(id: meetingID) {
            do {
                preview = try await app.meetingTransferPreview(meetingID)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $pendingShare, onDismiss: finishShare) { item in
            MeetingTransferShareSheet(
                packageURL: item.result.packageURL,
                completion: finishShare
            )
        }
        .alert(
            "Meeting cannot be shared",
            isPresented: Binding(
                get: { errorMessage != nil && preview != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            exportTask?.cancel()
            finishShare()
        }
    }

    private func prepareShare() {
        guard exportTask == nil else { return }
        isPreparing = true
        errorMessage = nil
        exportTask = Task { @MainActor in
            var preparedResult: MeetingTransferExportResult?
            defer {
                isPreparing = false
                exportTask = nil
            }
            do {
                let result = try await app.prepareMeetingTransferExport(
                    meetingID: meetingID,
                    selectedAudioAssetIDs: selectedAudioAssetIDs
                )
                preparedResult = result
                try Task.checkCancellation()
                pendingShare = PendingShare(result: result)
            } catch is CancellationError {
                if let preparedResult {
                    try? app.cleanupMeetingTransferExport(preparedResult)
                }
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishShare() {
        guard let result = pendingShare?.result else { return }
        pendingShare = nil
        do {
            try app.cleanupMeetingTransferExport(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PendingShare: Identifiable {
    let result: MeetingTransferExportResult

    var id: URL { result.packageURL }
}
