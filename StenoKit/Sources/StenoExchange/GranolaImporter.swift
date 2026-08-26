import Foundation
import StenoDomain
import StenoLibrary

// Port of skills/granola-to-steno semantics: a Granola JSON export (titles,
// dates, participants, summaries, verbatim transcripts) is imported into
// fresh meetings. Every imported meeting carries the provenance key
// `granola:<noteId>` so a repeated import of the same export skips existing
// meetings instead of duplicating them - the whole flow is safe to rerun.

// MARK: - Export document parsing

/// One meeting note extracted from a Granola JSON export.
///
/// Field names are matched tolerantly because Granola's export shape has
/// drifted between versions: every field accepts common aliases and missing
/// values degrade to empty strings rather than failing the whole import.
public struct GranolaNote: Equatable, Sendable {
    public let noteID: String
    public let title: String
    /// Parsed meeting date; nil when the export carries no parseable date.
    public let date: Date?
    /// The unparsed raw date string, kept for diagnostics.
    public let rawDate: String?
    /// Cleaned participant display names (emails and company suffixes removed).
    public let participants: [String]
    /// The AI summary markdown; empty when the note has none.
    public let summary: String
    /// The verbatim transcript; empty when the note has none.
    public let transcript: String

    public init(
        noteID: String,
        title: String,
        date: Date?,
        rawDate: String?,
        participants: [String],
        summary: String,
        transcript: String
    ) {
        self.noteID = noteID
        self.title = title
        self.date = date
        self.rawDate = rawDate
        self.participants = participants
        self.summary = summary
        self.transcript = transcript
    }
}

public struct GranolaParseResult: Equatable, Sendable {
    public let notes: [GranolaNote]
    /// Export entries skipped because they carried no usable note ID.
    public let skippedCount: Int

    public init(notes: [GranolaNote], skippedCount: Int) {
        self.notes = notes
        self.skippedCount = skippedCount
    }
}

public enum GranolaExchangeError: Error, Equatable, Sendable {
    case invalidFormat(String)
}

public enum GranolaDocument {
    public static func read(from url: URL) throws -> GranolaParseResult {
        try read(Data(contentsOf: url))
    }

