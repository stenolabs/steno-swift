import Foundation
import StenoDomain
import StenoExchange
import StenoPipeline
import SwiftUI

struct MeetingTransferSceneID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct MeetingTransferSecurityScopedResource: Sendable {
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void

    static let live = Self(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

struct MeetingTransferOwnedSession: Sendable {
    let sessionID: UUID
    let client: MeetingTransferImportClient
}

struct MeetingTransferImportClient: Sendable {
    typealias Progress = @Sendable (MeetingTransferProgress) -> Void
    let prepareImport: @Sendable (URL, @escaping Progress) async throws
        -> MeetingTransferImportPresentation
    let importPrepared: @Sendable (
        UUID,
        MeetingTransferProcessingChoice,
        @escaping Progress
    ) async throws -> MeetingTransferImportResult
    let discardPrepared: @Sendable (UUID) async throws -> Void

    init(
        prepareImport: @escaping @Sendable (URL, @escaping Progress) async throws
            -> MeetingTransferImportPresentation,
        importPrepared: @escaping @Sendable (
            UUID,
            MeetingTransferProcessingChoice,
            @escaping Progress
        ) async throws -> MeetingTransferImportResult,
        discardPrepared: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.prepareImport = prepareImport
        self.importPrepared = importPrepared
        self.discardPrepared = discardPrepared
    }

    init(service: MeetingTransferImportService) {
        prepareImport = { url, progress in
            MeetingTransferImportPresentation(
                try await service.prepareImport(at: url, progress: progress)
            )
        }
        importPrepared = { sessionID, choice, progress in
            try await service.importPrepared(
                sessionID: sessionID,
                choice: choice,
                progress: progress
            )
        }
        discardPrepared = { sessionID in
            try await service.discardPrepared(sessionID: sessionID)
        }
    }
}

enum MeetingTransferImportFlowState: Equatable, Sendable {
    case preparing(MeetingTransferProgress?)
    case preview(MeetingTransferImportPresentation)
    case importing(MeetingTransferImportPresentation, MeetingTransferProgress?)
    case cleanupRequired(
        sessionID: UUID,
        committedResult: MeetingTransferImportResult?,
        message: String
    )
    case completed(MeetingTransferImportResult)
    case recoveryRequired(MeetingID)
    case failed(String)

    var preview: MeetingTransferImportPresentation? {
        switch self {
        case .preview(let presentation), .importing(let presentation, _): presentation
        case .preparing, .cleanupRequired, .completed, .recoveryRequired, .failed: nil
        }
    }

    var cleanupSessionID: UUID? {
        guard case .cleanupRequired(let sessionID, _, _) = self else { return nil }
        return sessionID
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .importing: true
        case .preview, .cleanupRequired, .completed, .recoveryRequired, .failed: false
        }
    }
}

struct MeetingTransferImportPresentation: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable { case importOnly, openExisting, close }

    struct AudioTrack: Equatable, Sendable {
        let label: String
        let byteCount: Int64
    }

    struct SpeakerLabelRow: Identifiable, Equatable, Sendable {
        let id: Int
        let label: String
    }

    let sessionID: UUID
    let sourceMeetingID: MeetingID
    let title: String
    let createdAt: Date
    let capabilities: Set<MeetingTransferCapability>
    let visibleSpeakerLabels: [String]
    let audioTracks: [AudioTrack]
    let localeIdentifier: String?
    let localeOrigin: MeetingTransferLocaleOrigin
    let disposition: MeetingTransferImportDisposition

    var id: UUID { sessionID }
    var technicalOriginID: String { String(sourceMeetingID.description.prefix(8)) }
    var capabilityLabels: [LocalizedStringResource] {
        MeetingTransferCapability.allCases.compactMap { capability in
            guard capabilities.contains(capability) else { return nil }
            return switch capability {
            case .notes: "Notes"
            case .transcript: "Transcript"
            case .audio: "Audio"
            }
        }
    }
    var audioTrackCount: Int { audioTracks.count }
    var totalAudioBytes: Int64 { audioTracks.reduce(0) { $0 + $1.byteCount } }
    var containsRawRecording: Bool { !audioTracks.isEmpty }
    var speakerLabelRows: [SpeakerLabelRow] {
        visibleSpeakerLabels.enumerated().map { index, label in
            SpeakerLabelRow(id: index, label: label)
        }
    }
    var speakerLabelPrivacyHint: LocalizedStringResource {
        "Only visible speaker labels are included. Identity and review data are not transferred."
    }
    var cleartextWarning: LocalizedStringResource {
        containsRawRecording
            ? "This transfer contains an unencrypted raw recording and may include voices of other people."
            : "This transfer contains unencrypted meeting text."
    }
    var externalFileWarning: LocalizedStringResource {
        "The received file remains in Files until you remove it yourself. Steno does not delete or change that external file."
    }

