import Foundation
import Observation
import Security
import StenoIntelligence
import StenoPipeline

typealias TextModelProviderBuilding = @Sendable (
    TextModelEndpoint,
    String?
) throws -> any TextModelProvider

enum TextModelSettingsMutationError: LocalizedError, Equatable {
    case replacementAPIKeyRequired

    var errorDescription: String? {
        String(localized: "Enter the API key again before changing this endpoint URL.")
    }
}

/// Verwaltung der konfigurierten OpenAI-kompatiblen Endpunkte.
/// Endpunktliste und Journal liegen atomar in Application Support, die
/// API-Schlüssel ausschließlich im Keychain.
@MainActor
@Observable
final class TextModelSettings {
    nonisolated static let endpointsDefaultsKey = "steno.textmodel.endpoints"
    nonisolated static let registryStateDefaultsKey =
        UserDefaultsTextModelEndpointRegistryStore.defaultStateKey

    private let defaults: UserDefaults
    private let secrets: any TextModelSecretStoring
    private let registry: any TextModelEndpointRegistryStoring
    private let mutationAction: (TextModelEndpointMutationCheckpoint) throws -> Void
    private(set) var endpoints: [TextModelEndpoint] = []
    private(set) var recoveryErrorMessage: String?
    var selectedEndpointID: UUID?

    convenience init() {
        self.init(
            defaults: .standard,
            secrets: TextModelKeychain.shared,
            registry: AtomicTextModelEndpointRegistryStore(defaults: .standard)
        )
    }

    init(
        defaults: UserDefaults,
        secrets: any TextModelSecretStoring,
        registry: any TextModelEndpointRegistryStoring,
        mutationAction: @escaping (
            TextModelEndpointMutationCheckpoint
        ) throws -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.registry = registry
        self.mutationAction = mutationAction
        do {
            endpoints = try TextModelSettingsResolutionLock.withLock {
                try TextModelEndpointRegistryRecovery.recover(
                    registry: self.registry,
                    secrets: secrets
                ).endpoints.map(TextModelEndpointPolicy.validate)
            }
            recoveryErrorMessage = nil
        } catch {
            endpoints = []
            recoveryErrorMessage = error.localizedDescription
        }
    }

    var selectedEndpoint: TextModelEndpoint? {
        selectedEndpointID.flatMap { endpointID in
            endpoints.first { $0.id == endpointID }
        }
    }

