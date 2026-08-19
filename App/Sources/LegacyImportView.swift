import Observation
import StenoExchange
import StenoLibrary
import SwiftUI

/// Import aus der alten Steno-App: Quelle wählen, Vorschau ansehen,
/// bewusst starten. Die alte Installation wird ausschließlich gelesen.
@MainActor
@Observable
final class LegacyImportModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case scanned(LegacyStoreSnapshot)
        case importing(completed: Int, total: Int, stem: String)
        case finished(ImportReport)
        case failed(String)
    }

    /// Ein Quellwechsel verwirft die Vorschau sofort: Sonst zeigte das
    /// Fenster die Zahlen des alten Ordners, importiert würde aber der neue.
    var sourceURL: URL = URL(
        fileURLWithPath: NSHomeDirectory()
    )
    .appending(path: "Library/Application Support/stenoai", directoryHint: .isDirectory) {
        didSet {
            guard sourceURL != oldValue, !isBusy else { return }
            phase = .idle
        }
    }

    private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .scanning, .importing: true
        default: false
        }
    }

    func scan() async {
        phase = .scanning
        let url = sourceURL
        do {
            let snapshot = try await Task.detached {
                try LegacyStore(rootURL: url).scan()
            }.value
            phase = .scanned(snapshot)
        } catch {
            phase = .failed("The folder could not be read: \(error.localizedDescription)")
        }
    }

    func runImport(library: Library, folders: FolderStore) async {
        // Schützt gegen einen zweiten Klick, bevor der erste Task lief:
        // bis hierher hat noch kein await stattgefunden.
        guard !isBusy else { return }
        phase = .importing(completed: 0, total: 0, stem: "")
        let url = sourceURL
        do {
            let report = try await LegacyImporter(
                sourceRoot: url,
                library: library,
                folders: folders
            ).performImport { [weak self] progress in
                Task { @MainActor in
                    // Verspätete Fortschrittsmeldungen dürfen ein bereits
                    // erreichtes Ergebnis - besonders einen Fehler - nicht
                    // wieder überschreiben.
                    guard let self, case .importing = self.phase else { return }
                    self.phase = .importing(
                        completed: progress.completed,
                        total: progress.total,
                        stem: progress.stem
                    )
                }
            }
            phase = .finished(report)
        } catch {
            phase = .failed("The import failed: \(error.localizedDescription)")
        }
    }
}

struct LegacyImportView: View {
    @Environment(AppModel.self) private var model
    @State private var importModel = LegacyImportModel()
    @State private var showFolderPicker = false

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
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                importModel.sourceURL = url
            }
        }
        .task { await importModel.scan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import from Legacy Steno App")
                .font(.title3.weight(.semibold))
            Text("Meetings, transcripts, speaker profiles and minutes are copied. The legacy installation stays unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Source").font(.caption).foregroundStyle(.secondary)
                Text(importModel.sourceURL.path(percentEncoded: false))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button("Choose folder…") { showFolderPicker = true }
                .disabled(importModel.isBusy)
            Button("Scan again") {
                Task { await importModel.scan() }
            }
            .disabled(importModel.isBusy)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch importModel.phase {
        case .idle, .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning folder…").foregroundStyle(.secondary)
            }
        case .scanned(let snapshot):
            scanSummary(snapshot)
        case .importing(let completed, let total, let stem):
            VStack(alignment: .leading, spacing: 8) {
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                    Text("\(completed) of \(total): \(stem)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    ProgressView()
                }
            }
        case .finished(let report):
            reportSummary(report)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Steno.Colors.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scanSummary(_ snapshot: LegacyStoreSnapshot) -> some View {
        let importable = snapshot.entries.filter {
            $0.summary != nil && $0.transcript != nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Found").font(.headline)
            row("Importable meetings", "\(importable.count)")
            row("With audio", "\(importable.filter { !$0.recordings.isEmpty }.count)")
            row("With speaker data", "\(importable.filter { $0.speakers != nil }.count)")
            if !snapshot.orphans.isEmpty {
                row("Incomplete (skipped)", "\(snapshot.orphans.count)")
            }
            if !snapshot.pendingDeleteFiles.isEmpty {
                Label(
                    "\(snapshot.pendingDeleteFiles.count) file(s) are in the legacy app\u{2019}s delete queue and will not be imported.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if importable.isEmpty {
                Label(
                    "This folder contains no importable meetings.",
                    systemImage: "questionmark.folder"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func reportSummary(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Import complete", systemImage: "checkmark.circle")
                .font(.headline)
            row("New meetings", "\(report.meetingsCreated)")
            row("Audio files copied", "\(report.audioCopied)")
            if report.audioRepaired > 0 {
                row("Audio repaired (WebM to CAF)", "\(report.audioRepaired)")
            }
            if report.audioMissing > 0 {
                row("Meetings without audio", "\(report.audioMissing)")
            }
            row("Speaker clusters", "\(report.clustersCreated)")
            row("People", "\(report.personsCreated) (\(report.prototypesCreated) voice prints)")
            row("Minutes", "\(report.reportsCreated)")
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
            case .scanned(let snapshot):
                let importable = snapshot.entries.filter {
                    $0.summary != nil && $0.transcript != nil
                }
                Button("Import") {
                    Task {
                        if let library = model.runtime?.library,
                           let folders = model.folderStore
                        {
                            await importModel.runImport(
                                library: library,
                                folders: folders
                            )
                            await model.refreshMeetings()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    importable.isEmpty
                        || model.runtime == nil
                        || model.folderStore == nil
                )
            case .finished:
                Button("Scan again") {
                    Task { await importModel.scan() }
                }
            default:
                EmptyView()
            }
        }
    }
}
