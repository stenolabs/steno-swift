import Observation
import StenoDomain
import StenoIntelligence
import SwiftUI
import UIKit

struct TextModelEndpointDeletionFailure: Equatable {
    let endpointID: UUID
    let endpointName: String
    let reason: String
}

struct TextModelEndpointDeletionState {
    private(set) var target: TextModelEndpoint?
    private(set) var failure: TextModelEndpointDeletionFailure?

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
            if failure?.endpointID == target.id {
                failure = nil
            }
        } catch {
            failure = TextModelEndpointDeletionFailure(
                endpointID: target.id,
                endpointName: target.name,
                reason: error.localizedDescription
            )
        }
    }

    mutating func dismissFailure() {
        failure = nil
    }
}

struct TextModelSettingsView: View {
    @Environment(TextModelSettings.self) private var settings
    @State private var editor: EndpointDraft?
    @State private var probeState = TextModelProbeState()
    @State private var probing: Set<UUID> = []
    @State private var deletionErrors: [UUID: String] = [:]
    @State private var deletionState = TextModelEndpointDeletionState()

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
                    Text(TextModelEndpointPresentation.deletionFailureMessage(failure))
                        .foregroundStyle(.red)
                    Button {
                        deletionState.dismissFailure()
                    } label: {
                        Text(TextModelEndpointPresentation.deletionFailureDismissLabel)
                    }
                } header: {
                    Text(TextModelEndpointPresentation.deletionFailureTitle)
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
        .alert(
            Text(deletionAlertTitle),
            isPresented: deletionIsPresented,
            presenting: deletionState.target
        ) { endpoint in
            Button(role: .destructive) {
                delete(endpoint)
            } label: {
                Text(TextModelEndpointPresentation.deletionConfirmationLabel)
            }
            Button(role: .cancel) {
                deletionState.cancelDeletion()
            } label: {
                Text(TextModelEndpointPresentation.deletionCancellationLabel)
            }
        } message: { endpoint in
            Text(TextModelEndpointPresentation.deletionMessage(for: endpoint))
        }
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(
            get: { deletionState.target != nil },
            set: { if !$0 { deletionState.cancelDeletion() } }
        )
    }

    private var deletionAlertTitle: LocalizedStringResource {
        guard let target = deletionState.target else {
            return TextModelEndpointPresentation.deletionTitle
        }
        return TextModelEndpointPresentation.deletionTitle(for: target)
    }

    private func endpointRow(_ endpoint: TextModelEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    Button("Edit") { editor = EndpointDraft(endpoint) }
                    Button("Delete", role: .destructive) {
                        deletionState.requestDeletion(of: endpoint)
                    }
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

    private func delete(_ endpoint: TextModelEndpoint) {
        deletionState.confirmDeletion { try settings.remove($0) }
        if let failure = deletionState.failure,
           failure.endpointID == endpoint.id {
            deletionErrors[endpoint.id] = failure.reason
        } else {
            deletionErrors[endpoint.id] = nil
        }
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
            let result = try await ExternalTextModelProviderFactory.probe(
                endpoint: endpoint,
                resolvingSecret: { _ in secret }
            )
            probeState.setResult(
                String(localized: TextModelEndpointPresentation.probeMessage(
                    for: result,
                    modelID: endpoint.modelID
                )),
                for: endpoint.id,
                generation: generation
            )
        } catch {
            probeState.setResult(
                TextModelEndpointPresentation.probeMessage(for: error),
                for: endpoint.id,
                generation: generation
            )
        }
    }

}

