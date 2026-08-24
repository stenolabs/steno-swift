import Darwin
import Foundation

public protocol TextModelSecretStoring: AnyObject, Sendable {
    func value(for slot: TextModelSecretSlot) throws -> String?
    func setValue(_ value: String, for slot: TextModelSecretSlot) throws
    func removeValue(for slot: TextModelSecretSlot) throws
}

public protocol TextModelEndpointRegistryStoring: AnyObject, Sendable {
    func load() throws -> TextModelEndpointRegistryState
    func persist(_ state: TextModelEndpointRegistryState) throws
}

public extension TextModelSecretSlot {
    /// Every keychain slot owned by an endpoint, ordered so the endpoint's
    /// current revision is removed before its UUID-only legacy slot.
    static func allKnownSlots(for endpoint: TextModelEndpoint) -> [Self] {
        let current = Self(endpoint: endpoint)
        let legacy = Self(
            endpointID: endpoint.id,
            configurationRevision: nil
        )
        return current == legacy ? [current] : [current, legacy]
    }
}

public enum TextModelEndpointMutationCheckpoint: Equatable, Sendable {
    case upsertJournalPersisted
    case upsertSecretWritten
    case upsertRegistryCommitted
    case upsertOldSecretRemoved
    case deleteJournalPersisted
    case deleteCurrentSecretRemoved
    case deleteSecretRemoved
    case deleteRegistryCommitted
}

public struct TextModelEndpointRegistryState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public var endpoints: [TextModelEndpoint]
    public var journal: TextModelEndpointMutationJournal?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        endpoints: [TextModelEndpoint] = [],
        journal: TextModelEndpointMutationJournal? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.endpoints = endpoints
        self.journal = journal
    }
}

public struct TextModelEndpointMutationJournal: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case upsert
        case delete
        case revisionMigration
    }

    public enum Phase: String, Codable, Sendable {
        case prepared
        case committed
    }

    public let operation: Operation
    public let phase: Phase
    public let previousEndpoint: TextModelEndpoint?
    public let nextEndpoint: TextModelEndpoint?
    /// Reconciliation fact only. This never contains secret material.
    public let deleteCurrentSecretWasPresent: Bool?

    public init(
        operation: Operation,
        phase: Phase,
        previousEndpoint: TextModelEndpoint?,
        nextEndpoint: TextModelEndpoint?,
        deleteCurrentSecretWasPresent: Bool? = nil
    ) {
        self.operation = operation
        self.phase = phase
        self.previousEndpoint = previousEndpoint
        self.nextEndpoint = nextEndpoint
        self.deleteCurrentSecretWasPresent = deleteCurrentSecretWasPresent
    }

    public static func upsert(
        phase: Phase,
        previous: TextModelEndpoint?,
        next: TextModelEndpoint
    ) -> Self {
        Self(
            operation: .upsert,
            phase: phase,
            previousEndpoint: previous,
            nextEndpoint: next
        )
    }

    public static func delete(
        phase: Phase,
        previous: TextModelEndpoint,
        currentSecretWasPresent: Bool? = nil
    ) -> Self {
        Self(
            operation: .delete,
            phase: phase,
            previousEndpoint: previous,
            nextEndpoint: nil,
            deleteCurrentSecretWasPresent: currentSecretWasPresent
        )
    }

    public static func revisionMigration(
        phase: Phase,
        previous: TextModelEndpoint,
        next: TextModelEndpoint
    ) -> Self {
        Self(
            operation: .revisionMigration,
            phase: phase,
            previousEndpoint: previous,
            nextEndpoint: next
        )
    }
}

public enum TextModelEndpointRegistryError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidMutationJournal

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "The text model endpoint registry uses unsupported schema version \(version)."
        case .invalidMutationJournal:
            "The text model endpoint registry contains an invalid pending change."
        }
    }
}

