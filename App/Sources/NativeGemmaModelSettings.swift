#if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
import Foundation
import Observation
import StenoDomain
import StenoGemmaClient
import StenoGemmaIPC
import StenoPipeline
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class NativeGemmaModelSettings {
    private static let selectionKey = "steno.nativeGemma.selection"
    private let defaults: UserDefaults

    private(set) var selectedSnapshot: NativeGemmaModelSnapshot?
    private(set) var isImporting = false
    private(set) var isCheckingInstallation = false
    private(set) var isInstalled = false
    private(set) var errorMessage: String?
    private var hasCheckedInstallation = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.selectionKey),
           let decoded = try? JSONDecoder().decode(
                NativeGemmaModelSnapshot.self,
                from: data
           ),
           decoded == NativeGemmaProviderCatalog.gemma4E2BSnapshot
        {
            selectedSnapshot = decoded
        }
    }

    var displayName: String { "Gemma 4 E2B (4-bit)" }

    func refreshInstalled(force: Bool = false) async {
        guard force || !hasCheckedInstallation else { return }
        guard !isCheckingInstallation else { return }
        isCheckingInstallation = true
        defer {
            isCheckingInstallation = false
            hasCheckedInstallation = true
        }
        let snapshot = NativeGemmaProviderCatalog.gemma4E2BSnapshot
        guard let modelPin = try? GemmaModelSnapshotPin(
            modelIdentifier: snapshot.modelIdentifier,
            checkpointRevision: snapshot.checkpointRevision,
            adapterRevision: snapshot.adapterRevision,
            licenseIdentifier: snapshot.licenseIdentifier,
            manifestSHA256: snapshot.manifestSHA256
        ) else {
            isInstalled = false
            return
        }
        isInstalled = await Task.detached(priority: .utility) {
            (try? NativeGemmaModelStoreAdapter.productionInstalledModelDirectory(
                for: modelPin
            )) != nil
        }.value
    }

    func importFolder(_ sourceRoot: URL) async {
        guard !isImporting else { return }
        guard let pin = ApprovedNativeGemmaModelCatalog.productionPin else {
            errorMessage = "This Steno build has no valid approved Gemma checkpoint."
            return
        }
        let hasSecurityScopedAccess = sourceRoot.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                sourceRoot.stopAccessingSecurityScopedResource()
            }
        }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            let coordinator = try ModelInstallationCoordinator.standard()
            let facade = NativeGemmaModelImportFacade(
                installationCoordinator: coordinator
            )
            let snapshot = try await facade.importModel(
                pin: pin,
                sourceRoot: sourceRoot,
                consentGranted: true
            )
            selectedSnapshot = snapshot
            defaults.set(
                try JSONEncoder().encode(snapshot),
                forKey: Self.selectionKey
            )
            await refreshInstalled(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectInstalled() {
        guard isInstalled else { return }
        selectedSnapshot = NativeGemmaProviderCatalog.gemma4E2BSnapshot
        if let data = try? JSONEncoder().encode(selectedSnapshot) {
            defaults.set(data, forKey: Self.selectionKey)
        }
    }

    func deselect() {
        selectedSnapshot = nil
        defaults.removeObject(forKey: Self.selectionKey)
    }
}

struct NativeGemmaModelSettingsView: View {
    @Environment(NativeGemmaModelSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @State private var showingImporter = false
    @State private var pendingImportURL: URL?

    var body: some View {
        Section("Native Gemma") {
            Text("Gemma 4 E2B runs locally through the isolated MLX helper. No Ollama or network access is used.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("Checkpoint", value: settings.displayName)
            LabeledContent("Download size", value: "3.34 GiB")
            LabeledContent("License", value: "Conversion: gemma · Base: Apache-2.0")
            Text("The conversion repository and its Google base-model card use different license identifiers. Review both before importing; Steno records the conservative “gemma” identifier.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Link(
                    "Conversion model card",
                    destination: URL(string: "https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/tree/238767527555cb75a05732a84dff5d6ba0dd6809")!
                )
                Link(
                    "Google base-model card",
                    destination: URL(string: "https://huggingface.co/google/gemma-4-E2B-it/tree/70af34e20bd4b7a91f0de6b22675850c43922a03")!
                )
            }
            .font(.caption)
            if settings.isCheckingInstallation {
                ProgressView("Checking installed checkpoint…")
            } else if settings.isInstalled {
                Label("Verified and installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if settings.selectedSnapshot != nil {
                    Label("Selected for minutes", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use for minutes") { settings.selectInstalled() }
                }
            } else {
                Text("Choose the prepared checkpoint folder containing the seven runtime files and gemma-model-manifest.json. Steno does not download models here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose local checkpoint folder…") { showingImporter = true }
                    .disabled(settings.isImporting || model.isRecording)
            }
            if settings.isImporting { ProgressView("Verifying and importing…") }
            if let error = settings.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await settings.refreshInstalled() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            pendingImportURL = url
        }
        .alert(
            "Import Gemma 4 E2B?",
            isPresented: Binding(
                get: { pendingImportURL != nil },
                set: { if !$0 { pendingImportURL = nil } }
            )
        ) {
            Button("Import and verify") {
                guard let url = pendingImportURL else { return }
                pendingImportURL = nil
                Task { await settings.importFolder(url) }
            }
            Button("Cancel", role: .cancel) { pendingImportURL = nil }
        } message: {
            Text("Steno will verify the exact 3.34 GiB checkpoint, its immutable revision, manifest, and checksums, then copy it into Steno’s local model store. The model remains on this Mac and runs without Ollama or network access.")
        }
    }
}
#endif