    func upsert(_ endpoint: TextModelEndpoint, apiKey: String?) throws {
        let validated = try TextModelEndpointPolicy.validate(endpoint)
        let hasNewAPIKey = apiKey.map { !$0.isEmpty } ?? false
        let proposed = TextModelEndpoint(
            id: validated.id,
            name: validated.name,
            baseURL: validated.baseURL,
            modelID: validated.modelID,
            requiresAPIKey: validated.requiresAPIKey || hasNewAPIKey,
            hosting: validated.hosting,
            dialect: validated.dialect,
            contextWindowTokens: validated.contextWindowTokens,
            bedrock: validated.bedrock
        )
        try TextModelSettingsResolutionLock.withLock {
            var state = try TextModelEndpointRegistryRecovery.recover(
                registry: registry,
                secrets: secrets
            )
            endpoints = state.endpoints
            recoveryErrorMessage = nil
            let existing = state.endpoints.first { $0.id == proposed.id }
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
                    : existing?.configurationRevision,
                hosting: proposed.hosting,
                dialect: proposed.dialect,
                contextWindowTokens: proposed.contextWindowTokens,
                bedrock: proposed.bedrock
            )
            let newSlot = TextModelSecretSlot(endpoint: persisted)
            var candidate = state.endpoints
            if let index = candidate.firstIndex(where: { $0.id == persisted.id }) {
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
    }

    func remove(_ endpoint: TextModelEndpoint) throws {
        try TextModelSettingsResolutionLock.withLock {
            var state = try TextModelEndpointRegistryRecovery.recover(
                registry: registry,
                secrets: secrets
            )
            endpoints = state.endpoints
            recoveryErrorMessage = nil
            let stored = state.endpoints.first(where: { $0.id == endpoint.id }) ?? endpoint
            let slots = TextModelSecretSlot.allKnownSlots(for: stored)
            let currentSlot = slots[0]
            let currentSecretWasPresent = try secrets.value(for: currentSlot) != nil
            state.journal = .delete(
                phase: .prepared,
                previous: stored,
                currentSecretWasPresent: currentSecretWasPresent
            )
            try persistReconcilingAmbiguity(state)
            try mutationAction(.deleteJournalPersisted)
            do {
                try secrets.removeValue(for: currentSlot)
            } catch {
                state.journal = nil
                try? registry.persist(state)
                throw error
            }
            try mutationAction(.deleteCurrentSecretRemoved)
            state.journal = .delete(
                phase: .committed,
                previous: stored,
                currentSecretWasPresent: currentSecretWasPresent
            )
            try persistReconcilingAmbiguity(state)
            for slot in slots.dropFirst() {
                try secrets.removeValue(for: slot)
            }
            try mutationAction(.deleteSecretRemoved)
            let candidate = state.endpoints.filter { $0.id != endpoint.id }
            var committed = TextModelEndpointRegistryState(
                endpoints: candidate,
                journal: .delete(
                    phase: .committed,
                    previous: stored,
                    currentSecretWasPresent: currentSecretWasPresent
                )
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
    }

    func endpoint(withID id: String?) -> TextModelEndpoint? {
        guard let id, let endpointID = UUID(uuidString: id) else { return nil }
        return endpoints.first { $0.id == endpointID }
    }

    func resetSelectionForColdLaunch() {
        selectedEndpointID = nil
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

    nonisolated private static func samePublicConfiguration(
        _ lhs: TextModelEndpoint,
        _ rhs: TextModelEndpoint
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.baseURL == rhs.baseURL
            && lhs.modelID == rhs.modelID
            && lhs.requiresAPIKey == rhs.requiresAPIKey
            && lhs.hosting == rhs.hosting
            && lhs.dialect == rhs.dialect
            && lhs.contextWindowTokens == rhs.contextWindowTokens
            && lhs.bedrock == rhs.bedrock
    }

    nonisolated static func resolveProvider(
        selection: TextModelProviderSelection
    ) throws -> any TextModelProvider {
        try makeProviderResolver()(selection)
    }

    nonisolated static func makeProviderResolver() -> TextModelProviderResolver {
        makeProviderResolver(
            defaults: .standard,
            secrets: TextModelKeychain.shared,
            registry: AtomicTextModelEndpointRegistryStore(defaults: .standard)
        )
    }

    nonisolated static func makeProviderResolver(
        defaults: UserDefaults,
        secrets: any TextModelSecretStoring,
        registry: any TextModelEndpointRegistryStoring,
        providerFactory: @escaping TextModelProviderBuilding = { endpoint, secret in
            try ExternalTextModelProviderFactory.makeProvider(
                for: endpoint,
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
            guard let identifier = UUID(uuidString: endpointID),
                  let stored = state.endpoints.first(where: { $0.id == identifier })
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
            return try providerFactory(endpoint, secret)
        }
    }
}

private final class SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private enum TextModelSettingsResolutionLock {
    private static let lock = NSLock()

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

final class TextModelKeychain: TextModelSecretStoring, @unchecked Sendable {
    static let shared = TextModelKeychain()
    private static let service = "org.steno.textmodel"

    func value(for slot: TextModelSecretSlot) throws -> String? {
        var query = Self.baseQuery(for: slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw TextModelKeychainError.readFailed(status) }
        return value
    }

    func setValue(_ value: String, for slot: TextModelSecretSlot) throws {
        let data = Data(value.utf8)
        var query = Self.baseQuery(for: slot)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TextModelKeychainError.storeFailed(addStatus)
            }
        } else if status != errSecSuccess {
            throw TextModelKeychainError.storeFailed(status)
        }
    }

    func removeValue(for slot: TextModelSecretSlot) throws {
        let status = SecItemDelete(Self.baseQuery(for: slot) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TextModelKeychainError.deleteFailed(status)
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

private struct TextModelKeychainError: LocalizedError {
    enum Operation {
        case store
        case delete
        case read
    }

    let operation: Operation
    let status: OSStatus

    static func storeFailed(_ status: OSStatus) -> Self {
        Self(operation: .store, status: status)
    }

    static func deleteFailed(_ status: OSStatus) -> Self {
        Self(operation: .delete, status: status)
    }

    static func readFailed(_ status: OSStatus) -> Self {
        Self(operation: .read, status: status)
    }

    var errorDescription: String? {
        switch operation {
        case .store:
            String(localized: "The API key could not be stored in the keychain.")
        case .delete:
            String(localized: "The API key could not be deleted from the keychain.")
        case .read:
            String(localized: "The API key could not be read from the keychain.")
        }
    }
}
