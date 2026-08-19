import Foundation
import Observation
import Security
import StenoIntelligence
import StenoPipeline

private enum TextModelSettingsResolutionLock {
    static let lock = NSLock()

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

typealias TextModelProviderBuilding = @Sendable (
    TextModelEndpoint,
    String?
) -> any TextModelProvider

private enum TextModelSelectionPersistencePolicy {
    case userDefaults(UserDefaults)
    case disabled

    static func defaultStore(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Self {
        environment[
            AtomicTextModelEndpointRegistryStore.testIsolationEnvironmentKey
        ] == "1"
            ? .disabled
            : .userDefaults(defaults)
    }

    func selection(
        forKey key: String,
        endpoints: [TextModelEndpoint]
    ) -> UUID? {
        guard case let .userDefaults(defaults) = self,
              let raw = defaults.string(forKey: key)
        else { return nil }
        guard let uuid = UUID(uuidString: raw),
              endpoints.contains(where: { $0.id == uuid })
        else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return uuid
    }

    func persist(_ endpointID: UUID?, forKey key: String) {
        guard case let .userDefaults(defaults) = self else { return }
        if let endpointID {
            defaults.set(endpointID.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

enum TextModelSettingsMutationError: LocalizedError, Equatable {
    case replacementAPIKeyRequired

    var errorDescription: String? {
        "Enter the API key again before changing this endpoint URL."
    }
}

/// Verwaltung der konfigurierten OpenAI-kompatiblen Endpunkte.
/// Endpunktliste und Journal liegen atomar in Application Support, die
/// Auswahl in UserDefaults und API-Schlüssel ausschließlich im Keychain.
@MainActor
@Observable
final class TextModelSettings {
    nonisolated static let endpointsDefaultsKey = "steno.textmodel.endpoints"
    nonisolated static let registryStateDefaultsKey =
        UserDefaultsTextModelEndpointRegistryStore.defaultStateKey
    nonisolated static let selectionDefaultsKey = "steno.textmodel.selection"

    private let selectionPersistencePolicy: TextModelSelectionPersistencePolicy
    private let secrets: any TextModelSecretStoring
    private let registry: any TextModelEndpointRegistryStoring
    private let mutationAction: (TextModelEndpointMutationCheckpoint) throws -> Void
    private(set) var endpoints: [TextModelEndpoint] = []
    private(set) var recoveryErrorMessage: String?

    /// nil = Apple Intelligence (Foundation Models). Extern wird nur, was der
    /// Nutzer ausdrücklich gewählt hat; die Wahl bleibt über Neustarts erhalten.
    var selectedEndpointID: UUID? {
        didSet { persistSelection() }
    }

    convenience init() {
        let defaults = UserDefaults.standard
        self.init(
            defaults: defaults,
            secrets: SystemTextModelSecretStore.shared,
            registry: AtomicTextModelEndpointRegistryStore(defaults: defaults),
            defaultStoreEnvironment: ProcessInfo.processInfo.environment
        )
    }

    convenience init(
        defaults: UserDefaults,
        secrets: any TextModelSecretStoring,
        registry: any TextModelEndpointRegistryStoring,
        defaultStoreEnvironment environment: [String: String]
    ) {
        self.init(
            selectionPersistencePolicy: .defaultStore(
                defaults: defaults,
                environment: environment
            ),
            secrets: secrets,
            registry: registry
        )
    }

    convenience init(
        defaults: UserDefaults,
        secrets: any TextModelSecretStoring,
        registry: any TextModelEndpointRegistryStoring,
        mutationAction: @escaping (
            TextModelEndpointMutationCheckpoint
        ) throws -> Void = { _ in }
    ) {
        self.init(
            selectionPersistencePolicy: .userDefaults(defaults),
            secrets: secrets,
            registry: registry,
            mutationAction: mutationAction
        )
    }

    private init(
        selectionPersistencePolicy: TextModelSelectionPersistencePolicy,
        secrets: any TextModelSecretStoring,
        registry: any TextModelEndpointRegistryStoring,
        mutationAction: @escaping (
            TextModelEndpointMutationCheckpoint
        ) throws -> Void = { _ in }
    ) {
        self.selectionPersistencePolicy = selectionPersistencePolicy
        self.secrets = secrets
        self.registry = registry
        self.mutationAction = mutationAction
        load()
    }

    var selectedEndpoint: TextModelEndpoint? {
        selectedEndpointID.flatMap { id in endpoints.first { $0.id == id } }
    }

    func upsert(_ endpoint: TextModelEndpoint, apiKey: String?) throws {
        TextModelSettingsResolutionLock.lock.lock()
        defer { TextModelSettingsResolutionLock.lock.unlock() }
        var state = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )
        endpoints = state.endpoints
        recoveryErrorMessage = nil
        let validated = try TextModelEndpointPolicy.validate(endpoint)
        let hasNewAPIKey = apiKey.map { !$0.isEmpty } ?? false
        let proposed = TextModelEndpoint(
            id: validated.id,
            name: validated.name,
            baseURL: validated.baseURL,
            modelID: validated.modelID,
            requiresAPIKey: validated.requiresAPIKey || hasNewAPIKey
        )
        let index = state.endpoints.firstIndex(where: { $0.id == proposed.id })
        let existing = index.map { state.endpoints[$0] }
        let retainedSecret: String?
        if let apiKey, hasNewAPIKey {
            retainedSecret = apiKey
        } else if let existing {
            retainedSecret = try secrets.value(for: TextModelSecretSlot(endpoint: existing))
            if existing.baseURL != proposed.baseURL, retainedSecret != nil {
                throw TextModelSettingsMutationError.replacementAPIKeyRequired
            }
            if proposed.requiresAPIKey,
               retainedSecret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    != false {
                throw OpenAICompatibleProviderError.apiKeyRequired
            }
        } else if proposed.requiresAPIKey {
            throw OpenAICompatibleProviderError.apiKeyRequired
        } else {
            retainedSecret = nil
        }

        let needsNewRevision = existing == nil
            || existing?.configurationRevision == nil
            || existing.map { !Self.samePublicConfiguration($0, proposed) } == true
            || hasNewAPIKey
        let persisted = TextModelEndpoint(
            id: proposed.id,
            name: proposed.name,
            baseURL: proposed.baseURL,
            modelID: proposed.modelID,
            requiresAPIKey: proposed.requiresAPIKey,
            configurationRevision: needsNewRevision
                ? UUID()
                : existing?.configurationRevision
        )
        let newSlot = TextModelSecretSlot(endpoint: persisted)
        var candidate = state.endpoints
        if let index {
            candidate[index] = persisted
        } else {
            candidate.append(persisted)
        }
        if !needsNewRevision, existing == persisted {
            return
        }
        state.journal = .upsert(
            phase: .prepared,
            previous: existing,
            next: persisted
        )
        try persistReconcilingAmbiguity(state)
        try mutationAction(.upsertJournalPersisted)

        do {
            if needsNewRevision, let retainedSecret {
                try secrets.setValue(retainedSecret, for: newSlot)
            }
        } catch {
            do {
                try secrets.removeValue(for: newSlot)
                state.journal = nil
                try persistReconcilingAmbiguity(state)
            } catch {
                // The durable prepared journal keeps recovery mandatory.
            }
            throw error
        }
        try mutationAction(.upsertSecretWritten)

        var committed = TextModelEndpointRegistryState(
            endpoints: candidate,
            journal: .upsert(
                phase: .committed,
                previous: existing,
                next: persisted
            )
        )
        try persistReconcilingAmbiguity(committed)
        endpoints = candidate
        try mutationAction(.upsertRegistryCommitted)

        if let existing {
            let oldSlot = TextModelSecretSlot(endpoint: existing)
            if oldSlot != newSlot {
                try secrets.removeValue(for: oldSlot)
            }
        }
        try mutationAction(.upsertOldSecretRemoved)
        committed.journal = nil
        try persistReconcilingAmbiguity(committed)
    }

    func remove(_ endpoint: TextModelEndpoint) throws {
        TextModelSettingsResolutionLock.lock.lock()
        defer { TextModelSettingsResolutionLock.lock.unlock() }
        var state = try TextModelEndpointRegistryRecovery.recover(
            registry: registry,
            secrets: secrets
        )
        endpoints = state.endpoints
        recoveryErrorMessage = nil
        let stored = state.endpoints.first(where: { $0.id == endpoint.id }) ?? endpoint
        state.journal = .delete(phase: .prepared, previous: stored)
        try persistReconcilingAmbiguity(state)
        try mutationAction(.deleteJournalPersisted)
        do {
            try secrets.removeValue(for: TextModelSecretSlot(endpoint: stored))
        } catch {
            state.journal = nil
            try? persistReconcilingAmbiguity(state)
            throw error
        }
        try mutationAction(.deleteSecretRemoved)
        let candidate = state.endpoints.filter { $0.id != endpoint.id }
        var committed = TextModelEndpointRegistryState(
            endpoints: candidate,
            journal: .delete(phase: .committed, previous: stored)
        )
        try persistReconcilingAmbiguity(committed)
        endpoints = candidate
        if selectedEndpointID == endpoint.id {
            selectedEndpointID = nil
        }
        try mutationAction(.deleteRegistryCommitted)
        committed.journal = nil
        try persistReconcilingAmbiguity(committed)
    }

    func endpoint(withID id: String?) -> TextModelEndpoint? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return endpoints.first { $0.id == uuid }
    }

    private func load() {
        do {
            endpoints = try TextModelSettingsResolutionLock.withLock {
                try TextModelEndpointRegistryRecovery.recover(
                    registry: registry,
                    secrets: secrets
                ).endpoints.map(TextModelEndpointPolicy.validate)
            }
            recoveryErrorMessage = nil
        } catch {
            endpoints = []
            recoveryErrorMessage = error.localizedDescription
            return
        }
        if let selection = selectionPersistencePolicy.selection(
            forKey: Self.selectionDefaultsKey,
            endpoints: endpoints
        ) {
            selectedEndpointID = selection
        }
    }

    private func persistReconcilingAmbiguity(
        _ state: TextModelEndpointRegistryState
    ) throws {
        do {
            try registry.persist(state)
        } catch {
            do {
                let actual = try TextModelEndpointRegistryRecovery.recover(
                    registry: registry,
                    secrets: secrets
                )
                endpoints = actual.endpoints
                if let selectedEndpointID,
                   !actual.endpoints.contains(where: { $0.id == selectedEndpointID }) {
                    self.selectedEndpointID = nil
                }
                recoveryErrorMessage = nil
            } catch let recoveryError {
                endpoints = []
                recoveryErrorMessage = recoveryError.localizedDescription
            }
            throw error
        }
    }

    private func persistSelection() {
        selectionPersistencePolicy.persist(
            selectedEndpointID,
            forKey: Self.selectionDefaultsKey
        )
    }

    nonisolated private static func samePublicConfiguration(
        _ lhs: TextModelEndpoint,
        _ rhs: TextModelEndpoint
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.baseURL == rhs.baseURL
            && lhs.modelID == rhs.modelID
            && lhs.requiresAPIKey == rhs.requiresAPIKey
    }
}

extension TextModelSettings {
    /// Resolver für die Pipeline: läuft außerhalb des MainActors und liest
    /// die Endpunktliste deshalb direkt aus der atomaren Registrydatei. nil bleibt
    /// Foundation Models; eine gepinnte, inzwischen gelöschte Endpunkt-ID
    /// führt zu einem Fehler statt stillem Fallback.
    nonisolated static func resolveProvider(
        selection: TextModelProviderSelection
    ) throws -> any TextModelProvider {
        try makeProviderResolver()(selection)
    }

    nonisolated static func makeProviderResolver() -> TextModelProviderResolver {
        makeProviderResolver(
            defaults: .standard,
            secrets: SystemTextModelSecretStore.shared,
            registry: AtomicTextModelEndpointRegistryStore(defaults: .standard)
        )
    }

    nonisolated static func makeProviderResolver(
        defaults: UserDefaults,
        secrets: any TextModelSecretStoring,
        registry: any TextModelEndpointRegistryStoring,
        providerFactory: @escaping TextModelProviderBuilding = { endpoint, secret in
            OpenAICompatibleProvider(
                endpoint: endpoint,
                resolvingSecret: { _ in secret }
            )
        }
    ) -> TextModelProviderResolver {
        let defaultsBox = SendableUserDefaults(defaults)
        return { selection in
            try resolveProvider(
                selection: selection,
                defaults: defaultsBox.value,
                secrets: secrets,
                registry: registry,
                providerFactory: providerFactory
            )
        }
    }

    nonisolated static func resolveProvider(
        selection: TextModelProviderSelection,
        defaults: UserDefaults,
        secrets: any TextModelSecretStoring,
        registry: any TextModelEndpointRegistryStoring,
        providerFactory: TextModelProviderBuilding
    ) throws -> any TextModelProvider {
        guard let endpointID = selection.endpointID else {
            return FoundationModelsProvider()
        }
        return try TextModelSettingsResolutionLock.withLock {
            let state = try TextModelEndpointRegistryRecovery.recover(
                registry: registry,
                secrets: secrets
            )
            guard let uuid = UUID(uuidString: endpointID),
                  let stored = state.endpoints.first(where: { $0.id == uuid })
            else {
                throw PipelineError.unknownTextModelEndpoint(endpointID)
            }
            let endpoint = try TextModelEndpointPolicy.validate(stored)
            if let pinned = selection.endpointSnapshot,
               !endpoint.matchesPinnedConfiguration(pinned) {
                throw PipelineError.textModelEndpointConfigurationChanged(endpointID)
            }
            let secret = try secrets.value(for: TextModelSecretSlot(endpoint: endpoint))
            if endpoint.requiresAPIKey,
               secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw OpenAICompatibleProviderError.apiKeyRequired
            }
            return providerFactory(endpoint, secret)
        }
    }
}

private final class SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

/// API-Schlüssel im Keychain; Account = Endpunkt-UUID plus optionale
/// Konfigurationsrevision. Nirgendwo sonst.
enum TextModelKeychain {
    private static let service = "org.steno.textmodel"

    static func secret(for slot: TextModelSecretSlot) throws -> String? {
        var query = baseQuery(for: slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw TextModelKeychainError(operation: .read, status: status) }
        return value
    }

    static func setSecret(_ secret: String, for slot: TextModelSecretSlot) throws {
        let data = Data(secret.utf8)
        var query = baseQuery(for: slot)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TextModelKeychainError(operation: .store, status: addStatus)
            }
        } else if status != errSecSuccess {
            throw TextModelKeychainError(operation: .store, status: status)
        }
    }

