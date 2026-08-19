import Observation
import StenoIntelligence
import SwiftUI

struct TextModelSettingsView: View {
    @Environment(TextModelSettings.self) private var settings
    @State private var editor: EndpointDraft?
    @State private var probeState = TextModelProbeState()
    @State private var probing: Set<UUID> = []
    @State private var deletionErrors: [UUID: String] = [:]

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
                    "Configured endpoints are only contacted when you test a connection or explicitly generate minutes with one."
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
                    editor = EndpointDraft()
                } label: {
                    Label("Add endpoint", systemImage: "plus")
                }
                .disabled(settings.recoveryErrorMessage != nil)
            }
        }
        .navigationTitle("Language models")
        .sheet(item: $editor) { draft in
            EndpointEditor(draft: draft) { endpoint, apiKey in
                try settings.upsert(endpoint, apiKey: apiKey)
                probeState.endpointWasSaved(endpoint.id)
            }
        }
    }

    private func endpointRow(_ endpoint: TextModelEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    Button("Edit") { editor = EndpointDraft(endpoint) }
                    Button("Delete", role: .destructive) { delete(endpoint) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if let warning = TextModelEndpointPresentation.plaintextWarning(for: endpoint) {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let result = probeState.result(for: endpoint.id) {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let deletionError = deletionErrors[endpoint.id] {
                Text(deletionError)
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
            let secret = try TextModelKeychain.shared.value(
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
            probeState.setResult(TextModelEndpointPresentation.probeMessage(
                for: result,
                modelID: endpoint.modelID
            ), for: endpoint.id, generation: generation)
        } catch {
            probeState.setResult(
                TextModelEndpointPresentation.probeMessage(for: error),
                for: endpoint.id,
                generation: generation
            )
        }
    }

    private func delete(_ endpoint: TextModelEndpoint) {
        do {
            try settings.remove(endpoint)
            deletionErrors[endpoint.id] = nil
        } catch {
            deletionErrors[endpoint.id] = error.localizedDescription
        }
    }
}

@Observable
final class EndpointDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    private let existingRequiresAPIKey: Bool
    var name: String
    var urlText: String
    var modelID: String
    var apiKey = ""

    init() {
        id = UUID()
        isNew = true
        existingRequiresAPIKey = false
        name = ""
        urlText = "http://localhost:1234/v1"
        modelID = ""
    }

    init(_ endpoint: TextModelEndpoint) {
        id = endpoint.id
        isNew = false
        existingRequiresAPIKey = endpoint.requiresAPIKey
        name = endpoint.name
        urlText = endpoint.baseURL.absoluteString
        modelID = endpoint.modelID
    }

    var validated: TextModelEndpoint? {
        try? validatedEndpoint()
    }

    var validationMessage: String? {
        do {
            _ = try validatedEndpoint()
            return nil
        } catch let error as TextModelEndpointPolicyError {
            return TextModelEndpointPresentation.validationMessage(for: error)
        } catch {
            return "Enter a name, URL and model."
        }
    }

    private func validatedEndpoint() throws -> TextModelEndpoint {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !modelID.isEmpty,
              let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw EndpointDraftError.missingRequiredValue
        }
        let endpoint = TextModelEndpoint(
            id: id,
            name: name,
            baseURL: url,
            modelID: modelID,
            requiresAPIKey: existingRequiresAPIKey || !apiKey.isEmpty
        )
        return try TextModelEndpointPolicy.validate(endpoint)
    }
}

private enum EndpointDraftError: Error {
    case missingRequiredValue
}

struct EndpointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: EndpointDraft
    let onSave: (TextModelEndpoint, String?) throws -> Void
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft.name, prompt: Text("LM Studio"))
                TextField("Base URL", text: $draft.urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model", text: $draft.modelID, prompt: Text("gemma-3-27b"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(
                    "API key",
                    text: $draft.apiKey,
                    prompt: Text(draft.isNew ? "optional" : "empty = unchanged")
                )
                Text("The key is stored in the keychain only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let validationMessage = draft.validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(draft.isNew ? "Add endpoint" : "Edit endpoint")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(draft.validated == nil)
                }
            }
        }
    }

    private func save() {
        guard let endpoint = draft.validated else { return }
        do {
            try onSave(endpoint, draft.apiKey.isEmpty ? nil : draft.apiKey)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

enum TextModelEndpointPresentation {
    static func plaintextWarning(for endpoint: TextModelEndpoint) -> String? {
        guard (try? TextModelEndpointPolicy.transportSecurity(for: endpoint.baseURL))
            == .localPlaintext
        else {
            return nil
        }
        return "This connection is not encrypted."
    }

    static func probeMessage(for result: TextModelProbeResult, modelID: String) -> String {
        result.isModelAvailable
            ? "Reachable, model \"\(modelID)\" is available."
            : "Reachable, but model \"\(modelID)\" was not found."
    }

    static func probeMessage(for error: Error) -> String {
        error.localizedDescription
    }

    static func validationMessage(for error: TextModelEndpointPolicyError) -> String {
        switch error {
        case .missingHost:
            "Enter a URL with a host."
        case .unsupportedScheme:
            "Use http or https."
        case .embeddedCredentials:
            "Remove credentials from the URL."
        case .queryNotAllowed:
            "Remove query parameters from the URL."
        case .fragmentNotAllowed:
            "Remove the URL fragment."
        case .insecureRemoteURL:
            "Unencrypted HTTP is only allowed for local endpoints."
        }
    }
}
