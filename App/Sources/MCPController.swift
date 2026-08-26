import Foundation
import Observation
import Security
import StenoDomain
import StenoIntelligence
import StenoLibrary
import StenoPipeline
import SwiftUI

// MARK: - Settings storage

/// Defaults and UserDefaults keys for the local MCP server surface. All
/// persisted values follow the shared `steno.*` convention; the API key
/// never touches defaults - it lives in the Keychain only.
enum MCPSettingsKeys {
    static let enabled = "steno.mcp.enabled"
    static let port = "steno.mcp.port"
    static let defaultPort = 27_127
}

/// Generic-password Keychain entry holding the MCP bearer key. Mirrors the
/// storage shape of `TextModelKeychain`: one service, fixed account.
struct MCPKeychainStore {
    static let service = "org.steno.mcp"
    static let account = "server-api-key"

    func loadKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func storeKey(_ key: String) throws {
        deleteKey()
        var query = baseQuery()
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MCPKeychainError(status: status)
        }
    }

    func deleteKey() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return }
    }

    /// Mints a fresh bearer key: 32 random bytes, base64url, like the legacy
    /// `crypto.randomBytes(32).toString('base64url')`.
    static func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let base64 = Data(bytes).base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

struct MCPKeychainError: Error {
    let status: OSStatus
}

// MARK: - Library facade

/// Maps the MCP tool facade onto the Library and the library chat pipeline.
///
/// Field mapping is honest about what this library stores: the meeting's
/// latest report markdown stands in for `summary`, user notes map to
/// `user_notes`, and attendee names resolve through the identity store.
/// Transcripts come from the current revision; reports never contain one.
@MainActor
final class MCPLibraryFacade: MCPMeetingFacade {
    private let runtimeProvider: @MainActor () async -> PipelineRuntime?
    private let makeAnswerer: @MainActor () throws -> any LiveQueryAnswering

    init(
        runtimeProvider: @escaping @MainActor () async -> PipelineRuntime?,
        makeAnswerer: @escaping @MainActor () throws -> any LiveQueryAnswering
    ) {
        self.runtimeProvider = runtimeProvider
        self.makeAnswerer = makeAnswerer
    }

    private static let dateFormatter = ISO8601DateFormatter()

    // MARK: Reads

    func listMeetings(limit: Int) async throws -> [MCPMeetingSummary] {
        try Array(await summaries().prefix(limit))
    }

    func getMeeting(meetingID: String) async throws -> MCPMeetingDetail {
        let meeting = try await findMeeting(idString: meetingID)
        return try await detail(for: meeting)
    }

    func getTranscript(meetingID: String) async throws -> (title: String, text: String) {
        let meeting = try await findMeeting(idString: meetingID)
        guard let runtime = await runtimeProvider() else {
            throw MCPFacadeError.backendFailure
        }
        let revision = try? await runtime.library.loadCurrentRevision(meetingID: meeting.id)
        let text = revision.map(Self.transcriptText) ?? ""
        return (meeting.title, text)
    }

