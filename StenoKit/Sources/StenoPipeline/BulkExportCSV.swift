import Foundation

/// Bulk export primitives shared by the Settings "Export all meetings" actions.
///
/// Pure and side-effect free on purpose: the app layer gathers the meeting
/// data, this module decides how it becomes CSV bytes and whether a target
/// directory is safe to write into. Parity with the legacy `export_all`
/// command (simple_recorder ~L5639, tests/test_export_all.py).
public enum BulkExportCSV {
    /// Exact header row, byte-for-byte parity with the legacy exporter.
    public static let headerLine = "title,date,duration,folders,attendees,summary,transcript"

    /// One flattened meeting record. All fields arrive pre-resolved so the
    /// builder never needs library or filesystem access.
    public struct MeetingRow: Equatable, Sendable {
        public var title: String
        /// ISO-8601 timestamp of the meeting, matching the legacy
        /// `processed_at` column content; empty when unknown.
        public var date: String
        /// Whole seconds; nil renders as an empty cell.
        public var durationSeconds: Int?
        public var folders: [String]
        public var attendees: [String]
        public var summary: String
        public var transcript: String

        public init(
            title: String,
            date: String = "",
            durationSeconds: Int? = nil,
            folders: [String] = [],
            attendees: [String] = [],
            summary: String = "",
            transcript: String = ""
        ) {
            self.title = title
            self.date = date
            self.durationSeconds = durationSeconds
            self.folders = folders
            self.attendees = attendees
            self.summary = summary
            self.transcript = transcript
        }
    }

    /// Guards against spreadsheet formula/DDE interpretation of a leading
    /// trigger character (=, +, -, @, TAB, CR), which otherwise makes Excel
    /// evaluate cell content or fail with #NAME?. A leading apostrophe is
    /// the established mitigation and round-trips harmlessly elsewhere.
    public static func guardedCell(_ value: String) -> String {
        guard let first = value.first,
              first == "=" || first == "+" || first == "-" || first == "@"
                  || first == "\t" || first == "\r"
        else { return value }
        return "'" + value
    }

    /// RFC 4180 field quoting: quotes appear only when needed and inner
    /// quotes are doubled, so commas, quotes and newlines survive a
    /// spreadsheet round-trip unchanged.
    public static func quotedField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"")
                  || value.contains("\n") || value.contains("\r")
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Legacy list rendering: ", " between entries.
    public static func joinedList(_ values: [String]) -> String {
        values.joined(separator: ", ")
    }

    static func cell(_ value: String) -> String {
        quotedField(guardedCell(value))
    }

    /// Renders rows plus the fixed header as CRLF-free CSV text terminated
    /// by a trailing newline. The returned line count is exactly
    /// `rows.count + 1`.
    public static func build(_ rows: [MeetingRow]) -> String {
        var lines = [headerLine]
        for row in rows {
            let duration = row.durationSeconds.map(String.init) ?? ""
            let fields = [
                cell(row.title),
                cell(row.date),
                cell(duration),
                cell(joinedList(row.folders)),
                cell(joinedList(row.attendees)),
                cell(row.summary),
                cell(row.transcript),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Destination safety for bulk exports. A bulk export must never land inside
/// the library itself - writing there would make exported copies look like
/// library data and risk feeding them back into later exports.
public enum BulkExportPathSafety {
    public static let containmentErrorMessage =
        "Cannot export directly into the Steno library folder"

    /// Returns the rejection message when `targetDirectory` resolves inside
    /// (or equals) `libraryDirectory`, nil when the destination is safe.
    ///
    /// Both paths are resolved through the real filesystem (symlinks and
    /// `..` collapsed) before comparison, so an alias pointing into the
    /// library is caught just like a direct subfolder pick.
    public static func rejectionReason(
        targetDirectory: URL,
        libraryDirectory: URL
    ) -> String? {
        func realpath(_ url: URL) -> URL {
            // resolvingSymlinksInPath resolves as much of the path as
            // exists, so it also copes with a not-yet-created destination.
            url.standardizedFileURL.resolvingSymlinksInPath()
        }
        let target = realpath(targetDirectory).path
        let library = realpath(libraryDirectory).path
        guard target.hasPrefix(library) else { return nil }
        if target == library { return containmentErrorMessage }
        guard target.count > library.count else { return nil }
        let next = target[target.index(target.startIndex, offsetBy: library.count)]
        // A bare string prefix would also match "/lib-stuff"; only a real
        // path component boundary counts.
        return next == "/" ? containmentErrorMessage : nil
    }
}