    static func actions(
        for disposition: MeetingTransferImportDisposition,
        hasAudio: Bool
    ) -> [Action] {
        switch disposition {
        case .conflict: [.close]
        case .alreadyPresent: [.openExisting, .close]
        case .new: [.importOnly, .close]
        }
    }

    init(
        sessionID: UUID,
        sourceMeetingID: MeetingID,
        title: String,
        createdAt: Date,
        capabilities: Set<MeetingTransferCapability>,
        visibleSpeakerLabels: [String],
        audioTracks: [AudioTrack],
        localeIdentifier: String?,
        localeOrigin: MeetingTransferLocaleOrigin,
        disposition: MeetingTransferImportDisposition
    ) {
        self.sessionID = sessionID
        self.sourceMeetingID = sourceMeetingID
        self.title = title
        self.createdAt = createdAt
        self.capabilities = capabilities
        self.visibleSpeakerLabels = visibleSpeakerLabels
        self.audioTracks = audioTracks
        self.localeIdentifier = localeIdentifier
        self.localeOrigin = localeOrigin
        self.disposition = disposition
    }

    init(_ prepared: MeetingTransferPreparedImport) {
        self.init(
            sessionID: prepared.sessionID,
            sourceMeetingID: prepared.preview.sourceMeetingID,
            title: prepared.preview.title,
            createdAt: prepared.preview.createdAt,
            capabilities: prepared.preview.capabilities,
            visibleSpeakerLabels: prepared.preview.visibleSpeakerLabels,
            audioTracks: prepared.preview.audioTracks.map {
                AudioTrack(label: $0.label, byteCount: $0.byteCount)
            },
            localeIdentifier: prepared.preview.localeIdentifier,
            localeOrigin: prepared.preview.localeOrigin,
            disposition: prepared.preview.disposition
        )
    }
}

struct MeetingTransferDetailPresentation: Equatable, Sendable {
    let receipt: MeetingTransferReceipt

    var originLabel: LocalizedStringResource { "Imported via AirDrop" }
    var contentLabel: LocalizedStringResource {
        let capabilities = receipt.includedCapabilities
        return switch (
            capabilities.contains(.notes),
            capabilities.contains(.transcript),
            capabilities.contains(.audio)
        ) {
        case (true, true, true): "Notes, Transcript, Audio"
        case (true, true, false): "Notes, Transcript"
        case (true, false, true): "Notes, Audio"
        case (false, true, true): "Transcript, Audio"
        case (true, false, false): "Notes"
        case (false, true, false): "Transcript"
        case (false, false, true): "Audio"
        case (false, false, false): "No content"
        }
    }
    var sourceLanguageLabel: LocalizedStringResource {
        guard let identifier = receipt.sourceLocaleIdentifier else {
            return "Not included"
        }
        switch receipt.sourceLocaleOrigin {
        case .explicit:
            return "\(identifier) (selected on source device)"
        case .estimated:
            return "\(identifier) (estimated on source device)"
        case .absent:
            return "\(identifier) (not included)"
        }
    }
    var externalFileWarning: LocalizedStringResource {
        "The received unencrypted meeting file may remain in Files. Steno does not delete or change that external file."
    }
}

struct MeetingTransferImportSheet: View {
    @Environment(AppModel.self) private var model
    let sceneID: MeetingTransferSceneID

