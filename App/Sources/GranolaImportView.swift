import Observation
import StenoExchange
import StenoLibrary
import SwiftUI
import UniformTypeIdentifiers

/// Import of a Granola JSON export: pick the file, review the preview,
/// start deliberately. The export is only ever read. Repeated imports skip
/// meetings already present via the `granola:<noteId>` provenance keys.
@MainActor
@Observable
final class GranolaImportModel {
    typealias ImportOperation = @Sendable (
        GranolaImporter,
        URL,
        @escaping @Sendable (GranolaImportProgress) -> Void
    ) async throws -> GranolaImportOutcome

    enum Phase: Equatable {
        case idle
        case scanning
        case scanned(GranolaParseResult)
        case importing(completed: Int, total: Int, title: String)
        case finished(GranolaImportReport)
        case cancelled(GranolaImportReport)
        case failed(String)
    }

    private enum ImportCompletion: Sendable {
        case outcome(GranolaImportOutcome)
        case failed(String)
    }

    /// Changing the source discards the preview immediately: otherwise the
    /// window would show the old file's numbers while importing the new one.
    var fileURL: URL? {
        didSet {
            guard fileURL != oldValue, !isBusy else { return }
            phase = .idle
        }
    }

    private(set) var phase: Phase = .idle
    private let importOperation: ImportOperation
    private var importTask: Task<ImportCompletion, Never>?
    private var importID: UUID?

    init(
        importOperation: @escaping ImportOperation = { importer, url, progress in
            try await importer.performImport(from: url, progress: progress)
        }
    ) {
        self.importOperation = importOperation
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .importing: true
        default: false
        }
    }

    func scan() async {
        guard !isBusy else { return }
        guard let url = fileURL else { return }
        phase = .scanning
        do {
            let result = try await Task.detached {
                try GranolaDocument.read(from: url)
            }.value
            phase = .scanned(result)
        } catch {
            phase = .failed("The export file could not be read: \(error.localizedDescription)")
        }
    }

    func runImport(library: Library) async {
        // Guards against a second click before the first task ran: no await
        // has happened up to this point.
        guard !isBusy, let url = fileURL else { return }
        phase = .importing(completed: 0, total: 0, title: "")
        let id = UUID()
        let importer = GranolaImporter(library: library)
        let importOperation = self.importOperation
        let progressHandler: @Sendable (GranolaImportProgress) -> Void = {
            [weak self, id] progress in
            Task { @MainActor [weak self, id] in
                guard let self,
                      self.importID == id,
                      case .importing = self.phase else { return }
                self.phase = .importing(
                    completed: progress.completed,
                    total: progress.total,
                    title: progress.title
                )
            }
        }
        let task = Task<ImportCompletion, Never> {
            do {
                return ImportCompletion.outcome(
                    try await importOperation(importer, url, progressHandler)
                )
            } catch {
                return ImportCompletion.failed(
                    "The import failed: \(error.localizedDescription)"
                )
            }
        }
        importID = id
        importTask = task
        let completion = await task.value
        guard importID == id else { return }
        importID = nil
        importTask = nil
        switch completion {
        case .outcome(.finished(let report)):
            phase = .finished(report)
        case .outcome(.cancelled(let report)):
            phase = .cancelled(report)
        case .failed(let message):
            phase = .failed(message)
        }
    }

    @discardableResult
    func cancelImport() -> Bool {
        guard let importTask, case .importing = phase else { return false }
        // The import drains after the current safe step and then reports
        // `cancelled`; only the cancellation signal is set here.
        importTask.cancel()
        return true
    }
}

struct GranolaImportView: View {
    @Environment(AppModel.self) private var model
    @State private var importModel = GranolaImportModel()
    @State private var showFilePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            sourceRow
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json]
        ) { result in
            if case .success(let url) = result {
                importModel.fileURL = url
                Task { await importModel.scan() }
            }
        }
        .interactiveDismissDisabled(importModel.isBusy)
        .windowDismissBehavior(importModel.isBusy ? .disabled : .automatic)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import from Granola")
                .font(.title3.weight(.semibold))
            Text("Titles, dates, participants, summaries and transcripts are imported into fresh meetings. Running the same export again skips meetings that are already present.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export file").font(.caption).foregroundStyle(.secondary)
                Text(
                    importModel.fileURL?
                        .path(percentEncoded: false)
                        ?? "No file selected"
                )
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            }
            Spacer()
            Button("Choose file…") { showFilePicker = true }
                .disabled(importModel.isBusy)
            if importModel.fileURL != nil {
                Button("Scan again") {
                    Task { await importModel.scan() }
                }
                .disabled(importModel.isBusy)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch importModel.phase {
        case .idle:
            Label(
                "Choose a Granola JSON export to preview what will be imported.",
                systemImage: "doc.text"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading export file…").foregroundStyle(.secondary)
            }
        case .scanned(let result):
            scanSummary(result)
        case .importing(let completed, let total, let title):
            VStack(alignment: .leading, spacing: 8) {
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                    Text("\(completed) of \(total): \(title)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    ProgressView()
                }
            }
        case .cancelled(let report):
            reportSummary(
                report,
                title: "Import cancelled",
                systemImage: "xmark.circle",
                explanation: "Meetings listed below were already imported and were not rolled back. Run the import again to add the remaining meetings."
            )
        case .finished(let report):
            reportSummary(
                report,
                title: "Import complete",
                systemImage: "checkmark.circle",
                explanation: nil
            )
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Steno.Colors.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scanSummary(_ result: GranolaParseResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Found").font(.headline)
            row("Meetings in export", "\(result.notes.count)")
            row("With transcript", "\(result.notes.filter { !$0.transcript.isEmpty }.count)")
            row("Without summary", "\(result.notes.filter { $0.summary.isEmpty }.count)")
            row("Without readable date", "\(result.notes.filter { $0.date == nil }.count)")
            if result.skippedCount > 0 {
                row("Invalid entries (skipped)", "\(result.skippedCount)")
            }
            if result.notes.isEmpty {
                Label(
                    "This export contains no importable meetings.",
                    systemImage: "questionmark.folder"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func reportSummary(
        _ report: GranolaImportReport,
        title: LocalizedStringKey,
        systemImage: String,
        explanation: LocalizedStringKey?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            if let explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row("New meetings", "\(report.meetingsCreated)")
            row("Notes written", "\(report.notesCreated)")
            row("People added", "\(report.peopleCreated)")
            if !report.duplicates.isEmpty {
                row("Already present (skipped)", "\(report.duplicates.count)")
            }
            if !report.warnings.isEmpty {
                DisclosureGroup("\(report.warnings.count) notices") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch importModel.phase {
            case .scanned(let result):
                Button("Import") {
                    Task {
                        if let library = model.runtime?.library {
                            await importModel.runImport(library: library)
                            await model.refreshMeetings()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result.notes.isEmpty || model.runtime == nil)
            case .importing:
                Button("Cancel") {
                    importModel.cancelImport()
                }
            case .finished, .cancelled:
                Button("Scan again") {
                    Task { await importModel.scan() }
                }
            default:
                EmptyView()
            }
        }
    }
}
