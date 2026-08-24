import StenoDomain
import StenoTranscription
import SwiftUI

/// Einstellungen "Transcription": Live- und Finalmodell waehlen, Parakeet
/// mit Zustimmung installieren.
///
/// Ein nicht installiertes Modell steht in der Liste, ist aber nicht
/// waehlbar - Falle 4 aus dem Integrationsplan: nichts raten, was der
/// Nutzer als Tatsache liest.
struct TranscriptionModelSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Transcription models") {
                modelPicker("Live transcript", use: .live)
                modelPicker("Final transcript", use: .final)
            }
            Section("Offline model") {
                parakeetRow
            }
            Section("Experimental") {
                Toggle(
                    "Use Parakeet for the live transcript",
                    isOn: Binding(
                        get: { model.transcriptionModels.liveExperimentalEnabled },
                        set: { model.transcriptionModels.setLiveExperimentalEnabled($0) }
                    )
                )
                .disabled(model.isRecording)
                Text("The live transcript is unfinished on this path. It never stops the recording, but it can fall silent or lag. Apple stays the safe choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Choices are pinned with the spoken language when a recording starts. Changing them affects only new recordings and explicit re-transcriptions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
        .task { await model.refreshParakeetReadiness() }
    }

    @ViewBuilder
    private func modelPicker(_ title: String, use: TranscriptionUse) -> some View {
        Picker(title, selection: Binding(
            get: {
                use == .live
                    ? model.transcriptionModels.liveProviderID
                    : model.transcriptionModels.finalProviderID
            },
            set: { id in
                guard model.canChangeTranscriptionModels else { return }
                model.transcriptionModels.select(id, for: use)
            }
        )) {
            ForEach(availableModels(for: use), id: \.id) { descriptor in
                Text(pickerLabel(descriptor, use: use))
                    .tag(descriptor.id)
                    .disabled(selectability(descriptor, use: use) != .selectable)
            }
        }
        .disabled(!model.canChangeTranscriptionModels)
    }

    /// Warum ein Modell hier steht, aber nicht gewaehlt werden kann.
    enum Selectability: Equatable {
        case selectable
        case notInstalled
        case liveNotAvailableYet
    }

    func selectability(
        _ descriptor: TranscriptionModelDescriptor,
        use: TranscriptionUse
    ) -> Selectability {
        if use == .live && descriptor.maturity == .experimental
            && !model.transcriptionModels.liveExperimentalEnabled {
            return .liveNotAvailableYet
        }
        if !model.isTranscriptionModelInstalled(descriptor.id) {
            return .notInstalled
        }
        return .selectable
    }

    private func pickerLabel(
        _ descriptor: TranscriptionModelDescriptor,
        use: TranscriptionUse
    ) -> String {
        switch selectability(descriptor, use: use) {
        case .selectable:
            descriptor.displayName
        case .notInstalled:
            "\(descriptor.displayName) (not installed)"
        case .liveNotAvailableYet:
            "\(descriptor.displayName) (needs the switch below)"
        }
    }

    /// Nur Modelle, die fuer diesen Anwendungsfall und die gespeicherte
    /// Sprache ueberhaupt infrage kommen. Ob sie schon installiert sind,
    /// entscheidet zusaetzlich, ob der Eintrag waehlbar ist - er verschwindet
    /// dafuer nicht aus der Liste.
    private func availableModels(for use: TranscriptionUse) -> [TranscriptionModelDescriptor] {
        model.transcriptionCatalog.descriptors.filter {
            model.transcriptionCatalog.supports(
                $0.id,
                use: use,
                locale: model.transcriptionLocale,
                // Auch das noch gesperrte Live-Modell auflisten: es fehlen zu
                // lassen sieht aus, als gaebe es die Wahl gar nicht. Waehlbar
                // ist es deshalb nicht, `selectability` nennt den Grund.
                experimentalLiveEnabled: true
            )
        }
    }

    @ViewBuilder
    private var parakeetRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FluidAudio Parakeet TDT")
                // Nur solange es noch etwas zu laden gibt. Nach der
                // Installation ist die Downloadgroesse keine Information
                // mehr, sondern Rauschen.
                if model.parakeetReadiness?.isReady(for: model.transcriptionLocale) != true {
                    Text("About 461 MB from huggingface.co")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isInstallingParakeet,
               let action = parakeetInstallAction {
                parakeetInstallActionButton(action)
            } else if model.parakeetReadiness?
                .isReady(for: model.transcriptionLocale) == true {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let action = parakeetInstallAction {
                parakeetInstallActionButton(action)
            }
        }
        if model.isInstallingParakeet {
            parakeetInstallProgress
        }
        if let error = model.modelError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var parakeetInstallAction: MacModelInstallActionPresentation? {
        MacModelInstallActionPresentation.make(
            isReady: model.parakeetReadiness?
                .isReady(for: model.transcriptionLocale) == true,
            isInstallingAny: model.isInstallingModels,
            isActiveInstallation: model.isInstallingParakeet
                && model.showsModelInstallationCancellationAction,
            cancellationState: model.modelInstallationCancellationState,
            installTitle: "Install"
        )
    }

    @ViewBuilder
    private func parakeetInstallActionButton(
        _ action: MacModelInstallActionPresentation
    ) -> some View {
        switch action {
        case .install(let title):
            Button {
                Task { await model.installParakeet() }
            } label: {
                Text(title)
            }
            .disabled(model.isRecording || model.isStartingRecording)
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

    @ViewBuilder
    private var parakeetInstallProgress: some View {
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
}
