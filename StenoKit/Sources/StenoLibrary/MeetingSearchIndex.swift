import Foundation
import SQLite3
import StenoDomain

/// A hit inside one meeting's content.
public struct MeetingContentHit: Equatable, Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case transcript
        case note
        case report
    }

    public let source: Source
    /// FTS5 snippet around the first match, with "..." at the edges.
    public let snippet: String

    public init(source: Source, snippet: String) {
        self.source = source
        self.snippet = snippet
    }
}

/// Search results grouped per meeting, in stable deterministic order.
public struct MeetingContentGroup: Equatable, Sendable {
    public let meetingID: MeetingID
    public let hits: [MeetingContentHit]

    public init(meetingID: MeetingID, hits: [MeetingContentHit]) {
        self.meetingID = meetingID
        self.hits = hits
    }
}

/// Errors surfaced by the search index.
public enum MeetingSearchIndexError: Error, LocalizedError, Equatable {
    case sqlite(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .sqlite(operation, code):
            return "Search index SQLite error in \(operation) (code \(code))."
        }
    }
}

/// Derived, rebuildable SQLite FTS5 index over meeting content.
///
/// Indexed content per meeting:
/// - the text of the CURRENT transcript revision (`loadCurrentRevision`),
/// - the user note (`MeetingNotesStore`, including the imported legacy note),
/// - the report markdown of the most recent report run.
///
/// Never indexed: audio, embeddings, person metadata, or any identity data
/// beyond names already present in transcript/note/report text. The index
/// lives in a single SQLite file under the library layout and can be deleted
/// at any time; `rebuild(library:)` recreates it from the library.
///
/// # Integration points for the orchestrator
///
/// The index exposes exactly two maintenance entry points; call sites are
/// wired by the orchestrator, not by this file:
///
/// 1. `update(meetingID:library:)` - call after every job completion that
///    touches a meeting (final ASR run, diarization, report run, note edit).
///    A fingerprint check makes this a no-op when nothing changed, so calling
///    it unconditionally is cheap. Also suitable for a startup sweep over
///    recently changed meetings.
/// 2. `rebuild(library:)` - call once at startup right after `Library.open`
///    (also heals a missing/corrupt/older-schema index file). Performance
///    targets: incremental < 2 s per meeting batch, queries < 50 ms at 100
///    meetings.
///
/// Querying goes through `search(_:limit:)`, which returns results grouped
/// per meeting; the sidebar routes "all content" scope queries here.
public actor MeetingSearchIndex {
    private nonisolated let fileURL: URL
    private nonisolated(unsafe) var handle: OpaquePointer?

    // MARK: Lifecycle

    /// Opens (creating if missing) the index file under the given layout.
    /// A file written by an older schema version is wiped and recreated;
    /// callers should follow with `rebuild(library:)`.
    public init(layout: LibraryLayout) throws {
        fileURL = layout.searchIndexFile
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try openDatabase()
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    private nonisolated func openDatabase() throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &db, flags, nil) == SQLITE_OK else {
            let code = sqlite3_errcode(db)
            sqlite3_close_v2(db)
            throw MeetingSearchIndexError.sqlite(operation: "open", code: code)
        }
        handle = db
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec(SearchIndexSchema.metaDDL)
        try exec(SearchIndexSchema.contentDDL)
        try exec(SearchIndexSchema.stateDDL)

        if storedSchemaVersion() != SearchIndexSchema.schemaVersion {
            // Derived data: drop everything and start fresh rather than
            // migrating an index nobody needs preserved.
            try exec("DROP TABLE IF EXISTS content")
            try exec("DROP TABLE IF EXISTS index_state")
            try exec(SearchIndexSchema.contentDDL)
            try exec(SearchIndexSchema.stateDDL)
            try exec(
                "INSERT OR REPLACE INTO index_meta(key, value) VALUES ('schema_version', '\(SearchIndexSchema.schemaVersion)')"
            )
        }
    }

    private nonisolated func storedSchemaVersion() -> Int? {
        guard let statement = prepare(
            "SELECT value FROM index_meta WHERE key = 'schema_version'"
        ) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: Maintenance API (orchestrator wires the call sites)

    /// Incrementally reindexes one meeting from the current library state.
    ///
    /// Computes a fingerprint of the sources (current revision ID, notes
    /// digest, latest report digest). When nothing changed, this is a no-op,
    /// making it safe to call after every job completion. When the meeting no
    /// longer exists in the library, its rows are removed.
    public func update(meetingID: MeetingID, library: Library) async throws {
        let document = try await Self.indexDocument(meetingID: meetingID, library: library)
        let previous = try readFingerprint(meetingID: meetingID)
        guard previous != document.fingerprint else { return }
        try replaceRows(document: document)
    }

    /// Drops and recreates the whole index from the library. Safe to run on
    /// every startup; also heals missing or corrupt index files.
    public func rebuild(library: Library) async throws {
        try exec("DELETE FROM content")
        try exec("DELETE FROM index_state")
        for meeting in try await library.listMeetings() {
            let document = try await Self.indexDocument(
                meetingID: meeting.id,
                library: library
            )
            try replaceRows(document: document)
        }
    }

    // MARK: Query API

    /// Full-text query returning `(meetingID, snippet)` hits grouped by
    /// meeting. Ordering is stable and deterministic: groups are ordered by
    /// best hit rank (FTS5 `rank`), ties broken by meeting ID string so the
    /// same corpus always yields the same order.
    ///
    /// The query is folded with the same normalization as the sidebar title
    /// filter (`MeetingSearch.normalized`): case-, diacritic- and width-
    /// insensitive. Each whitespace-separated term becomes a quoted FTS5
    /// token so raw user input never changes the query syntax.
    public func search(_ query: String, limit: Int = 50) async throws -> [MeetingContentGroup] {
        let matchQuery = Self.matchExpression(for: query)
        guard !matchQuery.isEmpty else { return [] }

        let sql = """
            SELECT meeting_id, source, snippet(content, 0, '', '', '...', 16), rank
            FROM content WHERE content MATCH ? ORDER BY rank LIMIT ?
            """
        guard let statement = prepare(sql) else {
            throw lastError(operation: "prepare search")
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, matchQuery)
        sqlite3_bind_int64(statement, 2, Int64(max(1, limit)))

        struct RawHit {
            let meetingID: String
            let source: MeetingContentHit.Source
            let snippet: String
            let rank: Double
        }
        var rawHits: [RawHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let meetingCStr = sqlite3_column_text(statement, 0),
                let snippetCStr = sqlite3_column_text(statement, 2)
            else { continue }
            let sourceRaw = sqlite3_column_text(statement, 1)
                .map { String(cString: $0) } ?? ""
            rawHits.append(
                RawHit(
                    meetingID: String(cString: meetingCStr),
                    source: MeetingContentHit.Source(rawValue: sourceRaw) ?? .transcript,
                    snippet: String(cString: snippetCStr),
                    rank: sqlite3_column_double(statement, 3)
                )
            )
        }

        // Stable ordering: rank asc (better first), then meeting ID, then
        // source name as final tiebreaker so repeated runs are identical.
        rawHits.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.meetingID != b.meetingID { return a.meetingID < b.meetingID }
            return a.source.rawValue < b.source.rawValue
        }

        let sourceRank = Dictionary(uniqueKeysWithValues: MeetingContentHit.Source.allCases.enumerated().map {
            ($1, $0)
        })

        var order: [String] = []
        var grouped: [String: [MeetingContentHit]] = [:]
        for hit in rawHits {
            if grouped[hit.meetingID] == nil { order.append(hit.meetingID) }
            grouped[hit.meetingID, default: []].append(
                MeetingContentHit(source: hit.source, snippet: hit.snippet)
            )
        }
        return order.compactMap { id in
            guard let uuid = UUID(uuidString: id), var hits = grouped[id] else {
                return nil
            }
            // Within one meeting, hits are presented in the canonical
            // source order (transcript, note, report). Meeting ORDER above
            // still follows the best hit rank; only the per-meeting list is
            // canonical, so it never depends on bm25 length coincidences.
            hits.sort { sourceRank[$0.source]! < sourceRank[$1.source]! }
            return MeetingContentGroup(meetingID: MeetingID(rawValue: uuid), hits: hits)
        }
    }

    /// Characters that carry syntactic meaning in an FTS5 query (grouping,
    /// column filters, boosts, option lists). If the raw user input contains
    /// any of these we stop treating whitespace as a term separator and keep
    /// the entire normalized query as ONE quoted phrase: raw input must
    /// never be able to alter the query grammar. Plain double quotes are not
    /// in this set - they are already neutralized below by doubling.
    private static let fts5SyntaxCharacters = CharacterSet(charactersIn: "()[]{}^:")

    /// Builds the FTS5 MATCH expression for a raw user query.
    static func matchExpression(for query: String) -> String {
        let folded = MeetingSearch.normalized(query)
        guard !folded.isEmpty else { return "" }

        func quoted(_ term: String) -> String {
            "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        if folded.unicodeScalars.contains(where: fts5SyntaxCharacters.contains) {
            return quoted(folded)
        }
        return folded
            .split(whereSeparator: \.isWhitespace)
            .map { quoted(String($0)) }
            .joined(separator: " ")
    }

    // MARK: Content extraction

    /// Everything the index knows about one meeting, extracted from the
    /// library. Internal so tests can inspect fingerprints indirectly.
    struct IndexDocument {
        var meetingID: MeetingID
        var entries: [(source: MeetingContentHit.Source, body: String)]
        var fingerprint: IndexFingerprint
    }

    struct IndexFingerprint: Equatable {
        var revisionID: String
        var notesDigest: String
        var reportDigest: String
    }

    static func indexDocument(
        meetingID: MeetingID,
        library: Library
    ) async throws -> IndexDocument {
        var entries: [(source: MeetingContentHit.Source, body: String)] = []
        var revisionID = ""
        var notesDigest = ""
        var reportDigest = ""

        // Current transcript revision. A missing revision simply contributes
        // no rows - meetings before their first transcription stay searchable
        // through note/report once those exist.
        if let revision = try? await library.loadCurrentRevision(meetingID: meetingID) {
            let text = revision.turns.flatMap { turn in
                turn.segments.map(\.text)
            }.joined(separator: " ")
            if !text.isEmpty {
                entries.append((source: .transcript, body: text))
            }
            revisionID = revision.id.description
        }

        // User note (actor call; readers fall back to the imported legacy
        // note until the user edits the note themselves).
        let notesStore = MeetingNotesStore(layout: library.layout)
        if let notes = try await notesStore.notes(meetingID), !notes.isEmpty {
            entries.append((source: .note, body: notes))
        }
        notesDigest = digest(notesDigestSource(meetingID: meetingID, layout: library.layout))

        // Most recent report markdown, if any.
        if let report = Self.latestReportText(meetingID: meetingID, layout: library.layout),
           !report.text.isEmpty
        {
            entries.append((source: .report, body: report.text))
            reportDigest = report.digest
        }

        return IndexDocument(
            meetingID: meetingID,
            entries: entries,
            fingerprint: IndexFingerprint(
                revisionID: revisionID,
                notesDigest: notesDigest,
                reportDigest: reportDigest
            )
        )
    }

    private static func notesDigestSource(
        meetingID: MeetingID,
        layout: LibraryLayout
    ) -> String {
        // Digest the actual note bytes so edits invalidate deterministically;
        // include the imported legacy note, which is what readers fall back to.
        let own = (try? Data(contentsOf: layout.userNotes(meetingID))) ?? Data()
        let legacy = (try? Data(contentsOf: layout.legacyUserNotes(meetingID))) ?? Data()
        return "\(own.count):\(String(decoding: own, as: UTF8.self))|\(legacy.count):\(String(decoding: legacy, as: UTF8.self))"
    }

    private static func digest(_ source: String) -> String {
        // A plain stable hash is enough: we only need change detection, and
        // keeping the state row small matters more than collision resistance.
        var hash: UInt64 = 1_469_598_103_934_665_6037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "\(source.utf8.count)-\(hash)"
    }

    private static func latestReportText(
        meetingID: MeetingID,
        layout: LibraryLayout
    ) -> (text: String, digest: String)? {
        let directory = layout.reportsDirectory(meetingID)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).filter { $0.pathExtension == "json" }
        guard let newest = files.sorted(by: { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }).first else { return nil }

        guard let data = try? Data(contentsOf: newest),
              let result = try? JSONDecoder().decode(TemplateResult.self, from: data)
        else { return nil }
        return (
            text: result.markdown,
            digest: digest("\(newest.lastPathComponent):\(result.markdown)")
        )
    }

    // MARK: SQLite plumbing

    private func readFingerprint(meetingID: MeetingID) throws -> IndexFingerprint? {
        guard let statement = prepare(
            "SELECT revision_id, notes_digest, report_digest FROM index_state WHERE meeting_id = ?"
        ) else {
            throw lastError(operation: "prepare fingerprint read")
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, meetingID.description)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return IndexFingerprint(
            revisionID: columnText(statement, 0),
            notesDigest: columnText(statement, 1),
            reportDigest: columnText(statement, 2)
        )
    }

    private func replaceRows(document: IndexDocument) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            let meetingIDText = document.meetingID.description
            // Identifiers are lowercase UUID strings; safe to interpolate into
            // SQL, unlike free text which always goes through bound parameters.
            try exec("DELETE FROM content WHERE meeting_id = '\(meetingIDText)'")
            for entry in document.entries {
                let insert =
                    "INSERT INTO content(body, meeting_id, source) VALUES (?, '\(meetingIDText)', '\(entry.source.rawValue)')"
                guard let statement = prepare(insert) else {
                    throw lastError(operation: "prepare insert")
                }
                defer { sqlite3_finalize(statement) }
                bindText(statement, 1, entry.body)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw lastError(operation: "insert row")
                }
            }
            let upsert = """
                INSERT INTO index_state(meeting_id, revision_id, notes_digest, report_digest)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(meeting_id) DO UPDATE SET
                    revision_id = excluded.revision_id,
                    notes_digest = excluded.notes_digest,
                    report_digest = excluded.report_digest
                """
            guard let statement = prepare(upsert) else {
                throw lastError(operation: "prepare state upsert")
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, document.meetingID.description)
            bindText(statement, 2, document.fingerprint.revisionID)
            bindText(statement, 3, document.fingerprint.notesDigest)
            bindText(statement, 4, document.fingerprint.reportDigest)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError(operation: "upsert state")
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private nonisolated func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw lastError(operation: "exec: \(sql.prefix(40))")
        }
    }

    private nonisolated func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private nonisolated func lastError(operation: String) -> MeetingSearchIndexError {
        .sqlite(operation: operation, code: sqlite3_extended_errcode(handle))
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, Self.sqlTransient)
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    /// Swift does not expose SQLITE_TRANSIENT; this mirrors its definition
    /// ((sqlite3_destructor_type) -1) so SQLite copies bound strings.
    private static let sqlTransient =
        unsafeBitCast(OpaquePointer(bitPattern: ~UInt(0)), to: sqlite3_destructor_type.self)
}