@Observable
final class EndpointDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    private let existingRequiresAPIKey: Bool
    var contextWindowText: String
    var name: String
    var urlText: String
    var modelID: String
    var apiKey = ""
    var hosting: TextModelHosting
    var dialect: TextModelAPIDialect
    var bedrockRegion: String
    var bedrockInferenceProfile: String

    private var hostingIsAutomatic: Bool
    private let initialHost: String?
    private let initialHosting: TextModelHosting

    private static let defaultBedrockRegion = "us-east-1"

    init() {
        id = UUID()
        isNew = true
        existingRequiresAPIKey = false
        contextWindowText = String(TextModelAPIDialect.openAICompatible.defaultContextWindowTokens)
        name = ""
        urlText = "http://localhost:1234/v1"
        modelID = ""
        hosting = .selfHosted
        dialect = .openAICompatible
        bedrockRegion = Self.defaultBedrockRegion
        bedrockInferenceProfile = ""
        hostingIsAutomatic = true
        initialHost = nil
        initialHosting = .selfHosted
    }

    init(_ endpoint: TextModelEndpoint) {
        id = endpoint.id
        isNew = false
        existingRequiresAPIKey = endpoint.requiresAPIKey
        contextWindowText = String(endpoint.contextWindowTokens)
        name = endpoint.name
        urlText = endpoint.baseURL.absoluteString
        modelID = endpoint.modelID
        hosting = endpoint.hosting
        dialect = endpoint.dialect
        bedrockRegion = endpoint.bedrock?.region ?? Self.defaultBedrockRegion
        bedrockInferenceProfile = endpoint.bedrock?.inferenceProfile ?? ""
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
              let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
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
        guard let value = Int(
                  contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
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
        guard let url = URL(
            string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return nil }
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
        try? validatedEndpoint()
    }

    var validationMessage: String? {
        do {
            _ = try validatedEndpoint()
            return nil
        } catch let error as TextModelEndpointPolicyError {
            return String(localized: TextModelEndpointPresentation.validationMessage(for: error))
        } catch {
            return String(localized: "Enter a name, URL and model.")
        }
    }

    private func validatedEndpoint() throws -> TextModelEndpoint {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !modelID.isEmpty,
              let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let contextWindowTokens
        else {
            throw EndpointDraftError.missingRequiredValue
        }
        let endpoint = TextModelEndpoint(
            id: id,
            name: name,
            baseURL: url,
            modelID: modelID,
            requiresAPIKey: existingRequiresAPIKey || !apiKey.isEmpty,
            hosting: hosting,
            dialect: dialect,
            contextWindowTokens: contextWindowTokens,
            bedrock: bedrockConfiguration
        )
        return try TextModelEndpointPolicy.validate(endpoint)
    }

    /// nil ausserhalb des amazonBedrock-Dialekts: TextModelEndpointPolicy
    /// weist jede Bedrock-Konfiguration bei einem anderen Dialekt ab.
    private var bedrockConfiguration: AmazonBedrockConfiguration? {
        guard dialect == .amazonBedrock else { return nil }
        let trimmedProfile = bedrockInferenceProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return AmazonBedrockConfiguration(
            region: bedrockRegion,
            inferenceProfile: trimmedProfile.isEmpty ? nil : trimmedProfile
        )
    }
}

private enum EndpointDraftError: Error {
    case missingRequiredValue
}

enum EndpointEditorKeyboard: Equatable, Sendable {
    case `default`
    case url
    case asciiCapable
    case numberPad
}

enum EndpointEditorCapitalization: Equatable, Sendable {
    case automatic
    case never
}

enum EndpointEditorSubmitBehavior: Equatable, Sendable {
    case next
    case keyboardToolbar
    case done
}

enum EndpointEditorTextContentType: Equatable, Sendable {
    case none
    case url
}

struct EndpointEditorInputConfiguration: Equatable, Sendable {
    let keyboard: EndpointEditorKeyboard
    let textContentType: EndpointEditorTextContentType
    let capitalization: EndpointEditorCapitalization
    let autocorrectionDisabled: Bool
    let submitBehavior: EndpointEditorSubmitBehavior
    let isSecure: Bool
    let isPrivacySensitive: Bool
}

enum EndpointEditorField: String, CaseIterable, Hashable, Sendable {
    case name
    case baseURL
    case inferenceProfile
    case model
    case contextWindow
    case apiKey

