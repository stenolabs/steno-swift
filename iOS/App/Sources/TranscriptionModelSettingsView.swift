import StenoDomain
import StenoTranscription
import SwiftUI

/// Live- und Finalmodell waehlen, Parakeet mit Zustimmung installieren.
///
/// Ein nicht installiertes Modell steht in der Liste, ist aber nicht
/// waehlbar - Falle 4 aus dem Integrationsplan: nichts raten, was der
/// Nutzer als Tatsache liest.
struct TranscriptionModelSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section("Transcription") {
                picker("Live transcript", use: .live)
                picker("Final transcript", use: .final)
            }
            Section("Offline model") {
                parakeetRow
            }
            Section("Experimental") {
                Toggle(
                    "Use Parakeet for the live transcript",
                    isOn: Binding(
                        get: { app.transcriptionModels.liveExperimentalEnabled },
                        set: { app.transcriptionModels.setLiveExperimentalEnabled($0) }
                    )
                )
                .disabled(app.recording.isActive)
                Text("The live transcript is unfinished on this path. It never stops the recording, but it can fall silent or lag. Apple stays the safe choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Choices are pinned with the spoken language when a recording starts. Apple is available without an additional large download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Transcription models")
        .task { await app.transcriptionModelInstaller.refresh(for: app.language.locale) }
    }

    @ViewBuilder
    private func picker(_ title: String, use: TranscriptionUse) -> some View {
        Picker(title, selection: Binding(
            get: {
                use == .live
                    ? app.transcriptionModels.liveProviderID
                    : app.transcriptionModels.finalProviderID
            },
            set: { id in
                guard app.canChangeTranscriptionModels else { return }
                app.transcriptionModels.select(id, for: use)
            }
        )) {
            ForEach(availableModels(for: use), id: \.id) { descriptor in
                Text(pickerLabel(descriptor, use: use))
                    .tag(descriptor.id)
                    .disabled(selectability(descriptor, use: use) != .selectable)
            }
        }
        .disabled(!app.canChangeTranscriptionModels)
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
            && !app.transcriptionModels.liveExperimentalEnabled {
            return .liveNotAvailableYet
        }
        if !app.isTranscriptionModelInstalled(descriptor.id) {
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
        app.transcriptionCatalog.descriptors.filter {
            app.transcriptionCatalog.supports(
                $0.id,
                use: use,
                locale: app.language.locale,
                // Auch das noch gesperrte Live-Modell auflisten: es fehlen zu
                // lassen sieht aus, als gaebe es die Wahl gar nicht. Waehlbar
                // ist es deshalb nicht, `selectability` nennt den Grund.
                experimentalLiveEnabled: true
            )
        }
    }

    private var parakeetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FluidAudio Parakeet TDT")
                Spacer()
                if app.transcriptionModelInstaller.isReady(for: app.language.locale) == true {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if app.transcriptionModelInstaller.installProgressPresentation == nil {
                    Button("Install") {
                        Task {
                            _ = await app.transcriptionModelInstaller.allowAndInstall(
                                for: app.language.locale,
                                recordingIsActive: app.recording.isActive
                            )
                        }
                    }
                    .disabled(app.recording.isActive)
                }
            }

            // Nur solange es noch etwas zu laden gibt. Nach der Installation
            // ist die Downloadgroesse keine Information mehr, sondern Rauschen.
            if app.transcriptionModelInstaller.isReady(for: app.language.locale) != true {
                Text("About 461 MB from huggingface.co")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let presentation = app.transcriptionModelInstaller.installProgressPresentation {
                IOSModelInstallationProgressView(
                    presentation: presentation,
                    isCancelling: app.transcriptionModelInstaller.isCancelling
                ) {
                    Task { await app.transcriptionModelInstaller.cancelInstall() }
                }
            }

            if let error = app.transcriptionModelInstaller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
