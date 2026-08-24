import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary
import StenoPipeline
import SwiftUI

struct MeetingTransferSecurityScopedResource: Sendable {
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void

    static let live = MeetingTransferSecurityScopedResource(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

struct MeetingTransferImportClient: Sendable {
    typealias Progress = @Sendable (MeetingTransferProgress) -> Void
    typealias Prepare = @Sendable (
        URL,
        @escaping Progress
    ) async throws -> MeetingTransferImportPresentation
    typealias Import = @Sendable (
        UUID,
        MeetingTransferProcessingChoice,
        @escaping Progress
    ) async throws -> MeetingTransferImportResult

    let prepareImport: Prepare
    let importPrepared: Import
    let discardPrepared: @Sendable (UUID) async throws -> Void

    init(
        prepareImport: @escaping Prepare,
        importPrepared: @escaping Import,
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

struct MeetingTransferDetailClient: Sendable {
    typealias Load = @Sendable (
        MeetingID
    ) async throws -> MeetingTransferDetailPresentation?
    typealias RequestManualRetry = @Sendable (
        MeetingID,
        MeetingTransferGenerationID,
        String,
        Bool
    ) async throws -> Void

    let load: Load
    let requestManualRetry: RequestManualRetry

    init(
        load: @escaping Load,
        requestManualRetry: @escaping RequestManualRetry
    ) {
        self.load = load
        self.requestManualRetry = requestManualRetry
    }

    init(library: Library, jobStore: JobStore) {
        let stateStore = MeetingTransferStateStore(layout: library.layout)
        let reconciler = ImportedMeetingProcessingReconciler(
            library: library,
            stateStore: stateStore,
            jobStore: jobStore
        )
        load = { meetingID in
            guard let state = try await stateStore.load(meetingID),
                  let receipt = try await library.loadMeeting(meetingID)
                    .metadata?.transferReceipt else {
                return nil
            }
            let job: Job?
            if case .jobEnqueued(let jobID, _) = state {
                job = try? await jobStore.load(jobID)
            } else {
                job = nil
            }
            return MeetingTransferDetailPresentation.make(
                receipt: receipt,
                state: state,
                hasAudio: receipt.includedCapabilities.contains(.audio),
                requiresFreshImportRetry: try await stateStore
                    .requiresFreshImportRetry(meetingID),
                job: job,
                meetingID: meetingID
            )
        }
        requestManualRetry = { meetingID, generationID, localeIdentifier, modelsReady in
            _ = try await reconciler.requestManualRetry(
                meetingID: meetingID,
                expectedImportGenerationID: generationID,
                localeIdentifier: localeIdentifier,
                modelsReady: modelsReady
            )
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
        case .preview(let presentation), .importing(let presentation, _):
            presentation
        case .preparing, .cleanupRequired, .completed, .recoveryRequired, .failed:
            nil
        }
    }

    var progress: MeetingTransferProgress? {
        switch self {
        case .preparing(let progress), .importing(_, let progress):
            progress
        case .preview, .cleanupRequired, .completed, .recoveryRequired, .failed:
            nil
        }
    }

    var cleanupSessionID: UUID? {
        guard case .cleanupRequired(let sessionID, _, _) = self else { return nil }
        return sessionID
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .importing:
            true
        case .preview, .cleanupRequired, .completed, .recoveryRequired, .failed:
            false
        }
    }
}

struct MeetingTransferImportPresentation: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case importOnly
        case importAndProcess
        case openExisting
        case close
    }

    enum ProcessingOutcome: Equatable, Sendable {
        case importsAwaitingModel
        case enqueuesPinnedProcessing
    }

    struct AudioTrack: Equatable, Sendable {
        let label: String
        let byteCount: Int64

        init(label: String, byteCount: Int64) {
            self.label = label
            self.byteCount = byteCount
        }
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

    var technicalOriginID: String {
        String(sourceMeetingID.description.prefix(8))
    }

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

    var containsPersonalSpeakerLabels: Bool {
        !visibleSpeakerLabels.isEmpty
    }

    var audioTrackCount: Int { audioTracks.count }

    var totalAudioBytes: Int64 {
        audioTracks.reduce(0) { $0 + $1.byteCount }
    }

    var containsRawRecording: Bool { !audioTracks.isEmpty }

    var preselectedLocaleIdentifier: String? {
        guard localeOrigin != .absent else { return nil }
        return localeIdentifier
    }

    var cleartextWarning: LocalizedStringResource {
        if containsRawRecording {
            "This transfer contains an unencrypted raw recording and may include voices of other people."
        } else {
            "This transfer contains unencrypted meeting text."
        }
    }

    var downloadsWarning: LocalizedStringResource {
        "The received file may remain in Downloads, where search indexing or a configured backup can copy it. Steno does not delete that file."
    }

    static func actions(
        for disposition: MeetingTransferImportDisposition,
        hasAudio: Bool
    ) -> [Action] {
        switch disposition {
        case .conflict:
            [.close]
        case .alreadyPresent:
            [.openExisting, .close]
        case .new where hasAudio:
            [.importOnly, .importAndProcess, .close]
        case .new:
            [.importOnly, .close]
        }
    }

    static func requiresLanguageConfirmation(
        _ origin: MeetingTransferLocaleOrigin
    ) -> Bool {
        switch origin {
        case .explicit, .estimated, .absent:
            true
        }
    }

    static func processingOutcome(modelsReady: Bool) -> ProcessingOutcome {
        modelsReady ? .enqueuesPinnedProcessing : .importsAwaitingModel
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
    enum Action: Equatable, Sendable {
        case process
        case confirmLanguage
        case installModelAndProcess
        case retry
    }

    enum ProcessingStatus: Equatable, Sendable {
        case ready
        case completed
        case confirmLanguage
        case modelMissing(localeIdentifier: String)
        case processing
        case failed(localeIdentifier: String, reason: String)
        case recoveryRequired
    }

    let receipt: MeetingTransferReceipt
    let hasAudio: Bool
    let processingStatus: ProcessingStatus
    private let retryIsAllowed: Bool

    var actions: [Action] {
        guard hasAudio else { return [] }
        return switch processingStatus {
        case .ready:
            [.process]
        case .completed:
            []
        case .confirmLanguage:
            [.confirmLanguage]
        case .modelMissing:
            [.installModelAndProcess]
        case .processing, .recoveryRequired:
            []
        case .failed:
            retryIsAllowed ? [.retry] : []
        }
    }

    static func make(
        receipt: MeetingTransferReceipt,
        state: ImportedMeetingProcessingState,
        hasAudio: Bool,
        requiresFreshImportRetry: Bool,
        job: Job? = nil,
        meetingID: MeetingID? = nil
    ) -> MeetingTransferDetailPresentation {
        let resolution: (status: ProcessingStatus, retryIsAllowed: Bool)
        if requiresFreshImportRetry {
            resolution = (.recoveryRequired, false)
        } else if !hasAudio, state == .awaitingLanguageConfirmation {
            resolution = (.ready, false)
        } else {
            resolution = switch state {
            case .importedOnly:
                (.ready, false)
            case .awaitingLanguageConfirmation:
                (.confirmLanguage, false)
            case .awaitingModel(let localeIdentifier):
                (.modelMissing(localeIdentifier: localeIdentifier), false)
            case .processingRequested:
                (.processing, false)
            case .jobEnqueued(let jobID, let localeIdentifier):
                resolveEnqueuedJob(
                    job,
                    expectedJobID: jobID,
                    expectedMeetingID: meetingID ?? receipt.sourceMeetingID,
                    expectedLocaleIdentifier: localeIdentifier,
                    expectedGenerationID: receipt.importGenerationID
                )
            case .needsManualRetry(_, let localeIdentifier, let reason):
                (.failed(localeIdentifier: localeIdentifier, reason: reason), true)
            }
        }
        return MeetingTransferDetailPresentation(
            receipt: receipt,
            hasAudio: hasAudio,
            processingStatus: resolution.status,
            retryIsAllowed: resolution.retryIsAllowed
        )
    }

    private static func resolveEnqueuedJob(
        _ job: Job?,
        expectedJobID: JobID,
        expectedMeetingID: MeetingID,
        expectedLocaleIdentifier: String,
        expectedGenerationID: MeetingTransferGenerationID?
    ) -> (ProcessingStatus, Bool) {
        guard let job,
              job.id == expectedJobID,
              job.kind == .finalASR,
              job.meetingID == expectedMeetingID,
              job.localeIdentifier == expectedLocaleIdentifier,
              job.importGenerationID == expectedGenerationID else {
            return (
                .failed(
                    localeIdentifier: expectedLocaleIdentifier,
                    reason: "The saved processing job does not match this import."
                ),
                false
            )
        }
        return switch job.status {
        case .queued, .running:
            (.processing, false)
        case .finished:
            (.completed, false)
        case .failed:
            (
                .failed(
                    localeIdentifier: expectedLocaleIdentifier,
                    reason: job.errorMessage ?? "Processing failed."
                ),
                true
            )
        case .cancelled:
            (
                .failed(
                    localeIdentifier: expectedLocaleIdentifier,
                    reason: "Processing was cancelled."
                ),
                true
            )
        }
    }
}

struct MeetingTransferImportView: View {
    @Environment(AppModel.self) private var model

    @State private var selectedLocaleIdentifier = ""
    @State private var languageConfirmed = false
    @State private var selectedModelsReady: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.l) {
            header
            Divider()
            stateContent
        }
        .padding(Steno.Space.xl)
        .frame(width: 640)
        .frame(minHeight: 360)
        .task(id: model.meetingTransferImportState?.preview?.sessionID) {
            await prepareLanguageChoice()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Text("Import meeting package")
                    .font(.title2.weight(.semibold))
                Text("Steno validates the received file before changing your library.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.meetingTransferImportState {
        case .preparing(let progress):
            progressContent(
                title: "Checking meeting package",
                progress: progress,
                cancelTitle: "Cancel"
            )
        case .preview(let presentation):
            previewContent(presentation)
        case .importing(let presentation, let progress):
            progressContent(
                title: "Importing \(presentation.title)",
                progress: progress,
                cancelTitle: "Cancel import"
            )
        case .cleanupRequired(_, let result, let message):
            cleanupContent(committedResult: result, message: message)
        case .completed(let result):
            VStack(alignment: .leading, spacing: Steno.Space.m) {
                Label("Import completed", systemImage: "checkmark.circle")
                    .font(.headline)
                Text(completedImportMessage(result))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Continue") { model.closeMeetingTransferImport() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .recoveryRequired:
            VStack(alignment: .leading, spacing: Steno.Space.m) {
                Label("Import recovery required", systemImage: "arrow.clockwise.circle")
                    .font(.headline)
                Text("Steno cannot confirm that the meeting commit completed. Recovery must finish before you import this package again. No processing job was created.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { model.closeMeetingTransferImport() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Steno.Space.m) {
                Label("The meeting package could not be imported", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(Steno.Colors.error)
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { model.closeMeetingTransferImport() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func completedImportMessage(
        _ result: MeetingTransferImportResult
    ) -> LocalizedStringResource {
        switch result {
        case .imported:
            "The meeting commit completed before cancellation could take effect. Continue to open the imported meeting."
        case .alreadyPresent:
            "The existing meeting was confirmed before cancellation could take effect. Continue to open it."
        case .pendingRecovery:
            "The commit outcome requires recovery before this package can be handled again."
        }
    }

    private func progressContent(
        title: String,
        progress: MeetingTransferProgress?,
        cancelTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Text(title).font(.headline)
            let progressPresentation = MeetingTransferProgressPresentation.make(progress)
            progressIndicator(progressPresentation)
            Text(progress.map(progressTitle) ?? "Preparing private validation copy")
            if let progress, progress.totalBytes > 0 {
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: progress.processedBytes,
                        countStyle: .file
                    )
                )
                .monospacedDigit()
            }
            Text("Closing stops the current check or import and removes Steno's private prepared copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(cancelTitle, role: .cancel) {
                    model.closeMeetingTransferImport()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func previewContent(
        _ presentation: MeetingTransferImportPresentation
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Steno.Space.l) {
                dispositionBanner(presentation.disposition)
                metadataSection(presentation)
                if !presentation.visibleSpeakerLabels.isEmpty {
                    speakersSection(presentation.visibleSpeakerLabels)
                }
                if !presentation.audioTracks.isEmpty {
                    audioSection(presentation)
                }
                warningsSection(presentation)
                if presentation.disposition == .new,
                   presentation.containsRawRecording {
                    processingSection(presentation)
                }
                actionRow(presentation)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func dispositionBanner(
        _ disposition: MeetingTransferImportDisposition
    ) -> some View {
        switch disposition {
        case .new:
            EmptyView()
        case .alreadyPresent:
            Label(
                "This exact meeting is already in your library. Importing it again would not change anything.",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(.secondary)
        case .conflict:
            Label(
                "A different version of this source meeting is already present. Steno will not overwrite, merge or duplicate it.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(Steno.Colors.error)
        }
    }

    private func metadataSection(
        _ presentation: MeetingTransferImportPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Text(presentation.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            LabeledContent("Meeting date") {
                Text(presentation.createdAt.formatted(date: .long, time: .shortened))
            }
            LabeledContent("Origin ID") {
                Text(presentation.technicalOriginID)
                    .monospaced()
                    .help(presentation.sourceMeetingID.description)
            }
            LabeledContent("Contents") {
                Text(
                    presentation.capabilityLabels
                        .map { String(localized: $0) }
                        .joined(separator: ", ")
                )
            }
            LabeledContent("Source language") {
                Text(sourceLanguageText(presentation))
            }
        }
    }

    private func speakersSection(_ labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            Label("Personal speaker text", systemImage: "person.text.rectangle")
                .font(.headline)
            Text("The package contains these visible speaker labels:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(labels.joined(separator: ", "))
                .textSelection(.enabled)
        }
    }

    private func audioSection(
        _ presentation: MeetingTransferImportPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Text("Audio").font(.headline)
            ForEach(Array(presentation.audioTracks.enumerated()), id: \.offset) { _, track in
                LabeledContent(track.label) {
                    Text(Self.byteCount(track.byteCount)).monospacedDigit()
                }
            }
            LabeledContent("Total, \(presentation.audioTrackCount) tracks") {
                Text(Self.byteCount(presentation.totalAudioBytes)).monospacedDigit()
            }
        }
    }

    private func warningsSection(
        _ presentation: MeetingTransferImportPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Label(presentation.cleartextWarning, systemImage: "lock.open")
            Label(presentation.downloadsWarning, systemImage: "folder.badge.questionmark")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func processingSection(
        _ presentation: MeetingTransferImportPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            Text("Optional local processing").font(.headline)
            Picker("Spoken language", selection: $selectedLocaleIdentifier) {
                Text("Choose a language").tag("")
                ForEach(model.availableLocales, id: \.identifier) { locale in
                    Text(model.localizedLanguageName(locale)).tag(locale.identifier)
                }
            }
            .onChange(of: selectedLocaleIdentifier) {
                languageConfirmed = false
                selectedModelsReady = nil
                Task { await refreshSelectedModelReadiness() }
            }
            Toggle(isOn: $languageConfirmed) {
                Text(confirmationText(presentation))
            }
            .disabled(selectedLocaleIdentifier.isEmpty)
            modelStatus
        }
        .padding(Steno.Space.m)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var modelStatus: some View {
        if selectedLocaleIdentifier.isEmpty {
            Text("Choose the language spoken in this recording. The Mac system locale is never used as a guess.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let selectedModelsReady {
            Label(
                selectedModelsReady
                    ? "Local models are ready."
                    : "Local models are missing. The meeting and audio will still be imported, but no job or download will start.",
                systemImage: selectedModelsReady ? "checkmark.circle" : "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: Steno.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Checking local models")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func actionRow(
        _ presentation: MeetingTransferImportPresentation
    ) -> some View {
        let actions = MeetingTransferImportPresentation.actions(
            for: presentation.disposition,
            hasAudio: presentation.containsRawRecording
        )
        return HStack {
            Button("Close", role: .cancel) {
                model.closeMeetingTransferImport()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if actions.contains(.openExisting) {
                Button("Open existing meeting") {
                    model.openExistingMeetingFromTransferPreview()
                }
                .keyboardShortcut(.defaultAction)
            }
            if actions.contains(.importOnly) {
                Button(presentation.containsRawRecording ? "Import only" : "Import") {
                    model.importMeetingPackage(choice: .importOnly)
                }
                .keyboardShortcut(
                    presentation.containsRawRecording ? nil : .defaultAction
                )
            }
            if actions.contains(.importAndProcess) {
                Button("Import and process") {
                    importAndProcess()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedLocaleIdentifier.isEmpty
                        || !languageConfirmed
                        || selectedModelsReady == nil
                )
            }
        }
    }

    private func cleanupContent(
        committedResult: MeetingTransferImportResult?,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Label("Private import cleanup required", systemImage: "trash.slash")
                .font(.headline)
                .foregroundStyle(Steno.Colors.error)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                committedResult == nil
                    ? "The prepared session is retained so cleanup can be retried. Nothing has been imported."
                    : "The library commit may be complete, but Steno will not show success or start another action until its private session is removed."
            )
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Retry cleanup") { model.retryMeetingTransferCleanup() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func prepareLanguageChoice() async {
        guard let presentation = model.meetingTransferImportState?.preview else { return }
        languageConfirmed = false
        if let sourceIdentifier = presentation.preselectedLocaleIdentifier,
           let locale = model.meetingTransferLocale(identifier: sourceIdentifier) {
            selectedLocaleIdentifier = locale.identifier
        } else {
            selectedLocaleIdentifier = ""
        }
        await refreshSelectedModelReadiness()
    }

    private func refreshSelectedModelReadiness() async {
        guard !selectedLocaleIdentifier.isEmpty else {
            selectedModelsReady = nil
            return
        }
        let identifier = selectedLocaleIdentifier
        let ready = await model.meetingTransferModelsReady(for: identifier)
        guard selectedLocaleIdentifier == identifier else { return }
        selectedModelsReady = ready
    }

    private func importAndProcess() {
        guard languageConfirmed,
              !selectedLocaleIdentifier.isEmpty,
              let selectedModelsReady else { return }
        model.importMeetingPackage(choice: .process(
            localeIdentifier: selectedLocaleIdentifier,
            languageConfirmed: true,
            modelsReady: selectedModelsReady
        ))
    }

    private func sourceLanguageText(
        _ presentation: MeetingTransferImportPresentation
    ) -> String {
        let source = presentation.localeIdentifier.map {
            Locale.current.localizedString(forIdentifier: $0) ?? $0
        } ?? String(localized: "Not included")
        switch presentation.localeOrigin {
        case .explicit:
            return String(localized: "\(source) (selected on the source device)")
        case .estimated:
            return String(localized: "\(source) (estimated on the source device)")
        case .absent:
            return String(localized: "\(source) (no source language)")
        }
    }

    private func confirmationText(
        _ presentation: MeetingTransferImportPresentation
    ) -> String {
        let locale = model.meetingTransferLocale(identifier: selectedLocaleIdentifier)
        let name = locale.map(model.localizedLanguageName)
            ?? String(localized: "the selected language")
        return String(localized: "I confirm that \(name) is spoken in this recording.")
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
            ProgressView(value: value, total: 1)
                .accessibilityLabel(Text(presentation.accessibilityLabel))
        }
    }

    private func progressTitle(_ progress: MeetingTransferProgress) -> String {
        switch progress.phase {
        case .enumerating: String(localized: "Reading package contents")
        case .hashing: String(localized: "Hashing the received file")
        case .readingArchive: String(localized: "Validating the package")
        case .validatingAudio: String(localized: "Validating audio")
        case .writing: String(localized: "Writing the private import copy")
        }
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