    static func deleteSecret(for slot: TextModelSecretSlot) throws {
        let status = SecItemDelete(baseQuery(for: slot) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TextModelKeychainError(operation: .delete, status: status)
        }
    }

    private static func baseQuery(for slot: TextModelSecretSlot) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: slot),
        ]
    }

    private static func account(for slot: TextModelSecretSlot) -> String {
        guard let revision = slot.configurationRevision else {
            return slot.endpointID.uuidString
        }
        return "\(slot.endpointID.uuidString).\(revision.uuidString)"
    }
}

final class SystemTextModelSecretStore: TextModelSecretStoring, @unchecked Sendable {
    static let shared = SystemTextModelSecretStore()

    func value(for slot: TextModelSecretSlot) throws -> String? {
        try TextModelKeychain.secret(for: slot)
    }

    func setValue(_ value: String, for slot: TextModelSecretSlot) throws {
        try TextModelKeychain.setSecret(value, for: slot)
    }

    func removeValue(for slot: TextModelSecretSlot) throws {
        try TextModelKeychain.deleteSecret(for: slot)
    }
}

private struct TextModelKeychainError: LocalizedError {
    enum Operation {
        case read
        case store
        case delete
    }

    let operation: Operation
    let status: OSStatus

    var errorDescription: String? {
        switch operation {
        case .read:
            "The API key could not be read from the keychain."
        case .store:
            "The API key could not be stored in the keychain."
        case .delete:
            "The API key could not be deleted from the keychain."
        }
    }
}