    var body: some View {
        NavigationStack {
            Group {
                switch model.meetingTransferImportState {
                case .preparing(let progress):
                    progressContent("Checking meeting package", progress: progress)
                case .preview(let presentation):
                    previewContent(presentation)
                case .importing(let presentation, let progress):
                    progressContent("Importing \(presentation.title)", progress: progress)
                case .cleanupRequired(_, let result, let message):
                    cleanupContent(result: result, message: message)
                case .completed(let result):
                    completedContent(result)
                case .recoveryRequired:
                    outcomeContent(
                        "Import recovery required",
                        systemImage: "arrow.clockwise.circle",
                        message: "Steno cannot confirm the meeting commit. Recovery must finish before this package can be handled again."
                    )
                case .failed(let message):
                    outcomeContent(
                        "The meeting package could not be imported",
                        systemImage: "exclamationmark.triangle",
                        message: message
                    )
                case nil:
                    EmptyView()
                }
            }
            .navigationTitle("Import meeting")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(model.meetingTransferImportState?.isBusy == true)
    }

    private func progressContent(
        _ title: String,
        progress: MeetingTransferProgress?
    ) -> some View {
        let presentation = MeetingTransferProgressPresentation.make(progress)
        return VStack(spacing: 16) {
            progressIndicator(presentation)
            Text(title).font(.headline)
            Text("Closing stops this operation and removes Steno's private prepared copy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel", role: .cancel) { model.closeMeetingTransferImport(for: sceneID) }
        }
        .padding()
    }

    @ViewBuilder
    private func progressIndicator(
        _ presentation: MeetingTransferProgressPresentation
    ) -> some View {
        switch presentation {
        case .indeterminate:
            ProgressView()
                .accessibilityLabel(Text(presentation.accessibilityLabel))
        case .determinate(let value):
            ProgressView(value: value)
                .accessibilityLabel(Text(presentation.accessibilityLabel))
        }
    }

    private func previewContent(_ presentation: MeetingTransferImportPresentation) -> some View {
        List {
            if case .alreadyPresent = presentation.disposition {
                Label("This meeting is already in your library. Nothing will be imported.", systemImage: "checkmark.circle")
            } else if presentation.disposition != .new {
                Label("A different version of this meeting is already present. Steno will not overwrite, merge, or duplicate it.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Section("Meeting") {
                LabeledContent("Title", value: presentation.title)
                LabeledContent("Date", value: presentation.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Origin ID", value: presentation.technicalOriginID)
                LabeledContent(
                    "Contents",
                    value: presentation.capabilityLabels
                        .map { String(localized: $0) }
                        .joined(separator: ", ")
                )
                LabeledContent("Source language", value: sourceLanguage(presentation))
            }
            if !presentation.visibleSpeakerLabels.isEmpty {
                Section("Visible speaker labels") {
                    ForEach(presentation.speakerLabelRows) { row in
                        Text(row.label)
                    }
                    Text(presentation.speakerLabelPrivacyHint)
                        .foregroundStyle(.secondary)
                }
            }
            if !presentation.audioTracks.isEmpty {
                Section("Audio") {
                    ForEach(Array(presentation.audioTracks.enumerated()), id: \.offset) { _, track in
                        LabeledContent(track.label, value: byteCount(track.byteCount))
                    }
                    LabeledContent("Total", value: byteCount(presentation.totalAudioBytes))
                }
            }
            Section("Cleartext file") {
                Label(presentation.cleartextWarning, systemImage: "lock.open")
                Label(presentation.externalFileWarning, systemImage: "folder")
            }
            Section {
                actions(presentation)
            }
        }
    }

    @ViewBuilder
    private func actions(_ presentation: MeetingTransferImportPresentation) -> some View {
        let actions = MeetingTransferImportPresentation.actions(
            for: presentation.disposition,
            hasAudio: presentation.containsRawRecording
        )
        if actions.contains(.openExisting) {
            Button("Open existing meeting") {
                model.openExistingMeetingFromTransferPreview(for: sceneID)
            }
        }
        if actions.contains(.importOnly) {
            Button("Import") { model.importMeetingPackage(for: sceneID) }
        }
        Button("Close", role: .cancel) { model.closeMeetingTransferImport(for: sceneID) }
    }

    private func cleanupContent(
        result: MeetingTransferImportResult?,
        message: String
    ) -> some View {
        VStack(spacing: 16) {
            Label("Private import cleanup required", systemImage: "trash.slash")
                .font(.headline)
            Text(message).multilineTextAlignment(.center)
            Text(result == nil
                ? "Nothing has been imported."
                : "The import outcome is retained until Steno can remove its private prepared copy.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry cleanup") { model.retryMeetingTransferCleanup(for: sceneID) }
        }
        .padding()
    }

    private func completedContent(_ result: MeetingTransferImportResult) -> some View {
        outcomeContent(
            "Import completed",
            systemImage: "checkmark.circle",
            message: completedMessage(result)
        )
    }

    private func outcomeContent(
        _ title: String,
        systemImage: String,
        message: String
    ) -> some View {
        VStack(spacing: 16) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Close") { model.closeMeetingTransferImport(for: sceneID) }
        }
        .padding()
    }

    private func completedMessage(_ result: MeetingTransferImportResult) -> String {
        switch result {
        case .imported: String(localized: "The meeting commit completed before cancellation could take effect.")
        case .alreadyPresent: String(localized: "The existing meeting was confirmed before cancellation could take effect.")
        case .pendingRecovery: String(localized: "The commit outcome requires recovery.")
        }
    }

    private func sourceLanguage(_ presentation: MeetingTransferImportPresentation) -> String {
        let identifier = presentation.localeIdentifier
            ?? String(localized: "Not included")
        switch presentation.localeOrigin {
        case .explicit:
            return String(localized: "\(identifier) (selected on source device)")
        case .estimated:
            return String(localized: "\(identifier) (estimated on source device)")
        case .absent:
            return String(localized: "\(identifier) (not included)")
        }
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