    var inputConfiguration: EndpointEditorInputConfiguration {
        switch self {
        case .name:
            EndpointEditorInputConfiguration(
                keyboard: .default,
                textContentType: .none,
                capitalization: .automatic,
                autocorrectionDisabled: false,
                submitBehavior: .next,
                isSecure: false,
                isPrivacySensitive: false
            )
        case .baseURL:
            EndpointEditorInputConfiguration(
                keyboard: .url,
                textContentType: .url,
                capitalization: .never,
                autocorrectionDisabled: true,
                submitBehavior: .next,
                isSecure: false,
                isPrivacySensitive: false
            )
        case .inferenceProfile, .model:
            EndpointEditorInputConfiguration(
                keyboard: .asciiCapable,
                textContentType: .none,
                capitalization: .never,
                autocorrectionDisabled: true,
                submitBehavior: .next,
                isSecure: false,
                isPrivacySensitive: false
            )
        case .contextWindow:
            EndpointEditorInputConfiguration(
                keyboard: .numberPad,
                textContentType: .none,
                capitalization: .never,
                autocorrectionDisabled: true,
                submitBehavior: .keyboardToolbar,
                isSecure: false,
                isPrivacySensitive: false
            )
        case .apiKey:
            EndpointEditorInputConfiguration(
                keyboard: .asciiCapable,
                textContentType: .none,
                capitalization: .never,
                autocorrectionDisabled: true,
                submitBehavior: .done,
                isSecure: true,
                isPrivacySensitive: true
            )
        }
    }
}

struct EndpointEditorFocusOrder: Equatable, Sendable {
    let fields: [EndpointEditorField]

    init(dialect: TextModelAPIDialect) {
        if dialect == .amazonBedrock {
            fields = [
                .name,
                .inferenceProfile,
                .model,
                .contextWindow,
                .apiKey,
            ]
        } else {
            fields = [
                .name,
                .baseURL,
                .model,
                .contextWindow,
                .apiKey,
            ]
        }
    }

    func next(after field: EndpointEditorField) -> EndpointEditorField? {
        guard let index = fields.firstIndex(of: field) else { return nil }
        let nextIndex = fields.index(after: index)
        guard nextIndex < fields.endIndex else { return nil }
        return fields[nextIndex]
    }
}

private extension EndpointEditorKeyboard {
    var uiKeyboardType: UIKeyboardType {
        switch self {
        case .default:
            .default
        case .url:
            .URL
        case .asciiCapable:
            .asciiCapable
        case .numberPad:
            .numberPad
        }
    }
}

private extension View {
    @ViewBuilder
    func endpointAutocorrectionDisabled(_ disabled: Bool) -> some View {
        if disabled {
            autocorrectionDisabled()
        } else {
            self
        }
    }

    @ViewBuilder
    func endpointCapitalization(
        _ capitalization: EndpointEditorCapitalization
    ) -> some View {
        switch capitalization {
        case .automatic:
            self
        case .never:
            textInputAutocapitalization(.never)
        }
    }

    @ViewBuilder
    func endpointPrivacySensitive(_ sensitive: Bool) -> some View {
        if sensitive {
            privacySensitive()
        } else {
            self
        }
    }
}

private struct EndpointEditorFieldModifier: ViewModifier {
    let field: EndpointEditorField
    let focusedField: FocusState<EndpointEditorField?>.Binding
    let onSubmit: (() -> Void)?

    private var configuration: EndpointEditorInputConfiguration {
        field.inputConfiguration
    }

    func body(content: Content) -> some View {
        configuredContent(content)
    }

    @ViewBuilder
    private func configuredContent<V: View>(_ content: V) -> some View {
        let common = content
            .keyboardType(configuration.keyboard.uiKeyboardType)
            .endpointAutocorrectionDisabled(configuration.autocorrectionDisabled)
            .endpointCapitalization(configuration.capitalization)
            .focused(focusedField, equals: field)
            .endpointPrivacySensitive(configuration.isPrivacySensitive)

        if configuration.textContentType == .url {
            submitConfigured(common.textContentType(.URL))
        } else {
            submitConfigured(common)
        }
    }

