import StenoDomain
import SwiftUI

/// Einstellungen "Models": der eine Ort, an dem der Zustimmung zum Nachladen
/// der Modelle erteilt und widerrufen wird.
///
/// Ohne diese Stelle scheiterte Steno auf einem frischen Rechner bei jeder
/// Verarbeitung, weil die Modelle fehlten und es keinen Weg gab, ihrer
/// Installation zuzustimmen.
struct ModelStatusView: View {
    @Environment(AppModel.self) private var model

    private var localeName: String {
        model.localizedLanguageName(model.transcriptionLocale)
    }

    var body: some View {
        Form {
            Section("Models Steno needs") {
                if model.modelBundles.isEmpty {
                    Text("The model list is not available.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.modelBundles, id: \.title) { bundle in
                    bundleRow(bundle)
                }
            }

            Section("Status") {
                statusRow
            }

            Section {
                if model.isInstallingBaselineModels {
                    installProgress
                }
                if let action = installAction {
                    installActionButton(action)
                }
                // Ein gesperrter Knopf ohne Grund laesst raten. Solange die
                // Sprachliste fehlt, steht der Grund darunter; sobald sie da
                // ist, verschwindet der Satz von selbst.
                if !model.hasLoadedLocales {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(AppModel.waitingForLocalesMessage)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(
                    """
                    Without these models Steno cannot transcribe at all. \
                    Speech models come from Apple, speaker separation from huggingface.co. \
                    Revoking stops future downloads; models already installed keep working.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = model.modelError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let record = model.modelConsent.record {
                Section("Your consent") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Granted on \(Self.dateText(record.grantedAt))")
                        Text(record.sources.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Revoke", role: .destructive) {
                        Task { await model.revokeModelConsent() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 360)
        .task { await model.refreshModelReadiness() }
    }

    @ViewBuilder
    private func bundleRow(_ bundle: ModelBundleDescription) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.title).font(.body.weight(.medium))
                Text(bundle.source.displayHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.sizeText(bundle.approximateBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusRow: some View {
        if let readiness = model.modelReadiness {
            if readiness.isReady(for: model.transcriptionLocale) {
                if model.lastCheckFoundWrongBytes {
                    // Kein gruener Haken neben einer roten Meldung. Die
                    // Dateien sind vollstaendig da - `readiness` prueft nur
                    // das - aber ihre Bytes stimmen nicht. Nur dieser Fall
                    // nimmt die Bereitschaft zurueck, kein Netzfehler.
                    VStack(alignment: .leading, spacing: 2) {
                        Label(
                            "Installed, but not confirmed for \(localeName).",
                            systemImage: "exclamationmark.triangle"
                        )
                        Text("The last check found bytes that do not match what you approved. The detail is below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Ready for \(localeName).", systemImage: "checkmark.circle")
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Not ready for \(localeName).", systemImage: "exclamationmark.circle")
                    let missing = readiness.missingNames(for: model.transcriptionLocale)
                    if !missing.isEmpty {
                        // Bundletitel, dieselben Namen wie in der Liste
                        // oben. Dateinamen gehoeren nicht in die Oberflaeche.
                        Text("Still to download: \(missing.joined(separator: ", ")).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("Checking \u{2026}").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installProgress: some View {
        switch model.modelInstallProgressPresentation {
        case .indeterminate(let title):
            ProgressView {
                Text(title)
            }
        case .determinate(let title, let fraction):
            ProgressView(value: fraction, total: 1) {
                Text(title)
            } currentValueLabel: {
                Text("\(Int((fraction * 100).rounded())) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case nil:
            EmptyView()
        }
    }

    private var installAction: MacModelInstallActionPresentation? {
        let isReady = model.modelReadiness?
            .isReady(for: model.transcriptionLocale) == true
            && !model.lastCheckFoundWrongBytes
        return MacModelInstallActionPresentation.make(
            isReady: isReady,
            isInstallingAny: model.isInstallingModels,
            isActiveInstallation: model.isInstallingBaselineModels
                && model.showsModelInstallationCancellationAction,
            cancellationState: model.modelInstallationCancellationState,
            installTitle: "Allow and install"
        )
    }

    @ViewBuilder
    private func installActionButton(
        _ action: MacModelInstallActionPresentation
    ) -> some View {
        switch action {
        case .install(let title):
            Button {
                Task { await model.allowAndInstallModels() }
            } label: {
                Text(title)
            }
            .disabled(model.modelBundles.isEmpty || !model.hasLoadedLocales)
        case .cancel(let title):
            Button {
                Task { await model.cancelModelInstallation() }
            } label: {
                Text(title)
            }
        case .cancelling(let title):
            Button {} label: {
                Text(title)
            }
            .disabled(true)
        }
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