public enum TextModelEndpointRegistryRecovery {
    @discardableResult
    public static func recover(
        registry: any TextModelEndpointRegistryStoring,
        secrets: any TextModelSecretStoring
    ) throws -> TextModelEndpointRegistryState {
        var state = try registry.load()
        guard state.schemaVersion <= TextModelEndpointRegistryState.currentSchemaVersion else {
            throw TextModelEndpointRegistryError.unsupportedSchemaVersion(
                state.schemaVersion
            )
        }
        // Ein aelterer Build lehnt den neuen Zustand ab, statt hosting und
        // dialect beim naechsten Persist still zu verwerfen; das Decoding
        // von TextModelEndpoint ist ohnehin tolerant, hier wird nur der
        // Versionsstempel nachgezogen und sofort zurueckgeschrieben.
        if state.schemaVersion < TextModelEndpointRegistryState.currentSchemaVersion {
            state = TextModelEndpointRegistryState(
                schemaVersion: TextModelEndpointRegistryState.currentSchemaVersion,
                endpoints: state.endpoints,
                journal: state.journal
            )
            try registry.persist(state)
        }
        if let journal = state.journal {
            state = try recover(
                state: state,
                journal: journal,
                registry: registry,
                secrets: secrets
            )
        }

        for endpoint in state.endpoints where endpoint.configurationRevision == nil {
            state = try migrateRevision(
                for: endpoint,
                in: state,
                registry: registry,
                secrets: secrets
            )
        }
        return state
    }

    private static func recover(
        state initialState: TextModelEndpointRegistryState,
        journal: TextModelEndpointMutationJournal,
        registry: any TextModelEndpointRegistryStoring,
        secrets: any TextModelSecretStoring
    ) throws -> TextModelEndpointRegistryState {
        var state = initialState
        switch (journal.operation, journal.phase) {
        case (.upsert, .prepared):
            guard let next = journal.nextEndpoint else {
                throw TextModelEndpointRegistryError.invalidMutationJournal
            }
            let newSlot = TextModelSecretSlot(endpoint: next)
            if journal.previousEndpoint.map({ TextModelSecretSlot(endpoint: $0) }) != newSlot {
                try secrets.removeValue(for: newSlot)
            }
            state.journal = nil
            try registry.persist(state)

        case (.upsert, .committed):
            guard let next = journal.nextEndpoint else {
                throw TextModelEndpointRegistryError.invalidMutationJournal
            }
            if let previous = journal.previousEndpoint {
                let oldSlot = TextModelSecretSlot(endpoint: previous)
                let newSlot = TextModelSecretSlot(endpoint: next)
                if oldSlot != newSlot {
                    try secrets.removeValue(for: oldSlot)
                }
            }
            state.journal = nil
            try registry.persist(state)

        case (.delete, .prepared):
            guard let previous = journal.previousEndpoint,
                  journal.nextEndpoint == nil
            else {
                throw TextModelEndpointRegistryError.invalidMutationJournal
            }
            if let currentSecretWasPresent = journal.deleteCurrentSecretWasPresent {
                let currentSlot = TextModelSecretSlot.allKnownSlots(for: previous)[0]
                let currentSecretIsPresent = try secrets.value(for: currentSlot) != nil
                if !currentSecretWasPresent || currentSecretIsPresent {
                    state.journal = nil
                    try registry.persist(state)
                    break
                }
            }
            try removeAllKnownSecrets(for: previous, from: secrets)
            state.endpoints.removeAll { $0.id == previous.id }
            state.journal = .delete(
                phase: .committed,
                previous: previous,
                currentSecretWasPresent: journal.deleteCurrentSecretWasPresent
            )
            try registry.persist(state)
            state.journal = nil
            try registry.persist(state)

        case (.delete, .committed):
            guard let previous = journal.previousEndpoint,
                  journal.nextEndpoint == nil
            else {
                throw TextModelEndpointRegistryError.invalidMutationJournal
            }
            try removeAllKnownSecrets(for: previous, from: secrets)
            state.endpoints.removeAll { $0.id == previous.id }
            state.journal = nil
            try registry.persist(state)

        case (.revisionMigration, .prepared):
            guard let previous = journal.previousEndpoint,
                  let next = journal.nextEndpoint,
                  isValidRevisionMigration(previous: previous, next: next)
            else {
                throw TextModelEndpointRegistryError.invalidMutationJournal
            }
            if previous.requiresAPIKey {
                try secrets.removeValue(for: TextModelSecretSlot(endpoint: next))
            }
            state.endpoints = replacing(next, with: previous, in: state.endpoints)
            state.journal = nil
            try registry.persist(state)

        case (.revisionMigration, .committed):
            guard let previous = journal.previousEndpoint,
                  let next = journal.nextEndpoint,
                  isValidRevisionMigration(previous: previous, next: next)
            else {
                throw TextModelEndpointRegistryError.invalidMutationJournal
            }
            if previous.requiresAPIKey,
               let legacySecret = try secrets.value(
                    for: TextModelSecretSlot(endpoint: previous)
               ),
               try secrets.value(for: TextModelSecretSlot(endpoint: next))
                    != legacySecret {
                state.endpoints = replacing(next, with: previous, in: state.endpoints)
                state.journal = .revisionMigration(
                    phase: .prepared,
                    previous: previous,
                    next: next
                )
                try registry.persist(state)
                try secrets.removeValue(for: TextModelSecretSlot(endpoint: next))
            }
            state.journal = nil
            try registry.persist(state)
        }
        return state
    }

