import StenoDomain
import StenoPipeline
import SwiftUI

struct MeetingDetailObservationState {
    struct Key: Hashable {
        let meetingID: MeetingID
        let generation: UInt64
    }

    private var generation: UInt64 = 0

    func key(for meetingID: MeetingID) -> Key {
        Key(meetingID: meetingID, generation: generation)
    }

    mutating func restartAfterManualProcessingRequest() {
        generation &+= 1
    }
}

enum MeetingDetailObservationPolicy {
    static func shouldContinue(
        hasRevision: Bool,
        jobs: [Job],
        transferStatus: MeetingTransferDetailPresentation.ProcessingStatus?
    ) -> Bool {
        if jobs.contains(where: { $0.status == .queued || $0.status == .running }) {
            return true
        }
        if let transferStatus {
            return transferStatus == .processing
        }
        return !hasRevision
    }
}

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let meetingID: MeetingID

    @State private var revision: TranscriptRevision?
    @State private var jobs: [StenoDomain.Job] = []
    @State private var review: MeetingReviewData?
    /// Importierte Alt-Meetings bringen ein Transkript ohne Wortzeitstempel
    /// mit; die Sprechererkennung transkribiert dann zuerst neu.
    @State private var needsTranscriptionFirst = false
    @State private var meeting: Meeting?
    @State private var duration: TimeInterval?
    @State private var speakerPresentationContext = SpeakerPresentationContext.empty
    /// Der Inspector oeffnet sich von selbst, solange Sprecherarbeit ansteht,
    /// und bleibt danach zu - er ist Werkzeug, nicht Daueranzeige.
    @State private var showInspector = false
    @State private var didDecideInspector = false
    /// Genau eine Zeile ist bearbeitbar. Mehrere offene Felder auf demselben
    /// Stand wuerden beim zweiten Speichern an der Elternpruefung scheitern -
    /// zu Recht, aber ohne dass jemand versteht, warum.
    @State private var editingTurn: Int?
    @State private var transcriptQuery = ""
    @State private var showFind = false
    @FocusState private var findFocused: Bool
    @State private var pending: TranscriptRevision?
    /// Sofortiges UI-Gate: gespeicherte Jobs werden erst nach dem ersten
    /// await sichtbar. Bis dahin darf ein zweiter Klick nicht durchkommen.
    @State private var isStartingSpeakerProcessing = false
    @State private var transferDetail: MeetingTransferDetailPresentation?
    @State private var transferLocaleIdentifier = ""
    @State private var transferLanguageConfirmed = false
    @State private var isWorkingOnTransfer = false
    @State private var observationState = MeetingDetailObservationState()
    @State private var showMeetingTransferExport = false

    var body: some View {
        Group {
            if let revision, !revision.turns.isEmpty {
                transcriptList(revision)
            } else {
                ContentUnavailableView(
                    meeting?.status == .draft ? "Draft" : "No transcript yet",
                    systemImage: meeting?.status == .draft
                        ? "square.and.pencil"
                        : "text.quote",
                    description: Text(pendingDescription)
                )
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                meetingTransferTopStatus
                pendingBanner
                legacyUpgradeTopStatus
                findBar
            }
        }
        .safeAreaInset(edge: .bottom) { jobStatusBar }
        .navigationTitle(meeting?.title ?? "")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $showInspector) { inspectorContent }
        .toolbar {
            ToolbarItem {
                Button {
                    showFind = true
                    findFocused = true
                } label: {
                    Label("Find in transcript", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f")
                .help("Find in this transcript (Cmd-F)")
                .disabled(revision == nil)
            }
            ToolbarItem {
                Toggle(isOn: $showInspector) {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show notes, participants and speaker assignment")
            }
            if MeetingPresentation.canShareMeeting(status: meeting?.status) {
                ToolbarItem {
                    Button {
                        showMeetingTransferExport = true
                    } label: {
                        Label("Share meeting", systemImage: "square.and.arrow.up")
                    }
                    .help("Share this meeting through AirDrop")
                }
            }
        }
        .sheet(isPresented: $showMeetingTransferExport) {
            MeetingTransferExportView(meetingID: meetingID)
                .environment(model)
        }
        .task(id: observationState.key(for: meetingID)) { await refreshLoop() }
        // Eine offene Bearbeitung ueberlebt weder einen Filterwechsel noch
        // einen neuen Transkriptstand: im ersten Fall verschwindet die Zeile
        // unter dem offenen Feld, im zweiten zeigt der Index auf einen anderen
        // Turn. Das Speichern faenge das ueber die Elternpruefung ab, aber der
        // Benutzer haette bis dahin in ein totes Feld getippt.
        .onChange(of: transcriptQuery) { editingTurn = nil }
        .onChange(of: revision?.id) { editingTurn = nil }
    }

    @ViewBuilder
    private var meetingTransferTopStatus: some View {
        if let transferDetail {
            VStack(alignment: .leading, spacing: Steno.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Imported via AirDrop", systemImage: "airplayaudio")
                        .font(.headline)
                    Spacer()
                    Text(transferDetail.receipt.importedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(
                    transferDetail.hasAudio
                        ? "Audio included in the received meeting."
                        : "No audio was included in the received meeting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                meetingTransferProcessingStatus(transferDetail)
            }
            .padding(.horizontal, Steno.Space.m)
            .padding(.vertical, Steno.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            Divider()
        }
    }

    @ViewBuilder
    private func meetingTransferProcessingStatus(
        _ detail: MeetingTransferDetailPresentation
    ) -> some View {
        switch detail.processingStatus {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            if detail.actions.contains(.process) {
                meetingTransferLanguageAction(
                    detail,
                    title: "Process recording"
                )
            }
        case .completed:
            Label("Ready - processing completed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .confirmLanguage:
            Label("Confirm language", systemImage: "character.bubble")
                .foregroundStyle(.secondary)
            if detail.actions.contains(.confirmLanguage) {
                meetingTransferLanguageAction(
                    detail,
                    title: "Confirm language and process"
                )
            }
        case .modelMissing(let localeIdentifier):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Label(
                    "Model missing for \(languageName(localeIdentifier))",
                    systemImage: "arrow.down.circle"
                )
                .foregroundStyle(.secondary)
                Text("No download or processing job starts automatically. Installation downloads speech assets from Apple and speaker separation from huggingface.co.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isInstallingModels {
                    ProgressView(
                        value: model.modelInstallProgress?.fraction ?? 0,
                        total: 1
                    ) {
                        Text(model.modelInstallProgress?.title ?? "Installing models")
                    }
                } else if detail.actions.contains(.installModelAndProcess) {
                    Button("Install model and process") {
                        installTransferModelAndProcess(localeIdentifier)
                    }
                    .controlSize(.small)
                    .disabled(isWorkingOnTransfer)
                }
                if let error = model.modelError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Steno.Colors.error)
                        .textSelection(.enabled)
                }
            }
        case .processing:
            HStack(spacing: Steno.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Processing")
            }
            .foregroundStyle(.secondary)
        case .failed(let localeIdentifier, let reason):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Label(
                    "Processing failed for \(languageName(localeIdentifier)): \(reason)",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Steno.Colors.error)
                if detail.actions.contains(.retry) {
                    meetingTransferLanguageAction(
                        detail,
                        title: "Retry"
                    )
                }
            }
        case .recoveryRequired:
            Label(
                "Retry the import after recovery. No processing job was created.",
                systemImage: "arrow.clockwise.circle"
            )
            .foregroundStyle(Steno.Colors.error)
        }
    }

    private func meetingTransferLanguageAction(
        _ detail: MeetingTransferDetailPresentation,
        title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            Picker("Spoken language", selection: $transferLocaleIdentifier) {
                Text("Choose a language").tag("")
                ForEach(model.availableLocales, id: \.identifier) { locale in
                    Text(model.localizedLanguageName(locale)).tag(locale.identifier)
                }
            }
            .onChange(of: transferLocaleIdentifier) {
                transferLanguageConfirmed = false
            }
            Toggle(
                "I confirm this is the language spoken in the recording.",
                isOn: $transferLanguageConfirmed
            )
            .disabled(transferLocaleIdentifier.isEmpty)
            Button(title) {
                requestTransferProcessing(detail)
            }
            .controlSize(.small)
            .disabled(
                isWorkingOnTransfer
                    || transferLocaleIdentifier.isEmpty
                    || !transferLanguageConfirmed
            )
        }
    }

    private func requestTransferProcessing(
        _ detail: MeetingTransferDetailPresentation
    ) {
        guard detail.hasAudio,
              !transferLocaleIdentifier.isEmpty,
              transferLanguageConfirmed,
              !isWorkingOnTransfer else { return }
        isWorkingOnTransfer = true
        Task {
            defer { isWorkingOnTransfer = false }
            let ready = await model.meetingTransferModelsReady(
                for: transferLocaleIdentifier
            )
            guard await model.retryImportedMeetingProcessing(
                meetingID: meetingID,
                localeIdentifier: transferLocaleIdentifier,
                modelsReady: ready
            ) else { return }
            transferLanguageConfirmed = false
            updateTransferDetail(
                await model.loadMeetingTransferDetail(meetingID: meetingID)
            )
            jobs = await model.jobs(for: meetingID)
            observationState.restartAfterManualProcessingRequest()
        }
    }

    private func installTransferModelAndProcess(_ localeIdentifier: String) {
        guard !isWorkingOnTransfer else { return }
        isWorkingOnTransfer = true
        Task {
            defer { isWorkingOnTransfer = false }
            guard await model.installMeetingTransferModels(
                for: localeIdentifier
            ) else { return }
            guard await model.retryImportedMeetingProcessing(
                meetingID: meetingID,
                localeIdentifier: localeIdentifier,
                modelsReady: true
            ) else { return }
            updateTransferDetail(
                await model.loadMeetingTransferDetail(meetingID: meetingID)
            )
            jobs = await model.jobs(for: meetingID)
            observationState.restartAfterManualProcessingRequest()
        }
    }

    private func languageName(_ localeIdentifier: String) -> String {
        model.meetingTransferLocale(identifier: localeIdentifier)
            .map(model.localizedLanguageName)
            ?? localeIdentifier
    }

    /// Sprecherarbeit steht neben dem Transkript, nicht darueber: Wer eine
    /// Hoerprobe prueft, will den Kontext im Transkript sehen, ohne zwischen
    /// zwei Enden derselben Liste zu springen.
    @ViewBuilder
    private var inspectorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Steno.Space.xl) {
                NotesSection(meetingID: meetingID)
                Divider()
                ParticipantsSection(meetingID: meetingID, review: review)
                if review != nil {
                    Divider()
                    SpeakerReviewSection(
                        meetingID: meetingID,
                        revision: revision,
                        review: $review
                    )
                } else if !isSpeakerProcessing,
                          model.meetingsWithAudio.contains(meetingID) {
                    Divider()
                    diarizationStart
                }
            }
            .padding(Steno.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
    }

    /// Diarisierung und Anhören setzen die Originalspur voraus; ohne Audio
    /// (Altimport, geloeschte Spur) gibt es beides nicht.
    private var diarizationStart: some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            Button {
                startSpeakerProcessing()
            } label: {
                Label(
                    needsTranscriptionFirst
                        ? "Re-transcribe and detect speakers"
                        : "Detect speakers",
                    systemImage: "person.2.wave.2"
                )
            }
            .help("Compute diarization and speaker suggestions for this meeting")
            .disabled(isSpeakerProcessing || isStartingSpeakerProcessing)
            if needsTranscriptionFirst {
                Text("This imported meeting has no word-level timestamps. Steno re-transcribes the recording for them; the existing transcript is kept as an earlier version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func transcriptList(_ revision: TranscriptRevision) -> some View {
        // Die Suche filtert, gibt aber die **echten** Turn-Indizes weiter.
        // Mit den Positionen der Trefferliste zu arbeiten hiesse, eine
        // Korrektur an Treffer 2 an Turn 2 des Transkripts zu schreiben.
        let hits = TranscriptSearch.matchingTurnIndices(
            in: revision,
            query: transcriptQuery
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Steno.Space.m) {
                originNote(revision.origin)
                ReportsSection(meetingID: meetingID, review: review)
                Divider()
                if isSearchingTranscript {
                    Text(hits.isEmpty
                        ? "No line contains \u{201C}\(transcriptQuery)\u{201D}."
                        : "\(hits.count) of \(revision.turns.count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(hits, id: \.self) { index in
                    let turn = revision.turns[index]
                    TranscriptTurnRow(
                        turn: turn,
                        review: review,
                        presentationContext: speakerPresentationContext,
                        meetingID: meetingID,
                        isEditing: editingTurn == index,
                        beginEditing: { editingTurn = index },
                        cancelEditing: { editingTurn = nil },
                        endEditing: { text in
                            await save(text, at: index, in: revision)
                        }
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Eigene Leiste statt `.searchable`: Die Seitenleiste belegt den
    /// Suchplatz des Fensters bereits, und zwei `.searchable` im selben
    /// NavigationSplitView streiten sich um dasselbe Feld.
    @ViewBuilder
    private var findBar: some View {
        if showFind {
            HStack(spacing: Steno.Space.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in transcript", text: $transcriptQuery)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    .onExitCommand { closeFind() }
                Button {
                    closeFind()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close the search")
            }
            .padding(.horizontal, Steno.Space.m)
            .padding(.vertical, Steno.Space.s)
            .background(.background.secondary)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func closeFind() {
        transcriptQuery = ""
        showFind = false
    }

    private var isSearchingTranscript: Bool {
        !transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Speichert eine Korrektur und uebernimmt den neuen Stand sofort in die
    /// Ansicht - sonst zeigt sie bis zum naechsten Schleifendurchlauf den
    /// alten Text und der Benutzer tippt ihn ein zweites Mal.
    private func save(
        _ text: String,
        at index: Int,
        in revision: TranscriptRevision
    ) async {
        if let updated = await model.saveTranscriptEdit(
            meetingID: meetingID,
            revision: revision,
            turnIndex: index,
            text: text
        ) {
            self.revision = updated
        }
        editingTurn = nil
    }

    /// Der Neulauf, der wegen einer eigenen Korrektur wartet. Ohne diesen
    /// Hinweis wartet er fuer immer: die Bibliothek parkt ihn, damit er die
    /// Korrektur nicht ueberschreibt, und niemand haette ihn je gesehen.
    @ViewBuilder
    private var pendingBanner: some View {
        if let pending {
            HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                Label(
                    "A newer transcription is ready. Your correction is shown instead.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout)
                Spacer()
                Button("Use the new one") {
                    Task {
                        if await model.adoptPendingTranscript(for: meetingID) {
                            self.pending = nil
                            revision = await model.transcript(for: meetingID)
                        }
                    }
                }
                .controlSize(.small)
                .help("Your correction stays stored as an earlier version")
            }
            .padding(Steno.Space.s)
            .background(.background.secondary)
        }
    }

    /// Datum, Dauer und Zustand in einer Zeile - bei mehreren gleich
    /// benannten Aufnahmen war bisher nicht erkennbar, worin man arbeitet.
    private var subtitle: String {
        guard let meeting else { return "" }
        var parts = [
            meeting.createdAt.formatted(
                .dateTime.day().month().year().hour().minute()
            ),
        ]
        if let duration {
            parts.append(Self.durationText(duration))
        }
        if meeting.status != .ready {
            parts.append(statusWord(meeting.status))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func statusWord(_ status: Meeting.Status) -> String {
        switch status {
        case .draft: "Draft"
        case .recording: "Recording"
        case .interrupted: "Interrupted"
        case .processing: "Processing"
        case .ready: "Ready"
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d min", minutes, secs)
    }

    private var legacyUpgradeState: LegacyUpgradePresentation {
        LegacyUpgradePresentation.state(
            meeting: meeting,
            revision: revision,
            reviewRunID: review?.runID,
            jobs: jobs,
            hasAudio: model.meetingsWithAudio.contains(meetingID),
            needsTranscriptionFirst: needsTranscriptionFirst
        )
    }

    @ViewBuilder
    private var legacyUpgradeTopStatus: some View {
        if legacyUpgradeState != .hidden {
            legacyUpgradeBanner
                .padding(.horizontal, Steno.Space.m)
                .padding(.vertical, Steno.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background)
            Divider()
        }
    }

    @ViewBuilder
    private var legacyUpgradeBanner: some View {
        switch legacyUpgradeState {
        case .hidden:
            EmptyView()
        case .unavailable:
            legacyUpgradeExplanation
        case .ready(let actionTitle):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                legacyUpgradeExplanation
                legacyUpgradeButton(actionTitle)
            }
        case .running(let job):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                legacyUpgradeExplanation
                HStack(spacing: Steno.Space.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(LegacyUpgradePresentation.stepTitle(for: job.kind))
                    Text("for \(Text(job.createdAt, style: .relative))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
            }
        case .failed(let message, let actionTitle):
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                legacyUpgradeExplanation
                Label(
                    "Processing failed: \(message)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(Steno.Colors.error)
                if let actionTitle {
                    legacyUpgradeButton(actionTitle)
                }
            }
        }
    }

    private var legacyUpgradeExplanation: some View {
        Label(
            "Taken over from the legacy Steno app: the timestamps are imprecise and the speaker assignment comes from the old recognition.",
            systemImage: "clock.badge.exclamationmark"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func legacyUpgradeButton(_ title: String) -> some View {
        Button {
            startSpeakerProcessing()
        } label: {
            Label(title, systemImage: "person.2.wave.2")
        }
        .controlSize(.small)
        .help("Compute precise timestamps, diarization and speaker suggestions")
        .disabled(isSpeakerProcessing || isStartingSpeakerProcessing)
    }

    private func startSpeakerProcessing() {
        guard !isStartingSpeakerProcessing else { return }
        isStartingSpeakerProcessing = true
        Task {
            defer { isStartingSpeakerProcessing = false }
            let started = await model.requestDiarization(meetingID: meetingID)
            jobs = await model.jobs(for: meetingID)
            guard started else { return }
            await refreshLoop()
        }
    }

    @ViewBuilder
    private func originNote(_ origin: TranscriptOrigin) -> some View {
        switch origin {
        case .liveProvisional:
            Label(
                "Provisional live transcript; the final run replaces it.",
                systemImage: "hourglass"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .legacyImport:
            EmptyView()
        case .finalRun, .userEdit, .meetingTransfer:
            EmptyView()
        }
    }

    /// Die Statusleiste gehört der Transkriptions-Kette (finalASR,
    /// Diarisierung, Identität). Protokoll-Jobs melden Fortschritt und
    /// Fehler im Protokoll-Bereich, dem konkreten Lauf zugeordnet; ein
    /// alter Protokoll-Fehlschlag darf hier nicht dauerhaft leuchten.
    private var transcriptionJobs: [Job] {
        jobs.filter { $0.kind != .templateRender && $0.kind != .export }
    }

    private var isSpeakerProcessing: Bool {
        transcriptionJobs.contains {
            $0.status == .queued || $0.status == .running
        }
    }

    /// Nur ein Fehlschlag, der nicht schon durch einen spaeteren erfolgreichen
    /// Lauf derselben Art ueberholt ist. Sonst leuchtet ein alter Fehler
    /// dauerhaft weiter, obwohl laengst alles durchgelaufen ist.
    private var lastFailedTranscriptionJob: Job? {
        let failed = transcriptionJobs
            .filter { $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
        return failed.first { job in
            !transcriptionJobs.contains {
                $0.kind == job.kind
                    && $0.status == .finished
                    && $0.createdAt > job.createdAt
            }
        }
    }

    @ViewBuilder
    private var jobStatusBar: some View {
        if !legacyUpgradeOwnsProcessingStatus {
            if let job = transcriptionJobs.first(where: { $0.status == .running || $0.status == .queued }) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stepText(job))
                        .font(.callout)
                    // Die Kette liefert keinen Fortschrittswert. Die verstrichene
                    // Zeit ist das Ehrlichste, was sich anzeigen lässt, und sie
                    // unterscheidet "rechnet noch" von "hängt".
                    Text("for \(Text(job.createdAt, style: .relative))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(8)
                .background(.background.secondary)
            } else if let failed = lastFailedTranscriptionJob {
                Label(
                    "Processing failed: \(failed.errorMessage ?? "unknown")",
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.callout)
                    .foregroundStyle(Steno.Colors.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.background.secondary)
            }
        }
    }

    private var legacyUpgradeOwnsProcessingStatus: Bool {
        switch legacyUpgradeState {
        case .running, .failed: true
        case .hidden, .unavailable, .ready: false
        }
    }

    /// Die Kette hat drei Glieder, und sie dauert Minuten. Wer nach der
    /// Transkription weiter "Transkription läuft" liest, während schon ein
    /// Transkript dasteht, hält die App für hängengeblieben.
    private func stepText(_ job: Job) -> String {
        let step = switch job.kind {
        case .finalASR: "Transcription (step 1 of 3)"
        case .diarization: "Detecting speaker changes (step 2 of 3)"
        case .identitySuggestion: "Comparing voices (step 3 of 3)"
        default: "Processing"
        }
        return job.status == .running ? "\(step) running" : "\(step) queued"
    }

    private var pendingDescription: String {
        if meeting?.status == .draft {
            "Write your notes on the right. Start a recording when the meeting begins."
        } else if jobs.contains(where: { $0.status == .running || $0.status == .queued }) {
            "The final transcription is still running."
        } else {
            "There is no transcript for this meeting."
        }
    }

    /// Aktualisiert Transkript und Jobstatus, solange die Ansicht sichtbar
    /// ist; endet, sobald kein Job mehr offen ist und ein Transkript da ist.
    private func refreshLoop() async {
        while !Task.isCancelled {
            speakerPresentationContext = await model.speakerPresentationContext(
                for: meetingID
            )
            revision = await model.transcript(for: meetingID)
            jobs = await model.jobs(for: meetingID)
            review = await model.loadReviewData(meetingID: meetingID)
            meeting = await model.meeting(meetingID)
            updateTransferDetail(
                await model.loadMeetingTransferDetail(meetingID: meetingID)
            )
            duration = await model.duration(for: meetingID)
            // Verhindert veraltete Audio-Zusagen: sonst blieben Abspiel- und
            // Diarisierungs-Knöpfe nach einer Spurlöschung klickbar.
            await model.refreshAudioAvailability(meetingID)
            needsTranscriptionFirst = ((try? await model.hasFinalASRRun(meetingID)) ?? true) == false
            pending = await model.pendingTranscript(for: meetingID)
            decideInspectorOnce()
            if !MeetingDetailObservationPolicy.shouldContinue(
                hasRevision: revision != nil,
                jobs: jobs,
                transferStatus: transferDetail?.processingStatus
            ) {
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func updateTransferDetail(
        _ detail: MeetingTransferDetailPresentation?
    ) {
        let previousGeneration = transferDetail?.receipt.importGenerationID
        let previousStatus = transferDetail?.processingStatus
        transferDetail = detail
        guard let detail else {
            transferLocaleIdentifier = ""
            transferLanguageConfirmed = false
            return
        }
        let generationChanged = previousGeneration
            != detail.receipt.importGenerationID
        let statusChanged = previousStatus != detail.processingStatus
        guard generationChanged || statusChanged || transferLocaleIdentifier.isEmpty else {
            return
        }
        let suggestedIdentifier: String? = switch detail.processingStatus {
        case .modelMissing(let localeIdentifier),
             .failed(let localeIdentifier, _):
            localeIdentifier
        case .ready, .completed, .confirmLanguage, .processing, .recoveryRequired:
            detail.receipt.sourceLocaleOrigin == .absent
                ? nil
                : detail.receipt.sourceLocaleIdentifier
        }
        if let suggestedIdentifier,
           let locale = model.meetingTransferLocale(identifier: suggestedIdentifier) {
            transferLocaleIdentifier = locale.identifier
        } else if generationChanged {
            transferLocaleIdentifier = ""
        }
        if generationChanged || statusChanged {
            transferLanguageConfirmed = false
        }
    }

    /// Einmal je Meeting entscheiden, nicht bei jedem Schleifendurchlauf:
    /// Sonst risse der Inspector dem Benutzer nach jeder Bestaetigung die
    /// Ansicht unter den Haenden weg.
    private func decideInspectorOnce() {
        // Ein Entwurf besteht aus nichts als seiner Notiz - dort ist der
        // Inspector nicht Werkzeug, sondern der ganze Inhalt.
        if !didDecideInspector, meeting?.status == .draft {
            didDecideInspector = true
            showInspector = true
            return
        }
        guard !didDecideInspector, let review else { return }
        didDecideInspector = true
        showInspector = review.clusters.contains { cluster in
            guard !cluster.isSelf, !cluster.containsMultipleSpeakers else {
                return false
            }
            if case .confirmed = cluster.reviewState { return false }
            return true
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        // Ab einer Stunde ist "1:12:45" lesbar, "72:45" nicht mehr.
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// Ein Transkript-Turn mit Anhören-per-Klick: Play am Zeitstempel spielt
/// genau diesen Turn aus der Originalspur, zur Verifikation des Gehörten.
struct TranscriptTurnRow: View {
    @Environment(AppModel.self) private var model
    let turn: TranscriptTurn
    let review: MeetingReviewData?
    var presentationContext: SpeakerPresentationContext = .empty
    let meetingID: MeetingID
    var isEditing = false
    var beginEditing: (() -> Void)?
    var cancelEditing: (() -> Void)?
    var endEditing: ((String) async -> Void)?

    @State private var hovering = false
    @State private var draft = ""
    @State private var isSaving = false

    var body: some View {
        let presentation = SpeakerPresentationResolver.presentation(
            for: turn.speaker,
            review: review,
            context: presentationContext
        )
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(timestamp(turn.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if model.meetingsWithAudio.contains(meetingID) {
                    Button {
                        Task {
                            await model.toggleSample(
                                playbackSample(channel: playbackChannel(for: presentation)),
                                meetingID: meetingID
                            )
                        }
                    } label: {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                            .foregroundStyle(isPlaying ? AnyShapeStyle(Steno.Colors.recording) : AnyShapeStyle(.secondary))
                            .opacity(isPlaying ? 1 : (hovering ? 1 : 0.3))
                    }
                    .buttonStyle(.plain)
                    // Abspielen liefe in die laufende Aufnahme hinein.
                    .disabled(model.isRecording)
                    .help(model.isRecording
                        ? "Not while recording - it would be captured into the recording"
                        : "Play this section")
                    .accessibilityLabel(isPlaying ? "Stop playback" : "Play this section")
                }
            }
            .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let label = presentation.label {
                    HStack(spacing: 5) {
                        // Der Marker ist eine Zugabe zum Namen, nie sein
                        // Ersatz: Farbe traegt hier keine Information allein.
                        if let color = Steno.Colors.speaker(presentation.marker) {
                            Circle()
                                .fill(color)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let cue = presentation.originCue {
                        Label(cue, systemImage: "text.badge.checkmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(cue)
                    }
                }
                if isEditing {
                    editor
                } else {
                    Text(Self.turnText(turn))
                        .textSelection(.enabled)
                        .font(Steno.readingBody)
                        .lineSpacing(3)
                }
            }
            if !isEditing, beginEditing != nil {
                Spacer(minLength: Steno.Space.s)
                Button {
                    draft = Self.turnText(turn)
                    beginEditing?()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Erscheint erst beim Darueberfahren: Korrigieren ist die
                // Ausnahme, Lesen der Normalfall, und ein Stift an jeder Zeile
                // machte aus dem Transkript ein Formular.
                .opacity(hovering ? 1 : 0)
                .help("Correct this line")
                .accessibilityLabel("Correct this line")
            }
        }
        .onHover { hovering = $0 }
    }

    /// Korrigieren heisst tippen, nicht neu diktieren: das Feld startet mit
    /// dem erkannten Text. Escape verwirft, Cmd-Return speichert - Return
    /// allein bleibt ein Zeilenumbruch, weil eine Wortmeldung ueber mehrere
    /// Zeilen laufen kann.
    private var editor: some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            TextEditor(text: $draft)
                .font(Steno.readingBody)
                .frame(minHeight: 60)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.tertiary)
                }
                .onExitCommand { cancelEditing?() }
            HStack(spacing: Steno.Space.s) {
                Text("The recognised text stays available as an earlier version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Abbrechen darf nicht ueber den Speicherweg laufen. `turnText`
                // streicht ein fuehrendes Satzzeichen kosmetisch weg - der
                // "unveraenderte" Text waere also veraendert und haette beim
                // Abbrechen eine echte Korrektur angelegt.
                Button("Cancel") { cancelEditing?() }
                .controlSize(.small)
                Button("Save") { submit() }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(isSaving)
            }
        }
    }

    private func submit() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await endEditing?(draft)
            isSaving = false
        }
    }

    /// Der ganze Turn als abspielbarer Bereich, ohne 20-s-Deckel: hier geht
    /// es um Verifikation des Inhalts, nicht um eine Hörprobe.
    private func playbackSample(channel: String) -> SpeakerSample {
        SpeakerSample(
            turnStart: turn.start,
            clipStart: turn.start,
            clipEnd: max(turn.end, turn.start + 0.5),
            text: "",
            channel: channel
        )
    }

    private func playbackChannel(for presentation: SpeakerPresentation) -> String {
        switch turn.speaker {
        case .cluster:
            return presentation.channel ?? ""
        case .channel(let label):
            // Kanal-Labels der Live-/Finalläufe: "Ich" = Mikrofonspur.
            return label == "Ich"
                ? MediaAsset.Kind.micTrack.rawValue
                : MediaAsset.Kind.systemTrack.rawValue
        case .person, .importedTextLabel, .none:
            return ""
        }
    }

    private var isPlaying: Bool { model.playingSampleID == turn.start }

    /// Laeuft ein Satz ueber die Blockgrenze, beginnt der naechste Turn mit
    /// dem Satzzeichen des vorigen (". Und dann ..."). Rein kosmetisch: Der
    /// gespeicherte Text bleibt unveraendert, damit Zeitmarken und
    /// Wortbezuege weiter stimmen.
    static func turnText(_ turn: TranscriptTurn) -> String {
        let joined = turn.segments.map(\.text).joined(separator: " ")
        let trimmed = joined.drop { $0.isWhitespace || $0.isPunctuation }
        return trimmed.isEmpty ? joined : String(trimmed)
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        // Ab einer Stunde ist "1:12:45" lesbar, "72:45" nicht mehr.
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