    func search(query: String, limit: Int) async throws -> [MCPSearchHit] {
        let queryLower = query.lowercased()
        var hits: [MCPSearchHit] = []
        for row in try await searchableRows() {
            let meeting = row.meeting
            let report = row.report
            let notes = row.notes
            let attendeeNames = row.attendees
            let folderNames = row.folders
            var matchedFields: [String] = []
            func matches(_ field: String, _ value: String) {
                if !value.isEmpty, value.lowercased().contains(queryLower) {
                    matchedFields.append(field)
                }
            }
            matches("title", meeting.title)
            matches("summary", report ?? "")
            matches("key_points", "")
            matches("action_items", "")
            matches("user_notes", notes ?? "")
            matches("attendees", attendeeNames.joined(separator: " "))
            matches("folders", folderNames.joined(separator: " "))

            if !matchedFields.isEmpty {
                hits.append(MCPSearchHit(
                    meeting: Self.summary(
                        from: meeting,
                        date: Self.dateFormatter.string(from: meeting.createdAt),
                        durationSeconds: nil,
                        folders: folderNames,
                        attendees: attendeeNames
                    ),
                    matchedFields: matchedFields
                ))
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    func folders() async throws -> [MCPFolderInfo] {
        guard let runtime = await runtimeProvider() else {
            throw MCPFacadeError.backendFailure
        }
        let store = try await FolderStore.open(layout: runtime.library.layout)
        return try await store.listFolders().map {
            MCPFolderInfo(id: $0.id.rawValue.uuidString, name: $0.name)
        }
    }

    // MARK: Cross-note chat

    func ask(
        question: String,
        meetingIDs: [String]?,
        folderID: String?
    ) async throws -> String {
        guard let runtime = await runtimeProvider() else {
            throw MCPFacadeError.backendFailure
        }

        var scope: [Meeting]
        let allMeetings = (try? await runtime.library.listMeetings()) ?? []
        if let meetingIDs {
            // Unknown identifiers fail loudly instead of silently widening
            // the corpus.
            let requested = Set(meetingIDs.compactMap(UUID.init(uuidString:)))
            guard requested.count == meetingIDs.count, !requested.isEmpty else {
                throw MCPFacadeError.invalidID("meeting_ids")
            }
            scope = allMeetings.filter { requested.contains($0.id.rawValue) }
            guard !scope.isEmpty else {
                throw MCPFacadeError.invalidID("meeting_ids")
            }
        } else if let folderID {
            guard let uuid = UUID(uuidString: folderID),
                  let folder = try await FolderStore.open(layout: runtime.library.layout)
                  .folder(FolderID(rawValue: uuid))
            else {
                throw MCPFacadeError.invalidID("folder_id")
            }
            scope = allMeetings.filter { $0.folderID == folder.id }
        } else {
            scope = allMeetings
        }

        let notesStore = MeetingNotesStore(layout: runtime.library.layout)
        let reportStore = TemplateResultStore(layout: runtime.library.layout)
        var sources: [LibraryChatMeetingSource] = []
        for meeting in scope {
            let notes = try? await notesStore.notes(meeting.id)
            let reports = (try? reportStore.listWithRepairOutcome(meetingID: meeting.id))?
                .results ?? []
            let latestMarkdown = reports
                .max { $0.result.createdAt < $1.result.createdAt }?
                .result.markdown
            sources.append(LibraryChatMeetingSource(
                title: meeting.title,
                createdAt: meeting.createdAt,
                userNotes: notes,
                reportMarkdown: latestMarkdown
            ))
        }

        let prompt: LiveQueryPrompt
        do {
            prompt = try LibraryChatContextBuilder().assemble(message: question, sources: sources)
        } catch {
            throw MCPFacadeError.backendFailure
        }
        let answerer = try makeAnswerer()

        var answer = ""
        let stream = answerer.stream(
            systemInstructions: prompt.systemInstructions,
            userPrompt: prompt.userPrompt
        )
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                answer += chunk
                guard answer.utf8.count <= LibraryChatLimits.maximumAnswerBytes else {
                    throw MCPFacadeError.backendFailure
                }
            }
        } catch is MCPFacadeError {
            throw MCPFacadeError.backendFailure
        } catch is CancellationError {
            throw MCPFacadeError.backendFailure
        } catch {
            throw MCPFacadeError.backendFailure
        }
        return answer
    }

    // MARK: Row assembly

    private struct SearchRow {
        let meeting: Meeting
        let report: String?
        let notes: String?
        let attendees: [String]
        let folders: [String]
    }

    private func searchableRows() async throws -> [SearchRow] {
        guard let runtime = await runtimeProvider() else {
            throw MCPFacadeError.backendFailure
        }
        let meetings = try await runtime.library.listMeetings()
        let namesByID = try await personNames(runtime: runtime)
        let namesByFolder = try await folderNames(runtime: runtime)

        let notesStore = MeetingNotesStore(layout: runtime.library.layout)
        let reportStore = TemplateResultStore(layout: runtime.library.layout)

        var rows: [SearchRow] = []
        for meeting in meetings {
            let notes = try? await notesStore.notes(meeting.id)
            let reports = (try? reportStore.listWithRepairOutcome(meetingID: meeting.id))?.results ?? []
            let latest = reports.max { $0.result.createdAt < $1.result.createdAt }?.result.markdown
            let attendeeIDs = meeting.participantIDs + meeting.additionalParticipantIDs
            let attendeeNames = attendeeIDs.compactMap { namesByID[$0] }
            let folderNames = meeting.folderID.flatMap { namesByFolder[$0] }.map { [$0] } ?? []
            rows.append(SearchRow(
                meeting: meeting,
                report: latest,
                notes: notes,
                attendees: attendeeNames,
                folders: folderNames
            ))
        }
        return rows
    }

    private func summaries() async throws -> [MCPMeetingSummary] {
        guard let runtime = await runtimeProvider() else {
            throw MCPFacadeError.backendFailure
        }
        let meetings = try await runtime.library.listMeetings()
        let namesByID = try await personNames(runtime: runtime)
        let namesByFolder = try await folderNames(runtime: runtime)

        var results: [MCPMeetingSummary] = []
        for meeting in meetings {
            let assets = (try? await runtime.library.listMediaAssets(meetingID: meeting.id)) ?? []
            let seconds = assets.isEmpty
                ? nil
                : Int(AppendedTimeline.timelineEnd(of: assets).rounded())
            results.append(Self.summary(
                from: meeting,
                date: Self.dateFormatter.string(from: meeting.createdAt),
                durationSeconds: seconds,
                folders: meeting.folderID.flatMap { namesByFolder[$0] }.map { [$0] } ?? [],
                attendees: (meeting.participantIDs + meeting.additionalParticipantIDs)
                    .compactMap { namesByID[$0] }
            ))
        }
        return results
    }

    private func findMeeting(idString: String) async throws -> Meeting {
        guard let runtime = await runtimeProvider(), let uuid = UUID(uuidString: idString) else {
            throw MCPFacadeError.invalidID(idString)
        }
        let wanted = MeetingID(rawValue: uuid)
        let meetings = try await runtime.library.listMeetings()
        guard let meeting = meetings.first(where: { $0.id == wanted }) else {
            throw MCPFacadeError.invalidID(idString)
        }
        return meeting
    }

    private func detail(for meeting: Meeting) async throws -> MCPMeetingDetail {
        guard let runtime = await runtimeProvider() else {
            throw MCPFacadeError.backendFailure
        }
        let notesStore = MeetingNotesStore(layout: runtime.library.layout)
        let reportStore = TemplateResultStore(layout: runtime.library.layout)
        let notes = try? await notesStore.notes(meeting.id)
        let reports = (try? reportStore.listWithRepairOutcome(meetingID: meeting.id))?.results ?? []
        let latest = reports.max { $0.result.createdAt < $1.result.createdAt }?.result.markdown
        let assets = (try? await runtime.library.listMediaAssets(meetingID: meeting.id)) ?? []
        let seconds = assets.isEmpty ? nil : Int(AppendedTimeline.timelineEnd(of: assets).rounded())
        let namesByID = try await personNames(runtime: runtime)
        let namesByFolder = try await folderNames(runtime: runtime)

        return MCPMeetingDetail(
            summary: Self.summary(
                from: meeting,
                date: Self.dateFormatter.string(from: meeting.createdAt),
                durationSeconds: seconds,
                folders: meeting.folderID.flatMap { namesByFolder[$0] }.map { [$0] } ?? [],
                attendees: (meeting.participantIDs + meeting.additionalParticipantIDs)
                    .compactMap { namesByID[$0] }
            ),
            reportMarkdown: latest ?? "",
            keyPoints: [],
            actionItems: [],
            userNotes: notes
        )
    }

    private func personNames(runtime: PipelineRuntime) async throws -> [PersonID: String] {
        let store = try IdentityStore(layout: runtime.library.layout)
        let persons = (try? await store.listPersons()) ?? []
        return Dictionary(uniqueKeysWithValues: persons.map { ($0.id, $0.displayName) })
    }

    private func folderNames(runtime: PipelineRuntime) async throws -> [FolderID: String] {
        let store = try await FolderStore.open(layout: runtime.library.layout)
        let folders = (try? await store.listFolders()) ?? []
        return Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
    }

    private static func summary(
        from meeting: Meeting,
        date: String,
        durationSeconds: Int?,
        folders: [String],
        attendees: [String]
    ) -> MCPMeetingSummary {
        MCPMeetingSummary(
            id: meeting.id.rawValue.uuidString,
            title: meeting.title,
            date: date,
            durationSeconds: durationSeconds,
            folders: folders,
            attendees: attendees
        )
    }

    private static func transcriptText(_ revision: TranscriptRevision) -> String {
        revision.turns.flatMap { turn in
            turn.segments.map(\.text)
        }
        .joined(separator: "\n")
    }
}

// MARK: - Controller

/// Owns the local MCP server lifecycle plus every settings decision behind
/// it: enable/disable, port validation, key reveal/regenerate/custom paste.
/// The key lives exclusively in the Keychain and is never logged anywhere.
@MainActor
@Observable
final class MCPController {
    private let facade: MCPLibraryFacade
    private let keychain = MCPKeychainStore()
    private var server: MCPServer?

