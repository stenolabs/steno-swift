import StenoDomain
import StenoIntelligence
import SwiftUI

enum MacTextModelEndpointPresentation {
    static let deletionTitle: LocalizedStringResource = "Delete endpoint?"
    static let deletionConfirmationLabel: LocalizedStringResource = "Delete"
    static let deletionCancellationLabel: LocalizedStringResource = "Cancel"
    static let deletionFailureTitle: LocalizedStringResource =
        "Endpoint deletion incomplete"
    static let deletionFailureDismissLabel: LocalizedStringResource = "Dismiss"

    static func deletionMessage(
        for endpoint: TextModelEndpoint
    ) -> LocalizedStringResource {
        "Deleting “\(endpoint.name)” removes its configuration and saved API key from this Mac. This cannot be undone."
    }

    static func deletionFailureMessage(
        _ failure: MacTextModelEndpointDeletionFailure
    ) -> LocalizedStringResource {
        "Steno couldn't finish deleting “\(failure.endpointName)”. The endpoint may already have been removed. \(failure.reason)"
    }

    static func probeMessage(
        _ result: TextModelProbeResult,
        for endpoint: TextModelEndpoint
    ) -> String {
        guard result.isModelAvailable else {
            return String(localized: "Reachable, but model \u{201C}\(endpoint.modelID)\u{201D} was not found.")
        }
        guard result.supportsStructuredGeneration else {
            if let tokens = result.reportedContextWindowTokens {
                return String(localized: "Reachable, but structured output is not ready. Reported context: \(tokens) tokens.")
            }
            return String(localized: "Reachable, but structured output is not ready.")
        }
        return String(localized: "Reachable, model \u{201C}\(endpoint.modelID)\u{201D} is available.")
    }
}

struct MacTextModelEndpointDeletionFailure: Equatable {
    let endpointName: String
    let reason: String
}

struct MacTextModelEndpointDeletionState {
    private(set) var target: TextModelEndpoint?
    private(set) var failure: MacTextModelEndpointDeletionFailure?

    mutating func requestDeletion(of endpoint: TextModelEndpoint) {
        target = endpoint
    }

    mutating func cancelDeletion() {
        target = nil
    }

    mutating func confirmDeletion(
        removing remove: (TextModelEndpoint) throws -> Void
    ) {
        guard let target else { return }
        self.target = nil
        do {
            try remove(target)
            failure = nil
        } catch {
            failure = MacTextModelEndpointDeletionFailure(
                endpointName: target.name,
                reason: error.localizedDescription
            )
        }
    }

    mutating func dismissFailure() {
        failure = nil
    }
}

/// Einstellungen "Sprachmodelle": konfigurierte OpenAI-kompatible Endpunkte
/// (LM Studio, eigenes Ollama, bewusst aktivierte Cloud-APIs). Kein Endpunkt
/// wird automatisch kontaktiert; "Verbindung testen" läuft nur auf Klick.
struct TextModelSettingsView: View {
    @Environment(TextModelSettings.self) private var settings

    @State private var editorEndpoint: EndpointDraft?
    @State private var probeState = TextModelProbeState()
    @State private var probing: Set<UUID> = []
    @State private var mutationErrors: [UUID: String] = [:]
    @State private var deletionState = MacTextModelEndpointDeletionState()