    @ViewBuilder
    private func submitConfigured<V: View>(_ content: V) -> some View {
        switch configuration.submitBehavior {
        case .next:
            if let onSubmit {
                content
                    .submitLabel(.next)
                    .onSubmit { onSubmit() }
            } else {
                content.submitLabel(.next)
            }
        case .keyboardToolbar:
            content
        case .done:
            if let onSubmit {
                content
                    .submitLabel(.done)
                    .onSubmit { onSubmit() }
            } else {
                content.submitLabel(.done)
            }
        }
    }
}

private struct EndpointEditorInput: View {
    let field: EndpointEditorField
    let title: LocalizedStringKey
    let prompt: Text?
    @Binding var text: String
    let focusedField: FocusState<EndpointEditorField?>.Binding
    let onSubmit: (() -> Void)?

    init(
        field: EndpointEditorField,
        title: LocalizedStringKey,
        text: Binding<String>,
        prompt: Text? = nil,
        focusedField: FocusState<EndpointEditorField?>.Binding,
        onSubmit: (() -> Void)? = nil
    ) {
        self.field = field
        self.title = title
        self.prompt = prompt
        self._text = text
        self.focusedField = focusedField
        self.onSubmit = onSubmit
    }

    var body: some View {
        if field.inputConfiguration.isSecure {
            SecureField(title, text: $text, prompt: prompt)
                .modifier(EndpointEditorFieldModifier(
                    field: field,
                    focusedField: focusedField,
                    onSubmit: onSubmit
                ))
        } else {
            TextField(title, text: $text, prompt: prompt)
                .modifier(EndpointEditorFieldModifier(
                    field: field,
                    focusedField: focusedField,
                    onSubmit: onSubmit
                ))
        }
    }
}