    private static func migrateRevision(
        for previous: TextModelEndpoint,
        in initialState: TextModelEndpointRegistryState,
        registry: any TextModelEndpointRegistryStoring,
        secrets: any TextModelSecretStoring
    ) throws -> TextModelEndpointRegistryState {
        let next = TextModelEndpoint(
            id: previous.id,
            name: previous.name,
            baseURL: previous.baseURL,
            modelID: previous.modelID,
            requiresAPIKey: previous.requiresAPIKey,
            configurationRevision: UUID(),
            hosting: previous.hosting,
            dialect: previous.dialect,
            contextWindowTokens: previous.contextWindowTokens,
            bedrock: previous.bedrock
        )
        let legacySecret = previous.requiresAPIKey
            ? try secrets.value(for: TextModelSecretSlot(endpoint: previous))
            : nil

        var prepared = initialState
        prepared.journal = .revisionMigration(
            phase: .prepared,
            previous: previous,
            next: next
        )
        try registry.persist(prepared)

        if let legacySecret {
            do {
                let nextSlot = TextModelSecretSlot(endpoint: next)
                try secrets.setValue(legacySecret, for: nextSlot)
                guard try secrets.value(for: nextSlot) == legacySecret else {
                    throw TextModelEndpointRegistryFileError.verificationFailed
                }
            } catch {
                try secrets.removeValue(for: TextModelSecretSlot(endpoint: next))
                var rolledBack = initialState
                rolledBack.journal = nil
                try registry.persist(rolledBack)
                return rolledBack
            }
        }

        var committed = TextModelEndpointRegistryState(
            endpoints: replacing(previous, with: next, in: initialState.endpoints),
            journal: .revisionMigration(
                phase: .committed,
                previous: previous,
                next: next
            )
        )
        try registry.persist(committed)
        committed.journal = nil
        try registry.persist(committed)
        return committed
    }

    private static func removeAllKnownSecrets(
        for endpoint: TextModelEndpoint,
        from secrets: any TextModelSecretStoring
    ) throws {
        for slot in TextModelSecretSlot.allKnownSlots(for: endpoint) {
            try secrets.removeValue(for: slot)
        }
    }

    private static func replacing(
        _ old: TextModelEndpoint,
        with new: TextModelEndpoint,
        in endpoints: [TextModelEndpoint]
    ) -> [TextModelEndpoint] {
        endpoints.map { $0.id == old.id ? new : $0 }
    }

    private static func isValidRevisionMigration(
        previous: TextModelEndpoint,
        next: TextModelEndpoint
    ) -> Bool {
        previous.configurationRevision == nil
            && next.configurationRevision != nil
            && previous.id == next.id
            && previous.name == next.name
            && previous.baseURL == next.baseURL
            && previous.modelID == next.modelID
            && previous.requiresAPIKey == next.requiresAPIKey
            && previous.hosting == next.hosting
            && previous.dialect == next.dialect
            && previous.contextWindowTokens == next.contextWindowTokens
            && previous.bedrock == next.bedrock
    }
}

