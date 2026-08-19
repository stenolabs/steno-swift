import StenoIntelligence
import SwiftUI

/// Einstellungen "Sprachmodelle": konfigurierte OpenAI-kompatible Endpunkte
/// (LM Studio, eigenes Ollama, bewusst aktivierte Cloud-APIs). Kein Endpunkt
/// wird automatisch kontaktiert; "Verbindung testen" läuft nur auf Klick.
struct TextModelSettingsView: View {
    @Environment(TextModelSettings.self) private var settings

    @State private var editorEndpoint: EndpointDraft?
    @State private var probeState = TextModelProbeState()
    @State private var probing: Set<UUID> = []
    @State private var mutationErrors: [UUID: String] = [:]

    var body: some View {
        Form {
            if let recoveryError = settings.recoveryErrorMessage {
                Section("Endpoint storage unavailable") {
                    Text(recoveryError)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text(
                    """
                    Minutes use Apple Intelligence on this device by default. \
                    Endpoints configured here (for example LM Studio or Ollama) are only used \
                    when you explicitly select one while generating minutes; \
                    the transcript is then sent to that endpoint.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section("Endpoints") {
                if settings.endpoints.isEmpty {
                    Text("No endpoints configured.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.endpoints, id: \.id) { endpoint in
                    endpointRow(endpoint)
                }
                Button {
                    editorEndpoint = EndpointDraft()
                } label: {
                    Label("Add endpoint", systemImage: "plus")
                }
                .disabled(settings.recoveryErrorMessage != nil)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 320)
        .sheet(item: $editorEndpoint) { draft in
            EndpointEditor(draft: draft) { finished, apiKey in
                try settings.upsert(finished, apiKey: apiKey)
                probeState.endpointWasSaved(finished.id)
                mutationErrors[finished.id] = nil
            }
        }
    }

    @ViewBuilder
    private func endpointRow(_ endpoint: TextModelEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.name).font(.body.weight(.medium))
                    Text("\(endpoint.baseURL.absoluteString) · \(endpoint.modelID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if probing.contains(endpoint.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test connection") {
                        Task { await probe(endpoint) }
                    }
                    .controlSize(.small)
                }
                Menu {
                    Button("Edit") {
                        editorEndpoint = EndpointDraft(endpoint)
                    }
                    Button("Delete", role: .destructive) {
                        do {
                            try settings.remove(endpoint)
                            mutationErrors[endpoint.id] = nil
                        } catch {
                            mutationErrors[endpoint.id] = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let result = probeState.result(for: endpoint.id) {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = mutationErrors[endpoint.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func probe(_ endpoint: TextModelEndpoint) async {
        let generation = probeState.beginProbe(for: endpoint.id)
        probing.insert(endpoint.id)
        defer { probing.remove(endpoint.id) }
        do {
            let secret = try TextModelKeychain.secret(
                for: TextModelSecretSlot(endpoint: endpoint)
            )
            if endpoint.requiresAPIKey,
               secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw OpenAICompatibleProviderError.apiKeyRequired
            }
            let provider = OpenAICompatibleProvider(
                endpoint: endpoint,
                resolvingSecret: { _ in secret }
            )
            let result = try await provider.probe(endpoint: endpoint)
            probeState.setResult(
                result.isModelAvailable
                    ? "Reachable, model \u{201C}\(endpoint.modelID)\u{201D} is available."
                    : "Reachable, but model \u{201C}\(endpoint.modelID)\u{201D} was not found.",
                for: endpoint.id,
                generation: generation
            )
        } catch {
            probeState.setResult(
                error.localizedDescription,
                for: endpoint.id,
                generation: generation
            )
        }
    }
}

/// Bearbeitbarer Entwurf; der Schlüssel wird nie aus dem Keychain
/// zurückgelesen, leeres Feld heißt "unverändert lassen".
@Observable
final class EndpointDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var name: String
    var urlText: String
    var modelID: String
    var apiKey: String = ""
    private let persistedRequiresAPIKey: Bool

    init() {
        id = UUID()
        isNew = true
        name = ""
        urlText = "http://localhost:1234/v1"
        modelID = ""
        persistedRequiresAPIKey = false
    }

    init(_ endpoint: TextModelEndpoint) {
        id = endpoint.id
        isNew = false
        name = endpoint.name
        urlText = endpoint.baseURL.absoluteString
        modelID = endpoint.modelID
        persistedRequiresAPIKey = endpoint.requiresAPIKey
    }

    var validated: TextModelEndpoint? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedModel = modelID.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedModel.isEmpty,
              let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return TextModelEndpoint(
            id: id,
            name: trimmedName,
            baseURL: url,
            modelID: trimmedModel,
            requiresAPIKey: persistedRequiresAPIKey || !apiKey.isEmpty
        )
    }
}

struct EndpointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: EndpointDraft
    let onSave: (TextModelEndpoint, String?) throws -> Void
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isNew ? "Add endpoint" : "Edit endpoint")
                .font(.headline)
            Form {
                TextField("Name", text: $draft.name, prompt: Text("LM Studio"))
                TextField(
                    "Base URL",
                    text: $draft.urlText,
                    prompt: Text("http://localhost:1234/v1")
                )
                TextField("Model", text: $draft.modelID, prompt: Text("gemma-3-27b"))
                SecureField(
                    "API key",
                    text: $draft.apiKey,
                    prompt: Text(draft.isNew ? "optional" : "empty = unchanged")
                )
                Text("The key is stored in the keychain only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if let endpoint = draft.validated {
                        do {
                            try onSave(endpoint, draft.apiKey.isEmpty ? nil : draft.apiKey)
                            saveError = nil
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validated == nil)
            }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