struct EndpointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: EndpointDraft
    let onSave: (TextModelEndpoint, String?) throws -> Void
    @State private var saveError: String?
    @FocusState private var focusedField: EndpointEditorField?

    private var focusOrder: EndpointEditorFocusOrder {
        EndpointEditorFocusOrder(dialect: draft.dialect)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("API type", selection: Binding(
                    get: { draft.dialect },
                    set: { draft.selectDialect($0) }
                )) {
                    ForEach(TextModelAPIDialect.configurableCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                EndpointEditorInput(
                    field: .name,
                    title: "Name",
                    text: $draft.name,
                    prompt: Text("LM Studio"),
                    focusedField: $focusedField,
                    onSubmit: { focusNext(after: .name) }
                )
                EndpointEditorInput(
                    field: .baseURL,
                    title: "Base URL",
                    text: $draft.urlText,
                    focusedField: $focusedField,
                    onSubmit: { focusNext(after: .baseURL) }
                )
                    .disabled(draft.dialect == .amazonBedrock)
                    .onChange(of: draft.urlText) {
                        draft.updateHostingFromURLIfAutomatic()
                    }
                if draft.nativeDialectSuggestion != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This address looks like Ollama.")
                        Text("Steno can address it directly instead of through its OpenAI-compatible layer. Only that way can it switch off the model's thinking mode and set the context size. With a thinking model, that decides whether an answer arrives at all.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Use the Ollama API type") {
                            draft.applyNativeDialectSuggestion()
                        }
                    }
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
                    EndpointEditorInput(
                        field: .inferenceProfile,
                        title: "Inference profile",
                        text: $draft.bedrockInferenceProfile,
                        prompt: Text("optional, falls back to model"),
                        focusedField: $focusedField,
                        onSubmit: { focusNext(after: .inferenceProfile) }
                    )
                }
                EndpointEditorInput(
                    field: .model,
                    title: "Model",
                    text: $draft.modelID,
                    prompt: Text("gemma-3-27b"),
                    focusedField: $focusedField,
                    onSubmit: { focusNext(after: .model) }
                )
                EndpointEditorInput(
                    field: .contextWindow,
                    title: "Context window",
                    text: $draft.contextWindowText,
                    prompt: Text("4096"),
                    focusedField: $focusedField
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
                EndpointEditorInput(
                    field: .apiKey,
                    title: "API key",
                    text: $draft.apiKey,
                    prompt: Text(draft.isNew ? "optional" : "empty = unchanged"),
                    focusedField: $focusedField,
                    onSubmit: { focusedField = nil }
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
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedField?.inputConfiguration.submitBehavior == .keyboardToolbar {
                        Spacer()
                        Button("Next") {
                            if let focusedField {
                                focusNext(after: focusedField)
                            }
                        }
                        Button("Done") { focusedField = nil }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(draft.validated == nil)
                }
            }
            .onChange(of: draft.dialect) { _, newDialect in
                let order = EndpointEditorFocusOrder(dialect: newDialect)
                if let focusedField, !order.fields.contains(focusedField) {
                    self.focusedField = nil
                }
            }
        }
    }

    private func focusNext(after field: EndpointEditorField) {
        focusedField = focusOrder.next(after: field)
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
    static let deletionTitle: LocalizedStringResource = "Delete endpoint?"
    static let deletionConfirmationLabel: LocalizedStringResource = "Delete Endpoint"
    static let deletionCancellationLabel: LocalizedStringResource = "Cancel"
    static let deletionFailureTitle: LocalizedStringResource =
        "Endpoint deletion incomplete"
    static let deletionFailureDismissLabel: LocalizedStringResource = "Dismiss"

    static func deletionTitle(
        for endpoint: TextModelEndpoint
    ) -> LocalizedStringResource {
        "Delete endpoint “\(endpoint.name)”?"
    }

    static func displayHost(for endpoint: TextModelEndpoint) -> String {
        endpoint.baseURL.host() ?? endpoint.baseURL.absoluteString
    }

    static func deletionMessage(
        for endpoint: TextModelEndpoint
    ) -> LocalizedStringResource {
        "Deleting “\(endpoint.name)” (\(displayHost(for: endpoint))) removes its configuration and saved API key from this device. Jobs pinned to this endpoint can no longer use that saved API key. This cannot be undone."
    }

    static func deletionFailureMessage(
        _ failure: TextModelEndpointDeletionFailure
    ) -> LocalizedStringResource {
        "Steno couldn't finish deleting “\(failure.endpointName)”. The endpoint may already have been removed. \(failure.reason)"
    }

    static func plaintextWarning(
        for endpoint: TextModelEndpoint
    ) -> LocalizedStringResource? {
        guard (try? TextModelEndpointPolicy.transportSecurity(for: endpoint.baseURL))
            == .localPlaintext
        else {
            return nil
        }
        return "This connection is not encrypted."
    }

    static func probeMessage(
        for result: TextModelProbeResult,
        modelID: String
    ) -> LocalizedStringResource {
        guard result.isModelAvailable else {
            return "Reachable, but model \"\(modelID)\" was not found."
        }
        guard result.supportsStructuredGeneration else {
            if let tokens = result.reportedContextWindowTokens {
                return "Reachable, but structured output is not ready. Reported context: \(tokens) tokens."
            }
            return "Reachable, but structured output is not ready."
        }
        return "Reachable, model \"\(modelID)\" is available."
    }

    static func probeMessage(for error: Error) -> String {
        error.localizedDescription
    }

    static func validationMessage(
        for error: TextModelEndpointPolicyError
    ) -> LocalizedStringResource {
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
        case .invalidHosting:
            "This endpoint cannot claim on-device hosting."
        case .invalidProviderConfiguration:
            "This endpoint has settings that do not belong to its API type."
        case .unsupportedDialect:
            "This API type is not available yet."
        case .invalidContextWindow:
            "The context window must be between \(TextModelEndpoint.minimumContextWindowTokens) and \(TextModelEndpoint.maximumContextWindowTokens) tokens."
        }
    }
}
