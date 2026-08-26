import Foundation

/// Static definition of the derived full-text search index.
///
/// The index is ONLY a derived, always-rebuildable artifact: it indexes the
/// text of the current transcript revision, the user note, and the report
/// text per meeting. Never indexed: audio, embeddings, person metadata, or
/// identity information beyond names that already appear in transcript text.
/// Deleting the index file is always safe - the next `rebuild()` recreates it.
public enum SearchIndexSchema {
    /// File name within the library root directory.
    public static let fileName = "search-index.sqlite"

    /// Physical schema version. When the DDL changes, bump this number: an
    /// index file with an older version is deleted and rebuilt from scratch
    /// (derived data, nothing lost).
    public static let schemaVersion = 1

    /// FTS5 table: only `body` is indexed; `meeting_id` and `source` are
    /// UNINDEXED columns used for filtering and snippet attribution.
    /// `source` is "transcript", "note", or "report".
    ///
    /// The tokenizer folds diacritics (remove_diacritics 2); unicode61 also
    /// handles case folding. Additionally, query terms are folded through
    /// `MeetingSearch.normalized` (including width) before matching, so
    /// "Mueller" and "Müller" behave exactly like in the title filter.
    public static let contentDDL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS content USING fts5(
            body,
            meeting_id UNINDEXED,
            source UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
        )
        """

    /// Fingerprint table for incremental updates: per meeting, the IDs or
    /// digests of the sources indexed last time. If one changes, that
    /// meeting's rows are replaced; if none change, the update is a no-op.
    public static let stateDDL = """
        CREATE TABLE IF NOT EXISTS index_state (
            meeting_id TEXT PRIMARY KEY,
            revision_id TEXT NOT NULL,
            notes_digest TEXT NOT NULL,
            report_digest TEXT NOT NULL
        )
        """

    /// Metadata table holding the schema version of this index file.
    public static let metaDDL = """
        CREATE TABLE IF NOT EXISTS index_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
}

extension LibraryLayout {
    /// Path of the index file under the library layout. The file is created
    /// when the index opens if it is missing.
    ///
    /// Deliberately an extension here instead of a property in
    /// LibraryLayout.swift: T4 does not own that file. The orchestrator can
    /// move this property into LibraryLayout.swift later; no caller changes.
    public var searchIndexFile: URL {
        root.appendingPathComponent(SearchIndexSchema.fileName)
    }
}