    private(set) var running = false
    private(set) var startError: String?

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: MCPSettingsKeys.enabled) }
    }

    var portInput: String {
        didSet {
            guard portInput != oldValue else { return }
            guard let port = validatedPort else { return }
            UserDefaults.standard.set(port, forKey: MCPSettingsKeys.port)
            // A running server picks the new port up immediately.
            if running {
                Task { await restartOnValidatedPort() }
            }
        }
    }

    var isKeyRevealed = false
    var isRegenerateConfirmPresented = false
    var isCustomKeyEntryActive = false
    var customKeyDraft = ""

    init(
        runtimeProvider: @escaping @MainActor () async -> PipelineRuntime?,
        makeAnswerer: @escaping @MainActor () throws -> any LiveQueryAnswering
    ) {
        facade = MCPLibraryFacade(
            runtimeProvider: runtimeProvider,
            makeAnswerer: makeAnswerer
        )
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: MCPSettingsKeys.enabled)
        let storedPort = defaults.integer(forKey: MCPSettingsKeys.port)
        portInput = String(storedPort > 0 ? storedPort : MCPSettingsKeys.defaultPort)

        // Re-enable at launch when the toggle was left on.
        if isEnabled {
            Task { await enableFromPersistedState() }
        }
    }

    // MARK: Derived state

    var validatedPort: Int? {
        guard let port = Int(portInput.trimmingCharacters(in: .whitespaces)),
              (1_024...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    var portErrorMessage: String? {
        validatedPort == nil ? "Port must be an integer between 1024 and 65535." : nil
    }

    var hasKey: Bool { keychain.loadKey() != nil }

    var endpointURL: String {
        "http://127.0.0.1:\(validatedPort.map(String.init) ?? portInput)/mcp"
    }

    /// Client configuration snippet shown in settings; copy stays disabled
    /// while the server is stopped because a dead endpoint helps nobody.
    var clientSnippet: String {
        """
        {
          "mcpServers": {
            "steno": {
              "url": "\(endpointURL)",
              "headers": {
                "Authorization": "Bearer YOUR_API_KEY"
              }
            }
          }
        }
        """
    }

    // MARK: Lifecycle

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        Task {
            if enabled {
                await startServer()
            } else {
                await stopServer()
            }
        }
    }

    private func enableFromPersistedState() async {
        await startServer()
    }

    private func startServer() async {
        guard let port = validatedPort else {
            startError = "Port must be an integer between 1024 and 65535."
            isEnabled = false
            return
        }
        // First enable mints the bearer key locally; it never leaves the
        // Keychain afterwards.
        if keychain.loadKey() == nil {
            do {
                try keychain.storeKey(MCPKeychainStore.generateKey())
            } catch {
                startError = "The MCP API key could not be stored in the Keychain."
                isEnabled = false
                return
            }
        }

        let toolkit = MCPToolkit(facade: facade)
        let newServer = MCPServer(
            port: UInt16(port),
            apiKeyProvider: { [keychain] in keychain.loadKey() }
        ) { headers, body in
            await mcpHandleRPC(
                headers: headers,
                body: body,
                tools: toolkit.definitions,
                callTool: { name, arguments in
                    await toolkit.call(name: name, arguments: arguments)
                },
                serverInfo: ["name": "steno"]
            )
        }
        do {
            try await newServer.start()
            server = newServer
            running = true
            startError = nil
        } catch {
            startError = "The MCP server could not bind to port \(port)."
            isEnabled = false
        }
    }

    private func stopServer() async {
        await server?.stop()
        server = nil
        running = false
    }

    private func restartOnValidatedPort() async {
        await stopServer()
        await startServer()
    }

    // MARK: Key flows

    /// Reveals or re-masks the key. The revealed value comes straight from
    /// the Keychain at render time; nothing is cached in view state.
    func revealedKey() -> String? {
        keychain.loadKey()
    }

    /// Replaces the key after the confirmation dialog. Active clients keep
    /// working until they next authenticate - then they fail with 401.
    func regenerateKey() {
        do {
            try keychain.storeKey(MCPKeychainStore.generateKey())
        } catch {
            startError = "The MCP API key could not be stored in the Keychain."
        }
    }

    /// Stores a user-pasted custom key. Empty input is rejected; the caller
    /// keeps the editor open so the user can correct it.
    func saveCustomKey() -> Bool {
        let trimmed = customKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try keychain.storeKey(trimmed)
        } catch {
            startError = "The MCP API key could not be stored in the Keychain."
            return false
        }
        customKeyDraft = ""
        isCustomKeyEntryActive = false
        return true
    }

    func cancelCustomKey() {
        customKeyDraft = ""
        isCustomKeyEntryActive = false
    }
}