    var body: some View {
        Form {
            if let recoveryError = settings.recoveryErrorMessage {
                Section("Endpoint storage unavailable") {
                    Text(recoveryError)
                        .foregroundStyle(.red)
                }
            }
            if let failure = deletionState.failure {
                Section {
                    Text(
                        MacTextModelEndpointPresentation.deletionFailureMessage(failure)
                    )
                    .foregroundStyle(.red)
                    Button {
                        deletionState.dismissFailure()
                    } label: {
                        Text(
                            MacTextModelEndpointPresentation.deletionFailureDismissLabel
                        )
                    }
                } header: {
                    Text(MacTextModelEndpointPresentation.deletionFailureTitle)
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
            #if STENO_NATIVE_GEMMA_MODEL_STORE && canImport(StenoGemmaClient)
            NativeGemmaModelSettingsView()
            #endif
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
        .alert(
            Text(MacTextModelEndpointPresentation.deletionTitle),
            isPresented: deletionIsPresented,
            presenting: deletionState.target
        ) { endpoint in
            Button(role: .destructive) {
                delete(endpoint)
            } label: {
                Text(MacTextModelEndpointPresentation.deletionConfirmationLabel)
            }
            Button(role: .cancel) {
                deletionState.cancelDeletion()
            } label: {
                Text(MacTextModelEndpointPresentation.deletionCancellationLabel)
            }
        } message: { endpoint in
            Text(MacTextModelEndpointPresentation.deletionMessage(for: endpoint))
        }
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(
            get: { deletionState.target != nil },
            set: { if !$0 { deletionState.cancelDeletion() } }
        )
    }

    @ViewBuilder
    private func endpointRow(_ endpoint: TextModelEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.name).font(.body.weight(.medium))
                    Text(
                        "\(endpoint.baseURL.absoluteString) · \(endpoint.modelID) · "
                            + "\(endpoint.dialect.displayName) · "
                            + endpoint.hosting.displayName
                    )
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
                        deletionState.requestDeletion(of: endpoint)
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

    private func delete(_ endpoint: TextModelEndpoint) {
        deletionState.confirmDeletion { try settings.remove($0) }
        if deletionState.failure == nil {
            mutationErrors[endpoint.id] = nil
        }
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
            let result = try await ExternalTextModelProviderFactory.probe(
                endpoint: endpoint,
                resolvingSecret: { _ in secret }
            )
            probeState.setResult(
                MacTextModelEndpointPresentation.probeMessage(result, for: endpoint),
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
    var hosting: TextModelHosting
    var dialect: TextModelAPIDialect
    var bedrockRegion: String
    var bedrockInferenceProfile: String
    private let persistedRequiresAPIKey: Bool
    var contextWindowText: String
    private var hostingIsAutomatic: Bool
    private let initialHost: String?
    private let initialHosting: TextModelHosting

    private static let defaultBedrockRegion = "us-east-1"

    init() {
        id = UUID()
        isNew = true
        name = ""
        urlText = "http://localhost:1234/v1"
        modelID = ""
        persistedRequiresAPIKey = false
        hosting = .selfHosted
        dialect = .openAICompatible
        bedrockRegion = Self.defaultBedrockRegion
        bedrockInferenceProfile = ""
        contextWindowText = String(TextModelAPIDialect.openAICompatible.defaultContextWindowTokens)
        hostingIsAutomatic = true
        initialHost = nil
        initialHosting = .selfHosted
    }

    init(_ endpoint: TextModelEndpoint) {
        id = endpoint.id
        isNew = false
        name = endpoint.name
        urlText = endpoint.baseURL.absoluteString
        modelID = endpoint.modelID
        persistedRequiresAPIKey = endpoint.requiresAPIKey
        hosting = endpoint.hosting
        dialect = endpoint.dialect
        bedrockRegion = endpoint.bedrock?.region ?? Self.defaultBedrockRegion
        bedrockInferenceProfile = endpoint.bedrock?.inferenceProfile ?? ""
        contextWindowText = String(endpoint.contextWindowTokens)
        hostingIsAutomatic = true
        initialHost = endpoint.baseURL.host?.lowercased()
        initialHosting = endpoint.hosting
    }

    /// Folgt der URL, solange der Nutzer die Hosting-Wahl nicht ausdruecklich
    /// getroffen hat; bleibt beim urspruenglichen Wert, solange der Host
    /// unveraendert ist, damit ein bestehender Endpunkt beim blossen Oeffnen
    /// des Editors sein Hosting nicht verliert.
    func updateHostingFromURLIfAutomatic() {
        guard hostingIsAutomatic,
              let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        hosting = url.host?.lowercased() == initialHost
            ? initialHosting
            : TextModelEndpointPolicy.inferredHosting(for: url)
    }

    func selectHosting(_ hosting: TextModelHosting) {
        self.hosting = hosting
        hostingIsAutomatic = false
    }

    /// Wie viele Token der Server je Anfrage verarbeitet. Steno teilt das
    /// Transkript danach auf, und der Wert entscheidet dabei mehr als es
    /// aussieht: bei 4096 zerfaellt eine lange Besprechung in so viele
    /// Abschnitte, dass die Zwischenergebnisse nicht mehr zu zweit in eine
    /// Anfrage passen und die Zusammenfassung nicht mehr zusammenlaeuft.
    ///
    /// nil, solange die Eingabe keine Zahl im erlaubten Bereich ist. Der
    /// Editor speichert dann nicht, statt still einen anderen Wert zu nehmen.
    var contextWindowTokens: Int? {
        guard let value = Int(contextWindowText.trimmingCharacters(in: .whitespaces)),
              value >= TextModelEndpoint.minimumContextWindowTokens,
              value <= TextModelEndpoint.maximumContextWindowTokens
        else { return nil }
        return value
    }

    /// Ollama laesst sich auch als generischer OpenAI-Endpunkt eintragen,
    /// aber dann fehlen Steno der Denkmodus-Schalter und die Kontextgroesse.
    /// Der Port ist nur ein Indiz, deshalb wird hier nichts umgestellt,
    /// sondern angeboten.
    var nativeDialectSuggestion: TextModelEndpointPolicy.NativeDialectSuggestion? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return TextModelEndpointPolicy.nativeDialectSuggestion(
            baseURL: url,
            dialect: dialect
        )
    }

    /// Bewusst ohne `selectDialect`: das wuerde die eingetippte Adresse durch
    /// die Standardadresse des Dialekts ersetzen und damit den Host verwerfen,
    /// um den es gerade geht.
    func applyNativeDialectSuggestion() {
        guard let suggestion = nativeDialectSuggestion else { return }
        dialect = suggestion.dialect
        urlText = suggestion.baseURL.absoluteString
        contextWindowText = String(suggestion.dialect.defaultContextWindowTokens)
    }

    func selectDialect(_ dialect: TextModelAPIDialect) {
        self.dialect = dialect
        // Der Startwert gehoert zum Dialekt: nur Ollama laesst sich die
        // Fenstergroesse vorgeben, und nur dort ist ein grosser Wert mehr als
        // eine Behauptung. Sichtbar im Feld, also jederzeit ueberschreibbar.
        contextWindowText = String(dialect.defaultContextWindowTokens)
        if dialect == .amazonBedrock {
            selectBedrockRegion(bedrockRegion)
        } else if let defaultBaseURL = dialect.defaultBaseURL {
            urlText = defaultBaseURL.absoluteString
        }
    }

    /// Haelt die Basis-URL an die Region gebunden, damit die Bedrock-
    /// Sonderpolicy in TextModelEndpointPolicy nie eine Basis-URL sieht, die
    /// nicht zur Region passt.
    func selectBedrockRegion(_ region: String) {
        bedrockRegion = region
        if let baseURL = try? AmazonBedrockEndpointPolicy.baseURL(region: region) {
            urlText = baseURL.absoluteString
        }
    }

    var validated: TextModelEndpoint? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedModel = modelID.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedModel.isEmpty,
              let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https",
              let contextWindowTokens
        else { return nil }
        return TextModelEndpoint(
            id: id,
            name: trimmedName,
            baseURL: url,
            modelID: trimmedModel,
            requiresAPIKey: persistedRequiresAPIKey || !apiKey.isEmpty,
            hosting: hosting,
            dialect: dialect,
            contextWindowTokens: contextWindowTokens,
            bedrock: bedrockConfiguration
        )
    }

    /// nil ausserhalb des amazonBedrock-Dialekts: TextModelEndpointPolicy
    /// weist jede Bedrock-Konfiguration bei einem anderen Dialekt ab.
    private var bedrockConfiguration: AmazonBedrockConfiguration? {
        guard dialect == .amazonBedrock else { return nil }
        let trimmedProfile = bedrockInferenceProfile.trimmingCharacters(in: .whitespaces)
        return AmazonBedrockConfiguration(
            region: bedrockRegion,
            inferenceProfile: trimmedProfile.isEmpty ? nil : trimmedProfile
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
                Picker("API type", selection: Binding(
                    get: { draft.dialect },
                    set: { draft.selectDialect($0) }
                )) {
                    ForEach(TextModelAPIDialect.configurableCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                TextField("Name", text: $draft.name, prompt: Text("LM Studio"))
                TextField(
                    "Base URL",
                    text: $draft.urlText,
                    prompt: Text("http://localhost:1234/v1")
                )
                .disabled(draft.dialect == .amazonBedrock)
                .onChange(of: draft.urlText) {
                    draft.updateHostingFromURLIfAutomatic()
                }
                if draft.nativeDialectSuggestion != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This address looks like Ollama.")
                            .font(.callout)
                        Text("Steno can address it directly instead of through its OpenAI-compatible layer. Only that way can it switch off the model's thinking mode and set the context size. With a thinking model, that decides whether an answer arrives at all.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Use the Ollama API type") {
                            draft.applyNativeDialectSuggestion()
                        }
                        .padding(.top, 2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                if draft.dialect == .amazonBedrock {
                    Picker("Region", selection: Binding(
                        get: { draft.bedrockRegion },
                        set: { draft.selectBedrockRegion($0) }
                    )) {
                        ForEach(AmazonBedrockEndpointPolicy.supportedRegions, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    TextField(
                        "Inference profile",
                        text: $draft.bedrockInferenceProfile,
                        prompt: Text("optional, falls back to model")
                    )
                }
                TextField("Model", text: $draft.modelID, prompt: Text("gemma-3-27b"))
                TextField(
                    "Context window",
                    text: $draft.contextWindowText,
                    prompt: Text("4096")
                )
                Text(draft.contextWindowTokens == nil
                    ? "Tokens per request, between \(TextModelEndpoint.minimumContextWindowTokens) and \(TextModelEndpoint.maximumContextWindowTokens)."
                    : "Tokens per request. Must match what the server actually loads. Too small a value splits a long meeting into so many pieces that the summary no longer converges.")
                    .font(.caption)
                    .foregroundStyle(draft.contextWindowTokens == nil ? .red : .secondary)
                Picker("Processing location", selection: Binding(
                    get: { draft.hosting },
                    set: { draft.selectHosting($0) }
                )) {
                    Text(TextModelHosting.selfHosted.displayName).tag(TextModelHosting.selfHosted)
                    Text(TextModelHosting.cloud.displayName).tag(TextModelHosting.cloud)
                }
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