public final class UserDefaultsTextModelEndpointRegistryStore:
    TextModelEndpointRegistryStoring,
    @unchecked Sendable
{
    public static let defaultStateKey = "steno.textmodel.registry-state"

    private let defaults: UserDefaults
    private let stateKey: String
    private let legacyEndpointsKey: String

    public init(
        defaults: UserDefaults,
        stateKey: String = UserDefaultsTextModelEndpointRegistryStore.defaultStateKey,
        legacyEndpointsKey: String = "steno.textmodel.endpoints"
    ) {
        self.defaults = defaults
        self.stateKey = stateKey
        self.legacyEndpointsKey = legacyEndpointsKey
    }

    public func load() throws -> TextModelEndpointRegistryState {
        if let data = defaults.data(forKey: stateKey) {
            return try JSONDecoder().decode(
                TextModelEndpointRegistryState.self,
                from: data
            )
        }
        guard let legacyData = defaults.data(forKey: legacyEndpointsKey) else {
            return TextModelEndpointRegistryState()
        }
        let endpoints = try JSONDecoder().decode(
            [TextModelEndpoint].self,
            from: legacyData
        )
        let migrated = TextModelEndpointRegistryState(endpoints: endpoints)
        try persist(migrated)
        defaults.removeObject(forKey: legacyEndpointsKey)
        return migrated
    }

    public func persist(_ state: TextModelEndpointRegistryState) throws {
        defaults.set(try JSONEncoder().encode(state), forKey: stateKey)
    }
}

public enum TextModelEndpointRegistryWriteCheckpoint: Equatable, Sendable {
    case beforeWrite
    case afterFileSync
    case afterRenameBeforeDirectorySync
}

public enum TextModelEndpointRegistryFileError: LocalizedError, Equatable {
    case verificationFailed
    case posix(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed:
            "The durable text model endpoint registry could not be verified."
        case let .posix(operation, code):
            "The text model endpoint registry failed during \(operation) (\(code))."
        }
    }
}