    public static func read(_ data: Data) throws -> GranolaParseResult {
        let root = try JSONSerialization.jsonObject(with: data, options: [])
        let entries: [Any]
        switch root {
        case let array as [Any]:
            entries = array
        case let object as [String: Any]:
            guard let value = ["notes", "meetings", "documents"]
                .compactMap({ object[$0] as? [Any] }).first else {
                throw GranolaExchangeError.invalidFormat(
                    "Expected a JSON array of notes or an object with a notes/meetings/documents array"
                )
            }
            entries = value
        default:
            throw GranolaExchangeError.invalidFormat(
                "Unexpected top-level JSON structure"
            )
        }

        var notes: [GranolaNote] = []
        var skippedCount = 0
        for entry in entries {
            guard let object = entry as? [String: Any],
                  let noteID = stringField(in: object, ["id", "noteId", "note_id"]),
                  !noteID.isEmpty else {
                skippedCount += 1
                continue
            }
            let rawTitle = stringField(in: object, ["title", "name"]) ?? ""
            let rawDate = stringField(
                in: object,
                ["date", "created_at", "createdAt", "start_time", "startTime"]
            )
            notes.append(GranolaNote(
                noteID: noteID,
                title: rawTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                date: rawDate.flatMap(parseDate),
                rawDate: rawDate,
                participants: participants(in: object),
                summary: (stringField(
                    in: object,
                    ["summary", "notes_plain", "notes_markdown", "notes"]
                ) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                transcript: stringField(
                    in: object,
                    ["transcript", "transcript_text", "transcript_plain"]
                ) ?? ""
            ))
        }
        return GranolaParseResult(notes: notes, skippedCount: skippedCount)
    }

    private static func stringField(
        in object: [String: Any],
        _ keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
            // Numeric IDs are written by some export variants.
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func participants(in object: [String: Any]) -> [String] {
        let rawValues = ["participants", "known_participants"]
            .compactMap { object[$0] }
        var names: [String] = []
        for raw in rawValues {
            if let list = raw as? [Any] {
                for item in list {
                    if let name = item as? String {
                        names.append(name)
                    } else if let object = item as? [String: Any],
                              let name = stringField(
                                  in: object,
                                  ["name", "displayName", "display_name"]
                              ) {
                        names.append(name)
                    }
                }
            } else if let joined = raw as? String {
                // Some exports carry one semicolon/comma-separated string.
                names.append(contentsOf: joined.split(
                    whereSeparator: { $0 == ";" || $0 == "," }
                ).map(String.init))
            }
        }
        // Strip emails, "from <Company>" and "(note creator)" decorations,
        // matching the staging rules of the legacy skill script.
        let cleaned = names.map { name in
            var cleaned = name
            for pattern in ["from ", "(note creator)"] {
                while let range = cleaned.range(of: pattern) {
                    cleaned.removeSubrange(range)
                }
            }
            if let angleStart = cleaned.firstIndex(of: "<"),
               let angleEnd = cleaned.firstIndex(of: ">"),
               angleStart < angleEnd {
                cleaned.removeSubrange(angleStart...angleEnd)
            }
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var seen = Set<String>()
        return cleaned.filter {
            !$0.isEmpty && seen.insert(normalizedGranolaPersonName($0)).inserted
        }
    }

    /// Parses both ISO-8601 timestamps and the human display format Granola
    /// shows in its UI ("Jun 26, 2026 2:30 PM GMT+2").
    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let internetDateTime = ISO8601DateFormatter()
        if let date = internetDateTime.date(from: trimmed) { return date }
        let fractionalSeconds = ISO8601DateFormatter()
        fractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalSeconds.date(from: trimmed) { return date }

        let display = DateFormatter()
        display.locale = Locale(identifier: "en_US_POSIX")
        // Pinned so display strings WITHOUT an offset never depend on the
        // host timezone; inputs carrying "GMT+2" style zones override it.
        display.timeZone = TimeZone(identifier: "UTC")
        display.dateFormat = "MMM d, yyyy h:mm a zzz"
        if let date = display.date(from: trimmed) { return date }

        let compact = DateFormatter()
        compact.locale = Locale(identifier: "en_US_POSIX")
        compact.timeZone = TimeZone(identifier: "UTC")
        compact.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = compact.date(from: trimmed) { return date }
        return nil
    }
}

/// Same normalization as the legacy importer's person matching.
private func normalizedGranolaPersonName(_ name: String) -> String {
    name.split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .precomposedStringWithCanonicalMapping
}

// MARK: - Meeting preparation

struct PreparedGranolaMeeting {
    let bundle: PreparedMeetingImport
    let warnings: [String]
}

func prepareGranolaMeeting(
    note: GranolaNote,
    participantIDs: [PersonID]
) -> PreparedGranolaMeeting {
    var warnings: [String] = []
    // Deterministic placeholder for an unparseable date, mirroring the legacy
    // convention: never now(), so a rerun produces the same result.
    let createdAt = note.date ?? Date(timeIntervalSince1970: 0)
    if note.date == nil, let rawDate = note.rawDate {
        warnings.append(
            "Note \(note.noteID) has an unreadable date (\(rawDate)); "
                + "a placeholder date was used."
        )
    }
    let meeting = Meeting(
        title: note.title.isEmpty ? note.noteID : note.title,
        createdAt: createdAt,
        status: .ready,
        // Participants arrive without speech evidence, so they are recorded
        // as silent attendees, never as confirmed speakers.
        additionalParticipantIDs: participantIDs,
        metadata: MeetingMetadata(
            legacyProvenanceKey: GranolaImporter.provenanceKey(
                forNoteID: note.noteID
            )
        )
    )

    let turns = granolaTranscriptTurns(note.transcript)
    // StenoDomain knows no dedicated Granola origin; the import-origin marker
    // of the legacy importer is reused so imported text never masquerades as
    // machine-generated ASR output.
    let revision = TranscriptRevision(
        meetingID: meeting.id,
        createdAt: createdAt,
        origin: .legacyImport,
        turns: turns
    )

    // notes = summary: the summary becomes the meeting's user-editable note.
    var notes: [PreparedMeetingNoteImport] = []
    if !note.summary.isEmpty {
        notes.append(PreparedMeetingNoteImport(
            fileName: "user-notes.md",
            data: Data(note.summary.utf8)
        ))
    }

    return PreparedGranolaMeeting(
        bundle: PreparedMeetingImport(
            meeting: meeting,
            media: [],
            revision: revision,
            notes: notes
        ),
        warnings: warnings
    )
}

/// Splits a Granola verbatim transcript into turns. `Me:` / `Them:` /
/// `Speaker N:` markers open labelled turns; transcripts without any marker
/// fall back to blank-line paragraphs without speaker attribution. Durations
/// are estimated from word count, following the legacy importer.
func granolaTranscriptTurns(_ transcript: String) -> [TranscriptTurn] {
    let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return [] }
    let lines = body.components(separatedBy: .newlines)

    struct Block {
        var speakerLabel: String?
        var lines: [String] = []
    }
    var blocks: [Block] = []
    for line in lines {
        if let label = granolaSpeakerMarker(line) {
            blocks.append(Block(speakerLabel: label, lines: [line]))
        } else if blocks.indices.contains(blocks.count - 1),
                  blocks[blocks.count - 1].speakerLabel != nil {
            blocks[blocks.count - 1].lines.append(line)
        } else {
            if blocks.indices.contains(blocks.count - 1),
               blocks[blocks.count - 1].speakerLabel == nil {
                blocks[blocks.count - 1].lines.append(line)
            } else {
                blocks.append(Block(speakerLabel: nil, lines: [line]))
            }
        }
    }

    // No speaker markers anywhere: treat blank-line separated paragraphs as
    // unattributed turns instead.
    if blocks.allSatisfy({ $0.speakerLabel == nil }) {
        let paragraphs = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var cursor: TimeInterval = 0
        return paragraphs.map { paragraph in
            let end = cursor + estimatedGranolaSpeechDuration(paragraph)
            defer { cursor = end }
            return granolaTranscriptTurn(
                text: paragraph,
                start: cursor,
                end: end,
                speaker: nil
            )
        }
    }

    var cursor: TimeInterval = 0
    return blocks
        .map { block in
            (
                label: block.speakerLabel,
                text: block.lines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        .filter { !$0.text.isEmpty }
        .map { block in
            let end = cursor + estimatedGranolaSpeechDuration(block.text)
            defer { cursor = end }
            let speaker = block.label.map { SpeakerReference.channel($0) }
            return granolaTranscriptTurn(
                text: block.text,
                start: cursor,
                end: end,
                speaker: speaker
            )
        }
}

/// Recognises the turn markers emitted by Granola transcripts (`Me:`,
/// `Them:`, `You:`, `Speaker 3:`). A general `Name:` heuristic would misfire
/// on URLs and times, so the accepted labels stay deliberately narrow.
private func granolaSpeakerMarker(_ line: String) -> String? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
    switch label {
    case "Me", "Them", "You":
        return label
    default:
        guard label.hasPrefix("Speaker "),
              let digits = Int(label.dropFirst("Speaker ".count))
        else { return nil }
        return digits >= 0 ? label : nil
    }
}

private func estimatedGranolaSpeechDuration(_ text: String) -> TimeInterval {
    let wordCount = text.split(whereSeparator: \.isWhitespace).count
    return max(1, Double(wordCount) / 2.5)
}

private func granolaTranscriptTurn(
    text: String,
    start: TimeInterval,
    end: TimeInterval,
    speaker: SpeakerReference?
) -> TranscriptTurn {
    TranscriptTurn(
        speaker: speaker,
        start: start,
        end: end,
        segments: [TranscriptSegment(text: text, start: start, end: end, words: [])]
    )
}

// MARK: - Import reporting

public struct GranolaImportProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let title: String

    public init(completed: Int, total: Int, title: String) {
        self.completed = completed
        self.total = total
        self.title = title
    }
}

public struct GranolaImportReport: Equatable, Sendable {
    public internal(set) var meetingsCreated = 0
    public internal(set) var notesCreated = 0
    public internal(set) var peopleCreated = 0
    public internal(set) var duplicates: [String] = []
    public internal(set) var warnings: [String] = []

