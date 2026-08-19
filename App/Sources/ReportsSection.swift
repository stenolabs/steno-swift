import AppKit
import StenoDomain
import StenoIntelligence
import StenoPipeline
import SwiftUI

/// Protokoll-Bereich im Meeting-Detail: Vorlage rendern lassen, Ergebnis
/// lesen und kopieren, ältere Ergebnisse abrufen. Läuft nur auf explizite
/// Anforderung; ohne verfügbares Modell erklärt der Bereich den Zustand.
struct ReportsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(TextModelSettings.self) private var textModelSettings
    let meetingID: MeetingID
    /// Fuer den Hinweis, wie viele Sprecher noch unbestaetigt sind.
    let review: MeetingReviewData?

    @State private var reports: [StoredTemplateResult] = []
    @State private var selectedRunID: RunID?
    @State private var renderPending = false
    @State private var renderError: String?
    @State private var pendingJobID: JobID?
    @State private var pendingEndpointID: String?
    @State private var pendingEndpointSnapshot: TextModelEndpointSnapshot?
    @State private var selectedEndpointSnapshot: TextModelEndpointSnapshot?
    @State private var preflight: TemplateRenderPreflight?
    @State private var preflightIsReady = false
    @State private var preflightError: String?

    /// Nur der On-Device-Standard hat eine Vorab-Verfügbarkeitsauskunft;
    /// externe Endpunkte werden erst beim Rendern kontaktiert (nie vorab).
    private var availabilityHint: String? {
        guard !endpointDisplay.usesExternalEndpoint else { return nil }
        return FoundationModelsProvider().availability.unavailabilityMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Minutes")
                    .font(.headline)
                Spacer()
                if renderPending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(ReportsPendingJobObservation.statusLabel(for: endpointDisplay))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let pendingJobID {
                            Button("Cancel") {
                                Task { await model.cancelJob(pendingJobID) }
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    modelPicker
                    Button {
                        Task { await startRender() }
                    } label: {
                        Label(
                            reports.isEmpty
                                ? "Generate minutes"
                                : "Regenerate",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                    .disabled(
                        availabilityHint != nil
                            || !preflightIsReady
                            || externalModelNoticeError != nil
                    )
                }
            }
            if let notice = externalModelNotice {
                Label(
                    notice.text,
                    systemImage: "arrow.up.forward.circle"
                )
                .font(.callout)
                .foregroundStyle(notice.isPlaintext ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let externalModelNoticeError {
                Label(externalModelNoticeError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Steno.Colors.error)
            }
            if let availabilityHint {
                Label(
                    "\(availabilityHint) Transcript and speakers remain fully usable without a model.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if let unconfirmed = unconfirmedSpeakerHint {
                Label(unconfirmed, systemImage: "person.fill.questionmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let renderError {
                Label(renderError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Steno.Colors.error)
            }
            if let preflightError {
                HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                    Label(preflightError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Steno.Colors.error)
                    Spacer()
                    Button("Try Again") {
                        Task { await refreshPreflight() }
                    }
                    .controlSize(.small)
                }
            }
            if let shown = shownReport {
                reportView(shown)
            }
        }
        .task(id: meetingID) {
            selectedEndpointSnapshot = textModelSettings.selectedEndpoint?.snapshot
            await refreshPreflight()
            await refreshLoop()
        }
    }

    /// Modellwahl je Erstellung; extern nur nach ausdrücklicher Wahl,
    /// die Auswahl wird gemerkt, aber nie automatisch auf extern gestellt.
    private var modelPicker: some View {
        Picker("Model", selection: selectedEndpointID) {
            Text("Apple Intelligence (on device)").tag(UUID?.none)
            ForEach(textModelSettings.endpoints, id: \.id) { endpoint in
                Text("\(endpoint.name) (external)").tag(UUID?.some(endpoint.id))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var selectedEndpointID: Binding<UUID?> {
        Binding(
            get: { selectedEndpointSnapshot?.id },
            set: { endpointID in
                selectedEndpointSnapshot = endpointID.flatMap { selectedID in
                    textModelSettings.endpoints.first { $0.id == selectedID }?.snapshot
                }
                textModelSettings.selectedEndpointID = endpointID
            }
        )
    }

    private var externalModelNotice: ExternalModelNotice? {
        guard let snapshot = endpointDisplay.endpointSnapshot,
              let preflight
        else { return nil }
        return try? ReportsDisclosurePresentation.externalNotice(
            endpoint: TextModelEndpoint(snapshot: snapshot),
            preflight: preflight
        )
    }

    private var externalModelNoticeError: String? {
        if case .unavailableExternal = endpointDisplay {
            return "The selected text-model endpoint is no longer available."
        }
        guard let snapshot = endpointDisplay.endpointSnapshot,
              let preflight else { return nil }
        do {
            _ = try ReportsDisclosurePresentation.externalNotice(
                endpoint: TextModelEndpoint(snapshot: snapshot),
                preflight: preflight
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var endpointDisplay: ReportTextModelDisplay {
        ReportTextModelDisplay.resolve(
            isPending: renderPending,
            pendingEndpointID: pendingEndpointID,
            pendingEndpointSnapshot: pendingEndpointSnapshot,
            selectedEndpointSnapshot: selectedEndpointSnapshot,
            configuredEndpoints: textModelSettings.endpoints
        )
    }

    /// Ein Protokoll aus unbestaetigten Sprechern nennt sie "Speaker 1".
    /// Das ist ein legitimer Wunsch, aber es soll niemand erst am Ergebnis
    /// merken - ein vollstaendiger Modelllauf ist zu teuer dafuer.
    private var unconfirmedSpeakerHint: String? {
        guard let review else { return nil }
        let nameable = review.clusters.filter {
            !$0.isSelf && !$0.containsMultipleSpeakers
        }
        guard !nameable.isEmpty else { return nil }
        let open = nameable.filter {
            if case .confirmed = $0.reviewState { return false }
            return true
        }
        guard !open.isEmpty else { return nil }
        return "\(open.count) of \(nameable.count) speakers are still unconfirmed; the minutes will call them \u{201C}Speaker 1\u{201D} and so on."
    }

    private var shownReport: StoredTemplateResult? {
        selectedRunID.flatMap { id in reports.first { $0.runID == id } }
            ?? reports.first
    }

    @ViewBuilder
    private func reportView(_ stored: StoredTemplateResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(stored.result.createdAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(engineLabel(stored.result.engine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if reports.count > 1 {
                    Menu("Earlier versions") {
                        ForEach(reports, id: \.runID) { report in
                            Button {
                                selectedRunID = report.runID
                            } label: {
                                Text(
                                    report.result.createdAt
                                        .formatted(.dateTime.day().month().hour().minute().second())
                                    + "  ·  "
                                    + engineLabel(report.result.engine)
                                )
                            }
                        }
                    }
                    .font(.caption)
                    .fixedSize()
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        stored.result.markdown,
                        forType: .string
                    )
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            MarkdownLiteView(markdown: stored.result.markdown)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func engineLabel(_ engine: EngineDescriptor) -> String {
        if let modelVersion = engine.modelVersion {
            return "\(engine.name) · \(modelVersion)"
        }
        return engine.name
    }

    private func startRender() async {
        guard let preflight else { return }
        renderError = nil
        do {
            let endpoint = selectedEndpointSnapshot
            let job = try await model.requestMeetingMinutes(
                meetingID: meetingID,
                textModelEndpointID: endpoint?.id.uuidString,
                textModelEndpointSnapshot: endpoint,
                preflight: preflight
            )
            pendingJobID = job.id
            pendingEndpointID = job.textModelEndpointID
            pendingEndpointSnapshot = job.textModelEndpointSnapshot
            renderPending = true
            await refreshLoop()
        } catch {
            renderError = AppModel.message("The minutes could not be started.", error)
            await refreshPreflight()
        }
    }

    private func refreshPreflight() async {
        preflightIsReady = false
        preflightError = nil
        do {
            preflight = try await model.reportPreflight(for: meetingID)
            preflightIsReady = true
        } catch {
            preflight = nil
            preflightError = error.localizedDescription
        }
    }

    /// Läuft, solange ein Render-Job offen ist, und einmalig beim Erscheinen.
    /// Laufende Fehler werden exakt dem beobachteten Job zugeordnet; beim
    /// ersten Snapshot erscheint höchstens der neueste unbeobachtete Pin-Fehler.
    private func refreshLoop() async {
        let shouldObserveColdFailure = pendingJobID == nil
        var isFirstSnapshot = true
        while !Task.isCancelled {
            let snapshot = await ReportsRefreshSnapshot.load(
                pendingJobID: pendingJobID,
                reports: { await model.reports(for: meetingID) },
                jobs: { await model.jobs(for: meetingID) }
            )
            reports = snapshot.reports
            let jobs = snapshot.jobs
            let activeJobs = jobs.filter {
                $0.kind == .templateRender
                    && ($0.status == .queued || $0.status == .running)
            }
            if pendingJobID == nil, let active = activeJobs.first {
                pendingJobID = active.id
                pendingEndpointID = active.textModelEndpointID
                pendingEndpointSnapshot = active.textModelEndpointSnapshot
            }
            if let jobID = pendingJobID,
               let job = jobs.first(where: { $0.id == jobID })
            {
                switch job.status {
                case .failed:
                    await ReportsPendingJobObservation.refreshPreflightIfNeeded(for: job) {
                        await refreshPreflight()
                    }
                    renderError = job.errorMessage
                    pendingJobID = nil
                    pendingEndpointID = nil
                    pendingEndpointSnapshot = nil
                case .finished:
                    renderError = nil
                    pendingJobID = nil
                    pendingEndpointID = nil
                    pendingEndpointSnapshot = nil
                case .cancelled:
                    pendingJobID = nil
                    pendingEndpointID = nil
                    pendingEndpointSnapshot = nil
                case .queued, .running:
                    break
                }
            }
            if pendingJobID == nil, let active = activeJobs.first {
                pendingJobID = active.id
                pendingEndpointID = active.textModelEndpointID
                pendingEndpointSnapshot = active.textModelEndpointSnapshot
            }
            if isFirstSnapshot,
               shouldObserveColdFailure,
               pendingJobID == nil,
               let message = await ReportsPendingJobObservation.observeColdPinsFailure(
                   in: jobs,
                   ledger: .process,
                   refreshPreflight: { await refreshPreflight() }
               ) {
                renderError = message
            }
            isFirstSnapshot = false
            renderPending = pendingJobID != nil
            if !renderPending { break }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

enum ReportsPendingJobObservation {
    static func statusLabel(for endpoint: ReportTextModelDisplay) -> String {
        "Generating with \(endpoint.modelLabel)…"
    }

    @MainActor
    static func refreshPreflightIfNeeded(
        for job: Job,
        refreshPreflight: () async -> Void
    ) async {
        guard job.status == .failed,
              job.failureReason == .templateRenderInputChanged
                || job.failureReason == .templateRenderPinsRequired
        else { return }
        await refreshPreflight()
    }

    @MainActor
    static func observeColdPinsFailure(
        in jobs: [Job],
        ledger: TemplateRenderPinsFailureObservationLedger,
        refreshPreflight: () async -> Void
    ) async -> String? {
        guard let failed = ledger.claimLatestFailure(in: jobs) else { return nil }
        await refreshPreflight()
        return failed.errorMessage
            ?? "Generate the minutes again to confirm the current inputs."
    }
}

struct ReportsRefreshSnapshot: Equatable {
    let reports: [StoredTemplateResult]
    let jobs: [Job]

    @MainActor
    static func load(
        pendingJobID _: JobID?,
        reports loadReports: () async -> [StoredTemplateResult],
        jobs loadJobs: () async -> [Job]
    ) async -> ReportsRefreshSnapshot {
        let jobs = await loadJobs()
        let reports = await loadReports()
        return ReportsRefreshSnapshot(reports: reports, jobs: jobs)
    }
}

enum ReportsDisclosurePresentation {
    static func externalNotice(
        endpoint: TextModelEndpoint,
        preflight: TemplateRenderPreflight
    ) throws -> ExternalModelNotice {
        try externalNotice(endpoint: endpoint, disclosure: preflight.disclosure)
    }

    static func externalNotice(
        endpoint: TextModelEndpoint,
        disclosure: OutboundDisclosure
    ) throws -> ExternalModelNotice {
        try ExternalModelNotice(
            endpoint: endpoint,
            disclosure: disclosure,
            localDeviceDescription: "this Mac"
        )
    }
}

/// Minimaler Markdown-Renderer für die Protokollanzeige: Überschriften,
/// Aufzählungen, Absätze. Bewusst kein vollwertiges Markdown.
struct MarkdownLiteView: View {
    let markdown: String

    /// Lesbare Protokollschrift; die 13-pt-Systemgröße war im Einsatz zu klein.
    /// Transkript und Protokoll teilen sich die Größe über das Token.
    private static let bodyFont = Steno.readingBody

    private enum Block: Hashable {
        case heading(String)
        case subheading(String)
        case bullet(String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(.title3.weight(.semibold))
                        .padding(.top, 4)
                case .subheading(let text):
                    Text(text)
                        .font(.headline)
                        .padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(text))
                    }
                    .font(Self.bodyFont)
                case .paragraph(let text):
                    Text(inline(text))
                        .font(Self.bodyFont)
                        .lineSpacing(3)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Aufeinanderfolgende Textzeilen bilden einen Absatz; Leerzeilen
    /// trennen Absätze. So bleiben Absätze auch dann sichtbar, wenn das
    /// Modell sie nur durch Zeilenumbrüche markiert.
    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                flushParagraph()
                result.append(.subheading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                result.append(.heading(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                result.append(.bullet(String(line.dropFirst(2))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return result
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