public final class AtomicTextModelEndpointRegistryStore:
    TextModelEndpointRegistryStoring,
    @unchecked Sendable
{
    private enum LegacyMigrationPolicy {
        case enabled
        case disabled
    }

    public static let testIsolationEnvironmentKey =
        "STENO_TEST_ISOLATE_TEXT_MODEL_REGISTRY"
    public typealias WriteAction = @Sendable (
        TextModelEndpointRegistryWriteCheckpoint,
        TextModelEndpointRegistryState
    ) throws -> Void

    public static let fileName = "registry-state.json"

    public let fileURL: URL
    private let defaults: UserDefaults
    private let stateKey: String
    private let legacyEndpointsKey: String
    private let legacyMigrationPolicy: LegacyMigrationPolicy
    private let writeAction: WriteAction

    public convenience init(
        fileURL: URL,
        defaults: UserDefaults,
        stateKey: String = UserDefaultsTextModelEndpointRegistryStore.defaultStateKey,
        legacyEndpointsKey: String = "steno.textmodel.endpoints",
        writeAction: @escaping WriteAction = { _, _ in }
    ) {
        self.init(
            fileURL: fileURL,
            defaults: defaults,
            stateKey: stateKey,
            legacyEndpointsKey: legacyEndpointsKey,
            legacyMigrationPolicy: .enabled,
            writeAction: writeAction
        )
    }

    private init(
        fileURL: URL,
        defaults: UserDefaults,
        stateKey: String,
        legacyEndpointsKey: String,
        legacyMigrationPolicy: LegacyMigrationPolicy,
        writeAction: @escaping WriteAction
    ) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.stateKey = stateKey
        self.legacyEndpointsKey = legacyEndpointsKey
        self.legacyMigrationPolicy = legacyMigrationPolicy
        self.writeAction = writeAction
    }

    public convenience init(
        defaults: UserDefaults,
        applicationSupportDirectory: URL? = nil,
        stateKey: String = UserDefaultsTextModelEndpointRegistryStore.defaultStateKey,
        legacyEndpointsKey: String = "steno.textmodel.endpoints",
        writeAction: @escaping WriteAction = { _, _ in }
    ) {
        let base = applicationSupportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let environment = ProcessInfo.processInfo.environment
        self.init(
            fileURL: Self.defaultFileURL(
                applicationSupportDirectory: base,
                temporaryDirectory: FileManager.default.temporaryDirectory,
                environment: environment,
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            ),
            defaults: defaults,
            stateKey: stateKey,
            legacyEndpointsKey: legacyEndpointsKey,
            legacyMigrationPolicy:
                environment[Self.testIsolationEnvironmentKey] == "1"
                    ? .disabled
                    : .enabled,
            writeAction: writeAction
        )
    }

    public static func productionFileURL(
        applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("TextModelEndpoints", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public static func defaultFileURL(
        applicationSupportDirectory: URL,
        temporaryDirectory: URL,
        environment: [String: String],
        processIdentifier: Int32
    ) -> URL {
        guard environment[testIsolationEnvironmentKey] == "1" else {
            return productionFileURL(
                applicationSupportDirectory: applicationSupportDirectory
            )
        }
        return temporaryDirectory
            .appendingPathComponent(
                "StenoTextModelEndpointRegistryTests-\(processIdentifier)",
                isDirectory: true
            )
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public func load() throws -> TextModelEndpointRegistryState {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let state = try loadFile()
            if legacyMigrationPolicy == .enabled {
                clearMigrationValues()
            }
            return state
        }

        guard legacyMigrationPolicy == .enabled else {
            return TextModelEndpointRegistryState()
        }

        let migrated: TextModelEndpointRegistryState
        if let data = defaults.data(forKey: stateKey) {
            migrated = try JSONDecoder().decode(
                TextModelEndpointRegistryState.self,
                from: data
            )
        } else if let data = defaults.data(forKey: legacyEndpointsKey) {
            migrated = TextModelEndpointRegistryState(
                endpoints: try JSONDecoder().decode(
                    [TextModelEndpoint].self,
                    from: data
                )
            )
        } else {
            return TextModelEndpointRegistryState()
        }

        try persist(migrated)
        guard try loadFile() == migrated else {
            throw TextModelEndpointRegistryFileError.verificationFailed
        }
        clearMigrationValues()
        return migrated
    }

    public func persist(_ state: TextModelEndpointRegistryState) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try writeAction(.beforeWrite, state)

        let directoryURL = fileURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw posix("open temporary file")
        }

        var descriptorIsOpen = true
        var renamed = false
        do {
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw posix("fsync temporary file")
            }
            try writeAction(.afterFileSync, state)
            guard Darwin.close(descriptor) == 0 else {
                descriptorIsOpen = false
                throw posix("close temporary file")
            }
            descriptorIsOpen = false

            let renameResult = temporaryURL.path.withCString { temporaryPath in
                fileURL.path.withCString { destinationPath in
                    Darwin.rename(temporaryPath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw posix("rename registry file")
            }
            renamed = true
            try writeAction(.afterRenameBeforeDirectorySync, state)
            try synchronizeDirectory(directoryURL)
        } catch {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            if !renamed {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private func loadFile() throws -> TextModelEndpointRegistryState {
        try JSONDecoder().decode(
            TextModelEndpointRegistryState.self,
            from: Data(contentsOf: fileURL, options: [.mappedIfSafe])
        )
    }

    private func clearMigrationValues() {
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: legacyEndpointsKey)
    }

    private func prepareDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directoryURL.path
        )
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
#endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try mutableDirectoryURL.setResourceValues(values)
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw posix("write temporary file")
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }

    private func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw posix("open registry directory")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posix("fsync registry directory")
        }
    }

    private func posix(_ operation: String) -> TextModelEndpointRegistryFileError {
        .posix(operation: operation, code: errno)
    }
}