    public init() {}
}

public enum GranolaImportOutcome: Equatable, Sendable {
    case finished(GranolaImportReport)
    case cancelled(GranolaImportReport)

    public var report: GranolaImportReport {
        switch self {
        case .finished(let report), .cancelled(let report): report
        }
    }
}

// MARK: - Importer

public struct GranolaImporter: Sendable {
    public let library: Library

    public init(library: Library) {
        self.library = library
    }

    /// Stable provenance key of a Granola note inside the library.
    public static func provenanceKey(forNoteID noteID: String) -> String {
        "granola:\(noteID)"
    }

    public func performImport(
        from url: URL,
        progress: (@Sendable (GranolaImportProgress) -> Void)? = nil
    ) async throws -> GranolaImportOutcome {
        var report = GranolaImportReport()
        do {
            try Task.checkCancellation()
            let parse = try GranolaDocument.read(from: url)
            if parse.skippedCount > 0 {
                report.warnings.append(
                    "\(parse.skippedCount) export entry/entries without a "
                        + "usable note ID were skipped."
                )
            }

            let identityStore = try IdentityStore(layout: library.layout)
            let identitySnapshot = try await identityStore.snapshot()
            var persons = identitySnapshot.persons
            var identityRevision = identitySnapshot.revision
            var createdPeople = 0

            // Creates or reuses a person per normalized display name and
            // persists additions immediately, so a committed meeting never
            // references a person that a later cancellation would lose.
            func personID(
                forName name: String
            ) async throws -> PersonID {
                let key = normalizedGranolaPersonName(name)
                if let existing = persons.first(where: {
                    normalizedGranolaPersonName($0.displayName) == key
                }) {
                    return existing.id
                }
                let person = Person(
                    id: PersonID(),
                    displayName: name,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                persons.append(person)
                identityRevision = try await identityStore.replacePersons(
                    persons,
                    expectedRevision: identityRevision
                )
                createdPeople += 1
                return person.id
            }

            var completed = 0
            let total = parse.notes.count
            func reportProgress(_ title: String) {
                completed += 1
                progress?(GranolaImportProgress(
                    completed: completed,
                    total: total,
                    title: title
                ))
            }

            for note in parse.notes {
                try Task.checkCancellation()
                let displayName = note.title.isEmpty ? note.noteID : note.title
                let provenanceKey = Self.provenanceKey(forNoteID: note.noteID)
                // Duplicate re-import skips existing provenance keys.
                if try await library.meetingID(forProvenanceKey: provenanceKey) != nil {
                    report.duplicates.append(displayName)
                    reportProgress(displayName)
                    continue
                }
                do {
                    var participantIDs: [PersonID] = []
                    for name in note.participants {
                        try Task.checkCancellation()
                        participantIDs.append(try await personID(forName: name))
                    }
                    // Counted people belong to this meeting's report line
                    // even if its own commit below fails.
                    let newlyCreatedPeople = createdPeople
                    createdPeople = 0
                    let prepared = prepareGranolaMeeting(
                        note: note,
                        participantIDs: participantIDs
                    )
                    _ = try await library.commitPreparedMeeting(prepared.bundle)
                    report.meetingsCreated += 1
                    report.notesCreated += prepared.bundle.notes.count
                    report.peopleCreated += newlyCreatedPeople
                    report.warnings.append(contentsOf: prepared.warnings)
                } catch let error where !(error is CancellationError) {
                    report.warnings.append(
                        "\"\(displayName)\" could not be imported and was "
                            + "skipped: \(error)"
                    )
                }
                reportProgress(displayName)
            }
            return .finished(report)
        } catch is CancellationError {
            return .cancelled(report)
        }
    }
}
